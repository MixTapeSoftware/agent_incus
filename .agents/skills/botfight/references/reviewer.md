# Reviewer mode

Watch an existing PR and review each new head commit once for the requested review scope. Publish actionable inline findings for the botfight fixer to triage. Reviewer owns observation and comments; fixer owns code changes and thread resolution.

## Review scope and state

Use the additional instructions as the review brief. Preserve their full text in continuation state and apply them on every review. A focus such as "security" prioritizes that area; an explicit limit such as "only review authentication" restricts the review to that scope. With no instructions, review correctness, regressions, security, and relevant test coverage. Instructions refine what to inspect; they do not switch reviewer into fixer mode.

Whatever the brief, use the repository's skills as review guidance: when an available skill covers the brief's area (for example a security skill for a security review), load it and apply its checks. Report missing guidance or access instead of silently claiming that scope was covered.

### Skill-based scopes

With `--skills`, split the list on commas and trim each area. Each area is its own scope, with the area text as its brief. For each area, choose the available skill whose name or description best covers it; the match need not be exact (`ui polish` can match a skill named `ui-review` or one described as UI and UX polish). Load that skill and review the head as it directs, within the area. When no available skill reasonably covers an area, do not review it from general knowledge: report it to the user as an uncovered area so the repository can add a skill for it, and continue with the other areas.

Review each area in its own sub-agent so the areas do not shape one another's findings, and submit a separate `COMMENT` review per area. Name the area and the matched skill in each review summary.

Set `scope_id` to the lowercase hexadecimal SHA-256 digest of the exact instruction text (for a `--skills` area, the trimmed area text) encoded as UTF-8, without adding a newline; use `general` when instructions are absent. Track completed reviews by `(repository, PR number, head SHA, scope_id)`. A review with different instructions does not satisfy the current brief. If the user changes the brief during the loop, carry the new text and scope ID forward and review the current head for that scope, even if its SHA is unchanged.

Carry these fields in every wakeup:

- Mode `reviewer`, canonical PR URL, repository, and PR number.
- Original deadline and polling interval.
- Full review instructions and `scope_id`, or each `--skills` area with its matched skill and `scope_id`.
- The GitHub login used to post reviews.
- Any `--skills` areas with no matching skill.
- Completed review keys and their submitted review links; last observed head SHA.
- Iteration count, findings posted, and any pending review or publication failure.

## Loop

1. **Check the deadline first**, including on continuations. If expired, report and stop without reviewing or posting. On first invocation use the shared timing defaults. Resolve the explicitly supplied PR, or the current branch's PR if omitted, and pin that identity for the whole loop. If no PR exists, report the missing target and stop; do not create one.
2. **Fetch current state**: PR open/closed/merged status, head SHA, base, diff, existing reviews and review threads (paginate). Closed or merged means exit. A new head SHA is a code update; timestamps, new comments, CI changes, and the reviewer's own posts do not trigger another review of the same code and scope.
3. **Check for a completed review** of this head and scope in carried state and submitted reviews from the recorded GitHub login. Recover state using the completion marker below. Pending drafts or failed submissions do not count. If already reviewed, skip to waiting; do not post another review or a heartbeat comment.
4. **Review the pinned head** against the PR's base. Read applicable `AGENTS.md` instructions, the PR description, changed code and enough surrounding code/tests to substantiate findings. On later updates, examine the new changes and their effect on the full PR, including whether earlier findings were fixed. Obtain source at the captured SHA through GitHub or `git show <sha>:<path>` after a fetch; do not review unrelated local edits or switch/reset the fixer's working tree. Read-only checks may support findings; never apply fixes, commit, push, merge, or resolve threads.
5. **Prepare inline findings** as described below. Before publication, re-fetch PR status and head, check the deadline, and check for an already-submitted review of this head/scope. If closed, merged, or expired, exit without posting. If the head moved, discard stale anchors and review the latest head within the remaining time. If already submitted, recover its state and wait.
6. **Submit one `COMMENT` review** pinned to the captured head SHA, containing the inline findings and a brief completion summary. Use `COMMENT`, not `APPROVE` or `REQUEST_CHANGES`; reviewer supplies findings for the coordinator. If there are no new findings, submit a summary saying so, with no manufactured inline comments. Mark the review key completed only after confirming successful submission and saving its link. If submission fails or its result is ambiguous, re-fetch reviews before retrying; recover a matching submitted review instead of duplicating it. Do not count incomplete inspection as a completed review.
7. **Keep watching until the deadline**, user cancellation, PR closure/merge, or a blocker that requires user input. A clean review, green CI, and resolved threads are reasons to wait, not exit. Use a recurring wakeup when available, with the explicit `reviewer <PR-URL> until <deadline> every <interval>` arguments and all state above. Cap the delay at time remaining. Otherwise stay in the foreground with bounded waits of at most 60 seconds and check for cancellation/deadline between waits. Never claim background monitoring unless a wakeup was actually scheduled. Transient read/publication errors retry on the next interval within the same deadline; report persistent access failures as blockers.

## Inline findings and completion record

Use the available GitHub integration to create actual PR review comments anchored to the relevant file and diff line, rather than a top-level comment containing a list of findings. With the [GitHub review API](https://docs.github.com/en/rest/pulls/reviews#create-a-review-for-a-pull-request), supply the reviewed `commit_id`, `event: "COMMENT"`, summary `body`, and `comments` containing `path`, `line`, `side`, and `body`. Through `gh`, write that payload to a JSON file and send it with `gh api repos/{owner}/{repo}/pulls/<n>/reviews --input <file>.json`. Choose `RIGHT` for added/current code or `LEFT` for deleted code as appropriate. For a finding that spans several lines, add `start_line` (and `start_side` when it differs) so that `line` is the last line of the range; `line` alone anchors to that one line. Validate anchors against the captured diff; never guess line numbers. If a finding cannot be anchored accurately, include it as an unposted limitation in the user report.

Each inline comment contains a short issue title, importance score (1–10 using the fixer's scale), the concrete trigger and impact, and the suggested correction, followed by the reviewer attribution footer from `SKILL.md`. Report substantiated, actionable issues in the requested scope; skip speculative concerns and cosmetic churn. The fixer independently decides whether to fix or decline using its 6/10 threshold.

Read prior threads before posting. Do not duplicate an existing finding, including one awaiting action or already declined, just because the head changed. A regression or new evidence can justify a new finding; link the prior discussion and explain what changed. Do not reply to or resolve existing threads. Human questions and conflicts belong in the user report with draft replies; do not open a replacement bot thread to bypass a human decision.

The review summary states the reviewed SHA, scope, finding count, and any inspection limitations. Before its attribution footer, include this machine-readable completion marker with the actual SHA and scope ID:

```html
<!-- botfight:reviewer head=<head-sha> scope=<scope-id> -->
```

This submitted review is the durable completion record, including for zero-findings reviews. Only a matching marker from the recorded reviewer login, on a submitted review whose `commit_id` matches, satisfies the completion check. A differently scoped review or another author's review does not.

## Coordination and exit

Reviewer does not change PR titles, run the fixer workflow, or clean up another loop's state. An existing `🤖⚔️ [botfight]` (or older `🤖 [botfight]`) title belongs to the fixer and remains untouched. Reviewer may run alongside a fixer, but does not start one automatically.

On every exit, cancel only this reviewer's pending wakeups and report why it ended, review scope, iterations, heads reviewed and review links, inline findings posted, pending/unposted findings or failures, and human items needing the user. Distinguish a completed review with no findings from a review that could not be completed. Leave submitted findings open for the fixer to address.
