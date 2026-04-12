COMPONENT_ID="glow"
COMPONENT_NAME="Glow"
COMPONENT_DESC="Terminal markdown viewer"
COMPONENT_DEFAULT=0

component_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'command -v glow' &>/dev/null
}

component_install() {
  log "Installing Glow..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' <<'EOF'
    set -e
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list
    sudo apt-get update && sudo apt-get install -y glow
EOF
}
