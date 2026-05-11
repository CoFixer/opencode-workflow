---
description: Fix implementation gaps found by the gap analysis
argument-hint: Optional specific gap ID or file to fix
---

Run the fix-gaps skill to resolve gaps identified by the find-gaps analysis.

Workflow:
1. Read the latest gap analysis report from `.project/status/`
2. Prioritize critical and high-severity gaps
3. Implement fixes with minimal, focused changes
4. Follow existing code patterns and conventions
5. Update tests if needed
6. Mark gaps as resolved in status tracking

Always verify fixes don't introduce regressions.
