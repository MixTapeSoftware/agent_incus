#!/bin/bash
# tests/plugins_source_test.sh
# --plugins, BOXEN_PLUGINS_SOURCE and ~/.config/boxen/plugins-source: the
# optional plugins come from a repository or a directory in place of ours,
# the built-in agents stay, the clone is cached and reused when a fetch
# fails, and the container records the source. Runs boxen.create against the
# fake `incus` with a real git, on repositories made here.
# Run: bash tests/plugins_source_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
exec </dev/null
command -v git >/dev/null || { echo "needs git"; exit 1; }

PASS=0
FAIL=0
assert_eq() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); echo "  ok  $1"
  else FAIL=$((FAIL+1)); echo "  FAIL $1"; echo "    expected: $2"; echo "    actual:   $3"; fi
}
assert_contains() {
  if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); echo "  ok  $1"
  else FAIL=$((FAIL+1)); echo "  FAIL $1"; echo "    expected to contain: $2"; echo "    actual: $3"; fi
}

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin" "$SANDBOX/repo/plugins" "$SANDBOX/ws" "$SANDBOX/home"
cp "$SCRIPT_DIR/lib/fake_incus" "$SANDBOX/bin/incus"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/curl"
# git is real for the plugin sources and this script's own repositories, and
# a no-op elsewhere, so the fake container downloads nothing.
REAL_GIT="$(command -v git)"
cat > "$SANDBOX/bin/git" <<EOF
#!/bin/sh
case "\$1:\$2" in
  -C:$SANDBOX/home/.local/share/boxen/plugin-sources/*|-C:$SANDBOX/src*) exec "$REAL_GIT" "\$@" ;;
esac
exit 0
EOF
chmod +x "$SANDBOX/bin/"*
cp "$REPO_ROOT"/boxen.* "$SANDBOX/repo/"
cp -R "$REPO_ROOT/egress" "$SANDBOX/repo/egress"

# Our plugins: an agent and an optional one, each recording that it ran.
cat > "$SANDBOX/repo/plugins/40-agent.sh" <<EOF
PLUGIN_ID="agent"; PLUGIN_NAME="Agent"; PLUGIN_DESC="a coding agent"; PLUGIN_DEFAULT=1
PLUGIN_AGENT_COMMAND="agent"
plugin_install() { echo "agent" >> "$SANDBOX/ran"; }
EOF
cat > "$SANDBOX/repo/plugins/50-ours.sh" <<EOF
PLUGIN_ID="ours"; PLUGIN_NAME="Ours"; PLUGIN_DESC="a built-in plugin"; PLUGIN_DEFAULT=1
plugin_install() { echo "ours" >> "$SANDBOX/ran"; }
EOF

# A plugin file that records its own name and the source it came from.
plugin_file() {
  cat <<EOF
PLUGIN_ID="$1"; PLUGIN_NAME="$2"; PLUGIN_DESC="$3"; PLUGIN_DEFAULT=1
plugin_install() { echo "$1" >> "$SANDBOX/ran"; }
EOF
}

# A repository with its plugins under plugins/, served over file://.
mkdir -p "$SANDBOX/src/plugins"
plugin_file theirs Theirs "from the repository" > "$SANDBOX/src/plugins/50-theirs.sh"
git -C "$SANDBOX/src" init -q -b main
git -C "$SANDBOX/src" -c user.name=t -c user.email=t@example.com add -A
git -C "$SANDBOX/src" -c user.name=t -c user.email=t@example.com commit -q -m one
REPO_URL="file://$SANDBOX/src"
commit1="$(git -C "$SANDBOX/src" rev-parse HEAD)"

# A directory with its plugins at the top level.
mkdir -p "$SANDBOX/dir"
plugin_file local Local "from a directory" > "$SANDBOX/dir/50-local.sh"

export PATH="$SANDBOX/bin:$PATH"
export HOME="$SANDBOX/home"
export XDG_DATA_HOME="$SANDBOX/home/.local/share"
export BOXEN_NET_SUBNET=10.201.0.1/16
export BOXEN_UFW_CONF="$SANDBOX/no-ufw.conf"
export FAKE_EGRESS_CTL="$SCRIPT_DIR/lib/fake_egress_ctl"
export FAKE_INCUS_VERSION=7.5.1
unset BOXEN_PLUGINS_SOURCE

fresh() {
  export FAKE_INCUS_STATE="$SANDBOX/state-$RANDOM$RANDOM"
  export BOXEN_LOCK_DIR="$FAKE_INCUS_STATE/lock"
  export BOXEN_CONFIG_DIR="$FAKE_INCUS_STATE/config"
  rm -f "$SANDBOX/ran"
}
init() { local n="$1"; shift; bash "$SANDBOX/repo/boxen.create" --name "$n" "$@" --agent agent --no-tui --egress off -p "$SANDBOX/ws" >"$SANDBOX/out" 2>&1 && RC=0 || RC=$?; }
cfg() { cat "$FAKE_INCUS_STATE/instances/$1/config/$2" 2>/dev/null; }
ran() { sort "$SANDBOX/ran" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
CACHE="$XDG_DATA_HOME/boxen/plugin-sources"

echo "the built-in plugins"
fresh
init box
assert_eq "it builds" "0" "$RC"
[[ "$RC" == 0 ]] || tail -20 "$SANDBOX/out"
assert_eq "ours run" "agent ours" "$(ran)"
assert_eq "no source is recorded" "" "$(cfg box user.boxen.plugins.source)"
assert_eq "the dry run says so" "Plugins:     built in" "$(bash "$SANDBOX/repo/boxen.create" --name dry --agent agent --no-tui --egress off -p "$SANDBOX/ws" --dry-run 2>/dev/null | grep '^Plugins:')"

echo "a repository"
fresh
init rbox --plugins "$REPO_URL"
assert_eq "it builds" "0" "$RC"
[[ "$RC" == 0 ]] || tail -20 "$SANDBOX/out"
assert_eq "its plugins run in place of ours, and the agent stays" "agent theirs" "$(ran)"
assert_eq "the source is recorded" "$REPO_URL" "$(cfg rbox user.boxen.plugins.source)"
assert_eq "and the commit" "$commit1" "$(cfg rbox user.boxen.plugins.commit)"
assert_contains "the build says where the plugins came from" "Optional plugins from $REPO_URL at ${commit1:0:12} (--plugins)" "$(cat "$SANDBOX/out")"
assert_eq "one clone, named for the URL" "1" "$(ls -d "$CACHE"/* | wc -l | tr -d ' ')"
assert_contains "under the URL's name" "${SANDBOX//\//_}_src" "$(ls "$CACHE")"

echo "the repository moves"
plugin_file theirs Theirs "from the repository, changed" > "$SANDBOX/src/plugins/50-theirs.sh"
plugin_file more More "a second one" > "$SANDBOX/src/plugins/60-more.sh"
git -C "$SANDBOX/src" -c user.name=t -c user.email=t@example.com add -A
git -C "$SANDBOX/src" -c user.name=t -c user.email=t@example.com commit -q -m two
commit2="$(git -C "$SANDBOX/src" rev-parse HEAD)"
git -C "$SANDBOX/src" tag v1 "$commit1"
fresh
init rbox2 "--plugins=$REPO_URL"
assert_eq "it builds" "0" "$RC"
[[ "$RC" == 0 ]] || tail -20 "$SANDBOX/out"
assert_eq "the next build has the new plugins" "agent more theirs" "$(ran)"
assert_eq "at the new commit" "$commit2" "$(cfg rbox2 user.boxen.plugins.commit)"
fresh
init tbox --plugins "$REPO_URL#v1"
assert_eq "a tag builds" "0" "$RC"
assert_eq "at its commit" "$commit1" "$(cfg tbox user.boxen.plugins.commit)"
assert_eq "with its plugins" "agent theirs" "$(ran)"
assert_eq "the ref is part of the recorded source" "$REPO_URL#v1" "$(cfg tbox user.boxen.plugins.source)"
assert_eq "still one clone" "1" "$(ls -d "$CACHE"/* | wc -l | tr -d ' ')"

echo "the repository is unreachable"
mv "$SANDBOX/src" "$SANDBOX/src.away"
fresh
init obox --plugins "$REPO_URL"
assert_eq "it builds from the clone" "0" "$RC"
[[ "$RC" == 0 ]] || tail -20 "$SANDBOX/out"
assert_contains "and says so" "Could not fetch the plugins from $REPO_URL; using the copy from last time" "$(cat "$SANDBOX/out")"
assert_eq "at the commit it had" "$commit1" "$(cfg obox user.boxen.plugins.commit)"
fresh
init nbox --plugins "file://$SANDBOX/nowhere"
assert_eq "a repository never fetched refuses" "1" "$RC"
assert_contains "and says why" "Could not fetch the plugins from file://$SANDBOX/nowhere" "$(cat "$SANDBOX/out")"
mv "$SANDBOX/src.away" "$SANDBOX/src"

echo "two URLs that read the same as a name"
make_repo() {
  mkdir -p "$1/plugins"
  plugin_file "$2" "$2" "from $1" > "$1/plugins/50-$2.sh"
  git -C "$1" init -q -b main
  git -C "$1" -c user.name=t -c user.email=t@example.com add -A
  git -C "$1" -c user.name=t -c user.email=t@example.com commit -q -m one
}
make_repo "$SANDBOX/src2/x" slash
make_repo "$SANDBOX/src2_x" under
fresh
init xbox --plugins "file://$SANDBOX/src2/x"
assert_eq "the first builds with its plugins" "agent slash" "$(ran)"
fresh
init ybox --plugins "file://$SANDBOX/src2_x"
assert_eq "the second builds" "0" "$RC"
[[ "$RC" == 0 ]] || tail -20 "$SANDBOX/out"
assert_eq "with its own plugins, not the first's" "agent under" "$(ran)"
assert_eq "from a clone of its own" "2" "$(ls -d "$CACHE"/*src2* | wc -l | tr -d ' ')"
for _x in "$CACHE"/*src2*; do git -C "$_x" remote set-url origin "file://$SANDBOX/elsewhere"; done
fresh
init zbox --plugins "file://$SANDBOX/src2/x"
assert_eq "a clone of another URL is refused" "1" "$RC"
assert_contains "and says so" "is a clone of another repository, not file://$SANDBOX/src2/x" "$(cat "$SANDBOX/out")"
rm -rf "$CACHE"/*src2*

echo "a directory"
fresh
init dbox --plugins "$SANDBOX/dir"
assert_eq "it builds" "0" "$RC"
[[ "$RC" == 0 ]] || tail -20 "$SANDBOX/out"
assert_eq "its plugins run, from the top level" "agent local" "$(ran)"
assert_eq "the source is recorded" "$SANDBOX/dir" "$(cfg dbox user.boxen.plugins.source)"
assert_eq "without a commit" "" "$(cfg dbox user.boxen.plugins.commit)"
fresh
init ebox --plugins "$SANDBOX/ws"
assert_eq "a directory without plugins refuses" "1" "$RC"
assert_contains "and says where it looked" "No plugins (*.sh) in $SANDBOX/ws: looked in $SANDBOX/ws" "$(cat "$SANDBOX/out")"
fresh
init fbox --plugins "$SANDBOX/dir#main"
assert_eq "a directory takes no ref" "1" "$RC"

echo "the user directory still layers on top"
mkdir -p "$XDG_DATA_HOME/boxen/plugins"
plugin_file theirs Theirs "the user's own" > "$XDG_DATA_HOME/boxen/plugins/50-theirs.sh"
sed -i.bak 's/echo "theirs"/echo "user-theirs"/' "$XDG_DATA_HOME/boxen/plugins/50-theirs.sh"
plugin_file mine Mine "the user's own" > "$XDG_DATA_HOME/boxen/plugins/50-mine.sh"
fresh
init ubox --plugins "$REPO_URL#v1"
assert_eq "it builds" "0" "$RC"
assert_eq "the user's plugin overrides the source's of the same id, and adds its own" "agent mine user-theirs" "$(ran)"
rm -rf "$XDG_DATA_HOME/boxen/plugins"

echo "the setting"
fresh
mkdir -p "$BOXEN_CONFIG_DIR"
printf '# where the optional plugins come from\n\n  %s  \n' "$SANDBOX/dir" > "$BOXEN_CONFIG_DIR/plugins-source"
init cbox
assert_eq "the config file sets the source" "agent local" "$(ran)"
assert_contains "and is named as where it came from" "($BOXEN_CONFIG_DIR/plugins-source)" "$(cat "$SANDBOX/out")"
fresh
mkdir -p "$BOXEN_CONFIG_DIR"
printf '%s\n' "$SANDBOX/dir" > "$BOXEN_CONFIG_DIR/plugins-source"
BOXEN_PLUGINS_SOURCE="$REPO_URL#v1" init vbox
assert_eq "the variable beats the file" "agent theirs" "$(ran)"
fresh
mkdir -p "$BOXEN_CONFIG_DIR"
printf '%s\n' "$SANDBOX/dir" > "$BOXEN_CONFIG_DIR/plugins-source"
BOXEN_PLUGINS_SOURCE="$REPO_URL#v1" init wbox --plugins builtin
assert_eq "--plugins builtin beats both" "agent ours" "$(ran)"
assert_eq "and records nothing" "" "$(cfg wbox user.boxen.plugins.source)"

echo "a GitHub name"
fresh
# Nothing is fetched from GitHub here: git is told to look elsewhere for it,
# so the fetch fails, and the clone it set up shows the URL the name became.
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://$SANDBOX/nowhere/.insteadOf" GIT_CONFIG_VALUE_0="https://github.com/" \
  init gbox --plugins "someone/plugins"
assert_eq "it refuses when it can't fetch" "1" "$RC"
_g="$(ls "$CACHE" | grep github)"
assert_eq "the clone is named for github.com" "github.com_someone_plugins" "${_g%-*}"
assert_eq "with GitHub's URL" "https://github.com/someone/plugins.git" "$(git -C "$CACHE/$_g" config remote.origin.url)"

echo "a URL with a token in it"
fresh
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://$SANDBOX/nowhere/.insteadOf" GIT_CONFIG_VALUE_0="https://someone:s3cret@example.com/" \
  init kbox --plugins "https://someone:s3cret@example.com/plugins.git"
assert_eq "it refuses when it can't fetch" "1" "$RC"
assert_contains "and names the URL" "Could not fetch the plugins from https://example.com/plugins.git" "$(cat "$SANDBOX/out")"
assert_eq "without the token" "" "$(grep s3cret "$SANDBOX/out" || true)"
assert_eq "nor in the clone's name" "" "$(ls "$CACHE" | grep s3cret || true)"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
