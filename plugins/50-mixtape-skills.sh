PLUGIN_ID="mixtape-skills"
PLUGIN_NAME="MixTape Skills"
PLUGIN_DESC="botfight and other agent skills from MixTape Software, for Claude Code, Codex, and Grok"
PLUGIN_DEFAULT=0
PLUGIN_CLI_FLAGS="--mixtape-skills"

plugin_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c '
    test -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/botfight/SKILL.md" &&
    test -f "$HOME/.agents/skills/botfight/SKILL.md"
  ' &>/dev/null
}

plugin_install() {
  log "Installing MixTape skills for Claude Code, Codex, and Grok..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' <<'EOF'
    set -e
    repo=https://github.com/MixTapeSoftware/skills.git
    dir="$HOME/.local/share/mixtape-skills"
    # Update our own checkout; move anything else at that path aside.
    if [ "$(git -C "$dir" remote get-url origin 2>/dev/null)" = "$repo" ]; then
      git -C "$dir" pull --ff-only --quiet
    else
      if [ -e "$dir" ] || [ -L "$dir" ]; then mv "$dir" "$dir.backup.$(date +%s)"; fi
      mkdir -p "$(dirname "$dir")"
      git clone --quiet --depth 1 "$repo" "$dir"
    fi
    # Each top-level directory with a SKILL.md is a skill. Codex and Grok
    # read ~/.agents/skills; Claude Code gets its own links. A skill there
    # that isn't one of ours is left alone.
    for target in "$HOME/.agents/skills" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills"; do
      mkdir -p "$target"
      for skill in "$dir"/*/SKILL.md; do
        [ -f "$skill" ] || continue
        src="$(dirname "$skill")"
        name="$(basename "$src")"
        if [ ! -e "$target/$name" ] && [ ! -L "$target/$name" ]; then
          ln -s "$src" "$target/$name"
        elif [ -L "$target/$name" ] && [ "$(readlink "$target/$name")" = "$src" ]; then
          :
        else
          echo "[!] $target/$name already exists and isn't from MixTape Skills; left it alone" >&2
        fi
      done
    done
EOF
}
