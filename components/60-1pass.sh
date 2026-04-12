COMPONENT_ID="1pass"
COMPONENT_NAME="1Password CLI"
COMPONENT_DESC="Password manager CLI"
COMPONENT_DEFAULT=0
COMPONENT_CLI_FLAGS="--1pass"
COMPONENT_NEEDS_PROMPT=1

component_prompt() {
  echo ""
  log "1Password CLI requires a service account token"
  echo "Create one at: https://start.1password.com/settings/automation"
  read -rsp "Enter token: " ONEPASSWORD_SERVICE_KEY
  echo ""
  if [[ -z "$ONEPASSWORD_SERVICE_KEY" ]]; then error "Token required"; fi
}

component_is_installed() {
  incus exec "$CONTAINER_NAME" -- sh -c 'command -v op' &>/dev/null
}

component_install() {
  if ! component_is_installed; then
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
