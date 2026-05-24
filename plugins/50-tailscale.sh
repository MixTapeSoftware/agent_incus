PLUGIN_ID="tailscale"
PLUGIN_NAME="Tailscale"
PLUGIN_DESC="Tailscale VPN for tailnet access inside the container"
PLUGIN_DEFAULT=0
PLUGIN_CLI_FLAGS="--tailscale"
PLUGIN_NEEDS_PROMPT=1
PLUGIN_RUN_ON_LAUNCH=1

plugin_prompt() {
  echo ""
  log "Tailscale will be installed. Recommended: paste a *tagged* auth key"
  log "so the container joins as a machine with ACL-scoped privileges"
  log "(not as you). Create one at:"
  echo "  https://login.tailscale.com/admin/settings/keys"
  echo "with 'Tags' set (e.g. tag:incus-dev). Blank to skip and auth later."
  read -rsp "Tailscale auth key: " TS_AUTH_KEY
  echo ""

  if [[ -n "$TS_AUTH_KEY" ]]; then
    log "Optionally expose a local dev port over HTTPS via tailscale serve."
    echo "  e.g. 5173 (Vite), 4000 (Phoenix), 3000 (Next). Blank to skip."
    read -rp "Dev port to serve on :443: " TS_SERVE_PORT
    if [[ -n "$TS_SERVE_PORT" && ! "$TS_SERVE_PORT" =~ ^[0-9]+$ ]]; then
      error "TS_SERVE_PORT must be a number, got: $TS_SERVE_PORT"
    fi
  fi
}

plugin_is_installed() {
  incus exec "$CONTAINER_NAME" -- sh -c 'command -v tailscale' &>/dev/null
}

plugin_install() {
  log "Adding /dev/net/tun to $CONTAINER_NAME..."
  if ! incus config device get "$CONTAINER_NAME" tun type &>/dev/null; then
    incus config device add "$CONTAINER_NAME" tun unix-char path=/dev/net/tun
  fi

  if ! plugin_is_installed; then
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

    # Expose the joined machine's FQDN as a global so other plugins
    # can derive URLs from it.
    TS_DNS_NAME=$(incus exec "$CONTAINER_NAME" -- tailscale status --json 2>/dev/null \
      | python3 -c 'import sys,json; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null || true)
    if [[ -n "${TS_DNS_NAME:-}" ]]; then
      log "Tailscale machine URL: https://$TS_DNS_NAME"
    else
      warn "Could not read tailnet DNS name from 'tailscale status'"
    fi

    if [[ -n "${TS_SERVE_PORT:-}" ]]; then
      log "Registering tailscale serve :443 -> localhost:$TS_SERVE_PORT..."
      incus exec "$CONTAINER_NAME" -- tailscale serve --bg --https=443 "http://localhost:$TS_SERVE_PORT" || \
        warn "tailscale serve failed — run it manually once your app is up"
      unset TS_SERVE_PORT
    fi
  else
    echo ""
    echo "  To join the tailnet, run:"
    echo "    incs -s $CONTAINER_NAME \"sudo tailscale up --operator=$HOST_USER\""
  fi
}

plugin_on_launch() {
  plugin_install
}
