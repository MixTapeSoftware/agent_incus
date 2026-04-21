COMPONENT_ID="tidewave"
COMPONENT_NAME="Tidewave"
COMPONENT_DESC="Tidewave CLI for agent-driven web app dev"
COMPONENT_DEFAULT=0
COMPONENT_NEEDS_PROMPT=1

component_prompt() {
  # If Tailscale is selected with an auth key, we'll derive TIDEWAVE_ORIGIN
  # from the joined tailnet's DNS name at install time — no prompt needed.
  if [[ "${SELECTED[tailscale]:-0}" == "1" && -n "${TS_AUTH_KEY:-}" ]]; then
    log "TIDEWAVE_ORIGIN will be derived from Tailscale once the container joins."
    return 0
  fi

  if [[ "${SELECTED[tailscale]:-0}" != "1" ]]; then
    warn "Tidewave is typically paired with Tailscale for remote access."
    warn "Tailscale is not selected — you'll need to expose Tidewave yourself."
  fi
  [[ ! -t 0 ]] && error "Tidewave prompt needs an interactive terminal"
  echo ""
  log "Tidewave needs TIDEWAVE_ORIGIN set to the URL clients use to reach it."
  echo "  e.g. https://project-dev.your-tailnet.ts.net"
  TIDEWAVE_ORIGIN=""
  while [[ -z "$TIDEWAVE_ORIGIN" ]]; do
    read -rp "TIDEWAVE_ORIGIN: " TIDEWAVE_ORIGIN || error "Failed to read TIDEWAVE_ORIGIN"
    if [[ -z "$TIDEWAVE_ORIGIN" ]]; then
      echo "  (required, try again — Ctrl+C to abort)"
    fi
  done
  return 0
}

component_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'test -x "$HOME/.local/bin/tidewave"' &>/dev/null
}

component_install() {
  log "Installing Tidewave CLI..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' <<'EOF'
    set -e
    arch=$(uname -m)
    case "$arch" in
      x86_64)  asset="tidewave-cli-x86_64-unknown-linux-gnu" ;;
      aarch64) asset="tidewave-cli-aarch64-unknown-linux-gnu" ;;
      *) echo "Unsupported arch: $arch" >&2; exit 1 ;;
    esac
    mkdir -p "$HOME/.local/bin"
    curl -fsSL "https://github.com/tidewave-ai/tidewave_app/releases/latest/download/$asset" \
      -o "$HOME/.local/bin/tidewave"
    chmod +x "$HOME/.local/bin/tidewave"
    export PATH="$HOME/.local/bin:$PATH"
    tidewave --version || tidewave --help | head -1
EOF

  # Derive from tailscale if the prompt skipped (tailscale + auth key path).
  # Tidewave is served on 4443 so Phoenix can keep the default :443.
  if [[ -z "${TIDEWAVE_ORIGIN:-}" ]]; then
    if [[ -n "${TS_DNS_NAME:-}" ]]; then
      TIDEWAVE_ORIGIN="https://$TS_DNS_NAME:4443"
      log "Derived TIDEWAVE_ORIGIN=$TIDEWAVE_ORIGIN"
    else
      error "TIDEWAVE_ORIGIN not set and no Tailscale DNS name to derive from"
    fi
  fi

  log "Setting TIDEWAVE_ORIGIN in container environment..."
  incus config set "$CONTAINER_NAME" environment.TIDEWAVE_ORIGIN="$TIDEWAVE_ORIGIN"
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c \
    "echo 'export TIDEWAVE_ORIGIN=\"$TIDEWAVE_ORIGIN\"' >> ~/.zshenv"

  log "Writing /workspace/tidewave-dev.sh..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'cat > /workspace/tidewave-dev.sh' <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

: "${TIDEWAVE_ORIGIN:?TIDEWAVE_ORIGIN must be set}"

# Reset + re-register tailscale serve (idempotent across runs)
tailscale serve reset
tailscale serve --bg --https=443  http://localhost:4000
tailscale serve --bg --https=4443 http://localhost:5555

# Tidewave in the background, phoenix in the foreground
tidewave -p 5555 --allow-remote-access --allowed-origins="$TIDEWAVE_ORIGIN" &
TW_PID=$!
trap 'kill $TW_PID 2>/dev/null || true' EXIT

PORT=4000 exec mise x -- iex -S mix phx.server
SCRIPT
  incus exec "$CONTAINER_NAME" -- chmod +x /workspace/tidewave-dev.sh
}
