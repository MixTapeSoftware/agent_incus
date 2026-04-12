COMPONENT_ID="openspec"
COMPONENT_NAME="OpenSpec"
COMPONENT_DESC="Spec-driven development CLI"
COMPONENT_DEFAULT=0

component_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'command -v openspec' &>/dev/null
}

component_install() {
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
