COMPONENT_ID="just"
COMPONENT_NAME="just"
COMPONENT_DESC="Command runner for project tasks"
COMPONENT_DEFAULT=0

component_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'test -x "$HOME/.local/bin/just"' &>/dev/null
}

component_install() {
  log "Installing just..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' <<'EOF'
    set -e
    curl -fsSL https://just.systems/install.sh | bash -s -- --to "$HOME/.local/bin"
    export PATH="$HOME/.local/bin:$PATH"
    just --version
EOF
}
