---
name: "commit"
description: "Runs build/type checks, updates bun.lock if needed, then commits current branch, opens a PR to dev, and merges it. Invoke when user says '/skill:commit' to ship changes."
---

# Commit (PR → dev → merge)

This skill ships the **current branch** through a PR into `dev`:

- Verifies you are **not** on `dev`, `main`, or `master`
- Detects which package(s) changed and runs their **typecheck/build**
- If dependencies changed and a package uses **bun.lock**, regenerates it via `bun install`
- Commits, pushes, creates a PR to `dev`, and merges the PR

## Hard rules

- Stop immediately if current branch is `dev`, `main`, or `master`
- Do not create a new branch; use the current branch only
- Do not proceed if build/typecheck fails
- Do not proceed if PR creation fails
- Never stage secrets (for example `.env*`, credentials files)

## Workflow (PowerShell commands)

### 0) Branch guard

```powershell
$branch = (git branch --show-current).Trim()
if ([string]::IsNullOrWhiteSpace($branch)) { throw "Detached HEAD. Checkout a feature branch first." }
if ($branch -in @('dev','main','master')) { throw "Refusing to run on protected branch: $branch" }
```

### 1) Ensure there are changes

```powershell
$status = git status --porcelain
if (-not $status) { throw "No changes to commit." }
```

### 2) Detect changed packages (generic)

Do **not** hardcode package names. Discover workspace roots dynamically:

- Preferred: read the workspace config (`package.json` → `workspaces`, `pnpm-workspace.yaml`, `turbo.json`, `lerna.json`, `nx.json`).
- Fallback: top-level directories containing `package.json`, `composer.json`, or `pyproject.toml`.

```powershell
$changedFiles = ($status | ForEach-Object { $_.Substring(3) })
$changedRoots = $changedFiles | ForEach-Object { ($_ -split '/')[0] } | Sort-Object -Unique
$packageRoots = @($changedRoots | Where-Object {
  (Test-Path (Join-Path $_ 'package.json')) -or
  (Test-Path (Join-Path $_ 'composer.json')) -or
  (Test-Path (Join-Path $_ 'pyproject.toml'))
})
# Empty list = repo-root change. Run only the gates that exist.
```

### 3) Lockfile sync (only when needed)

For each changed package root, run only if **both** are true:
- the package contains a lockfile (`bun.lock`, `bun.lockb`, `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`)
- `package.json` (or the lock itself) changed in that package

Also stop if the required package manager is not installed.

```powershell
function Sync-Lockfile([string]$pkgPath) {
  $pkgJsonChanged = $changedFiles | Where-Object { $_ -eq "$pkgPath/package.json" }
  if (-not $pkgJsonChanged) { return }

  if (Test-Path (Join-Path $pkgPath 'bun.lock')) {
    if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
      throw "bun.lock exists in $pkgPath but bun is not installed."
    }
    Push-Location $pkgPath
    try { bun install } finally { Pop-Location }
  }
  elseif (Test-Path (Join-Path $pkgPath 'pnpm-lock.yaml')) {
    Push-Location $pkgPath
    try { pnpm install --lockfile-only } finally { Pop-Location }
  }
  elseif (Test-Path (Join-Path $pkgPath 'yarn.lock')) {
    Push-Location $pkgPath
    try { yarn install --mode update-lockfile } finally { Pop-Location }
  }
  elseif (Test-Path (Join-Path $pkgPath 'package-lock.json')) {
    Push-Location $pkgPath
    try { npm install --package-lock-only } finally { Pop-Location }
  }
}

foreach ($pkg in $packageRoots) { Sync-Lockfile $pkg }
```

### 4) Build + typecheck gates (only for changed packages)

Run the first matching script that exists in each package. Never assume script names.

```powershell
function Invoke-ScriptIfPresent([string]$pkg, [string[]]$scriptNames) {
  $pkgJsonPath = Join-Path $pkg 'package.json'
  if (-not (Test-Path $pkgJsonPath)) { return }
  $pkgJson = Get-Content $pkgJsonPath -Raw | ConvertFrom-Json
  if (-not $pkgJson.scripts) { return }
  $available = $pkgJson.scripts.PSObject.Properties.Name
  foreach ($name in $scriptNames) {
    if ($available -contains $name) {
      Push-Location $pkg
      try { npm run $name } finally { Pop-Location }
      return
    }
  }
}

foreach ($pkg in $packageRoots) {
  Invoke-ScriptIfPresent $pkg @('type-check', 'typecheck', 'tsc')
  Invoke-ScriptIfPresent $pkg @('build')
}
```

### 5) Stage safely

```powershell
git add -A

# Never commit secrets / envs
git reset HEAD -- .env .env.* 2>$null

# Avoid committing the .opencode submodule pointer if present/dirty
git reset HEAD -- .opencode .gitmodules 2>$null
```

### 6) Create commit (Conventional Commits)

- Type: `fix|feat|chore|refactor|test|docs|build|ci|perf|revert`
- Scope: prefer the changed package root name (e.g. `backend|frontend|dashboard|plugin`) or `monorepo` when multiple roots change.

If multiple packages changed, use `monorepo` scope.

```powershell
# Example:
git commit -m "fix(frontend): render recent activity content"
```

### 7) Push current branch

```powershell
git push -u origin $branch
```

### 8) Create PR to dev (requires gh)

Stop if `gh` is not installed or not authenticated.

```powershell
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "gh CLI is required." }
gh auth status

$title = (git log -1 --pretty=%s).Trim()
$body = @"
## Summary
- <fill based on diff>

## Validation
- <list the commands you ran, e.g. frontend: npm run typecheck; npm run build>
"@

$prUrl = gh pr create --base dev --head $branch --title $title --body $body
if ([string]::IsNullOrWhiteSpace($prUrl)) { throw "PR creation failed." }
```

### 9) Merge PR into dev

```powershell
$prNumber = gh pr view $branch --json number --jq '.number'
gh pr merge $prNumber --merge --delete-branch=false
```

Optional: keep the current branch synced with dev:

```powershell
git fetch origin dev
git merge origin/dev --no-edit
```

## Output to user

Return:
- branch name
- commit SHA + subject
- PR URL
- merge status (MERGED / NOT MERGED) and any failure reason
