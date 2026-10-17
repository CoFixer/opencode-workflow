---
name: "promote-dev-to-main"
description: "Opens a production PR from dev to main, verifies CI, asks for explicit confirmation, merges it without deleting dev, and can tag the release. Invoke when user says '/skill:promote-dev-to-main'."
---

# Promote Dev → Main (Production Release)

Promotes the verified `dev` branch into `main`:

```
dev (verified) -> release PR -> CI checks -> explicit confirmation
               -> merge into main -> optional tag -> dev + main kept
```

Full pipeline:

```
feature branches -> staging -> dev -> main
```

## When to use

- The user says `/skill:promote-dev-to-main`
- A release candidate in `dev` is ready for production
- A previous release PR failed CI or timed out and needs a retry
- You need to merge an already-open `dev -> main` PR (`-Resume`)

## Hard rules

- **Ask the user for explicit approval before merging to `main`** — never assume it
- **Never delete `dev` or `main`**
- Never commit directly to `dev` or `main`
- Never force-push `main`
- Never merge while checks are failing
- Never tag a release that did not merge
- Stop and report if migrations or breaking changes are present without a stated plan
- Do not bypass branch protection unless the user explicitly instructs it

## Step 1 — Pre-flight review

```powershell
git fetch origin --prune
git log --oneline origin/main..origin/dev
git diff --stat origin/main...origin/dev
git diff --name-only origin/main...origin/dev
```

Stop and ask the user when you see:

| Signal | Why |
| --- | --- |
| `**/migrations/**` or schema-changing `*.entity.ts` | Production data risk |
| `!:` commit subject or `BREAKING CHANGE` | API/contract break |
| `.github/workflows/**` | Release/CI behaviour changes |
| `.env.example`, `docker-compose*` | Deployment config changes |
| `origin/main` ahead of `origin/dev` | Hotfix drift; sync main back into dev |

The script also warns about migrations and blocks on merge conflicts.

## Step 2 — Confirm with the user (mandatory)

Use the `question` tool (or plain chat) and require an unambiguous answer:

> Merge `dev` into `main` and release? This affects production.
> - PR: `<url>`
> - Commits: `<n>` · Files: `<n>`
> - Migrations: `<yes/no>` · Breaking changes: `<yes/no>`

Only after an explicit yes may you run with `-Yes`. The script itself also
requires typing `MERGE` when `-Yes` is absent.

## Step 3 — Run the promotion

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .opencode/skills/promote-dev-to-main/run-promotion.ps1 -Yes
```

With a release tag:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .opencode/skills/promote-dev-to-main/run-promotion.ps1 -Yes -Tag v1.4.0
```

| Switch | Purpose |
| --- | --- |
| `-DryRun` | Show the generated release notes and plan, touch nothing |
| `-Resume` | Re-attach to the open release PR, wait, and merge |
| `-NoWait` | Create the PR and return immediately |
| `-Yes` | Skip the interactive confirmation (only after user approval) |
| `-Title "..."` | Override the generated title |
| `-ShowBody` | Print the generated release notes during `-DryRun` |
| `-Tag v1.4.0` | Create + push an annotated tag on `main` after merge |
| `-MergeMethod merge` | Default; keeps `dev` as an ancestor of `main` |
| `-MaxWaitMinutes 15` | Bounded CI wait |
| `-StuckAfterMinutes 5` | When to trigger CI recovery |
| `-RunBuildGates` | Also run local gates on a clean `dev` checkout |
| `-SkipTests` / `-AllowCheckTimeout` | Only for verified CI outages |

> **Tool timeout:** the script waits for CI. Run it with a generous timeout
> (`timeout: 0`) or use `-NoWait` + `-Resume -Yes`.

## Step 4 — Title and release notes

**Title** (auto, unless `-Title` is passed):
- single commit → that subject, e.g. `fix(backend): repair nightly bed charge`
- multiple commits → `release: <top feat/fix summary> (+N more)`
- long or mixed → `release: promote dev to main (N files)`

**Body** always includes:
- base/head SHAs, file and commit counts
- **Breaking changes** section (when `!:` commits exist)
- release notes grouped as Features / Fixes / Performance / Other changes
- affected areas + diffstat
- migration/schema file list when present
- production deployment checklist
- promotion semantics (dev and main kept, merge method, tag)
- rollback (pre-merge SHA, `git revert -m 1`, tag deletion)

## Step 5 — Handle the exit code

| Exit | Meaning | Required action |
| --- | --- | --- |
| `0` | Merged / nothing to promote / PR created with `-NoWait` | Report |
| `1` | Unexpected failure | Fix the reported state and re-run |
| `2` | Local gate failed (`-RunBuildGates`) | Fix through the staging pipeline, then retry |
| `3` | CI failed or PR closed | Fix through the staging pipeline, then `-Resume` |
| `4` | CI still running / stalled | Wait, then `-Resume -Yes` |
| `5` | Merge blocked or conflict | Resolve, then `-Resume -Yes` |
| `6` | Confirmation missing/declined | Ask the user, then re-run with `-Yes` |

### CI failed (exit 3)

Never fix `main` or `dev` directly. Route the fix through the pipeline:

1. Inspect:
   ```powershell
   gh pr checks <pr-number>
   gh run list --branch dev --limit 5
   gh run view <run-id> --log-failed
   ```
2. Fix with `/skill:execute-staging-pr-workflow`
3. Promote with `/skill:promote-staging-to-dev`
4. Re-run this skill with `-Resume -Yes` (same PR reused)

### CI stalled (exit 4)

The script automatically:
- waits 90 s for checks to register
- detects a pending set unchanged for `-StuckAfterMinutes`
- re-runs failed workflow runs (`gh run rerun --failed`)
- cancels + re-runs jobs stuck in `queued`
- runs `gh pr update-branch` when the PR is `BEHIND`

If it still times out, check the run URLs and retry:

```powershell
gh pr checks <pr-number>
powershell -File .opencode/skills/promote-dev-to-main/run-promotion.ps1 -Resume -Yes
```

### Merge blocked (exit 5)

- `CONFLICTING` / `DIRTY` → the script stops before creating the PR; merge `main`
  back into `dev` through the staging pipeline, then retry
- `BLOCKED` (review required) → obtain approval, then `-Resume -Yes`
- `BEHIND` → handled automatically; otherwise `gh pr update-branch <pr>`

### Confirmation missing (exit 6)

Ask the user explicitly; never auto-approve a production merge.

## Step 6 — After the merge

The script:
- keeps `dev` and `main`
- fetches with `--prune`
- updates local `main` only when it is the current branch and clean
- creates and pushes the tag when `-Tag` was supplied and the PR merged

It does **not**:
- delete `dev`, `main`, or `staging`
- merge `main` back into `dev` (do that manually if `main` received hotfixes)
- deploy anything

## Output to user

Return:
- PR URL + number and the title used
- commits/files released, affected areas
- migrations / breaking changes present (yes/no)
- CI result (`PASSED / FAILED / NO_CHECKS / TIMEOUT`)
- merge result (`MERGED / AUTO_MERGE_ENABLED / NOT_MERGED`)
- tag created (or `none`)
- confirmation that `dev` and `main` were kept
- on failure: exit code, failing command, and next action
