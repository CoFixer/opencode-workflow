---
description: Commit changes to current branch, create PR to dev, run audit review, and optionally merge (main project only, skips submodules)
argument-hint: Optional commit message override (leave empty for AI-generated message)
---

You are a git workflow assistant. Your task is to commit changes to the **current branch**, create PRs targeting `dev`, run automated audit checks, and merge upon user approval.

**Note:** This command commits the **main project only**. Use `/commit-all` to include submodule changes.

## CRITICAL RULES (NEVER VIOLATE)

1. **NEVER push directly to `dev`, `main`, or `master`** - All changes MUST go through PRs
2. **ALWAYS use the current branch** - Do NOT create new branches
3. **ALWAYS create a PR targeting `dev`** - The workflow is NOT complete until a PR URL is generated
4. **STOP if on `main`, `dev`, or `master`** - Ask user to create/checkout a feature branch first
5. **STOP if PR creation fails** - Do NOT continue, do NOT suggest manual alternatives
6. **NEVER commit submodule changes** - This command is for main project only
7. **NEVER merge without user approval** - Always ask before merging PR to dev
8. **ALWAYS run audit checks** - PR review is mandatory before merge decision

## Branch Policy

- **Feature branches only** (e.g., `feature/<name>`, `fix/<name>`, `<your-name>`) - Never commit on `main`, `dev`, or `master`
- **PRs target `dev`** - All PRs merge into `dev`, not `main`
- **Use current branch** - No new branch creation during commit

---

## Step 0: Branch Validation (CRITICAL)

Before any commit, validate the current branch:

```powershell
$branch = (git branch --show-current).Trim()
Write-Host "Current branch: $branch"
```

### 0.1 Check for Detached HEAD

```powershell
if ([string]::IsNullOrWhiteSpace($branch)) {
  throw "Detached HEAD. Checkout a feature branch first."
}
```

### 0.2 Check for Protected Branches

```powershell
if ($branch -in @('dev','main','master')) {
  throw "Refusing to run on protected branch: $branch"
}
```

### 0.3 Ensure `dev` Branch Exists

```powershell
$devExists = git show-ref --verify --quiet refs/heads/dev
if (-not $devExists) {
  Write-Host "Creating dev branch from main..."
  $orig = $branch
  git checkout main; git checkout -b dev; git push -u origin dev; git checkout $orig
  Write-Host "Created dev branch"
}
```

### 0.4 Confirm Ready

```powershell
Write-Host "Using branch: $branch"
Write-Host "PR will target: dev"
```

---

## Step 1: Check for Submodule Changes (Warning Only)

**IMPORTANT:** This command does NOT commit submodules. Check if any exist and warn the user.

```powershell
git status
```

### 1.1 Detect Submodule Changes

Look for patterns like:
- `modified:   .opencode (modified content)`
- `modified:   .opencode (new commits)`
- Any path ending with `(modified content)` or `(new commits)`

### 1.2 Warn User (Do NOT Commit Submodules)

If submodule changes are detected:

```
⚠️ Submodule Changes Detected

The following submodules have uncommitted changes:
- .opencode (modified content)

These will NOT be committed by /commit.
Use /commit-all to commit both submodules and main project.

Proceeding with main project changes only...
```

**Continue with main project commit - do NOT commit submodules.**

---

## Step 2: Detect Projects with Changes

Run `git status --porcelain` and group changes by their root folder.

**IMPORTANT:** Exclude submodule paths from staging.

### Project Folder Detection Rules:

**Known project patterns** (each gets its own commit):
- `backend/` - Backend API (NestJS)
- `frontend/` - Main frontend app (React 19)
- `dashboard/` - Admin dashboard (React 19)
- `storepilot-plugin/` - WordPress WooCommerce plugin

**Exclusions** (never commit):
- `.env` files or files containing secrets
- `credentials.json` or similar sensitive files
- `node_modules/`, `dist/`, build artifacts
- `playwright-report/`, `test-results/` (test output)
- **Submodules** (`.opencode/`, `.claude/`, `.pi/`, `.kimi/`, or any path marked as submodule)

---

## Step 3: Stage Files

### Stage files (excluding submodules):

```powershell
git add -A
git reset HEAD -- .env .env.* 2>$null
git reset HEAD -- .opencode .claude .pi .kimi .gitmodules 2>$null
```

Or stage specific project folders:
```powershell
git add "<project-folder>/"
```

---

## Step 4: Sync with dev (Conflict Prevention)

**Purpose:** Ensure branch is up-to-date with `dev` before committing, so merge conflicts are caught locally.

### 4.1 Fetch and merge latest dev

```powershell
git fetch origin dev
git merge origin/dev --no-edit
```

### 4.2 Handle conflicts

**If merge conflicts occur → STOP immediately:**

```
⚠️ Merge Conflicts with dev Detected

Conflicting files:
  - <file1>
  - <file2>

Resolve conflicts, then re-run /commit:
  1. Fix the conflicting files
  2. git add <resolved-files>
  3. git commit (to complete the merge)
  4. Re-run /commit
```

**Do NOT proceed to commit if conflicts exist.**

**If merge succeeds or already up-to-date → continue to Step 5.**

---

## Step 5: bun.lock Sync (only when needed)

Run only if **both** are true:
- package contains `bun.lock`
- `package.json` (or the lock itself) changed in that package

Also stop if `bun` is required but not installed.

```powershell
function Ensure-Bun {
  if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
    throw "bun is required to update bun.lock, but bun is not installed/available in PATH."
  }
}

function Sync-BunLock([string]$pkgPath) {
  $changedFiles = (git status --porcelain | ForEach-Object { $_.Substring(3) })
  $pkgJsonChanged = $changedFiles | Where-Object { $_ -eq "$pkgPath/package.json" }
  $bunLockChanged = $changedFiles | Where-Object { $_ -eq "$pkgPath/bun.lock" }
  $hasBunLock = Test-Path (Join-Path $pkgPath 'bun.lock')
  if ($hasBunLock -and ($pkgJsonChanged -or $bunLockChanged)) {
    Ensure-Bun
    Push-Location $pkgPath
    bun install
    Pop-Location
  }
}

$status = git status --porcelain
$changedFiles = ($status | ForEach-Object { $_.Substring(3) })
$hasBackend = $changedFiles | Where-Object { $_ -like 'backend/*' }
$hasFrontend = $changedFiles | Where-Object { $_ -like 'frontend/*' }
$hasDashboard = $changedFiles | Where-Object { $_ -like 'dashboard/*' }
$hasPlugin = $changedFiles | Where-Object { $_ -like 'storepilot-plugin/*' }

if ($hasBackend) { Sync-BunLock 'backend' }
if ($hasFrontend) { Sync-BunLock 'frontend' }
if ($hasDashboard) { Sync-BunLock 'dashboard' }
if ($hasPlugin) { Sync-BunLock 'storepilot-plugin' }
```

---

## Step 6: Build + Typecheck Gates (only for changed packages)

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

if ($hasPlugin) {
  Push-Location storepilot-plugin
  npm run build
  Pop-Location
}
```

---

## Step 7: Commit

### Create commit with proper message:

- Type: `fix|feat|chore|refactor|test|docs|build|ci|perf|revert`
- Scope: prefer `backend|frontend|dashboard|plugin|monorepo`

If multiple packages changed, use `monorepo` scope.

```powershell
# Example:
git commit -m "fix(frontend): render recent activity content"
```

If $ARGUMENTS is provided by the user, use it as the commit message.

---

## Step 8: Push and Create PR (MANDATORY)

### Push to current branch:

```powershell
git push -u origin $branch
```

### Create PR targeting dev:

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

### Verify PR was created (REQUIRED):

```powershell
gh pr view $branch --json url --jq '.url'
```

**If this command fails or returns empty: STOP immediately.**

---

## Step 9: Run Automated Audit Checks

After PR is created, run a battery of checks against the changed files. Each check produces a result: **PASS / WARN / FAIL**.

### 9.0 Auto-Detect Stacks

```powershell
$prNumber = gh pr view $branch --json number --jq '.number'
$changedFiles = gh pr diff $prNumber --name-only

$hasReact = (Test-Path frontend/package.json) -and (Select-String -Path frontend/package.json -Pattern '"react"' -Quiet)
$hasNestjs = (Test-Path backend/nest-cli.json) -or ((Test-Path backend/package.json) -and (Select-String -Path backend/package.json -Pattern '"@nestjs' -Quiet))
$hasPlugin = Test-Path storepilot-plugin/storepilot-plugin.php
```

Only run checks for detected stacks. Skip checks for stacks not present.

### 9.1 Build Validation

| Stack | Command |
|-------|---------|
| **React (frontend)** | `cd frontend && npx tsc --noEmit` |
| **React (dashboard)** | `cd dashboard && npx tsc --noEmit` |
| **NestJS** | `cd backend && npx tsc --noEmit` |
| **Plugin** | `cd storepilot-plugin && npm run build` |

**Result:** PASS if exit code 0, FAIL if errors found.

### 9.2 Type Checking / Code Formatting

| Stack | Command |
|-------|---------|
| **React (frontend)** | `cd frontend && npm run typecheck` |
| **React (dashboard)** | `cd dashboard && npm run typecheck` |
| **NestJS** | `cd backend && npm run type-check` |

**Result:** PASS if clean, WARN if formatting issues found.

### 9.3 Linting

| Stack | Command (if tool exists) | Fallback |
|-------|--------------------------|----------|
| **React** | `cd frontend && npm run lint` | Agent-based scan |
| **React (dashboard)** | `cd dashboard && npm run lint` | Agent-based scan |
| **NestJS** | `cd backend && npm run lint` | Agent-based scan |

**Detect if linter exists:** Check `package.json` for `lint` script.

**Fallback:** If no linter is configured, this check is covered by the Code Quality Scan (Step 9.5).

### 9.4 Migration / Schema Check

| Stack | Command |
|-------|---------|
| **NestJS** | `cd backend && npx typeorm migration:generate --check` (if TypeORM configured) |
| **React** | Skip — not applicable |

**Result:** PASS if no pending migrations, FAIL if model changes are missing migrations.

### 9.5 Code Quality Scan (Agent-Based)

Launch `code-architecture-reviewer` agent in **quick diff mode** against the PR diff:

```
Agent(
  subagent_type='code-architecture-reviewer',
  description='Quick PR audit review',
  prompt='QUICK REVIEW MODE — diff-only scan for PR audit.

PR diff:
$(gh pr diff $prNumber)

Detected stacks: [list detected stacks]

Apply the appropriate checklist per stack. Check for:
- Security issues (hardcoded secrets, XSS, SQL injection)
- Type safety (no `any` in TypeScript, proper typing)
- Code patterns (per project conventions)
- No console.logs, TODOs, or commented-out code
- Proper error handling
- Auth/permissions on new endpoints or routes

Return a structured verdict:
VERDICT: PASS | WARN | FAIL
ISSUES: (numbered list, each with severity CRITICAL/WARNING)
Keep response under 20 lines.'
)
```

### 9.6 API Integration Validation

**Runs when:** Changed files include API service files (`services/`), backend controllers, or URL/route files.

Launch `api-integration-agent` to check:
- Frontend/dashboard service calls match backend endpoints
- Missing parameters (search, pagination, filters, sort)
- Response shape matches TypeScript types / DTO output

```
Agent(
  subagent_type='api-integration-agent',
  description='API integration audit',
  prompt='Quick audit of API integration for PR #$prNumber.
Changed files: $changedFiles
Check: endpoint consistency, missing params, type mismatches.
Return: PASS / WARN / FAIL with brief list of issues.'
)
```

### 9.7 Routing Validation

**Runs when:** Changed files include route/URL/navigation files.

| Stack | What to Check |
|-------|---------------|
| **React** | Routes in `routes/*.ts` — new routes registered, no orphans |
| **NestJS** | Controllers registered in modules, route decorators present |

### 9.8 Authentication & Role Validation

**Runs when:** Changed files touch auth, guards, permissions, or protected routes.

| Stack | What to Check |
|-------|---------------|
| **React** | Protected routes use auth guards, role-based access correct |
| **NestJS** | `@UseGuards(JwtAuthGuard)` applied, `@Roles()` decorators correct |

---

## Step 10: Generate PR Audit Report

Aggregate all check results and calculate QA score:
- Each PASS = full points
- Each WARN = half points
- Each FAIL = 0 points
- **QA Score** = (earned / total) × 100

Display the audit report to the user:

```
╔══════════════════════════════════════════════╗
║            PR AUDIT REPORT                   ║
║   Branch: $branch → dev              ║
║   PR: #$prNumber                            ║
╠══════════════════════════════════════════════╣
║                                              ║
║  Build Validation       ✓ PASS / ⚠ WARN / ✗ FAIL  ║
║  Type Check / Format    ✓ PASS / ⚠ WARN / ✗ FAIL  ║
║  Linting                ✓ PASS / ⚠ WARN / ✗ FAIL  ║
║  Migration Check        ✓ PASS / ⚠ WARN / ✗ FAIL  ║
║  Code Quality           ✓ PASS / ⚠ WARN / ✗ FAIL  ║
║  API Integration        ✓ PASS / ⚠ WARN / ✗ FAIL  ║
║  Routing                ✓ PASS / ⚠ WARN / ✗ FAIL  ║
║  Auth/Role              ✓ PASS / ⚠ WARN / ✗ FAIL  ║
║                                              ║
╠══════════════════════════════════════════════╣
║  QA Score: XX/100                            ║
║  Severity: X CRITICAL, X WARNINGS           ║
║                                              ║
║  Issues:                                     ║
║  1. [CRITICAL] <description>                 ║
║  2. [WARNING] <description>                  ║
║                                              ║
║  Suggestions:                                ║
║  1. <actionable fix>                         ║
║  2. <actionable fix>                         ║
╚══════════════════════════════════════════════╝
```

**Notes:**
- Only show checks that were actually run (skip N/A checks)
- List all issues with severity levels
- Provide actionable suggestions for each issue

---

## Step 11: Ask User for Approval

Use **AskUserQuestion** to present the results and ask for explicit approval:

```
PR Audit Complete — QA Score: XX/100
Stacks detected: [React, NestJS, etc.]
X CRITICAL issues, X warnings found.

[Show summary of critical issues if any]

What would you like to do?
```

**Options:**
- **"Approve & Merge to dev"** — Merge the PR into dev immediately
- **"Reject — Fix issues first"** — PR stays open, user fixes issues and re-runs /commit
- **"Keep PR open (no merge)"** — PR is created but not merged, user merges manually later

**IMPORTANT:** NEVER merge without explicit user approval from this step.

---

## Step 12: Conditional Merge

### If user selects "Approve & Merge to dev":

```powershell
$prNumber = gh pr view $branch --json number --jq '.number'
gh pr merge $prNumber --merge --delete-branch=false
```

Verify merge succeeded:
```powershell
$prState = gh pr view $prNumber --json state --jq '.state'
if ($prState -eq "MERGED") {
  Write-Host "PR auto-merged to dev"
}
```

Sync current branch with dev:
```powershell
git fetch origin dev
git merge origin/dev --no-edit
```

**If merge fails** (unexpected conflicts, branch protection):
- Do NOT STOP — the PR is already created
- Report: "PR created at <URL> but merge failed: <reason>. Merge manually or resolve conflicts."

### If user selects "Reject — Fix issues first":

- PR stays open
- Report: "PR open at <URL>. Fix the issues listed above, then re-run /commit."

### If user selects "Keep PR open (no merge)":

- PR stays open
- Report: "PR created at <URL>. Merge manually when ready."

---

## Step 13: Final Report

```
✓ Workflow Complete

Branch: $branch
Commit: <hash> - <commit message>
PR: <URL>
Audit: QA Score XX/100 — X critical, X warnings
Merge: ✓ Auto-merged to dev / ⚠️ PR open — pending fixes / ℹ️ PR open — manual merge
Branch synced: ✓ / N/A

Note: Submodule changes were skipped. Use /commit-all to include them.
```

---

## Error Handling

### STOP conditions (halt workflow immediately):
- **On `main`, `dev`, or `master` branch** → Ask user for feature branch name
- **Detached HEAD** → Ask user for branch name
- **Merge conflicts with dev** → Ask user to resolve conflicts
- **PR creation fails** → STOP, show error
- **Push fails** → STOP, show error
- **`gh` CLI not authenticated** → STOP, instruct user to run `gh auth login`
- **No changes detected** → STOP, inform user

### NEVER do these:
- ❌ Push directly to `dev`, `main`, or `master` in ANY repo
- ❌ Create new branches (use current branch only)
- ❌ Push without creating a PR
- ❌ Report "success" if PR was not created
- ❌ Suggest "manual PR creation" as an alternative
- ❌ Commit submodule changes (use /commit-all for that)
- ❌ Merge PR without explicit user approval
- ❌ Skip audit checks

---

## Important Notes

- **Use current branch** - Never create new branches during commit
- **PR is mandatory** - The workflow does not complete without a PR URL
- **Audit is mandatory** - Always run checks and show report before merge decision
- **User approval required** - Never auto-merge without asking
- **Submodules are skipped** - Use `/commit-all` for full workflow including submodules
- **Stack auto-detection** - Checks are tailored to detected stacks (React, NestJS, WordPress plugin)
- **After merging PR** - Delete the branch to keep repo clean
