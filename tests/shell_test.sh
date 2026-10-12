#!/bin/bash
# tests/shell_test.sh
# Behavior tests for incus.shell argument parsing and --with-sudo, against the
# stateful fake `incus`.
# Run: bash tests/shell_test.sh

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

USER_GID=4100; DOCKER_GID=4101; SUDO_GID=4242
HOST_UID_NOW="$(id -u)"
HOST_GID_NOW="$(id -g)"

fresh_box() {
  export FAKE_INCUS_STATE="$SANDBOX/state-$RANDOM$RANDOM"
  mkdir -p "$FAKE_INCUS_STATE"
  incus launch images:ubuntu/24.04 box
  mkdir -p "$FAKE_INCUS_STATE/instances/box/root/etc"
}
# The container user: primary group first, then docker.
with_user_groups() { echo "$USER_GID $DOCKER_GID" > "$FAKE_INCUS_STATE/instances/box/root/etc/id-G"; }
with_sudo_group()  { echo "_sudo:x:$SUDO_GID:" > "$FAKE_INCUS_STATE/instances/box/root/etc/group"; }
shell() { bash "$REPO_ROOT/incus.shell" "$@"; }
last_call() { tail -1 "$FAKE_INCUS_STATE/calls.log"; }
# The command incus runs inside the container (everything after the first --).
launched() { local c; c="$(last_call)"; echo "${c#* -- }"; }

echo "incus.shell"

fresh_box; with_user_groups; with_sudo_group
shell box >/dev/null 2>&1
assert_eq "plain shell: user's own groups, primary first, no _sudo" \
  "setpriv --reuid=$HOST_UID_NOW --regid=$USER_GID --groups=$USER_GID,$DOCKER_GID --inh-caps=-all -- zsh -li" \
  "$(launched)"
# incus exec --group holds one GID; repeating it silently drops the others.
assert_not_contains "plain shell: no incus --group flag" " --group " "$(last_call)"
assert_not_contains "plain shell: no incus --user flag"  " --user "  "$(last_call)"

fresh_box; with_user_groups; with_sudo_group
shell --with-sudo box >/dev/null 2>&1
assert_eq "--with-sudo: adds _sudo, keeps the primary group and docker" \
  "setpriv --reuid=$HOST_UID_NOW --regid=$USER_GID --groups=$USER_GID,$DOCKER_GID,$SUDO_GID --inh-caps=-all -- zsh -li" \
  "$(launched)"

fresh_box; with_user_groups; with_sudo_group
shell box echo --with-sudo >/dev/null 2>&1
assert_eq "--with-sudo after the name is passed to the command, not treated as a flag" \
  "setpriv --reuid=$HOST_UID_NOW --regid=$USER_GID --groups=$USER_GID,$DOCKER_GID --inh-caps=-all -- zsh -lic echo --with-sudo" \
  "$(launched)"

fresh_box; with_user_groups
out="$(shell --with-sudo box 2>&1)" && rc=0 || rc=$?
assert_eq       "missing _sudo group: exit code" "1" "$rc"
assert_contains "missing _sudo group: explains why" "_sudo group not found" "$out"

fresh_box
shell box >/dev/null 2>&1
assert_eq "group lookup unavailable: falls back to the host GID" \
  "setpriv --reuid=$HOST_UID_NOW --regid=$HOST_GID_NOW --groups=$HOST_GID_NOW --inh-caps=-all -- zsh -li" \
  "$(launched)"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
