<#
.SYNOPSIS
    Promote dev -> main with a pull request, CI checks, confirmation, and a merge.
    Neither `dev` nor `main` is ever deleted.

.DESCRIPTION
      1. Fetches and verifies both branches exist.
      2. Refuses to continue when content conflicts exist or main is ahead in a
         way that makes the promotion unsafe.
      3. Builds production release notes (grouped by commit type).
      4. Requires explicit confirmation before merging to main.
      5. Waits for CI with stall detection and automatic workflow re-runs.
      6. Merges with a true merge commit, keeps `dev`, and optionally tags the release.

    Exit codes:
      0  success (or PR created with -NoWait, or nothing to promote)
      1  unexpected failure
      2  local build gate failed (only with -RunBuildGates)
      3  CI failed / PR closed
      4  CI still running / timed out
      5  merge blocked (conflict or protection)
      6  confirmation missing

.EXAMPLE
    .\run-promotion.ps1 -Yes

.EXAMPLE
    .\run-promotion.ps1 -Tag v1.4.0 -Yes

.EXAMPLE
    .\run-promotion.ps1 -DryRun

.NOTES
    Requires: git, GitHub CLI (gh), authenticated gh session.
#>

[CmdletBinding()]
param(
    [string]$HeadBranch = 'dev',
    [string]$BaseBranch = 'main',
    [ValidateSet('merge', 'squash', 'rebase')]
    [string]$MergeMethod = 'merge',
    [int]$MaxWaitMinutes = 15,
    [int]$StuckAfterMinutes = 5,
    [string]$Title,
    [string]$Tag,
    [switch]$ShowBody,
    [switch]$Yes,
    [switch]$RunBuildGates,
    [switch]$AutoFix,
    [switch]$SkipTests,
    [switch]$AllowCheckTimeout,
    [switch]$NoWait,
    [switch]$Resume,
    [switch]$DryRun
)

. (Join-Path $PSScriptRoot '..\_shared\pr-workflow-lib.ps1')

try {
    Write-Host @"
+---------------------------------------------------------------+
|  Promote dev -> main  (PR -> CI -> confirm -> merge)          |
+---------------------------------------------------------------+
"@ -ForegroundColor Magenta

    # --- 0. Pre-flight -----------------------------------------------------
    Write-Step 'Pre-flight checks'
    $repoRoot = Assert-Preflight -RequireGh
    Write-Ok "Repository: $repoRoot"

    Invoke-External -FilePath git -CommandArgs @('fetch', 'origin', '--prune') -AllowFailure | Out-Null

    if (-not (Test-RemoteBranch -Branch $HeadBranch)) {
        throw "Remote branch 'origin/$HeadBranch' does not exist."
    }
    if (-not (Test-RemoteBranch -Branch $BaseBranch)) {
        throw "Remote branch 'origin/$BaseBranch' does not exist."
    }
    Write-Ok "Branches present: origin/$HeadBranch -> origin/$BaseBranch"

    $baseRef = "origin/$BaseBranch"
    $headRef = "origin/$HeadBranch"
    $baseSha = Get-GitValue -CommandArgs @('rev-parse', '--short', $baseRef)
    $headSha = Get-GitValue -CommandArgs @('rev-parse', '--short', $headRef)

    # --- 1. Is there anything to promote? ---------------------------------
    Write-Step 'Comparing branches'

    & git diff --quiet "$baseRef...$headRef" 2>$null
    $hasContentDiff = ($LASTEXITCODE -ne 0)

    $ahead = [int](Get-GitValue -CommandArgs @('rev-list', '--count', "$baseRef..$headRef"))
    $behind = [int](Get-GitValue -CommandArgs @('rev-list', '--count', "$headRef..$baseRef"))

    Write-Info "Commits ahead: $ahead | Commits behind: $behind"
    Write-Info "Base $BaseBranch @ $baseSha | Head $HeadBranch @ $headSha"

    if (-not $hasContentDiff) {
        Write-Ok "Nothing to promote: '$HeadBranch' has no content that '$BaseBranch' is missing."
        if ($behind -gt 0) {
            Write-Info "'$HeadBranch' is $behind commit(s) behind '$BaseBranch' (hotfixes already in main)."
        }
        return
    }

    if ($behind -gt 0) {
        Write-Warn "'$BaseBranch' contains $behind commit(s) not in '$HeadBranch'."
        Write-Warn 'The merge commit preserves them, but remember to sync main back into dev afterwards.'
    }

    # --- 2. Conflict pre-check (do not open a doomed production PR) -------
    Write-Step 'Checking for merge conflicts'

    $mergeTreeOutput = @(& git merge-tree --write-tree $baseRef $headRef 2>&1)
    $mergeTreeExit = $LASTEXITCODE
    $mergeTreeText = ($mergeTreeOutput -join "`n")

    if ($mergeTreeExit -ne 0 -and $mergeTreeText -match '(?i)conflict') {
        Write-Fail 'The branches conflict. Nothing was created.'
        Write-Host @"

Resolve before promoting:
  1. Merge origin/main into dev through a feature branch.
  2. Re-run execute-staging-pr-workflow, then promote-staging-to-dev.
  3. Then re-run this promotion.
"@ -ForegroundColor Yellow
        exit 5
    }

    $changedFiles = @(& git diff --name-only "$baseRef...$headRef" 2>$null | Where-Object { $_ })
    $areas = @(Get-Areas -Files $changedFiles)
    Write-Info "$($changedFiles.Count) file(s) changed across: $($areas.Name -join ', ')"

    $migrationFiles = @($changedFiles | Where-Object { $_ -match '(?i)(migration|\.entity\.ts$)' })
    if ($migrationFiles.Count -gt 0) {
        Write-Warn "This release contains $($migrationFiles.Count) migration/entity file(s). Confirm a backup + rollback plan."
    }

    # --- 3. Optional local gates ------------------------------------------
    if ($RunBuildGates) {
        Write-Step 'Running local build + typecheck gates'

        $currentBranch = ((& git branch --show-current 2>$null) -join '').Trim()
        $dirty = ((& git status --porcelain 2>$null) -join '').Trim()
        $headMatches = ($currentBranch -eq $HeadBranch)

        if (-not $headMatches -or $dirty) {
            Write-Warn "Local tree is not a clean '$HeadBranch' checkout; skipping local gates and relying on CI."
        }
        else {
            $gateResults = @(Invoke-BuildGates -Files $changedFiles -AutoFix:$AutoFix)
            $failedGates = @($gateResults | Where-Object { -not $_.Success })
            if ($failedGates.Count -gt 0) {
                Write-FixGuidance -Results $gateResults
                exit 2
            }
            Write-Ok 'Local gates passed'
        }
    }

    # --- 4. Collect commits for release notes -----------------------------
    $rawCommits = @(& git log --format='%h%x09%s' "$baseRef..$headRef" 2>$null | Where-Object { $_ })
    $commits = @($rawCommits | ForEach-Object {
            $parts = $_ -split "`t", 2
            $subject = if ($parts.Length -gt 1) { $parts[1] } else { $parts[0] }
            $commitType = 'other'
            if ($subject -match '^([a-z]+)(\([^)]+\))?!?:') { $commitType = $matches[1] }
            [pscustomobject]@{ Sha = $parts[0]; Subject = $subject; Type = $commitType }
        })

    $featCommits = @($commits | Where-Object { $_.Type -eq 'feat' })
    $fixCommits = @($commits | Where-Object { $_.Type -eq 'fix' })
    $perfCommits = @($commits | Where-Object { $_.Type -eq 'perf' })
    $breakingCommits = @($commits | Where-Object { $_.Subject -match '^[a-z]+(\([^)]+\))?!:' })
    $otherCommits = @($commits | Where-Object { $_.Type -notin @('feat', 'fix', 'perf') })

    # --- 5. Title ----------------------------------------------------------
    if (-not [string]::IsNullOrWhiteSpace($Title)) {
        $prTitle = $Title
    }
    elseif ($commits.Count -eq 1) {
        $prTitle = $commits[0].Subject
    }
    elseif ($featCommits.Count -gt 0) {
        $top = ($featCommits[0].Subject -replace '^[a-z]+(\([^)]+\))?!?:\s*', '')
        $prTitle = "release: $top (+$($commits.Count - 1) more)"
    }
    elseif ($fixCommits.Count -gt 0) {
        $top = ($fixCommits[0].Subject -replace '^[a-z]+(\([^)]+\))?!?:\s*', '')
        $prTitle = "release: $top (+$($commits.Count - 1) more)"
    }
    else {
        $prTitle = "release: promote $HeadBranch to $BaseBranch"
    }

    if ($prTitle.Length -gt 100) {
        $prTitle = "release: promote $HeadBranch to $BaseBranch ($($changedFiles.Count) files)"
    }

    # --- 6. Release notes body --------------------------------------------
    function Format-CommitGroup {
        param([object[]]$Items, [string]$Heading)
        if ($Items.Count -eq 0) { return '' }
        $lines = @("### $Heading", '')
        $lines += @($Items | Select-Object -First 25 | ForEach-Object { "- $($_.Subject) (``$($_.Sha)``)" })
        if ($Items.Count -gt 25) { $lines += "- ... and $($Items.Count - 25) more" }
        $lines += ''
        return ($lines -join [Environment]::NewLine)
    }

    $notes = @(
        (Format-CommitGroup -Items $featCommits -Heading 'Features'),
        (Format-CommitGroup -Items $fixCommits -Heading 'Fixes'),
        (Format-CommitGroup -Items $perfCommits -Heading 'Performance'),
        (Format-CommitGroup -Items $otherCommits -Heading 'Other changes')
    ) | Where-Object { $_ }
    $notesBlock = $notes -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($notesBlock)) {
        $notesBlock = 'No unique commits (content-only promotion). See the diffstat below.'
    }

    $breakingBlock = ''
    if ($breakingCommits.Count -gt 0) {
        $breakingLines = @('## Breaking changes', '')
        $breakingLines += @($breakingCommits | ForEach-Object { "- $($_.Subject) (``$($_.Sha)``)" })
        $breakingLines += ''
        $breakingBlock = $breakingLines -join [Environment]::NewLine
    }

    $areaLines = @($areas | Where-Object { $_.Name -ne 'project' } | ForEach-Object { "- ``$($_.Name)``: $($_.Count) file(s)" })
    if ($areaLines.Count -eq 0) { $areaLines = @('- `project`: documentation / shared files') }
    $areaBlock = $areaLines -join [Environment]::NewLine

    $statLines = @(& git diff --stat "$baseRef...$headRef" 2>$null | Select-Object -Last 1)
    $statText = ($statLines -join [Environment]::NewLine)

    $migrationBlock = ''
    if ($migrationFiles.Count -gt 0) {
        $migrationLines = @('## Migration / schema files', '')
        $migrationLines += @($migrationFiles | Select-Object -First 20 | ForEach-Object { "- ``$_``" })
        $migrationBlock = $migrationLines -join [Environment]::NewLine
    }

    $tagLine = if ($Tag) { "- Release tag: ``$Tag`` (created after merge)" } else { '- Release tag: none' }
    $tagRollback = if ($Tag) { "- If the tag was created: ``git push --delete origin $Tag`` (and delete it locally)" } else { '' }

    $prBody = @"
## Release: ``$HeadBranch`` -> ``$BaseBranch``

Production promotion of everything currently in ``$HeadBranch``.
- Base ``$BaseBranch`` at ``$baseSha``
- Head ``$HeadBranch`` at ``$headSha``
- $($changedFiles.Count) file(s) changed, $ahead commit(s) ahead

$breakingBlock
## Release notes
$notesBlock

## Affected areas
$areaBlock

## Diffstat
``````text
$statText
``````

$migrationBlock
## Deployment checklist
- [ ] ``$HeadBranch`` verified after the staging promotion
- [ ] Database migrations reviewed (and a backup exists)
- [ ] Environment/config changes applied to production
- [ ] Deploy window approved
- [ ] Rollback plan confirmed
- [ ] CI checks green on this PR

## Promotion semantics
- ``$HeadBranch`` is **not** deleted after this merge.
- ``$BaseBranch`` is **not** deleted.
- Merge method: ``$MergeMethod``.
$tagLine

## Rollback
- Pre-merge ``$BaseBranch`` tip: ``$baseSha``
- Revert the merge commit: ``git revert -m 1 <merge-sha>``
$tagRollback
"@

    # --- 7. Create or reuse the PR ----------------------------------------
    Write-Step "Preparing PR: $HeadBranch -> $BaseBranch"

    $openPr = Get-OpenPullRequest -HeadBranch $HeadBranch -BaseBranch $BaseBranch

    if ($openPr) {
        Write-Info "Reusing open PR #$($openPr.number): $($openPr.url)"
        $prUrl = $openPr.url
        $prNumber = "$($openPr.number)"
    }
    else {
        if ($DryRun) {
            Write-Step 'Dry run summary'
            Write-Host "  Title : $prTitle"
            Write-Host "  Head  : $HeadBranch ($headSha)"
            Write-Host "  Base  : $BaseBranch ($baseSha)"
            Write-Host "  Merge : $MergeMethod (both branches kept)"
            Write-Host "  Files : $($changedFiles.Count)"
            Write-Host "  Tag   : $(if ($Tag) { $Tag } else { '(none)' })"
            if ($ShowBody) {
                Write-Host "`n----- PR BODY -----" -ForegroundColor DarkGray
                Write-Host $prBody -ForegroundColor DarkGray
                Write-Host '-------------------' -ForegroundColor DarkGray
            }
            return
        }

        $createOutput = ((& gh pr create --base $BaseBranch --head $HeadBranch --title $prTitle --body $prBody 2>&1) -join "`n").Trim()
        if ($LASTEXITCODE -ne 0 -or $createOutput -notmatch '^https?://') {
            throw "PR creation failed: $createOutput"
        }
        Write-Ok "PR created: $createOutput"
        $prUrl = $createOutput
        $prNumber = Get-GhValue -CommandArgs @('pr', 'view', $prUrl, '--json', 'number', '--jq', '.number')
    }

    if ($DryRun) {
        Write-Step 'Dry run summary'
        Write-Host "  Would reuse PR #$prNumber ($prUrl)"
        return
    }

    if ($NoWait) {
        Write-Host @"

+---------------------------------------------------------------+
|               PR created (checks not awaited)                 |
+---------------------------------------------------------------+
  PR   : $prUrl
  Next : re-run with -Resume -Yes to wait and merge into main.
"@ -ForegroundColor Yellow
        return
    }

    # --- 8. Wait for checks ----------------------------------------------
    $checkStatus = 'SKIPPED'
    if (-not $SkipTests) {
        Write-Step "Waiting for CI checks on PR #$prNumber"
        $checkResult = Wait-PullRequestChecks -PrNumber $prNumber -HeadBranch $HeadBranch -MaxWaitMinutes $MaxWaitMinutes -StuckAfterMinutes $StuckAfterMinutes
        Format-CheckResult -CheckResult $checkResult -PrNumber $prNumber -HeadBranch $HeadBranch
        $checkStatus = $checkResult.Status

        switch ($checkStatus) {
            'FAILED' { Write-Fail 'CI failed. Nothing was merged.'; exit 3 }
            'CLOSED' { Write-Fail "PR #$prNumber is no longer open."; exit 3 }
            'TIMEOUT' {
                if (-not $AllowCheckTimeout) {
                    Write-Warn 'Leaving the PR open for a later -Resume run.'
                    exit 4
                }
                Write-Warn 'Proceeding despite pending checks (-AllowCheckTimeout)'
            }
        }
    }
    else {
        Write-Warn 'Skipping CI checks (-SkipTests)'
    }

    # --- 9. Production confirmation ---------------------------------------
    if (-not $Yes) {
        Write-Host "`nAbout to merge '$HeadBranch' into '$BaseBranch':" -ForegroundColor Yellow
        Write-Host "  PR    : $prUrl"
        Write-Host "  Files : $($changedFiles.Count)"
        Write-Host "  Title : $prTitle"
        Write-Host "  Tag   : $(if ($Tag) { $Tag } else { '(none)' })"

        try {
            $answer = Read-Host "Type MERGE to continue"
        }
        catch {
            Write-Fail 'Confirmation required for production merges.'
            Write-Host 'Get explicit user approval, then re-run with -Yes.' -ForegroundColor Yellow
            exit 6
        }

        if ($answer -ne 'MERGE') {
            Write-Warn 'Aborted by user. The PR remains open.'
            exit 6
        }
    }

    # --- 10. Merge (never delete dev or main) -----------------------------
    Write-Step "Merging PR #$prNumber into $BaseBranch"

    try {
        $mergeStatus = Merge-PullRequestSafe -PrNumber $prNumber -MergeMethod $MergeMethod -DeleteBranch:$false
    }
    catch {
        Write-Fail $_.Exception.Message
        Write-Host @"

The PR is still open: $prUrl
Resolve the blocker, then re-run with -Resume -Yes.
"@ -ForegroundColor Yellow
        exit 5
    }

    $finalState = Get-PullRequestState -PrNumber $prNumber
    if ($finalState -eq 'MERGED') {
        Write-Ok "PR #$prNumber merged into $BaseBranch (dev and main kept)"
    }
    else {
        Write-Warn "Merge status: $mergeStatus (PR state: $finalState)"
    }

    # --- 11. Optional release tag -----------------------------------------
    if ($Tag -and $finalState -eq 'MERGED') {
        Write-Step "Creating release tag '$Tag'"

        if ($Tag -notmatch '^[A-Za-z0-9._/-]+$') {
            Write-Warn "Tag '$Tag' contains unusual characters; skipping tag creation."
        }
        else {
            $existingTag = Get-GitValue -CommandArgs @('tag', '--list', $Tag) -AllowFailure
            if (-not [string]::IsNullOrWhiteSpace($existingTag)) {
                Write-Warn "Tag '$Tag' already exists; skipping."
            }
            else {
                Invoke-External -FilePath git -CommandArgs @('tag', '-a', $Tag, '-m', "Release $Tag", "origin/$BaseBranch") | Out-Null
                Invoke-External -FilePath git -CommandArgs @('push', 'origin', $Tag) | Out-Null
                Write-Ok "Tag $Tag pushed"
            }
        }
    }

    # --- 12. Post-merge sync (never delete dev/main) ----------------------
    Write-Step 'Post-merge sync'
    Invoke-External -FilePath git -CommandArgs @('fetch', 'origin', '--prune') -AllowFailure | Out-Null

    $currentBranch = ((& git branch --show-current 2>$null) -join '').Trim()
    $dirty = ((& git status --porcelain 2>$null) -join '').Trim()
    if ($currentBranch -eq $BaseBranch -and -not $dirty) {
        Invoke-External -FilePath git -CommandArgs @('pull', '--ff-only', 'origin', $BaseBranch) -AllowFailure | Out-Null
        Write-Ok "Updated local $BaseBranch"
    }
    else {
        Write-Info "Local $BaseBranch not updated (current: '$currentBranch'). Run 'git checkout $BaseBranch; git pull --ff-only' when convenient."
    }

    Write-Ok "'$HeadBranch' kept (promotion branches are never deleted)"

    Write-Host @"

+---------------------------------------------------------------+
|                    Release complete                           |
+---------------------------------------------------------------+
  PR      : $prUrl
  Route   : $HeadBranch -> $BaseBranch
  Checks  : $checkStatus
  Merge   : $mergeStatus ($MergeMethod) / $finalState
  Kept    : $HeadBranch, $BaseBranch
  Tag     : $(if ($Tag) { $Tag } else { '(none)' })
"@ -ForegroundColor Green
}
catch {
    Write-Fail "Promotion failed: $($_.Exception.Message)"
    if ($env:PR_WORKFLOW_DEBUG) {
        Write-Host "`n$($_.ScriptStackTrace)" -ForegroundColor DarkGray
    }
    Write-Host 'Re-run with the same arguments once the issue is fixed. The open PR (if any) is reused.' -ForegroundColor Yellow
    exit 1
}
