#!/usr/bin/env bash
# Exercise the host spikes' receiver probe and ss parser without an Incus host.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
extract_fn() {
  awk -v name="$1" '$0 ~ "^" name "\\(\\)" {copy=1} copy {print} copy && /} *$/ {exit}' "$2"
}
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
incus() {
  [[ "$*" == "exec receiver -- timeout 8 tcpdump -l -n -i eth0 -c 1 src host $A_IP and dst host $P_IP and tcp dst port 443 and tcp[tcpflags] & tcp-syn != 0" ]]
  echo 'listening on eth0, link-type EN10MB (Ethernet)' >&2
  sleep 0.1
  return "$PROBE_RESULT"
}
connects() {
  # Even an unfiltered spoofed SYN can fail to complete a handshake.
  printf '%s\n' "$*" > "$TMP/sender"
  echo no
}
eval "$(extract_fn sees_syn "$ROOT/tests/host/net_spike.sh")"
[[ "$(sees_syn "$A" "$A_IP")" == yes ]]
[[ "$(cat "$TMP/sender")" == "$A $P_IP 443 $A_IP" ]]
echo 'ok receiver sees a SYN even when the handshake fails'
PROBE_RESULT=124
[[ "$(sees_syn "$A" "$A_IP")" == no ]]
echo 'ok a ready capture timing out reports no packet'
PROBE_RESULT=1
[[ "$(sees_syn "$A" "$A_IP")" == error ]]
echo 'ok capture failures cannot pass as filtered traffic'
incus() { return 1; }
[[ "$(sees_syn "$A" "$A_IP")" == error ]]
echo 'ok a capture that never becomes ready reports an error'
