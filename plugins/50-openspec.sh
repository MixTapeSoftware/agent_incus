PLUGIN_ID="openspec"
PLUGIN_NAME="OpenSpec"
PLUGIN_DESC="Spec-driven development CLI"
PLUGIN_DEFAULT=0

plugin_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'command -v openspec' &>/dev/null
}

plugin_install() {
  log "Installing OpenSpec..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' <<'EOF'
    set -e
    sudo npm install -g @fission-ai/openspec@latest
    export OPENSPEC_TELEMETRY=0
    if [[ -d /workspace ]]; then
      cd /workspace && openspec init --tools claude
    fi
EOF
}
