#!/bin/bash
# tests/egress_tui_test.sh
# The status view's allowlist parts: the lock mark in the list, the egress
# rows in Info, the Network and Rules tabs, the allow, remove and mode keys
# with their confirmations, the start key refusing a container behind the
# boot barrier, and the delete key with its confirmation. Drives the live view in a pseudo-terminal against a
# stubbed incus and a stubbed `incs egress`.
# Run: bash tests/egress_tui_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

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

command -v jq >/dev/null || { echo "needs jq"; exit 1; }
script -qec true /dev/null >/dev/null 2>&1 || { echo "  skip (needs util-linux script)"; exit 0; }

S="$(mktemp -d)"
trap 'rm -rf "$S"' EXIT
mkdir -p "$S/bin" "$S/repo"
cp "$REPO_ROOT"/incs "$REPO_ROOT"/incus.* "$S/repo/"
cat > "$S/bin/incus" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  query) echo '{"cpu":{"total":4},"memory":{"total":17179869184}}' ;;
  list) cat "$STUB/instances.json" ;;
  start|stop) echo "$1 $2" >> "$STUB/calls" ;;
  delete) echo "$*" >> "$STUB/calls" ;;
  *) exit 1 ;;
esac
EOF
# `incs egress`, as the TUI calls it: canned records, and the changes asked.
cat > "$S/repo/incs.egress" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  log)
    printf 'TIME\tHOST\tPORT\tDECISION\tREASON\tGEN\n'
    if [[ -f "$STUB/long-host" ]]; then
      printf '2026-10-30T10:01:00Z\t%s\t443\tblocked\tdefault rule policy used\t3\n' "$(cat "$STUB/long-host")"
      exit
    fi
    printf '2026-10-30T10:01:00Z\tapi.anthropic.com\t443\tallowed\tmatched\t3\n'
    printf '2026-10-30T10:02:00Z\tdocs.rs\t443\tblocked\tdefault rule policy used\t3\n'
    printf '2026-10-30T10:03:00Z\tdocs.rs\t443\tblocked\tdefault rule policy used\t3\n'
    printf '2026-10-30T10:04:00Z\tevil\033]0;pwned\007.example\t443\tblocked\tdefault rule policy used\t3\n'
    ;;
  ls) printf 'api.anthropic.com\tbaseline\nown.example\tbox\n' ;;
  *) echo "$*" >> "$STUB/egress-calls"; [[ "$*" == "mode box off" ]] || echo "[+] box: done" ;;
esac
EOF
chmod +x "$S/bin/incus" "$S/repo/incs.egress"
cat > "$S/instances.json" <<'EOF'
[
 {"name":"box","status":"Running","type":"container",
  "expanded_config":{"user.managed-by":"agent-incus","user.incs.egress.container":"incs-egress",
    "user.incs.egress":"enforce","user.incs.egress.port":"10000","user.incs.egress.active":"enforce:0123456789abcdef",
    "user.incs.egress.plugin-allow":"*.tailscale.com,tailscale.com"},
  "state":{"pid":100,"cpu":{"usage":5000000000},"memory":{"usage":432316416},"disk":{},"network":{}}},
 {"name":"rbox","status":"Running","type":"container",
  "expanded_config":{"user.managed-by":"agent-incus","user.incs.egress.container":"incs-egress",
    "user.incs.egress":"report","user.incs.egress.port":"10001","user.incs.egress.active":"enforce:0123456789abcdef"},
  "state":{"pid":101,"cpu":{"usage":5000000000},"memory":{"usage":432316416},"disk":{},"network":{}}},
 {"name":"stuck","status":"Stopped","type":"container",
  "expanded_config":{"user.managed-by":"agent-incus","user.incs.egress.container":"incs-egress",
    "user.incs.egress":"enforce","user.incs.egress.transition":"enforce:10.201.0.30"},
  "state":{"pid":0,"cpu":{"usage":0},"memory":{"usage":0},"disk":{},"network":null}},
 {"name":"plain","status":"Running","type":"container","expanded_config":{"user.managed-by":"agent-incus"},
  "state":{"pid":102,"cpu":{"usage":5000000000},"memory":{"usage":432316416},"disk":{},"network":{}}},
 {"name":"incs-egress","status":"Running","type":"container","expanded_config":{"user.managed-by":"agent-incus","user.incs.role":"egress"},
  "state":{"pid":103,"cpu":{"usage":5000000000},"memory":{"usage":432316416},"disk":{},"network":{}}},
 {"name":"other","status":"Running","type":"container","expanded_config":{},
  "state":{"pid":104,"cpu":{"usage":5000000000},"memory":{"usage":432316416},"disk":{},"network":{}}}
]
EOF

tui() {
  rm -f "$S/calls" "$S/egress-calls"
  STUB="$S" PATH="$S/bin:$PATH" TERM=xterm script -qfec "stty rows 30 cols 140; tty > '$S/tty'; bash '$S/repo/incs' status" "${TUI_TRANSCRIPT:-/dev/null}"
}
last_frame() { local f=${1##*$'\033[H'}; printf '%s\n' "${f%%$'\033[J'*}"; }
plain() { sed $'s/\033\\[[0-9;?]*[A-Za-z]//g; s/\r//g'; }
# Keys typed after the first frame, a pause after each. A q while a question
# is open answers it, so a second q quits.
keys() { sleep 1.5; for k in "$@"; do printf '%b' "$k"; sleep 0.6; done; sleep 1; printf 'q'; sleep 0.4; printf 'q'; sleep 0.5; }

echo "the list and Info"
out=$(keys | tui) || true
frame=$(last_frame "$out" | plain)
assert_contains "an enforced container shows a lock" "box 🔒" "$frame"
assert_contains "a reporting one shows an open lock" "rbox 🔓" "$frame"
cols=$(sed 's/🔒/XX/g; s/🔓/XX/g; s/●/o/g; s/○/o/g' <<<"$frame" |
  while IFS= read -r line; do if [[ "$line" == *"│"* ]]; then p=${line%%│*}; echo "${#p}"; fi; done | sort -u | wc -l)
assert_eq "the marks keep the divider in one column" "1" "$((cols))"
assert_contains "Info shows the mode" "Egress        enforce: only listed hosts" "$frame"
assert_contains "Info shows the proxy" "Proxy         incs-egress:10000" "$frame"
assert_contains "Info marks Tailscale as not confined" "Tailscale     not confined against a determined agent" "$frame"
assert_contains "the tabs are listed" "Network" "$frame"
out=$(keys j | tui) || true
assert_contains "a mode that isn't applied is called out" "wants report, runs enforce: incs egress refresh rbox" "$(last_frame "$out" | plain)"

echo "the Network tab"
out=$(keys '\t' l | tui) || true
frame=$(last_frame "$out" | plain)
assert_contains "it lists what was tried" "DECISION      HITS  LAST      HOST" "$frame"
assert_contains "blocked hosts come first, with hits" "blocked          2  10:03:00  docs.rs:443" "$frame"
[[ "$out" != *$'\033]0;'* ]] && pass=yes || pass=no
assert_eq "a hostile hostname can't reach the terminal as an escape" "yes" "$pass"
out=$(keys '\t' l a | tui) || true
assert_contains "a asks about the exact host and container" "Allow docs.rs for box? y/n" "$(plain <<<"$out")"
out=$(keys '\t' l a n | tui) || true
assert_eq "n changes nothing" "" "$(cat "$S/egress-calls" 2>/dev/null)"
out=$(keys '\t' l a y | tui) || true
assert_eq "y allows it for the container" "allow box docs.rs" "$(cat "$S/egress-calls" 2>/dev/null)"
assert_contains "the result is shown" "box: done" "$(last_frame "$out" | plain)"
out=$(keys '\t' l A | tui) || true
assert_contains "A asks about every container" "Allow docs.rs for every container? y/n" "$(plain <<<"$out")"
out=$(keys '\t' l A y | tui) || true
assert_eq "y allows it everywhere" "allow --all docs.rs --yes" "$(cat "$S/egress-calls" 2>/dev/null)"

echo "long host confirmations"
long_host="docs.rs.$(printf '%063d' 0).$(printf '%063d' 0).attacker.example"
printf '%s\n' "$long_host" > "$S/long-host"
out=$(keys '\t' l a y | tui) || true
assert_contains "a clipped hostname is marked" "...:443" "$(plain <<<"$out")"
assert_contains "an unreadable confirmation directs to the CLI" "Host and scope do not fit; use incs egress allow." "$(plain <<<"$out")"
assert_eq "y cannot allow a host whose confirmation is clipped" "" "$(cat "$S/egress-calls" 2>/dev/null)"
out=$(keys '\t' l A y | tui) || true
assert_eq "y cannot allow a clipped host everywhere" "" "$(cat "$S/egress-calls" 2>/dev/null)"

# Wait for an initially readable confirmation, then shrink the terminal
# while read is waiting for the answer. No redraw may be needed before y.
long_host="docs.rs.$(printf '%063d' 0).attacker.example"
printf '%s\n' "$long_host" > "$S/long-host"
export TUI_TRANSCRIPT="$S/resize-transcript"
resize_keys() {
  sleep 1.5; printf '\t'; sleep 0.6; printf l; sleep 0.6; printf a
  local tries
  for ((tries = 0; tries < 200; tries++)); do
    if grep -Fq "Allow $long_host for box? y/n" "$TUI_TRANSCRIPT" 2>/dev/null; then
      stty cols 80 < "$(cat "$S/tty")"
      touch "$S/resized"
      printf y
      break
    fi
    sleep 0.02
  done
  sleep 1; printf q; sleep 0.4; printf q; sleep 0.5
}
out=$(resize_keys | tui) || true
unset TUI_TRANSCRIPT
[[ -f "$S/resized" ]] && resized=yes || resized=no
assert_eq "the terminal shrinks while confirmation is waiting" yes "$resized"
assert_eq "y after a resize cannot approve a now-clipped host" "" "$(cat "$S/egress-calls" 2>/dev/null)"
assert_contains "the resized confirmation directs to the CLI" "Host and scope do not fit; use incs egress allow." "$(plain <<<"$out")"
rm "$S/long-host"

echo "the Rules tab"
out=$(keys '\t' l l | tui) || true
frame=$(last_frame "$out" | plain)
assert_contains "it lists hosts and where they come from" "own.example" "$frame"
out=$(keys '\t' l l d | tui) || true
assert_contains "a baseline host can't be removed here" "isn't on box's own list; it comes from baseline" "$(last_frame "$out" | plain)"
out=$(keys '\t' l l j d y | tui) || true
assert_eq "the container's own host is removed after a yes" "rm box own.example" "$(cat "$S/egress-calls" 2>/dev/null)"

echo "mode and start"
out=$(keys '\t' m | tui) || true
assert_contains "m offers the modes" "Mode for box: e enforce · r report · o off" "$(plain <<<"$out")"
out=$(keys '\t' m r | tui) || true
assert_eq "r sets report" "mode box report" "$(cat "$S/egress-calls" 2>/dev/null)"
out=$(keys '\t' m o '' l | tui) || true
assert_eq "a job that prints nothing runs" "mode box off" "$(cat "$S/egress-calls" 2>/dev/null)"
assert_contains "and the view still answers keys after it" "DECISION" "$(last_frame "$out" | plain)"
out=$(keys j j ' ' | tui) || true
assert_eq "space won't start a container behind the barrier" "" "$(cat "$S/calls" 2>/dev/null)"
assert_contains "and says how to finish" "finish it: incs egress refresh stuck" "$(last_frame "$out" | plain)"
out=$(keys j j j '\t' l | tui) || true
assert_eq "a container with no allowlist has only Info" "" "$(last_frame "$out" | plain | grep -o 'DECISION' || true)"

echo "delete"
out=$(keys | tui) || true
assert_contains "the key help offers delete" "D delete" "$(last_frame "$out" | plain)"
out=$(keys j j j D | tui) || true
assert_contains "D asks first, naming the container" "Delete plain and everything in it? This can't be undone. y/n" "$(plain <<<"$out")"
out=$(keys j j j D n | tui) || true
assert_eq "n deletes nothing" "" "$(cat "$S/calls" 2>/dev/null)"
assert_contains "and says so" "Nothing changed" "$(last_frame "$out" | plain)"
out=$(keys j j j d | tui) || true
assert_eq "a lowercase d in the list deletes nothing" "" "$(cat "$S/calls" 2>/dev/null)"
out=$(keys j j j D y | tui) || true
assert_eq "y deletes it through incs delete" "delete --force plain" "$(cat "$S/calls" 2>/dev/null)"
assert_contains "the result is shown" "Deleted plain" "$(last_frame "$out" | plain)"
out=$(keys j j j j D y | tui) || true
assert_eq "the egress container isn't deleted from here" "" "$(cat "$S/calls" 2>/dev/null)"
assert_contains "and says why" "runs other containers' proxies" "$(last_frame "$out" | plain)"
out=$(keys j j j j j D y | tui) || true
assert_eq "an instance incs didn't make isn't deleted" "" "$(cat "$S/calls" 2>/dev/null)"
assert_contains "and says so" "wasn't made by incs" "$(last_frame "$out" | plain)"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
