#!/usr/bin/env bash
# Exercise the host spikes' receiver probe and ss parser without an Incus host.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
extract_fn() {
  awk -v name="$1" '$0 ~ "^" name "\\(\\)" {copy=1} copy {print} copy && /} *$/ {exit}' "$2"
}
mkdir "$TMP/bin"
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/incus"
chmod +x "$TMP/bin/incus"
ln -s /bin/true "$TMP/bin/python3"
if PATH="$TMP/bin" /bin/bash "$ROOT/tests/host/egress_spike.sh" >"$TMP/preflight.out" 2>&1; then
  echo 'FAIL missing ss must stop the host spike'; exit 1
fi
grep -q 'ss not found' "$TMP/preflight.out"
echo 'ok missing ss fails before any provisioning'

GW=10.230.0.1
ss() {
  case "$1" in
    -Hlnu) printf '%s\n' "$UDP_LISTENERS" ;;
    -Hlnt) printf '%s\n' "$TCP_LISTENERS" ;;
    *) return 1 ;;
  esac
}
eval "$(extract_fn dns_listeners "$ROOT/tests/host/egress_spike.sh")"
UDP_LISTENERS='UNCONN 0 0 10.230.0.1%incs-spike1:53 0.0.0.0:*'
TCP_LISTENERS='LISTEN 0 32 10.230.0.1:53 0.0.0.0:*'
[[ "$(dns_listeners | wc -l | tr -d ' ')" == 2 ]]
echo 'ok DNS listeners include interface-qualified UDP and plain TCP addresses'
for bind in 0.0.0.0 '*' '[::]'; do
  UDP_LISTENERS="UNCONN 0 0 $bind:53 0.0.0.0:*"
  TCP_LISTENERS=''
  [[ -n "$(dns_listeners)" ]]
done
echo 'ok wildcard listeners are reported'
UDP_LISTENERS='UNCONN 0 0 127.0.0.53%lo:53 0.0.0.0:*'
TCP_LISTENERS='LISTEN 0 32 10.230.0.1:5353 0.0.0.0:*'
[[ -z "$(dns_listeners)" ]]
echo 'ok unrelated resolver addresses and ports are ignored'

P=receiver
A=client
A_IP=10.230.0.10
P_IP=10.230.0.20
PROBE_RESULT=0
PROBE_CAPTURED=1
SENDER_RESULT=1
SENDER_ERROR='socat[42] E connect(5, AF=2 10.230.0.20:443, 16): Connection timed out'
incus() {
  if [[ "$2" == "$A" ]]; then
    [[ "$*" == "exec client -- env LC_ALL=C timeout 7 socat -u /dev/null TCP:$P_IP:443,connect-timeout=5,bind=$A_IP" ]] || return 1
    printf '%s\n' "$*" > "$TMP/sender"
    echo "$SENDER_ERROR" >&2
    return "$SENDER_RESULT"
  fi
  [[ "$*" == "exec receiver -- env LC_ALL=C timeout 8 tcpdump -l -n -i eth0 -c 1 src host $A_IP and dst host $P_IP and tcp dst port 443 and tcp[tcpflags] & tcp-syn != 0" ]] || return 1
  echo 'listening on eth0, link-type EN10MB (Ethernet)' >&2
  sleep 0.1
  if [[ "$PROBE_CAPTURED" == 1 ]]; then
    echo 'IP 10.230.0.10.40000 > 10.230.0.20.443: Flags [S]'
    echo '1 packet captured' >&2
  else
    echo '0 packets captured' >&2
  fi
  return "$PROBE_RESULT"
}
eval "$(extract_fn sees_syn "$ROOT/tests/host/net_spike.sh")"
[[ "$(sees_syn "$A" "$A_IP")" == yes ]]
[[ "$(cat "$TMP/sender")" == "exec client -- env LC_ALL=C timeout 7 socat -u /dev/null TCP:$P_IP:443,connect-timeout=5,bind=$A_IP" ]]
echo 'ok receiver sees a SYN even when the handshake fails'
PROBE_CAPTURED=0
for PROBE_RESULT in 0 124 143; do
  [[ "$(sees_syn "$A" "$A_IP")" == no ]]
done
echo 'ok BusyBox and GNU timeout results report no packet from capture evidence'
SENDER_ERROR='socat[42] E bind(5, AF=2 10.230.0.10:0, 16): Address not available'
[[ "$(sees_syn "$A" "$A_IP")" == error ]]
echo 'ok a failed source bind cannot pass as filtered traffic'
SENDER_ERROR='socat: not found'
[[ "$(sees_syn "$A" "$A_IP")" == error ]]
echo 'ok a sender that cannot run cannot pass as filtered traffic'
SENDER_ERROR='socat[42] E connect(5, AF=2 10.230.0.20:443, 16): Connection timed out'
PROBE_RESULT=1
[[ "$(sees_syn "$A" "$A_IP")" == error ]]
echo 'ok capture failures cannot pass as filtered traffic'
incus() { return 1; }
[[ "$(sees_syn "$A" "$A_IP")" == error ]]
echo 'ok a capture that never becomes ready reports an error'
incus() {
  echo 'listening on eth0, link-type EN10MB (Ethernet)' >&2
  sleep 0.1
}
[[ "$(sees_syn "$A" "$A_IP")" == error ]]
echo 'ok an unexplained empty capture is not accepted as filtered traffic'
