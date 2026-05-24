PLUGIN_ID="just"
PLUGIN_NAME="just"
PLUGIN_DESC="Command runner for project tasks"
PLUGIN_DEFAULT=0

plugin_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'test -x "$HOME/.local/bin/just"' &>/dev/null
}

plugin_install() {
  log "Installing just..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' <<'EOF'
    set -e
    curl -fsSL https://just.systems/install.sh | bash -s -- --to "$HOME/.local/bin"
    export PATH="$HOME/.local/bin:$PATH"
    just --version
EOF
}
