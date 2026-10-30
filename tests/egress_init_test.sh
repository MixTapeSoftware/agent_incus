#!/bin/bash
# tests/egress_init_test.sh
# incs -i under an allowlist (the default): a fresh build installs plugins
# that take no credentials while open, locks, then copies the workspace and
# installs the rest; a template launch is locked before its first start; and
# --egress off, report and the refusals. Runs incus.init end to end against
# the fake `incus`, with curl and git stubbed so nothing is downloaded.
# Run: bash tests/egress_init_test.sh

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
assert_before() {
  local a b
  a="$(grep -nE -m1 -- "$2" "$FAKE_INCUS_STATE/calls.log" | cut -d: -f1)"
  b="$(grep -nE -m1 -- "$3" "$FAKE_INCUS_STATE/calls.log" | cut -d: -f1)"
  if [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]]; then PASS=$((PASS+1)); echo "  ok  $1"
  else FAIL=$((FAIL+1)); echo "  FAIL $1"; echo "    expected '$2' (line ${a:-none}) before '$3' (line ${b:-none})"; fi
}

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin" "$SANDBOX/repo/plugins" "$SANDBOX/ws"
cp "$SCRIPT_DIR/lib/fake_incus" "$SANDBOX/bin/incus"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/curl"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/git"
chmod +x "$SANDBOX/bin/"*
cp "$REPO_ROOT"/incus.* "$SANDBOX/repo/"
cp -R "$REPO_ROOT/egress" "$SANDBOX/repo/egress"
# Two plugins that record the build phase they ran in.
cat > "$SANDBOX/repo/plugins/10-open.sh" <<EOF
PLUGIN_ID="open-one"; PLUGIN_NAME="Open one"; PLUGIN_DESC="no credentials"; PLUGIN_DEFAULT=1
plugin_install() { echo "open-one:\$(incus config get "\$CONTAINER_NAME" user.incs.egress.build)" >> "$SANDBOX/order"; }
EOF
cat > "$SANDBOX/repo/plugins/20-locked.sh" <<EOF
PLUGIN_ID="locked-one"; PLUGIN_NAME="Locked one"; PLUGIN_DESC="takes a token"; PLUGIN_DEFAULT=1
PLUGIN_NEEDS_PROMPT=1
PLUGIN_EGRESS_ALLOW="Locked.Example *.api.locked.example"
plugin_prompt() { :; }
plugin_install() { echo "locked-one:\$(incus config get "\$CONTAINER_NAME" user.incs.egress.build)" >> "$SANDBOX/order"; }
EOF
echo hello > "$SANDBOX/ws/README"

export PATH="$SANDBOX/bin:$PATH"
export HOME="$SANDBOX/home"
export INCS_NET_SUBNET=10.201.0.1/16
export INCS_UFW_CONF="$SANDBOX/no-ufw.conf"
export FAKE_EGRESS_CTL="$SCRIPT_DIR/lib/fake_egress_ctl"
export FAKE_INCUS_VERSION=7.5.1

fresh() {
  export FAKE_INCUS_STATE="$SANDBOX/state-$RANDOM$RANDOM"
  export INCS_LOCK_DIR="$FAKE_INCUS_STATE/lock"
  export INCS_CONFIG_DIR="$FAKE_INCUS_STATE/config"
  mkdir -p "$FAKE_INCUS_STATE/images/incus-init/base/root"
  rm -f "$SANDBOX/order"
}
init() { bash "$SANDBOX/repo/incus.init" "$@" --no-tui -p "$SANDBOX/ws" >"$SANDBOX/out" 2>&1 && RC=0 || RC=$?; }
cfg() { cat "$FAKE_INCUS_STATE/instances/$1/config/$2" 2>/dev/null; }
stdin_all() { cat "$FAKE_INCUS_STATE"/exec-stdin/* 2>/dev/null | tr -d '\0'; }

echo "a fresh build"
fresh
init box
assert_eq "it builds" "0" "$RC"
[[ "$RC" == 0 ]] || tail -20 "$SANDBOX/out"
assert_eq "it's created stopped" "init images:ubuntu/24.04 box" "$(grep -m1 '^init .* box' "$FAKE_INCUS_STATE/calls.log" | cut -d' ' -f1-3)"
assert_before "autostart is off before it first starts" '^config set box boot.autostart=false' '^start box'
assert_eq "the plugin without credentials ran open" "open-one:open" "$(grep open-one "$SANDBOX/order")"
assert_eq "the plugin with one ran locked" "locked-one:locked" "$(grep locked-one "$SANDBOX/order")"
assert_before "the lock comes before the workspace copy" '^config set box user.incs.egress.build=locked' '^exec box -- tar --no-same-owner -C /workspace'
assert_before "the lockdown stops it before the workspace copy" '^stop box' '^exec box -- tar --no-same-owner -C /workspace'
assert_eq "plugin hosts are recorded, checked" "*.api.locked.example,locked.example" "$(cfg box user.incs.egress.plugin-allow)"
assert_eq "it enforces" "enforce" "$(cfg box user.incs.egress)"
assert_eq "its card is locked" "reject" "$(cfg box devices.eth0.security.acls.default.egress.action)"
assert_eq "it moved to a fresh address on lock" "10.201.0.12" "$(cfg box devices.eth0.ipv4.address)"
assert_eq "the build is done" "done" "$(cfg box user.incs.egress.build)"
assert_eq "the barrier is cleared" "none" "$(cfg box user.incs.egress.transition)"
assert_eq "autostart is back to unset" "" "$(cfg box boot.autostart)"
assert_contains "the proxy is in its environment" "http://10.201.0.11:10000" "$(cfg box environment.HTTPS_PROXY)"
assert_contains "github remotes use HTTPS" 'insteadOf "git@github.com:"' "$(stdin_all)"
assert_contains "the agents get a note" "## Network allowlist" "$(stdin_all)"
assert_contains "the note names the allow command" "incs egress allow box <host>" "$(stdin_all)"
assert_contains "the login banner" "This container is on an allowlist (enforce)" "$(stdin_all)"
assert_contains "networking is checked through the proxy after the lock" "curl -fsS -o /dev/null --max-time 5 https://github.com" "$(cat "$FAKE_INCUS_STATE/exec.log")"

echo "a template launch"
fresh
init tbox --from base
assert_eq "it builds" "0" "$RC"
[[ "$RC" == 0 ]] || tail -20 "$SANDBOX/out"
assert_before "its card is locked before its first start" '^config device set tbox eth0 security.acls=incs-a-tbox' '^start tbox'
assert_before "its proxy is verified before its first start" '^exec incs-egress -- /usr/local/sbin/incs-egress-ctl (tighten|widen) tbox' '^start tbox'
assert_eq "it's never stopped for a lockdown" "" "$(grep '^stop tbox' "$FAKE_INCUS_STATE/calls.log" || true)"
assert_eq "both plugins ran locked, in name order" "locked-one:locked open-one:locked" "$(tr '\n' ' ' < "$SANDBOX/order" | sed 's/ $//')"
assert_eq "the build is done" "done" "$(cfg tbox user.incs.egress.build)"
assert_eq "autostart is back to unset" "" "$(cfg tbox boot.autostart)"
assert_eq "the barrier keys are cleared" "none" "$(cfg tbox user.incs.egress.autostart-saved)"

echo "modes and refusals"
fresh
init obox --egress off --from base
assert_eq "--egress off builds" "0" "$RC"
assert_eq "--egress off launches as before" "launch" "$(grep -m1 -E '^(launch|init) .* obox' "$FAKE_INCUS_STATE/calls.log" | cut -d' ' -f1)"
assert_eq "--egress off makes no egress container" "no" "$([[ -d "$FAKE_INCUS_STATE/instances/incs-egress" ]] && echo yes || echo no)"
assert_eq "--egress off has no build state" "" "$(cfg obox user.incs.egress.build)"
assert_contains "an off launch from a template clears its old proxy settings" "rm -f /etc/apt/apt.conf.d/95incs-proxy" "$(cat "$FAKE_INCUS_STATE/exec.log")"
fresh
mkdir -p "$SANDBOX/globdir"; touch "$SANDBOX/globdir/x.api.locked.example"
(cd "$SANDBOX/globdir" && init gl --from base)
assert_eq "a plugin wildcard isn't expanded against files in the current directory" "*.api.locked.example,locked.example" "$(cfg gl user.incs.egress.plugin-allow)"
fresh
init rbox --egress report --from base
assert_eq "--egress report builds" "0" "$RC"
assert_eq "it reports" "report" "$(cfg rbox user.incs.egress)"
fresh
init gbox --egress-container eogva --from base
assert_eq "--egress-container builds" "0" "$RC"
assert_eq "its proxy is in the named egress container" "incs-egress-eogva" "$(cfg gbox user.incs.egress.container)"
fresh
init x --insecure-network --egress enforce --from base
assert_eq "an allowlist on the default bridge is refused" "1" "$RC"
assert_contains "and says why" "needs the isolated network" "$(cat "$SANDBOX/out")"
init x --insecure-network --from base
assert_eq "--insecure-network alone builds with no allowlist" "0" "$RC"
init y --egress sideways --from base
assert_contains "an unknown mode is refused" "--egress must be enforce, report or off" "$(cat "$SANDBOX/out")"

echo "dry run and Node"
fresh
init dry --dry-run
assert_contains "--dry-run names the allowlist" "Egress:      enforce (allowlist), proxy in incs-egress" "$(cat "$SANDBOX/out")"
echo "20.11.1" > "$SANDBOX/ws/.nvmrc"
init dry --dry-run
assert_contains "an old pinned Node is called out" "pins Node 20.11.1" "$(cat "$SANDBOX/out")"
echo "24.1.0" > "$SANDBOX/ws/.nvmrc"
init dry --dry-run
assert_eq "a supported Node isn't" "" "$(grep 'pins Node' "$SANDBOX/out" || true)"
rm "$SANDBOX/ws/.nvmrc"

echo "the Tailscale plugin"
ts_up() {
  bash -c 'set -euo pipefail
    log(){ :; }; warn(){ :; }; error(){ exit 1; }
    CALLS="$1.calls"
    incus() { echo "incus $*" >> "$CALLS"; case "$*" in *"command -v tailscale"*|*"test -c"*) return 0 ;; esac; }
    source "$2"; CONTAINER_NAME=box HOST_USER=dev TS_AUTH_KEY=tskey-test EGRESS_MODE="$3"
    plugin_install >/dev/null' _ "$SANDBOX/ts" "$REPO_ROOT/plugins/50-tailscale.sh" "$1"
  grep -A3 'tailscale up' "$SANDBOX/ts.calls"; rm -f "$SANDBOX/ts.calls"
}
out="$(ts_up enforce)"
assert_contains "the plugin brings Tailscale up" "tailscale up" "$out"
assert_eq "under an allowlist, the agent isn't Tailscale's operator" "no" "$(grep -q -- '--operator' <<< "$out" && echo yes || echo no)"
assert_eq "with no allowlist it still is" "yes" "$(ts_up off | grep -q -- '--operator=dev' && echo yes || echo no)"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
