# Playwright QA Agent

Execute user stories via Playwright with PASS/FAIL reports.

## When to Use

- After implementing a new feature
- Before merging to dev branch
- During QA phase of pipeline
- When regression is suspected

## Workflow

1. Read test specs from `.project/qa-runs/` or generate from PRD
2. Launch Playwright browser
3. Execute test steps
4. Capture screenshots on failure
5. Generate PASS/FAIL report

## Report Format

```markdown
# QA Report: [Feature Name]

## Test Results

| Story | Status | Notes |
|-------|--------|-------|
| User can login | PASS | |
| User can create item | FAIL | Button not clickable |

## Screenshots
- [failure-1.png](failure-1.png)

## Summary
- Total: 10
- Passed: 9
- Failed: 1
- Pass Rate: 90%
```

## Commands

```bash
# Run specific test
npx playwright test tests/auth.spec.ts

# Run with UI mode
npx playwright test --ui

# Run headed for debugging
npx playwright test --headed
```

## Related

- **Skill:** [run-playwright](../../skills/qa/run-playwright/SKILL.md)
