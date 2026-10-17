---
name: "promote-staging-to-dev"
description: "Opens a PR from staging to dev, waits for CI checks with stall recovery, and merges it without deleting the staging branch. Invoke when user says '/skill:promote-staging-to-dev'."
---

# Promote Staging → Dev

Promotes the integrated `staging` branch into `dev`:

```
staging (verified) -> promotion PR -> CI checks -> merge into dev
                                              -> staging branch kept
```

This is the second gate of the release pipeline:

```
feature branches -> staging -> dev -> main
```

## When to use

- The user says `/skill:promote-staging-to-dev`
- `staging` contains work that must reach `dev`
- A previous promotion PR failed CI or timed out and needs a retry
- You need to merge an already-open `staging -> dev` PR (`-Resume`)

## Hard rules

- **Never delete `staging`** after merging (no `--delete-branch`)
- **Never delete `dev`**
- Never commit directly to `staging` or `dev`
- Never force-push `staging` or `dev`
- Never merge while checks are failing
- Only promote content that already passed the staging workflow
- Prompt the user before merging if the PR includes migrations or breaking changes

## Step 1 — Verify the starting point

```powershell
git fetch origin --prune
git log --oneline origin/dev..origin/staging
git diff --stat origin/dev...origin/staging
git branch -r --list "origin/staging" "origin/dev"
```

- If `origin/staging` is missing, run `execute-staging-pr-workflow` first.
- If the diff is empty, there is nothing to promote — stop.
- If `dev` is ahead of `staging`, that is fine; the merge commit preserves `dev`.
  Mention it in the PR body (the script does).

## Step 2 — Confirm scope (migrations / breaking changes)

Scan the commit subjects and the diff before opening the PR:

```powershell
git log --oneline --no-merges origin/dev..origin/staging
git diff --name-only origin/dev...origin/staging
```

Flag and ask about:
- new/changed migrations (`**/migrations/**`, `*.entity.ts` with schema changes)
- `!:` commits or `BREAKING CHANGE` in the body
- env/config changes (`.env.example`, `docker-compose.yml`, CI workflows)

## Step 3 — Run the promotion

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .opencode/skills/promote-staging-to-dev/run-promotion.ps1
```

| Switch | Purpose |
| --- | --- |
| `-DryRun` | Show the generated title/body and planned merge, touch nothing |
| `-Resume` | Re-attach to the open promotion PR, wait, and merge |
| `-NoWait` | Create the PR and return immediately |
| `-Title "..."` | Override the generated title |
| `-ShowBody` | Print the generated PR body during `-DryRun` |
| `-MergeMethod merge` | Default; `squash` also supported |
| `-MaxWaitMinutes 15` | Bounded CI wait |
| `-StuckAfterMinutes 5` | When to trigger CI recovery |
| `-RunBuildGates` | Also run local gates (only when on a clean `staging` checkout) |
| `-SkipTests` | Only for verified CI outages |
| `-AllowCheckTimeout` | Merge while checks are pending (avoid) |

> **Tool timeout:** the script waits for CI. Run it with a generous timeout
> (`timeout: 0`) or use `-NoWait` + `-Resume`.

## Step 4 — Title and body

The script generates a release-style PR:

**Title** (auto, unless `-Title` is passed):
- single commit → that commit's subject, e.g. `feat(backend): add bed charge refresh`
- multiple commits → `release: <top feat/fix summary> (+N more)`
- long or mixed → `release: promote staging to dev (N files)`

**Body** always contains:
- base/head SHAs and the number of files/commits
- highlights (up to 3 feature/fix/refactor commits)
- full commit table (newest first, capped at 30)
- affected areas with file counts
- diffstat
- validation checklist
- promotion semantics (`staging` kept, merge method)
- rollback (`git revert -m 1 <merge-sha>`, pre-merge SHA)

Example title/body:

```
release: add bed charge refresh + payment reconciliation (+4 more)
```

```markdown
## Promotion: `staging` -> `dev`
- Base `dev` at `5140876`
- Head `staging` at `9ab31c2`
- 42 file(s) changed, 5 commit(s) ahead
...
```

## Step 5 — Handle the exit code

| Exit | Meaning | Required action |
| --- | --- | --- |
| `0` | Merged / nothing to promote / PR created with `-NoWait` | Report |
| `1` | Unexpected failure | Fix the reported state and re-run |
| `2` | Local gate failed (`-RunBuildGates`) | Fix code through `execute-staging-pr-workflow`, then retry |
| `3` | CI failed or PR closed | Fix through staging, then `-Resume` |
| `4` | CI still running / stalled | Wait, then `-Resume` |
| `5` | Merge blocked | Resolve conflict/protection, then `-Resume` |

### CI failed (exit 3)

The promotion PR **must not** be fixed by pushing directly to `staging`. Fix it
the normal way:

1. Inspect logs:
   ```powershell
   gh pr checks <pr-number>
   gh run list --branch staging --limit 5
   gh run view <run-id> --log-failed
   ```
2. Fix via the feature pipeline:
   ```powershell
   /skill:execute-staging-pr-workflow
   ```
3. Re-run the promotion with `-Resume` (same PR is reused).

### CI stalled (exit 4)

Before timing out, the script automatically:
- waits 90 s for checks to register
- detects a pending set that has not changed for `-StuckAfterMinutes`
- re-runs failed workflow runs (`gh run rerun --failed`)
- cancels + re-runs jobs stuck in `queued`
- runs `gh pr update-branch` when the PR is `BEHIND`

If it still times out, inspect and retry:

```powershell
gh pr checks <pr-number>
powershell -File .opencode/skills/promote-staging-to-dev/run-promotion.ps1 -Resume
```

### Merge blocked (exit 5)

- `CONFLICTING` / `DIRTY` → merge `dev` into `staging` via a feature branch, then retry
- `BLOCKED` (review required) → obtain the approval, then `-Resume`
- `BEHIND` → handled automatically; otherwise `gh pr update-branch <pr>`

## Step 6 — After the merge

The script:
- keeps `staging` and `dev`
- fetches with `--prune`
- updates local `dev` only when it is the current branch and clean

It does **not** merge `staging` back into `dev` or vice versa, and does not tag
releases. Production promotion is a separate skill (`promote-dev-to-main`).

## Output to user

Return:
- PR URL + number
- title used
- commits/files promoted and affected areas
- CI result (`PASSED / FAILED / NO_CHECKS / TIMEOUT`)
- merge result (`MERGED / AUTO_MERGE_ENABLED / NOT_MERGED`)
- confirmation that `staging` was kept
- on failure: exit code, failing command, and next action
