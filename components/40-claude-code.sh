COMPONENT_ID="claude-code"
COMPONENT_NAME="Claude Code"
COMPONENT_DESC="AI coding assistant"
COMPONENT_DEFAULT=0

component_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'test -x "$HOME/.local/bin/claude"' &>/dev/null
}

component_install() {
  log "Installing Claude Code..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' <<'CLAUDE'
    set -e
    curl -fsSL https://claude.ai/install.sh | bash
CLAUDE
}
