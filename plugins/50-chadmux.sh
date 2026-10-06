PLUGIN_ID="chadmux"
PLUGIN_NAME="Chadmux"
PLUGIN_DESC="Chad's tmux config + TPM plugins (dracula, yank, vim-tmux-navigator)"
PLUGIN_DEFAULT=0

plugin_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c '
    case "$(git -C "$HOME/.config/tmux" config --get remote.origin.url)" in
      https://github.com/chadfennell/chadmux|https://github.com/chadfennell/chadmux.git) ;;
      *) exit 1 ;;
    esac
    test -d "$HOME/.config/tmux/.git" &&
    test -f "$HOME/.config/tmux/tmux.conf" &&
    test -x "$HOME/.config/tmux/scripts/incus-panes.sh" &&
    test -L "$HOME/.tmux.conf" &&
    test "$HOME/.tmux.conf" -ef "$HOME/.config/tmux/tmux.conf" &&
    test -d "$HOME/.tmux/plugins/tpm"
  ' &>/dev/null
}

plugin_install() {
  log "Installing Chadmux from chadfennell/chadmux..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' <<'CONF'
    set -e
    config_dir="$HOME/.config/tmux"
    upstream="https://github.com/chadfennell/chadmux.git"

    preserve_existing() {
      local path="$1" backup
      if [[ -e "$path" || -L "$path" ]]; then
        backup="$(mktemp -d "$path.backup.XXXXXX")"
        mv "$path" "$backup/${path##*/}"
        echo "Preserved $path in $backup"
      fi
    }

    mkdir -p "$HOME/.config"
    origin=""
    if [[ -d "$config_dir/.git" ]]; then
      origin="$(git -C "$config_dir" config --get remote.origin.url || true)"
    fi
    if [[ "$origin" == "$upstream" || "$origin" == "${upstream%.git}" ]]; then
      git -C "$config_dir" pull --ff-only origin main
    else
      # Finish downloading before moving any existing user configuration.
      staging="$(mktemp -d "$HOME/.config/.chadmux.XXXXXX")"
      trap 'rm -rf "$staging"' EXIT
      git clone --depth 1 --branch main "$upstream" "$staging"
      preserve_existing "$config_dir"
      mv "$staging" "$config_dir"
      trap - EXIT
    fi
    # The legacy config takes precedence over ~/.config/tmux/tmux.conf.
    if [[ ! -L "$HOME/.tmux.conf" || ! "$HOME/.tmux.conf" -ef "$config_dir/tmux.conf" ]]; then
      preserve_existing "$HOME/.tmux.conf"
      ln -s "$config_dir/tmux.conf" "$HOME/.tmux.conf"
    fi
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
