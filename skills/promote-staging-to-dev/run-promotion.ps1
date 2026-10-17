<#
.SYNOPSIS
    Promote staging -> dev with a pull request, CI checks, and a merge.
    The `staging` branch is never deleted.

.DESCRIPTION
      1. Fetches and verifies both branches exist.
      2. Detects whether `staging` actually contains content missing from `dev`.
      3. Reuses an open promotion PR when one exists (idempotent re-runs).
      4. Builds a release-style title + body from the real commits and diff.
      5. Waits for CI with stall detection and automatic workflow re-runs.
      6. Merges the PR with a true merge commit and keeps `staging`.

    Exit codes:
      0  success (or PR created with -NoWait, or nothing to promote)
      1  unexpected failure
      2  local build gate failed (only with -RunBuildGates)
      3  CI failed / PR closed
      4  CI still running / timed out
      5  merge blocked (conflict or protection)

.EXAMPLE
    .\run-promotion.ps1

.EXAMPLE
    .\run-promotion.ps1 -DryRun

.EXAMPLE
    .\run-promotion.ps1 -NoWait
    # later
    .\run-promotion.ps1 -Resume

.NOTES
    Requires: git, GitHub CLI (gh), authenticated gh session.
#>

[CmdletBinding()]
param(
    [string]$HeadBranch = 'staging',
    [string]$BaseBranch = 'dev',
    [ValidateSet('merge', 'squash', 'rebase')]
    [string]$MergeMethod = 'merge',
    [int]$MaxWaitMinutes = 15,
    [int]$StuckAfterMinutes = 5,
    [string]$Title,
    [switch]$ShowBody,
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
|  Promote staging -> dev  (PR -> CI -> merge, branch kept)     |
+---------------------------------------------------------------+
"@ -ForegroundColor Magenta

    # --- 0. Pre-flight -----------------------------------------------------
    Write-Step 'Pre-flight checks'
    $repoRoot = Assert-Preflight -RequireGh
    Write-Ok "Repository: $repoRoot"

    Invoke-External -FilePath git -CommandArgs @('fetch', 'origin', '--prune') -AllowFailure | Out-Null

    if (-not (Test-RemoteBranch -Branch $HeadBranch)) {
        throw "Remote branch 'origin/$HeadBranch' does not exist. Run execute-staging-pr-workflow first."
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
            Write-Info "'$HeadBranch' is $behind commit(s) behind '$BaseBranch' (that is fine)."
        }
        return
    }

    if ($behind -gt 0) {
        Write-Warn "'$BaseBranch' contains $behind commit(s) not in '$HeadBranch'. The merge commit will preserve them."
    }

    $changedFiles = @(& git diff --name-only "$baseRef...$headRef" 2>$null | Where-Object { $_ })
    $areas = @(Get-Areas -Files $changedFiles)
    Write-Info "$($changedFiles.Count) file(s) changed across: $($areas.Name -join ', ')"

    # --- 2. Optional local gates ------------------------------------------
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

    # --- 3. Collect commits for the title/body ----------------------------
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

    # --- 4. Title ----------------------------------------------------------
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

    # --- 5. Body -----------------------------------------------------------
    $highlightSource = @($commits | Where-Object { $_.Type -in @('feat', 'fix', 'refactor', 'perf') } | Select-Object -First 3)
    if ($highlightSource.Count -eq 0) { $highlightSource = @($commits | Select-Object -First 3) }
    $highlightLines = @($highlightSource | ForEach-Object { "- $($_.Subject)" })
    if ($highlightLines.Count -eq 0) {
        $highlightLines = @('- Content-only promotion: the commit history was previously squashed. See the diffstat below.')
    }

    $commitPreview = @($commits | Select-Object -First 30)
    $commitLines = @($commitPreview | ForEach-Object { "| ``$($_.Sha)`` | $($_.Type) | $($_.Subject) |" })
    if ($commits.Count -eq 0) {
        $commitLines = @('| - | - | No unique commits (content-only promotion) |')
    }
    elseif ($commits.Count -gt $commitPreview.Count) {
        $commitLines += "| ... | | $($commits.Count - $commitPreview.Count) more commit(s) |"
    }

    $areaLines = @($areas | Where-Object { $_.Name -ne 'project' } | ForEach-Object { "- ``$($_.Name)``: $($_.Count) file(s)" })
    if ($areaLines.Count -eq 0) { $areaLines = @('- `project`: documentation / shared files') }

    $statLines = @(& git diff --stat "$baseRef...$headRef" 2>$null | Select-Object -Last 1)
    $statText = ($statLines -join [Environment]::NewLine)

    $highlightBlock = $highlightLines -join [Environment]::NewLine
    $commitBlock = $commitLines -join [Environment]::NewLine
    $areaBlock = $areaLines -join [Environment]::NewLine

    $prBody = @"
## Promotion: ``$HeadBranch`` -> ``$BaseBranch``

Promotes the content of ``$HeadBranch`` into ``$BaseBranch``.
- Base ``$BaseBranch`` at ``$baseSha``
- Head ``$HeadBranch`` at ``$headSha``
- $($changedFiles.Count) file(s) changed, $ahead commit(s) ahead

## Highlights
$highlightBlock

## Commits (newest first)
| Commit | Type | Subject |
| --- | --- | --- |
$commitBlock

## Affected areas
$areaBlock

## Diffstat
``````text
$statText
``````

## Validation
- [x] Feature work was already merged into ``$HeadBranch``
- [x] CI checks verified by this workflow
- [ ] Reviewer sign-off (only if branch protection requires it)

## Promotion semantics
- ``$HeadBranch`` is **not** deleted after this merge.
- Merge method: ``$MergeMethod``.
- ``$BaseBranch`` must remain the only path to ``main``.

## Rollback
- Pre-merge ``$BaseBranch`` tip: ``$baseSha``
- Revert the merge commit: ``git revert -m 1 <merge-sha>``
"@

    # --- 6. Create or reuse the PR ----------------------------------------
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
            Write-Host "  Merge : $MergeMethod (branch is kept)"
            Write-Host "  Files : $($changedFiles.Count)"
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
  Next : re-run with -Resume to wait and merge.
"@ -ForegroundColor Yellow
        return
    }

    # --- 7. Wait for checks ----------------------------------------------
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

    # --- 8. Merge (never delete the head branch) --------------------------
    Write-Step "Merging PR #$prNumber into $BaseBranch"

    try {
        $mergeStatus = Merge-PullRequestSafe -PrNumber $prNumber -MergeMethod $MergeMethod -DeleteBranch:$false
    }
    catch {
        Write-Fail $_.Exception.Message
        Write-Host @"

The PR is still open: $prUrl
Resolve the blocker, then re-run with -Resume.
"@ -ForegroundColor Yellow
        exit 5
    }

    $finalState = Get-PullRequestState -PrNumber $prNumber
    if ($finalState -eq 'MERGED') {
        Write-Ok "PR #$prNumber merged into $BaseBranch (head branch kept)"
    }
    else {
        Write-Warn "Merge status: $mergeStatus (PR state: $finalState)"
    }

    # --- 9. Post-merge sync (never delete staging) ------------------------
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
|                   Promotion complete                          |
+---------------------------------------------------------------+
  PR      : $prUrl
  Route   : $HeadBranch -> $BaseBranch
  Checks  : $checkStatus
  Merge   : $mergeStatus ($MergeMethod) / $finalState
  Kept    : $HeadBranch
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
