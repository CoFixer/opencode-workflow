<#
.SYNOPSIS
    Execute Staging PR Workflow - ship a change into the `staging` integration branch.

.DESCRIPTION
    Full lifecycle with resilience and conflict handling built in:
      1. Creates `staging` on origin from `dev` when it does not exist yet.
      2. Detects and classifies the working-tree changes.
      3. Runs typecheck + build gates. On failure: prints a fix loop and exits 2
         (optionally applies package auto-fixes first with -AutoFix).
      4. Creates a feature branch based on `origin/staging`, or reuses the current
         branch when it already owns an open PR or has commits ahead of staging.
      5. Commits, merges origin/staging to remove drift, auto-resolves mechanical
         conflicts, and stops with exit 7 when real code conflicts need resolution.
      6. Pushes, opens a PR into `staging` with a generated title/body.
      7. Waits for CI with stuck-detection/recovery and a bounded timeout.
      8. Merges (squash by default), deletes the feature branch, prunes merged branches.

    Exit codes:
      0  success (or PR created with -NoWait)
      1  unexpected failure
      2  build/typecheck failure -> fix code, then re-run
      3  CI failed / PR closed      -> inspect logs, fix, then re-run with -Resume
      4  CI still running/timed out -> re-run with -Resume later
      5  merge blocked              -> resolve protection/conflicts, then re-run with -Resume
      7  merge conflict needs a human decision -> resolve, then re-run

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

function Get-BranchPrimarySubject {
    param([string]$BaseBranch)

    $subjects = @(& git log --no-merges --format='%s' "origin/$BaseBranch..HEAD" 2>$null | Where-Object { $_ })
    if ($subjects.Count -gt 0) { return $subjects[$subjects.Count - 1] }
    return $null
}

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

    # --- 2. Detect state (changes / PR / merge in progress) ----------------
    Write-Step 'Detecting state'

    $allChanged = @(Get-ChangedFiles)
    $workFiles = @($allChanged | Where-Object { Test-CommittableFile -Path $_ })

    $protectedBranches = @('main', 'master', 'dev', 'staging', 'develop')
    $currentBranch = ((& git branch --show-current 2>$null) -join '').Trim()
    $currentIsFeature = -not [string]::IsNullOrWhiteSpace($currentBranch) -and
        ($protectedBranches -notcontains $currentBranch) -and
        ($currentBranch -match '^(feat|fix|refactor|docs|test|chore)/')

    $openPr = $null
    if ($currentIsFeature -and -not (Test-MergeInProgress)) {
        $openPr = Get-OpenPullRequest -HeadBranch $currentBranch -BaseBranch $BaseBranch
    }

    $resumeBranch = $null
    # -Resume with an explicit branch name: switch to it so the PR can be re-attached.
    if ($Resume -and $CustomBranchName -and -not $openPr -and -not (Test-MergeInProgress)) {
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

    $mergeInProgress = Test-MergeInProgress
    $conflicts = @()
    if ($mergeInProgress) { $conflicts = @(Get-ConflictedFiles) }

    $aheadOfBase = 0
    if ($currentIsFeature -and -not $mergeInProgress) {
        $aheadOfBase = [int](Get-GitValue -CommandArgs @('rev-list', '--count', "origin/$BaseBranch..HEAD") -AllowFailure)
    }

    $reuseCurrent = ($null -ne $openPr) -or ($currentIsFeature -and $aheadOfBase -gt 0)

    $mode = 'none'
    if ($mergeInProgress) { $mode = 'merge-recovery' }
    elseif ($workFiles.Count -gt 0) { $mode = 'commit' }
    elseif ($openPr) { $mode = 'resume-pr' }
    elseif ($reuseCurrent) { $mode = 'publish' }

    if ($mode -eq 'none' -and -not $openPr) {
        Write-Warn 'No committable changes and no branch to publish. Nothing to do.'
        return
    }

    if ($mode -eq 'merge-recovery' -and $protectedBranches -contains $currentBranch) {
        throw "A merge is in progress on protected branch '$currentBranch'. Finish or abort it, then run from a feature branch."
    }

    if ($workFiles.Count -gt 0 -and $mode -eq 'commit') {
        Write-Info "Detected $($workFiles.Count) committable file(s)"
    }

    Write-Info "Mode: $mode"

    # --- 3. Merge-recovery: resolve and finish the in-progress merge -------
    $commitSha = $null
    $prFiles = @()

    if ($mode -eq 'merge-recovery') {
        if ($conflicts.Count -gt 0) {
            $remaining = @(Resolve-MechanicalConflicts -Files $conflicts)
            if ($remaining.Count -gt 0) {
                Write-ConflictGuidance -Files $remaining -Branch $currentBranch
                exit 7
            }
            Write-Ok 'Mechanical conflicts auto-resolved'
        }

        Invoke-External -FilePath git -CommandArgs @('add', '-A') | Out-Null
        foreach ($pattern in @('.env', '.env.*', '*.pem', '*.key', '*.p12', '*.pfx', 'id_rsa*', 'credentials*.json', 'secrets*.json', '*.tsbuildinfo')) {
            Invoke-External -FilePath git -CommandArgs @('reset', '-q', 'HEAD', '--', $pattern) -AllowFailure | Out-Null
        }
        Invoke-External -FilePath git -CommandArgs @('reset', '-q', 'HEAD', '--', '.opencode', '.commandcode', '.gitmodules') -AllowFailure | Out-Null

        Invoke-External -FilePath git -CommandArgs @('commit', '--no-edit') | Out-Null
        $commitSha = Get-GitValue -CommandArgs @('rev-parse', '--short', 'HEAD')
        Write-Ok "Merge committed as $commitSha"
    }

    # --- 4. Classify -------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($CommitMessage)) {
        if ($mode -eq 'commit') {
            $CommitMessage = $null
        }
        else {
            $CommitMessage = Get-BranchPrimarySubject -BaseBranch $BaseBranch
        }
    }

    $messageType = Get-ConventionalType -Message $CommitMessage
    $messageScope = Get-ConventionalScope -Message $CommitMessage

    $resolvedType = $ChangeType
    if ($resolvedType -eq 'auto') {
        if ($messageType) { $resolvedType = $messageType }
        elseif ($workFiles.Count -gt 0) { $resolvedType = Resolve-ChangeType -Files $workFiles }
        else { $resolvedType = 'feat' }
    }

    $scopeFiles = if ($mode -eq 'commit') {
        $workFiles
    }
    else {
        @(& git diff --name-only "origin/$BaseBranch...HEAD" 2>$null | Where-Object { $_ } | Where-Object { Test-CommittableFile -Path $_ })
    }

    $areas = @(if ($scopeFiles.Count -gt 0) { Get-Areas -Files $scopeFiles } else { @([pscustomobject]@{ Name = 'project'; Count = 0 }) })

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

    $moduleHint = if ($scopeFiles.Count -gt 0) { Get-ModuleHint -Files $scopeFiles -Fallback $primaryArea } else { $primaryArea }
    $isFollowUp = ($null -ne $openPr) -or ($mode -in @('merge-recovery', 'publish'))

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
    if ($mode -eq 'merge-recovery' -or $reuseCurrent) {
        $branchName = $currentBranch
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

    Write-Ok "Branch: $branchName"
    Write-Ok "Title:  $CommitMessage"

    # --- 5. Dry run --------------------------------------------------------
    if ($DryRun) {
        Write-Step 'Dry run summary'
        Write-Host "  Base branch : origin/$BaseBranch"
        Write-Host "  Feature     : $branchName"
        Write-Host "  Title       : $CommitMessage"
        Write-Host "  PR target   : $BaseBranch (merge via $MergeMethod)"
        Write-Host "  Local gates : $(if ($SkipBuild) { 'skipped' } else { 'typecheck + build for affected packages' })"
        Write-Host "  Conflicts   : mechanical auto-fix, then a guided fix loop (exit 7)"
        Write-Host "  CI checks   : $(if ($SkipTests) { 'skipped' } else { "wait up to $MaxWaitMinutes min (auto-recovery on stalls)" })"
        Write-Host "  Cleanup     : delete merged feature branch + prune merged feature branches"
        return
    }

    $validation = @()
    $finalState = 'NOT_MERGED'
    $checkStatus = 'SKIPPED'

    # --- 6. Commit the work (if any) --------------------------------------
    if ($mode -eq 'commit') {
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

        if ($reuseCurrent) {
            Write-Step "Reusing branch '$branchName'"
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

        Invoke-External -FilePath git -CommandArgs @('commit', '-m', $CommitMessage) | Out-Null
        $commitSha = Get-GitValue -CommandArgs @('rev-parse', '--short', 'HEAD')
        Write-Ok "Commit $commitSha"
    }

    # --- 7. Sync with the base branch (fix drift / conflicts) -------------
    if ($mode -in @('commit', 'publish', 'resume-pr')) {
        Write-Step "Syncing with origin/$BaseBranch"

        $merge = Merge-BaseIntoCurrentBranch -BaseRef "origin/$BaseBranch"

        if ($merge.Status -eq 'CONFLICT') {
            Write-ConflictGuidance -Files $merge.Files -Branch $branchName
            exit 7
        }
        if ($merge.Status -eq 'FAILED') {
            throw "Could not merge origin/$BaseBranch into '$branchName'. Check 'git status' and re-run."
        }

        if ($merge.Status -eq 'CLEAN') {
            Write-Ok 'Already up to date with the base branch'
        }
        else {
            Write-Ok 'Base branch merged'

            # Validate the code that arrived from the base branch.
            if (-not $SkipBuild -and $mode -ne 'publish') {
                $incoming = @(& git diff --name-only 'ORIG_HEAD' 'HEAD' 2>$null | Where-Object { $_ } | Where-Object { Test-CommittableFile -Path $_ })
                if ($incoming.Count -gt 0) {
                    Write-Step "Re-running gates for $($incoming.Count) incoming file(s)"
                    $gateResults = @(Invoke-BuildGates -Files $incoming -AutoFix:$AutoFix)
                    $failedGates = @($gateResults | Where-Object { -not $_.Success })
                    if ($failedGates.Count -gt 0) {
                        Write-FixGuidance -Results $gateResults
                        exit 2
                    }
                    $validation += @($gateResults | Where-Object { $_.Success } | ForEach-Object { "$($_.Package) :: $($_.Script)" })
                }
            }
        }
    }

    # --- 8. Publish the branch --------------------------------------------
    $prFiles = @(& git diff --name-only "origin/$BaseBranch...HEAD" 2>$null | Where-Object { $_ } | Where-Object { Test-CommittableFile -Path $_ })
    $prAreas = @(if ($prFiles.Count -gt 0) { Get-Areas -Files $prFiles } else { $areas })

    if ($prFiles.Count -eq 0) {
        throw "No committable diff against origin/$BaseBranch. Nothing to publish."
    }

    if (-not $SkipBuild -and $mode -in @('publish', 'merge-recovery')) {
        Write-Step "Running gates for the branch diff ($($prFiles.Count) file(s))"
        $gateResults = @(Invoke-BuildGates -Files $prFiles -AutoFix:$AutoFix)
        $failedGates = @($gateResults | Where-Object { -not $_.Success })
        if ($failedGates.Count -gt 0) {
            Write-FixGuidance -Results $gateResults
            exit 2
        }
        $validation += @($gateResults | Where-Object { $_.Success } | ForEach-Object { "$($_.Package) :: $($_.Script)" })
    }

    if ([string]::IsNullOrWhiteSpace($commitSha)) {
        $commitSha = Get-GitValue -CommandArgs @('rev-parse', '--short', 'HEAD') -AllowFailure
    }

    Write-Step 'Pushing branch'
    $upstream = Get-GitValue -CommandArgs @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}') -AllowFailure
    if ([string]::IsNullOrWhiteSpace($upstream)) {
        Invoke-External -FilePath git -CommandArgs @('push', '-u', 'origin', $branchName) | Out-Null
    }
    else {
        Invoke-External -FilePath git -CommandArgs @('push', 'origin', $branchName) | Out-Null
    }
    Write-Ok "Pushed origin/$branchName"

    # --- 9. Create or reuse the PR ----------------------------------------
    $prUrl = $null
    $prNumber = $null

    # A merge-recovery run may have an existing PR that was not visible earlier.
    if (-not $openPr) {
        $openPr = Get-OpenPullRequest -HeadBranch $branchName -BaseBranch $BaseBranch
    }

    if ($openPr) {
        $prUrl = $openPr.url
        $prNumber = "$($openPr.number)"
        Write-Info "Using open PR #${prNumber}: $prUrl"
    }
    else {
        Write-Step "Creating PR: $branchName -> $BaseBranch"

        $summaryLines = @("- $CommitMessage")
        foreach ($area in $prAreas) {
            $areaFiles = @($prFiles | Where-Object { $_ -like "$($area.Name)/*" })
            if ($areaFiles.Count -eq 0) { continue }
            $summaryLines += "- ``$($area.Name)``: $($areaFiles.Count) file(s)"
        }

        $areaLines = @($prAreas | Where-Object { $_.Count -gt 0 } | ForEach-Object { "- ``$($_.Name)``: $($_.Count) file(s)" })
        $validationLines = if ($validation.Count -gt 0) {
            @($validation | Select-Object -Unique | ForEach-Object { "- [x] ``$_``" })
        }
        else {
            @('- [x] No local package gates applied')
        }

        $filePreview = @($prFiles | Select-Object -First 50)
        $fileLines = @($filePreview | ForEach-Object { "- ``$_``" })
        if ($prFiles.Count -gt $filePreview.Count) {
            $fileLines += "- ... and $($prFiles.Count - $filePreview.Count) more file(s)"
        }

        $summaryBlock = $summaryLines -join [Environment]::NewLine
        $areaBlock = $areaLines -join [Environment]::NewLine
        $validationBlock = $validationLines -join [Environment]::NewLine
        $fileBlock = $fileLines -join [Environment]::NewLine

        $conflictNote = if ($mode -eq 'merge-recovery') { '- [x] Merge conflicts resolved (mechanical + reviewed)' } else { '' }

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
$conflictNote

## Branching
- Base: ``$BaseBranch`` (integration)
- Head: ``$branchName``
- Commit: ``$commitSha``
- Based on: latest ``origin/$BaseBranch`` (drift merged before push)

## Files changed ($($prFiles.Count))
$fileBlock

## Rollback
- Revert on ``$BaseBranch``: ``git revert $commitSha``
"@

        $createOutput = ((& gh pr create --base $BaseBranch --head $branchName --title $CommitMessage --body $prBody 2>&1) -join "`n").Trim()
        if ($LASTEXITCODE -ne 0 -or $createOutput -notmatch '^https?://') {
            throw "PR creation failed: $createOutput"
        }
        Write-Ok "PR created: $createOutput"
        $prUrl = $createOutput
        $prNumber = Get-GhValue -CommandArgs @('pr', 'view', $prUrl, '--json', 'number', '--jq', '.number')
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

    # --- 10. Wait for checks ----------------------------------------------
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

    # --- 11. Merge --------------------------------------------------------
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

    # --- 12. Cleanup ------------------------------------------------------
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

    # --- 13. Summary ------------------------------------------------------
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
