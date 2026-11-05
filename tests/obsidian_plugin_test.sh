#!/bin/bash
# tests/obsidian_plugin_test.sh
# The Obsidian Headless plugin: opt-in, installed as the instance user with a
# Node 22 from mise (the system's is 18, which ob can't run on), started
# through a launcher that pins that Node, never logged in at build, and given
# Obsidian's hosts under an allowlist. Runs the plugin's commands with
# stand-ins for mise, npm and node.
# Run: bash tests/obsidian_plugin_test.sh

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
BIN="$SANDBOX/bin"       # the system's: mise, and a Node 18
NODE22="$SANDBOX/node22" # what mise exec node@22 puts first on PATH
mkdir -p "$H" "$BIN" "$NODE22"
# mise: `exec [--yes] node@22 -- <command>` runs the command with Node 22
# first on PATH, and says how it was asked.
cat > "$BIN/mise" <<EOF
#!/bin/bash
echo "mise \$*" >> "\$HOME/calls.log"
[[ "\$1" == exec ]] || exit 1
shift
[[ "\$1" == --yes ]] && shift
[[ "\$1" == node@22 && "\$2" == -- ]] || exit 1
shift 2
PATH="$NODE22:\$PATH" exec "\$@"
EOF
# The system's Node 18: ob can't run on it.
cat > "$BIN/node" <<'EOF'
#!/bin/bash
echo "node18 $*" >> "$HOME/calls.log"
echo "ReferenceError: crypto is not defined" >&2
exit 1
EOF
cat > "$NODE22/node" <<'EOF'
#!/bin/bash
echo "node22 $*" >> "$HOME/calls.log"
[[ -f "$1" ]] || { echo "Cannot find module '$1'" >&2; exit 1; }
[[ -f "$HOME/.broken" ]] && exit 1
exit 0
EOF
# npm: `install --global --prefix <dir> <package>` puts the package's cli.js
# where npm does, or fails when told to.
cat > "$NODE22/npm" <<'EOF'
#!/bin/bash
echo "npm $*" >> "$HOME/calls.log"
[[ -f "$HOME/.fail" ]] && { echo "network error" >&2; exit 1; }
[[ "$1 $2 $3" == "install --global --prefix" ]] || exit 1
mkdir -p "$4/lib/node_modules/$5"
echo "// $5" > "$4/lib/node_modules/$5/cli.js"
EOF
chmod +x "$BIN/mise" "$BIN/node" "$NODE22/node" "$NODE22/npm"

log() { :; }
# The plugin's commands, run as the instance user would run them.
incus() {
  [[ "$1 $2 $3 $4 $5 $6 $7" == "exec box -- su - dev -c" ]] || return 1
  env -i HOME="$H" PATH="$BIN:/usr/bin:/bin" bash -c "$8"
}
as_user() { env -i HOME="$H" PATH="$BIN:/usr/bin:/bin" "$@"; }
calls() { cat "$H/calls.log" 2>/dev/null || true; }
CONTAINER_NAME=box HOST_USER=dev
source "$REPO_ROOT/plugins/50-obsidian.sh"
CLI="$H/.local/share/obsidian-headless/lib/node_modules/obsidian-headless/cli.js"

echo "the plugin"
assert_eq "it's off unless asked for" "0" "$PLUGIN_DEFAULT"
assert_eq "--obsidian asks for it" "--obsidian" "$PLUGIN_CLI_FLAGS"
assert_eq "it asks for Obsidian's hosts under an allowlist" "*.obsidian.md" "$PLUGIN_EGRESS_ALLOW"
assert_eq "it takes no credentials at build" "0" "${PLUGIN_NEEDS_PROMPT:-0}"
# The menu splits each plugin's entry on colons.
assert_eq "its description has no colon" "no" "$([[ "$PLUGIN_DESC" == *:* ]] && echo yes || echo no)"

echo "install"
plugin_is_installed && before=yes || before=no
assert_eq "not installed at first" "no" "$before"
plugin_install > "$SANDBOX/out" 2>&1 && rc=0 || rc=$?
assert_eq "it installs" "0" "$rc"
assert_eq "with npm under mise's Node 22, into a prefix of its own" \
  "npm install --global --prefix $H/.local/share/obsidian-headless obsidian-headless" "$(calls | grep '^npm ')"
assert_eq "asking mise to install that Node if it's missing" \
  "mise exec --yes node@22 -- npm install --global --prefix $H/.local/share/obsidian-headless obsidian-headless" \
  "$(calls | grep '^mise .* npm ')"
assert_eq "ob is on the user's PATH" "yes" "$([[ -x "$H/.local/bin/ob" ]] && echo yes || echo no)"
assert_eq "it was run once to check it starts" "node22 $CLI --version" "$(calls | grep '^node22 ')"
assert_eq "and never logged in" "" "$(calls | grep -i 'login' || true)"
plugin_is_installed && after=yes || after=no
assert_eq "installed afterwards" "yes" "$after"

echo "the launcher"
: > "$H/calls.log"
(cd "$SANDBOX" && as_user "$H/.local/bin/ob" sync --path "my vault" --continuous) && rc=0 || rc=$?
assert_eq "ob runs" "0" "$rc"
assert_eq "on Node 22, with its arguments as given" "node22 $CLI sync --path my vault --continuous" "$(calls | grep '^node22 ')"
assert_eq "not on the system's Node 18" "" "$(calls | grep '^node18 ' || true)"

echo "a failed install"
rm -rf "$H/.local" "$H/calls.log"
touch "$H/.fail"
plugin_install > "$SANDBOX/out" 2>&1 && rc=0 || rc=$?
assert_eq "npm failing fails the install" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
assert_eq "no launcher is left behind" "no" "$([[ -e "$H/.local/bin/ob" ]] && echo yes || echo no)"
plugin_is_installed && after=yes || after=no
assert_eq "and it isn't taken for installed" "no" "$after"
rm -f "$H/.fail"
touch "$H/.broken"
plugin_install > "$SANDBOX/out" 2>&1 && rc=0 || rc=$?
assert_eq "an ob that doesn't start fails the install" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
plugin_is_installed && after=yes || after=no
assert_eq "and isn't taken for installed either" "no" "$after"
rm -f "$H/.broken"
plugin_install > "$SANDBOX/out" 2>&1 && rc=0 || rc=$?
assert_eq "a later run installs it" "0" "$rc"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
