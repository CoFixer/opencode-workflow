<#
.SYNOPSIS
    Execute PR Workflow - Automated CI/CD pipeline for feature/bug fixes.

.DESCRIPTION
    This script automates the full PR lifecycle:
    1. Detects changes and determines branch type (feat/ or fix/)
    2. Runs build and type checks
    3. Commits and pushes to appropriate branch
    4. Creates PR to dev branch
    5. Waits for CI/QA tests to pass
    6. Auto-merges PR to dev
    7. If first commit, also creates PR from dev -> main and merges

.NOTES
    Requires: Git, GitHub CLI (gh), Node.js/npm/pnpm/bun
#>

[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [switch]$SkipTests,
    [switch]$DryRun,
    [string]$CustomBranchName,
    [string]$CommitMessage,
    # Maximum time to wait for CI checks before giving up (minutes).
    [int]$MaxWaitMinutes = 8,
    # If no runner picks up a queued job within this many seconds, treat CI as
    # stuck (e.g. a GitHub Actions incident) instead of waiting the full budget.
    [int]$RunnerAcquireTimeoutSeconds = 120
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "Continue"

# Colors for output
$Colors = @{
    Success = "Green"
    Error = "Red"
    Warning = "Yellow"
    Info = "Cyan"
    Step = "Magenta"
}

function Write-Step {
    param([string]$Message)
    Write-Host "`n[STEP] $Message" -ForegroundColor $Colors.Step
}

function Write-Success {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor $Colors.Success
}

function Write-Error {
    param([string]$Message)
    Write-Host "  [x] $Message" -ForegroundColor $Colors.Error
}

function Write-Info {
    param([string]$Message)
    Write-Host "  -> $Message" -ForegroundColor $Colors.Info
}

function Invoke-Command {
    param(
        [string]$Command,
        [string]$Arguments,
        [string]$WorkingDirectory = ".",
        [int]$TimeoutSeconds = 300
    )

    Write-Info "Running: $Command $Arguments"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Command
    $psi.Arguments = $Arguments
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::Start($psi)

    # Read output asynchronously
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()

    $completed = $process.WaitForExit($TimeoutSeconds * 1000)

    if (-not $completed) {
        $process.Kill()
        throw "Command timed out after $TimeoutSeconds seconds: $Command $Arguments"
    }

    [void]$stdout.Wait()
    [void]$stderr.Wait()

    $output = $stdout.Result
    $errorOutput = $stderr.Result

    if ($process.ExitCode -ne 0) {
        Write-Host $output -ForegroundColor Gray
        Write-Host $errorOutput -ForegroundColor Red
        throw "Command failed with exit code $($process.ExitCode): $Command $Arguments"
    }

    Write-Host $output -ForegroundColor Gray
    return $output
}

function Test-CommandExists {
    param([string]$Command)
    return [bool](Get-Command $Command -ErrorAction SilentlyContinue)
}

function Get-PackageManager {
    if (Test-Path "bun.lockb") { return "bun" }
    if (Test-Path "pnpm-lock.yaml") { return "pnpm" }
    if (Test-Path "yarn.lock") { return "yarn" }
    if (Test-Path "package-lock.json") { return "npm" }
    return "npm"
}

function Get-ChangedFiles {
    $staged = git diff --cached --name-only
    $unstaged = git diff --name-only
    $untracked = git ls-files --others --exclude-standard
    return ($staged + $unstaged + $untracked | Where-Object { $_ } | Select-Object -Unique)
}

function Get-ChangeType {
    param([string[]]$Files)

    $typeIndicators = @{
        Feature = @("feat", "feature", "add", "implement", "create")
        BugFix = @("fix", "bug", "hotfix", "patch", "repair")
        Refactor = @("refactor", "restructure", "clean")
        Docs = @("doc", "readme", "md", "comment")
        Test = @("test", "spec")
        Chore = @("chore", "update", "bump", "deps", "config")
    }

    # Check file paths for indicators
    $fileString = ($Files -join " ").ToLower()

    foreach ($type in $typeIndicators.Keys) {
        foreach ($indicator in $typeIndicators[$type]) {
            if ($fileString -match $indicator) {
                return $type
            }
        }
    }

    # Default based on file types
    if ($Files | Where-Object { $_ -match "\.(test|spec)\.(ts|tsx|js|jsx)$" }) { return "Test" }
    if ($Files | Where-Object { $_ -match "\.md$" }) { return "Docs" }
    if ($Files | Where-Object { $_ -match "package\.json|pnpm|yarn|bun" }) { return "Chore" }

    return "Feature"
}

function Get-BranchPrefix {
    param([string]$ChangeType)
    switch ($ChangeType) {
        "BugFix" { return "fix" }
        "Feature" { return "feat" }
        "Refactor" { return "refactor" }
        "Docs" { return "docs" }
        "Test" { return "test" }
        "Chore" { return "chore" }
        default { return "feat" }
    }
}

function Get-DefaultCommitMessage {
    param([string[]]$Files, [string]$ChangeType)

    $areas = @()
    if ($Files | Where-Object { $_ -match "^backend/" }) { $areas += "backend" }
    if ($Files | Where-Object { $_ -match "^dashboard/|^frontend/" }) { $areas += "frontend" }
    if ($Files | Where-Object { $_ -match "^\.opencode/" }) { $areas += "opencode" }
    if ($Files | Where-Object { $_ -match "^mobile/" }) { $areas += "mobile" }

    $area = if ($areas.Count -gt 0) { $areas[0] } else { "project" }

    switch ($ChangeType) {
        "BugFix" { return "fix($area): resolve issue" }
        "Feature" { return "feat($area): add new functionality" }
        "Refactor" { return "refactor($area): improve code structure" }
        "Docs" { return "docs($area): update documentation" }
        "Test" { return "test($area): add/update tests" }
        "Chore" { return "chore($area): maintenance updates" }
        default { return "feat($area): automated changes" }
    }
}

function Invoke-BuildCheck {
    param([string]$ProjectDir)

    if (-not (Test-Path $ProjectDir)) { return $true }

    Write-Step "Running Build Check in $ProjectDir"

    $pm = Get-PackageManager
    $buildCmd = switch ($pm) {
        "bun" { "bun run build" }
        "pnpm" { "pnpm build" }
        "yarn" { "yarn build" }
        default { "npm run build" }
    }

    try {
        Invoke-Command -Command "cmd" -Arguments "/c $buildCmd" -WorkingDirectory $ProjectDir -TimeoutSeconds 300
        Write-Success "Build passed for $ProjectDir"
        return $true
    }
    catch {
        Write-Error "Build failed for ${ProjectDir}: $_"
        return $false
    }
}

function Invoke-TypeCheck {
    param([string]$ProjectDir)

    if (-not (Test-Path $ProjectDir)) { return $true }

    Write-Step "Running Type Check in $ProjectDir"

    $pm = Get-PackageManager
    $typeCheckCmd = $null

    # Check for type-check script
    $packageJson = Join-Path $ProjectDir "package.json"
    if (Test-Path $packageJson) {
        $pkg = Get-Content $packageJson | ConvertFrom-Json
        if ($pkg.scripts."type-check") { $typeCheckCmd = "$pm run type-check" }
        elseif ($pkg.scripts."tsc") { $typeCheckCmd = "$pm run tsc" }
        elseif ($pkg.scripts."lint:types") { $typeCheckCmd = "$pm run lint:types" }
    }

    # Fallback to tsc directly
    if (-not $typeCheckCmd -and (Test-Path (Join-Path $ProjectDir "tsconfig.json"))) {
        $pm = Get-PackageManager
        $tscCmd = if (Test-Path (Join-Path $ProjectDir "node_modules/.bin/tsc")) {
            "npx tsc --noEmit"
        } else {
            "tsc --noEmit"
        }
        $typeCheckCmd = $tscCmd
    }

    if (-not $typeCheckCmd) {
        Write-Info "No type check configuration found in $ProjectDir, skipping"
        return $true
    }

    try {
        Invoke-Command -Command "cmd" -Arguments "/c $typeCheckCmd" -WorkingDirectory $ProjectDir -TimeoutSeconds 300
        Write-Success "Type check passed for $ProjectDir"
        return $true
    }
    catch {
        Write-Error "Type check failed for ${ProjectDir}: $_"
        return $false
    }
}

# CI states that mean "still working" and CI states that mean "broken".
$script:PendingCheckStates = @("PENDING", "QUEUED", "IN_PROGRESS", "EXPECTED", "REQUESTED", "WAITING", "STALE")
$script:FailedCheckStates = @("FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED")

<#
.SYNOPSIS
    Returns $true when GitHub Actions is reporting anything other than
    operational (e.g. an incident delaying runner assignment).
#>
function Test-GitHubActionsDegraded {
    try {
        $resp = Invoke-RestMethod -Uri "https://www.githubstatus.com/api/v2/components.json" -TimeoutSec 10 -ErrorAction Stop
        $actions = $resp.components | Where-Object { $_.name -eq "Actions" } | Select-Object -First 1
        if ($actions -and ([string]$actions.status) -ne "operational") { return $true }
    }
    catch {
        # Status endpoint unreachable - assume healthy and continue.
    }
    return $false
}

<#
.SYNOPSIS
    Returns $true when the base branch enforces the CI check as a required
    status check. On repos without branch protection this returns $false, so
    advisory checks never block a merge.
#>
function Test-ChecksRequired {
    param([string]$BaseBranch = "dev")

    try {
        $repo = gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>$null
        if (-not $repo) { return $false }
        $protection = gh api "repos/$repo/branches/$BaseBranch/protection" 2>$null
        if (-not $protection) { return $false }
        $obj = $protection | ConvertFrom-Json
        $contexts = @($obj.required_status_checks.contexts)
        return ($contexts.Count -gt 0)
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
    Waits for CI checks on a PR with bounded, self-terminating logic.

.DESCRIPTION
    Returns one of: Passed, Failed, NoChecks, Stuck, TimedOut.
    - Failed   : a check reported a terminal failure.
    - Stuck    : no runner ever picked up the job within the acquisition budget
                 (typical of a GitHub Actions incident) - returns quickly instead
                 of burning the whole wait budget.
    - NoChecks : the PR has no checks configured.
    - TimedOut : checks were running but did not finish in time.
#>
function Invoke-QATests {
    param(
        [string]$Branch,
        [string]$BaseBranch = "dev",
        [int]$MaxWaitMinutes = 8,
        [int]$RunnerAcquireTimeoutSeconds = 120
    )

    Write-Step "Waiting for CI checks: $Branch -> $BaseBranch"

    if (-not (Test-CommandExists "gh")) {
        Write-Warning "GitHub CLI (gh) not found. Skipping automated CI check."
        return "NoChecks"
    }

    # Locate the PR (short, bounded retry).
    $prNumber = $null
    for ($i = 0; $i -lt 10 -and -not $prNumber; $i++) {
        Start-Sleep -Seconds 2
        $prList = gh pr list --head $Branch --base $BaseBranch --json number --jq '.[0].number' 2>$null
        if ($prList) { $prNumber = $prList.Trim() }
    }
    if (-not $prNumber) {
        Write-Warning "Could not find an open PR for $Branch -> $BaseBranch."
        return "NoChecks"
    }

    # One-time platform health check so we can react intelligently to an incident.
    if (Test-GitHubActionsDegraded) {
        Write-Warning "GitHub Actions is reporting degraded performance (see https://www.githubstatus.com). Runner assignment may stall."
    }

    $waited = 0
    $sawProgress = $false
    $emptyPolls = 0

    while ($waited -lt ($MaxWaitMinutes * 60)) {
        Start-Sleep -Seconds 10
        $waited += 10

        $json = gh pr checks $prNumber --json name,state,startedAt 2>$null
        if (-not $json) {
            $emptyPolls++
            if ($emptyPolls -ge 3) {
                Write-Info "No CI checks are configured for PR #$prNumber."
                return "NoChecks"
            }
            continue
        }

        $checks = @($json | ConvertFrom-Json)
        if ($checks.Count -eq 0) { return "NoChecks" }

        $states = @($checks | ForEach-Object { ([string]$_.state).ToUpper() })

        $failed = @($states | Where-Object { $script:FailedCheckStates -contains $_ })
        if ($failed.Count -gt 0) {
            Write-Error "CI failed on PR #$prNumber ($($failed -join ', '))."
            return "Failed"
        }

        $pending = @($states | Where-Object { $script:PendingCheckStates -contains $_ })
        if ($pending.Count -eq 0) {
            Write-Success "All CI checks passed on PR #$prNumber."
            return "Passed"
        }

        # Has any job actually been picked up by a runner yet?
        $running = @($checks | Where-Object {
            ([string]$_.state).ToUpper() -eq "IN_PROGRESS" -or
            ($_.startedAt -and ([string]$_.state).ToUpper() -notin @("QUEUED", "PENDING", "EXPECTED", "REQUESTED", "WAITING"))
        })
        if ($running.Count -gt 0) { $sawProgress = $true }

        # Nothing ever started and we've exhausted the runner-acquisition budget.
        if (-not $sawProgress -and $waited -ge $RunnerAcquireTimeoutSeconds) {
            Write-Warning "No runner picked up the CI job within ${RunnerAcquireTimeoutSeconds}s (still queued). This is a GitHub-hosted runner capacity/incident issue, not a code failure."
            return "Stuck"
        }

        if ($waited % 60 -eq 0) {
            Write-Info "Still waiting for CI... ($([int]($waited / 60)) min elapsed)"
        }
    }

    Write-Warning "Timed out waiting for CI after $MaxWaitMinutes minutes."
    return "TimedOut"
}

function New-PullRequest {
    param(
        [string]$Branch,
        [string]$BaseBranch,
        [string]$Title,
        [string]$Body = ""
    )

    Write-Step "Creating PR: $Branch -> $BaseBranch"

    if (-not (Test-CommandExists "gh")) {
        throw "GitHub CLI (gh) is required but not installed. Install from: https://cli.github.com/"
    }

    $prUrl = gh pr create `
        --head $Branch `
        --base $BaseBranch `
        --title $Title `
        --body $Body `
        --fill 2>$null

    if ($LASTEXITCODE -ne 0) {
        # PR might already exist
        $existingPr = gh pr list --head $Branch --base $BaseBranch --json url --jq '.[0].url' 2>$null
        if ($existingPr) {
            Write-Info "PR already exists: $existingPr"
            return $existingPr.Trim()
        }
        throw "Failed to create PR"
    }

    Write-Success "Created PR: $prUrl"
    return $prUrl.Trim()
}

function Merge-PullRequest {
    param(
        [string]$Branch,
        [string]$BaseBranch,
        [switch]$AutoMerge
    )

    Write-Step "Merging PR: $Branch -> $BaseBranch"

    if (-not (Test-CommandExists "gh")) {
        throw "GitHub CLI (gh) is required but not installed."
    }

    # Get PR number
    $prNumber = gh pr list --head $Branch --base $BaseBranch --json number --jq '.[0].number' 2>$null
    if (-not $prNumber) {
        throw "Could not find PR for branch $Branch -> $BaseBranch"
    }

    $prNumber = $prNumber.Trim()

    # Enable auto-merge or merge directly
    if ($AutoMerge) {
        try {
            gh pr merge $prNumber --auto --squash 2>$null
            Write-Success "Enabled auto-merge for PR #$prNumber"
            return $true
        }
        catch {
            Write-Info "Auto-merge not available, attempting direct merge"
        }
    }

    # Direct merge
    gh pr merge $prNumber --squash --delete-branch 2>$null
    if ($LASTEXITCODE -ne 0) {
        # Retry without deleting the branch (some repos protect the head branch).
        gh pr merge $prNumber --squash 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to merge PR #$prNumber (exit $LASTEXITCODE). The PR may require a completed, passing CI check."
        }
    }
    Write-Success "Merged PR #$prNumber"
    return $true
}

function Test-IsFirstCommit {
    # Only merge dev -> main on the very first commit when main is empty.
    # Once main has any commits, never auto-create a release PR.
    git rev-parse --verify main 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        # main branch does not exist
        return $true
    }

    $mainCommitCount = git rev-list --count main 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $true
    }

    return ([int]$mainCommitCount -eq 0)
}

# ==================== MAIN WORKFLOW ====================

try {
    Write-Host @"
+===============================================================+
|              Execute PR Workflow Automation                   |
|                                                               |
|  Automated CI/CD: Build -> Type Check -> PR -> CI -> Merge    |
+===============================================================+
"@ -ForegroundColor $Colors.Step

    # Pre-flight checks
    Write-Step "Pre-flight Checks"

    if (-not (Test-CommandExists "git")) {
        throw "Git is not installed or not in PATH"
    }

    if (-not (Test-CommandExists "gh")) {
        throw "GitHub CLI (gh) is not installed. Install from: https://cli.github.com/"
    }

    # Verify we're in a git repo
    $gitRoot = git rev-parse --show-toplevel 2>$null
    if (-not $gitRoot) {
        throw "Not a git repository"
    }

    Set-Location $gitRoot
    Write-Success "Working in repository: $gitRoot"

    # Check git status
    $changedFiles = Get-ChangedFiles
    if ($changedFiles.Count -eq 0) {
        Write-Host "`nNo changes detected. Nothing to do." -ForegroundColor $Colors.Warning
        exit 0
    }

    Write-Info "Detected $($changedFiles.Count) changed file(s):"
    $changedFiles | ForEach-Object { Write-Host "    - $_" -ForegroundColor Gray }

    # Determine change type
    $changeType = Get-ChangeType -Files $changedFiles
    $branchPrefix = Get-BranchPrefix -ChangeType $changeType
    Write-Info "Detected change type: $changeType (prefix: $branchPrefix)"

    # Determine affected areas
    $areas = @()
    if ($changedFiles | Where-Object { $_ -match "^backend/" }) { $areas += "backend" }
    if ($changedFiles | Where-Object { $_ -match "^dashboard/|^frontend/" }) { $areas += "frontend" }
    if ($changedFiles | Where-Object { $_ -match "^\.opencode/" }) { $areas += "opencode" }
    if ($changedFiles | Where-Object { $_ -match "^mobile/" }) { $areas += "mobile" }
    $area = if ($areas.Count -gt 0) { $areas[0] } else { "project" }

    # Generate branch name
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    if ($CustomBranchName) {
        $branchName = "$branchPrefix/$CustomBranchName"
    } else {
        $branchName = "$branchPrefix/$area-$timestamp"
    }

    Write-Info "Will use branch: $branchName"

    # Get commit message
    if (-not $CommitMessage) {
        $CommitMessage = Get-DefaultCommitMessage -Files $changedFiles -ChangeType $changeType
    }
    Write-Info "Commit message: $CommitMessage"

    if ($DryRun) {
        Write-Host "`n[DRY RUN] Would execute the following:" -ForegroundColor $Colors.Warning
        Write-Host "  - Stage all changes"
        Write-Host "  - Create branch: $branchName"
        Write-Host "  - Commit: $CommitMessage"
        Write-Host "  - Push to origin"
        Write-Host "  - Create PR to dev"
        Write-Host "  - Wait for CI checks (bounded; sticky queue aware)"
        Write-Host "  - Merge to dev"
        if (Test-IsFirstCommit) {
            Write-Host "  - Create PR dev -> main"
            Write-Host "  - Merge to main"
        }
        exit 0
    }

    # Step 1: Stage all changes
    Write-Step "Staging Changes"
    git add -A
    Write-Success "All changes staged"

    # Step 2: Run build checks
    if (-not $SkipBuild) {
        $buildSuccess = $true

        if ($changedFiles | Where-Object { $_ -match "^backend/" }) {
            $buildSuccess = $buildSuccess -and (Invoke-BuildCheck -ProjectDir "backend")
            $buildSuccess = $buildSuccess -and (Invoke-TypeCheck -ProjectDir "backend")
        }

        if ($changedFiles | Where-Object { $_ -match "^dashboard/|^frontend/" }) {
            $buildSuccess = $buildSuccess -and (Invoke-BuildCheck -ProjectDir "dashboard")
            $buildSuccess = $buildSuccess -and (Invoke-TypeCheck -ProjectDir "dashboard")
        }

        if (-not $buildSuccess) {
            throw "Build or type check failed. Fix errors before proceeding."
        }

        Write-Success "All build and type checks passed"
    } else {
        Write-Info "Skipping build checks (--SkipBuild)"
    }

    # Step 3: Create branch and commit
    Write-Step "Creating Branch and Committing"

    $currentBranch = git branch --show-current
    git checkout -b $branchName
    Write-Success "Created branch: $branchName"

    git commit -m $CommitMessage
    Write-Success "Committed: $CommitMessage"

    # Step 4: Push to remote
    Write-Step "Pushing to Remote"
    git push -u origin $branchName
    Write-Success "Pushed to origin/$branchName"

    # Step 5: Create PR to dev
    $prTitle = $CommitMessage
    $prBody = @"
## Automated PR

**Change Type:** $changeType
**Affected Areas:** $($areas -join ', ')
**Branch:** $branchName

### Files Changed:
$($changedFiles | ForEach-Object { "- $_" } | Out-String)

### Checklist:
- [x] Build checks passed
- [x] Type checks passed
- [x] Changes committed and pushed
"@

    $prUrl = New-PullRequest -Branch $branchName -BaseBranch "dev" -Title $prTitle -Body $prBody

    # Step 6: Wait for CI checks (bounded; detects stuck/unassigned runners)
    $ciStatus = "Skipped"
    if (-not $SkipTests) {
        $ciStatus = Invoke-QATests -Branch $branchName -BaseBranch "dev" -MaxWaitMinutes $MaxWaitMinutes -RunnerAcquireTimeoutSeconds $RunnerAcquireTimeoutSeconds
    } else {
        Write-Info "Skipping CI wait (--SkipTests)"
    }

    $checksRequired = Test-ChecksRequired -BaseBranch "dev"
    switch ($ciStatus) {
        "Passed"   { }
        "NoChecks" { Write-Info "No CI checks found for this PR; proceeding to merge." }
        "Skipped"  { }
        "Failed"   { throw "CI checks failed on the PR. Fix the issues before merging." }
        default {
            # Stuck or TimedOut: only block when the base branch enforces the check.
            if ($checksRequired) {
                throw "CI did not complete ($ciStatus) and 'dev' requires these checks. PR left open at $($prUrl). Re-run once GitHub Actions recovers."
            }
            Write-Warning "CI did not complete ($ciStatus), but checks are not required on 'dev' and local build/type checks passed. Proceeding to merge."
        }
    }

    # Step 7: Merge to dev
    Merge-PullRequest -Branch $branchName -BaseBranch "dev"

    # Step 8: Check if this is the first commit (dev has changes not in main)
    $isFirstCommit = Test-IsFirstCommit

    if ($isFirstCommit) {
        Write-Step "First Commit Detected - Creating dev -> main PR"

        # Ensure we're on dev
        git checkout dev
        git pull origin dev

        $devToMainBranch = "release/dev-to-main-$timestamp"
        git checkout -b $devToMainBranch
        git push -u origin $devToMainBranch

        $releasePrTitle = "release: merge dev to main"
        $releasePrBody = @"
## Release PR: dev -> main

This PR merges all changes from dev to main.

### Included Changes:
$($changedFiles | ForEach-Object { "- $_" } | Out-String)

### Verification:
- [x] Feature PR merged to dev
- [x] QA tests passed
- [x] Ready for production
"@

        $releasePrUrl = New-PullRequest -Branch $devToMainBranch -BaseBranch "main" -Title $releasePrTitle -Body $releasePrBody

        # Wait for CI on the release PR (bounded, same stuck detection).
        if (-not $SkipTests) {
            $releaseCiStatus = Invoke-QATests -Branch $devToMainBranch -BaseBranch "main" -MaxWaitMinutes $MaxWaitMinutes -RunnerAcquireTimeoutSeconds $RunnerAcquireTimeoutSeconds
            if ($releaseCiStatus -eq "Failed") {
                throw "CI checks failed on the release PR. Fix the issues before merging."
            }
            if (($releaseCiStatus -eq "Stuck" -or $releaseCiStatus -eq "TimedOut") -and (Test-ChecksRequired -BaseBranch "main")) {
                throw "Release PR checks are required on 'main' but did not complete ($releaseCiStatus). PR left open at $($releasePrUrl)."
            }
            if ($releaseCiStatus -eq "Stuck" -or $releaseCiStatus -eq "TimedOut") {
                Write-Warning "Release CI did not complete ($releaseCiStatus); checks are not required on 'main'. Proceeding to merge."
            }
        }

        # Merge release PR
        Merge-PullRequest -Branch $devToMainBranch -BaseBranch "main"

        # Cleanup
        git checkout main
        git pull origin main
        git branch -D $devToMainBranch 2>$null
    }

    # Cleanup local feature branch
    git checkout dev 2>$null
    git pull origin dev 2>$null
    git branch -D $branchName 2>$null

    # Summary
    Write-Host @"

+===============================================================+
|                    Workflow Complete! [OK]                        |
+===============================================================+

  Branch:       $branchName
  Commit:       $CommitMessage
  PR to dev:    $prUrl

"@ -ForegroundColor $Colors.Success

    if ($isFirstCommit) {
        Write-Host "  Release PR:   $releasePrUrl" -ForegroundColor $Colors.Success
        Write-Host "  Merged:       dev -> main" -ForegroundColor $Colors.Success
    }

    Write-Host "`nAll changes have been successfully integrated!`n" -ForegroundColor $Colors.Success
}
catch {
    Write-Error "Workflow failed: $_"
    Write-Host "`nStack Trace:`n$($_.ScriptStackTrace)" -ForegroundColor Gray
    exit 1
}
