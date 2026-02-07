#!/bin/bash
set -euo pipefail

# install-incus-scripts
# Creates symbolic links to incus helper scripts in ~/.local/bin

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log()   { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Files to link
FILES=(
  "incus.claude"
  "incus.shell"
  "incus.init"
)

# Ensure ~/.local/bin exists
mkdir -p ~/.local/bin

log "Installing incus helper scripts to ~/.local/bin"

for file in "${FILES[@]}"; do
  SOURCE="$SCRIPT_DIR/$file"
  TARGET="$HOME/.local/bin/$file"

  # Check if source file exists
  if [[ ! -f "$SOURCE" ]]; then
    warn "Source file not found: $SOURCE (skipping)"
    continue
  fi

  # Make source file executable
  chmod +x "$SOURCE"

  # Remove existing symlink or file if it exists
  if [[ -L "$TARGET" ]]; then
    log "Removing existing symlink: $TARGET"
    rm "$TARGET"
  elif [[ -f "$TARGET" ]]; then
    warn "File exists (not a symlink): $TARGET"
    read -p "Overwrite? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      rm "$TARGET"
    else
      warn "Skipping $file"
      continue
    fi
  fi

  # Create symlink
  ln -s "$SOURCE" "$TARGET"
  log "Linked: $file -> $TARGET"
done

echo ""
log "Done! Make sure ~/.local/bin is in your PATH"

# Check if ~/.local/bin is in PATH
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  warn "~/.local/bin is not in your PATH"
  echo ""
  echo "Add this to your ~/.bashrc or ~/.zshrc:"
  echo '  export PATH="$HOME/.local/bin:$PATH"'
fi
