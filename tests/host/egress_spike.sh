#!/usr/bin/env bash
# tests/host/egress_spike.sh
# Spike for the egress allowlist design
# (docs/superpowers/specs/2026-10-27-egress-allowlist-design.md, Build gates).
# It checks two things the design takes on faith, on a real Incus host:
#
#   1. A bridge with its DNS server turned off still hands out addresses, and
#      neither answers nor advertises DNS.
#   2. Whether a connection a container opened while open survives locking
#      the container down, and then a restart. If it survives the restart,
#      incs has to clear the host's connection tracking, or give the
#      container a new IP.
#
#   bash tests/host/egress_spike.sh              # about 2 minutes
#   bash tests/host/egress_spike.sh --restart    # also restarts Incus (sudo) and re-checks DNS
#
# It creates only throwaway objects named incs-spike*, refuses to start if any
# already exist, and deletes them all on exit. It also runs a small Python
# listener on the host for the connection test. Needs python3 on the host.
# conntrack and passwordless sudo are optional, for the last check.
# Prints PASS/FAIL for what the design relies on and INFO for what it needs
# to know. Paste the whole output back.

set -uo pipefail

RESTART=0
[[ "${1:-}" == "--restart" ]] && RESTART=1

NET=incs-spike1                 # a bridge name must be 15 characters or fewer
PROFILE=incs-spike-egress
X=incs-spike-x
ACL_LOCK=incs-spike-lock
IMAGE=images:alpine/3.24
UDP_PORT=47990
TCP_PORT=47991
OLD_SPORT=40000                 # the source port of the flow opened while open
NEW_SPORT=40001                 # a fresh flow, as a control

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
info() { echo "INFO $1"; }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected: $2, got: $3)"; fi; }
section() { echo ""; echo "== $1"; }

TMP=""
HOST_PY_PID=""
cleanup() {
  echo ""; echo "== cleanup"
  [[ -n "$HOST_PY_PID" ]] && kill "$HOST_PY_PID" 2>/dev/null
  incus delete --force "$X" >/dev/null 2>&1
  incus network acl delete "$ACL_LOCK" >/dev/null 2>&1
  incus profile delete "$PROFILE" >/dev/null 2>&1
  incus network delete "$NET" >/dev/null 2>&1
  [[ -n "$TMP" ]] && rm -rf "$TMP"
  echo "removed incs-spike objects"
}

# --- preflight -------------------------------------------------------------
section "preflight"
command -v incus >/dev/null || { echo "incus not found"; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found on the host"; exit 1; }
incus info "$X" >/dev/null 2>&1 && { echo "Instance $X already exists; refusing to run."; exit 1; }
incus network show "$NET" >/dev/null 2>&1 && { echo "Network $NET already exists; refusing to run."; exit 1; }
incus profile show "$PROFILE" >/dev/null 2>&1 && { echo "Profile $PROFILE already exists; refusing to run."; exit 1; }
incus network acl show "$ACL_LOCK" >/dev/null 2>&1 && { echo "ACL $ACL_LOCK already exists; refusing to run."; exit 1; }
trap cleanup EXIT
TMP="$(mktemp -d)"
info "server version: $(incus version 2>/dev/null | awk -F': *' '/^Server version/ {print $2}')"
info "firewall driver: $(incus info 2>/dev/null | awk -F': *' 'tolower($1) ~ /firewall/ {print $2; exit}')"

ip_of() { incus list "^$1\$" -c 4 --format csv | grep -oE '[0-9]+(\.[0-9]+){3}' | head -1; }
wait_ip() { for _ in $(seq 1 60); do [[ -n "$(ip_of "$1")" ]] && return 0; sleep 1; done; return 1; }
# 0 when a TCP connection opens, nonzero when it is dropped or refused.
connects() { incus exec "$X" -- timeout 7 socat -u /dev/null "TCP:$1:$2,connect-timeout=5" >/dev/null 2>&1 && echo yes || echo no; }
dns_listeners() { ss -Hlnu 2>/dev/null | awk -v gw="$GW" '$4 == gw":53"'; ss -Hlnt 2>/dev/null | awk -v gw="$GW" '$4 == gw":53"'; }

# --- 1. a bridge with no DNS -------------------------------------------------
section "bridge with DNS turned off"
if incus network create "$NET" ipv4.address=auto ipv4.nat=true ipv6.address=none "raw.dnsmasq=port=0" >/dev/null 2>"$TMP/err"; then
  pass "create a bridge with raw.dnsmasq=port=0"
else
  fail "create a bridge with raw.dnsmasq=port=0: $(cat "$TMP/err")"; exit 1
fi
GW_CIDR="$(incus network get "$NET" ipv4.address)"; GW="${GW_CIDR%/*}"
info "bridge $NET: $GW_CIDR"
incus profile create "$PROFILE" >/dev/null
incus profile device add "$PROFILE" eth0 nic network="$NET" \
  security.ipv4_filtering=true security.mac_filtering=true >/dev/null || { fail "profile NIC"; exit 1; }
info "launching $X from $IMAGE (the first run downloads the image)"
incus launch "$IMAGE" "$X" -p default -p "$PROFILE" >/dev/null || { fail "launch $X"; exit 1; }
info "waiting up to 60s for a DHCP address"
if wait_ip "$X"; then pass "DHCP still hands out an address ($(ip_of "$X"))"; else fail "DHCP hands out an address"; exit 1; fi
X_IP="$(ip_of "$X")"

resolv="$(incus exec "$X" -- cat /etc/resolv.conf 2>/dev/null)"
info "resolv.conf from DHCP: $(tr '\n' ';' <<< "$resolv")"
if grep -q "nameserver $GW" <<< "$resolv"; then
  fail "DHCP still advertises the bridge ($GW) as a DNS server with port=0 alone"
  info "trying raw.dnsmasq 'port=0' plus 'dhcp-option=option:dns-server'"
  incus network set "$NET" raw.dnsmasq "$(printf 'port=0\ndhcp-option=option:dns-server')" >/dev/null 2>"$TMP/err" \
    || info "setting the extra dhcp-option failed: $(cat "$TMP/err")"
  incus restart "$X" >/dev/null; wait_ip "$X"
  resolv="$(incus exec "$X" -- cat /etc/resolv.conf 2>/dev/null)"
  info "resolv.conf after adding the option: $(tr '\n' ';' <<< "$resolv")"
  if grep -q "nameserver $GW" <<< "$resolv"; then fail "DHCP still advertises $GW with the extra option"
  else pass "with dhcp-option=option:dns-server, DHCP stops advertising $GW"; fi
else
  pass "DHCP doesn't advertise the bridge as a DNS server (port=0 alone)"
fi

check "nothing on the host listens for DNS on $GW" "" "$(dns_listeners)"
check "a DNS query to the bridge gets no answer" "no" \
  "$(incus exec "$X" -- timeout 8 nslookup example.com "$GW" >/dev/null 2>&1 && echo yes || echo no)"

# Tools for the rest. The container has no DNS of its own, so point it at a
# public resolver for the install only; its network is still open here.
incus exec "$X" -- sh -c 'echo "nameserver 1.1.1.1" > /etc/resolv.conf'
info "installing socat in $X"
incus exec "$X" -- apk add --no-cache -q socat >/dev/null 2>&1 || { fail "install socat in $X (needs internet)"; exit 1; }
check "TCP to the bridge's port 53 is refused" "no" "$(connects "$GW" 53)"

old_ip="$X_IP"
incus exec "$X" -- sh -c 'kill -USR1 "$(pidof udhcpc)"' >/dev/null 2>&1
sleep 3
check "a DHCP renewal keeps the address" "$old_ip" "$(ip_of "$X")"

# Changing a DHCP setting restarts dnsmasq; DNS must stay off afterwards.
incus network set "$NET" ipv4.dhcp.expiry 2h >/dev/null
sleep 3
check "after dnsmasq restarts, nothing listens for DNS on $GW" "" "$(dns_listeners)"

if [[ "$RESTART" == "1" ]]; then
  if sudo systemctl restart incus 2>/dev/null || sudo snap restart incus 2>/dev/null; then
    sleep 10
    check "after an Incus restart, nothing listens for DNS on $GW" "" "$(dns_listeners)"
  else
    fail "could not restart Incus (tried systemctl and snap)"
  fi
fi

# --- 2. open connections across a lock and a restart -------------------------
section "connections opened while open, then locked"
HOST_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="src") {print $(i+1); exit}}')"
[[ -n "$HOST_IP" ]] || { fail "find the host's main address"; exit 1; }
info "host listener on $HOST_IP (udp $UDP_PORT, tcp $TCP_PORT)"
cat > "$TMP/listen.py" <<'PY'
import socket, sys, threading, time
host, udp_port, tcp_port, log = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
out = open(log, "a", buffering=1)
def udp():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((host, udp_port))
    while True:
        _, addr = s.recvfrom(2048)
        out.write(f"{time.time():.1f} udp {addr[0]} {addr[1]}\n")
        s.sendto(b"echo\n", addr)  # replies make the flow two-way
def serve(c, addr):
    with c:
        for _ in c.makefile():
            out.write(f"{time.time():.1f} tcp {addr[0]} {addr[1]}\n")
def tcp():
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((host, tcp_port)); s.listen(5)
    while True:
        c, addr = s.accept()
        threading.Thread(target=serve, args=(c, addr), daemon=True).start()
threading.Thread(target=udp, daemon=True).start()
tcp()
PY
python3 -I "$TMP/listen.py" "$HOST_IP" "$UDP_PORT" "$TCP_PORT" "$TMP/seen.log" & HOST_PY_PID=$!
sleep 1
# Lines seen since a time, from the container's address, optionally one port.
seen_since() { awk -v t="$1" -v p="$2" -v ip="$X_IP" -v sp="${3:-}" \
  '$1 >= t && $2 == p && $3 == ip && (sp == "" || $4 == sp)' "$TMP/seen.log" | wc -l | tr -d ' '; }
now() { date +%s; }

# No ':' or ',' in the loop: socat reads those as address separators.
tick='while true; do echo tick; sleep 0.5; done'
incus exec "$X" -- sh -c "setsid socat -u SYSTEM:'$tick' UDP:$HOST_IP:$UDP_PORT,sourceport=$OLD_SPORT </dev/null >/dev/null 2>&1 &"
incus exec "$X" -- sh -c "setsid socat -u SYSTEM:'$tick' TCP:$HOST_IP:$TCP_PORT </dev/null >/dev/null 2>&1 &"
sleep 3
t0="$(now)"; sleep 3
check "control: the open container's UDP flow reaches the host" "yes" "$([[ "$(seen_since "$t0" udp)" -gt 0 ]] && echo yes || echo no)"
check "control: the open container's TCP stream reaches the host" "yes" "$([[ "$(seen_since "$t0" tcp)" -gt 0 ]] && echo yes || echo no)"

# Lock it: outbound default reject with no allow rules, the shape enforce uses
# (enforce would also allow DHCP and the proxy port).
incus network acl create "$ACL_LOCK" >/dev/null
incus config device override "$X" eth0 security.acls="$ACL_LOCK" \
  security.acls.default.egress.action=reject security.acls.default.ingress.action=allow >/dev/null 2>"$TMP/err" \
  || { fail "attach the locking ACL live: $(cat "$TMP/err")"; exit 1; }
sleep 2
t1="$(now)"; sleep 4
udp_after="$(seen_since "$t1" udp)"; tcp_after="$(seen_since "$t1" tcp)"
info "after the lock, still arriving: udp $udp_after packets, tcp $tcp_after lines (Incus accepts established traffic before its rules)"
check "a new TCP connection after the lock is refused" "no" "$(connects "$HOST_IP" "$TCP_PORT")"

section "after a restart, behind the lock"
info "restarting $X behind the lock"
incus restart "$X" >/dev/null; wait_ip "$X"
check "the container keeps its address across the restart" "$X_IP" "$(ip_of "$X")"
send_from() { incus exec "$X" -- sh -c "echo probe | timeout 3 socat -u - UDP:$HOST_IP:$UDP_PORT,sourceport=$1" >/dev/null 2>&1; }
t2="$(now)"
for _ in 1 2 3 4 5; do send_from "$OLD_SPORT"; send_from "$NEW_SPORT"; sleep 0.5; done
sleep 1
old_ok="$([[ "$(seen_since "$t2" udp "$OLD_SPORT")" -gt 0 ]] && echo yes || echo no)"
new_ok="$([[ "$(seen_since "$t2" udp "$NEW_SPORT")" -gt 0 ]] && echo yes || echo no)"
check "control: a fresh UDP flow after the restart is blocked" "no" "$new_ok"
check "the old UDP flow's addresses and ports are blocked after the restart" "no" "$old_ok"
if [[ "$old_ok" == yes ]]; then
  info "RESULT: the host's connection tracking outlives the restart. incs must clear it, or give the container a new IP."
else
  info "RESULT: a restart is enough to end old flows on this host."
fi

if [[ "$old_ok" == yes ]]; then
  if command -v conntrack >/dev/null && sudo -n true 2>/dev/null; then
    sudo conntrack -D -s "$X_IP" >/dev/null 2>&1; sudo conntrack -D -d "$X_IP" >/dev/null 2>&1
    t3="$(now)"
    for _ in 1 2 3; do send_from "$OLD_SPORT"; sleep 0.5; done
    sleep 1
    check "after clearing the container's connection tracking, the old flow is blocked" "0" "$(seen_since "$t3" udp "$OLD_SPORT")"
  else
    info "to check whether clearing works, run as root while the spike is paused: conntrack -D -s $X_IP; conntrack -D -d $X_IP"
  fi
fi

echo ""
echo "== done: $PASS passed, $FAIL failed"
