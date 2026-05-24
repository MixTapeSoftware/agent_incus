PLUGIN_ID="fzf-bat"
PLUGIN_NAME="fzf + bat"
PLUGIN_DESC="Interactive search & file preview"
PLUGIN_DEFAULT=0

plugin_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'command -v fzf' &>/dev/null
}

plugin_install() {
  log "Installing fzf and bat via mise..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' <<'EOF'
  set -e
  export MISE_TRUSTED_CONFIG_PATHS="/workspace"
  mise use -g go@latest fzf@latest bat@latest

  cat >> ~/.zshrc <<'FZF'

# fzf + bat aliases
alias f="fzf --preview 'bat {-1} --color=always'"
gdiff() {
  local preview="git diff $@ --color=always -- {-1}"
  git diff $@ --name-only | fzf -m --ansi --preview $preview
}
FZF
EOF
}
