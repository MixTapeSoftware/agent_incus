PLUGIN_ID="gh-auth"
PLUGIN_NAME="GitHub Auth"
PLUGIN_DESC="GitHub token & git credentials"
# The git identity (user.name, user.email) is set for every container by
# boxen.init, from the host; this plugin only handles the token.
PLUGIN_DEFAULT=0
PLUGIN_CLI_FLAGS="--gh-token"
PLUGIN_NEEDS_PROMPT=1

plugin_prompt() {
  echo ""
  log "GitHub auth requires a fine-grained personal access token"
  echo "Create one at: https://github.com/settings/tokens?type=beta"
  echo "Recommended scopes: Contents (read/write), Metadata (read)"
  read_secret GH_TOKEN_VALUE "Enter GitHub token: "
  if [[ -z "$GH_TOKEN_VALUE" ]]; then error "GitHub token required"; fi
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
  # with `zsh:1: unmatched "`. Mirrors the safe pattern in bxn's cmd_set_env.
  local export_line
  printf -v export_line 'export GH_TOKEN=%q\n' "$GH_TOKEN_VALUE"
  printf '%s' "$export_line" | incus exec "$CONTAINER_NAME" -- \
    su - "$HOST_USER" -s /bin/sh -c '
      touch ~/.zshenv
      sed -i "/^export GH_TOKEN=/d" ~/.zshenv
      cat >> ~/.zshenv
    '

  log "Configuring git's credential helper..."
  # The token goes in on stdin, never into a command string, and doesn't
  # depend on env surviving the `su -` login shell.
  printf '%s\n' "$GH_TOKEN_VALUE" | incus exec "$CONTAINER_NAME" -- \
    su - "$HOST_USER" -s /bin/sh -c 'IFS= read -r t && GH_TOKEN="$t" gh auth setup-git'

  unset GH_TOKEN_VALUE
}
