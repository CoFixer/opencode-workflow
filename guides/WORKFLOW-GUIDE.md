# .opencode Workflow Guide

How to use the `.opencode` workflow system effectively.

## Quick Reference

### Skills

Skills activate automatically based on what you type:

| Skill | Trigger Keywords |
|-------|-----------------|
| commit | "commit", "git commit", "pull request" |
| gap | "gap", "missing", "incomplete", "find gaps" |
| fix | "fix gap", "implement missing" |
| feature | "implement feature", "build feature", "new feature" |
| review | "review code", "code review", "check quality" |
| docs | "generate docs", "update documentation" |

### Prompts

Reference prompts by name when starting a task:

```
"Use the debug prompt to investigate this error"
"Use the feature-spec prompt for this ticket"
```

Available prompts:
- `commit` - Git commit workflow
- `debug` - Systematic debugging
- `refactor` - Safe refactoring
- `feature-spec` - Feature implementation from spec

### Agents

Agents are specialized roles for complex tasks:

```
"Run the backend-agent to implement this API"
"Run the frontend-agent to build this page"
"Run the code-reviewer to check this PR"
```

## Directory Structure

```
.opencode/
├── skills/          # Auto-activating skills with rules
├── prompts/         # Reusable prompt templates
├── guides/          # Project-specific guides
├── agents/          # Specialized agent definitions
└── examples/        # Example outputs
```

## Best Practices

1. **Start with context**
   - Mention the package: backend, frontend, dashboard, plugin
   - Reference tickets or specs when available

2. **Use skills explicitly**
   - If a skill doesn't auto-activate, mention it by name
   - "Use the gap-finder skill on this module"

3. **Chain workflows**
   - feature-dev → gap-finder → gap-fixer → code-review → commit-workflow

4. **Reference guides**
   - Backend patterns → `.opencode/backend/guides/`
   - Project specs → `.project/docs/`
   - OpenCode workflows → `.opencode/guides/`

## Generic vs project-specific

Keep the submodule reusable:

| Belongs in `.opencode/` | Belongs in `.project/` |
|-------------------------|------------------------|
| Skills, agents, prompts, generic guides | Product requirements (`prd/`) |
| Framework patterns | Architecture, API, database docs (`docs/`) |
| Workflow templates | Status, gaps, traceability (`status/`) |
| Empty/generic config templates | Decisions, preferences (`memory/`) |
| Hooks and scripts | Visual prototypes (`resources/`) |

Rules:
- Never hardcode a project name, package list, port, route, or entity in `.opencode/`.
- Detect packages from the workspace config at runtime (see `skills/commit/SKILL.md`).
- If a workflow needs project facts, read them from `.project/docs/` instead of embedding them.
- `.opencode/base/settings.json` is a template; project values are supplied by the host project.

## Adding New Skills

1. Create folder: `.opencode/skills/{category}/{skill-name}/`
2. Add `SKILL.md` with frontmatter:
   ```markdown
   ---
   name: skill-name
   description: What this skill does
   ---
   ```
3. Register in `.opencode/skills/skill-rules.json`
4. Define trigger keywords and file patterns

## Extending Agents

1. Create file: `.opencode/agents/{category}/{agent-name}.md`
2. Define role, capabilities, and process
3. Invoke with: "Run the {agent-name} to..."
