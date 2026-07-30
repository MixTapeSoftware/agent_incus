PLUGIN_ID="supabase-serve"
# Name sorts immediately after "Tailscale" (install order is A-Z by name), so
# tailscale is installed and brought up before this preset applies. No colon in
# the name — the TUI's PLUGINS entries are colon-delimited.
PLUGIN_NAME="Tailscale + Supabase serve"
PLUGIN_DESC="Serve app + Supabase ports over tailnet HTTPS"
PLUGIN_DEFAULT=0
PLUGIN_CLI_FLAGS="--supabase-serve"
PLUGIN_REQUIRES="tailscale"

# HTTPS port on the tailnet -> localhost target inside the instance.
#   443  -> 3000   app dev server        4410 -> 3010   secondary app
#   4431 -> 3001   secondary app         5432 -> 54321  Supabase API (Kong)
#   5433 -> 54323  Supabase Studio       5434 -> 54324  Mailpit/Inbucket
#   8443 -> 8000   Kong http
SUPABASE_SERVE_MAP="443:3000 4410:3010 4431:3001 5432:54321 5433:54323 5434:54324 8443:8000"

plugin_is_installed() {
  # Always (re)apply: `tailscale serve --bg` is idempotent and tailscaled
  # persists the config, so fresh builds and template launches both converge.
  false
}

plugin_install() {
  # Template edge: tailscale should always be present via PLUGIN_REQUIRES, but
  # a hand-built template could get here without it. Don't fail the build.
  if ! incus exec "$CONTAINER_NAME" -- sh -c 'command -v tailscale' &>/dev/null; then
    warn "Tailscale not present in $CONTAINER_NAME; skipping Supabase serve preset"
    return 0
  fi

  log "Applying Supabase serve preset..."
  local pair src dst failed=0
  for pair in $SUPABASE_SERVE_MAP; do
    src="${pair%%:*}"
    dst="${pair##*:}"
    if incus exec "$CONTAINER_NAME" -- tailscale serve --bg --https="$src" \
        "http://127.0.0.1:$dst" >/dev/null 2>&1; then
      log "  serve :$src -> localhost:$dst"
    else
      warn "  serve :$src -> localhost:$dst failed"
      failed=1
    fi
  done

  if [[ "$failed" == "1" ]]; then
    warn "Some mappings failed — if the machine hasn't joined the tailnet yet,"
    warn "run 'sudo tailscale up' inside the instance and re-launch, or re-apply"
    warn "manually with: tailscale serve --bg --https=<port> http://127.0.0.1:<target>"
  fi
}
