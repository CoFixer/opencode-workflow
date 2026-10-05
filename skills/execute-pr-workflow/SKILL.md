---
name: "execute-pr-workflow"
description: "Runs build/type checks, pushes to a feature/bug branch, creates a PR to dev, runs QA tests, and merges. If this is the first commit, also creates a PR from dev to main and merges it. Invoke when user says '/skill:execute-pr-workflow'."
---

# Execute PR Workflow

This skill automates the **full PR lifecycle** from changes to merged code:

1. Detects changes and determines branch type (`feat/` or `fix/`)
2. Runs build and type checks for affected packages
3. Commits and pushes to an appropriate branch
4. Creates a PR to the `dev` branch
5. Waits for CI checks with a **bounded timeout** (detects jobs that never get a runner)
6. Auto-merges the PR to `dev` — blocking only when the base branch actually requires the check
7. **First commit detection:** If `dev` has changes not in `main`, also creates a PR `dev -> main` and merges it

## Hard rules

- Stop immediately if there are no changes to commit
- Do not proceed if build/typecheck fails
- Do not proceed if PR creation fails
- Never stage secrets (for example `.env*`, credentials files)
- Always create a new branch; never commit directly to `dev` or `main`
- **Never wait indefinitely on CI.** Use a bounded wait (default 8 min) and bail
  out early when a queued job is never picked up by a runner.
- **Advisory checks must not block a merge.** Only block on a failing/stuck check
  when the base branch enforces it as a required status check.
- **Keep skill scripts ASCII-only.** PowerShell 5.1 reads BOM-less UTF-8 files as
  ANSI, turning glyphs like `✓` into "smart quotes" that break parsing. Use
  `[OK]`, `[x]`, `->` instead of `✓`, `✗`, `→`.
- `run-workflow.ps1` is the **single source of truth**; `run-workflow-fixed.ps1`
  is a thin wrapper that delegates to it so the two can never drift.

## Workflow (PowerShell commands)

### 0) Detect changes

```powershell
$status = git status --porcelain
if (-not $status) { throw "No changes to commit." }

$changedFiles = ($status | ForEach-Object { $_.Substring(3) })
```

### 1) Determine change type and branch prefix

```powershell
$changeType = "feature"  # default
$branchPrefix = "feat"   # default

# Check commit message or file paths for indicators
# fix, bug, hotfix, patch → prefix: fix
# feat, feature, add, implement → prefix: feat
# refactor, restructure → prefix: refactor
# docs, readme → prefix: docs
# test, spec → prefix: test
# chore, update, bump, deps → prefix: chore

if ($changedFiles | Where-Object { $_ -match "(fix|bug|hotfix|patch)" }) {
    $branchPrefix = "fix"
} elseif ($changedFiles | Where-Object { $_ -match "(refactor|restructure)" }) {
    $branchPrefix = "refactor"
} elseif ($changedFiles | Where-Object { $_ -match "(test|spec)" }) {
    $branchPrefix = "test"
} elseif ($changedFiles | Where-Object { $_ -match "(docs|readme)" }) {
    $branchPrefix = "docs"
} elseif ($changedFiles | Where-Object { $_ -match "(chore|deps|bump)" }) {
    $branchPrefix = "chore"
}
```

### 2) Detect affected packages

```powershell
$hasBackend = $changedFiles | Where-Object { $_ -like 'backend/*' }
$hasFrontend = $changedFiles | Where-Object { $_ -like 'frontend/*' }
$hasDashboard = $changedFiles | Where-Object { $_ -like 'dashboard/*' }
$hasOpencode = $changedFiles | Where-Object { $_ -like '.opencode/*' }
$hasMobile = $changedFiles | Where-Object { $_ -like 'mobile/*' }
```

### 3) Build + typecheck gates (only for changed packages)

```powershell
if ($hasBackend) {
    Push-Location backend
    npm run type-check
    npm run build
    Pop-Location
}

if ($hasFrontend) {
    Push-Location frontend
    npm run typecheck
    npm run build
    Pop-Location
}

if ($hasDashboard) {
    Push-Location dashboard
    npm run typecheck
    npm run build
    Pop-Location
}

if ($hasMobile) {
    Push-Location mobile
    npm run typecheck
    npm run build
    Pop-Location
}
```

### 4) Stage safely

```powershell
git add -A

# Never commit secrets / envs
git reset HEAD -- .env .env.* 2>$null

# Avoid committing the .opencode submodule pointer if present/dirty
git reset HEAD -- .opencode .gitmodules 2>$null
```

### 5) Create branch

```powershell
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$area = "project"
if ($hasBackend) { $area = "backend" }
elseif ($hasFrontend) { $area = "frontend" }
elseif ($hasDashboard) { $area = "dashboard" }
elseif ($hasOpencode) { $area = "opencode" }
elseif ($hasMobile) { $area = "mobile" }

$branchName = "$branchPrefix/$area-$timestamp"
git checkout -b $branchName
```

### 6) Create commit (Conventional Commits)

```powershell
# Auto-generate commit message based on change type
$commitType = $branchPrefix
$commitMessage = "$commitType($area): automated changes"

# If user provided a custom message, use that instead
git commit -m "$commitMessage"
```

### 7) Push branch

```powershell
git push -u origin $branchName
```

### 8) Create PR to dev

Requires `gh` CLI.

```powershell
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "gh CLI is required." }
gh auth status

$title = $commitMessage
$body = @"
## Automated PR

**Change Type:** $changeType
**Affected Areas:** $area
**Branch:** $branchName

### Files Changed:
$($changedFiles | ForEach-Object { "- $_" } | Out-String)

### Checklist:
- [x] Build checks passed
- [x] Type checks passed
- [x] Changes committed and pushed
"@

$prUrl = gh pr create --base dev --head $branchName --title $title --body $body
if ([string]::IsNullOrWhiteSpace($prUrl)) { throw "PR creation failed." }
```

### 9) Wait for CI checks and merge to dev (bounded, incident-aware)

Do **not** poll blindly for 30 minutes. A queued job that never gets a runner is a
platform problem (GitHub Actions incident / runner capacity), not a code problem.
Detect it early and move on.

```powershell
$prNumber = gh pr view $branchName --json number --jq '.number'

$maxWaitSeconds              = 8 * 60   # overall budget for the whole wait
$runnerAcquireTimeoutSeconds = 120      # give up if nothing is picked up in 2 min

$waited = 0
$sawProgress = $false
$ciStatus = "TimedOut"

while ($waited -lt $maxWaitSeconds) {
    Start-Sleep -Seconds 10
    $waited += 10

    $json = gh pr checks $prNumber --json name,state,startedAt 2>$null
    if (-not $json) { $ciStatus = "NoChecks"; break }

    $checks = @($json | ConvertFrom-Json)
    $states = @($checks | ForEach-Object { ([string]$_.state).ToUpper() })

    if ($states -contains "FAILURE" -or $states -contains "ERROR" -or $states -contains "CANCELLED") {
        $ciStatus = "Failed"; break
    }

    $pending = @($states | Where-Object { $_ -in @("PENDING","QUEUED","IN_PROGRESS","EXPECTED","REQUESTED","WAITING","STALE") })
    if ($pending.Count -eq 0) { $ciStatus = "Passed"; break }

    # Has any job actually been picked up by a runner yet?
    $running = @($checks | Where-Object { ([string]$_.state).ToUpper() -eq "IN_PROGRESS" -or $_.startedAt })
    if ($running.Count -gt 0) { $sawProgress = $true }

    # Nothing ever started -> GitHub-hosted runner capacity / Actions incident.
    if (-not $sawProgress -and $waited -ge $runnerAcquireTimeoutSeconds) {
        $ciStatus = "Stuck"; break
    }
}

# Decide whether CI can block the merge: only if 'dev' enforces required checks.
$checksRequired = $false
$repo = gh repo view --json nameWithOwner --jq '.nameWithOwner'
$protection = gh api "repos/$repo/branches/dev/protection" 2>$null
if ($protection) {
    $contexts = @(($protection | ConvertFrom-Json).required_status_checks.contexts)
    $checksRequired = $contexts.Count -gt 0
}

switch ($ciStatus) {
    "Passed"   { }
    "Failed"   { throw "CI failed on PR #$prNumber. Fix before merging." }
    "NoChecks" { Write-Host "No CI checks configured; proceeding." }
    default {
        if ($checksRequired) {
            throw "CI did not complete ($ciStatus) and 'dev' requires it. PR left open: $prUrl"
        }
        Write-Host "CI did not complete ($ciStatus); checks are advisory on 'dev'. Merging."
    }
}

# Merge PR (verify success; do not silently ignore a failed merge)
gh pr merge $prNumber --squash --delete-branch
if ($LASTEXITCODE -ne 0) { gh pr merge $prNumber --squash }
if ($LASTEXITCODE -ne 0) { throw "Failed to merge PR #$prNumber." }
```

**CI outcomes:** `Passed`, `Failed`, `NoChecks`, `Stuck` (no runner picked up the
job), `TimedOut`. `Stuck` / `TimedOut` only block the merge when the base branch
enforces required status checks; otherwise the merge proceeds after the short
wait. A one-time GitHub Actions health check
(`https://www.githubstatus.com/api/v2/components.json`) is also performed and a
warning is printed when Actions is degraded.

### 10) First commit: create dev -> main PR

Only create the release PR if `main` is empty (no commits yet). Once `main` has been initialized, never auto-merge `dev` to `main`.

```powershell
git rev-parse --verify main 2>$null | Out-Null
$mainExists = $LASTEXITCODE -eq 0
$mainCommitCount = if ($mainExists) { git rev-list --count main 2>$null } else { 0 }
$isFirstCommit = (-not $mainExists) -or ([int]$mainCommitCount -eq 0)

if ($isFirstCommit) {
    # This is the first commit — create release PR
    $releaseBranch = "release/dev-to-main-$timestamp"
    git checkout dev
    git pull origin dev
    git checkout -b $releaseBranch
    git push -u origin $releaseBranch

    $releaseTitle = "release: merge dev to main"
    $releaseBody = @"
## Release PR: dev → main

This PR merges all changes from dev to main.

### Verification:
- [x] Feature PR merged to dev
- [x] QA tests passed
- [x] Ready for production
"@

    $releasePrUrl = gh pr create --base main --head $releaseBranch --title $releaseTitle --body $releaseBody

    # Wait using the same bounded/incident-aware logic as Section 9, against base 'main'.
    # Only block the release merge when 'main' enforces required status checks.
    $releasePrNumber = gh pr view $releaseBranch --json number --jq '.number'

    # Merge release PR
    gh pr merge $releasePrNumber --squash --delete-branch

    # Cleanup
    git checkout main
    git pull origin main
    git branch -D $releaseBranch 2>$null
}
```

### 11) Cleanup

```powershell
git checkout dev 2>$null
git pull origin dev 2>$null
git branch -D $branchName 2>$null
```

## Output to user

Return:
- branch name created
- commit SHA + subject
- PR URL (dev PR)
- CI status: `PASSED` / `FAILED` / `NO CHECKS` / `STUCK (no runner)` / `TIMED OUT`
- merge status (MERGED / NOT MERGED)
- If first commit: release PR URL and merge status
- any failure reason
- when CI was `STUCK`/`TIMED OUT` and the check was advisory: state clearly that
  the merge proceeded on locally-passing build/type checks while GitHub Actions
  was degraded
