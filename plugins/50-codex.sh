PLUGIN_ID="codex"
PLUGIN_NAME="Codex"
PLUGIN_DESC="OpenAI coding agent"
PLUGIN_DEFAULT=0

plugin_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'command -v codex' &>/dev/null
}

plugin_install() {
  log "Installing Codex..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' <<'EOF'
    set -e
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y bubblewrap
    sudo npm install -g @openai/codex
EOF
}
