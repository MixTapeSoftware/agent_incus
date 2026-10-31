PLUGIN_ID="mixtape-skills"
PLUGIN_NAME="MixTape Skills"
PLUGIN_DESC="botfight and other agent skills from MixTape Software, for Claude Code, Codex, and Grok"
PLUGIN_DEFAULT=0
PLUGIN_CLI_FLAGS="--mixtape-skills"

# Installed means our checkout, with both links pointing into it: a botfight
# of the user's own doesn't count.
plugin_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c '
    d="$HOME/.local/share/mixtape-skills"
    [ "$(git -C "$d" remote get-url origin 2>/dev/null)" = https://github.com/MixTapeSoftware/skills.git ] &&
    [ "$(readlink "$HOME/.agents/skills/botfight")" = "$d/botfight" ] &&
    [ "$(readlink "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/botfight")" = "$d/botfight" ]
  ' &>/dev/null
}

plugin_install() {
  log "Installing MixTape skills for Claude Code, Codex, and Grok..."
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' <<'EOF'
    set -e
    repo=https://github.com/MixTapeSoftware/skills.git
    dir="$HOME/.local/share/mixtape-skills"
    # Update our own checkout. Otherwise clone beside the path first, so a
    # failed download leaves what's there, then move that aside to a backup
    # name mktemp reserves, so it can't collide with an earlier one.
    if [ "$(git -C "$dir" remote get-url origin 2>/dev/null)" = "$repo" ]; then
      git -C "$dir" pull --ff-only --quiet
    else
      mkdir -p "$(dirname "$dir")"
      new="$(mktemp -d "$dir.new.XXXXXX")"
      if ! git clone --quiet --depth 1 "$repo" "$new"; then rm -rf "$new"; exit 1; fi
      if [ -e "$dir" ] || [ -L "$dir" ]; then
        backup="$(mktemp -d "$dir.backup.XXXXXX")"
        rmdir "$backup"
        mv "$dir" "$backup"
        # Links into the old checkout follow it, so they keep what they had.
        for target in "$HOME/.agents/skills" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills"; do
          for link in "$target"/*; do
            [ -L "$link" ] || continue
            old="$(readlink "$link")"
            case "$old" in "$dir"/*) ln -sfn "$backup/${old#"$dir"/}" "$link" ;; esac
          done
        done
      fi
      mv "$new" "$dir"
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
