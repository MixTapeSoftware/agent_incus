#!/bin/bash
# tests/docker_plugin_test.sh
# The Docker plugin relaxes the container's sandbox only as far as Docker
# needs: nesting and two syscall intercepts. It must not run the container
# unconfined or hide AppArmor from dockerd, as older builds did, and it takes
# the mask those builds left in templates back out. Runs the real plugin
# against the fake `incus`.
# Run: bash tests/docker_plugin_test.sh

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

# The plugin, with the globals and helpers incus.init gives it.
log()  { echo "[+] $1"; }
warn() { echo "[!] $1"; }
wait_for_container() { :; }
wait_for_network()   { :; }
# shellcheck source=../plugins/10-docker.sh
source "$REPO_ROOT/plugins/10-docker.sh"
CONTAINER_NAME=box HOST_USER=dev IS_VM=0 READY_TIMEOUT=1

echo "defaults"
assert_eq "docker is opt-in"           "0"        "$PLUGIN_DEFAULT"
assert_eq "…with a flag to opt in"     "--docker" "$PLUGIN_CLI_FLAGS"
assert_contains "the description says what the group means" "root inside" "$PLUGIN_DESC"

fresh_box() {
  export FAKE_INCUS_STATE="$SANDBOX/state-$RANDOM$RANDOM"
  mkdir -p "$FAKE_INCUS_STATE"
  unset FAKE_INCUS_FAIL_EXEC FAKE_INCUS_FAIL_CALL FAKE_INCUS_VERSION
  IS_VM=0
  incus launch images:ubuntu/24.04 box
}
cfg()   { incus config get box "$1"; }
calls() { cat "$FAKE_INCUS_STATE/calls.log"; }
execs() { cat "$FAKE_INCUS_STATE/exec.log" 2>/dev/null || true; }
root()  { echo "$FAKE_INCUS_STATE/instances/box/root"; }
install() { plugin_install > "$SANDBOX/out" 2>&1 && RC=0 || RC=$?; OUT="$(cat "$SANDBOX/out")"; }
MASK_UNIT=/etc/systemd/system/mask-apparmor.service

# ===========================================================================
echo "a fresh container"
# ===========================================================================
fresh_box
install   # no docker binary in the fixture
assert_eq "install: succeeds" "0" "$RC"
assert_eq "install: nesting on"            "true" "$(cfg security.nesting)"
assert_eq "install: mknod intercept on"    "true" "$(cfg security.syscalls.intercept.mknod)"
assert_eq "install: setxattr intercept on" "true" "$(cfg security.syscalls.intercept.setxattr)"
assert_eq "install: the container is not run unconfined" "" "$(cfg raw.lxc)"
assert_not_contains "install: never sets raw.lxc"           "config set box raw.lxc" "$(calls)"
assert_not_contains "install: never masks AppArmor"         "apparmor_disabled"  "$(execs)"
assert_not_contains "install: never bind-mounts over /sys"  "mount --bind"       "$(execs)"
assert_eq "install: no mask unit is written" "gone" "$([[ -e "$(root)$MASK_UNIT" ]] && echo present || echo gone)"
assert_contains "install: restarts so the intercepts take effect" "restart box" "$(calls)"
assert_contains "install: installs the packages" "apt-get install" "$(cat "$FAKE_INCUS_STATE"/exec-stdin/* 2>/dev/null)"
assert_contains "install: the user joins the docker group" "box :: sh -c usermod -aG docker dev" "$(execs)"
assert_not_contains "install: no warning on a current Incus" "[!]" "$OUT"

# Docker already present (a template launch): same config, no package install.
fresh_box
mkdir -p "$(root)/usr/bin"; touch "$(root)/usr/bin/docker"
install
assert_eq "relaunch: succeeds" "0" "$RC"
assert_eq "relaunch: nesting on" "true" "$(cfg security.nesting)"
assert_eq "relaunch: not unconfined" "" "$(cfg raw.lxc)"
assert_contains "relaunch: skips the package install" "already installed" "$OUT"
assert_eq "relaunch: no packages are installed" "" "$(cat "$FAKE_INCUS_STATE"/exec-stdin/* 2>/dev/null)"
assert_contains "relaunch: the user still joins the docker group" "usermod -aG docker dev" "$(execs)"

# ===========================================================================
echo "an Incus that predates the AppArmor fix"
# ===========================================================================
for v in 6.18 6.0.5 5.21; do
  fresh_box
  FAKE_INCUS_VERSION="$v" install
  assert_eq "Incus $v: still configures the container" "true" "$(cfg security.nesting)"
  assert_eq "Incus $v: still not unconfined" "" "$(cfg raw.lxc)"
  assert_contains "Incus $v: warns about the fix" "lxc/incus#2624" "$OUT"
done
for v in 6.19 6.24 7.0; do
  fresh_box
  FAKE_INCUS_VERSION="$v" install
  assert_not_contains "Incus $v: no warning" "lxc/incus#2624" "$OUT"
done

# ===========================================================================
echo "a template built by an older plugin"
# ===========================================================================
fresh_box
mkdir -p "$(root)/etc/systemd/system"
echo "[Unit]" > "$(root)$MASK_UNIT"
install
assert_eq "old mask: succeeds" "0" "$RC"
assert_eq "old mask: the unit is removed" "gone" "$([[ -e "$(root)$MASK_UNIT" ]] && echo present || echo gone)"
assert_contains "old mask: the unit is disabled" "box :: systemctl disable mask-apparmor.service" "$(execs)"
assert_contains "old mask: the bind mount is undone" "box :: umount /sys/module/apparmor/parameters/enabled" "$(execs)"
assert_contains "old mask: says what it did" "AppArmor mask" "$OUT"
# The mask must be gone before the restart, so dockerd boots with AppArmor.
removed_at="$(calls | grep -n "^file delete box$MASK_UNIT" | cut -d: -f1 | head -n 1)"
restart_at="$(calls | grep -n "^restart box" | cut -d: -f1 | head -n 1)"
assert_eq "old mask: removed before the restart" "yes" "$([[ -n "$removed_at" && -n "$restart_at" && "$removed_at" -lt "$restart_at" ]] && echo yes || echo no)"

# The check itself fails: do not restart with a mask that may be there.
fresh_box
FAKE_INCUS_FAIL_EXEC='mask-apparmor' install
assert_eq "mask check fails: the plugin fails" "1" "$RC"
assert_contains "mask check fails: says why" "AppArmor mask" "$OUT"
assert_not_contains "mask check fails: no restart" "restart box" "$(calls)"
assert_not_contains "mask check fails: no package install" "apt-get" "$(cat "$FAKE_INCUS_STATE"/exec-stdin/* 2>/dev/null)"

# ===========================================================================
echo "a VM"
# ===========================================================================
fresh_box
IS_VM=1 install
assert_eq "vm: succeeds" "0" "$RC"
assert_eq "vm: no container sandbox keys" "" "$(cfg security.nesting)$(cfg security.syscalls.intercept.mknod)$(cfg raw.lxc)"
assert_not_contains "vm: no restart" "restart box" "$(calls)"
assert_contains "vm: the user joins the docker group" "usermod -aG docker dev" "$(execs)"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
