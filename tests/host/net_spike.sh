#!/usr/bin/env bash
# tests/host/net_spike.sh
# Spike for the network lockdown plan (N1). Before incs builds on Incus
# network ACLs, address sets and IP/MAC filtering, check on a real host that
# they do what the plan assumes. The bridge is the one the egress design
# settled on: a /16 with no DNS server, public resolvers handed out by DHCP,
# and addresses set by incs at launch. Run it on a machine with Incus:
#
#   bash tests/host/net_spike.sh              # about 3 minutes
#   bash tests/host/net_spike.sh --restart    # also restarts Incus (sudo) and re-checks
#
# It creates only throwaway objects named incs-spike*, refuses to start if any
# already exist, and deletes them all on exit. If ufw is active, it adds narrow
# rules for its bridge with sudo and removes them on exit.
# Prints PASS/FAIL for what the plan relies on and INFO for what it needs to
# know. Paste the whole output back.

set -uo pipefail

RESTART=0
[[ "${1:-}" == "--restart" ]] && RESTART=1

NET=incs-spike0                 # a bridge name must be 15 characters or fewer
PROFILE=incs-spike-net
A=incs-spike-a                  # an agent attached to the proxy
B=incs-spike-b                  # an agent not attached to it
P=incs-spike-p                  # stands in for a proxy, listening on 443
SET=incs-spike-clients          # address set: the proxy's attached clients
ACL_P=incs-spike-p-in           # proxy ingress: 443 from the set only
ACL_PREC=incs-spike-prec        # allow and drop on the same port: which wins?
ACL_AGENT=incs-spike-agent      # agent: ingress from the host only, no egress to the host
IMAGE=images:alpine/3.24
HOST_PORT=47999                 # host side of the proxy-device check
HOST_SVC_PORT=47998             # a host service on the bridge address
RESOLVERS=1.1.1.1,9.9.9.9       # what DHCP hands out instead of the bridge

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
info() { echo "INFO $1"; }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected: $2, got: $3)"; fi; }
section() { echo ""; echo "== $1"; }

HOST_PY_PID=""
UFW_ADDED=0
# ufw denies incoming and routed traffic by default, which drops DHCP on a new
# bridge. These open what incs will (DHCP in, forwarding out) plus the host
# service, so the ACL is what blocks it rather than ufw. No DNS (53).
ufw_rules() {
  local verb="$1"
  sudo ufw $verb allow in on "$NET" to any port 67 proto udp &&
  sudo ufw $verb allow in on "$NET" to any port "$HOST_SVC_PORT" proto tcp &&
  sudo ufw route $verb allow in on "$NET"
}
cleanup() {
  echo ""; echo "== cleanup"
  [[ "$UFW_ADDED" == "1" ]] && ufw_rules delete >/dev/null 2>&1
  [[ -n "$HOST_PY_PID" ]] && kill "$HOST_PY_PID" 2>/dev/null
  for i in "$A" "$B" "$P"; do incus delete --force "$i" >/dev/null 2>&1; done
  for acl in "$ACL_P" "$ACL_PREC" "$ACL_AGENT"; do incus network acl delete "$acl" >/dev/null 2>&1; done
  incus network address-set delete "$SET" >/dev/null 2>&1
  incus profile delete "$PROFILE" >/dev/null 2>&1
  incus network delete "$NET" >/dev/null 2>&1
  for n in 63 64 71; do
    incus network acl delete "$(printf 'a%.0s' $(seq 1 "$n"))" >/dev/null 2>&1
    incus network address-set delete "$(printf 's%.0s' $(seq 1 "$n"))" >/dev/null 2>&1
  done
  echo "removed incs-spike objects"
}

# --- preflight -------------------------------------------------------------
section "preflight"
command -v incus >/dev/null || { echo "incus not found"; exit 1; }
for i in "$A" "$B" "$P"; do
  incus info "$i" >/dev/null 2>&1 && { echo "Instance $i already exists; refusing to run."; exit 1; }
done
incus network show "$NET" >/dev/null 2>&1 && { echo "Network $NET already exists; refusing to run."; exit 1; }
incus profile show "$PROFILE" >/dev/null 2>&1 && { echo "Profile $PROFILE already exists; refusing to run."; exit 1; }
for acl in "$ACL_P" "$ACL_PREC" "$ACL_AGENT" $(for n in 63 64 71; do printf 'a%.0s' $(seq 1 "$n"); echo; done); do
  incus network acl show "$acl" >/dev/null 2>&1 && { echo "ACL $acl already exists; refusing to run."; exit 1; }
done
for set in "$SET" $(for n in 63 64 71; do printf 's%.0s' $(seq 1 "$n"); echo; done); do
  incus network address-set show "$set" >/dev/null 2>&1 && { echo "Address set $set already exists; refusing to run."; exit 1; }
done
trap cleanup EXIT
info "br_netfilter loaded: $(lsmod 2>/dev/null | grep -q '^br_netfilter' && echo yes || echo no) (yes means ufw also filters traffic between containers on one bridge)"
if command -v ufw >/dev/null && sudo ufw status 2>/dev/null | grep -q '^Status: active'; then
  info "ufw is active; adding narrow rules for $NET (sudo; removed on exit)"
  UFW_ADDED=1
  ufw_rules "" >/dev/null || { fail "add the ufw rules for $NET"; exit 1; }
fi

server_version="$(incus version 2>/dev/null | awk -F': *' '/^Server version/ {print $2}')"
info "server version: ${server_version:-unknown}"
firewall="$(incus info 2>/dev/null | awk -F': *' 'tolower($1) ~ /firewall/ {print $2; exit}')"
info "firewall driver: ${firewall:-not reported}"
check "firewall is nftables" "nftables" "$firewall"
exts="$(incus info 2>/dev/null)"
for ext in network_bridge_acl_devices network_address_set; do
  if grep -q -- "- $ext\$" <<< "$exts"; then pass "API extension $ext"; else
    info "API extension $ext not listed; extensions mentioning it: $(grep -o -- "- [a-z_]*${ext#network_}[a-z_]*" <<< "$exts" | tr '\n' ' ')"
  fi
done

# --- name limits -----------------------------------------------------------
section "name length limits"
for n in 63 64 71; do
  name="$(printf 'a%.0s' $(seq 1 "$n"))"
  if incus network acl create "$name" >/dev/null 2>&1; then info "ACL name of $n characters: accepted"; incus network acl delete "$name" >/dev/null 2>&1
  else info "ACL name of $n characters: refused"; fi
  name="$(printf 's%.0s' $(seq 1 "$n"))"
  if incus network address-set create "$name" >/dev/null 2>&1; then info "address-set name of $n characters: accepted"; incus network address-set delete "$name" >/dev/null 2>&1
  else info "address-set name of $n characters: refused"; fi
done

# --- bridge, profile, instances --------------------------------------------
section "bridge and instances"
# A /16 no route on the host already covers, like incs picks.
OCT=""
for o in $(seq 230 250); do
  ip -4 route 2>/dev/null | grep -q "^10\.$o\." && continue
  incus network list --format csv 2>/dev/null | grep -q ",10\.$o\." && continue
  OCT="$o"; break
done
[[ -n "$OCT" ]] || { fail "find a free 10.x.0.0/16"; exit 1; }
if incus network create "$NET" "ipv4.address=10.$OCT.0.1/16" ipv4.nat=true ipv6.address=none \
     "ipv4.dhcp.ranges=10.$OCT.255.10-10.$OCT.255.250" \
     "raw.dnsmasq=$(printf 'port=0\ndhcp-option=option:dns-server,%s' "$RESOLVERS")" >/dev/null 2>/tmp/incs-spike-err.$$; then
  pass "create a /16 bridge with no DNS and public resolvers over DHCP"
else
  fail "create the bridge: $(cat /tmp/incs-spike-err.$$)"; rm -f /tmp/incs-spike-err.$$; exit 1
fi
rm -f /tmp/incs-spike-err.$$
GW_CIDR="$(incus network get "$NET" ipv4.address)"; GW="${GW_CIDR%/*}"
info "bridge $NET: $GW_CIDR, IPv6 off, DHCP pool 10.$OCT.255.10-250"
incus profile create "$PROFILE" >/dev/null
incus profile device add "$PROFILE" eth0 nic network="$NET" \
  security.ipv4_filtering=true security.mac_filtering=true >/dev/null || { fail "profile NIC with filtering"; exit 1; }

# incs sets each address at launch, outside the DHCP pool. P takes a pool
# address, as a control for DHCP itself.
A_WANT="10.$OCT.0.10"; B_WANT="10.$OCT.0.11"
incus launch "$IMAGE" "$A" -p default -p "$PROFILE" -d "eth0,ipv4.address=$A_WANT" >/dev/null || { fail "launch $A with a set address"; exit 1; }
incus launch "$IMAGE" "$B" -p default -p "$PROFILE" -d "eth0,ipv4.address=$B_WANT" >/dev/null || { fail "launch $B with a set address"; exit 1; }
incus launch "$IMAGE" "$P" -p default -p "$PROFILE" >/dev/null || { fail "launch $P"; exit 1; }
ip_of() { incus list "^$1\$" -c 4 --format csv | grep -oE '[0-9]+(\.[0-9]+){3}' | head -1; }
for i in "$A" "$B" "$P"; do
  for _ in $(seq 1 60); do [[ -n "$(ip_of "$i")" ]] && break; sleep 1; done
done
A_IP="$(ip_of "$A")"; B_IP="$(ip_of "$B")"; P_IP="$(ip_of "$P")"
info "A=$A_IP  B=$B_IP  P=$P_IP"
check "A gets the address set at launch" "$A_WANT" "$A_IP"
check "a launch-time address keeps the profile's ipv4_filtering" "true" "$(incus config device get "$A" eth0 security.ipv4_filtering 2>/dev/null)"
case "$P_IP" in 10.$OCT.255.*) pass "P gets a pool address ($P_IP)" ;; *) fail "P gets a pool address (got: ${P_IP:-none})" ;; esac
check "the profile's eth0 replaces the default profile's (A is on $NET)" "$NET" "$(incus config show "$A" --expanded | awk '/^  eth0:/ {d=1} d && /network:/ {print $2; exit}')"
resolv="$(incus exec "$A" -- cat /etc/resolv.conf 2>/dev/null)"
info "A's resolv.conf from DHCP: $(tr '\n' ';' <<< "$resolv")"
check "DHCP hands out the public resolvers" "yes" "$(grep -q "nameserver ${RESOLVERS%%,*}" <<< "$resolv" && echo yes || echo no)"
check "DHCP doesn't hand out the bridge as a resolver" "no" "$(grep -q "nameserver $GW" <<< "$resolv" && echo yes || echo no)"

for i in "$A" "$B" "$P"; do
  incus exec "$i" -- sh -c 'apk add --no-cache -q socat iproute2 curl iputils-arping >/dev/null 2>&1 || apk add --no-cache -q socat iproute2 curl iputils >/dev/null 2>&1' \
    || fail "install tools in $i (needs internet through $NET)"
done
listen() { incus exec "$1" -- sh -c "setsid socat TCP-LISTEN:$2,fork,reuseaddr SYSTEM:'echo ok' </dev/null >/dev/null 2>&1 &"; }
listen "$P" 443; listen "$P" 8443; listen "$A" 8080; listen "$A" 8081
sleep 1
# 0 when a TCP connection opens, nonzero when it is dropped or refused.
connects() { incus exec "$1" -- timeout 7 socat -u /dev/null "TCP:$2:$3,connect-timeout=5${4:+,bind=$4}" >/dev/null 2>&1 && echo yes || echo no; }
host_connects() { timeout 7 bash -c "</dev/tcp/$1/$2" >/dev/null 2>&1 && echo yes || echo no; }

check "control, no ACLs yet: B reaches P:443" "yes" "$(connects "$B" "$P_IP" 443)"
check "control, no ACLs yet: B reaches A:8080" "yes" "$(connects "$B" "$A_IP" 8080)"

# --- IP pinning ------------------------------------------------------------
section "address pinning under ipv4_filtering"
info "leases: $(incus network list-leases "$NET" --format csv 2>/dev/null | grep -E "$A|$B|$P" | tr '\n' ';')"
incus restart "$A" >/dev/null; for _ in $(seq 1 60); do [[ -n "$(ip_of "$A")" ]] && break; sleep 1; done
check "A keeps its address across a restart" "$A_IP" "$(ip_of "$A")"
listen "$A" 8080; listen "$A" 8081

# --- the proxy's client allowlist ------------------------------------------
section "proxy accepts only its attached clients"
if incus network address-set create "$SET" >/dev/null 2>&1 && incus network address-set add "$SET" "$A_IP" >/dev/null 2>&1; then
  pass "address set created with A's address"
else
  fail "address set create/add (see: incus network address-set --help)"
fi
incus network acl create "$ACL_P" >/dev/null
incus network acl rule add "$ACL_P" ingress action=allow protocol=tcp destination_port=443 "source=\$$SET" >/dev/null \
  || fail "ACL rule with source=\$$SET"
# Pin the address and attach the ACL in one override, then check the profile's
# security keys came along: the override copies the device.
incus stop "$P" >/dev/null
incus config device override "$P" eth0 ipv4.address="$P_IP" security.acls="$ACL_P" \
  security.acls.default.ingress.action=drop security.acls.default.egress.action=allow >/dev/null \
  || fail "device override with ACL and pinned address"
incus start "$P" >/dev/null; sleep 3
check "the override keeps ipv4_filtering" "true" "$(incus config device get "$P" eth0 security.ipv4_filtering 2>/dev/null)"
check "the override keeps mac_filtering" "true" "$(incus config device get "$P" eth0 security.mac_filtering 2>/dev/null)"
listen "$P" 443; listen "$P" 8443; sleep 1
check "attached client A reaches P:443" "yes" "$(connects "$A" "$P_IP" 443)"
check "unattached B cannot reach P:443" "no" "$(connects "$B" "$P_IP" 443)"
check "A cannot reach P on another port (8443)" "no" "$(connects "$A" "$P_IP" 8443)"
check "the host cannot reach P:443" "no" "$(host_connects "$P_IP" 443)"
check "P still reaches the internet (egress allow)" "yes" \
  "$(incus exec "$P" -- timeout 15 curl -s -o /dev/null https://example.com && echo yes || echo no)"
incus network address-set add "$SET" "$B_IP" >/dev/null 2>&1
check "adding B to the set opens P:443 for B, live" "yes" "$(connects "$B" "$P_IP" 443)"
incus network address-set remove "$SET" "$B_IP" >/dev/null 2>&1
check "removing B from the set closes it again, live" "no" "$(connects "$B" "$P_IP" 443)"

# --- spoofing ----------------------------------------------------------------
section "spoofing"
B_MAC="$(incus config get "$B" volatile.eth0.hwaddr)"; A_MAC="$(incus config get "$A" volatile.eth0.hwaddr)"
incus exec "$B" -- ip addr add "$A_IP/32" dev eth0 2>/dev/null
check "B using A's address cannot reach P:443" "no" "$(connects "$B" "$P_IP" 443 "$A_IP")"
incus exec "$B" -- sh -c "arping -U -c 3 -I eth0 -s $A_IP $A_IP >/dev/null 2>&1 || arping -A -c 3 -I eth0 $A_IP >/dev/null 2>&1"
host_mac="$(ip neigh show "$A_IP" 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="lladdr") print $(i+1)}')"
if [[ "$host_mac" == "$B_MAC" ]]; then fail "gratuitous ARP from B made the host map A's address to B ($B_MAC)"
else pass "gratuitous ARP from B did not take over A's address (host sees: ${host_mac:-no entry}, A is $A_MAC)"; fi
incus exec "$B" -- ip addr del "$A_IP/32" dev eth0 2>/dev/null

# --- rule precedence ---------------------------------------------------------
section "allow vs drop on the same traffic"
incus network acl create "$ACL_PREC" >/dev/null
incus network acl rule add "$ACL_PREC" ingress action=allow protocol=tcp destination_port=8443 "source=$A_IP" >/dev/null
incus network acl rule add "$ACL_PREC" ingress action=drop protocol=tcp destination_port=8443 "source=$GW_CIDR" >/dev/null
incus config device set "$P" eth0 security.acls="$ACL_P,$ACL_PREC" >/dev/null
sleep 1
if [[ "$(connects "$A" "$P_IP" 8443)" == yes ]]; then info "precedence: an allow for A beats a drop for A's subnet"
else info "precedence: a drop for A's subnet beats an allow for A (drop/reject outrank allow)"; fi
incus config device set "$P" eth0 security.acls="$ACL_P" >/dev/null

# --- an agent's own ACL ------------------------------------------------------
section "agent: inbound from the host only, nothing to the host"
if command -v python3 >/dev/null; then
  python3 -m http.server "$HOST_SVC_PORT" --bind "$GW" >/dev/null 2>&1 & HOST_PY_PID=$!
  sleep 1
  check "control: A reaches a host service on $GW before the ACL" "yes" "$(connects "$A" "$GW" "$HOST_SVC_PORT")"
else
  info "python3 not on the host: skipping the host-service checks"
fi
incus network acl create "$ACL_AGENT" >/dev/null
incus network acl rule add "$ACL_AGENT" ingress action=allow "source=$GW" >/dev/null
incus network acl rule add "$ACL_AGENT" egress action=reject "destination=$GW" >/dev/null
incus config device override "$A" eth0 security.acls="$ACL_AGENT" \
  security.acls.default.ingress.action=drop security.acls.default.egress.action=allow >/dev/null \
  || fail "agent ACL override (live)"
sleep 2
check "B cannot reach A:8080" "no" "$(connects "$B" "$A_IP" 8080)"
check "the host reaches A:8080" "yes" "$(host_connects "$A_IP" 8080)"
if [[ -n "$HOST_PY_PID" ]]; then
  t0="$(date +%s%N)"
  check "A cannot reach the host service on $GW" "no" "$(connects "$A" "$GW" "$HOST_SVC_PORT")"
  info "the rejected connection failed after $(( ($(date +%s%N) - t0) / 1000000 )) ms (a reject should fail at once; a drop waits for the 5 s timeout)"
fi
check "A still resolves names through the public resolvers" "yes" \
  "$(incus exec "$A" -- timeout 10 nslookup example.com >/dev/null 2>&1 && echo yes || echo no)"
check "nothing answers DNS on the bridge" "no" \
  "$(incus exec "$A" -- timeout 8 nslookup example.com "$GW" >/dev/null 2>&1 && echo yes || echo no)"
check "A still reaches the internet" "yes" \
  "$(incus exec "$A" -- timeout 15 curl -s -o /dev/null https://example.com && echo yes || echo no)"
check "A, with its own ACL, still reaches P:443" "yes" "$(connects "$A" "$P_IP" 443)"
incus config device add "$A" spikefwd proxy "listen=tcp:127.0.0.1:$HOST_PORT" "connect=tcp:127.0.0.1:8081" >/dev/null \
  || fail "add a proxy device (incs -n style)"
sleep 1
check "incs -n style port forward still works under the ACL" "yes" "$(host_connects 127.0.0.1 "$HOST_PORT")"

# --- IPv6 filtering with IPv6 off ------------------------------------------
section "ipv6_filtering on a bridge with IPv6 off"
if out="$(incus config device set "$B" eth0 security.ipv6_filtering=true 2>&1)" || \
   out="$(incus config device override "$B" eth0 security.ipv6_filtering=true 2>&1)"; then
  info "ipv6_filtering=true accepted"
else
  info "ipv6_filtering=true refused: $out"
fi

# --- surviving an Incus restart ---------------------------------------------
if [[ "$RESTART" == "1" ]]; then
  section "after restarting Incus"
  if sudo systemctl restart incus 2>/dev/null || sudo snap restart incus 2>/dev/null; then
    sleep 10
    listen "$P" 443; listen "$A" 8080; sleep 1
    check "after restart: A reaches P:443" "yes" "$(connects "$A" "$P_IP" 443)"
    check "after restart: B cannot reach P:443" "no" "$(connects "$B" "$P_IP" 443)"
    check "after restart: B cannot reach A:8080" "no" "$(connects "$B" "$A_IP" 8080)"
  else
    fail "could not restart Incus (tried systemctl and snap)"
  fi
fi

echo ""
echo "== done: $PASS passed, $FAIL failed"
