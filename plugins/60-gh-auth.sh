PLUGIN_ID="gh-auth"
PLUGIN_NAME="GitHub Auth"
PLUGIN_DESC="GitHub token & git credentials (kept in the container's proxy)"
PLUGIN_DEFAULT=0
PLUGIN_CLI_FLAGS="--gh-token"
PLUGIN_NEEDS_PROMPT=1

plugin_prompt() {
  echo ""
  log "GitHub auth requires a fine-grained personal access token"
  if [[ "${SKIP_CREDENTIAL_PROXY:-0}" == "0" ]]; then
    echo "It is stored in this container's credential proxy; the container gets a placeholder."
  else
    warn "--no-proxy: the real token will be stored inside the container"
  fi
  echo "Create one at: https://github.com/settings/tokens?type=beta"
  echo "Recommended scopes: Contents (read/write), Metadata (read)"
  read_secret GH_TOKEN_VALUE "Enter GitHub token: "
  if [[ -z "$GH_TOKEN_VALUE" ]]; then error "GitHub token required"; fi

  local default_name default_email
  default_name="$(git config --global user.name 2>/dev/null || true)"
  default_email="$(git config --global user.email 2>/dev/null || true)"

  read_value GH_USER_NAME "Git user.name [${default_name:-}]: "
  GH_USER_NAME="${GH_USER_NAME:-$default_name}"
  if [[ -z "$GH_USER_NAME" ]]; then error "Git user.name required"; fi

  read_value GH_USER_EMAIL "Git user.email [${default_email:-}]: "
  GH_USER_EMAIL="${GH_USER_EMAIL:-$default_email}"
  if [[ -z "$GH_USER_EMAIL" ]]; then error "Git user.email required"; fi
}

plugin_is_installed() {
  # gh is installed in base provisioning; this plugin configures auth
  false
}

# The container's own proxy, if it has one.
_gh_auth_proxy() {
  [[ "${SKIP_CREDENTIAL_PROXY:-0}" == "0" ]] || return 0
  incus config get "$CONTAINER_NAME" user.incs.owned-proxy 2>/dev/null || true
}

_gh_auth_git_identity() {
  # Built with %q and run from stdin so a value containing a quote cannot
  # break the remote shell.
  local git_script
  printf -v git_script 'git config --global user.name %q\ngit config --global user.email %q\n' \
    "$GH_USER_NAME" "$GH_USER_EMAIL"
  printf '%s' "$git_script" | incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -s /bin/sh
}

plugin_install() {
  local proxy
  proxy="$(_gh_auth_proxy)"
  if [[ -n "$proxy" ]]; then
    # The real token goes to the proxy; the container gets a placeholder, and
    # proxy_attach also sets up git's credential helper.
    log "Storing the GitHub token in proxy '$proxy'..."
    proxy_attach "$CONTAINER_NAME" "$proxy" "" "$GH_TOKEN_VALUE"
    unset GH_TOKEN_VALUE
    log "Configuring git identity..."
    _gh_auth_git_identity
    return 0
  fi

  warn "No credential proxy: storing the real GitHub token in $CONTAINER_NAME"
  incus config set "$CONTAINER_NAME" environment.GH_TOKEN="$GH_TOKEN_VALUE"

  # Persist the token in .zshenv so it survives `su -` login shells. Fed over
  # stdin with %q quoting, never spliced into a remote command string.
  local export_line
  printf -v export_line 'export GH_TOKEN=%q\n' "$GH_TOKEN_VALUE"
  printf '%s' "$export_line" | incus exec "$CONTAINER_NAME" -- \
    su - "$HOST_USER" -s /bin/sh -c '
      touch ~/.zshenv
      sed -i "/^export GH_TOKEN=/d" ~/.zshenv
      cat >> ~/.zshenv
    '

  log "Configuring git credential helper and identity..."
  local git_script
  printf -v git_script 'export GH_TOKEN=%q\ngh auth setup-git\n' "$GH_TOKEN_VALUE"
  printf '%s' "$git_script" | incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -s /bin/sh
  _gh_auth_git_identity

  unset GH_TOKEN_VALUE
}
