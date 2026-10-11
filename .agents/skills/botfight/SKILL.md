---
name: botfight
description: Use when asked to run an unattended PR loop — e.g. "run botfight", "fight the bots on this PR", "botfight fixer", or "botfight reviewer" — including repeated reviews focused on security or other user-supplied instructions.
---

# Botfight — unattended PR review loop

## Overview

Botfight has two modes: **fixer** (the default coordinator) addresses bot findings on the PR; **reviewer** watches for new PR commits and posts inline findings for the fixer to address. Both run unattended and leave human interactions for the user. Comments post from the user's GitHub account, so automated attribution and the bot/human distinction matter in both modes.

Both modes read review threads through GraphQL and post reviews and replies with request bodies. Through `gh`, send each body, including read-only GraphQL queries, as a JSON file with `gh api <endpoint> --input <file>.json` and never with `-f`/`-F` field flags, following the `gh api` rules in the root `AGENTS.md`.

## Invocation and loop state

- With no mode argument, use `fixer`. `/botfight` and `/botfight fixer` are equivalent.
- Both modes default to checking every 5 minutes for 1.5 hours. Accept optional interval and duration arguments (for example, `/botfight fixer 10m 2h`). Existing `/botfight 10m 2h` invocations still work.
- Reviewer accepts an optional PR number or URL and additional free-text review instructions: `/botfight reviewer [<PR-number-or-URL>] [<interval> <duration>] [<instructions>]`. For example, `/botfight reviewer 42 5m 1h focus on security and tenant isolation`. With no target, use the current branch's PR; with no instructions, perform a general code review. Instruction text starts at the first token that is neither a PR number or URL nor an interval-and-duration pair, and everything after a `--` is instruction text whatever it looks like; preserve the full instruction text.
- `--skills <list>` takes everything after it as a comma-separated list of review areas, for example `/botfight reviewer 42 5m 1h --skills security, ui polish`. Put any PR target and timing before `--skills`. Each area becomes its own reviewer scope, reviewed with the closest matching skill available in the repository; see [references/reviewer.md](references/reviewer.md). Free-text instructions and `--skills` are alternatives.
- Continuations carry the explicit mode: `fixer until <ISO-8601 deadline> every <interval>` or `reviewer <PR-URL> until <ISO-8601 deadline> every <interval>`, plus that mode's state. Legacy continuations without a mode remain `fixer`.

On first invocation: get the current UTC time (`date -u +%Y-%m-%dT%H:%M:%SZ`), compute `deadline = now + duration`, and carry it in every wakeup prompt. Never recompute the deadline on a continuation — parse it from the args.

**Select the mode before any PR mutation.** For `reviewer`, read [references/reviewer.md](references/reviewer.md) and follow that loop with the shared attribution below. All fixer sections below apply only to `fixer`; reviewer never runs the fixer's create/fix flow.

## Fixer loop mechanics

0. **On a continuation, check the deadline first**: parse the deadline from the args before doing anything else. If it has passed, skip straight to the exit step (6) — no iteration, no fixes, no replies.
1. **Find the PR** for the current branch (`gh pr view`). If none exists, push the branch and create one with `gh pr create` against the default branch, then continue.
2. **Mark the title**: if the PR title does not already start with `🤖⚔️ [botfight] ` (or the older `🤖 [botfight] `), record the exact current title as the **original title** (carry it in the wakeup state), then prepend `🤖⚔️ [botfight] `. Strip a `🧑 [ready for human review] ` prefix only when the carried state proves an earlier botfight run added it — never delete a marker this loop cannot attribute to itself; anything else stays part of the original title and is restored verbatim on exit. The robot-and-swords prefix means exactly "an unattended loop is active on this PR."
3. **Run an iteration** (below).
4. **Check exit conditions** — exit when any holds:
   - PR merged or closed by someone else.
   - Clean: CI green, zero unresolved bot threads, no new bot comments to process, **and** no push since the previous iteration — after any push, run at least one more interval so review bots get a pass at the new commit. On the first invocation, or whenever the carried previous head SHA is absent (a legacy continuation or lost state), there is no previous iteration to compare against: treat the branch as just-pushed, so a clean exit always requires at least one full interval after the loop's last push.
   - Deadline reached.
   - Blocked on something only the user can decide.
5. **If not exiting**: use the harness's recurring-wakeup capability when one is available. Set the delay to the interval, capped at the seconds remaining until the deadline; carry the continuation arguments `fixer until <deadline> every <interval>`, the original title from step 2, the previous head SHA, and a short status reason. If recurring wakeups are unavailable, continue in the foreground using bounded waits. Never claim the loop will continue after returning unless a wakeup was actually scheduled.
6. **On exit — every exit, including timeout, blocked, and errors**: restore the original title recorded in step 2 (never touch a title this loop did not mark), then post the exit report to the user. A leftover robot prefix tells teammates a loop is running when it isn't.

## Fixer iteration

Each iteration addresses the existing PR: gather unresolved review threads, CI status, and top-level comments; fix; run the repository's documented verification (the checks its `AGENTS.md` requires); push. Botfight gathers unresolved threads whether or not they are outdated, because a push can outdate a reviewer finding before it is scored; for an outdated thread, check whether the current code still has the issue: if it does, score it as usual; if a later commit already removed it, the finding is addressed — reply naming that commit and resolve the thread. Every iteration follows three rules:

### 1. Classify every author first

For each thread and top-level comment, decide **bot or human** before doing anything else:

- Bot: GitHub account type `Bot`, login ending in `[bot]`, or a known review/CI bot (`github-actions`, `vercel`, `render`).
- Botfight comments from the user's account with the fixer or reviewer footer defined below also count as bot comments, including findings from a separate reviewer session. A quoted footer or bare mention of botfight does not count. Unsigned comments from that same account remain human.
- Everything else — including any account you are not sure about — is **human**.

Classify **whole threads, not openers**: a thread is a bot thread only if every comment in it is from a bot. One human reply anywhere in a bot-opened thread makes the entire thread human — report it, act on nothing in it, resolve nothing in it — even if you already scored the bot's finding. Signed reviewer findings receive the same scoring and handling as other bot findings. Review completion summaries, including zero-findings summaries, are status records and require no reply or fix.

### 2. Bot findings: the 6/10 rule

First verify each bot finding against the current code. A finding the code disproves is declined whatever its importance: reply with the evidence, then resolve the thread. Score each remaining bot finding's importance 1–10 (correctness, security, data isolation, data loss score high; style, naming, doc phrasing score low). Then:

- **Score ≥ 6**: fix the code, reply confirming the change with the commit reference, resolve the thread.
- **Score < 6**: do **not** touch the code. Reply stating the finding was reviewed and declined as below the unattended-fix bar (include the score), then resolve the thread. The threshold exists to bound unattended churn — "it's a 30-second fix" is not an override.

Every bot thread ends the iteration **fixed + resolved**, **declined + resolved**, or — only when it touches a frozen area (see below) — **left open for the user** and listed in the report. Push and verify (the repository's documented checks) before posting replies, so replies reference real commits.

### 3. Human comments: report, never act

Three reasons this line exists:

1. **Authority** — a human comment may be a scope or design decision (accept a risk, defer to another ticket, "don't do it this way"). Those are the user's calls; auto-"fixing" could override the reviewer's actual intent.
2. **Voice** — replies post from the user's account. Automated attribution on a bot thread is established convention; a colleague asking the user a question and getting an unreviewed agent answer in their name is a different thing.
3. **Conflict handling** — if a human contradicts a fix already made for a bot, the human wins by default, but that reconciliation must not happen autonomously on a public thread.

The rules, with no exceptions for "trivial" cases:

- Never edit code in response to a human comment — not a rename, not a revert, not a change the human explicitly requested.
- Never reply to a human's thread or comment, and never resolve a human's thread.
- If a human contradicts a bot fix you already made: **freeze that code area** — do not revert, do not re-apply, and skip any bot finding that touches it — and put the conflict at the top of the report.
- Collect every human item verbatim into the report, each with a **draft reply the user can post or discard**. The repo rule "reply to every review comment" is satisfied by the user posting from these drafts after the loop — botfight drafting instead of posting is how that rule and this one coexist.
- Keep processing bot findings in unrelated code as normal.

## Attribution

Every comment botfight posts carries attribution, including each inline review comment and the review summary. Fixer keeps the existing footer:

```
---
🤖 botfight · <agent harness> (<exact model id when available>)
```

Reviewer uses:

```
---
🤖 botfight reviewer · <agent harness> (<exact model id when available>)
```

## Fixer exit report

- Why the loop ended (clean / deadline / merged / blocked) and iterations run.
- Bot findings fixed (score, commit) and declined (score, link).
- **Human items awaiting the user**, quoted, each with its draft reply.
- Any frozen code areas from human-vs-bot conflicts.
- CI status, and whether this loop's title prefix was removed. If another loop owns the prefix, report that it was left untouched.

## Fixer red flags — stop, you're rationalizing

| Thought                                                       | Reality                                                                                        |
| ------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| "The human's ask is trivial, I'll just do it"                 | Acting on human comments is out of scope at any size. Draft, report.                           |
| "The human told me to revert, so reverting is what they want" | Reconciliation belongs to the user, not an unattended loop. Freeze the area.                   |
| "I know the answer to their question"                         | The answer would post unreviewed in the user's name. Draft it for the report.                  |
| "AGENTS.md says reply to every review comment"                | The user replies to humans from your drafts after the loop. Bot threads you reply to directly. |
| "The nit takes 30 seconds"                                    | Below 6 means decline + resolve. The bar bounds unattended churn.                              |
| "Timed out / errored, the prefix hardly matters"              | The robot means "loop active." Strip it and restore the original title on every exit path.     |
| "The signature clutters a one-line reply"                     | Attribution is mandatory on every posted comment.                                              |
