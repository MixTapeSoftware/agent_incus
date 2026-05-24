# `.env` mount warning

## Problem

`incs` bind-mounts the user's current directory into the container at
`/workspace` (incus.init:761-769). That mount is live and unfiltered: anything
in the directory — including `.env` files containing plaintext secrets — is
readable by every process in the container, including any coding agent the
container is provisioned to run.

There is currently no signal at launch time that the workspace contains
`.env` files. A user spinning up an agent container in a repo with a populated
`.env` may not realize the agent will have full read access to those secrets.

## Goal

Before the workspace is mounted, surface a warning that lists the `.env*`
files the user is about to expose to the container, require explicit
acknowledgement to proceed, and point the user at a durable alternative
(1Password CLI hydration with the `1pass` plugin omitted from agent
containers).

Non-goals: hiding, masking, or otherwise blocking `.env` files at mount time.
The mount is live, so any guarantee would be partial — a `.env` added to the
host workspace after launch would still appear inside the container. Warning
about the current state is honest; partial masking would imply protection that
the design cannot deliver.

## Detection

Runs once, after workspace path validation (incus.init:582-586) and before
the MAP_USER prompt (incus.init:600).

- Skipped when `NO_MOUNT=1` — no host mount, nothing to warn about. This also
  covers `SAVE_TEMPLATE=1`, which forces `NO_MOUNT=1` (incus.init:588-590).
- Recursive scan: `find "$WORKSPACE_PATH" -type f -name '.env*'`.
- Path exclusions (skip dependency/build trees that often vendor unrelated
  `.env` files): `node_modules`, `.git`, `vendor`, `target`, `dist`, `build`.
- Basename exclusions (checked-in templates, not secrets): `.env.example`,
  `.env.sample`, `.env.template`, `.env.dist`.
- Results stored in a bash array `ENV_FILES` of absolute paths.

If `ENV_FILES` is empty, the rest of the feature is a no-op.

## Warning block

Printed to stderr via the existing `warn()` helper (yellow `WARN:` prefix,
incus.init:12-15) when `ENV_FILES` is non-empty. Paths are shown relative to
`WORKSPACE_PATH`. If the list exceeds 20 entries, it is truncated with a
`…and N more` line so the warning stays readable.

```
WARN: The workspace mount will expose these .env files inside the container:
      .env
      apps/web/.env.local
      services/api/.env.production
WARN: Anything running in the container — including coding agents — can read these.
WARN: Adding a .env to the workspace later will also be visible; this warning only
      reflects what's present right now.
WARN: Safer pattern: use the 1Password CLI to hydrate env at runtime
      (`op run --env-file=.env.tpl -- ./your-cmd`) with op:// references in place of
      plaintext secrets, and skip the 1pass plugin in agent containers so the agent
      can't resolve those references.
```

## Confirmation

- **Interactive** (`[[ -t 0 ]]` is true): `read -rp "Type 'yes' to continue, Ctrl-C to abort: "`
  in a loop. Only the exact string `yes` proceeds. Anything else re-prompts.
  Ctrl-C aborts via the existing cleanup trap (incus.init:216-228).
- **Non-interactive**: `error()` out immediately with a message that instructs
  the user to pass `--ack-env`. The error message includes the same file list
  so the user knows what they would be acknowledging.

## New flag

`--ack-env` — acknowledges the warning and suppresses the confirmation prompt.
The warning block is still printed (the user should still see what's being
exposed). Suitable for `--no-tui`, scripted, and CI runs.

Parsed in the existing argument loop (incus.init:540-555) by setting
`ACK_ENV=1`. Default `ACK_ENV=0`.

## Dry-run integration

The existing dry-run summary (incus.init:620-640) gains a line when
`ENV_FILES` is non-empty:

```
.env files exposed: 3
  .env
  apps/web/.env.local
  services/api/.env.production
```

Same 20-entry truncation. The warning block and confirmation still run before
the dry-run summary — a dry run that would expose `.env` files should still
require acknowledgement, since the goal is awareness, not blocking the
container creation.

## Help text

Add `--ack-env` to the usage block (incus.init:31-50) with a one-line
description: `--ack-env  Acknowledge .env files in the workspace (skip prompt)`.

## Out of scope

- Masking or hiding `.env` files inside the container (see Goal section for
  reasoning).
- Scanning for secrets in non-`.env` files (e.g., `config.json`,
  `credentials.yaml`). The convention `.env*` is well-understood; broader
  heuristics would produce false positives and undermine the signal.
- Modifying the `1pass` plugin. The warning text references it but the
  durable workflow (omit `1pass` from agent containers) is achieved through
  the existing TUI selection — no plugin changes required.
