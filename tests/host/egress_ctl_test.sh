#!/usr/bin/env bash
# tests/host/egress_ctl_test.sh
# Runs egress/incs-egress-ctl for real, with systemd and a smokescreen v0.1.0
# build, the way an egress container does. Run it in a throwaway machine or
# container with systemd and sudo, not on a host you care about:
#
#   bash tests/host/egress_ctl_test.sh /path/to/smokescreen [/path/to/jq]
#   bash tests/host/egress_ctl_test.sh --cleanup
#
# It installs the ctl, the wrapper and the binary at their egress-container
# paths, units named incs-*, and h1-h9.proto.test in /etc/hosts, then removes
# them all. The test clients come from tests/host/proxy_swap. The only
# test-only change to a generation: allow_ranges for 127.0.0.0/8, so the
# proxy can reach a local echo server.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PC="$HERE/proxy_swap/pc.py"
CTL=/usr/local/sbin/incs-egress-ctl

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected: $2, got: $3)"; fi; }
contains() { if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1 (expected to contain: $2, got: $3)"; fi; }
section() { echo ""; echo "== $1"; }

cleanup() {
  pkill -f "proxy_swap/echo.py" 2>/dev/null
  pkill -f "proxy_swap/pc.py" 2>/dev/null
  for a in a b; do sudo "$CTL" remove "$a" >/dev/null 2>&1; done
  sudo systemctl disable --now incs-egress-ack.socket >/dev/null 2>&1
  sudo systemctl disable incs-egress-boot.service >/dev/null 2>&1
  sudo systemctl reset-failed 'incs-*' 2>/dev/null
  sudo rm -f /etc/systemd/system/incs-egress-ack.socket /etc/systemd/system/incs-egress-ack@.service \
    /etc/systemd/system/incs-egress-boot.service /etc/systemd/system/incs-*_*
  sudo systemctl daemon-reload
  sudo rm -rf /etc/incs-egress /usr/local/libexec/incs "$CTL"
  sudo sed -i '/# incs-egress-test$/d' /etc/hosts
  rm -f "$HERE"/proxy_swap/*.status "$HERE"/proxy_swap/*.out
  echo "removed the test install"
}
[[ "${1:-}" == "--cleanup" ]] && { cleanup; exit 0; }
SMOKESCREEN="${1:?usage: egress_ctl_test.sh /path/to/smokescreen [/path/to/jq] | --cleanup}"
JQ="${2:-$(command -v jq || true)}"
[[ -x "$JQ" ]] || { echo "needs jq: pass its path as the second argument"; exit 1; }
trap cleanup EXIT

sudo install -d /usr/local/libexec/incs
sudo install -m755 "$SMOKESCREEN" "$REPO/egress/incs-proxy-run" /usr/local/libexec/incs/
sudo install -m755 "$REPO/egress/incs-egress-ctl" "$CTL"
command -v jq >/dev/null || sudo install -m755 "$JQ" /usr/local/bin/jq
grep -q '# incs-egress-test$' /etc/hosts ||
  echo '127.0.0.1 h1.proto.test h2.proto.test h3.proto.test h4.proto.test h5.proto.test h6.proto.test h7.proto.test h8.proto.test h9.proto.test # incs-egress-test' |
  sudo tee -a /etc/hosts >/dev/null
setsid python3 -I "$HERE/proxy_swap/echo.py" >/dev/null 2>&1 &
sleep 0.5

ctl() { sudo "$CTL" "$@"; }
hosts_upto() { local i; for i in $(seq 1 "$1"); do echo "h$i.proto.test"; done; }
# A new generation for agent a, opened to the local echo server.
newgen() {
  local mode="$1" n; shift
  n="$(printf '%s\n' "$@" | ctl gen a "$mode" "$(printf '%s' "$mode $*" | sha256sum | cut -c1-16)")" || return 1
  echo 'allow_ranges: ["127.0.0.0/8"]' | sudo tee -a "/etc/incs-egress/agents/a/gens/$n/config.yaml" >/dev/null
  echo "$n"
}
once() { python3 -I "$PC" once "$1"; }
cur_gen() { ctl status a | cut -f3; }
active() { ctl status a | cut -f7; }

section "setup"
out="$(ctl setup 1.1.1.1,9.9.9.9 "" 2>&1)"; contains "one resolver only: smokescreen takes one" "bad resolver" "$out"
ctl setup 1.1.1.1 "" && pass "setup" || fail "setup"
ctl add a 4750 && pass "add agent a on 4750" || fail "add agent a"
check "a new agent has no current generation" "none" "$(cur_gen)"
out="$(ctl add a 4751 2>&1)"; contains "an agent's port can't change" "already listens on 4750" "$out"
out="$(echo 'not a host!' | ctl gen a enforce 0123456789abcdef 2>&1)"; contains "a bad hostname is refused" "bad hostname" "$out"
out="$(echo '10.0.0.1' | ctl gen a enforce 0123456789abcdef 2>&1)"; contains "an IP address is refused" "bad hostname" "$out"
out="$(echo 'a.*.example.com' | ctl gen a enforce 0123456789abcdef 2>&1)"; contains "a wildcard in the middle is refused" "bad hostname" "$out"

section "the wrapper refuses an unsafe generation"
g="$(newgen enforce h1.proto.test)"
sudo rm "/etc/incs-egress/agents/a/gens/$g/acl.yaml"
out="$(sudo /usr/local/libexec/incs/incs-proxy-run a "$g" 2>&1)"; rc=$?
check "no allowlist: exit 64" "64" "$rc"; contains "no allowlist: says why" "no allowlist" "$out"
out="$(ctl widen a "$g" 2>&1)"; contains "widen with no allowlist changes nothing" "nothing changed" "$out"
g="$(newgen enforce h1.proto.test)"
sudo sed -i 's/action: enforce/action: open/' "/etc/incs-egress/agents/a/gens/$g/acl.yaml"
out="$(ctl widen a "$g" 2>&1)"; contains "an open policy under enforce is refused" "nothing changed" "$out"
g="$(newgen report h1.proto.test)"
sudo sed -i 's/^report$/enforce/' "/etc/incs-egress/agents/a/gens/$g/mode"
out="$(ctl widen a "$g" 2>&1)"; contains "the wrong default for the mode is refused" "nothing changed" "$out"
check "after the failures, still no current generation" "none" "$(cur_gen)"

section "enforce"
g1="$(newgen enforce h1.proto.test)"
ctl widen a "$g1" && pass "the first generation starts" || fail "the first generation starts"
check "it's current" "$g1" "$(cur_gen)"
check "an allowed host connects" "ok" "$(once h1.proto.test)"
check "a host off the list is denied" "denied407" "$(once h2.proto.test)"
out="$(ctl widen a "$g1" 2>&1)"; contains "widening to the running generation is refused" "already running" "$out"
out="$(ctl tighten a "$g1" 2>&1)"; contains "so is tightening to it" "already running" "$out"
check "and it keeps serving" "ok" "$(once h1.proto.test)"

section "widening keeps open streams"
cd "$HERE/proxy_swap"
rm -f s*.status hammer.out
python3 -I "$PC" stream h1.proto.test 60 s1.status &
python3 -I "$PC" hammer h1.proto.test 14 > hammer.out & H=$!
sleep 2
for n in 2 3 4; do
  g="$(newgen enforce $(hosts_upto "$n"))"
  ctl widen a "$g" || fail "widen to h1-h$n"
  [[ $n -lt 4 ]] && { python3 -I "$PC" stream "h$n.proto.test" 60 "s$n.status" & }
  sleep 3
done
check "h4 is allowed now" "ok" "$(once h4.proto.test)"
check "hosts lists the current generation's hosts" "$(hosts_upto 4 | tr '\n' ' ')" "$(ctl hosts a | tr '\n' ' ')"
check "h5 still isn't" "denied407" "$(once h5.proto.test)"
for i in 1 2 3; do contains "the stream opened through h$i is still open" "alive" "$(cat s$i.status)"; done
wait $H
hammer="$(cat hammer.out)"; echo "INFO new connections during the widenings: $hammer"
contains "no new connection failed during the widenings" "ok=" "$hammer"
[[ "$hammer" != *refused* && "$hammer" != *error* && "$hammer" != *denied* ]] && pass "none refused or broken" || fail "none refused or broken ($hammer)"
echo "INFO status: $(ctl status a)"

section "logs"
jcur="$(sudo journalctl -n 0 --show-cursor -o cat --no-pager | sed -n 's/^-- cursor: //p')"
curl -s -o /dev/null --max-time 5 -x http://127.0.0.1:4750 -H "X-Incs-Sentinel: hdr-SENTINEL-7f3a" \
  "http://h1.proto.test:4760/path-SENTINEL-7f3a?token=SENTINEL-7f3a"
curl -s -o /dev/null --max-time 5 -x http://127.0.0.1:4750 -H "Authorization: Bearer SENTINEL-7f3a" \
  "http://h9.proto.test:4760/denied-SENTINEL-7f3a"
printf 'GET /malformed-SENTINEL-7f3a HTTP/1.1\r\nHost: SENTINEL-7f3a\r\n\r\n' | timeout 3 nc -q1 127.0.0.1 4750 >/dev/null 2>&1 ||
  printf 'GET /malformed-SENTINEL-7f3a HTTP/1.1\r\nHost: SENTINEL-7f3a\r\n\r\n' | timeout 3 bash -c 'cat > /dev/tcp/127.0.0.1/4750' 2>/dev/null
sleep 1
log="$(ctl log a)"
contains "the log has the denied host" $'h2.proto.test\t4760\tblocked' "$log"
contains "the log has an allowed host" $'h1.proto.test\t4760\tallowed' "$log"
[[ "$log" != *incs-probe.invalid* ]] && pass "probe records are left out of the log" || fail "probe records are left out of the log"
check "nothing from a URL or header reaches the raw journal" "0" \
  "$(sudo journalctl --after-cursor="$jcur" -o json --no-pager | grep -c 'SENTINEL-7f3a')"
check "the filter keeps the decision records" "1" \
  "$(sudo journalctl -u 'incs-gen_a@*' --after-cursor="$jcur" -o cat --no-pager | grep CANONICAL-PROXY-DECISION | grep -c '"requested_host":"h1.proto.test:4760"')"

section "tightening ends open connections"
python3 -I "$PC" hammer h1.proto.test 6 > hammer2.out & H=$!
sleep 1
g="$(newgen enforce h1.proto.test)"
ctl tighten a "$g" && pass "tighten" || fail "tighten"
sleep 1
for i in 1 2 3; do contains "the stream through h$i ended" "broken" "$(cat s$i.status)"; done
check "h4 is denied again" "denied407" "$(once h4.proto.test)"
check "only the new generation runs" "$g" "$(active)"
wait $H; echo "INFO new connections during the tighten: $(cat hammer2.out)"

section "at most six draining generations"
SPIDS=()
for n in 1 2 3 4 5 6; do
  python3 -I "$PC" stream h1.proto.test 120 "d$n.status" & SPIDS+=($!)
  sleep 0.5
  g="$(newgen enforce h1.proto.test "h$((n + 1)).proto.test")"
  ctl widen a "$g" >/dev/null || fail "widen $n"
done
sleep 0.5
g7="$(newgen enforce h1.proto.test h9.proto.test)"
out="$(ctl widen a "$g7" 2>&1)"; rc=$?
check "a seventh draining generation is refused" "1" "$rc"; contains "it says why" "still draining" "$out"
check "h9 isn't allowed after the refusal" "denied407" "$(once h9.proto.test)"
ctl widen a "$g7" --force >/dev/null && pass "--force makes room" || fail "--force makes room"
check "h9 is allowed after --force" "ok" "$(once h9.proto.test)"
contains "--force ended the oldest draining generation's stream" "broken" "$(cat d1.status)"
contains "the other draining streams stay open" "alive" "$(cat d2.status)"
kill "${SPIDS[@]}" 2>/dev/null

section "stop, boot and remove"
ctl stop a && pass "stop" || fail "stop"
check "stop leaves no current generation" "none" "$(cur_gen)"
check "stop leaves no generation running" "" "$(active)"
r="$(PROXY_PORT=4750 timeout 8 python3 -I "$PC" once h1.proto.test)"
[[ "$r" != ok ]] && pass "nothing serves after stop ($r)" || fail "nothing serves after stop"
g="$(newgen enforce h1.proto.test)"; ctl widen a "$g" >/dev/null
sudo systemctl stop "incs-gen_a@$g.service"
ctl boot
check "boot starts the current generation" "$g" "$(active)"
check "and it serves" "ok" "$(once h1.proto.test)"
ctl add b 4752 >/dev/null
ctl boot
check "boot starts nothing for an agent with no current generation" "none" "$(ctl status b | cut -f3)"
ctl remove a && pass "remove" || fail "remove"
check "remove deletes the agent's units" "0" "$(ls /etc/systemd/system | grep -c '_a[.@]')"
check "remove closes its port" "no" "$( (exec 3<>/dev/tcp/127.0.0.1/4750) 2>/dev/null && echo yes || echo no)"

echo ""
echo "== done: $PASS passed, $FAIL failed"
