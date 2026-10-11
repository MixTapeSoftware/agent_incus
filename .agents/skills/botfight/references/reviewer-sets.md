# Reviewer sets

Named lists of review briefs for `/botfight reviewer --set <name> [<PR>] [<interval> <duration>]`. Each brief is an ordinary reviewer brief: it gets its own `scope_id` (the SHA-256 of the exact text below, without a trailing newline) and its own completed-review record, so the reviewers do not satisfy one another's checks. Changing a brief's wording changes its `scope_id`, so treat edits as a new review scope.

Run each brief as its own reviewer: a separate session per brief when it should keep watching the PR, or one sub-agent per brief when a single pass per head is enough. Every reviewer follows [reviewer.md](reviewer.md) unchanged and posts its own `COMMENT` review.

## standard

1. `code quality gate based on stated project preferences, FastAPI and Next.js best practices`
2. `security review focused on RLS and service-role use, auth and IDOR, service-to-service auth, secrets, migrations, CORS and customer geodata`
3. `UI and UX polish: accessibility, keyboard and screen-reader use, responsive layout, loading, empty and error states, copy, and consistent use of Radix Themes`
