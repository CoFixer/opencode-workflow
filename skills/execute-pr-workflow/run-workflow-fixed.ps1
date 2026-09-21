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
    [string]$CommitMessage
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
    Write-Host "  ✓ $Message" -ForegroundColor $Colors.Success
}

function Write-Error {
    param([string]$Message)
    Write-Host "  ✗ $Message" -ForegroundColor $Colors.Error
}

function Write-Info {
    param([string]$Message)
    Write-Host "  → $Message" -ForegroundColor $Colors.Info
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

function Invoke-QATests {
    param(
        [string]$Branch,
        [string]$BaseBranch = "dev",
        [int]$MaxWaitMinutes = 30
    )

    Write-Step "Waiting for CI/QA Tests on PR: $Branch -> $BaseBranch"

    # Check if GitHub CLI is available
    if (-not (Test-CommandExists "gh")) {
        Write-Warning "GitHub CLI (gh) not found. Skipping automated QA check. Please verify tests manually."
        return $true
    }

    # Get PR number
    $prNumber = $null
    $attempts = 0
    $maxAttempts = 10

    while (-not $prNumber -and $attempts -lt $maxAttempts) {
        Start-Sleep -Seconds 3
        $attempts++

        try {
            $prList = gh pr list --head $Branch --base $BaseBranch --json number --jq '.[0].number' 2>$null
            if ($prList) {
                $prNumber = $prList.Trim()
            }
        }
        catch { }
    }

    if (-not $prNumber) {
        Write-Warning "Could not find PR number. Skipping automated QA check."
        return $true
    }

    Write-Info "Found PR #$prNumber, waiting for checks..."

    # Wait for checks to complete
    $waited = 0
    while ($waited -lt ($MaxWaitMinutes * 60)) {
        Start-Sleep -Seconds 10
        $waited += 10

        try {
            $checks = gh pr checks $prNumber --json state --jq '.[].state' 2>$null
            if ($checks) {
                $checkStates = $checks -split "`n" | Where-Object { $_ }

                if ($checkStates | Where-Object { $_ -eq "FAILURE" }) {
                    Write-Error "QA tests failed on PR #$prNumber"
                    return $false
                }

                if (($checkStates | Where-Object { $_ -ne "SUCCESS" -and $_ -ne "SKIPPED" }).Count -eq 0) {
                    Write-Success "All QA tests passed on PR #$prNumber"
                    return $true
                }
            }
        }
        catch { }

        if ($waited % 60 -eq 0) {
            Write-Info "Waiting for checks... ($($waited / 60) minutes elapsed)"
        }
    }

    Write-Warning "Timed out waiting for checks after $MaxWaitMinutes minutes"
    return $true
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
    Write-Success "Merged PR #$prNumber and deleted branch"
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
╔═══════════════════════════════════════════════════════════════╗
║              Execute PR Workflow Automation                   ║
║                                                               ║
║  Automated CI/CD: Build → Type Check → PR → QA → Merge        ║
╚═══════════════════════════════════════════════════════════════╝
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
        Write-Host "  - Wait for QA tests"
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

    # Step 6: Wait for QA tests
    if (-not $SkipTests) {
        $qaPassed = Invoke-QATests -Branch $branchName -BaseBranch "dev"
        if (-not $qaPassed) {
            throw "QA tests failed. Please fix issues and retry."
        }
    } else {
        Write-Info "Skipping QA test wait (--SkipTests)"
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
## Release PR: dev → main

This PR merges all changes from dev to main.

### Included Changes:
$($changedFiles | ForEach-Object { "- $_" } | Out-String)

### Verification:
- [x] Feature PR merged to dev
- [x] QA tests passed
- [x] Ready for production
"@

        $releasePrUrl = New-PullRequest -Branch $devToMainBranch -BaseBranch "main" -Title $releasePrTitle -Body $releasePrBody

        # Wait for QA on dev->main PR
        if (-not $SkipTests) {
            $releaseQaPassed = Invoke-QATests -Branch $devToMainBranch -BaseBranch "main" -MaxWaitMinutes 30
            if (-not $releaseQaPassed) {
                throw "QA tests failed on release PR. Please fix issues and retry."
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

╔═══════════════════════════════════════════════════════════════╗
║                    Workflow Complete! ✓                        ║
╚═══════════════════════════════════════════════════════════════╝

  Branch:       $branchName
  Commit:       $CommitMessage
  PR to dev:    $prUrl

"@ -ForegroundColor $Colors.Success

    if ($isFirstCommit) {
        Write-Host "  Release PR:   $releasePrUrl" -ForegroundColor $Colors.Success
        Write-Host "  Merged:       dev → main" -ForegroundColor $Colors.Success
    }

    Write-Host "`nAll changes have been successfully integrated!`n" -ForegroundColor $Colors.Success
}
catch {
    Write-Error "Workflow failed: $_"
    Write-Host "`nStack Trace:`n$($_.ScriptStackTrace)" -ForegroundColor Gray
    exit 1
}

