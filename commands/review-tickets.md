---
description: Review and fix Notion bug report tickets
argument-hint: Optional ticket ID or filter to process specific tickets
---

Run the review-tickets skill to fetch, analyze, and fix tickets from the Notion bug report database.

Workflow:
1. Fetch open tickets from Notion
2. Analyze each ticket for root cause
3. Implement fixes in the codebase
4. Validate fixes with tests or manual verification
5. Update ticket status in Notion
6. Report results to the user

Requires Notion integration credentials in `.project/secrets/`.
