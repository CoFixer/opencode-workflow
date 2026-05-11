---
name: opencode-workspace
description: Project-specific AI workflow system for OpenCode agents.
---

# .opencode Workflow

A project-specific workflow system for OpenCode agents, modeled after `.claude`, `.kimi`, and `.pi` but optimized for OpenCode's capabilities.

## Directory Structure

```
.opencode/
├── README.md                    # This file
├── settings.json                # Workspace settings (reference only)
├── skill-rules.json             # Skill activation rules (reference only)
├── prompts/                     # Reusable prompt templates (60+)
├── commands/                    # OpenCode custom commands (Ctrl+K)
│   ├── new-project.md
│   ├── init-workspace.md
│   ├── init-harness.md
│   ├── fullstack.md
│   ├── commit.md
│   ├── find-gaps.md
│   ├── fix-gaps.md
│   ├── generate-docs.md
│   ├── generate-prd.md
│   ├── reflect.md
│   └── ... and 50+ more
├── skills/                      # Project-level skills
│   ├── dev/
│   │   ├── commit/
│   │   ├── create-dev-pr/
│   │   ├── find-gaps/
│   │   ├── fix-gaps/
│   │   ├── generate-docs/
│   │   ├── generate-ouroboros/
│   │   ├── review-tickets/
│   │   ├── run-fullstack/
│   │   └── meta/
│   │       └── reflect/
│   ├── operation/
│   │   ├── generate-invoice/
│   │   ├── generate-ppt/
│   │   ├── generate-prd/
│   │   └── generate-proposal/
│   └── qa/
│       └── run-playwright/
├── agents/                      # Shared agents (30+)
│   ├── agent-manifest.json
│   ├── analysis/                # Code review, gap analysis
│   ├── development/             # Backend, frontend, mobile devs
│   ├── documentation/           # Doc generation agents
│   ├── orchestration/           # Project coordinator
│   ├── quality/                 # QA agents
│   └── testing/                 # Playwright QA agent
├── backend/                     # NestJS-specific workspace
│   ├── guides/                  # Backend dev guides (25+)
│   └── agents/                  # Backend-specific agents
├── frontend/                    # React-specific workspace
│   ├── guides/                  # Frontend dev guides (14+)
│   └── agents/                  # Frontend-specific agents
├── mobile/                      # React Native workspace
│   ├── guides/                  # Mobile dev guides
│   └── agents/                  # Mobile-specific agents
├── hooks/                       # Automation hooks
│   ├── auto-reflect.sh
│   ├── status-auto-updater.sh
│   └── skill-activation-prompt.sh
├── base/                        # Base templates and docs
│   ├── docs/
│   ├── guides/
│   └── templates/
├── guides/                      # Quick-reference guides
└── memory/                      # Framework-specific state
    ├── DECISIONS.md
    ├── LEARNINGS.md
    └── PREFERENCES.md
```

## How It Works

### Skills

OpenCode auto-discovers `SKILL.md` files under `.opencode/skills/` (and other framework skill dirs). These skills are exposed via the built-in **`skill`** tool.

**To invoke a skill, type in chat:**
- `/skill:<name>` — e.g. `/skill:commit`
- `/<name>` — shorthand, e.g. `/commit`

The AI will automatically call the `skill` tool and load the skill instructions.

| Skill | Command | Purpose |
|-------|---------|---------|
| `commit` | `/commit` or `/skill:commit` | Git commit & PR workflow |
| `create-dev-pr` | `/create-dev-pr` | Create PR to dev branch |
| `find-gaps` | `/find-gaps` | Find implementation gaps |
| `fix-gaps` | `/fix-gaps` | Fix identified gaps |
| `generate-docs` | `/generate-docs` | Generate API & knowledge docs |
| `generate-ouroboros` | `/generate-ouroboros` | Validate PRD specs |
| `review-tickets` | `/review-tickets` | Review Notion tickets |
| `run-fullstack` | `/run-fullstack` | Full-stack dev pipeline |
| `reflect` | `/reflect` | Session reflection |
| `generate-prd` | `/generate-prd` | Generate PRD from input |
| `generate-ppt` | `/generate-ppt` | Generate HTML presentations |
| `generate-proposal` | `/generate-proposal` | Generate client proposals |
| `generate-invoice` | `/generate-invoice` | Generate invoices |
| `run-playwright` | `/run-playwright` | Run Playwright E2E tests |

### Custom Commands (Ctrl+K)

Project commands are also available via the **Command Dialog** (`Ctrl+K`):

- `project:commit`
- `project:find-gaps`
- `project:fix-gaps`
- `project:generate-docs`
- `project:run-fullstack`
- `project:reflect`
- `project:review-tickets`
- `project:run-playwright`

Commands live in `.opencode/commands/*.md`. Each file becomes a command whose content is sent as a prompt.

### Agents
Agents are specialized roles for complex tasks. Register them in `agents/agent-manifest.json`:

**Development Agents:**
- `backend-developer` — NestJS specialist
- `frontend-developer` — React specialist
- `mobile-developer` — React Native specialist
- `api-integration-agent` — API integration specialist
- `database-designer` — Database schema designer
- `fullstack-agent` — Full-stack coordinator

**Analysis Agents:**
- `code-architecture-reviewer` — Architecture review
- `gap-finder` — Find implementation gaps
- `gap-fixer` — Fix gaps
- `automation-scout` — Detect automation opportunities
- `learning-extractor` — Extract learnings
- `followup-suggester` — Suggest follow-ups

**Quality Agents:**
- `quality-lead` — Quality oversight
- `auto-error-resolver` — Auto fix errors
- `reviewer` — General reviewer

**Documentation Agents:**
- `doc-updater` — Sync docs
- `prd-converter` — PRD to spec

**Orchestration:**
- `project-coordinator` — Multi-agent orchestration

**Testing:**
- `playwright-qa-agent` — E2E test execution

### Prompts
Reusable prompt templates for common tasks (60+ prompts):
- `new-project` — New project setup
- `init-workspace` — Initialize .project folder
- `init-harness` — Init session harness
- `fullstack` — Full-stack development
- `commit` — Git commit workflow
- `find-gaps` — Find gaps
- `fix-gaps` — Fix gaps
- `generate-docs` — Generate documentation
- `generate-prd` — Generate PRD
- `reflect` — Session reflection
- ... and 50+ more in `prompts/`

## Usage Examples

```
/skill:commit
/skill:find-gaps
/skill:generate-docs
/skill:run-fullstack
Run the backend-developer to implement this API
Run the project-coordinator to plan this feature
Run the playwright-qa-agent to test this flow
Use the fullstack prompt
```

## Creating New Skills

1. Create folder: `skills/{category}/{skill-name}/`
2. Add `SKILL.md` with frontmatter:
   ```markdown
   ---
   name: skill-name
   description: What this skill does and when to use it
   ---
   ```
3. OpenCode will auto-discover the skill on next restart
4. Invoke with `/skill:skill-name` or `/<skill-name>`

## Creating New Commands

1. Create file: `commands/{command-name}.md`
2. Write the prompt text that should be sent to the AI
3. Invoke via `Ctrl+K` → select `project:{command-name}`

## Creating New Agents

1. Create file: `agents/{category}/{agent-name}.md`
2. Add frontmatter with role and tags
3. Register in `agents/agent-manifest.json`
4. Invoke with: "Run the {agent-name} to..."

## Integration with .project

All three frameworks (`.claude`, `.pi`, `.kimi`, `.opencode`) share `.project/`:
- `.project/docs/` — Technical docs
- `.project/memory/` — Decisions, learnings
- `.project/status/` — Implementation status
- `.project/prd/` — Product requirements

**Rule**: Always update `.project/memory/DECISIONS.md` when making architectural choices, and `.project/memory/LEARNINGS.md` when discovering reusable patterns.

## Cross-Framework Conventions

| Action | Claude | Pi | Kimi | OpenCode |
|--------|--------|-----|------|----------|
| Create full project | `/new-project` | `/new-project` | `/new-project` | `/new-project` |
| Init docs only | `/init-workspace` | `/init-workspace` | `/init-workspace` | `/init-workspace` |
| Init session harness | `/init-harness` | `/init-harness` | `/init-harness` | `/init-harness` |
| Run fullstack loop | `/fullstack` | `/fullstack` | `/skill:run-fullstack` | `/skill:run-fullstack` |
| Commit & PR | `/commit` | — | `/skill:commit` | `/skill:commit` |
| Find gaps | `/find-gaps` | `/find-gaps` | `/skill:find-gaps` | `/skill:find-gaps` |
| Fix gaps | `/fix-gaps` | `/fix-gaps` | `/skill:fix-gaps` | `/skill:fix-gaps` |
| Generate docs | `/generate-docs` | `/generate-docs` | `/skill:generate-docs` | `/skill:generate-docs` |
