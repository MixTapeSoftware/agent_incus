## ADDED Requirements

### Requirement: Components are defined in a registry
The system SHALL maintain a component registry that defines each installable item with a unique ID, display name, description, default toggle state, and installation function.

#### Scenario: Registry contains all installable items
- **WHEN** the init script is loaded
- **THEN** the registry SHALL contain entries for: Docker, Chromium/Playwright, Oh My Zsh, fzf, bat, mise, Claude Code, 1Password CLI, GitHub auth, and Entire CLI

### Requirement: Docker defaults to on
The Docker component SHALL have its default toggle state set to **on**. All other components SHALL default to **off**.

#### Scenario: Default states
- **WHEN** the component registry is initialized with no CLI flag overrides
- **THEN** Docker SHALL be on and all other components SHALL be off

### Requirement: Installation sections are modular functions
Each component's installation logic SHALL be encapsulated in a discrete bash function that can be called independently based on the user's TUI selection.

#### Scenario: Selective installation
- **WHEN** user selects only Docker and mise
- **THEN** only the Docker and mise installation functions SHALL execute; Chromium, fzf, bat, Oh My Zsh, Claude Code, and optional tools SHALL be skipped

### Requirement: Base packages always install
Core system packages (APK_CORE, APK_BUILD, APK_DEVLIBS, APK_RUNTIME or APT equivalents), user creation, workspace mounting, and shell configuration SHALL always be installed regardless of TUI selections. Only the optional tool installations are controlled by the TUI.

#### Scenario: Base packages are not toggleable
- **WHEN** the TUI is displayed
- **THEN** base system packages, user creation, and workspace mounting SHALL NOT appear as selectable items

### Requirement: CLI flags pre-set component toggle state
Existing CLI flags (`--1pass`, `--gh-token`, `--entire`) SHALL set their corresponding component's toggle state to on before the TUI is displayed.

#### Scenario: Flag sets toggle
- **WHEN** user passes `--gh-token` flag
- **THEN** the GitHub auth component SHALL be pre-toggled to on in the TUI
