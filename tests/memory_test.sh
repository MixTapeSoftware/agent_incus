#!/bin/bash
# tests/memory_test.sh
# An instance's memory: --memory for a container or a VM, a selected plugin's
# PLUGIN_MIN_MEMORY raising it, and the refusal when the host can't back the
# figure. Container builds run end to end against the fake incus with
# --egress off; VM cases use --dry-run, which stops before incus init.
# Run: bash tests/memory_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
exec </dev/null
command -v jq >/dev/null || { echo "needs jq (the host's memory comes from the resources API)"; exit 1; }

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
mkdir -p "$SANDBOX/bin" "$SANDBOX/repo/plugins" "$SANDBOX/ws"
cp "$SCRIPT_DIR/lib/fake_incus" "$SANDBOX/bin/incus"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/curl"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/git"
chmod +x "$SANDBOX/bin/"*
cp "$REPO_ROOT"/boxen.* "$SANDBOX/repo/"
cp -R "$REPO_ROOT/egress" "$SANDBOX/repo/egress"
# A plugin that wants memory, and one whose figure isn't a size.
cat > "$SANDBOX/repo/plugins/10-big.sh" <<'EOF'
PLUGIN_ID="big"; PLUGIN_NAME="Big stack"; PLUGIN_DESC="a dozen containers"; PLUGIN_DEFAULT=0
PLUGIN_CLI_FLAGS="--big"
PLUGIN_MIN_MEMORY="8GiB"
plugin_install() { :; }
EOF
cat > "$SANDBOX/repo/plugins/20-odd.sh" <<'EOF'
PLUGIN_ID="odd"; PLUGIN_NAME="Odd one"; PLUGIN_DESC="misdeclared"; PLUGIN_DEFAULT=0
PLUGIN_CLI_FLAGS="--odd"
PLUGIN_MIN_MEMORY="lots"
plugin_install() { :; }
EOF
echo hello > "$SANDBOX/ws/README"

export PATH="$SANDBOX/bin:$PATH"
export HOME="$SANDBOX/home"
export BOXEN_NET_SUBNET=10.201.0.1/16
export BOXEN_UFW_CONF="$SANDBOX/no-ufw.conf"
export FAKE_INCUS_VERSION=7.5.1

fresh() {
  export FAKE_INCUS_STATE="$SANDBOX/state-$RANDOM$RANDOM"
  export BOXEN_LOCK_DIR="$FAKE_INCUS_STATE/lock"
  export BOXEN_CONFIG_DIR="$FAKE_INCUS_STATE/config"
  mkdir -p "$FAKE_INCUS_STATE/images/incus-init/base/root"
}
init() { local n="$1"; shift; bash "$SANDBOX/repo/boxen.init" --name "$n" "$@" --egress off --no-tui -p "$SANDBOX/ws" >"$SANDBOX/out" 2>&1 && RC=0 || RC=$?; }
out() { sed -e $'s/\033\\[[0-9;]*m//g' "$SANDBOX/out"; }
cfg() { cat "$FAKE_INCUS_STATE/instances/$1/config/$2" 2>/dev/null; }
exists() { [[ -d "$FAKE_INCUS_STATE/instances/$1" ]] && echo yes || echo no; }
GIB=1073741824

echo "a container"
fresh
init box
assert_eq "it builds" "0" "$RC"
[[ "$RC" == 0 ]] || tail -20 "$SANDBOX/out"
assert_eq "with the profile's limit, not one of its own" "" "$(cfg box limits.memory)"
assert_contains "the summary says so" "Memory:      6GB (default)" "$(out)"
fresh
init mbox --memory 8GiB
assert_eq "--memory builds" "0" "$RC"
assert_eq "--memory gives it its own limit" "8GiB" "$(cfg mbox limits.memory)"
assert_contains "and the summary names the flag" "Memory:      8GiB (--memory)" "$(out)"
fresh
init bad --memory lots
assert_eq "a figure that isn't a size is refused" "1" "$RC"
assert_contains "and told what one looks like" "--memory must be a size such as 8GiB or 6GB (got: lots)" "$(out)"
assert_eq "nothing is created" "no" "$(exists bad)"

echo "a plugin's floor"
fresh
init pbox --big
assert_eq "it builds" "0" "$RC"
assert_eq "the selected plugin raises the limit" "8GiB" "$(cfg pbox limits.memory)"
assert_contains "and the build says why" "Memory: 8GiB (Big stack needs at least 8GiB)" "$(out)"
fresh
init pbox2 --big --memory 12GiB
assert_eq "a larger --memory wins" "12GiB" "$(cfg pbox2 limits.memory)"
fresh
init pbox3 --big --memory 4GiB
assert_eq "a smaller --memory doesn't undercut the floor" "8GiB" "$(cfg pbox3 limits.memory)"
fresh
init obox --odd
assert_eq "a misdeclared floor doesn't stop the build" "0" "$RC"
assert_eq "and is ignored" "" "$(cfg obox limits.memory)"
assert_contains "with a warning naming the plugin" "Odd one: PLUGIN_MIN_MEMORY 'lots' isn't a size; ignored" "$(out)"

echo "a VM"
fresh
init vbox --vm --dry-run
assert_eq "the dry run works" "0" "$RC"
assert_contains "a VM defaults to 4GiB" "Type:        VM (disk=20GiB memory=4GiB cpus=4)" "$(out)"
assert_contains "and the summary agrees" "Memory:      4GiB (default)" "$(out)"
fresh
init vbox2 --vm --vm-memory 8GiB --dry-run
assert_contains "--vm-memory still works" "memory=8GiB" "$(out)"
fresh
init vbox3 --vm --big --dry-run
assert_contains "a plugin's floor applies to a VM too" "memory=8GiB" "$(out)"
fresh
init cbox --vm-memory 8GiB --dry-run
assert_contains "--vm-memory on a container is --memory, not ignored" "Memory:      8GiB (--memory)" "$(out)"
assert_eq "so there's no warning about VM options" "0" "$(out | grep -c 'are ignored without --vm' || true)"

echo "what the host can back"
fresh
FAKE_INCUS_MEMORY=$((8 * GIB)) init rbox --memory 8GiB
assert_eq "all of an 8GiB host is refused" "1" "$RC"
assert_contains "naming both figures" "This host has 8.0GiB of memory; rbox would get 8GiB (--memory), leaving it less than 2GiB. Choose less with --memory." "$(out)"
assert_eq "nothing is created" "no" "$(exists rbox)"
fresh
FAKE_INCUS_MEMORY=$((8 * GIB)) init rbox2 --big
assert_eq "a plugin's floor the host can't back is refused" "1" "$RC"
assert_contains "and the plugin is named" "rbox2 would get 8GiB (Big stack needs at least 8GiB)" "$(out)"
fresh
FAKE_INCUS_MEMORY=$((8 * GIB)) init okbox
assert_eq "the profile's 6GB fits an 8GiB host" "0" "$RC"
fresh
FAKE_INCUS_MEMORY=$((4 * GIB)) init sbox
assert_eq "a small host still builds when nothing asked for memory" "0" "$RC"
assert_contains "with a warning" "This host has 4.0GiB of memory, less than the profile's 6GB limit plus 2GiB" "$(out)"
assert_eq "and the container keeps the profile's limit" "" "$(cfg sbox limits.memory)"
fresh
FAKE_INCUS_MEMORY=$((16 * GIB)) init vbig --vm --memory 15GiB --dry-run
assert_eq "a VM is held to the same rule" "1" "$RC"
assert_contains "naming the figures" "This host has 16.0GiB of memory; vbig would get 15GiB" "$(out)"
assert_eq "before anything is shown" "0" "$(out | grep -c '^Type:' || true)"

echo "where the host's memory comes from"
# Without jq, the figure comes from incus info --resources, rounded.
mkdir -p "$SANDBOX/nojq"; printf '#!/bin/sh\nexit 127\n' > "$SANDBOX/nojq/jq"; chmod +x "$SANDBOX/nojq/jq"
fresh
PATH="$SANDBOX/nojq:$PATH" FAKE_INCUS_MEMORY=$((8 * GIB + GIB / 2)) init tbox --memory 8GiB
assert_eq "without jq the host is still measured" "1" "$RC"
assert_contains "from incus info --resources, decimals and all" "This host has 8.5GiB of memory; tbox would get 8GiB" "$(out)"
fresh
PATH="$SANDBOX/nojq:$PATH" FAKE_INCUS_MEMORY=$((64 * GIB)) init tbox2 --memory 8GiB
assert_eq "and a host that can back it builds" "0" "$RC"
# An Incus that won't say falls back to /proc/meminfo: this machine's. The
# profile's default builds whatever its size. Either way nothing is skipped.
fresh
FAKE_INCUS_NO_RESOURCES=1 init fbox
assert_eq "an Incus without resources still builds" "0" "$RC"
if [[ -r /proc/meminfo ]]; then
  assert_eq "with /proc/meminfo measured, so no warning" "0" "$(out | grep -c "wasn't checked" || true)"
else
  assert_contains "with a warning that nothing could measure it" "so whether it can back 6GB wasn't checked" "$(out)"
fi
# On macOS the message points at Colima. Only the bare uname the message
# checks answers Darwin; boxen.macos.setup's `uname -s` must keep seeing
# this machine, or the build would want Colima.
mkdir -p "$SANDBOX/mac"
printf '#!/bin/sh\n[ $# -eq 0 ] && { echo Darwin; exit 0; }\nexec %s "$@"\n' "$(command -v uname)" > "$SANDBOX/mac/uname"
chmod +x "$SANDBOX/mac/uname"
fresh
PATH="$SANDBOX/mac:$PATH" FAKE_INCUS_MEMORY=$((8 * GIB)) init mbox2 --memory 8GiB
assert_eq "a Mac refuses the same way" "1" "$RC"
assert_contains "and says how to resize Colima's VM" "leaving it less than 2GiB. Here that's Colima's VM, which --colima-memory sizes only when it's first made; to resize it: colima stop -p boxen && colima start -p boxen --memory N. Choose less with --memory." "$(out)"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
