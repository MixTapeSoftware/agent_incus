#!/bin/bash
# tests/plugins_cmd_test.sh
# bxn plugins: show says where the optional plugins come from and what the
# next build offers, update fetches a repository source again, set writes the
# config file after a fetch that proves the source. Runs with a real git on
# repositories made here, and nothing else.
# Run: bash tests/plugins_cmd_test.sh

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
assert_not_contains() {
  if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); echo "  ok  $1"
  else FAIL=$((FAIL+1)); echo "  FAIL $1"; echo "    expected not to contain: $2"; echo "    actual: $3"; fi
}

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin" "$SANDBOX/repo/plugins" "$SANDBOX/home"
cp "$SCRIPT_DIR/lib/fake_incus" "$SANDBOX/bin/incus"
chmod +x "$SANDBOX/bin/"*
cp "$REPO_ROOT"/boxen.* "$REPO_ROOT"/bxn* "$SANDBOX/repo/"
cat > "$SANDBOX/repo/plugins/40-agent.sh" <<'EOF'
PLUGIN_ID="agent"; PLUGIN_NAME="Agent"; PLUGIN_DESC="a coding agent"; PLUGIN_AGENT_COMMAND="agent"
EOF
cat > "$SANDBOX/repo/plugins/50-ours.sh" <<'EOF'
PLUGIN_ID="ours"; PLUGIN_NAME="Ours"; PLUGIN_DESC="a built-in plugin"
EOF
plugin_file() { printf 'PLUGIN_ID="%s"; PLUGIN_NAME="%s"; PLUGIN_DESC="%s"\n' "$1" "$2" "$3"; }

mkdir -p "$SANDBOX/src/plugins"
plugin_file theirs Theirs "from the repository" > "$SANDBOX/src/plugins/50-theirs.sh"
git -C "$SANDBOX/src" init -q -b main
git -C "$SANDBOX/src" -c user.name=t -c user.email=t@example.com add -A
git -C "$SANDBOX/src" -c user.name=t -c user.email=t@example.com commit -q -m one
REPO_URL="file://$SANDBOX/src"
commit1="$(git -C "$SANDBOX/src" rev-parse HEAD)"
mkdir -p "$SANDBOX/dir"
plugin_file local Local "from a directory" > "$SANDBOX/dir/50-local.sh"

export PATH="$SANDBOX/bin:$PATH"
export HOME="$SANDBOX/home"
export XDG_DATA_HOME="$SANDBOX/home/.local/share"
export BOXEN_CONFIG_DIR="$SANDBOX/config"
export FAKE_INCUS_STATE="$SANDBOX/state"
unset BOXEN_PLUGINS_SOURCE
CACHE="$XDG_DATA_HOME/boxen/plugin-sources"
# The clone's directory: named for the URL, with a checksum of the whole URL.
CLONE="$CACHE/${SANDBOX//\//_}_src-$(printf '%s' "$REPO_URL" | cksum | cut -d' ' -f1)"
FILE="$BOXEN_CONFIG_DIR/plugins-source"

plugins() { OUT="$(bash "$SANDBOX/repo/bxn" plugins "$@" 2>&1)" && RC=0 || RC=$?; }

echo "nothing configured"
plugins
assert_eq "show works" "0" "$RC"
assert_contains "the plugins are built in" "Optional plugins: built in (nothing configured; bxn plugins set <source> changes that)" "$OUT"
assert_contains "and listed, agents marked" "agent              Agent (agent)" "$OUT"
assert_contains "with the rest" "ours               Ours" "$OUT"
plugins show
assert_eq "show is the default" "0" "$RC"
plugins update
assert_eq "update has nothing to do" "1" "$RC"
assert_contains "and says so" "The optional plugins are the built-in ones; nothing to fetch" "$OUT"

echo "set"
plugins set "$REPO_URL"
assert_eq "it works" "0" "$RC"
[[ "$RC" == 0 ]] || echo "$OUT"
assert_contains "it fetches first" "$REPO_URL fetched, at ${commit1:0:12}" "$OUT"
assert_contains "and lists what it got" "theirs             Theirs" "$OUT"
assert_contains "then says every build uses it" "Every build now takes its optional plugins from $REPO_URL ($FILE)" "$OUT"
assert_eq "the file holds the source after a comment" "$REPO_URL" "$(grep -v '^#' "$FILE")"
plugins set "file://$SANDBOX/nowhere"
assert_eq "a source that can't be fetched is refused" "1" "$RC"
assert_eq "and the file is left as it was" "$REPO_URL" "$(grep -v '^#' "$FILE")"
plugins set "$SANDBOX/home"
assert_eq "a directory without plugins is refused" "1" "$RC"
assert_contains "and says so" "No plugins (*.sh) in $SANDBOX/home" "$OUT"
assert_eq "the file is still as it was" "$REPO_URL" "$(grep -v '^#' "$FILE")"

echo "show, with a repository"
plugins
assert_eq "it works" "0" "$RC"
assert_contains "the source and where it's set" "Optional plugins: $REPO_URL (from $FILE)" "$OUT"
assert_contains "the commit and how to move on" "at commit ${commit1:0:12}, fetched $(date +%Y-%m-%d); bxn plugins update fetches it again" "$OUT"
assert_contains "the agents come from the repository" "Agents, from $SANDBOX/repo/plugins:" "$OUT"
assert_contains "and are listed" "agent              Agent" "$OUT"
assert_not_contains "but not our optional plugin" "Ours" "$OUT"
assert_contains "the source's plugins are listed" "Plugins, from $CLONE/plugins:" "$OUT"
assert_contains "by id and name" "theirs             Theirs" "$OUT"
assert_not_contains "nothing of the user's yet" "Your own" "$OUT"
mkdir -p "$XDG_DATA_HOME/boxen/plugins"
plugin_file mine Mine "my own" > "$XDG_DATA_HOME/boxen/plugins/50-mine.sh"
plugins
assert_contains "the user's own are listed too" "Your own, from $XDG_DATA_HOME/boxen/plugins (these override by id):" "$OUT"
assert_contains "by id" "mine               Mine" "$OUT"

echo "update"
plugins update
assert_eq "it works" "0" "$RC"
assert_contains "nothing moved" "$REPO_URL is still at ${commit1:0:12}" "$OUT"
plugin_file more More "a second one" > "$SANDBOX/src/plugins/60-more.sh"
git -C "$SANDBOX/src" -c user.name=t -c user.email=t@example.com add -A
git -C "$SANDBOX/src" -c user.name=t -c user.email=t@example.com commit -q -m two
commit2="$(git -C "$SANDBOX/src" rev-parse HEAD)"
plugins update
assert_eq "it works" "0" "$RC"
assert_contains "it says what moved" "$REPO_URL moved from ${commit1:0:12} to ${commit2:0:12}" "$OUT"
assert_contains "and lists the new plugin" "more               More" "$OUT"
assert_eq "the clone is at the new commit" "$commit2" "$(git -C "$CLONE" rev-parse HEAD)"
git -C "$SANDBOX/src" tag v1 "$commit1"
plugins update "$REPO_URL#v1"
assert_eq "update with a source fetches that one" "0" "$RC"
assert_contains "at its commit" "$REPO_URL#v1 moved from ${commit2:0:12} to ${commit1:0:12}" "$OUT"
assert_eq "without changing the file" "$REPO_URL" "$(grep -v '^#' "$FILE")"
plugins update builtin
assert_eq "update builtin is refused" "1" "$RC"
assert_contains "with where updates come from" "come with the boxen repository" "$OUT"
mv "$SANDBOX/src" "$SANDBOX/src.away"
plugins update
assert_eq "an unreachable repository still exits 0 with the clone" "0" "$RC"
assert_contains "and warns" "Could not fetch the plugins from $REPO_URL; using the copy from last time" "$OUT"
mv "$SANDBOX/src.away" "$SANDBOX/src"

echo "a directory"
plugins set "$SANDBOX/dir"
assert_eq "set works" "0" "$RC"
assert_contains "and says there's nothing to fetch" "$SANDBOX/dir is a directory, read as it is at each build; nothing to fetch" "$OUT"
plugins
assert_contains "show names it" "Optional plugins: $SANDBOX/dir (from $FILE)" "$OUT"
assert_not_contains "without a commit" "at commit" "$OUT"
assert_contains "its plugins" "local              Local" "$OUT"
plugins update
assert_eq "update works" "0" "$RC"
assert_contains "and says there's nothing to fetch" "nothing to fetch" "$OUT"

echo "a token in the URL"
echo "https://user:s3cret@example.com/acme/plugins.git" > "$FILE"
plugins
assert_eq "show works" "0" "$RC"
assert_contains "the source is shown without it" "Optional plugins: https://example.com/acme/plugins.git (from $FILE)" "$OUT"
assert_not_contains "and the token appears nowhere" "s3cret" "$OUT"

echo "a repository not fetched yet"
echo "acme/boxen-plugins" > "$FILE"
plugins
assert_eq "show works" "0" "$RC"
assert_contains "it says so" "not fetched yet: the first build does, or bxn plugins update" "$OUT"
assert_not_contains "and lists no plugins from it" "Plugins, from" "$OUT"
echo "$SANDBOX/gone" > "$FILE"
plugins
assert_eq "a source that is nowhere fails" "1" "$RC"
assert_contains "and says so" "$SANDBOX/gone isn't a repository or a directory on this host" "$OUT"

echo "the variable"
echo "$SANDBOX/dir" > "$FILE"
BOXEN_PLUGINS_SOURCE="$REPO_URL" plugins
assert_contains "it beats the file" "Optional plugins: $REPO_URL (from BOXEN_PLUGINS_SOURCE)" "$OUT"
assert_contains "and says what it overrode" "$FILE says $SANDBOX/dir, which the variable overrides" "$OUT"
BOXEN_PLUGINS_SOURCE=builtin plugins
assert_contains "builtin in the variable" "Optional plugins: built in (BOXEN_PLUGINS_SOURCE=builtin)" "$OUT"
BOXEN_PLUGINS_SOURCE="$REPO_URL" plugins set builtin
assert_eq "set builtin works" "0" "$RC"
assert_eq "and writes it" "builtin" "$(grep -v '^#' "$FILE")"
assert_contains "warning about the variable" "BOXEN_PLUGINS_SOURCE=$REPO_URL is set in this shell and beats the file" "$OUT"
plugins
assert_contains "the file saying builtin" "Optional plugins: built in ($FILE says builtin)" "$OUT"

echo "help"
plugins -h
assert_eq "help works" "0" "$RC"
assert_contains "and explains" "Usage: bxn plugins [show]" "$OUT"
plugins frobnicate
assert_eq "an unknown command fails" "1" "$RC"
plugins set
assert_eq "set without a source fails" "1" "$RC"
assert_contains "bxn -h lists it" "plugins [show|update|set ...]" "$(bash "$SANDBOX/repo/bxn" -h)"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
