COMPONENT_ID="tailscale"
COMPONENT_NAME="Tailscale"
COMPONENT_DESC="Tailscale VPN for tailnet access inside the container"
COMPONENT_DEFAULT=0
COMPONENT_CLI_FLAGS="--tailscale"
COMPONENT_NEEDS_PROMPT=1
COMPONENT_RUN_ON_LAUNCH=1

component_prompt() {
  echo ""
  log "Tailscale will be installed. Recommended: paste a *tagged* auth key"
  log "so the container joins as a machine with ACL-scoped privileges"
  log "(not as you). Create one at:"
  echo "  https://login.tailscale.com/admin/settings/keys"
  echo "with 'Tags' set (e.g. tag:incus-dev). Blank to skip and auth later."
  read -rsp "Tailscale auth key: " TS_AUTH_KEY
  echo ""
}

component_is_installed() {
  incus exec "$CONTAINER_NAME" -- sh -c 'command -v tailscale' &>/dev/null
}

component_install() {
  log "Adding /dev/net/tun to $CONTAINER_NAME..."
  if ! incus config device get "$CONTAINER_NAME" tun type &>/dev/null; then
    incus config device add "$CONTAINER_NAME" tun unix-char path=/dev/net/tun
  fi

  if ! component_is_installed; then
    log "Installing Tailscale..."
    incus exec "$CONTAINER_NAME" -- sh -c 'curl -fsSL https://tailscale.com/install.sh | sh'
  fi

  incus exec "$CONTAINER_NAME" -- systemctl enable --now tailscaled

  if [[ -n "${TS_AUTH_KEY:-}" ]]; then
    log "Bringing tailscale up with provided auth key..."
    incus exec "$CONTAINER_NAME" -- tailscale up \
      --authkey="$TS_AUTH_KEY" \
      --hostname="$CONTAINER_NAME" \
      --operator="$HOST_USER"
    unset TS_AUTH_KEY

    # Expose the joined machine's FQDN as a global so other components
    # (e.g. tidewave) can derive URLs from it.
    TS_DNS_NAME=$(incus exec "$CONTAINER_NAME" -- tailscale status --json 2>/dev/null \
      | python3 -c 'import sys,json; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null || true)
    if [[ -n "${TS_DNS_NAME:-}" ]]; then
      log "Tailscale machine URL: https://$TS_DNS_NAME"
    else
      warn "Could not read tailnet DNS name from 'tailscale status'"
    fi
  else
    echo ""
    echo "  To join the tailnet, run:"
    echo "    incs -s $CONTAINER_NAME \"sudo tailscale up --operator=$HOST_USER\""
  fi
}

component_on_launch() {
  component_install
}
