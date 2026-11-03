PLUGIN_ID="vibe-wise"
PLUGIN_NAME="VibeWise"
PLUGIN_DESC="Claude Code plugin for learning to build while Claude writes the code (/vibe-wise:learn)"
PLUGIN_DEFAULT=0
PLUGIN_CLI_FLAGS="--vibe-wise"
# A Claude Code plugin: in any other agent's container it's refused with a
# message naming --agent claude.
PLUGIN_REQUIRES="claude-code"

# From Anthropic's plugin directory, which Claude Code has built in. It's a
# third-party plugin (github.com/nykooi1/vibe-wise) the directory lists; it
# downloads from github.com, already on the egress baseline, and needs no
# Claude login.
VIBE_WISE_PLUGIN="vibe-wise@anthropic-plugin-directory"

plugin_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c \
    "grep -qF '\"$VIBE_WISE_PLUGIN\"' \"\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/plugins/installed_plugins.json\"" &>/dev/null
}

plugin_install() {
  log "Installing the VibeWise plugin for Claude Code..."
  # No -y: if the directory ever declares a command to run for it, the
  # install stops instead of running it unseen.
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c \
    "\"\$HOME/.local/bin/claude\" plugin install '$VIBE_WISE_PLUGIN'" </dev/null
}
