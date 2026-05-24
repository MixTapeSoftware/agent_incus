PLUGIN_ID="claude-code"
PLUGIN_NAME="Claude Code"
PLUGIN_DESC="AI coding assistant"
PLUGIN_DEFAULT=0

plugin_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'test -x "$HOME/.local/bin/claude"' &>/dev/null
}

plugin_install() {
  log "Installing Claude Code..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' <<'CLAUDE'
    set -e
    curl -fsSL https://claude.ai/install.sh | bash
CLAUDE
}
