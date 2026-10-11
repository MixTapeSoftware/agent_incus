---
name: catchup
description: Use when asked to summarize or catch up on the current branch's changes relative to main. This is read-only and does not modify the branch.
---

Review what has changed on the current branch compared to main:

1. Resolve the base ref: if an `origin` remote exists, run `git fetch origin main` and use `origin/main`, so a stale local `main` cannot skew the comparison. Otherwise, or if the fetch fails, use `main` if `git rev-parse --verify main` succeeds. If neither resolves, report that and stop.
2. Run `git diff <base>...HEAD` to see all changes since this branch diverged from main
3. Run `git log <base>..HEAD --oneline` to see commit history
4. Identify key files and areas that have changed
5. Summarize the changes in a concise format:
   - What features or fixes were implemented
   - Which entities/components were modified
   - Any new dependencies or configuration changes
   - Testing: whether the diff adds or modifies tests (do not run the suite or report coverage numbers — this skill is read-only)
6. Highlight any potential concerns or areas that need attention

This helps you understand the current state of work when jumping into an existing branch.
