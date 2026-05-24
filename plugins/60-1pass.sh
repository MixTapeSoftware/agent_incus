PLUGIN_ID="1pass"
PLUGIN_NAME="1Password CLI"
PLUGIN_DESC="Password manager CLI"
PLUGIN_DEFAULT=0
PLUGIN_CLI_FLAGS="--1pass"
PLUGIN_NEEDS_PROMPT=1

plugin_prompt() {
  echo ""
  log "1Password CLI requires a service account token"
  echo "Create one at: https://start.1password.com/settings/automation"
  read -rsp "Enter token: " ONEPASSWORD_SERVICE_KEY
  echo ""
  if [[ -z "$ONEPASSWORD_SERVICE_KEY" ]]; then error "Token required"; fi
}

plugin_is_installed() {
  incus exec "$CONTAINER_NAME" -- sh -c 'command -v op' &>/dev/null
}

plugin_install() {
  if ! plugin_is_installed; then
    log "Installing 1Password CLI..."
    incus exec "$CONTAINER_NAME" -- sh -c '
      wget -q https://cache.agilebits.com/dist/1P/op2/pkg/v2.30.0/op_linux_amd64_v2.30.0.zip -O /tmp/op.zip
      unzip -q /tmp/op.zip -d /tmp/ && mv /tmp/op /usr/local/bin/ && chmod +x /usr/local/bin/op && rm /tmp/op.zip
    '
  fi
  log "Setting 1Password token via container environment..."
  incus config set "$CONTAINER_NAME" environment.OP_SERVICE_ACCOUNT_TOKEN="$ONEPASSWORD_SERVICE_KEY"

  # Also write to .zshenv so the token survives `su -` login shells
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c \
    "echo 'export OP_SERVICE_ACCOUNT_TOKEN=\"$ONEPASSWORD_SERVICE_KEY\"' >> ~/.zshenv"
  unset ONEPASSWORD_SERVICE_KEY
}
