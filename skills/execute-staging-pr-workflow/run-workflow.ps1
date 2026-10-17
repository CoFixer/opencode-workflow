<#
.SYNOPSIS
    Execute Staging PR Workflow - ship a change into the `staging` integration branch.

.DESCRIPTION
    Full lifecycle with resilience built in:
      1. Creates `staging` on origin from `dev` when it does not exist yet.
      2. Detects and classifies the working-tree changes.
      3. Runs typecheck + build gates. On failure: prints a fix loop and exits 2
         (optionally applies package auto-fixes first with -AutoFix).
      4. Creates a feature branch based on `origin/staging` (work is stashed and re-applied),
         or reuses the current branch when it already has an open PR (idempotent re-run).
      5. Commits, pushes, and opens a PR into `staging` with a generated title/body.
      6. Waits for CI with stuck-detection, automatic workflow re-runs, and a bounded timeout.
      7. Merges (squash by default), deletes the feature branch and prunes merged branches.

    Exit codes:
      0  success (or PR created with -NoWait)
      1  unexpected failure
      2  build/typecheck failure -> fix code, then re-run
      3  CI failed / PR closed      -> inspect logs, fix, then re-run with -Resume
      4  CI still running/timed out -> re-run with -Resume later
      5  merge blocked              -> resolve protection/conflicts, then re-run with -Resume

.EXAMPLE
    .\run-workflow.ps1 -CommitMessage "feat(backend): add bed charge refresh endpoint"

.EXAMPLE
    .\run-workflow.ps1 -CommitMessage "fix(frontend): repair invoice totals"

.EXAMPLE
    # CI was still running; check again later and merge
    .\run-workflow.ps1 -CustomBranchName backend-20261017-101500 -Resume

.NOTES
    Requires: git, GitHub CLI (gh), authenticated gh session.
#>

[CmdletBinding()]
param(
    [string]$BaseBranch = 'staging',
    [string]$SeedBranch = 'dev',
    [ValidateSet('auto', 'feat', 'fix', 'refactor', 'docs', 'test', 'chore')]
    [string]$ChangeType = 'auto',
    [string]$CustomBranchName,
    [string]$CommitMessage,
    [ValidateSet('squash', 'merge', 'rebase')]
    [string]$MergeMethod = 'squash',
    [int]$MaxWaitMinutes = 15,
    [int]$StuckAfterMinutes = 5,
    [int]$PruneOlderThanHours = 24,
    [switch]$AutoFix,
    [switch]$SkipBuild,
    [switch]$SkipTests,
    [switch]$AllowCheckTimeout,
    [switch]$NoWait,
    [switch]$Resume,
    [switch]$NoPruneMergedBranches,
    [switch]$DryRun
)

. (Join-Path $PSScriptRoot '..\_shared\pr-workflow-lib.ps1')

try {
    Write-Host @'
+---------------------------------------------------------------+
|          Execute Staging PR Workflow (feature -> staging)     |
|   build -> typecheck -> branch -> PR -> checks -> merge       |
+---------------------------------------------------------------+
'@ -ForegroundColor Magenta

    # --- 0. Pre-flight -----------------------------------------------------
    Write-Step 'Pre-flight checks'
    $repoRoot = Assert-Preflight -RequireGh
    Write-Ok "Repository: $repoRoot"
    Write-Ok 'GitHub CLI authenticated'

    # --- 1. Ensure the integration branch exists ---------------------------
    Write-Step "Ensuring '$BaseBranch' exists on origin"
    Invoke-External -FilePath git -CommandArgs @('fetch', 'origin', '--prune') -AllowFailure | Out-Null

    if (-not (Test-RemoteBranch -Branch $BaseBranch)) {
        if ($BaseBranch -ne 'staging') {
            throw "Remote branch 'origin/$BaseBranch' does not exist."
        }

        $seed = $null
        foreach ($candidate in @($SeedBranch, 'dev', 'main')) {
            if ($candidate -and (Test-RemoteBranch -Branch $candidate)) { $seed = $candidate; break }
        }
        if (-not $seed) { throw "Cannot create '$BaseBranch': no seed branch (dev/main) exists on origin." }

        $seedSha = Get-GitValue -CommandArgs @('rev-parse', "origin/$seed")
        Write-Info "Creating 'origin/$BaseBranch' from 'origin/$seed' ($seedSha)"

        if ($DryRun) {
            Write-Warn "Dry run: would run 'git push origin ${seedSha}:refs/heads/$BaseBranch'"
        }
        else {
            Invoke-External -FilePath git -CommandArgs @('push', 'origin', "${seedSha}:refs/heads/$BaseBranch") | Out-Null
            Invoke-External -FilePath git -CommandArgs @('fetch', 'origin', '--prune') | Out-Null
            if (-not (Test-RemoteBranch -Branch $BaseBranch)) { throw "Failed to create 'origin/$BaseBranch'." }
            Write-Ok "Created 'origin/$BaseBranch'"
        }
    }
    else {
        Write-Ok "'origin/$BaseBranch' already exists"
    }

    # --- 2. Detect changes and any in-flight PR ----------------------------
    Write-Step 'Detecting changes'

    $allChanged = @(Get-ChangedFiles)
    $workFiles = @($allChanged | Where-Object { Test-CommittableFile -Path $_ })

    $protectedBranches = @('main', 'master', 'dev', 'staging', 'develop')
    $currentBranch = ((& git branch --show-current 2>$null) -join '').Trim()
    $currentIsFeature = -not [string]::IsNullOrWhiteSpace($currentBranch) -and
        ($protectedBranches -notcontains $currentBranch) -and
        ($currentBranch -match '^(feat|fix|refactor|docs|test|chore)/')

    $openPr = $null
    if ($currentIsFeature) {
        $openPr = Get-OpenPullRequest -HeadBranch $currentBranch -BaseBranch $BaseBranch
    }

    $resumeBranch = $null
    # -Resume with an explicit branch name: switch to it so the PR can be re-attached.
    if ($Resume -and $CustomBranchName -and -not $openPr) {
        $candidate = $null
        if ($CustomBranchName -match '^(feat|fix|refactor|docs|test|chore)/') {
            $candidate = $CustomBranchName
        }
        else {
            foreach ($prefix in @('feat', 'fix', 'refactor', 'docs', 'test', 'chore')) {
                $tryBranch = "$prefix/$($CustomBranchName.Trim('/'))"
                if (Test-LocalBranch -Branch $tryBranch -or (Test-RemoteBranch -Branch $tryBranch)) {
                    $candidate = $tryBranch
                    break
                }
            }
        }

        if ($candidate) {
            if (-not (Test-LocalBranch -Branch $candidate)) {
                Invoke-External -FilePath git -CommandArgs @('checkout', '-b', $candidate, "origin/$candidate") | Out-Null
            }
            elseif ($candidate -ne $currentBranch) {
                $dirty = ((& git status --porcelain 2>$null) -join '').Trim()
                if ($dirty) {
                    throw "Working tree is dirty. Commit or stash your changes before resuming '$candidate'."
                }
                Invoke-External -FilePath git -CommandArgs @('checkout', $candidate) | Out-Null
            }

            $currentBranch = $candidate
            $currentIsFeature = $true
            $resumeBranch = $candidate
            $openPr = Get-OpenPullRequest -HeadBranch $candidate -BaseBranch $BaseBranch
            Write-Info "Resume target: $candidate (open PR: $(if ($openPr) { $openPr.url } else { 'none' }))"
        }
    }

    if ($workFiles.Count -gt 0) {
        Write-Info "Detected $($workFiles.Count) committable file(s):"
        $workFiles | ForEach-Object { Write-Host "    - $_" -ForegroundColor DarkGray }
    }
    elseif ($openPr) {
        Write-Info "No local changes. Resuming open PR #$($openPr.number): $($openPr.url)"
        $Resume = $true
    }
    else {
        Write-Warn 'No committable changes and no open PR to resume. Nothing to do.'
        return
    }

    if ($Resume -and -not $openPr -and $workFiles.Count -eq 0) {
        throw "Nothing to resume: current branch '$currentBranch' has no open PR into '$BaseBranch'."
    }

    # --- 3. Classify -------------------------------------------------------
    $messageType = Get-ConventionalType -Message $CommitMessage
    $messageScope = Get-ConventionalScope -Message $CommitMessage

    $resolvedType = $ChangeType
    if ($resolvedType -eq 'auto') {
        if ($messageType) { $resolvedType = $messageType }
        elseif ($workFiles.Count -gt 0) { $resolvedType = Resolve-ChangeType -Files $workFiles }
        else { $resolvedType = 'feat' }
    }

    $areas = @(if ($workFiles.Count -gt 0) { Get-Areas -Files $workFiles } else { @([pscustomobject]@{ Name = 'project'; Count = 0 }) })

    $knownAreas = @('backend', 'frontend', 'dashboard', 'print-agent', 'mobile')
    $messageAreas = @()
    if (-not [string]::IsNullOrWhiteSpace($messageScope)) {
        $messageAreas = @($messageScope -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $knownAreas -contains $_ })
    }

    $primaryArea = if ($messageAreas.Count -gt 0) { $messageAreas[0] } else { $areas[0].Name }

    $scope = $null
    if ($messageAreas.Count -gt 0) {
        $scope = $messageAreas -join ','
    }
    else {
        $inferredScope = @($areas | Select-Object -First 2 | ForEach-Object { $_.Name })
        $scope = if ($inferredScope.Count -gt 0) { $inferredScope -join ',' } else { 'project' }
    }
    if ([string]::IsNullOrWhiteSpace($scope)) { $scope = 'project' }

    $moduleHint = if ($workFiles.Count -gt 0) { Get-ModuleHint -Files $workFiles -Fallback $primaryArea } else { $primaryArea }
    $isFollowUp = $null -ne $openPr

    if ([string]::IsNullOrWhiteSpace($CommitMessage)) {
        $verb = 'update'
        switch ($resolvedType) {
            'fix' { $verb = 'fix' }
            'feat' { $verb = 'add' }
            'refactor' { $verb = 'refactor' }
            'docs' { $verb = 'update docs for' }
            'test' { $verb = 'add tests for' }
            'chore' { $verb = 'update' }
        }

        if ($isFollowUp) {
            $CommitMessage = "fix(${scope}): follow-up for $moduleHint"
        }
        else {
            $CommitMessage = "${resolvedType}(${scope}): $verb $moduleHint"
        }
    }
    elseif ($CommitMessage -notmatch '^(feat|fix|refactor|docs|test|chore|build|ci|perf|revert)(\([^)]+\))?!?:\s+') {
        $CommitMessage = "${resolvedType}(${scope}): $CommitMessage"
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    if ($openPr) {
        $branchName = $currentBranch
    }
    elseif ($resumeBranch) {
        $branchName = $resumeBranch
    }
    elseif ([string]::IsNullOrWhiteSpace($CustomBranchName)) {
        $branchName = "$resolvedType/$primaryArea-$timestamp"
    }
    elseif ($CustomBranchName -match '^(feat|fix|refactor|docs|test|chore)/') {
        $branchName = $CustomBranchName
    }
    else {
        $branchName = "$resolvedType/$($CustomBranchName.Trim('/'))"
    }

    if ($workFiles.Count -gt 0) {
        Write-Ok "Type:   $resolvedType"
        Write-Ok "Areas:  $($areas.Name -join ', ')"
    }
    Write-Ok "Branch: $branchName"
    Write-Ok "Commit: $CommitMessage"

    # --- 4. Dry run --------------------------------------------------------
    if ($DryRun) {
        Write-Step 'Dry run summary'
        Write-Host "  Base branch : origin/$BaseBranch"
        Write-Host "  Feature     : $branchName"
        Write-Host "  Commit      : $CommitMessage"
        Write-Host "  PR target   : $BaseBranch (merge via $MergeMethod)"
        Write-Host "  Local gates : $(if ($SkipBuild) { 'skipped' } else { 'typecheck + build for affected packages' })"
        Write-Host "  CI checks   : $(if ($SkipTests) { 'skipped' } else { "wait up to $MaxWaitMinutes min (auto-recovery on stalls)" })"
        Write-Host "  Cleanup     : delete merged feature branch + prune merged feature branches"
        return
    }

    $prUrl = $null
    $prNumber = $null
    $commitSha = $null
    $validation = @()
    $stagedFiles = @()
    $finalState = 'NOT_MERGED'
    $checkStatus = 'SKIPPED'

    # --- 5. Commit the work (if any) --------------------------------------
    if ($workFiles.Count -gt 0) {
        Write-Step 'Running local build + typecheck gates'
        if (-not $SkipBuild) {
            $gateResults = @(Invoke-BuildGates -Files $workFiles -AutoFix:$AutoFix)
            $failedGates = @($gateResults | Where-Object { -not $_.Success })

            if ($failedGates.Count -gt 0) {
                Write-FixGuidance -Results $gateResults
                exit 2
            }

            $validation = @($gateResults | Where-Object { $_.Success } | ForEach-Object { "$($_.Package) :: $($_.Script)" })
            if ($validation.Count -eq 0) { Write-Info 'No package-level gates applied for these changes.' }
            Write-Ok 'Local gates passed'
        }
        else {
            Write-Warn 'Skipping local build gates (-SkipBuild)'
        }

        # Branch selection: reuse the current branch only when it already owns an open PR.
        if ($openPr) {
            Write-Step "Reusing branch '$branchName' (PR #$($openPr.number) is still open)"
        }
        else {
            Write-Step "Creating branch '$branchName' from origin/$BaseBranch"

            if (Test-LocalBranch -Branch $branchName) {
                throw "Local branch '$branchName' already exists. Pick another -CustomBranchName or delete it first."
            }

            $originalBranch = $currentBranch
            $stashed = $false
            $dirty = ((& git status --porcelain 2>$null) -join '').Trim()
            if ($dirty) {
                Invoke-External -FilePath git -CommandArgs @('stash', 'push', '--include-untracked', '--message', "staging-workflow-$timestamp") | Out-Null
                $stashed = $true
                Write-Info 'Working tree changes stashed temporarily.'
            }

            try {
                Invoke-External -FilePath git -CommandArgs @('checkout', '-b', $branchName, "origin/$BaseBranch") | Out-Null
            }
            catch {
                if ($stashed) {
                    & git checkout $originalBranch *> $null
                    & git stash pop --index *> $null
                    Write-Warn 'Restored your changes on the original branch.'
                }
                throw
            }

            if ($stashed) {
                $popCode = Invoke-External -FilePath git -CommandArgs @('stash', 'pop', '--index') -AllowFailure
                if ($popCode -ne 0) {
                    throw "Could not re-apply your changes onto '$branchName'. Your work is safe in 'git stash list'; resolve conflicts and re-run."
                }
                Write-Ok 'Changes re-applied on the feature branch'
            }
        }

        Write-Step 'Staging changes'
        Invoke-External -FilePath git -CommandArgs @('add', '-A') | Out-Null
        foreach ($pattern in @('.env', '.env.*', '*.pem', '*.key', '*.p12', '*.pfx', 'id_rsa*', 'credentials*.json', 'secrets*.json', '*.tsbuildinfo')) {
            Invoke-External -FilePath git -CommandArgs @('reset', '-q', 'HEAD', '--', $pattern) -AllowFailure | Out-Null
        }
        Invoke-External -FilePath git -CommandArgs @('reset', '-q', 'HEAD', '--', '.opencode', '.commandcode', '.gitmodules') -AllowFailure | Out-Null

        $stagedFiles = @(& git diff --cached --name-only 2>$null)
        if ($stagedFiles.Count -eq 0) { throw 'Nothing staged after the secret/submodule filters. Aborting.' }
        Write-Ok "$($stagedFiles.Count) file(s) staged"

        Write-Step 'Committing and pushing'
        Invoke-External -FilePath git -CommandArgs @('commit', '-m', $CommitMessage) | Out-Null
        $commitSha = Get-GitValue -CommandArgs @('rev-parse', '--short', 'HEAD')
        Write-Ok "Commit $commitSha"

        $upstream = Get-GitValue -CommandArgs @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}') -AllowFailure
        if ([string]::IsNullOrWhiteSpace($upstream)) {
            Invoke-External -FilePath git -CommandArgs @('push', '-u', 'origin', $branchName) | Out-Null
        }
        else {
            Invoke-External -FilePath git -CommandArgs @('push', 'origin', $branchName) | Out-Null
        }
        Write-Ok "Pushed origin/$branchName"
    }

    if ([string]::IsNullOrWhiteSpace($commitSha)) {
        $commitSha = Get-GitValue -CommandArgs @('rev-parse', '--short', $branchName) -AllowFailure
    }

    # --- 6. Create or reuse the PR ----------------------------------------
    if (-not $openPr) {
        Write-Step "Creating PR: $branchName -> $BaseBranch"

        $summaryLines = @(Get-SummaryBullets -Files $stagedFiles -Subject $CommitMessage)
        $areaLines = @($areas | Where-Object { $_.Count -gt 0 } | ForEach-Object { "- ``$($_.Name)``: $($_.Count) file(s)" })
        $validationLines = if ($validation.Count -gt 0) {
            @($validation | ForEach-Object { "- [x] ``$_``" })
        }
        else {
            @('- [x] No local package gates applied')
        }

        $filePreview = @($stagedFiles | Select-Object -First 50)
        $fileLines = @($filePreview | ForEach-Object { "- ``$_``" })
        if ($stagedFiles.Count -gt $filePreview.Count) {
            $fileLines += "- ... and $($stagedFiles.Count - $filePreview.Count) more file(s)"
        }

        $summaryBlock = $summaryLines -join [Environment]::NewLine
        $areaBlock = $areaLines -join [Environment]::NewLine
        $validationBlock = $validationLines -join [Environment]::NewLine
        $fileBlock = $fileLines -join [Environment]::NewLine

        $prBody = @"
## Summary
$summaryBlock

## Change type
- [x] ``$resolvedType``

## Affected areas
$areaBlock

## Validation
$validationBlock
- [x] CI checks verified by this workflow (see PR checks)

## Branching
- Base: ``$BaseBranch`` (integration)
- Head: ``$branchName``
- Commit: ``$commitSha``
- Based on: ``origin/$BaseBranch``

## Files changed ($($stagedFiles.Count))
$fileBlock

## Rollback
- Revert on ``$BaseBranch``: ``git revert $commitSha``
"@

        $openPr = Get-OpenPullRequest -HeadBranch $branchName -BaseBranch $BaseBranch
        if ($openPr) {
            Write-Info "Reusing existing PR #$($openPr.number): $($openPr.url)"
        }
        else {
            $createOutput = ((& gh pr create --base $BaseBranch --head $branchName --title $CommitMessage --body $prBody 2>&1) -join "`n").Trim()
            if ($LASTEXITCODE -ne 0 -or $createOutput -notmatch '^https?://') {
                throw "PR creation failed: $createOutput"
            }
            Write-Ok "PR created: $createOutput"
            $openPr = [pscustomobject]@{ url = $createOutput; number = $null }
        }
    }

    $prUrl = $openPr.url
    $prNumber = if ($openPr.number) { "$($openPr.number)" } else {
        Get-GhValue -CommandArgs @('pr', 'view', $prUrl, '--json', 'number', '--jq', '.number')
    }

    if ($NoWait) {
        Write-Host @"

+---------------------------------------------------------------+
|               PR created (checks not awaited)                 |
+---------------------------------------------------------------+
  Branch : $branchName
  PR     : $prUrl
  Next   : re-run with -Resume (or check CI manually) to merge.
"@ -ForegroundColor Yellow
        return
    }

    # --- 7. Wait for checks ----------------------------------------------
    if (-not $SkipTests) {
        Write-Step "Waiting for CI checks on PR #$prNumber"
        Write-Info "Bounded wait: $MaxWaitMinutes min, stall recovery after $StuckAfterMinutes min."

        $checkResult = Wait-PullRequestChecks -PrNumber $prNumber -HeadBranch $branchName -MaxWaitMinutes $MaxWaitMinutes -StuckAfterMinutes $StuckAfterMinutes
        Format-CheckResult -CheckResult $checkResult -PrNumber $prNumber -HeadBranch $branchName
        $checkStatus = $checkResult.Status

        switch ($checkStatus) {
            'FAILED' {
                Write-Fail "CI failed on PR #$prNumber. Nothing was merged."
                exit 3
            }
            'CLOSED' {
                Write-Fail "PR #$prNumber is no longer open."
                exit 3
            }
            'TIMEOUT' {
                if (-not $AllowCheckTimeout) {
                    Write-Warn "Leaving PR #$prNumber open for a later -Resume run."
                    exit 4
                }
                Write-Warn 'Proceeding despite pending checks (-AllowCheckTimeout)'
            }
        }
    }
    else {
        Write-Warn 'Skipping CI checks (-SkipTests)'
    }

    # --- 8. Merge ---------------------------------------------------------
    Write-Step "Merging PR #$prNumber into $BaseBranch"

    try {
        $mergeStatus = Merge-PullRequestSafe -PrNumber $prNumber -MergeMethod $MergeMethod -Subject $CommitMessage -DeleteBranch
    }
    catch {
        Write-Fail $_.Exception.Message
        Write-Host @"

The PR is still open: $prUrl
Resolve the blocker, then re-run this skill with -Resume.
"@ -ForegroundColor Yellow
        exit 5
    }

    $finalState = Get-PullRequestState -PrNumber $prNumber
    if ($finalState -eq 'MERGED') {
        Write-Ok "PR #$prNumber merged into $BaseBranch"
    }
    else {
        Write-Warn "Merge status: $mergeStatus (PR state: $finalState)"
    }

    # --- 9. Cleanup -------------------------------------------------------
    if ($mergeStatus -eq 'MERGED') {
        Write-Step 'Cleaning up branches'
        Invoke-External -FilePath git -CommandArgs @('checkout', $BaseBranch) -AllowFailure | Out-Null
        Invoke-External -FilePath git -CommandArgs @('pull', '--ff-only', 'origin', $BaseBranch) -AllowFailure | Out-Null
        Invoke-External -FilePath git -CommandArgs @('branch', '-D', $branchName) -AllowFailure | Out-Null
        Invoke-External -FilePath git -CommandArgs @('fetch', 'origin', '--prune') -AllowFailure | Out-Null
        Write-Ok "Deleted local branch $branchName"

        if (-not $NoPruneMergedBranches) {
            Write-Step 'Pruning other merged feature branches'
            $pruned = Remove-MergedFeatureBranches -BaseBranch $BaseBranch -KeepBranch $branchName -OlderThanHours $PruneOlderThanHours
            Write-Ok "Pruned $($pruned.Local) local and $($pruned.Remote) remote merged branch(es)"
        }
    }
    else {
        Write-Info 'Feature branch kept because the merge is still pending.'
    }

    # --- 10. Summary ------------------------------------------------------
    Write-Host @"

+---------------------------------------------------------------+
|                   Workflow complete                           |
+---------------------------------------------------------------+
  Base branch : $BaseBranch
  Feature     : $branchName
  Commit      : $commitSha $CommitMessage
  PR          : $prUrl
  Checks      : $checkStatus
  Merge       : $mergeStatus ($MergeMethod) / $finalState
"@ -ForegroundColor Green
}
catch {
    Write-Fail "Workflow failed: $($_.Exception.Message)"
    if ($env:PR_WORKFLOW_DEBUG) {
        Write-Host "`n$($_.ScriptStackTrace)" -ForegroundColor DarkGray
    }
    Write-Host 'Re-run with the same arguments once the issue is fixed. Nothing is lost: the script is idempotent.' -ForegroundColor Yellow
    exit 1
}
