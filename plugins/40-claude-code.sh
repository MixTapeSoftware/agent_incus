PLUGIN_ID="claude-code"
PLUGIN_NAME="Claude Code"
PLUGIN_DESC="AI coding assistant"
PLUGIN_DEFAULT=0
PLUGIN_CLI_FLAGS="--claude --claude-code"
PLUGIN_AGENT_COMMAND="claude"

plugin_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'test -x "$HOME/.local/bin/claude"' &>/dev/null
}

plugin_install() {
  log "Installing Claude Code..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' <<'CLAUDE'
    set -euo pipefail
    curl -fsSL https://claude.ai/install.sh | bash
CLAUDE
}
