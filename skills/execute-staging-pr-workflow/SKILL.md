---
name: "execute-staging-pr-workflow"
description: "Creates the staging branch when missing, runs build/typecheck gates (fixing failures before committing), ships a feature or bug branch as a PR into staging, recovers stalled CI, merges it, and clears merged feature branches. Invoke when user says '/skill:execute-staging-pr-workflow'."
---

# Execute Staging PR Workflow

Ships work into the **`staging`** integration branch, end to end:

```
changes -> create staging (if missing) -> build/typecheck -> feature branch
        -> commit + push -> PR to staging -> CI checks -> squash merge
        -> delete feature branch -> prune merged feature branches
```

This is the same shape as `execute-pr-workflow`, but the PR lands in `staging`
instead of `dev`. `dev` only receives work through `promote-staging-to-dev`.

## When to use

- The user says `/skill:execute-staging-pr-workflow`
- A feature or bug fix is complete and should be integrated into `staging`
- CI on an existing staging PR failed and it needs a follow-up fix + merge
- You need to re-attach to an open staging PR and merge it later (`-Resume`)

## Hard rules

- Stop and ask if there is nothing to commit and no open PR to resume
- Never commit secrets: `.env*`, `*.pem`, `*.key`, credentials/secret JSON
- Never stage `.opencode`, `.commandcode`, or `.gitmodules` pointers
- Never commit directly to `staging`, `dev`, or `main`
- Never merge while build/typecheck is failing
- Never use `-SkipBuild` to bypass a real type/build error — only for a verified tooling failure
- Never force-push
- Do not touch `main`; this skill stops at `staging`

## Step 1 — Verify the starting point

```powershell
git status --porcelain
git branch --show-current
git log --oneline -5
```

- Uncommitted work is expected; the script stashes and re-applies it.
- If the current branch already has an open PR into `staging`, the script
  **reuses that branch** instead of creating a new one (safe re-runs).

## Step 2 — Derive a logical title (and pass it in)

The script derives a fallback subject, but **always prefer a specific,
human-meaningful subject** based on the diff:

```powershell
git diff --stat
git diff --cached --stat
git diff --name-only
```

Title pattern: `<type>(<scope>): <imperative summary>`
- `type`: `feat | fix | refactor | docs | test | chore`
- `scope`: `backend | frontend | dashboard | print-agent | mobile` (comma-join when split)
- Summary: what changed and why, ≤ 72 chars, no "automated changes", no "update files"

Good:
- `feat(backend): add nightly bed-charge refresh for active admissions`
- `fix(frontend,dashboard): stop duplicate invoice totals after refund`
- `refactor(backend): extract backup destination validation into a policy`

Bad:
- `feat(backend): automated changes`
- `chore: update files`
- `fix: bug fix`

If the user supplied a message, pass it through unchanged.

## Step 3 — Run the workflow

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .opencode/skills/execute-staging-pr-workflow/run-workflow.ps1 `
  -CommitMessage "feat(backend): add nightly bed-charge refresh"
```

Useful switches:

| Switch | Purpose |
| --- | --- |
| `-DryRun` | Print the plan, touch nothing |
| `-Resume` | Re-attach to the open PR for the current branch (or `-CustomBranchName`) and merge it |
| `-NoWait` | Create the PR and return immediately (avoids long-running shells) |
| `-AutoFix` | Run `lint:fix`/`format` and retry the failing gate once |
| `-MaxWaitMinutes 15` | Bounded CI wait (default 15) |
| `-StuckAfterMinutes 5` | When to trigger CI recovery |
| `-AllowCheckTimeout` | Merge even if checks are still pending (avoid) |
| `-SkipBuild` / `-SkipTests` | Only for verified tooling/CI outages |
| `-NoPruneMergedBranches` | Keep other merged branches |

> **Tool timeout:** the script waits for CI. Run it with a generous timeout
> (`timeout: 0`) or use `-NoWait` first and `-Resume` later. Never kill it
> mid-merge.

## Step 4 — Handle the exit code (fix loops)

The script is idempotent: re-running it after a fix commits the follow-up to the
same branch and reuses the open PR.

| Exit | Meaning | Required action |
| --- | --- | --- |
| `0` | Merged, or PR created with `-NoWait` | Report result |
| `1` | Unexpected failure | Read the message; fix auth/repo state; re-run |
| `2` | **Build/typecheck failed** | Enter the **fix loop** below |
| `3` | **CI failed / PR closed** | Enter the **CI fix loop** below |
| `4` | **CI still running / stalled** | Wait, then re-run with `-Resume` |
| `5` | **Merge blocked** | Resolve protection/conflict, then `-Resume` |

### Fix loop (mandatory, max 3 attempts)

**Never hand exit code 2 back to the user without attempting this loop.**

1. Read the failing package + script from the output.
2. Reproduce locally with the exact command:
   ```powershell
   cd backend; bun run build
   cd frontend; bun run build
   cd dashboard; bun run build
   ```
3. Fix the **source** — do not weaken `tsconfig`, disable lint rules, add `@ts-ignore`,
   or delete failing tests to get green.
4. Re-run the command until it passes.
5. Re-run the skill. Nothing was committed, so this is safe.
6. Only after 3 failed attempts, stop and report the exact error + files touched.

`-AutoFix` handles mechanical issues (formatting, auto-fixable lint). It is not a
substitute for the loop above.

### CI fix loop (exit 3, max 3 attempts)

1. Inspect the failure:
   ```powershell
   gh pr checks <pr-number>
   gh run list --branch <branch> --limit 5
   gh run view <run-id> --log-failed
   ```
2. Fix the underlying code/test (same rules as the fix loop).
3. Re-run the skill with `-Resume`. It commits the fix to the same branch,
   pushes, waits for the re-run, then merges.

Do **not** open a second PR for the same fix.

### Stalled CI (exit 4)

The script already:
- waits 90 s for checks to register before treating CI as absent
- detects "no progress" (same pending set for `-StuckAfterMinutes`)
- re-runs failed workflow runs (`gh run rerun --failed`)
- cancels + re-runs jobs stuck in `queued`
- runs `gh pr update-branch` when the PR is `BEHIND`

If it still times out, the PR is left open. Check the runs, then:

```powershell
# once CI is green (or genuinely stuck)
powershell -File .opencode/skills/execute-staging-pr-workflow/run-workflow.ps1 `
  -CustomBranchName <branch> -Resume
```

If no checks ever appear, workflows may not watch `staging` yet. Either add
`staging` to `.github/workflows/*.yml` `pull_request.branches`, or run with
`-SkipTests` **after** local gates pass.

### Merge blocked (exit 5)

- `CONFLICTING` → resolve on the feature branch, push, `-Resume`
- `BLOCKED` (review required) → get the approval, then `-Resume`
- `BEHIND` → the script updates the branch automatically; if it still fails, run
  `gh pr update-branch <pr>` and `-Resume`

## PR title and body

Titles follow Conventional Commits and are generated from the actual diff
(see Step 2). The body always contains:

```markdown
## Summary            <- subject + per-area file counts + key modules
## Change type        <- feat / fix / refactor / docs / test / chore
## Affected areas     <- backend / frontend / dashboard / ...
## Validation         <- exact typecheck/build commands that passed
## Branching          <- base: staging, head: <branch>, commit: <sha>
## Files changed      <- up to 50 files, then "... and N more"
## Rollback           <- git revert <sha> on staging
```

## What gets cleaned up

- The merged feature branch: remote via `gh pr merge --delete-branch`, local via `git branch -D`
- Other **merged** feature branches matching `feat|fix|refactor|docs|test|chore|release|hotfix`
  whose tip is older than `-PruneOlderThanHours` (default 24 h)
- `staging`, `dev`, `main`, `master`, `develop` are never deleted

## Output to user

Return:
- whether `staging` was created
- branch name + commit SHA + subject
- PR URL and PR number
- CI result (`PASSED / FAILED / NO_CHECKS / TIMEOUT`)
- merge result (`MERGED / AUTO_MERGE_ENABLED / NOT_MERGED`)
- cleanup counts
- on failure: the exact exit code, failing command, and next action
