# Preferences

Code-style and workflow preferences for OpenCode agents.

## Code Style

### TypeScript
- Use strict mode
- Prefer interfaces over types for objects
- Use explicit return types on exported functions
- Avoid `any` - use `unknown` with type guards

### React
- Use functional components with hooks
- Co-locate related components
- Extract reusable logic into custom hooks
- Use React Query for server state

### NestJS
- Use dependency injection
- Keep controllers thin, services fat
- Use DTOs for all inputs
- Add Swagger decorators to all endpoints

## Workflow Preferences

### Before Starting Work
1. Read relevant `.project/docs/` files
2. Check `.project/status/` for current state
3. Update status to "in_progress"

### After Completing Work
1. Run type checks and builds
2. Update `.project/status/` files
3. Write to `.project/memory/LEARNINGS.md` if patterns discovered
4. Write to `.project/memory/DECISIONS.md` if architectural choices made

### Communication
- Report file names that were changed
- Summarize what was done in 1-2 sentences
- Flag any issues that need human attention
