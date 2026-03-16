## ADDED Requirements

### Requirement: TUI displays selectable component list
The system SHALL display an interactive checklist of all installable components when `incus.init` is run without `--no-tui`. Each item SHALL show its name, a brief description, and its current toggle state (`[x]` on, `[ ]` off).

#### Scenario: Default display on launch
- **WHEN** user runs `incus.init <container-name>` without `--no-tui`
- **THEN** the TUI SHALL display all installable components with Docker toggled on and all other components toggled off

#### Scenario: Component with CLI flag pre-set
- **WHEN** user runs `incus.init --1pass <container-name>`
- **THEN** the 1Password component SHALL appear as toggled on in the TUI

### Requirement: User can navigate the component list
The system SHALL allow users to move a cursor highlight up and down through the component list using arrow keys or j/k keys.

#### Scenario: Navigate down with arrow key
- **WHEN** the cursor is on the first item and user presses the Down arrow key
- **THEN** the cursor SHALL move to the second item

#### Scenario: Navigate with j/k keys
- **WHEN** user presses `j`
- **THEN** the cursor SHALL move down one item

#### Scenario: Wrap at boundaries
- **WHEN** the cursor is on the last item and user presses Down
- **THEN** the cursor SHALL wrap to the first item

### Requirement: User can toggle components on and off
The system SHALL allow users to toggle the selected component's state by pressing Space.

#### Scenario: Toggle off to on
- **WHEN** a component is toggled off and user presses Space on it
- **THEN** the component SHALL become toggled on and display `[x]`

#### Scenario: Toggle on to off
- **WHEN** a component is toggled on and user presses Space on it
- **THEN** the component SHALL become toggled off and display `[ ]`

### Requirement: User can confirm selections
The system SHALL allow users to confirm their selections by pressing Enter, after which the init process SHALL proceed to install only the selected components.

#### Scenario: Confirm and proceed
- **WHEN** user presses Enter with Docker and Chromium toggled on
- **THEN** the system SHALL install Docker and Chromium and skip all other optional components

### Requirement: TUI can be skipped
The system SHALL accept a `--no-tui` flag that skips the interactive menu and uses default selections (only Docker).

#### Scenario: Non-interactive mode
- **WHEN** user runs `incus.init --no-tui <container-name>`
- **THEN** the system SHALL skip the TUI and install only Docker (plus base packages)

### Requirement: TUI shows header and instructions
The system SHALL display a header explaining the purpose and key bindings (arrows/j/k to navigate, Space to toggle, Enter to confirm, q to quit).

#### Scenario: Instructions visible
- **WHEN** the TUI is displayed
- **THEN** a header line SHALL show navigation instructions
