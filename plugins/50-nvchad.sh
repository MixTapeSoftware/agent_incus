PLUGIN_ID="nvchad"
PLUGIN_NAME="Chadception"
PLUGIN_DESC="Chad's nvChad"
PLUGIN_DEFAULT=0

plugin_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c \
    'command -v nvim && test -f ~/.config/nvim/lua/chadrc.lua' &>/dev/null
}

plugin_install() {
  log "Installing Neovim and dependencies..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' <<'EOF'
    set -e
    sudo apt-get update
    sudo apt-get install -y ripgrep
    case "$(uname -m)" in
      x86_64)        arch=x86_64 ;;
      aarch64|arm64) arch=arm64 ;;
      *) echo "Unsupported architecture for Neovim: $(uname -m)" >&2; exit 1 ;;
    esac
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSL "https://github.com/neovim/neovim/releases/latest/download/nvim-linux-$arch.tar.gz" -o "$tmp/nvim.tar.gz"
    sudo tar -C /usr/local --strip-components=1 -xzf "$tmp/nvim.tar.gz"
    nvim --version | head -1
EOF

  log "Cloning NvChad config..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' <<'EOF'
    set -e
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    git clone --depth 1 https://github.com/chadfennell/nvChad "$tmp/nvim"
    mkdir -p ~/.config
    rm -rf ~/.config/nvim
    mv "$tmp/nvim" ~/.config/nvim
EOF

  log "Running headless Neovim to install plugins..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c \
    'nvim --headless "+Lazy! sync" +qa 2>/dev/null' || \
    warn "Lazy sync returned non-zero — open nvim to finish plugin setup"

  log "Installing tree-sitter CLI..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c \
    'sudo npm install -g tree-sitter-cli'

  # install() is async; :wait() keeps nvim open until the parsers are built.
  log "Installing treesitter parsers..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c \
    "nvim --headless -c \"lua require('lazy').load({ plugins = { 'nvim-treesitter' } }); require('nvim-treesitter').install({ 'lua', 'go', 'python', 'typescript', 'bash', 'elixir' }):wait(300000)\" -c qa 2>/dev/null" || \
    warn "Treesitter install returned non-zero — run :TSInstall inside nvim to retry"

  # MasonInstall blocks until done when nvim is headless.
  log "Installing LSPs via Mason..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c \
    'nvim --headless "+MasonInstall lua-language-server gopls pyright typescript-language-server bash-language-server elixir-ls" +qa 2>/dev/null' || \
    warn "MasonInstall returned non-zero — run :Mason inside nvim to retry"
}
