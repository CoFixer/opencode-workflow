---
description: Run Playwright E2E tests for the frontend and dashboard
argument-hint: Optional test file, tag, or URL to focus testing on
---

Run the run-playwright skill to execute Playwright end-to-end tests.

Test scopes:
- `frontend/test/` — User dashboard tests
- `dashboard/test/` — Admin dashboard tests

Commands:
- Run all tests: `npx playwright test`
- Run specific file: `npx playwright test tests/auth/login.spec.ts`
- Run with UI: `npx playwright test --ui`
- Run in headed mode: `npx playwright test --headed`

Report results with PASS/FAIL status, screenshots for failures, and actionable fixes.
