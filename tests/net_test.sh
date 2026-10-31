#!/bin/bash
# tests/net_test.sh
# The isolated bridge (incus.net): address arithmetic, the Incus preflight,
# creating and converging the bridge, its rules and profile, handing out
# addresses, and incus.init launching new instances on it. Runs against the
# fake `incus`.
# Run: bash tests/net_test.sh

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
# sudo runs the command as is; ufw records what it was asked.
printf '#!/bin/sh\n"$@"\n' > "$SANDBOX/bin/sudo"
printf '#!/bin/sh\necho "$*" >> "%s/ufw.log"\n' "$SANDBOX" > "$SANDBOX/bin/ufw"
chmod +x "$SANDBOX/bin/"*
export PATH="$SANDBOX/bin:$PATH"
export HOME="$SANDBOX/home"
export INCS_NET_SUBNET=10.201.0.1/16
export INCS_UFW_CONF="$SANDBOX/no-ufw.conf"

fresh() {
  export FAKE_INCUS_STATE="$SANDBOX/state-$RANDOM$RANDOM"
  export INCS_LOCK_DIR="$FAKE_INCUS_STATE/lock"
  mkdir -p "$FAKE_INCUS_STATE"
  export FAKE_INCUS_VERSION=7.5.1
  unset FAKE_INCUS_FIREWALL FAKE_INCUS_EXTENSIONS FAKE_INCUS_FAIL_CALL FAKE_INCUS_IMAGE_TYPE
  rm -f "$SANDBOX/ufw.log"
}
# Runs a snippet with incus.net sourced. error() exits 1, as in incus.init.
net() {
  bash -c 'set -euo pipefail
    log()  { echo "[+] $1"; }
    warn() { echo "[!] $1"; }
    error(){ echo "[ERROR] $1" >&2; exit 1; }
    source "$1"; eval "$2"' _ "$REPO_ROOT/incus.net" "$1"
}
netkey() { cat "$FAKE_INCUS_STATE/networks/incsbr0/$1" 2>/dev/null; }
calls() { grep -c -- "$1" "$FAKE_INCUS_STATE/calls.log" 2>/dev/null || true; }

echo "address arithmetic"
fresh
assert_eq "a range outside the subnet is kept" "192.168.0.0/16" "$(net 'net_cidr_minus 192.168.0.0/16 10.201.0.0/16')"
assert_eq "a range inside the subnet is dropped" "" "$(net 'net_cidr_minus 10.201.0.0/16 10.0.0.0/8')"
assert_eq "10/8 minus 10.201/16 leaves its siblings" \
  "10.0.0.0/9 10.128.0.0/10 10.224.0.0/11 10.208.0.0/12 10.192.0.0/13 10.204.0.0/14 10.202.0.0/15 10.200.0.0/16" \
  "$(net 'net_cidr_minus 10.0.0.0/8 10.201.0.0/16' | tr '\n' ' ' | sed 's/ $//')"
rejects="$(net 'net_egress_rejects 10.201.0.1/16')"
assert_not_contains "the rejects leave the bridge's own /16 open" "10.201." "$rejects"
assert_contains "the rejects cover cloud metadata" "169.254.0.0/16" "$rejects"
assert_contains "the rejects cover tailnets" "100.64.0.0/10" "$rejects"
assert_eq "the DHCP pool is the last /24" "10.201.255.10-10.201.255.250" "$(net 'net_dhcp_pool 10.201.0.1/16')"
assert_eq "versions: equal is new enough" "yes" "$(net 'net_version_ge 7.5.1 7.5.1 && echo yes || echo no')"
assert_eq "versions: 7.10 is newer than 7.5.1" "yes" "$(net 'net_version_ge 7.10 7.5.1 && echo yes || echo no')"
assert_eq "versions: 6.0.5 LTS is too old" "no" "$(net 'net_version_ge "6.0.5 LTS" 7.5.1 && echo yes || echo no')"

echo "preflight"
fresh
assert_eq "Incus 7.5.1 with nftables and NIC ACLs passes" "ok" "$(net 'net_preflight && echo ok' 2>&1)"
out="$(FAKE_INCUS_VERSION=7.4 net 'net_preflight' 2>&1 || true)"
assert_contains "an old Incus is refused" "older than 7.5.1" "$out"
assert_contains "the refusal names the opt-out" "--insecure-network" "$out"
out="$(FAKE_INCUS_FIREWALL=xtables net 'net_preflight' 2>&1 || true)"
assert_contains "xtables is refused" "not nftables" "$out"
out="$(FAKE_INCUS_EXTENSIONS=network_address_set net 'net_preflight' 2>&1 || true)"
assert_contains "missing NIC ACLs are refused" "network_bridge_acl_devices" "$out"
out="$(FAKE_INCUS_FIREWALL=none net 'net_preflight' 2>&1 || true)"
assert_contains "a server that names no firewall is refused with a reason" "not nftables" "$out"

echo "ensure_net"
fresh
net 'ensure_net' >/dev/null
assert_eq "the bridge gets the subnet" "10.201.0.1/16" "$(netkey ipv4.address)"
assert_eq "IPv6 is off" "none" "$(netkey ipv6.address)"
assert_eq "NAT is on" "true" "$(netkey ipv4.nat)"
assert_eq "the DHCP pool is set" "10.201.255.10-10.201.255.250" "$(netkey ipv4.dhcp.ranges)"
assert_eq "no DNS server, public resolvers over DHCP" \
  "$(printf 'port=0\ndhcp-option=option:dns-server,1.1.1.1,9.9.9.9')" "$(netkey raw.dnsmasq)"
acl="$(cat "$FAKE_INCUS_STATE/acls/incs-base")"
assert_contains "the ACL rejects private ranges" "action: reject
  destination: 0.0.0.0/8,10.0.0.0/9" "$acl"
assert_contains "the ACL rejects the host" "destination: 10.201.0.1/32" "$acl"
assert_contains "the ACL lets the host in" "source: 10.201.0.1/32" "$acl"
dev="$FAKE_INCUS_STATE/profiles/incs-net/devices/eth0"
assert_eq "the profile's eth0 is on the bridge" "incsbr0" "$(cat "$dev/network")"
assert_eq "the profile filters IPv4 spoofing" "true" "$(cat "$dev/security.ipv4_filtering")"
assert_eq "the profile filters MAC spoofing" "true" "$(cat "$dev/security.mac_filtering")"
assert_eq "the profile uses the ACL" "incs-base" "$(cat "$dev/security.acls")"
assert_eq "inbound defaults to drop" "drop" "$(cat "$dev/security.acls.default.ingress.action")"
assert_eq "outbound defaults to allow" "allow" "$(cat "$dev/security.acls.default.egress.action")"
sets_before="$(calls '^network set incsbr0')"
INCS_NET_SUBNET=10.99.0.1/16 net 'ensure_net' >/dev/null
assert_eq "a second run keeps the subnet" "10.201.0.1/16" "$(netkey ipv4.address)"
assert_eq "a second run changes no bridge setting" "$sets_before" "$(calls '^network set incsbr0')"
assert_eq "no ufw rules without ufw" "no" "$([[ -f "$SANDBOX/ufw.log" ]] && echo yes || echo no)"

fresh
echo "ENABLED=yes" > "$SANDBOX/ufw.conf"
INCS_UFW_CONF="$SANDBOX/ufw.conf" net 'ensure_net' >/dev/null
ufw="$(cat "$SANDBOX/ufw.log")"
assert_contains "ufw: DHCP is allowed on the bridge" "allow in on incsbr0 to any port 67 proto udp" "$ufw"
assert_contains "ufw: forwarding out of the bridge is allowed" "route allow in on incsbr0" "$ufw"
assert_not_contains "ufw: DNS stays closed" "port 53" "$ufw"
INCS_UFW_CONF="$SANDBOX/ufw.conf" net 'ensure_net' >/dev/null
assert_eq "ufw rules are added once" "2" "$(wc -l < "$SANDBOX/ufw.log" | tr -d ' ')"

fresh
mkdir -p "$FAKE_INCUS_STATE/networks/incsbr0"
printf '10.5.0.1/24' > "$FAKE_INCUS_STATE/networks/incsbr0/ipv4.address"
out="$(net 'ensure_net' 2>&1 || true)"
assert_contains "a bridge that isn't a /16 is refused" "needs a /16" "$out"

echo "addresses"
fresh
net 'ensure_net' >/dev/null
assert_eq "the first address" "10.201.0.10" "$(net 'net_next_address')"
assert_eq "the next one" "10.201.0.11" "$(net 'net_next_address')"
assert_eq "the counter is in the bridge's config" "2" "$(netkey user.incs.next-address)"
incus launch img taken -d eth0,ipv4.address=10.201.0.12 >/dev/null
assert_eq "an address in use is skipped" "10.201.0.13" "$(net 'net_next_address')"
printf '245' > "$FAKE_INCUS_STATE/networks/incsbr0/user.incs.next-address"
assert_eq ".255 and .0 are skipped" "10.201.1.1" "$(net 'net_next_address')"
printf '65269' > "$FAKE_INCUS_STATE/networks/incsbr0/user.incs.next-address"
assert_eq "the counter wraps below the DHCP pool" "10.201.0.10" "$(net 'net_next_address')"

mkdir -p "$FAKE_INCUS_STATE/networks/incsbr0"
printf '10.77.0.10/16' > "$FAKE_INCUS_STATE/networks/incsbr0/ipv4.address"
printf '0' > "$FAKE_INCUS_STATE/networks/incsbr0/user.incs.next-address"
assert_eq "a custom gateway's address is never handed out" "10.77.0.11" "$(net 'net_next_address')"
assert_eq "routes that overlap a candidate rule it out" "yes" "$(net 'net_overlaps 10.0.0.0/8 10.200.0.0/16 && ! net_overlaps 10.199.0.0/16 10.200.0.0/16 && echo yes')"
assert_eq "a broad route pushes the pick outside it" "10.200.0.1/16" "$(INCS_NET_SUBNET= net 'ip() { echo "10.201.0.0/16 dev wg0"; }; net_pick_subnet')"
assert_eq "a 10/8 route leaves no free 10.x" "1" "$(INCS_NET_SUBNET= net 'ip() { echo "10.0.0.0/8 via 192.168.1.1"; }; net_pick_subnet' >/dev/null 2>&1; echo $?)"
assert_contains "resolvers that aren't IPv4 addresses are refused" "must be IPv4 addresses" "$(INCS_RESOLVERS=$'1.1.1.1\nport=53' net 'true' 2>&1 || true)"

echo "lock"
fresh
mkdir -p "$INCS_LOCK_DIR"; echo 999999 > "$INCS_LOCK_DIR/pid"
assert_eq "a lock left by a dead process is taken over" "$INCS_LOCK_DIR" "$(net 'incs_lock; echo "$INCS_LOCK_DIR"; incs_unlock')"
assert_eq "unlock removes it" "no" "$([[ -d "$INCS_LOCK_DIR" ]] && echo yes || echo no)"

echo "incus.init"
# A copy of the scripts with no plugins, launching from a template so nothing
# is provisioned.
mkdir -p "$SANDBOX/repo"
cp "$REPO_ROOT"/incus.* "$SANDBOX/repo/"
cp -R "$REPO_ROOT/egress" "$SANDBOX/repo/egress"
# The allowlist is tests/egress_init_test.sh's; these check the network alone.
init() { bash "$SANDBOX/repo/incus.init" "$@" --from base --no-tui --no-copy --egress off >"$SANDBOX/out" 2>&1 && RC=0 || RC=$?; }
template() { mkdir -p "$FAKE_INCUS_STATE/images/incus-init/base/root"; }
inst() { cat "$FAKE_INCUS_STATE/instances/$1/$2" 2>/dev/null; }

fresh; template
init box
assert_eq "a container launches" "0" "$RC"
assert_eq "it joins the isolated network's profile" "default agent-incus incs-net" "$(inst box profiles | tr '\n' ' ' | sed 's/ $//')"
assert_eq "it gets an assigned address" "10.201.0.10" "$(inst box config/devices.eth0.ipv4.address)"
assert_eq "it's marked isolated" "isolated" "$(inst box config/user.incs.net)"
init box2
assert_eq "the next container gets the next address" "10.201.0.11" "$(inst box2 config/devices.eth0.ipv4.address)"
assert_eq "the lock is released" "no" "$([[ -d "$INCS_LOCK_DIR" ]] && echo yes || echo no)"

fresh; template
FAKE_INCUS_IMAGE_TYPE=virtual-machine init vmbox
assert_eq "a VM launches" "0" "$RC"
assert_eq "a VM keeps the default profile and joins the network's" "default incs-net" "$(inst vmbox profiles | tr '\n' ' ' | sed 's/ $//')"

fresh; template
init open --insecure-network
assert_eq "--insecure-network launches" "0" "$RC"
assert_eq "--insecure-network keeps today's profiles" "default agent-incus" "$(inst open profiles | tr '\n' ' ' | sed 's/ $//')"
assert_eq "--insecure-network sets no address" "" "$(inst open config/devices.eth0.ipv4.address)"
assert_eq "--insecure-network creates no bridge" "no" "$([[ -d "$FAKE_INCUS_STATE/networks/incsbr0" ]] && echo yes || echo no)"
assert_eq "it's marked open" "open" "$(inst open config/user.incs.net)"
assert_contains "it says it isn't isolated" "where instances can reach each other and the host" "$(cat "$SANDBOX/out")"

fresh; template
INCS_INSECURE_NETWORK=1 init open2
assert_eq "INCS_INSECURE_NETWORK=1 keeps today's profiles" "default agent-incus" "$(inst open2 profiles | tr '\n' ' ' | sed 's/ $//')"

fresh; template
FAKE_INCUS_VERSION=7.4 init old
assert_eq "an old Incus stops the build" "1" "$RC"
assert_eq "nothing is created on an old Incus" "no" "$([[ -d "$FAKE_INCUS_STATE/instances/old" ]] && echo yes || echo no)"

fresh; template
bash "$SANDBOX/repo/incus.init" dry --from base --no-tui --no-copy --egress off --dry-run >"$SANDBOX/out" 2>&1 || true
assert_contains "--dry-run names the network" "Network:     incsbr0, isolated" "$(cat "$SANDBOX/out")"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
