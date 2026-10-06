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

# Fake incus: the Nth `incus list` call prints $STUB/sampleN.json.
cat > "$stub/incus" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == list ]] || exit 1
n=$(( $(cat "$STUB/count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$STUB/count"
cat "$STUB/sample$n.json"
EOF
chmod +x "$stub/incus"

run_status() {
  rm -f "$stub/count"
  STUB="$stub" PATH="$stub:$PATH" bash "$REPO_ROOT/incs" status
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
sed 's/"pid":200,"cpu":{"usage":9000000000}/"pid":201,"cpu":{"usage":9500000000}/' \
  "$stub/sample1.json" > "$stub/sample2.json"

cat > "$stub/expected" <<'EOF'
   NAME   TYPE  AGENT  CPU   MEMORY           DISK            IPV4
●  alpha  CT    yes    0.0%  412.3MiB / 4GiB  2.1GiB          10.0.0.5, 100.64.0.9
●  beta   VM    -      -     1.0GiB           -               10.0.0.6
◐  delta  CT    -      -     180.0MiB         -               10.0.0.8
○  gamma  CT    yes    -     -                3.0GiB / 20GiB  -

2 of 4 running
EOF

echo "status table:"
assert_eq "table matches" "$(cat "$stub/expected")" "$(run_status)"

echo "busy CPU:"
# alpha burns 0.6s of CPU between samples taken ~1s apart.
sed 's/"usage":5000000000/"usage":5600000000/' "$stub/sample1.json" > "$stub/sample2.json"
cpu=$(run_status | awk '$2 == "alpha" {print $5}')
if [[ "$cpu" =~ ^[1-9][0-9]*\.[0-9]%$ ]]; then busy=yes; else busy="no ($cpu)"; fi
assert_eq "alpha shows non-zero CPU %" "yes" "$busy"

echo "CPU missing from first sample:"
cp "$stub/sample1.json" "$stub/sample2.json"
sed -i.bak 's/"cpu":{"usage":5000000000}/"cpu":{}/' "$stub/sample1.json"
cpu=$(run_status | awk '$2 == "alpha" {print $5}') || cpu="(status failed)"
assert_eq "alpha CPU is -" "-" "$cpu"

echo "empty:"
echo '[]' > "$stub/sample1.json"
echo '[]' > "$stub/sample2.json"
assert_eq "no instances" "No instances found" "$(run_status)"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
