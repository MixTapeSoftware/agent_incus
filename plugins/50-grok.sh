PLUGIN_ID="grok"
PLUGIN_NAME="Grok Build"
PLUGIN_DESC="xAI coding agent"
PLUGIN_DEFAULT=0
PLUGIN_CLI_FLAGS="--grok --grokbot"
PLUGIN_AGENT_COMMAND="grok"

plugin_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'test -x "$HOME/.local/bin/grok" || command -v grok' &>/dev/null
}

plugin_install() {
  log "Installing Grok Build..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' <<'GROK'
    set -euo pipefail
    mkdir -p "$HOME/.local/bin"
    # Use the shared user PATH instead of depending on installer-specific rc edits.
    curl -fsSL https://x.ai/cli/install.sh | GROK_BIN_DIR="$HOME/.local/bin" bash
GROK
}
