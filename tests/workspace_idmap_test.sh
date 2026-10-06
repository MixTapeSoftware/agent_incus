#!/bin/bash
# tests/workspace_idmap_test.sh
# The workspace is a plain bind mount with only the user's UID/GID mapped
# into the container (raw.idmap), so root inside the container is not root
# over the checkout. These tests run the real helpers from incus.init: the
# mapping value, the subordinate-ID check that gates the launch, and the
# mount itself against the fake `incus`.
# Run: bash tests/workspace_idmap_test.sh

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

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin" "$SANDBOX/etc"
cp "$SCRIPT_DIR/lib/fake_incus" "$SANDBOX/bin/incus"
chmod +x "$SANDBOX/bin/incus"
export PATH="$SANDBOX/bin:$PATH"

extract_fn() {
  awk -v name="$1" '$0 ~ "^" name "\\(\\)" {c=1} c {print} c && /^}/ {exit}' "$REPO_ROOT/incus.init"
}
log()  { echo "[+] $1"; }
warn() { echo "[!] $1"; }
error(){ echo "[ERROR] $1" >&2; return 1; }
for fn in workspace_idmap subid_allows subids_missing subid_grant_hint mount_workspace; do
  eval "$(extract_fn "$fn")"
  declare -F "$fn" >/dev/null || { echo "$fn not found in incus.init"; exit 1; }
done

ETC="$SANDBOX/etc"
allows() { subid_allows "$ETC/$1" "$2" && echo yes || echo no; }

# ===========================================================================
echo "the mapping"
# ===========================================================================
assert_eq "same uid and gid: one line"  "both 1000 1000" "$(workspace_idmap 1000 1000)"
assert_eq "different gid: two lines"    "uid 1000 1000
gid 1001 1001" "$(workspace_idmap 1000 1001)"
assert_eq "a different user"            "both 501 501"   "$(workspace_idmap 501 501)"

# ===========================================================================
echo "what root has been granted"
# ===========================================================================
printf 'root:1000000:1000000000\n' > "$ETC/subuid"      # the usual Incus install line
assert_eq "the default Incus range does not cover 1000" "no" "$(allows subuid 1000)"
printf 'root:1000000:1000000000\nroot:1000:1\n' > "$ETC/subuid"
assert_eq "a one-ID grant covers it" "yes" "$(allows subuid 1000)"
assert_eq "…and only it" "no" "$(allows subuid 1001)"
printf '0:999:3\n' > "$ETC/subuid"
assert_eq "root by uid, a range that includes 1000" "yes" "$(allows subuid 1000)"
assert_eq "…up to its end" "yes" "$(allows subuid 1001)"
assert_eq "…and not past it" "no" "$(allows subuid 1002)"
printf 'chad:1000:1\n' > "$ETC/subuid"
assert_eq "another user's grant does not count" "no" "$(allows subuid 1000)"
printf 'root:1000000:1000000000\n# a comment\nroot:x:y\nroot:1000:1\n' > "$ETC/subuid"
assert_eq "junk lines are skipped" "yes" "$(allows subuid 1000)"
rm -f "$ETC/subuid"
assert_eq "no file: nothing granted" "no" "$(allows subuid 1000)"

# ===========================================================================
echo "the check before the launch"
# ===========================================================================
rm -f "$ETC/subuid" "$ETC/subgid"
assert_eq "no subid files: Incus uses its default range, nothing to grant" "" "$(subids_missing 1000 1000 "$ETC")"
printf 'root:1000000:1000000000\n' > "$ETC/subuid"
printf 'root:1000000:1000000000\n' > "$ETC/subgid"
assert_eq "neither grants: both named" "$ETC/subuid and $ETC/subgid" "$(subids_missing 1000 1000 "$ETC")"
printf 'root:1000:1\n' >> "$ETC/subuid"
assert_eq "uid granted, gid not: subgid named" "$ETC/subgid" "$(subids_missing 1000 1000 "$ETC")"
printf 'root:1000:1\n' >> "$ETC/subgid"
assert_eq "both granted: nothing missing" "" "$(subids_missing 1000 1000 "$ETC")"
assert_eq "a different gid is checked against subgid" "$ETC/subgid" "$(subids_missing 1000 1001 "$ETC")"
hint="$(subid_grant_hint 1000 1001)"
assert_contains "the hint grants exactly those IDs" "--add-subuids 1000-1000 --add-subgids 1001-1001 root" "$hint"
assert_contains "…and restarts Incus so it rereads them" "restart incus" "$hint"

# ===========================================================================
echo "the mount"
# ===========================================================================
export FAKE_INCUS_STATE="$SANDBOX/state"
mkdir -p "$FAKE_INCUS_STATE"
incus launch images:ubuntu/24.04 box
dev() { cat "$FAKE_INCUS_STATE/instances/box/config/devices.workspace.$1" 2>/dev/null || true; }
out="$(mount_workspace box /home/me/proj /workspace 2>&1)" && rc=0 || rc=$?
assert_eq "mount: succeeds" "0" "$rc"
assert_eq "mount: a disk device"       "disk"          "$(dev type)"
assert_eq "mount: from the host path"  "/home/me/proj" "$(dev source)"
assert_eq "mount: at the mount path"   "/workspace"    "$(dev path)"
assert_eq "mount: no ID shifting"      ""              "$(dev shift)"
assert_eq "mount: setuid is ignored inside" "nosuid"   "$(dev raw.mount.options)"
assert_contains "mount: says root inside stays unprivileged" "unprivileged" "$out"

export FAKE_INCUS_STATE="$SANDBOX/state2"
mkdir -p "$FAKE_INCUS_STATE"
incus launch images:ubuntu/24.04 box
out="$(FAKE_INCUS_FAIL_CALL='^config device add box workspace' mount_workspace box /home/me/proj /workspace 2>&1)" && rc=0 || rc=$?
assert_eq "mount fails: reports it" "1" "$rc"
assert_contains "mount fails: says so" "Workspace mount failed" "$out"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
