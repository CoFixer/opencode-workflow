# OpenCode Base

Framework documentation, guides, and workspace configuration for the OpenCode agent workflow.

## Contents

- `settings.json` — Workspace configuration (skills, agents, prompts, guides, docs)
- `docs/` — Framework documentation and checklists
- `guides/` — Setup guides (Google OAuth, PM2, etc.)

## Workspace Config

The `settings.json` file wires up:
- **Skills**: `../skill-rules.json` (auto-activate on trigger)
- **Agents**: `../agents/agent-manifest.json`
- **Prompts**: `../prompts/` directory
- **Guides**: Backend, frontend, mobile, and base guides
- **Docs**: Framework docs and checklists

## Integration

All paths are relative to the `.opencode/` root. The shared project hub is at `.project/`.
