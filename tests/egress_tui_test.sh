#!/bin/bash
# tests/egress_tui_test.sh
# The status view's allowlist parts: the lock mark in the list, the egress
# rows in Info, the Network and Rules tabs, the allow, remove and mode keys
# with their confirmations, the start key refusing a container behind the
# boot barrier, and the delete key with its confirmation. Drives the live view in a pseudo-terminal against a
# stubbed incus and a stubbed `bxn egress`.
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
cp "$REPO_ROOT"/bxn "$REPO_ROOT"/boxen.* "$S/repo/"
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
# `bxn egress`, as the TUI calls it: canned records, and the changes asked.
cat > "$S/repo/bxn.egress" <<'EOF'
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
    if [[ -f "$STUB/mismatch" ]]; then
      printf '2026-10-30T10:06:00Z\tgithub.com\t443\tname-mismatch\tTLS name was other.example; closed\t3\n'
    fi
    if [[ -f "$STUB/uploads" ]]; then
      printf '2026-10-30T10:07:00Z\tup.example\t443\tlarge-upload\t312.4M sent in an hour; limit 250M; let through\t3\n'
      printf '2026-10-30T10:08:00Z\tdump.example\t443\tupload-cut\t249.9M sent in an hour; limit 250M; cut\t3\n'
    fi
    if [[ -f "$STUB/private-host" ]]; then
      printf '2026-10-30T10:05:00Z\tinternal.example\t443\tblocked\tresolved to a denied address\t3\n'
    fi
    ;;
  # --applied: what the running proxy enforces; "applied" stands in for a
  # change that didn't apply.
  ls) if [[ "${4:-}" == --applied && -f "$STUB/applied" ]]; then cat "$STUB/applied"; else cat "$STUB/rules"; fi ;;
  *)
    echo "$*" >> "$STUB/egress-calls"
    # A change takes this long, so a test can see the view while it runs.
    sleep "$(cat "$STUB/slow" 2>/dev/null || echo 0)"
    case "$1:$2" in
      allow:--all) printf '%s\tbaseline\n' "$3" >> "$STUB/rules" ;;
      allow:*) printf '%s\t%s\n' "$3" "$2" >> "$STUB/rules" ;;
      rm:*) awk -F'\t' -v h="$3" '$1 != h' "$STUB/rules" > "$STUB/rules.new"; mv "$STUB/rules.new" "$STUB/rules" ;;
    esac
    [[ "$*" == "mode box off" ]] || echo "[+] box: done" ;;
esac
EOF
chmod +x "$S/bin/incus" "$S/repo/bxn.egress"
cat > "$S/instances.json" <<'EOF'
[
 {"name":"box","status":"Running","type":"container",
  "expanded_config":{"user.managed-by":"boxen","user.boxen.egress.container":"boxen-egress",
    "user.boxen.egress":"enforce","user.boxen.egress.port":"10000","user.boxen.egress.active":"enforce:0123456789abcdef",
    "user.boxen.egress.plugin-allow":"*.tailscale.com,tailscale.com"},
  "state":{"pid":100,"cpu":{"usage":5000000000},"memory":{"usage":432316416},"disk":{},"network":{}}},
 {"name":"rbox","status":"Running","type":"container",
  "expanded_config":{"user.managed-by":"boxen","user.boxen.egress.container":"boxen-egress",
    "user.boxen.egress":"report","user.boxen.egress.port":"10001","user.boxen.egress.active":"enforce:0123456789abcdef"},
  "state":{"pid":101,"cpu":{"usage":5000000000},"memory":{"usage":432316416},"disk":{},"network":{}}},
 {"name":"stuck","status":"Stopped","type":"container",
  "expanded_config":{"user.managed-by":"boxen","user.boxen.egress.container":"boxen-egress",
    "user.boxen.egress":"enforce","user.boxen.egress.transition":"enforce:10.201.0.30"},
  "state":{"pid":0,"cpu":{"usage":0},"memory":{"usage":0},"disk":{},"network":null}},
 {"name":"plain","status":"Running","type":"container","expanded_config":{"user.managed-by":"boxen"},
  "state":{"pid":102,"cpu":{"usage":5000000000},"memory":{"usage":432316416},"disk":{},"network":{}}},
 {"name":"boxen-egress","status":"Running","type":"container","expanded_config":{"user.managed-by":"boxen","user.boxen.role":"egress"},
  "state":{"pid":103,"cpu":{"usage":5000000000},"memory":{"usage":432316416},"disk":{},"network":{}}},
 {"name":"other","status":"Running","type":"container","expanded_config":{},
  "state":{"pid":104,"cpu":{"usage":5000000000},"memory":{"usage":432316416},"disk":{},"network":{}}}
]
EOF

# The hosts each container's list has, as `bxn egress ls --tsv` prints them.
# Every run starts from these unless KEEP_RULES is set.
printf 'api.anthropic.com\tbaseline\nown.example\tbox\n' > "$S/rules.default"
tui() {
  rm -f "$S/calls" "$S/egress-calls"
  [[ -n "${KEEP_RULES:-}" ]] || cp "$S/rules.default" "$S/rules"
  STUB="$S" PATH="$S/bin:$PATH" TERM=xterm script -qfec "stty rows 30 cols 140; tty > '$S/tty'; bash '$S/repo/bxn' status" "${TUI_TRANSCRIPT:-/dev/null}"
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
assert_contains "Info shows the proxy" "Proxy         boxen-egress:10000" "$frame"
assert_contains "Info marks Tailscale as not confined" "Tailscale     not confined against a determined agent" "$frame"
assert_contains "the tabs are listed" "Network" "$frame"
out=$(keys j | tui) || true
assert_contains "a mode that isn't applied is called out" "wants report, runs enforce: bxn egress refresh rbox" "$(last_frame "$out" | plain)"

echo "the Network tab"
out=$(keys '\t' l | tui) || true
frame=$(last_frame "$out" | plain)
assert_contains "it lists what was tried" "DECISION      HITS  LAST      HOST" "$frame"
assert_contains "blocked hosts come first, with hits" "blocked          2  10:03:00  docs.rs:443" "$frame"
touch "$S/mismatch"
out=$(keys '\t' l | tui) || true
rm -f "$S/mismatch"
frame=$(last_frame "$out" | plain)
assert_contains "a name mismatch is labelled, in the same columns" "name-mismatch    1  10:06:00  github.com:443" "$frame"
first=$(grep -oE '(name-mismatch|blocked) +[0-9]+  [0-9:]+  [^ ]+' <<<"$frame" | head -1)
assert_eq "and comes before the blocked hosts" "name-mismatch    1  10:06:00  github.com:443" "$first"
touch "$S/uploads"
out=$(keys '\t' l | tui) || true
rm -f "$S/uploads"
frame=$(last_frame "$out" | plain)
assert_contains "a large upload is labelled, in the same columns" "large-upload     1  10:07:00  up.example:443" "$frame"
assert_contains "and one the cap cut" "upload-cut       1  10:08:00  dump.example:443" "$frame"
first=$(grep -oE '(large-upload|upload-cut|blocked) +[0-9]+  [0-9:]+  [^ ]+' <<<"$frame" | head -1)
assert_eq "they come before the blocked hosts" "no" "$([[ "$first" == blocked* ]] && echo yes || echo no)"
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
out=$(keys '\t' l S | tui) || true
assert_eq "S does nothing in the Network tab" "" "$(cat "$S/calls" 2>/dev/null)"

echo "the tabs follow a change as soon as it's made"
echo 1 > "$S/slow"
out=$(keys '\t' l a y x x x | tui) || true
assert_contains "while the allow runs, its row says so" "docs.rs:443  · allowing…" "$(plain <<<"$out")"
frame=$(last_frame "$out" | plain)
assert_contains "once it finishes, the host reads as allowed" "allowed now      2  10:03:00  docs.rs:443" "$frame"
assert_eq "and the marker is gone" "no" "$([[ "$frame" == *"allowing…"* ]] && echo yes || echo no)"
out=$(keys '\t' l l j d y x x x | tui) || true
assert_contains "while a removal runs, its row says so" "own.example" "$(plain <<<"$out" | grep -o 'own.example.*removing…' | head -1)"
assert_eq "once it finishes, the host is gone from Rules" "no" "$([[ "$(last_frame "$out" | plain)" == *"own.example                                  box"* ]] && echo yes || echo no)"
rm -f "$S/slow"
printf 'own.example\tbox\n' > "$S/rules"
out=$(keys '\t' l | KEEP_RULES=1 tui) || true
assert_contains "an allowed host taken off an enforced list reads as blocked" "blocked now      1  10:01:00  api.anthropic.com:443" "$(last_frame "$out" | plain)"
out=$(keys j '\t' l | KEEP_RULES=1 tui) || true
assert_contains "and as unlisted under report" "unlisted now     1  10:01:00  api.anthropic.com:443" "$(last_frame "$out" | plain)"
printf 'api.anthropic.com\tbaseline\n*.rs\tbox\n' > "$S/rules"
out=$(keys '\t' l | KEEP_RULES=1 tui) || true
assert_contains "a wildcard covers a subdomain" "allowed now      2  10:03:00  docs.rs:443" "$(last_frame "$out" | plain)"
printf 'api.anthropic.com\tbaseline\n*.docs.rs\tbox\n' > "$S/rules"
out=$(keys '\t' l | KEEP_RULES=1 tui) || true
assert_contains "but not the name itself" "blocked          2  10:03:00  docs.rs:443" "$(last_frame "$out" | plain)"
touch "$S/private-host"
printf 'internal.example\tbox\n' > "$S/rules"
out=$(keys '\t' l | KEEP_RULES=1 tui) || true
assert_contains "a host blocked for its address stays blocked when listed" "blocked          1  10:05:00  internal.example:443" "$(last_frame "$out" | plain)"
rm -f "$S/private-host"
printf 'api.anthropic.com\tbaseline\ndocs.rs\tbox\n' > "$S/rules"
printf 'api.anthropic.com\tbaseline\n' > "$S/applied"
out=$(keys '\t' l | KEEP_RULES=1 tui) || true
assert_contains "a host listed by a change that didn't apply stays blocked" "blocked          2  10:03:00  docs.rs:443" "$(last_frame "$out" | plain)"
: > "$S/applied"
out=$(keys '\t' l | KEEP_RULES=1 tui) || true
assert_contains "when the running list can't be read, nothing is relabelled" "allowed          1  10:01:00  api.anthropic.com:443" "$(last_frame "$out" | plain)"
rm -f "$S/applied"

echo "long host confirmations"
long_host="docs.rs.$(printf '%063d' 0).$(printf '%063d' 0).attacker.example"
printf '%s\n' "$long_host" > "$S/long-host"
out=$(keys '\t' l a y | tui) || true
assert_contains "a clipped hostname is marked" "...:443" "$(plain <<<"$out")"
assert_contains "an unreadable confirmation directs to the CLI" "Host and scope do not fit; use bxn egress allow." "$(plain <<<"$out")"
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
assert_contains "the resized confirmation directs to the CLI" "Host and scope do not fit; use bxn egress allow." "$(plain <<<"$out")"
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
assert_contains "and says how to finish" "finish it: bxn egress refresh stuck" "$(last_frame "$out" | plain)"
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
assert_eq "y deletes it through bxn rm" "delete --force plain" "$(cat "$S/calls" 2>/dev/null)"
assert_contains "the result is shown" "Deleted plain" "$(last_frame "$out" | plain)"
out=$(keys j j j j D y | tui) || true
assert_eq "the egress container isn't deleted from here" "" "$(cat "$S/calls" 2>/dev/null)"
assert_contains "and says why" "runs other containers' proxies" "$(last_frame "$out" | plain)"
out=$(keys j j j j j D y | tui) || true
assert_eq "an instance bxn didn't make isn't deleted" "" "$(cat "$S/calls" 2>/dev/null)"
assert_contains "and says so" "wasn't made by bxn" "$(last_frame "$out" | plain)"
# The list empties while the question is open: answering mustn't end the view.
cp "$S/instances.json" "$S/instances.saved"
out=$( { sleep 1.5; for k in j j j D; do printf '%s' "$k"; sleep 0.6; done
         echo '[]' > "$S/instances.json"; sleep 1.5; printf y; sleep 1; printf q; sleep 0.4; printf q; sleep 0.5; } | tui ) || true
mv "$S/instances.saved" "$S/instances.json"
assert_eq "an answer after the list empties doesn't crash the view" "no" "$([[ "$out" == *"unbound variable"* ]] && echo yes || echo no)"
assert_eq "and deletes the container it asked about" "delete --force plain" "$(cat "$S/calls" 2>/dev/null)"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
