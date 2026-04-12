COMPONENT_ID="gh-auth"
COMPONENT_NAME="GitHub Auth"
COMPONENT_DESC="GitHub token & git credentials"
COMPONENT_DEFAULT=0
COMPONENT_CLI_FLAGS="--gh-token"
COMPONENT_NEEDS_PROMPT=1

component_prompt() {
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

component_is_installed() {
  # gh is installed in base provisioning; this component configures auth
  false
}

component_install() {
  log "Setting GitHub token via container environment..."
  incus config set "$CONTAINER_NAME" environment.GH_TOKEN="$GH_TOKEN_VALUE"

  # Write to .zshenv so the token survives `su -` login shells
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c \
    "echo 'export GH_TOKEN=\"$GH_TOKEN_VALUE\"' >> ~/.zshenv"

  log "Configuring git credential helper and identity..."
  incus exec "$CONTAINER_NAME" --env "GH_TOKEN=$GH_TOKEN_VALUE" -- su - "$HOST_USER" -c "
    gh auth setup-git
    git config --global user.name '$GH_USER_NAME'
    git config --global user.email '$GH_USER_EMAIL'
  "
  unset GH_TOKEN_VALUE
}
