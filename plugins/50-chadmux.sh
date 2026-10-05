PLUGIN_ID="chadmux"
PLUGIN_NAME="Chadmux"
PLUGIN_DESC="Chad's tmux config + TPM plugins (dracula, yank, vim-tmux-navigator)"
PLUGIN_DEFAULT=0

plugin_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c '
    test -d "$HOME/.config/tmux/.git" &&
    test -f "$HOME/.config/tmux/tmux.conf" &&
    test -x "$HOME/.config/tmux/scripts/incus-panes.sh" &&
    test "$HOME/.tmux.conf" -ef "$HOME/.config/tmux/tmux.conf" &&
    test -d "$HOME/.tmux/plugins/tpm"
  ' &>/dev/null
}

plugin_install() {
  log "Installing Chadmux from chadfennell/chadmux..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' <<'CONF'
    set -e
    config_dir="$HOME/.config/tmux"
    mkdir -p "$HOME/.config"
    if [[ -d "$config_dir/.git" ]]; then
      git -C "$config_dir" pull --ff-only origin main
    else
      git clone --depth 1 --branch main https://github.com/chadfennell/chadmux.git "$config_dir"
    fi
    # The legacy config takes precedence over ~/.config/tmux/tmux.conf.
    ln -sfn "$config_dir/tmux.conf" "$HOME/.tmux.conf"
CONF

  log "Cloning TPM..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c '
    set -e
    mkdir -p ~/.tmux/plugins
    if [[ ! -d ~/.tmux/plugins/tpm ]]; then
      git clone --depth 1 https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
    fi
  '

  log "Installing TPM plugins..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c '~/.tmux/plugins/tpm/bin/install_plugins' || \
    warn "TPM plugin install returned non-zero — run prefix + I inside tmux to retry"
}
