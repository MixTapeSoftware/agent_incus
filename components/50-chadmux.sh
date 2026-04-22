COMPONENT_ID="chadmux"
COMPONENT_NAME="Chadmux"
COMPONENT_DESC="Chad's tmux config + TPM plugins (dracula, yank, vim-tmux-navigator)"
COMPONENT_DEFAULT=0

component_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'test -d "$HOME/.tmux/plugins/tpm"' &>/dev/null
}

component_install() {
  log "Writing ~/.tmux.conf..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'cat > ~/.tmux.conf' <<'CONF'
# Basic settings
set -g base-index 1
setw -g pane-base-index 1
set -g default-shell /usr/bin/zsh
set -g history-limit 2000
set -g mouse off
set -g status on

# Status bar colors
set -g status-style bg=green,fg=black
set -g status-left "[#{session_name}] "
set -g status-right "\"#{=21:pane_title}\" %H:%M %d-%b-%y"

# Message colors
set -g message-style bg=yellow,fg=black
set -g message-command-style bg=black,fg=yellow

# Pane display colors
set -g display-panes-active-colour red
set -g display-panes-colour blue

set -g prefix C-s
setw -g mode-keys vi
bind-key h select-pane -L
bind-key j select-pane -D
bind-key k select-pane -U
bind-key l select-pane -R

# Active pane border stands out
set -g pane-border-status bottom
set -g pane-border-format "#[align=right]#{?pane_active,#[bg=#87d787 fg=black] #{pane_title}: #{pane_current_command} ,#[bg=#444444 fg=white] #{pane_title}: #{pane_current_command} }#[default]"
set -g pane-border-lines heavy
set -g window-active-style bg=terminal
set -g window-style bg=#1a1a2e

## Plugin Meownager
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-sensible'

# Pluguns'
set -g @plugin 'tmux-plugins/tmux-yank'
set -s set-clipboard on

set -g @plugin 'christoomey/vim-tmux-navigator'
set -g @plugin 'dracula/tmux'

set -g @dracula-show-powerline true
set -g @dracula-show-flags true
set -g @dracula-show-left-icon session
set -g status-position top
set -g @dracula-plugins "cpu-usage ram-usage"
set -g @dracula-show-weather false
set -g status on
set -g @dracula-show-window-tabs true

# Push current pane to a session
bind-key M command-prompt -p "Push pane to:" "join-pane -dt '%%'"

# Toggle to last session
bind-key W switch-client -l

run '~/.tmux/plugins/tpm/tpm'
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
