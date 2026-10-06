#!/bin/bash
# tests/template_scrub_test.sh
# A template must not carry the Tailscale node identity of the container it
# was built from. These tests run the real stash/restore functions from
# incus.init against the fake `incus`, around a real `publish`.
# Run: bash tests/template_scrub_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
exec </dev/null

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
assert_not_contains() {
  if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); echo "  ok  $1"
  else FAIL=$((FAIL+1)); echo "  FAIL $1"; echo "    expected NOT to contain: $2"; fi
}

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin" "$SANDBOX/run"
cp "$SCRIPT_DIR/lib/fake_incus" "$SANDBOX/bin/incus"
chmod +x "$SANDBOX/bin/incus"
export PATH="$SANDBOX/bin:$PATH"
# Where the backup lands.
export XDG_RUNTIME_DIR="$SANDBOX/run"

extract_fn() {
  awk -v name="$1" '$0 ~ "^" name "\\(\\)" {c=1} c {print} c && /^}/ {exit}' "$REPO_ROOT/incus.init"
}
log()  { echo "[+] $1"; }
warn() { echo "[!] $1"; }
error() { echo "[ERROR] $1" >&2; exit 1; }
READY_TIMEOUT=2
eval "$(extract_fn stash_tailscale_state)"
eval "$(extract_fn restore_tailscale_state)"
declare -F stash_tailscale_state restore_tailscale_state >/dev/null || { echo "functions not found in incus.init"; exit 1; }

CONTAINER_NAME=box
TS_STATE_BACKUP=""
root()  { echo "$FAKE_INCUS_STATE/instances/box/root"; }
image() { echo "$FAKE_INCUS_STATE/images/incus-init/box/root"; }
present() { [[ -e "$1" ]] && echo present || echo gone; }
execs() { cat "$FAKE_INCUS_STATE/exec.log" 2>/dev/null || true; }
backups() { ls "$XDG_RUNTIME_DIR" | grep -c '^incs-tailscale\.' || true; }
# The functions set TS_STATE_BACKUP, so they run in this shell, not in $(...).
stash()   { stash_tailscale_state   > "$SANDBOX/out" 2>&1 && RC=0 || RC=$?; OUT="$(cat "$SANDBOX/out")"; }
restore() { restore_tailscale_state > "$SANDBOX/out" 2>&1 && RC=0 || RC=$?; OUT="$(cat "$SANDBOX/out")"; }
# For runs that end in error(), which exits.
stash_sub() { ( stash_tailscale_state ) > "$SANDBOX/out" 2>&1 && RC=0 || RC=$?; OUT="$(cat "$SANDBOX/out")"; }
# GNU stat on Linux, BSD stat on macOS.
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

fresh_box() {
  export FAKE_INCUS_STATE="$SANDBOX/state-$RANDOM$RANDOM"
  mkdir -p "$FAKE_INCUS_STATE"
  unset FAKE_INCUS_FAIL_EXEC FAKE_INCUS_FAIL_CALL
  rm -f "$XDG_RUNTIME_DIR"/incs-tailscale.*
  TS_STATE_BACKUP=""
  incus launch images:ubuntu/24.04 box
  mkdir -p "$(root)/var/lib/tailscale/certs" "$(root)/etc"
  echo "NODE-KEY" > "$(root)/var/lib/tailscale/tailscaled.state"
  echo "TLS-KEY"  > "$(root)/var/lib/tailscale/certs/box.ts.net.key"
  echo "keep"     > "$(root)/etc/hostname"
}
publish() { incus stop box; incus publish box --alias incus-init/box; incus start box; }

# ===========================================================================
echo "a container that joined a tailnet"
# ===========================================================================
fresh_box
stash
assert_eq "stash: succeeds" "0" "$RC"
assert_eq "stash: the state directory is gone from the container" "gone" "$(present "$(root)/var/lib/tailscale")"
assert_eq "stash: the rest of the filesystem is untouched" "present" "$(present "$(root)/etc/hostname")"
assert_contains "stash: tailscaled was stopped first" "box :: systemctl stop tailscaled" "$(execs)"
assert_eq "stash: one backup file" "1" "$(backups)"
assert_eq "stash: the backup is private" "600" "$(mode "$TS_STATE_BACKUP")"
assert_contains "stash: the backup holds the node key" "tailscale/tailscaled.state" "$(tar -tf "$TS_STATE_BACKUP")"
assert_contains "stash: …and the serve certificates" "tailscale/certs/box.ts.net.key" "$(tar -tf "$TS_STATE_BACKUP")"
assert_contains "stash: says why" "node identity" "$OUT"

publish
assert_eq "publish: the image has no Tailscale state" "gone" "$(present "$(image)/var/lib/tailscale")"
assert_eq "publish: the image has everything else" "present" "$(present "$(image)/etc/hostname")"

restore
assert_eq "restore: succeeds" "0" "$RC"
assert_eq "restore: the node key is back" "NODE-KEY" "$(cat "$(root)/var/lib/tailscale/tailscaled.state")"
assert_eq "restore: the certificates are back" "TLS-KEY" "$(cat "$(root)/var/lib/tailscale/certs/box.ts.net.key")"
assert_eq "restore: the backup file is deleted" "0" "$(backups)"
assert_eq "restore: nothing left to restore" "" "$TS_STATE_BACKUP"
assert_eq "restore: tailscaled is stopped before and started after" \
  "box :: systemctl stop tailscaled
box :: systemctl start tailscaled" "$(execs | grep -E 'systemctl (stop|start) tailscaled' | tail -n 2)"
restore
assert_eq "restore again: a no-op success" "0" "$RC"

# ===========================================================================
echo "a container without Tailscale"
# ===========================================================================
fresh_box
rm -rf "$(root)/var/lib/tailscale"
stash
assert_eq "stash: succeeds" "0" "$RC"
assert_eq "stash: no backup" "0" "$(backups)"
assert_eq "stash: says nothing" "" "$OUT"
assert_not_contains "stash: does not touch tailscaled" "tailscaled" "$(execs)"
restore
assert_eq "restore: a no-op success" "0" "$RC"

# ===========================================================================
echo "the restore fails"
# ===========================================================================
fresh_box
stash
backup="$TS_STATE_BACKUP"
FAKE_INCUS_FAIL_EXEC='^tar -C /var/lib -xf' restore
assert_eq "restore cannot extract: fails" "1" "$RC"
assert_eq "restore cannot extract: the backup is kept" "present" "$(present "$backup")"
assert_eq "restore cannot extract: …and still remembered" "$backup" "$TS_STATE_BACKUP"
assert_not_contains "restore cannot extract: tailscaled is not started on an empty state" \
  "systemctl start tailscaled" "$(execs)"

# ===========================================================================
echo "the check for Tailscale state fails"
# ===========================================================================
fresh_box
FAKE_INCUS_FAIL_EXEC='test -d /var/lib/tailscale' stash_sub
assert_eq "check fails: stops the build" "1" "$RC"
assert_contains "check fails: says why" "No template saved" "$OUT"
assert_eq "check fails: the state is left in place" "present" "$(present "$(root)/var/lib/tailscale/tailscaled.state")"
assert_eq "check fails: no backup" "0" "$(backups)"

# ===========================================================================
echo "publish failed with the container stopped"
# ===========================================================================
fresh_box
stash
incus stop box
restore
assert_eq "stopped: restore succeeds" "0" "$RC"
assert_contains "stopped: the container is started first" "start box" "$(cat "$FAKE_INCUS_STATE/calls.log")"
assert_eq "stopped: the node key is back" "NODE-KEY" "$(cat "$(root)/var/lib/tailscale/tailscaled.state")"
assert_eq "stopped: the backup file is deleted" "0" "$(backups)"

fresh_box
stash
backup="$TS_STATE_BACKUP"
incus stop box
FAKE_INCUS_FAIL_CALL='^start box' restore
assert_eq "cannot start: restore fails" "1" "$RC"
assert_eq "cannot start: the backup is kept" "present" "$(present "$backup")"
assert_eq "cannot start: …and still remembered" "$backup" "$TS_STATE_BACKUP"

# ===========================================================================
echo "tailscaled does not start after the restore"
# ===========================================================================
fresh_box
stash
FAKE_INCUS_FAIL_EXEC='^systemctl start tailscaled' restore
assert_eq "no tailscaled: the restore itself succeeds" "0" "$RC"
assert_eq "no tailscaled: the node key is back" "NODE-KEY" "$(cat "$(root)/var/lib/tailscale/tailscaled.state")"
assert_eq "no tailscaled: the host copy of the key is gone" "0" "$(backups)"
assert_contains "no tailscaled: says how to start it" "systemctl start tailscaled" "$OUT"
assert_not_contains "no tailscaled: does not point at a deleted backup" "incs-tailscale." "$OUT"

# ===========================================================================
echo "tailscaled will not stop"
# ===========================================================================
# systemctl cannot be asked: that proves nothing, so the build stops.
fresh_box
FAKE_INCUS_FAIL_EXEC='^systemctl is-active tailscaled' stash_sub
assert_eq "stash, state unknown: stops the build" "1" "$RC"
assert_contains "stash, state unknown: says so" "(state: unknown)" "$OUT"
assert_eq "stash, state unknown: the state is left in place" "present" "$(present "$(root)/var/lib/tailscale/tailscaled.state")"

fresh_box
mkdir -p "$FAKE_INCUS_STATE/still-active"; touch "$FAKE_INCUS_STATE/still-active/tailscaled"
stash_sub
assert_eq "stash, still running: stops the build" "1" "$RC"
assert_contains "stash, still running: says why" "Could not stop tailscaled in box (state: active)" "$OUT"
assert_eq "stash, still running: the state is left in place" "present" "$(present "$(root)/var/lib/tailscale/tailscaled.state")"
assert_eq "stash, still running: no backup" "0" "$(backups)"

fresh_box
stash
backup="$TS_STATE_BACKUP"
mkdir -p "$FAKE_INCUS_STATE/still-active"; touch "$FAKE_INCUS_STATE/still-active/tailscaled"
restore
assert_eq "restore, still running: fails" "1" "$RC"
assert_eq "restore, still running: the backup is kept" "present" "$(present "$backup")"
assert_eq "restore, still running: nothing extracted over the live state" "gone" "$(present "$(root)/var/lib/tailscale/tailscaled.state")"

# ===========================================================================
echo "the host copy cannot be deleted"
# ===========================================================================
fresh_box
stash
backup="$TS_STATE_BACKUP"
chmod 500 "$XDG_RUNTIME_DIR"
restore
chmod 700 "$XDG_RUNTIME_DIR"
assert_eq "undeletable backup: restore reports failure" "1" "$RC"
assert_eq "undeletable backup: the node key is back in the container" "NODE-KEY" "$(cat "$(root)/var/lib/tailscale/tailscaled.state")"
assert_eq "undeletable backup: the path is still remembered" "$backup" "$TS_STATE_BACKUP"
assert_contains "undeletable backup: tailscaled is started anyway" "box :: systemctl start tailscaled" "$(execs)"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
