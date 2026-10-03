PLUGIN_ID="nvchad"
PLUGIN_NAME="Chadception"
PLUGIN_DESC="Chad's nvChad"
PLUGIN_DEFAULT=0

plugin_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'command -v nvim' &>/dev/null
}

plugin_install() {
  log "Installing Neovim and dependencies..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' <<'EOF'
    set -e
    sudo apt-get install -y ripgrep
    curl -fsSLO https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz
    sudo tar -C /usr/local --strip-components=1 -xzf nvim-linux-x86_64.tar.gz
    rm nvim-linux-x86_64.tar.gz
    nvim --version | head -1
EOF

  log "Cloning NvChad config..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' <<'EOF'
    set -e
    rm -rf ~/.config/nvim
    git clone https://github.com/chadfennell/nvChad ~/.config/nvim --depth 1
EOF

  log "Running headless Neovim to install plugins..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c \
    'nvim --headless "+Lazy! sync" +qa 2>/dev/null' || \
    warn "Lazy sync returned non-zero — open nvim to finish plugin setup"

  log "Installing tree-sitter CLI..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c \
    'sudo npm install -g tree-sitter-cli'

  log "Installing treesitter parsers..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c \
    'nvim --headless "+TSInstall lua go python typescript bash elixir" +qa 2>/dev/null' || \
    warn "TSInstall returned non-zero — run :TSInstall inside nvim to retry"

  log "Installing LSPs via Mason..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c \
    'nvim --headless "+MasonInstall lua-language-server gopls pyright typescript-language-server bash-language-server elixir-ls" +qa 2>/dev/null' || \
    warn "MasonInstall returned non-zero — run :Mason inside nvim to retry"
}
