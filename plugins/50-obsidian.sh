PLUGIN_ID="obsidian"
PLUGIN_NAME="Obsidian Headless"
PLUGIN_DESC="Obsidian Sync and Publish from the command line (ob)"
PLUGIN_DEFAULT=0
PLUGIN_CLI_FLAGS="--obsidian"
# Obsidian's API (api), Publish (publish, and the host a site is served from)
# and the Sync server a vault is assigned to (sync-N). upload: a vault's notes
# go to these, which is what Sync and Publish are for. The baseline lists them
# too; they stay here for a host whose approved baseline is older than that.
PLUGIN_EGRESS_ALLOW="*.obsidian.md"
# Asks for an account's email, password and 2FA code, so the user runs it.
PLUGIN_LOGIN_COMMAND="ob login"

# ob needs Node 22 or later and Ubuntu 24.04 ships 18, so it runs on a Node 22
# from mise, out of a prefix of its own: the better-sqlite3 it's built with
# stays beside it, whatever Node the workspace or the user picks.

plugin_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c '
    test -x "$HOME/.local/bin/ob" &&
    test -f "$HOME/.local/share/obsidian-headless/lib/node_modules/obsidian-headless/cli.js"
  ' &>/dev/null
}

plugin_install() {
  log "Installing Obsidian Headless..."
  # Installed as the user, with no login: that's PLUGIN_LOGIN_COMMAND, later.
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c 'bash -s' <<'EOF'
    set -euo pipefail
    prefix="$HOME/.local/share/obsidian-headless"
    mise exec --yes node@22 -- npm install --global --prefix "$prefix" obsidian-headless
    # The launcher pins the same Node: the npm one would take the first node
    # on PATH, and on Node 18 ob stops with "crypto is not defined". Under an
    # allowlist Node warns that its proxy support is experimental, a moment
    # after ob has asked "Email: ": the prompt then reads as a hang, so the
    # warning is off.
    mkdir -p "$HOME/.local/bin"
    printf '%s\n' '#!/bin/sh' \
      '# Obsidian Headless on the Node 22 it was installed with (boxen obsidian plugin).' \
      'exec mise exec node@22 -- node --disable-warning=UNDICI-EHPA "$HOME/.local/share/obsidian-headless/lib/node_modules/obsidian-headless/cli.js" "$@"' \
      > "$HOME/.local/bin/ob"
    chmod +x "$HOME/.local/bin/ob"
    "$HOME/.local/bin/ob" --version >/dev/null ||
      { rm -f "$HOME/.local/bin/ob"; echo "ob doesn't run after install" >&2; exit 1; }
EOF
}
