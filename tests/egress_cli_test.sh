#!/bin/bash
# tests/egress_cli_test.sh
# `incs egress` (incs.egress): turning a container's allowlist on, allowing
# and removing hosts, switching modes, the lockdown that restarts an open
# container on a new address behind a boot barrier, finishing an interrupted
# one, the baseline review, ls and log, and cleanup on delete. Runs against
# the fake `incus` and a stand-in for the ctl inside the egress container.
# Run: bash tests/egress_cli_test.sh

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
  else FAIL=$((FAIL+1)); echo "  FAIL $1"; echo "    expected not to contain: $2"; echo "    actual: $3"; fi
}

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin" "$SANDBOX/repo"
cp "$SCRIPT_DIR/lib/fake_incus" "$SANDBOX/bin/incus"
chmod +x "$SANDBOX/bin/incus"
# A copy of the scripts, so a test can change the shipped baseline.
cp "$REPO_ROOT"/incs "$REPO_ROOT"/incs.* "$REPO_ROOT"/incus.* "$SANDBOX/repo/"
cp -R "$REPO_ROOT/egress" "$SANDBOX/repo/egress"
export PATH="$SANDBOX/bin:$PATH"
export HOME="$SANDBOX/home"
export INCS_NET_SUBNET=10.201.0.1/16
export INCS_UFW_CONF="$SANDBOX/no-ufw.conf"
export FAKE_EGRESS_CTL="$SCRIPT_DIR/lib/fake_egress_ctl"
export FAKE_INCUS_STATE="$SANDBOX/state"
export INCS_LOCK_DIR="$FAKE_INCUS_STATE/lock"
export INCS_CONFIG_DIR="$FAKE_INCUS_STATE/config"
export FAKE_INCUS_VERSION=7.5.1
mkdir -p "$FAKE_INCUS_STATE"

eg() { bash "$SANDBOX/repo/incs" egress "$@"; }
run() { OUT="$(eg "$@" 2>&1)" && RC=0 || RC=$?; }
cfg() { cat "$FAKE_INCUS_STATE/instances/$1/config/$2" 2>/dev/null; }
status() { cat "$FAKE_INCUS_STATE/instances/$1/status"; }
E=incs-egress
gen_of() { cat "$FAKE_INCUS_STATE/ctl/$E/$1/current"; }
gen_file() { cat "$FAKE_INCUS_STATE/ctl/$E/$1/gens/$(gen_of "$1")/$2"; }
calls_since() { tail -n +"$(( $1 + 1 ))" "$FAKE_INCUS_STATE/calls.log"; }
ncalls() { wc -l < "$FAKE_INCUS_STATE/calls.log" | tr -d ' '; }

# An instance as incs -i makes it on the isolated bridge, autostart unset.
make_box() {
  incus launch img "$1" -p default -p incs-net -d "eth0,ipv4.address=$2" >/dev/null
  incus config set "$1" user.managed-by=agent-incus user.incs.net=isolated
}
bash -c 'log(){ :; }; warn(){ :; }; error(){ exit 1; }; source "$1/incus.net"; ensure_net' _ "$SANDBOX/repo"
make_box box 10.201.0.50

echo "turning the allowlist on"
before="$(ncalls)"
run mode box enforce
assert_eq "it succeeds" "0" "$RC"
assert_contains "it says the container restarted on a new address" "locked; it restarted on a new address" "$OUT"
assert_eq "the egress container exists" "yes" "$([[ -d "$FAKE_INCUS_STATE/instances/$E" ]] && echo yes || echo no)"
assert_eq "box's proxy is on port 10000" "10000" "$(cfg box user.incs.egress.port)"
assert_eq "the proxy address is in box's environment" "http://10.201.0.10:10000" "$(cfg box environment.HTTPS_PROXY)"
assert_eq "NO_PROXY keeps local traffic off the proxy" "localhost,127.0.0.1,::1" "$(cfg box environment.NO_PROXY)"
assert_eq "Node's fetch uses the proxy" "1" "$(cfg box environment.NODE_USE_ENV_PROXY)"
stdin="$(cat "$FAKE_INCUS_STATE"/exec-stdin/* 2>/dev/null)"
assert_contains "proxy settings for logins, apt and services are written" "/etc/apt/apt.conf.d/95incs-proxy" "$stdin"
assert_eq "box's card uses its own rules" "incs-a-box" "$(cfg box devices.eth0.security.acls)"
assert_eq "box's card rejects anything else" "reject" "$(cfg box devices.eth0.security.acls.default.egress.action)"
acl="$(cat "$FAKE_INCUS_STATE/acls/incs-a-box")"
assert_contains "box may reach only its proxy port" "destination: 10.201.0.10/32
  destination_port: \"10000\"" "$acl"
assert_contains "the host may reach box" "source: 10.201.0.1/32" "$acl"
assert_eq "box moved to a fresh address" "10.201.0.11" "$(cfg box devices.eth0.ipv4.address)"
eacl="$(cat "$FAKE_INCUS_STATE/acls/$E")"
assert_contains "the egress container lets box in from its new address" "source: 10.201.0.11/32" "$eacl"
assert_not_contains "and not from the old one" "10.201.0.50" "$eacl"
seq="$(calls_since "$before" | grep -nE '^stop box|^config device set box eth0 ipv4.address|^config set box user.incs.egress.transition=enforce' | cut -d: -f2- | cut -c1-40)"
assert_eq "barrier, then stop, then the new address" "config set box user.incs.egress.transiti
stop box --timeout 30
config device set box eth0 ipv4.address=" "$seq"
assert_eq "box runs again" "RUNNING" "$(status box)"
assert_eq "the barrier is cleared" "none" "$(cfg box user.incs.egress.transition)"
assert_eq "autostart is back to unset" "" "$(cfg box boot.autostart)"
assert_contains "the active state is enforce" "enforce:" "$(cfg box user.incs.egress.active)"
assert_eq "its proxy enforces" "enforce" "$(gen_file box mode)"

echo "allowing and removing"
run allow box Docs.RS
assert_contains "allow widens" "allowed; open connections keep running" "$OUT"
assert_eq "the host is stored normalized" "docs.rs" "$(cfg box user.incs.egress.allow)"
assert_contains "the proxy allows it" "docs.rs" "$(gen_file box hosts)"
run allow box "not a host"
assert_eq "a bad host is refused" "1" "$RC"
assert_contains "and named" "Not a hostname incs accepts: not a host" "$OUT"
run rm box docs.rs
assert_contains "rm tightens" "narrowed; its open connections through the proxy ended" "$OUT"
assert_eq "it's off box's list" "" "$(cfg box user.incs.egress.allow)"
run rm box api.anthropic.com
assert_contains "rm says when another source still allows it" "still allowed for box by baseline" "$OUT"

echo "modes"
addr="$(cfg box devices.eth0.ipv4.address)"
run mode box report
assert_contains "enforce to report widens" "allowed; open connections" "$OUT"
assert_eq "the proxy reports" "report" "$(gen_file box mode)"
run mode box enforce
assert_contains "report to enforce tightens without a restart" "narrowed" "$OUT"
assert_eq "the address stays" "$addr" "$(cfg box devices.eth0.ipv4.address)"
run mode box off
assert_contains "to off widens" "allowed" "$OUT"
assert_eq "off opens the card to the bridge's rules" "incs-base" "$(cfg box devices.eth0.security.acls)"
assert_eq "off allows outbound by default" "allow" "$(cfg box devices.eth0.security.acls.default.egress.action)"
assert_eq "the proxy stays, with the open policy" "off" "$(gen_file box mode)"
incus config set box boot.autostart=true
run mode box enforce
assert_contains "off to enforce locks it again" "locked" "$OUT"
assert_eq "on another fresh address" "10.201.0.12" "$(cfg box devices.eth0.ipv4.address)"
assert_eq "an explicit autostart comes back" "true" "$(cfg box boot.autostart)"

echo "an interrupted lockdown"
run mode box off
FAKE_INCUS_FAIL_CALL='^config device set box eth0 ipv4.address' run mode box enforce
assert_eq "a failed step fails" "1" "$RC"
assert_eq "box stays stopped" "STOPPED" "$(status box)"
assert_eq "it won't start on its own" "false" "$(cfg box boot.autostart)"
assert_contains "the original autostart is saved" "true" "$(cfg box user.incs.egress.autostart-saved)"
assert_contains "the transition records the target address" "enforce:10.201.0.13" "$(cfg box user.incs.egress.transition)"
shell_out="$(bash "$SANDBOX/repo/incus.shell" box true 2>&1 || true)"
assert_contains "incs won't start it" "partway through turning its allowlist on" "$shell_out"
incus start box   # as if someone started it by hand
FAKE_INCUS_FAIL_CALL='^stop box' run refresh box
assert_eq "a retry that can't stop it fails too" "1" "$RC"
assert_contains "the retry keeps the original autostart" "true" "$(cfg box user.incs.egress.autostart-saved)"
assert_contains "it says it couldn't confirm the stop" "Could not confirm box stopped" "$OUT"
run refresh box
assert_eq "refresh finishes it" "0" "$RC"
assert_eq "at the address the transition recorded" "10.201.0.13" "$(cfg box devices.eth0.ipv4.address)"
assert_eq "box runs" "RUNNING" "$(status box)"
assert_eq "the barrier is cleared" "none" "$(cfg box user.incs.egress.transition)"
assert_eq "the original autostart is restored" "true" "$(cfg box boot.autostart)"

echo "finishing a lockdown that only missed its commit"
incus config set box user.incs.egress.transition=enforce:10.201.0.13 user.incs.egress.autostart-saved=true boot.autostart=false
before="$(ncalls)"
run refresh box
assert_contains "it commits without stopping" "locked and its proxy is verified" "$OUT"
assert_eq "no stop" "" "$(calls_since "$before" | grep '^stop box' || true)"
assert_eq "the barrier is cleared" "none" "$(cfg box user.incs.egress.transition)"
assert_eq "autostart is restored" "true" "$(cfg box boot.autostart)"

echo "--all"
run allow --all extra.example
assert_eq "--all needs a yes without a terminal" "1" "$RC"
run allow --all extra.example --yes
assert_eq "--all --yes goes ahead" "0" "$RC"
assert_contains "it's in your additions" "extra.example" "$(cat "$INCS_CONFIG_DIR/egress-baseline.txt")"
assert_contains "box's proxy allows it" "extra.example" "$(gen_file box hosts)"
run rm --all extra.example --yes
assert_not_contains "rm --all takes it out" "extra.example" "$(cat "$INCS_CONFIG_DIR/egress-baseline.txt")"

echo "ls and log"
run ls
assert_contains "ls lists box" "box" "$OUT"
assert_contains "with its proxy" "incs-egress:10000" "$OUT"
run ls box
assert_contains "ls box shows where hosts come from" "api.anthropic.com" "$OUT"
assert_contains "the baseline is a source" "baseline" "$OUT"
mkdir -p "$FAKE_INCUS_STATE/ctl/$E/box"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
  2026-10-30T10:00:00Z docs.rs 443 blocked "default rule policy used" 9 \
  2026-10-30T10:05:00Z docs.rs 443 blocked "default rule policy used" 9 \
  2026-10-30T10:01:00Z api.anthropic.com 443 allowed "host matched allowed domain in rule" 9 > "$FAKE_INCUS_STATE/ctl/$E/box/log"
run log box
assert_contains "log counts hits per host" "docs.rs                                            443    blocked           2  2026-10-30T10:05:00Z" "$OUT"
assert_eq "blocked hosts come first" "docs.rs" "$(sed -n 2p <<< "$OUT" | awk '{print $1}')"
assert_contains "log says how to allow" "incs egress allow box <host>" "$OUT"

echo "a baseline update"
echo "new-tool.example" >> "$SANDBOX/repo/egress/baseline.txt"
run refresh
assert_eq "without a yes it keeps the approved baseline" "1" "$RC"
assert_contains "it asks for a yes" "Pass --yes" "$OUT"
assert_contains "it shows what changed" "+ new-tool.example" "$OUT"
run refresh box
assert_not_contains "a declined update stays out of box's policy" "new-tool.example" "$(gen_file box hosts)"
run refresh --yes
assert_contains "--yes approves it" "Approved the new baseline" "$OUT"
assert_contains "and box's proxy allows it" "new-tool.example" "$(gen_file box hosts)"

echo "refusals"
incus launch img legacy -p default >/dev/null
incus config set legacy user.managed-by=agent-incus
run mode legacy enforce
assert_contains "a container on the default bridge can't be confined" "on the default bridge" "$OUT"
run mode "$E" enforce
assert_contains "an egress container can't be allowlisted" "is an egress container" "$OUT"
run mode box sideways
assert_eq "an unknown mode is refused" "1" "$RC"

echo "deleting"
bash "$SANDBOX/repo/incs" -d box >/dev/null 2>&1
assert_contains "deleting box removes its proxy" "remove box" "$(cat "$FAKE_INCUS_STATE/ctl/$E/calls.log")"
assert_not_contains "and its rule in the egress container" "10.201.0.13" "$(cat "$FAKE_INCUS_STATE/acls/$E")"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
