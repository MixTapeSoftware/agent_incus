PLUGIN_ID="cubic"
PLUGIN_NAME="cubic"
PLUGIN_DESC="AI code review CLI (cubic.dev)"
PLUGIN_DEFAULT=0
PLUGIN_CLI_FLAGS="--cubic"

plugin_is_installed() {
  # Check the binary directly rather than via PATH: the installer drops it in
  # ~/.cubic/bin, which is only on PATH once the shell rc it patches is sourced.
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'test -x "$HOME/.cubic/bin/cubic"' &>/dev/null
}

plugin_install() {
  log "Installing cubic CLI..."
  # Official Linux installer: no sudo, installs to ~/.cubic/bin, appends that dir
  # to the shell rc PATH itself, and needs curl + unzip (both in APT_CORE).
  # Run as the user so it lands in their home and patches their rc. We do NOT run
  # `cubic` to verify: first run opens a browser for interactive login and would
  # hang a headless build. Auth happens later, when the user runs it themselves.
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' <<'EOF'
    set -e
    curl -fsSL https://cubic.dev/install | bash
    test -x "$HOME/.cubic/bin/cubic" || { echo "cubic binary not found after install" >&2; exit 1; }
EOF
}
