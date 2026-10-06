PLUGIN_ID="codex"
PLUGIN_NAME="Codex"
PLUGIN_DESC="OpenAI coding agent"
PLUGIN_DEFAULT=0
PLUGIN_CLI_FLAGS="--codex"
PLUGIN_AGENT_COMMAND="codex"

plugin_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'test -x "$HOME/.local/bin/codex" || command -v codex' &>/dev/null
}

plugin_install() {
  log "Installing Codex..."
  # Provision system dependencies as root through the host, so --no-sudo works.
  incus exec "$CONTAINER_NAME" -- bash -s <<'DEPS'
    set -euo pipefail
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y bubblewrap
DEPS
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' <<'EOF'
    set -euo pipefail
    npm install --global --prefix "$HOME/.local" @openai/codex
EOF
}
