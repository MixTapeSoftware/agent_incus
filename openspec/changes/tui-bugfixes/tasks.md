## 1. Data Structure Overhaul

- [x] 1.1 Replace parallel arrays (COMP_IDS, COMP_NAMES, COMP_DESCS, COMP_DEFAULTS, COMP_SELECTED) with single colon-delimited COMPONENTS array and `declare -A SELECTED` associative array
- [x] 1.2 Remove comp_index(), replace comp_select() and comp_is_selected() with direct SELECTED[] lookups
- [x] 1.3 Update show_tui() to parse COMPONENTS array and use SELECTED[] associative array
- [x] 1.4 Update all call sites (arg parsing, install dispatch, dry-run summary, final summary) to use new data structure

## 2. Bug Fixes

- [x] 2.1 Move container nesting, AppArmor unconfined, and restart block into install_docker()
- [x] 2.2 Move `mise activate zsh` from install_ohmyzsh() into base shell setup section
- [x] 2.3 Add `-t 0.2` timeout to ESC sequence read in show_tui() so bare ESC doesn't hang
- [x] 2.4 After TUI, unconditionally assign USE_1PASSWORD, USE_GH_TOKEN, USE_ENTIRE from SELECTED[] (clear if deselected)

## 3. Prompt Deduplication

- [x] 3.1 Extract prompt_1password_token() and prompt_gh_token() functions
- [x] 3.2 Remove pre-TUI prompt blocks, call prompt functions once after TUI/no-tui decision

## 4. TUI Polish

- [x] 4.1 Replace Unicode box drawing with ASCII equivalents
- [x] 4.2 Replace `for i in $(seq 0 ...)` with `for ((i=0; i<count; i++))`
- [x] 4.3 Hoist `local marker key seq` declarations to function scope
