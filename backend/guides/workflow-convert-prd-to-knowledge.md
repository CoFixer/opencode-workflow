# Workflow: Convert PRD → Project Knowledge

Generic workflow for turning a product requirements document into `.project/docs/PROJECT_KNOWLEDGE.md` (and the companion docs). Applies to any project using the `.opencode` workflow.

---

## Purpose

Give agents reliable product context without re-reading the PRD on every task. The knowledge doc captures architecture, roles, terminology, and constraints; the PRD remains the requirement source.

## Inputs

| Input | Path | Required |
|-------|------|----------|
| PRD index | `.project/prd/prd.md` | Yes (preferred) |
| PRD parts | `.project/prd/01-…` … `06-…` | Load only relevant parts |
| Original PDF | `.project/prd/prd.pdf` | Fallback only |
| Existing docs | `.project/docs/PROJECT_*.MD` | For iteration N |
| Implementation evidence | repo + `.project/status/` | For as-built accuracy |

> If the PRD is one large file, read it in sections. If it is split (recommended), read the index, then only the parts needed for the task.

---

## Iteration awareness

### Iteration 1 — initial
- Extract the full product context.
- Create `PROJECT_KNOWLEDGE.md` plus `PROJECT_API.md`, `PROJECT_DATABASE.md`, and the design guide.

### Iteration N — sync
1. Read the **existing** docs first.
2. Read the PRD index and the changed part(s).
3. Diff requirements against the docs and the code.
4. Update only what changed.
5. **Never overwrite as-built sections** (module map, env vars, security implementation) with PRD ideals.
6. Record deliberate deviations instead of hiding them.

---

## Execution steps

### 1. Read the PRD

```
Read .project/prd/prd.md
Read the relevant part file(s):
  01-product-strategy.md
  02-design-and-ux.md
  03-feature-specifications.md
  04-architecture-and-technical.md
  05-business-and-operations.md
  06-appendices.md
```

### 2. Extract categories

| Category | Look for |
|----------|----------|
| Product overview | Vision, problem, value proposition |
| Goals & metrics | KPIs, targets, success criteria |
| User types | Roles, permissions, personas |
| Terminology | Domain terms, acronyms |
| Architecture | Apps/services, stack, integration points |
| Screens/routes | Navigation, layouts, screen inventory |
| API | Endpoint groups, auth, payload shapes |
| Data model | Entities, relationships, enums |
| Design | Tokens, typography, components |
| Security | Auth, RBAC, confirmation rules, audit |
| Operations | Deployment, environments, monitoring |
| Business | Pricing, plans, roadmap |

### 3. Reconcile with the codebase

For every extracted item decide:

| State | Action |
|-------|--------|
| Matches implementation | Document once |
| PRD only (not built) | Mark as requirement/gap |
| Code only (not in PRD) | Mark as extension |
| Conflict | Document both + deviation + decision |

Do **not** invent missing values. Use `<!-- TODO: not found in PRD -->` and report it.

### 4. Write the docs

| File | Content |
|------|---------|
| `PROJECT_KNOWLEDGE.MD` | Overview, goals, roles, terminology, stack, architecture, modules, env, security, operations |
| `PROJECT_API.MD` | Conventions, auth, endpoint tables, request/response samples, contract deviations |
| `PROJECT_DATABASE.MD` | Tables, columns, enums, relationships, indexes, migrations |
| `PROJECT_DESIGN_GUIDELINES.MD` | Tokens, typography, spacing, components, motion, a11y |
| `PROJECT_API_INTEGRATION.MD` | Screen ↔ route ↔ endpoint mapping |
| `status/…/PRD_TRACEABILITY.MD` | Requirement → status → gap matrix |

Every doc starts with:
- Source(s) and date
- Authority order
- Link to related docs
- A short "how to use" note

### 5. Update status

- Mark each requirement `Implemented` / `Partial` / `Stub` / `Missing` / `Extension`.
- Cite evidence (file/module/route).
- Keep gap IDs (e.g. C1, M4) stable for cross-references.

### 6. Report

Summarize:
- Files created/updated
- Requirements not found in the PRD
- Conflicts and accepted deviations
- Top gaps / next actions

---

## Output shape (PROJECT_KNOWLEDGE)

```markdown
# Project Knowledge: {Project}

> Sources, date, authority order, traceability link

## Source of Truth
## PRD Alignment Summary   (surfaces, roles, naming deviations)
## Product Goals & Metrics
## Personas
## Overview
## User Types / RBAC
## Tech Stack
## Architecture
## Screen Inventory
## Key Decisions
## Known Gaps
## Terminology
## Environment Variables
## Security
## Operations
```

---

## Error handling

**PRD not found**
```
Error: no PRD at .project/prd/prd.md (or prd.pdf).
Place the file there or provide the path.
```

**Partial PRD**
- Generate what exists.
- Mark the rest `<!-- TODO: not found in PRD -->`.
- List missing sections in the report.

**Missing existing docs (iteration N)**
- Create from scratch.
- Flag that no baseline existed, so the diff is unknown.

**Code/docs conflict**
- Do not silently pick one.
- Document the conflict, the current behavior, and the recommended resolution.

---

## Example invocations

- "Update PROJECT_KNOWLEDGE from the PRD"
- "Sync the docs with the latest PRD part 04"
- "Regenerate the API and database docs from the PRD"
- "Build a PRD traceability matrix"

---

## Checklist

- [ ] Read the index before the parts
- [ ] Extracted all required categories
- [ ] Compared PRD against code
- [ ] Marked extensions vs gaps
- [ ] Preserved as-built sections
- [ ] Added sources + date to each doc
- [ ] Linked traceability matrix
- [ ] Reported conflicts and missing sections
- [ ] No project-specific values written into `.opencode/`
