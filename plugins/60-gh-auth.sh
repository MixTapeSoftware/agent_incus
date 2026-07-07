PLUGIN_ID="gh-auth"
PLUGIN_NAME="GitHub Auth"
PLUGIN_DESC="GitHub token & git credentials"
PLUGIN_DEFAULT=0
PLUGIN_CLI_FLAGS="--gh-token"
PLUGIN_NEEDS_PROMPT=1

plugin_prompt() {
  echo ""
  log "GitHub auth requires a fine-grained personal access token"
  echo "Create one at: https://github.com/settings/tokens?type=beta"
  echo "Recommended scopes: Contents (read/write), Metadata (read)"
  read -rsp "Enter GitHub token: " GH_TOKEN_VALUE
  echo ""
  if [[ -z "$GH_TOKEN_VALUE" ]]; then error "GitHub token required"; fi

  local default_name default_email
  default_name="$(git config --global user.name 2>/dev/null || true)"
  default_email="$(git config --global user.email 2>/dev/null || true)"

  read -rp "Git user.name [${default_name:-}]: " GH_USER_NAME
  GH_USER_NAME="${GH_USER_NAME:-$default_name}"
  if [[ -z "$GH_USER_NAME" ]]; then error "Git user.name required"; fi

  read -rp "Git user.email [${default_email:-}]: " GH_USER_EMAIL
  GH_USER_EMAIL="${GH_USER_EMAIL:-$default_email}"
  if [[ -z "$GH_USER_EMAIL" ]]; then error "Git user.email required"; fi
}

plugin_is_installed() {
  # gh is installed in base provisioning; this plugin configures auth
  false
}

plugin_install() {
  log "Setting GitHub token via container environment..."
  incus config set "$CONTAINER_NAME" environment.GH_TOKEN="$GH_TOKEN_VALUE"

  # Persist the token in .zshenv so it survives `su -` login shells. Feed the
  # export line over stdin with %q quoting rather than interpolating the value
  # into a remote command string: a token/name/email containing a shell
  # metacharacter (notably a single quote) otherwise breaks the remote shell
  # with `zsh:1: unmatched "`. Mirrors the safe pattern in incs' cmd_set_env.
  local export_line
  printf -v export_line 'export GH_TOKEN=%q\n' "$GH_TOKEN_VALUE"
  printf '%s' "$export_line" | incus exec "$CONTAINER_NAME" -- \
    su - "$HOST_USER" -s /bin/sh -c '
      touch ~/.zshenv
      sed -i "/^export GH_TOKEN=/d" ~/.zshenv
      cat >> ~/.zshenv
    '

  log "Configuring git credential helper and identity..."
  # Build the remote script on the host with %q quoting and run it from stdin,
  # so values are never spliced into a command string and we don't depend on
  # env surviving the `su -` login shell.
  local git_script
  printf -v git_script 'export GH_TOKEN=%q\ngh auth setup-git\ngit config --global user.name %q\ngit config --global user.email %q\n' \
    "$GH_TOKEN_VALUE" "$GH_USER_NAME" "$GH_USER_EMAIL"
  printf '%s' "$git_script" | incus exec "$CONTAINER_NAME" -- \
    su - "$HOST_USER" -s /bin/sh

  unset GH_TOKEN_VALUE
}
