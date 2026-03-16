## MODIFIED Requirements

### Requirement: Components are defined in a registry
The system SHALL maintain a component registry as a single array where each entry contains id, display name, description, and default state in a colon-delimited format (`id:name:description:default`). Runtime selection state SHALL be tracked in a `declare -A` associative array keyed by component ID.

#### Scenario: Registry contains all installable items
- **WHEN** the init script is loaded
- **THEN** the registry SHALL contain entries for: Docker, Chromium/Playwright, Oh My Zsh, fzf+bat, Claude Code, 1Password CLI, GitHub Auth, and Entire CLI, each as a single colon-delimited string

#### Scenario: Adding a new component
- **WHEN** a developer adds a new component
- **THEN** they SHALL add exactly one line to the COMPONENTS array with all fields

### Requirement: Docker-specific container config only runs when Docker is selected
Container nesting (`security.nesting`), syscall intercepts (`mknod`, `setxattr`), AppArmor unconfined profile (`raw.lxc`), and the associated container restart SHALL only execute when Docker is selected. These SHALL be part of `install_docker()`, not unconditional setup.

#### Scenario: Docker not selected
- **WHEN** user deselects Docker in the TUI
- **THEN** the container SHALL NOT have nesting enabled, SHALL NOT have unconfined AppArmor, and SHALL NOT be restarted for Docker config

#### Scenario: Docker selected
- **WHEN** user selects Docker
- **THEN** `install_docker()` SHALL configure nesting, AppArmor, restart the container, then install Docker packages

### Requirement: mise activation is independent of Oh My Zsh
The `mise activate zsh` line SHALL be added to `.zshrc` during base shell setup, not inside `install_ohmyzsh()`. This ensures mise-installed binaries (fzf, bat, go, etc.) are available in the user's PATH regardless of which components are selected.

#### Scenario: fzf+bat selected without Oh My Zsh
- **WHEN** user selects fzf+bat but deselects Oh My Zsh
- **THEN** mise SHALL be activated in the user's zsh session and fzf/bat binaries SHALL be in PATH

### Requirement: Single source of truth for component selection
After the TUI (or `--no-tui` default), the `SELECTED` associative array SHALL be the sole authority on which components to install. `USE_1PASSWORD`, `USE_GH_TOKEN`, and `USE_ENTIRE` flags SHALL be derived from `SELECTED` via unconditional assignment, not conditional set.

#### Scenario: User deselects a CLI-flag component in TUI
- **WHEN** user passes `--1pass` then deselects 1Password in the TUI
- **THEN** `USE_1PASSWORD` SHALL be 0 and the 1Password token prompt SHALL NOT appear

### Requirement: Token prompts are not duplicated
The 1Password token prompt and GitHub token prompt SHALL each be defined in exactly one function (`prompt_1password_token` and `prompt_gh_token`). These functions SHALL be called once, after the TUI decision, gated by the component's selection state.

#### Scenario: 1Password selected via TUI
- **WHEN** user toggles 1Password on in the TUI and confirms
- **THEN** `prompt_1password_token()` SHALL be called exactly once to collect the token

### Requirement: Dead code is removed
The `COMP_DEFAULTS` array, the `comp_index()` function, and the parallel array declarations (`COMP_IDS`, `COMP_NAMES`, `COMP_DESCS`) SHALL be removed and replaced by the single COMPONENTS array and SELECTED associative array.

#### Scenario: No dead code
- **WHEN** the script is loaded
- **THEN** there SHALL be no unused variable declarations or unreferenced functions related to the component registry
