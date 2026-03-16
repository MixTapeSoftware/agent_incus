## 1. Component Registry

- [x] 1.1 Define the component registry as bash arrays at the top of `incus.init` with ID, display name, description, and default state (Docker=on, all others=off)
- [x] 1.2 Refactor existing installation sections (Docker, Chromium, Oh My Zsh, fzf, bat, mise, Claude Code, 1Password, GitHub auth, Entire) into discrete bash functions callable by component ID

## 2. TUI Renderer

- [x] 2.1 Implement the TUI display function that renders the component checklist with `[x]`/`[ ]` toggle indicators, cursor highlight, and header with key binding instructions
- [x] 2.2 Implement keyboard input handling for arrow keys, j/k navigation, Space to toggle, Enter to confirm, q to quit
- [x] 2.3 Implement cursor wrapping at list boundaries (bottom wraps to top, top wraps to bottom)

## 3. CLI Integration

- [x] 3.1 Add `--no-tui` flag to argument parsing that skips the TUI and uses defaults
- [x] 3.2 Wire existing CLI flags (`--1pass`, `--gh-token`, `--entire`) to pre-set component toggle states before TUI display
- [x] 3.3 Insert the TUI selection step into the init flow after argument parsing but before provisioning begins

## 4. Conditional Installation

- [x] 4.1 Replace the current unconditional installation calls with conditional execution based on the user's TUI selections
- [x] 4.2 Ensure base packages, user creation, workspace mounting, and shell config always run regardless of selections

## 5. Testing & Polish

- [x] 5.1 Test TUI renders correctly and handles all key inputs in both Alpine and Ubuntu modes
- [x] 5.2 Test that `--no-tui` mode installs only Docker plus base packages
- [x] 5.3 Test that CLI flags correctly pre-toggle components and persist through TUI confirmation
