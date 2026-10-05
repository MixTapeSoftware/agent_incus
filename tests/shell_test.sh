#!/bin/bash
# tests/shell_test.sh
# Behavior tests for incus.shell argument parsing and --with-sudo, against the
# stateful fake `incus`.
# Run: bash tests/shell_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
exec </dev/null

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
  else FAIL=$((FAIL+1)); echo "  FAIL $1"; echo "    expected NOT to contain: $2"; fi
}

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin"
cp "$SCRIPT_DIR/lib/fake_incus" "$SANDBOX/bin/incus"
chmod +x "$SANDBOX/bin/incus"
export PATH="$SANDBOX/bin:$PATH"
unset CLAUDE_CONTAINER

fresh_box() {
  export FAKE_INCUS_STATE="$SANDBOX/state-$RANDOM$RANDOM"
  mkdir -p "$FAKE_INCUS_STATE"
  incus launch images:ubuntu/24.04 box
}
with_sudo_group() {
  mkdir -p "$FAKE_INCUS_STATE/instances/box/root/etc"
  echo "_sudo:x:999:" > "$FAKE_INCUS_STATE/instances/box/root/etc/group"
}
shell() { bash "$REPO_ROOT/incus.shell" "$@"; }
last_call() { tail -1 "$FAKE_INCUS_STATE/calls.log"; }

echo "incus.shell"

fresh_box
shell box >/dev/null 2>&1
assert_not_contains "plain shell: no _sudo group" "--group 999" "$(last_call)"
assert_contains     "plain shell: interactive login shell" "-- zsh -li" "$(last_call)"

fresh_box; with_sudo_group
shell --with-sudo box >/dev/null 2>&1
assert_contains "--with-sudo before the name adds the _sudo group" "--group 999" "$(last_call)"

fresh_box; with_sudo_group
shell box echo --with-sudo >/dev/null 2>&1
assert_not_contains "--with-sudo after the name is not a flag" "--group 999" "$(last_call)"
assert_contains     "…it is passed to the command instead" "zsh -lic echo --with-sudo" "$(last_call)"

fresh_box
out="$(shell --with-sudo box 2>&1)" && rc=0 || rc=$?
assert_eq       "missing _sudo group: exit code" "1" "$rc"
assert_contains "missing _sudo group: explains why" "_sudo group not found" "$out"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
