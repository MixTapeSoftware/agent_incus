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
  "config":{"image.description":"Ubuntu noble amd64"},"profiles":["default","agent-incus"],
  "created_at":"2026-10-12T14:03:12.5-05:00","last_used_at":"2026-10-26T09:12:00Z",
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
  "last_used_at":"0001-01-01T00:00:00Z",
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
  # The last frame still shows both results, not only the latest one.
  frame=${out##*$'\033[H'}
  if [[ "$frame" == *"Stopped beta"* && "$frame" == *"Started gamma"* ]]; then both=yes; else both=no; fi
  assert_eq "earlier results stay visible" "yes" "$both"

  # --once on a terminal prints the table and never opens the live view.
  rm -f "$stub/count"
  out=$(STUB="$stub" PATH="$stub:$PATH" TERM=xterm script -qec "bash '$REPO_ROOT/incs' status --once" /dev/null </dev/null &
    pid=$!
    ( sleep 10; kill "$pid" ) >/dev/null 2>&1 &
    watchdog=$!
    wait "$pid" || true
    kill "$watchdog" 2>/dev/null || true) || true
  if [[ "$out" == *"Agent Incus instances:"* && "$out" != *$'\033[?1049h'* ]]; then once=yes; else once=no; fi
  assert_eq "--once on a terminal prints the table only" "yes" "$once"

  # More instances than terminal rows: every frame fits the screen, the
  # highlighted row is always on it, and space acts on that row.
  big="$stub/big"
  mkdir -p "$big"
  cp "$stub/resources.json" "$big/"
  jq -n '[range(0; 30) as $i | {name: ("instance-" + (if $i < 10 then "0" else "" end) + ($i | tostring)),
    status: "Running", type: "container", expanded_config: {"user.managed-by": "agent-incus"},
    state: {pid: (1000 + $i), cpu: {usage: 1}, memory: {usage: 1048576}, disk: {}, network: {}}}]' > "$big/sample1.json"
  cp "$big/sample1.json" "$big/sample2.json"
  # 90 columns shows the table, 120 the list and details side by side.
  for cols in 90 120; do
    rm -f "$big/count" "$big/calls"
    out=$(
      {
        sleep 1.5
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do printf 'j'; sleep 0.1; done
        sleep 0.5
        printf ' ';      sleep 1.5   # stop instance-15
        printf 'q';      sleep 1
      } | STUB="$big" PATH="$stub:$PATH" TERM=xterm \
        script -qec "stty rows 10 cols $cols; bash '$REPO_ROOT/incs' status" /dev/null
    ) || true
    assert_eq "space acts on the visible selection ($cols cols)" "stop instance-15" "$(cat "$big/calls" 2>/dev/null)"
    # Each frame starts with cursor-home and ends at clear-to-end.
    tallest=0
    bad=0
    rest=${out//$'\r'/}
    rest=${rest#*$'\033[H'}
    while [[ -n "$rest" ]]; do
      f=${rest%%$'\033[H'*}
      f=${f%%$'\033[J'*}
      rows=$(printf '%s\n' "$f" | wc -l)
      if ((rows > tallest)); then tallest=$((rows)); fi
      if [[ "$f" != *$'\033[7m'* ]]; then bad=$((bad + 1)); fi
      if [[ "$rest" == *$'\033[H'* ]]; then rest=${rest#*$'\033[H'}; else rest=""; fi
    done
    if ((tallest >= 1 && tallest <= 10)); then fits=yes; else fits="no ($tallest rows)"; fi
    assert_eq "frames fit a 10-row terminal ($cols cols)" "yes" "$fits"
    assert_eq "every frame shows the highlighted row ($cols cols)" "0" "$bad"
    last=${out##*$'\033[H'}
    if [[ "$last" == *$'\033[7m\033[32m●\033[39m  instance-15'* ]]; then shown=yes; else shown=no; fi
    assert_eq "instance-15 is highlighted on screen ($cols cols)" "yes" "$shown"
  done

  echo "panels:"
  # Runs the live view in a pseudo-terminal of the given size, typing the
  # keys piped in, and prints everything it drew.
  tui() {
    rm -f "$stub/count" "$stub/calls"
    STUB="$stub" PATH="$stub:$PATH" TERM=xterm script -qec "stty $1; bash '$REPO_ROOT/incs' status" /dev/null
  }
  last_frame() { local f=${1##*$'\033[H'}; printf '%s\n' "${f%%$'\033[J'*}"; }
  plain() { sed $'s/\033\\[[0-9;?]*[A-Za-z]//g; s/\r//g'; }

  # Idle samples, so alpha's CPU reads 0.0%.
  cp "$stub/sample1.json" "$stub/sample2.json"
  out=$({ sleep 1.5; printf 'q'; sleep 1; } | tui "rows 20 cols 120") || true
  frame=$(last_frame "$out" | plain)
  if [[ "$frame" == *"│ alpha"* && "$frame" == *"Profiles      default, agent-incus"* ]]; then side=yes; else side=no; fi
  assert_eq "a wide terminal shows the details beside the list" "yes" "$side"
  details=$(sed -n 's/.*│ //p' <<<"$frame" | sed 's/ *$//')
  expected_details=$(cat <<'EOF'
alpha
 Info

State         Running
Type          Container
CPU           0.0%
Memory        412.3MiB / 16.0GiB
Disk          2.1GiB
IPv4          10.0.0.5, 100.64.0.9
Image         Ubuntu noble amd64
Profiles      default, agent-incus
Created       2026-10-12 14:03
Last started  2026-10-26 09:12
EOF
)
  assert_eq "details of the selected instance" "$expected_details" "$(sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' <<<"$details")"
  # The dots are one column but three bytes; count them as one.
  dividers=$(sed 's/●/o/g; s/○/o/g; s/◐/o/g' <<<"$frame" |
    while IFS= read -r line; do
      if [[ "$line" == *"│"* ]]; then prefix=${line%%│*}; echo "${#prefix}"; fi
    done | sort -u | wc -l)
  assert_eq "every row puts the divider in the same column" "1" "$((dividers))"

  # Tab gives the keys to the details: j scrolls them instead of moving the
  # selection, and space still acts on the selected instance.
  out=$(
    {
      sleep 1.5
      printf 'j';  sleep 0.3   # alpha -> gamma
      printf '\t'; sleep 0.3   # keys to the details
      printf 'j';  sleep 0.3   # scrolls, gamma stays selected
      printf ' ';  sleep 1.5   # start gamma
      printf 'q';  sleep 1
    } | tui "rows 20 cols 120"
  ) || true
  assert_eq "with the details focused, space acts on the selection" "start gamma" "$(cat "$stub/calls" 2>/dev/null)"
  frame=$(last_frame "$out")
  if [[ "$frame" == *$'\033[1m○  gamma'* && "$frame" == *$'\033[7m Info \033[27m'* ]]; then focused=yes; else focused=no; fi
  assert_eq "focus shows on the details tab, not the list" "yes" "$focused"

  # Narrow: enter opens the details full screen, j scrolls them, esc goes
  # back to the table.
  out=$(
    {
      sleep 1.5
      printf '\r'; sleep 1.2   # details
      for _ in 1 2 3 4 5 6; do printf 'j'; sleep 0.1; done
      sleep 1.2
      printf '\033'; sleep 2   # back
      printf 'q';  sleep 1
    } | tui "rows 12 cols 80"
  ) || true
  frames=()
  rest=${out#*$'\033[H'}
  while [[ -n "$rest" ]]; do
    f=${rest%%$'\033[H'*}
    frames+=("$(printf '%s' "${f%%$'\033[J'*}" | plain)")
    if [[ "$rest" == *$'\033[H'* ]]; then rest=${rest#*$'\033[H'}; else rest=""; fi
  done
  opened=no
  scrolled=no
  for f in "${frames[@]}"; do
    if [[ "$f" == "alpha"$'\n'* && "$f" == *"State         Running"* && "$f" != *"│"* ]]; then opened=yes; fi
    if [[ "$f" == "alpha"$'\n'* && "$f" == *"Last started  2026-10-26 09:12"* ]]; then scrolled=yes; fi
  done
  assert_eq "enter opens the details full screen" "yes" "$opened"
  assert_eq "j scrolls the details" "yes" "$scrolled"
  if [[ "${frames[${#frames[@]}-1]}" == *"NAME   TYPE"* ]]; then back=yes; else back=no; fi
  assert_eq "esc returns to the table" "yes" "$back"

  # An image description comes from image metadata. A newline in it must not
  # forge a list row, and an escape sequence must not reach the terminal.
  cp "$stub/sample1.json" "$stub/sample1.json.orig"
  jq '(.[] | select(.name == "alpha") | .config["image.description"]) = "Evil\nL\tFORGED ROW\u001b]0;pwned\u0007"' \
    "$stub/sample1.json.orig" > "$stub/sample1.json"
  cp "$stub/sample1.json" "$stub/sample2.json"
  out=$({ sleep 1.5; printf 'q'; sleep 1; } | tui "rows 20 cols 120") || true
  if [[ "$out" != *$'\033]0;'* ]]; then clean=yes; else clean=no; fi
  assert_eq "escape sequences in metadata never reach the terminal" "yes" "$clean"
  frame=$(last_frame "$out" | plain)
  if grep -q '^FORGED ROW' <<<"$frame" || ! grep -q 'Image         Evil L FORGED ROW' <<<"$frame"; then forged=yes; else forged=no; fi
  assert_eq "a newline in metadata stays on the Image row" "no" "$forged"
  mv "$stub/sample1.json.orig" "$stub/sample1.json"
  cp "$stub/sample1.json" "$stub/sample2.json"
else
  echo "  skip (needs util-linux script)"
fi

echo "bare incs:"
out=$(STUB="$stub" PATH="$stub:$PATH" bash "$REPO_ROOT/incs" </dev/null 2>&1) || true
if [[ "$out" == "Usage: incs"* ]]; then help=yes; else help=no; fi
assert_eq "off a terminal it prints help" "yes" "$help"
if script -qec true /dev/null >/dev/null 2>&1; then
  rm -f "$stub/count"
  out=$(
    { sleep 1.5; printf 'q'; sleep 1; } |
      STUB="$stub" PATH="$stub:$PATH" TERM=xterm script -qec "bash '$REPO_ROOT/incs'" /dev/null
  ) || true
  if [[ "$out" == *$'\033[?1049h'* && "$out" == *"Agent Incus instances:"* ]]; then live=yes; else live=no; fi
  assert_eq "on a terminal it opens the live view" "yes" "$live"

  # Without jq the view can't run, so a bare incs prints help instead.
  nojq="$stub/nojq"
  mkdir -p "$nojq"
  for tool in bash sh cat dirname readlink realpath; do ln -sf "$(command -v "$tool")" "$nojq/$tool"; done
  out=$(PATH="$nojq" SHELL="$nojq/sh" TERM=xterm "$(command -v script)" -qec "bash '$REPO_ROOT/incs'" /dev/null </dev/null) || true
  if [[ "$out" == *"Usage: incs"* && "$out" != *$'\033[?1049h'* ]]; then help=yes; else help=no; fi
  assert_eq "on a terminal without jq it prints help" "yes" "$help"
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
