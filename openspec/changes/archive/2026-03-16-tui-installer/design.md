## Context

The current `incus.init` script installs a fixed set of tools (Docker, Chromium, Oh My Zsh, fzf, bat, mise, Claude Code) unconditionally, with optional extras via CLI flags (`--1pass`, `--gh-token`, `--entire`). There is no interactive way for users to see all available components and choose which ones to install. The project values minimal dependencies and uses pure bash.

## Goals / Non-Goals

**Goals:**
- Provide an interactive TUI menu where users can toggle installable components on/off before provisioning
- Docker defaults to **on**; all other items default to **off**
- Preserve existing CLI flags as overrides that bypass/pre-set TUI selections
- Keep the implementation in pure bash with no new external dependencies

**Non-Goals:**
- Replacing the argument parsing or container creation logic
- Adding new installable components (only exposing existing ones as selectable)
- Supporting non-terminal (headless/CI) use beyond existing `--dry-run`

## Decisions

### 1. Pure bash ANSI TUI vs. `dialog`/`whiptail`

**Decision:** Pure bash using ANSI escape sequences.

**Rationale:** The project philosophy is zero external dependencies. `dialog`/`whiptail` may not be installed on the host system (the TUI runs on the host, not inside the container). ANSI escape sequences work in any modern terminal.

**Alternative considered:** `dialog`/`whiptail` — simpler API but adds a dependency and may not be present on macOS or minimal Linux installs.

### 2. Component registry as a bash array

**Decision:** Define components in an associative array at the top of the script with name, description, default state, and the function/code block that installs them.

**Rationale:** Keeps the component list declarative and easy to extend. Each component maps to an existing installation section in `incus.init`, which will be wrapped in a function.

### 3. TUI interaction model

**Decision:** Arrow keys (or j/k) to navigate, Space to toggle, Enter to confirm. Display a checklist with `[x]` / `[ ]` indicators.

**Rationale:** This is the standard checklist TUI pattern familiar to developers (similar to `npm init`, `yeoman`, etc.).

### 4. Integration with existing CLI flags

**Decision:** CLI flags like `--1pass` pre-toggle their corresponding component to **on** and skip showing it in the TUI (or show it as locked-on). The TUI only appears for components not already decided by flags.

**Rationale:** Backwards compatibility. Scripts or docs that use `incus.init --1pass` should continue to work without change.

### 5. Skipping the TUI

**Decision:** Add a `--no-tui` flag that uses defaults (only Docker) without showing the interactive menu, for CI/scripted use.

**Rationale:** Non-interactive environments need a way to skip the TUI entirely.

## Risks / Trade-offs

- **Terminal compatibility** — Pure ANSI TUI may render poorly in exotic terminals or over slow SSH connections. → Mitigation: Use only basic ANSI codes (cursor movement, colors already used in the script). Fall back to simple numbered list if `tput` is unavailable.
- **Maintenance burden** — Each new installable tool must be added to the component registry. → Mitigation: The registry is a single array; adding an entry is one line.
- **Input handling** — Reading arrow keys in bash requires parsing multi-byte escape sequences. → Mitigation: Well-tested pattern; also support j/k as alternative navigation.
