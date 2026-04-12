COMPONENT_ID="entire"
COMPONENT_NAME="Entire CLI"
COMPONENT_DESC="Entire CLI tool"
COMPONENT_DEFAULT=0
COMPONENT_CLI_FLAGS="--entire"

component_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'test -x "$HOME/go/bin/entire"' &>/dev/null
}

component_install() {
  log "Installing Entire CLI..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' <<'EOF'
    set -e
    mise use -g go@latest
    export PATH="$HOME/go/bin:$(mise where go)/bin:$PATH"
    go install github.com/entireio/cli/cmd/entire@latest
    if [[ -d /workspace/.git ]]; then
      cd /workspace && entire enable --telemetry=false
    fi
EOF
}
