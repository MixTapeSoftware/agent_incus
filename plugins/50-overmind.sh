PLUGIN_ID="overmind"
PLUGIN_NAME="Overmind"
PLUGIN_DESC="Procfile-based process manager (installs go)"
PLUGIN_DEFAULT=0

plugin_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'test -x "$HOME/.local/bin/overmind"' &>/dev/null
}

plugin_install() {
  log "Installing Overmind via go install (Go provisioned through mise)..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' <<'EOF'
    set -e
    mise use -g go@latest
    export PATH="$HOME/.local/share/mise/shims:$PATH"
    mkdir -p "$HOME/.local/bin"
    GOBIN="$HOME/.local/bin" go install github.com/DarthSim/overmind/v2@latest
    "$HOME/.local/bin/overmind" --version
EOF
}
