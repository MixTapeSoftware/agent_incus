## Context

The TUI installer was implemented in the previous change (`tui-installer`). Code review surfaced bugs and structural issues. All changes are confined to `incus.init`. No new dependencies or architectural changes — this is a fix-and-clean pass.

## Goals / Non-Goals

**Goals:**
- Fix all 4 correctness bugs (AppArmor gating, mise activation, ESC hang, dual control plane)
- Consolidate the component data structure to prevent miscount bugs
- Eliminate code duplication in token prompts
- Clean up minor TUI rendering issues

**Non-Goals:**
- Adding new components or features
- Changing the TUI's visual design or interaction model
- Modifying anything outside `incus.init`

## Decisions

### 1. Single component data structure: colon-delimited array

**Decision:** Replace 5 parallel arrays with a single `COMPONENTS` array where each entry is `id:name:description:default`. Parse fields with IFS=: on use. Add a `declare -A SELECTED` associative array for runtime state.

**Rationale:** One line per component. Can't miscount. Associative array gives O(1) lookup, eliminating the `comp_index` scan and the entire `comp_index`/`comp_select`/`comp_is_selected` indirection chain.

**Alternative considered:** Keep parallel arrays but add bounds checking — still fragile, just fails louder.

### 2. Eliminate USE_* flags for component-tracked items

**Decision:** After TUI, derive USE_1PASSWORD, USE_GH_TOKEN, USE_ENTIRE from SELECTED[] with unconditional assignment. These flags are only needed for the token prompt flow, not for install gating (which uses SELECTED[] directly).

**Rationale:** Single source of truth. If user deselects in TUI, the flag is cleared. No stale state.

### 3. Token prompts as functions, called once after TUI

**Decision:** Extract `prompt_1password_token()` and `prompt_gh_token()`. Remove the pre-TUI prompt blocks. Call the functions once after TUI/no-tui decision, gated by `[[ "${SELECTED[1pass]}" == "1" ]]`.

**Rationale:** Eliminates 30 lines of duplication. Prompts only happen for components that will actually be installed.

### 4. Move nesting/AppArmor into install_docker()

**Decision:** Move the entire security.nesting + AppArmor + restart block into `install_docker()`, at the top before Docker package installation.

**Rationale:** These are Docker prerequisites. Without Docker, they're a security regression and waste time on a restart.

### 5. ASCII box drawing for TUI header

**Decision:** Replace Unicode box characters with ASCII equivalents (`+`, `-`, `|`).

**Rationale:** Works in any locale. The rest of the script uses ASCII. No functional difference.

## Risks / Trade-offs

- **Container restart moved into install_docker()** — If Docker is selected, the restart now happens later in the flow (during component install rather than during container creation). This is fine because no other component depends on the nesting config. → No mitigation needed.
- **Bash 4+ required for declare -A** — Already effectively required (the script uses `${!array[@]}` syntax). macOS ships bash 3 but the script runs on the host which typically has bash 4+ via Homebrew, or on Linux which always has it. → No change in compatibility.
