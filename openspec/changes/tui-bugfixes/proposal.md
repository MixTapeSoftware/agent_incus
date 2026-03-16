## Why

Code review of the TUI installer revealed 4 correctness bugs, 4 structural problems, and 3 minor issues. The most critical: container nesting + AppArmor runs unconditionally, mise activation is coupled to Oh My Zsh (breaks fzf+bat without it), bare ESC hangs the TUI, and the dual USE_*/COMP_SELECTED control plane creates stale state.

## What Changes

- Move Docker-specific container nesting/AppArmor/restart into `install_docker()` so they only run when Docker is selected
- Move `mise activate zsh` into base shell setup so it's available regardless of Oh My Zsh selection
- Add timeout to ESC sequence reading so bare ESC doesn't hang
- Eliminate dual control plane: remove USE_* flags for component-tracked items, use COMP_SELECTED as single source of truth
- Extract duplicated 1Password/GitHub token prompts into functions, call once after TUI
- Replace parallel arrays with single colon-delimited COMPONENTS array (one line per component)
- Remove dead COMP_DEFAULTS array
- Replace comp_index O(n) scan with `declare -A` associative array
- Switch TUI box drawing to ASCII for portability
- Replace `seq` subprocess with C-style for loop in render
- Hoist `local` declarations to function scope in `show_tui`

## Capabilities

### New Capabilities

### Modified Capabilities
- `tui-selector`: Fix ESC hang, ASCII box drawing, render loop performance, local scoping
- `init-components`: Fix AppArmor/nesting gating, mise activation decoupling, single data structure, eliminate dual control plane, deduplicate prompts

## Impact

- **Code**: `incus.init` only — all changes are internal refactoring and bug fixes
- **Security**: Containers without Docker selected will no longer get unnecessary nesting/AppArmor relaxation
- **Backwards compatibility**: No CLI or behavioral changes for users; same flags, same TUI, same output
