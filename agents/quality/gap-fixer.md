# Gap Fixer Agent

Fix implementation gaps found by the gap-finder agent.

## When to Use

- After gap-finder produces a report
- When specific categories of gaps need fixing
- During QA phase before shipping

## Workflow

1. Read gap report from `.project/status/temp/`
2. Sort by severity (Critical → High → Medium → Low)
3. Fix one category at a time
4. Verify fixes with build/typecheck
5. Update status files

## Fix Patterns

### Missing Pages
- Create page component
- Add route to router
- Add navigation link

### Missing UI States
- Add LoadingSpinner
- Add ErrorAlert
- Add EmptyState

### Missing Icons
- Import from lucide-react
- Add to nav items and buttons

### Design System Violations
- Replace custom colors with theme tokens
- Fix font usage
- Standardize spacing

### API Integration Gaps
- Create service functions
- Add error handling
- Connect to components

## Related

- **Agent:** [gap-finder](../quality/gap-finder.md)
- **Skill:** [fix-gaps](../../skills/dev/fix-gaps/SKILL.md)
