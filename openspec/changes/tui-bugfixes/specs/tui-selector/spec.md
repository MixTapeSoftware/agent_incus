## MODIFIED Requirements

### Requirement: TUI displays selectable component list
The system SHALL display an interactive checklist of all installable components when `incus.init` is run without `--no-tui`. Each item SHALL show its name, a brief description, and its current toggle state (`[x]` on, `[ ]` off). The TUI header SHALL use ASCII box-drawing characters (`+`, `-`, `|`) for portability across all terminal locales.

#### Scenario: Default display on launch
- **WHEN** user runs `incus.init <container-name>` without `--no-tui`
- **THEN** the TUI SHALL display all installable components with Docker toggled on and all other components toggled off, using ASCII box drawing

#### Scenario: Component with CLI flag pre-set
- **WHEN** user runs `incus.init --1pass <container-name>`
- **THEN** the 1Password component SHALL appear as toggled on in the TUI

### Requirement: User can navigate the component list
The system SHALL allow users to move a cursor highlight up and down through the component list using arrow keys or j/k keys. The render loop SHALL use C-style for loops (`for ((i=0; i<count; i++))`) instead of subprocess-forking alternatives. Local variables SHALL be declared at function scope, not inside the loop body.

#### Scenario: Navigate down with arrow key
- **WHEN** the cursor is on the first item and user presses the Down arrow key
- **THEN** the cursor SHALL move to the second item

#### Scenario: Wrap at boundaries
- **WHEN** the cursor is on the last item and user presses Down
- **THEN** the cursor SHALL wrap to the first item

### Requirement: Bare ESC does not hang
The system SHALL use a timeout when reading the second part of an escape sequence. If no follow-up characters arrive within 0.2 seconds, the input SHALL be discarded and the TUI SHALL continue accepting input.

#### Scenario: User presses bare ESC
- **WHEN** user presses the Escape key by itself (not as part of an arrow key sequence)
- **THEN** the TUI SHALL ignore the input and continue (not hang)

#### Scenario: User presses arrow key
- **WHEN** user presses an arrow key (ESC + `[A` or `[B`)
- **THEN** the escape sequence SHALL be read within the timeout and navigation SHALL work normally
