PLUGIN_ID="nvchad"
PLUGIN_NAME="Chadception"
PLUGIN_DESC="Chad's nvChad"
PLUGIN_DEFAULT=0

plugin_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c \
    'command -v nvim && test -f ~/.config/nvim/lua/chadrc.lua' &>/dev/null
}

# Run a bash script (stdin) as the container user. Headless nvim is noisy, so
# its output is held back and printed only when the step fails.
_nvchad_quiet() {
  local out
  if out="$(incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' 2>&1)"; then
    return 0
  fi
  printf '%s\n' "$out" >&2
  return 1
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
  _nvchad_quiet <<'EOF' || warn "Lazy sync failed (output above) — open nvim to finish plugin setup"
    nvim --headless "+Lazy! sync" +qa
EOF

  log "Installing tree-sitter CLI..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c \
    'sudo npm install -g tree-sitter-cli'

  # The Lua goes through a file: nvim exits 0 after a Lua error in a -c
  # command, so the script reports failure itself with cquit.
  log "Installing treesitter parsers..."
  _nvchad_quiet <<'EOF' || warn "Treesitter parser install failed (output above) — run :TSInstall inside nvim to retry"
    set -e
    script="$(mktemp --suffix=.lua)"
    trap 'rm -f "$script"' EXIT
    cat > "$script" <<'LUA'
-- install() is async; wait() blocks until every parser is built.
require('lazy').load({ plugins = { 'nvim-treesitter' } })
local ok, built = pcall(function()
  return require('nvim-treesitter')
    .install({ 'lua', 'go', 'python', 'typescript', 'bash', 'elixir' })
    :wait(300000)
end)
if not (ok and built) then
  io.stderr:write('treesitter install failed: ' .. tostring(built) .. '\n')
  vim.cmd('cquit 1')
end
LUA
    nvim --headless -c "luafile $script" -c qa
EOF

  # MasonInstall blocks until done when nvim is headless, and exits non-zero
  # if a package fails.
  log "Installing LSPs via Mason..."
  _nvchad_quiet <<'EOF' || warn "Mason install failed (output above) — run :Mason inside nvim to retry"
    nvim --headless -c "MasonInstall lua-language-server gopls pyright typescript-language-server bash-language-server elixir-ls" -c qa
EOF
}
