---
description: Generate and update project documentation (API, database, knowledge)
argument-hint: Optional doc type to generate (api, database, knowledge, all)
---

Run the generate-docs skill to update project documentation based on the current codebase.

Generates:
- `PROJECT_API.md` — API endpoint specs from backend controllers and DTOs
- `PROJECT_DATABASE.md` — Schema, ERD, and table definitions from TypeORM entities
- `PROJECT_KNOWLEDGE.md` — Architecture, tech stack, and terminology
- `AGENTS.md` — Agent context and project conventions

Reads from:
- Backend NestJS modules, controllers, DTOs, entities
- Frontend React routes, components, services
- `.project/prd/` for requirements baseline

Writes to:
- `.project/docs/`
