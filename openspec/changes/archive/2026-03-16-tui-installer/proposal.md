## Why

The current init process (`incus.init`) installs a fixed set of tools with optional extras controlled by command-line flags. Users have no interactive way to choose which components to install — they get everything or must know the right flags upfront. A TUI installer would let users see all available components, toggle them on/off, and proceed with a clear understanding of what will be provisioned.

## What Changes

- Add an interactive TUI selection screen to the init process where users can browse and toggle installable components
- All items default to **off** except Docker, which defaults to **on**
- Users can navigate the list, toggle items, and confirm their selection before provisioning begins
- The selected items drive which installation sections of `incus.init` execute
- Implement using `dialog` or pure bash/ANSI escape sequences to keep the project dependency-minimal

## Capabilities

### New Capabilities
- `tui-selector`: Interactive terminal UI component for selecting installable items with toggle on/off, keyboard navigation, and default states
- `init-components`: Modular decomposition of init installable items into selectable components with default-on/off configuration

### Modified Capabilities
<!-- No existing specs to modify -->

## Impact

- **Code**: `incus.init` — refactor installation sections into conditionally-executed blocks driven by TUI selections
- **Dependencies**: Possibly `dialog`/`whiptail` (commonly pre-installed) or pure ANSI escape sequences (zero deps)
- **UX**: Users now see an interactive menu before provisioning starts instead of needing to know CLI flags
- **Backwards compatibility**: CLI flags (`--1pass`, `--gh-token`, etc.) should continue to work, bypassing the TUI for those items
