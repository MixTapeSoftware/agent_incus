PLUGIN_ID="matt-pocock-skills"
PLUGIN_NAME="Matt Pocock Skills"
PLUGIN_DESC="Engineering and productivity skills for Claude Code and Codex"
PLUGIN_DEFAULT=1
PLUGIN_CLI_FLAGS="--matt-pocock-skills"

plugin_is_installed() {
  # Codex reads the shared skills directory; Claude Code gets symlinks to it.
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c '
    test -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/setup-matt-pocock-skills/SKILL.md" &&
    test -f "$HOME/.agents/skills/setup-matt-pocock-skills/SKILL.md"
  ' &>/dev/null
}

plugin_install() {
  log "Installing Matt Pocock skills for Claude Code and Codex..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' <<'EOF'
    set -e
    # The skills CLI requires Node >=22.20; Ubuntu 24.04 ships Node 18.
    mise exec --yes node@22 -- npx --yes skills@latest add mattpocock/skills \
      --global --agent claude-code codex --skill '*' --yes
EOF
}
