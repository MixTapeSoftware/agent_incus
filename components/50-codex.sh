COMPONENT_ID="codex"
COMPONENT_NAME="Codex"
COMPONENT_DESC="OpenAI coding agent"
COMPONENT_DEFAULT=0

component_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'command -v codex' &>/dev/null
}

component_install() {
  log "Installing Codex..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' <<'EOF'
    set -e
    sudo npm install -g @openai/codex
EOF
}
