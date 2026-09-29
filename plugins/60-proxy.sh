PLUGIN_ID="proxy"
PLUGIN_NAME="Credential Proxy"
PLUGIN_DESC="GitHub access via a proxy; the real token never enters the container"
PLUGIN_DEFAULT=0
PLUGIN_CLI_FLAGS="--proxy"
# Prompting also makes a template launch re-run plugin_install, so every
# container launched from a template gets its own placeholder.
PLUGIN_NEEDS_PROMPT=1

# Non-interactive use: INCS_PROXY=<name> and INCS_PROXY_REF=op://... skip the
# matching prompts.

plugin_prompt() {
  # shellcheck source=../incus.proxy
  source "$SCRIPT_DIR/incus.proxy"

  local proxies count
  proxies="$(proxy_names)"
  if [[ -z "$proxies" ]]; then
    error "No credential proxies exist yet. Create one first: incs proxy new <name>"
  fi
  count="$(printf '%s\n' "$proxies" | wc -l | tr -d ' ')"

  echo ""
  if [[ -n "${INCS_PROXY:-}" ]]; then
    PROXY_NAME="$INCS_PROXY"
  elif [[ "$count" == "1" ]]; then
    PROXY_NAME="$proxies"
    log "Using credential proxy '$PROXY_NAME'"
  else
    log "Credential proxies:"
    printf '%s\n' "$proxies" | sed 's/^/    /'
    read -rp "Proxy to attach: " PROXY_NAME
  fi
  if ! printf '%s\n' "$proxies" | grep -qxF -- "$PROXY_NAME"; then
    error "Not a credential proxy: '$PROXY_NAME'"
  fi

  # This plugin sets GH_TOKEN to a placeholder. GitHub Auth would overwrite it
  # with a real token, which is exactly what the proxy exists to prevent.
  if [[ "$(selected_get gh-auth)" == "1" ]]; then
    warn "Credential Proxy replaces GitHub Auth — deselecting GitHub Auth"
    selected_set gh-auth 0
  fi

  PROXY_REF="" PROXY_TOKEN=""
  if proxy_has_1password "$PROXY_NAME"; then
    if [[ -n "${INCS_PROXY_REF:-}" ]]; then
      PROXY_REF="$INCS_PROXY_REF"
    else
      local vault default_ref
      vault="$(incus config get "$PROXY_NAME" user.incs.proxy-vault 2>/dev/null)"
      default_ref="op://${vault:-agent-tokens}/$CONTAINER_NAME/credential"
      echo "Store this container's GitHub token in 1Password, then give its reference."
      read -rp "1Password reference [$default_ref]: " PROXY_REF
      PROXY_REF="${PROXY_REF:-$default_ref}"
    fi
  else
    log "Proxy '$PROXY_NAME' has no 1Password account; the token is stored in the proxy."
    echo "Create a fine-grained token at: https://github.com/settings/tokens?type=beta"
    read -rsp "GitHub token for $CONTAINER_NAME (input hidden): " PROXY_TOKEN
    echo ""
    if [[ -z "$PROXY_TOKEN" ]]; then error "GitHub token required"; fi
  fi

  local default_name default_email
  default_name="$(git config --global user.name 2>/dev/null || true)"
  default_email="$(git config --global user.email 2>/dev/null || true)"
  read -rp "Git user.name [${default_name:-}]: " PROXY_GIT_NAME
  PROXY_GIT_NAME="${PROXY_GIT_NAME:-$default_name}"
  read -rp "Git user.email [${default_email:-}]: " PROXY_GIT_EMAIL
  PROXY_GIT_EMAIL="${PROXY_GIT_EMAIL:-$default_email}"
}

plugin_is_installed() {
  # Attaching is per container, never baked into an image.
  false
}

plugin_install() {
  # shellcheck source=../incus.proxy
  source "$SCRIPT_DIR/incus.proxy"
  proxy_attach "$CONTAINER_NAME" "$PROXY_NAME" "$PROXY_REF" "$PROXY_TOKEN"
  unset PROXY_TOKEN

  if [[ -n "${PROXY_GIT_NAME:-}" && -n "${PROXY_GIT_EMAIL:-}" ]]; then
    log "Configuring git identity..."
    # Built with %q and run from stdin so a name containing a quote cannot
    # break the remote shell. Mirrors the GitHub Auth plugin.
    local git_script
    printf -v git_script 'git config --global user.name %q\ngit config --global user.email %q\n' \
      "$PROXY_GIT_NAME" "$PROXY_GIT_EMAIL"
    printf '%s' "$git_script" | incus exec "$CONTAINER_NAME" -- \
      su - "$HOST_USER" -s /bin/sh
  else
    warn "Git identity not set — run 'git config --global user.name/user.email' in the container"
  fi
}
