#!/bin/bash
# tests/status_test.sh
# Renders `incs status` against a stubbed incus and checks the table.
# Run: bash tests/status_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS+1))
    echo "  ok  $label"
  else
    FAIL=$((FAIL+1))
    echo "  FAIL $label"
    echo "    expected: $expected"
    echo "    actual:   $actual"
  fi
}

stub="$(mktemp -d)"
trap 'rm -rf "$stub"' EXIT

# Fake incus: the Nth `incus list` call prints $STUB/sampleN.json, or the
# last sample once they run out; `incus query /1.0/resources` prints
# $STUB/resources.json if it exists; start and stop are logged to $STUB/calls.
cat > "$stub/incus" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  query)
    [[ "$2" == /1.0/resources ]] || exit 1
    cat "$STUB/resources.json" 2>/dev/null
    exit ;;
  start|stop)
    sleep 0.3
    echo "$1 $2" >> "$STUB/calls"
    exit ;;
  list) ;;
  *) exit 1 ;;
esac
n=$(( $(cat "$STUB/count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$STUB/count"
f="$STUB/sample$n.json"
[[ -f "$f" ]] || f="$STUB/sample2.json"
cat "$f"
EOF
chmod +x "$stub/incus"

run_status() {
  rm -f "$stub/count"
  STUB="$stub" PATH="$stub:$PATH" bash "$REPO_ROOT/incs" status "$@"
}

# alpha: running, tagged, idle (same CPU time in both samples), extra NICs,
#        filesystem total reported but no root size configured
# beta:  running VM, restarted between samples (new pid, CPU time went up)
# delta: frozen
# gamma: stopped, tagged, disk usage + root size configured
cat > "$stub/sample1.json" <<'EOF'
[
 {"name":"alpha","status":"Running","type":"container",
  "expanded_config":{"user.managed-by":"agent-incus","limits.memory":"4GiB"},
  "state":{"pid":100,"cpu":{"usage":5000000000},"memory":{"usage":432316416},
   "disk":{"root":{"usage":2254857830,"total":107374182400}},
   "network":{"docker0":{"addresses":[{"family":"inet","address":"172.17.0.1","scope":"global"}]},
              "eth0":{"addresses":[{"family":"inet","address":"10.0.0.5","scope":"global"},
                                   {"family":"inet6","address":"fd42::5","scope":"global"}]},
              "lo":{"addresses":[{"family":"inet","address":"127.0.0.1","scope":"local"}]},
              "tailscale0":{"addresses":[{"family":"inet","address":"100.64.0.9","scope":"global"}]}}}},
 {"name":"beta","status":"Running","type":"virtual-machine","expanded_config":{},
  "state":{"pid":200,"cpu":{"usage":9000000000},"memory":{"usage":1073741824},"disk":{},
   "network":{"enp5s0":{"addresses":[{"family":"inet","address":"10.0.0.6","scope":"global"}]}}}},
 {"name":"delta","status":"Frozen","type":"container","expanded_config":{},
  "state":{"pid":300,"cpu":{"usage":7000000000},"memory":{"usage":188743680},"disk":{},
   "network":{"eth0":{"addresses":[{"family":"inet","address":"10.0.0.8","scope":"global"}]}}}},
 {"name":"gamma","status":"Stopped","type":"container","expanded_config":{"user.managed-by":"agent-incus"},
  "expanded_devices":{"root":{"type":"disk","path":"/","pool":"default","size":"20GiB"}},
  "state":{"pid":0,"cpu":{"usage":0},"memory":{"usage":0},
   "disk":{"root":{"usage":3221225472,"total":21474836480}},"network":null}}
]
EOF
# Host: 4 CPUs, 16GiB memory.
echo '{"cpu":{"total":4},"memory":{"used":8589934592,"total":17179869184}}' > "$stub/resources.json"

sed 's/"pid":200,"cpu":{"usage":9000000000}/"pid":201,"cpu":{"usage":9500000000}/' \
  "$stub/sample1.json" > "$stub/sample2.json"

cat > "$stub/expected" <<'EOF'
   NAME   TYPE  CPU   MEMORY              DISK            IPV4

Agent Incus instances:
●  alpha  CT    0.0%  412.3MiB / 16.0GiB  2.1GiB          10.0.0.5, 100.64.0.9
○  gamma  CT    -     -                   3.0GiB / 20GiB  -

Other Incus instances:
●  beta   VM    -     1.0GiB / 16.0GiB    -               10.0.0.6
◐  delta  CT    -     180.0MiB / 16.0GiB  -               10.0.0.8

2 of 4 running, host has 4 CPUs
EOF

echo "status table:"
assert_eq "table matches" "$(cat "$stub/expected")" "$(run_status)"

echo "once flag:"
assert_eq "--once prints the same table" "$(cat "$stub/expected")" "$(run_status --once)"

echo "busy CPU:"
# alpha burns 0.6s of CPU between samples taken ~1s apart. On a 4-CPU host
# that is at most 15% of the host, never the 60% of one core.
sed 's/"usage":5000000000/"usage":5600000000/' "$stub/sample1.json" > "$stub/sample2.json"
cpu=$(run_status | awk '$2 == "alpha" {print $4}')
if [[ "$cpu" =~ ^[1-9][0-9]*\.[0-9]%$ ]] && [[ "${cpu%%.*}" -le 15 ]]; then busy=yes; else busy="no ($cpu)"; fi
assert_eq "alpha shows CPU as a share of the host" "yes" "$busy"

echo "host resources unavailable:"
mv "$stub/resources.json" "$stub/resources.json.off"
out=$(run_status)
assert_eq "alpha CPU is -" "-" "$(awk '$2 == "alpha" {print $4}' <<<"$out")"
assert_eq "alpha memory has no total" "412.3MiB 2.1GiB" "$(awk '$2 == "alpha" {print $5, $6}' <<<"$out")"
assert_eq "footer omits host" "2 of 4 running" "$(tail -n 1 <<<"$out")"
mv "$stub/resources.json.off" "$stub/resources.json"

echo "interactive:"
# Drive the live view through a pseudo-terminal. Display order is alpha,
# gamma (Agent Incus), then beta, delta (other): start gamma, cross into the
# other group, and stop beta. Needs util-linux script(1).
if script -qec true /dev/null >/dev/null 2>&1; then
  rm -f "$stub/count" "$stub/calls"
  out=$(
    {
      sleep 1.5
      printf 'j';      sleep 0.3   # alpha -> gamma
      printf ' ';      sleep 0.3   # start gamma
      printf '\033[B'; sleep 0.3   # gamma -> beta
      printf ' ';      sleep 0.3   # stop beta
      printf 'j';      sleep 0.3   # beta -> delta
      printf '\033[A'; sleep 1.5   # delta -> beta, let the jobs finish
      printf 'q';      sleep 1
    } | STUB="$stub" PATH="$stub:$PATH" TERM=xterm script -qec "bash '$REPO_ROOT/incs' status" /dev/null
  ) || true
  assert_eq "space stops running, starts stopped" "$(printf 'stop beta\nstart gamma')" "$(sort -r "$stub/calls" 2>/dev/null)"
  if [[ "$out" == *$'\033[7m\033[32m●\033[39m  beta'* ]]; then hl=yes; else hl=no; fi
  assert_eq "selected row is highlighted" "yes" "$hl"
  if [[ "$out" == *"Stopped beta"* && "$out" == *"Started gamma"* ]]; then done_msg=yes; else done_msg=no; fi
  assert_eq "finished jobs are reported" "yes" "$done_msg"
  if [[ "$out" == *$'\033[?1049l'* ]]; then restored=yes; else restored=no; fi
  assert_eq "q leaves the alternate screen" "yes" "$restored"
else
  echo "  skip (needs util-linux script)"
fi

echo "CPU missing from first sample:"
cp "$stub/sample1.json" "$stub/sample2.json"
sed -i.bak 's/"cpu":{"usage":5000000000}/"cpu":{}/' "$stub/sample1.json"
cpu=$(run_status | awk '$2 == "alpha" {print $4}') || cpu="(status failed)"
assert_eq "alpha CPU is -" "-" "$cpu"

echo "empty:"
echo '[]' > "$stub/sample1.json"
echo '[]' > "$stub/sample2.json"
assert_eq "no instances" "No instances found" "$(run_status)"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
