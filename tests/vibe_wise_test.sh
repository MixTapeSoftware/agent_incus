#!/bin/bash
# tests/vibe_wise_test.sh
# The VibeWise plugin is an opt-in Claude Code plugin: it needs the Claude
# Code agent, installs vibe-wise from Anthropic's plugin directory as the
# instance user with Claude's own CLI (never with -y), and is found again by
# Claude's record of installed plugins. Runs the plugin's commands with a
# stand-in claude.
# Run: bash tests/vibe_wise_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
exec </dev/null

PASS=0
FAIL=0
assert_eq() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); echo "  ok  $1"
  else FAIL=$((FAIL+1)); echo "  FAIL $1"; echo "    expected: $2"; echo "    actual:   $3"; fi
}

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
H="$SANDBOX/home"
mkdir -p "$H/.local/bin"
# claude: records its arguments; `plugin install` adds the plugin to the
# record Claude keeps, or fails when told to.
cat > "$H/.local/bin/claude" <<'EOF'
#!/bin/bash
echo "$*" >> "$HOME/claude.log"
if [[ "$1 $2" == "plugin install" ]]; then
  [[ -f "$HOME/.fail" ]] && { echo "network error" >&2; exit 1; }
  mkdir -p "$HOME/.claude/plugins"
  printf '{"version":2,"plugins":{"%s":[{"scope":"user"}]}}\n' "$3" > "$HOME/.claude/plugins/installed_plugins.json"
fi
EOF
chmod +x "$H/.local/bin/claude"

log() { :; }
# The plugin's commands, run as the instance user would run them.
incus() {
  [[ "$1 $2 $3 $4 $5 $6 $7" == "exec box -- su - dev -c" ]] || return 1
  env -i HOME="$H" PATH="/usr/bin:/bin" bash -c "$8"
}
CONTAINER_NAME=box HOST_USER=dev
source "$REPO_ROOT/plugins/45-vibe-wise.sh"

echo "the plugin"
assert_eq "it's off unless asked for" "0" "$PLUGIN_DEFAULT"
assert_eq "--vibe-wise asks for it" "--vibe-wise" "$PLUGIN_CLI_FLAGS"
assert_eq "it needs the Claude Code agent" "claude-code" "$PLUGIN_REQUIRES"
assert_eq "it needs no hosts beyond the baseline" "" "${PLUGIN_EGRESS_ALLOW:-}"
# The menu splits each plugin's entry on colons.
assert_eq "its description has no colon" "no" "$([[ "$PLUGIN_DESC" == *:* ]] && echo yes || echo no)"

echo "install"
plugin_is_installed && before=yes || before=no
assert_eq "not installed at first" "no" "$before"
plugin_install
assert_eq "Claude's CLI installs it from the directory, without -y" \
  "plugin install vibe-wise@anthropic-plugin-directory" "$(cat "$H/claude.log")"
plugin_is_installed && after=yes || after=no
assert_eq "then it's found installed" "yes" "$after"

echo "failure"
rm -rf "$H/.claude" "$H/claude.log"
touch "$H/.fail"
( set -e; plugin_install ) 2>/dev/null && rc=0 || rc=$?
assert_eq "a failed install fails the plugin (the build warns and goes on)" "1" "$rc"
plugin_is_installed && after=yes || after=no
assert_eq "and it isn't reported installed" "no" "$after"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
