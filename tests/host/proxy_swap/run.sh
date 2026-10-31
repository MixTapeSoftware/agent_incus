#!/bin/bash
# tests/host/proxy_swap/run.sh
# Prototype of the egress design's generation swap (spec item 8, Build gates):
# one agent's smokescreen generations share a listening socket that systemd
# holds, handed over through smokescreen's einhorn support, so a swap never
# refuses a new connection.
#
#   sudo needed; run in a throwaway container with systemd, not on a host.
#   bash tests/host/proxy_swap/run.sh /path/to/smokescreen   # v0.1.0 build
#   bash tests/host/proxy_swap/run.sh --cleanup
#
# Installs units named incs-proto-*, files under /etc/incs-proto and
# /usr/local/libexec/incs-proto, and h1-h9.proto.test in /etc/hosts. Runs
# the five cases, then removes everything.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

cleanup() {
  pkill -f "echo.py" 2>/dev/null
  pkill -f "pc.py" 2>/dev/null
  sudo systemctl stop 'incs-proto-a@*.service' 'incs-proto-a-check@*.service' incs-proto-a-hold.service \
    incs-proto-a.socket incs-proto-ack.socket 2>/dev/null
  sudo systemctl reset-failed 'incs-proto*' 2>/dev/null
  sudo rm -f /etc/systemd/system/incs-proto-*
  sudo systemctl daemon-reload
  sudo rm -rf /etc/incs-proto /usr/local/libexec/incs-proto
  sudo sed -i '/# incs-proto$/d' /etc/hosts
  rm -f "$HERE"/*.status "$HERE"/*.out
  echo "removed the prototype"
}
[[ "${1:-}" == "--cleanup" ]] && { cleanup; exit 0; }
SMOKESCREEN="${1:?usage: run.sh /path/to/smokescreen | --cleanup}"
trap cleanup EXIT

sudo install -d /usr/local/libexec/incs-proto /etc/incs-proto/a
sudo install -m755 "$SMOKESCREEN" "$HERE/incs-proxy-run" /usr/local/libexec/incs-proto/
sudo install -m644 "$HERE"/units/* /etc/systemd/system/
grep -q '# incs-proto$' /etc/hosts || echo '127.0.0.1 h1.proto.test h2.proto.test h3.proto.test h4.proto.test h5.proto.test h6.proto.test h7.proto.test h8.proto.test h9.proto.test # incs-proto' | sudo tee -a /etc/hosts >/dev/null
sudo systemctl daemon-reload
sudo systemctl start incs-proto-ack.socket incs-proto-a.socket incs-proto-a-hold.service
setsid python3 -I "$HERE/echo.py" >/dev/null 2>&1 &
sleep 0.5

"$HERE/proto-ctl" gen 1 enforce h1.proto.test && "$HERE/proto-ctl" widen 1
for t in t1 t2 t3 t4 t5; do echo ""; echo "== $t"; "$HERE/$t.sh" 2>&1 | grep -v 'triggering units\|^incs-proto-a.socket$'; done
