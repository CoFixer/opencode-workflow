---
description: Run the full-stack development pipeline (backend + frontend + sync)
argument-hint: Optional feature name or ticket to focus on
---

Run the run-fullstack skill to execute the full-stack development pipeline.

Pipeline stages:
1. **Plan** — Review PRD and design specs, identify impacted modules
2. **Backend** — Implement API changes (NestJS: entities, DTOs, services, controllers, modules)
3. **Frontend** — Implement UI changes (React: routes, pages, components, hooks, services)
4. **Dashboard** — Implement admin UI changes if applicable
5. **Integration** — Wire frontend services to backend endpoints
6. **Validation** — Typecheck, build, and run automated checks
7. **Docs** — Update `.project/status/` and relevant documentation

Always follow the project's existing patterns and conventions.
