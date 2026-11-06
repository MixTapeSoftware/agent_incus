#!/bin/bash
# tests/egress_test.sh
# The host side of the egress allowlist (boxen.egress): hostnames, the
# baseline, policy identity, the egress container's rules and setup, agent
# registration, and choosing between widening and tightening. Runs against
# the fake `incus`, with a stand-in for the ctl inside the egress container;
# tests/host/egress_ctl_test.sh runs the real ctl.
# Run: bash tests/egress_test.sh

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
mkdir -p "$SANDBOX/bin"
cp "$SCRIPT_DIR/lib/fake_incus" "$SANDBOX/bin/incus"
chmod +x "$SANDBOX/bin/incus"
export PATH="$SANDBOX/bin:$PATH"
export HOME="$SANDBOX/home"
export BOXEN_NET_SUBNET=10.201.0.1/16
export BOXEN_UFW_CONF="$SANDBOX/no-ufw.conf"
export FAKE_EGRESS_CTL="$SCRIPT_DIR/lib/fake_egress_ctl"

fresh() {
  export FAKE_INCUS_STATE="$SANDBOX/state-$RANDOM$RANDOM"
  export BOXEN_LOCK_DIR="$FAKE_INCUS_STATE/lock"
  export BOXEN_CONFIG_DIR="$FAKE_INCUS_STATE/config"
  mkdir -p "$FAKE_INCUS_STATE"
  export FAKE_INCUS_VERSION=7.5.1
  unset FAKE_EGRESS_CTL_FAIL
}
# Runs a snippet with boxen.net and boxen.egress sourced.
eg() {
  bash -c 'set -euo pipefail
    log()  { echo "[+] $1" >&2; }
    warn() { echo "[!] $1" >&2; }
    error(){ echo "[ERROR] $1" >&2; exit 1; }
    SCRIPT_DIR="$1"
    source "$1/boxen.net"; source "$1/boxen.egress"; eval "$2"' _ "$REPO_ROOT" "$1"
}
cfg() { cat "$FAKE_INCUS_STATE/instances/$1/config/$2" 2>/dev/null; }
ctl_calls() { cat "$FAKE_INCUS_STATE/ctl/$1/calls.log" 2>/dev/null; }
# An agent on the bridge, with an address.
agent() { incus launch img "$1" -p default -d "eth0,ipv4.address=$2" >/dev/null; }

echo "names and hostnames"
fresh
assert_eq "the default egress container" "boxen-egress" "$(eg 'egress_name')"
assert_eq "a named one" "boxen-egress-eogva" "$(eg 'egress_name eogva')"
assert_contains "a bad name is refused" "Invalid egress container name" "$(eg 'egress_name "Bad_Name"' 2>&1 || true)"
assert_eq "hosts are lowercased, trailing dot dropped" "docs.rs" "$(eg 'egress_host Docs.RS.')"
assert_eq "a leading wildcard is kept" "*.example.com" "$(eg 'egress_host "*.example.com"')"
assert_eq "punycode is accepted" "xn--bcher-kva.example" "$(eg 'egress_host xn--bcher-kva.example')"
for bad in "a.*.example.com" "10.0.0.1" "example.com:443" "exa_mple.com" "bücher.example" "-x.example.com" "example" "*.com.*"; do
  assert_eq "refused: $bad" "no" "$(eg "egress_host '$bad' >/dev/null && echo yes || echo no")"
done

echo "the baseline"
fresh
shipped="$(eg 'egress_read_hosts "$SCRIPT_DIR/egress/baseline.txt"')"
n="$(printf '%s\n' "$shipped" | wc -l | tr -d ' ')"
[[ "$n" -gt 150 ]] && { PASS=$((PASS+1)); echo "  ok  every shipped baseline host is valid ($n hosts)"; } ||
  { FAIL=$((FAIL+1)); echo "  FAIL the shipped baseline has $n hosts"; }
assert_eq "the shipped baseline has no duplicates" "" "$(printf '%s\n' "$shipped" | sort | uniq -d)"
for left_out in "*.amazonaws.com" "*.googleapis.com" "*.blob.core.windows.net" "*.googleusercontent.com"; do
  assert_eq "no bucket wildcard: $left_out" "" "$(grep -xF -- "$left_out" <<< "$shipped" || true)"
done
assert_contains "crl.digicert.com is spelled out" "crl.digicert.com" "$shipped"
printf 'good.example\nnot a host\n' > "$SANDBOX/bad.txt"
assert_contains "a bad list line is refused with its number" "line 2" "$(eg "egress_read_hosts '$SANDBOX/bad.txt'" 2>&1 || true)"

echo "an agent's hosts and policy"
fresh
agent box 10.201.0.20
incus config set box user.boxen.egress.allow=docs.rs,crates.example
incus config set box user.boxen.egress.plugin-allow=*.tailscale.com
mkdir -p "$BOXEN_CONFIG_DIR"; printf '# mine\nextra.example\n' > "$BOXEN_CONFIG_DIR/egress-baseline.txt"
hosts="$(eg 'egress_hosts box')"
assert_eq "first use approves the shipped baseline" "yes" "$([[ -f "$BOXEN_CONFIG_DIR/egress-approved-baseline.txt" ]] && echo yes || echo no)"
assert_contains "hosts include the baseline" "api.anthropic.com" "$hosts"
assert_contains "the user's additions" "extra.example" "$hosts"
assert_contains "the plugins' additions" "*.tailscale.com" "$hosts"
assert_contains "and the agent's own" "docs.rs" "$hosts"
assert_eq "hosts are sorted and unique" "$(printf '%s\n' "$hosts" | LC_ALL=C sort -u)" "$hosts"
# bxn's own log writes to stdout; the first-use notice mustn't join the list.
rm -f "$BOXEN_CONFIG_DIR/egress-approved-baseline.txt"
hosts="$(bash -c 'set -euo pipefail; log() { echo "[+] $1"; }; error() { exit 1; }
  SCRIPT_DIR="$1"; source "$1/boxen.net"; source "$1/boxen.egress"; egress_hosts box' _ "$REPO_ROOT" 2>/dev/null)"
assert_eq "the first-use notice stays out of the host list" "" "$(grep -v '^[*a-z0-9.-]*$' <<< "$hosts" || true)"
id1="$(eg 'egress_hosts box | egress_policy_id enforce')"
assert_eq "the policy id is stable" "$id1" "$(eg 'egress_hosts box | egress_policy_id enforce')"
assert_eq "the policy id is 16 hex digits" "yes" "$([[ "$id1" =~ ^[0-9a-f]{16}$ ]] && echo yes || echo no)"
[[ "$id1" != "$(eg 'egress_hosts box | egress_policy_id report')" ]] && { PASS=$((PASS+1)); echo "  ok  the mode changes the id"; } ||
  { FAIL=$((FAIL+1)); echo "  FAIL the mode changes the id"; }
[[ "$id1" != "$(eg '{ egress_hosts box; echo more.example; } | egress_policy_id enforce')" ]] && { PASS=$((PASS+1)); echo "  ok  a host changes the id"; } ||
  { FAIL=$((FAIL+1)); echo "  FAIL a host changes the id"; }

assert_eq "off ignores the hosts" "$(eg 'echo a.example | egress_policy_id off')" "$(eg 'echo b.example | egress_policy_id off')"
incus launch img old-egress >/dev/null
assert_eq "an egress container with no proxy version keeps its ids" "$id1" "$(eg 'egress_hosts box | egress_policy_id enforce old-egress')"
incus config set old-egress user.boxen.egress.version=0123456789abcdef
id2="$(eg 'egress_hosts box | egress_policy_id enforce old-egress')"
[[ "$id1" != "$id2" ]] && { PASS=$((PASS+1)); echo "  ok  the installed proxy version changes the id"; } ||
  { FAIL=$((FAIL+1)); echo "  FAIL the installed proxy version changes the id"; }
incus config set old-egress user.boxen.egress.version=fedcba9876543210
[[ "$id2" != "$(eg 'egress_hosts box | egress_policy_id enforce old-egress')" ]] && { PASS=$((PASS+1)); echo "  ok  and so does a newer one"; } ||
  { FAIL=$((FAIL+1)); echo "  FAIL and so does a newer one"; }

echo "the proxy version"
v="$(eg 'egress_proxy_version')"
assert_eq "it's 16 hex digits" "yes" "$([[ "$v" =~ ^[0-9a-f]{16}$ ]] && echo yes || echo no)"
for f in build-smokescreen.sh boxen-smokescreen/main.go boxen-proxy-run boxen-egress-ctl; do
  rm -rf "$SANDBOX/repo2"; mkdir -p "$SANDBOX/repo2"; cp -R "$REPO_ROOT/egress" "$SANDBOX/repo2/egress"
  echo "# changed" >> "$SANDBOX/repo2/egress/$f"
  [[ "$v" != "$(eg "SCRIPT_DIR='$SANDBOX/repo2'; egress_proxy_version")" ]] && { PASS=$((PASS+1)); echo "  ok  a change to $f changes it"; } ||
    { FAIL=$((FAIL+1)); echo "  FAIL a change to $f changes it"; }
done
rm -rf "$SANDBOX/repo2"; mkdir -p "$SANDBOX/repo2"; cp -R "$REPO_ROOT/egress" "$SANDBOX/repo2/egress"
echo "// test" >> "$SANDBOX/repo2/egress/boxen-smokescreen/main_test.go"
assert_eq "the Go tests aren't part of it" "$v" "$(eg "SCRIPT_DIR='$SANDBOX/repo2'; egress_proxy_version")"

echo "the egress container"
fresh
eg 'ensure_net; egress_ensure boxen-egress' 2>/dev/null
e=boxen-egress
assert_eq "it's created" "yes" "$([[ -d "$FAKE_INCUS_STATE/instances/$e" ]] && echo yes || echo no)"
assert_eq "it's on the isolated network" "default boxen-net" "$(tr '\n' ' ' < "$FAKE_INCUS_STATE/instances/$e/profiles" | sed 's/ $//')"
assert_eq "it has an assigned address" "10.201.0.10" "$(cfg $e devices.eth0.ipv4.address)"
assert_eq "it uses its own rules" "boxen-egress" "$(cfg $e devices.eth0.security.acls)"
assert_eq "outbound defaults to reject" "reject" "$(cfg $e devices.eth0.security.acls.default.egress.action)"
assert_eq "inbound defaults to drop" "drop" "$(cfg $e devices.eth0.security.acls.default.ingress.action)"
assert_eq "its rules come with incus init, not a later step" "0" "$(grep -c "^config device set $e " "$FAKE_INCUS_STATE/calls.log" || true)"
assert_eq "it starts on its own" "true" "$(cfg $e boot.autostart)"
assert_eq "before the agents" "100" "$(cfg $e boot.autostart.priority)"
assert_eq "it's set up" "1" "$(cfg $e user.boxen.egress.ready)"
assert_contains "the ctl is set up with one resolver and the deny ranges" "setup 1.1.1.1 0.0.0.0/8,10.0.0.0/8," "$(ctl_calls $e)"
stage=/root/boxen-egress-payload
assert_contains "smokescreen is built in it, from bxn's main.go" "sh $stage/build-smokescreen.sh $stage/main.go" "$(cat "$FAKE_INCUS_STATE/exec.log")"
assert_eq "bxn's main.go went in" "yes" "$(cmp -s "$REPO_ROOT/egress/boxen-smokescreen/main.go" "$FAKE_INCUS_STATE/instances/$e/root$stage/main.go" && echo yes || echo no)"
assert_contains "the scripts go in place after the build" "sh -c set -e; install -d -m 755" "$(grep -A1 "build-smokescreen.sh" "$FAKE_INCUS_STATE/exec.log" | tail -1)"
assert_eq "it records the proxy version" "$(eg 'egress_proxy_version')" "$(cfg $e user.boxen.egress.version)"
acl="$(cat "$FAKE_INCUS_STATE/acls/$e")"
assert_contains "out: private ranges rejected, the bridge included" "destination: 0.0.0.0/8,10.0.0.0/8," "$acl"
assert_contains "out: the web" "destination_port: 80,443" "$acl"
assert_contains "out: DNS to the resolvers only" "destination: 9.9.9.9/32" "$acl"
assert_contains "in: nothing before any agent" "ingress: []" "$acl"
eg 'egress_ensure boxen-egress' 2>/dev/null
assert_eq "a second run doesn't set it up again" "1" "$(ctl_calls $e | grep -c '^setup')"
assert_contains "a named group gets its own" "boxen-egress-eogva" "$(eg 'egress_name eogva')"

echo "agents"
agent box 10.201.0.20
agent two 10.201.0.21
eg 'egress_register box boxen-egress; egress_register two boxen-egress' 2>/dev/null
assert_eq "the first agent's port" "10000" "$(cfg box user.boxen.egress.port)"
assert_eq "the next agent's port" "10001" "$(cfg two user.boxen.egress.port)"
assert_eq "the agent records its egress container" "boxen-egress" "$(cfg box user.boxen.egress.container)"
assert_contains "its proxy is added" "add box 10000" "$(ctl_calls $e)"
acl="$(cat "$FAKE_INCUS_STATE/acls/$e")"
assert_contains "in: box, from its address, to its port only" "source: 10.201.0.20/32
  destination_port: \"10000\"" "$acl"
assert_contains "in: two, to its own port" "source: 10.201.0.21/32
  destination_port: \"10001\"" "$acl"
eg 'egress_register box boxen-egress' 2>/dev/null
assert_eq "registering again keeps the port" "10000" "$(cfg box user.boxen.egress.port)"
assert_contains "an agent can't move by registering" "already uses boxen-egress" "$(eg 'egress_register box boxen-egress-other' 2>&1 || true)"

echo "applying policies"
apply() { eg "egress_apply box ${1:-}" 2>/dev/null; }
assert_eq "the first policy" "tightened" "$(apply)"
assert_eq "it enforces by default" "enforce" "$(cat "$FAKE_INCUS_STATE/ctl/$e/box/gens/1/mode")"
assert_contains "the active state is recorded" "enforce:" "$(cfg box user.boxen.egress.active)"
assert_eq "applying again changes nothing" "unchanged" "$(apply)"
incus config set box user.boxen.egress.allow=docs.rs
assert_eq "adding a host widens" "widened" "$(apply)"
assert_contains "the new generation allows it" "docs.rs" "$(cat "$FAKE_INCUS_STATE/ctl/$e/box/gens/2/hosts")"
incus config set box user.boxen.egress.allow=
active="$(cfg box user.boxen.egress.active)"
current="$(cat "$FAKE_INCUS_STATE/ctl/$e/box/current")"
FAKE_EGRESS_CTL_FAIL='^hosts' eg 'if egress_apply box; then exit 0; else exit 1; fi' > "$SANDBOX/hosts-failure.out" 2>&1 && rc=0 || rc=1
assert_eq "a failed current-host read aborts the change" "1" "$rc"
assert_contains "the failed read explains why" "Could not read box's current hosts" "$(cat "$SANDBOX/hosts-failure.out")"
assert_eq "a failed host read keeps the current generation" "$current" "$(cat "$FAKE_INCUS_STATE/ctl/$e/box/current")"
assert_eq "a failed host read keeps the active state" "$active" "$(cfg box user.boxen.egress.active)"
assert_eq "removing a host tightens" "tightened" "$(apply)"
incus config set box user.boxen.egress=report
assert_eq "enforce to report widens" "widened" "$(apply)"
incus config set box user.boxen.egress=enforce
assert_eq "report to enforce tightens" "tightened" "$(apply)"
incus config set box user.boxen.egress=off
assert_eq "to off widens" "widened" "$(apply)"
incus config set box user.boxen.egress=enforce
active="$(cfg box user.boxen.egress.active)"
FAKE_EGRESS_CTL_FAIL='^tighten' eg 'egress_apply box' >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "a failed change fails" "1" "$rc"
assert_eq "and leaves the active state as it was" "$active" "$(cfg box user.boxen.egress.active)"
incus config set box user.boxen.egress=bogus
assert_contains "an unknown mode is refused" "unknown egress mode" "$(eg 'egress_apply box' 2>&1 || true)"
incus config set box user.boxen.egress=enforce

echo "updating the proxy"
assert_eq "a current egress container isn't out of date" "no" "$(eg 'egress_outdated boxen-egress && echo yes || echo no')"
assert_eq "or rebuilt" "" "$(eg 'egress_update boxen-egress' 2>&1)"
apply >/dev/null
incus config set $e user.boxen.egress.version=0123456789abcdef
# As left by an older bxn: the policy applied with the old build.
assert_eq "applied under the old build" "widened" "$(apply)"
assert_eq "it's out of date" "yes" "$(eg 'egress_outdated boxen-egress && echo yes || echo no')"
active="$(cfg box user.boxen.egress.active)"
current="$(cat "$FAKE_INCUS_STATE/ctl/$e/box/current")"
FAKE_INCUS_FAIL_EXEC='build-smokescreen' eg 'egress_ensure boxen-egress; echo carried on' > "$SANDBOX/update-failure.out" 2>&1
assert_contains "a failed update says how to retry" "Could not update the proxy in boxen-egress; its proxies keep serving as before. Retry: bxn egress refresh --all" "$(cat "$SANDBOX/update-failure.out")"
assert_contains "and egress_ensure carries on" "carried on" "$(cat "$SANDBOX/update-failure.out")"
assert_eq "a failed update keeps the old version" "0123456789abcdef" "$(cfg $e user.boxen.egress.version)"
assert_eq "and the agent's generation" "$current" "$(cat "$FAKE_INCUS_STATE/ctl/$e/box/current")"
assert_eq "and nothing new to apply" "unchanged" "$(apply)"
n="$(ctl_calls $e | grep -c '^setup' || true)"
eg 'egress_ensure boxen-egress' > "$SANDBOX/update.out" 2>&1
assert_contains "an update rebuilds smokescreen" "Updating the proxy in boxen-egress" "$(cat "$SANDBOX/update.out")"
assert_contains "and names the next step" "bxn egress refresh --all" "$(cat "$SANDBOX/update.out")"
assert_eq "it sets up the shared units again" "$((n + 1))" "$(ctl_calls $e | grep -c '^setup')"
assert_eq "it records the new version" "$(eg 'egress_proxy_version')" "$(cfg $e user.boxen.egress.version)"
assert_eq "the agent's next apply widens: open connections keep running" "widened" "$(apply)"
assert_contains "through a new generation" "widen box $(cat "$FAKE_INCUS_STATE/ctl/$e/box/current")" "$(ctl_calls $e | tail -1)"
assert_eq "and then nothing changes" "unchanged" "$(apply)"

echo "forgetting an agent"
# Its own rule set, as egress_nic_restrict leaves it.
incus network acl create boxen-a-box 2>/dev/null || true
eg 'egress_forget box boxen-egress' 2>/dev/null
assert_eq "a container that still exists keeps its rule set" "yes" "$([[ -f "$FAKE_INCUS_STATE/acls/boxen-a-box" ]] && echo yes || echo no)"
incus delete --force box
eg 'egress_forget box boxen-egress' 2>/dev/null
assert_contains "its proxy is removed" "remove box" "$(ctl_calls $e)"
assert_eq "and its own rule set is deleted" "no" "$([[ -f "$FAKE_INCUS_STATE/acls/boxen-a-box" ]] && echo yes || echo no)"
acl="$(cat "$FAKE_INCUS_STATE/acls/$e")"
assert_not_contains "its rule is gone" "10.201.0.20/32" "$acl"
assert_contains "the other agent's stays" "10.201.0.21/32" "$acl"
agent three 10.201.0.22
eg 'egress_register three boxen-egress' 2>/dev/null
assert_eq "a deleted agent's port isn't reused" "10002" "$(cfg three user.boxen.egress.port)"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
