#!/bin/bash
# tests/init_cleanup_test.sh
# incus.init gives the user passwordless sudo while plugins install. These
# tests run its real exit handling against the fake `incus` and check the
# grant is taken back on every way out of a failed build.
# Run: bash tests/init_cleanup_test.sh

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
mkdir -p "$SANDBOX/bin"
cp "$SCRIPT_DIR/lib/fake_incus" "$SANDBOX/bin/incus"
chmod +x "$SANDBOX/bin/incus"
export PATH="$SANDBOX/bin:$PATH"

# The real functions and trap lines, lifted out of incus.init.
extract_fn() {
  awk -v name="$1" '$0 ~ "^" name "\\(\\)" {c=1} c {print} c && /^}/ {exit}' "$REPO_ROOT/incus.init"
}
{
  echo 'set -euo pipefail'
  printf 'source %q\n' "$REPO_ROOT/incus.proxy"
  echo 'log()  { echo "[+] $1"; }'
  echo 'warn() { echo "[!] $1"; }'
  echo 'error(){ echo "[ERROR] $1" >&2; exit 1; }'
  extract_fn revoke_build_sudo
  extract_fn cleanup_on_exit
  echo 'CONTAINER_NAME=box; HOST_USER=dev; BUILD_SUDO_GRANTED="${GRANTED:-1}"'
  grep -E "^trap (cleanup_on_exit EXIT|'exit [0-9]+' (INT|TERM|HUP))\$" "$REPO_ROOT/incus.init" || true
  echo 'eval "$BODY"'
} > "$SANDBOX/harness.sh"
assert_eq "harness found the exit trap and three signal traps" \
  "4" "$(grep -c '^trap ' "$SANDBOX/harness.sh")"

fresh_box() {
  export FAKE_INCUS_STATE="$SANDBOX/state-$RANDOM$RANDOM"
  mkdir -p "$FAKE_INCUS_STATE"
  unset FAKE_INCUS_FAIL_EXEC FAKE_INCUS_FAIL_CALL GRANTED
  incus launch images:ubuntu/24.04 box
}
# run <body> — stdin is whatever the caller provides.
run() { BODY="$1" bash "$SANDBOX/harness.sh" > "$SANDBOX/out" 2>&1 && RC=0 || RC=$?; }
revoked() {
  local n
  n="$(grep -c '^box :: rm -f /etc/sudoers.d/dev$' "$FAKE_INCUS_STATE/exec.log" 2>/dev/null)" || true
  echo "${n:-0}"
}
exists()  { incus info box >/dev/null 2>&1 && echo yes || echo no; }

echo "incus.init exit handling"

# error() exits directly; an ERR trap never ran for it.
fresh_box
run 'error "mount failed"' </dev/null
assert_eq "error(), no stdin: exit code is kept"        "1"   "$RC"
assert_eq "error(), no stdin: sudo grant is revoked"    "1"   "$(revoked)"
assert_eq "error(), no stdin: container is not deleted" "yes" "$(exists)"

fresh_box
run 'false' </dev/null
assert_eq "failed command, no stdin: sudo grant is revoked"    "1"   "$(revoked)"
assert_eq "failed command, no stdin: container is not deleted" "yes" "$(exists)"

fresh_box
run 'false' <<< "n"
assert_eq "answer n: sudo grant is revoked" "1"   "$(revoked)"
assert_eq "answer n: container is kept"     "yes" "$(exists)"

fresh_box
run 'false' <<< ""
assert_eq "answer Enter: container is deleted" "no" "$(exists)"

fresh_box
export GRANTED=0
run 'false' </dev/null
assert_eq "failure before the grant: nothing to revoke" "0" "$(revoked)"

fresh_box
export FAKE_INCUS_FAIL_EXEC='rm -f /etc/sudoers'
run 'false' </dev/null
assert_contains "revoke fails: says so and how to recover" \
  "Could not revoke build-time sudo" "$(cat "$SANDBOX/out")"

fresh_box
BODY='sleep 5 & wait $!' bash "$SANDBOX/harness.sh" > "$SANDBOX/out" 2>&1 </dev/null &
pid=$!
sleep 1
kill -TERM "$pid"
wait "$pid" && RC=0 || RC=$?
assert_eq "SIGTERM mid-build: exit code"            "143" "$RC"
assert_eq "SIGTERM mid-build: sudo grant is revoked" "1"  "$(revoked)"

fresh_box
run 'revoke_build_sudo; trap - EXIT INT TERM HUP'
assert_eq "successful build: exit code"        "0" "$RC"
assert_eq "successful build: revoked once"     "1" "$(revoked)"

# Failures after the default proxy has been created must keep or delete the
# pair together, and a failed agent deletion must preserve its proxy.
make_owned_proxy() {
  printf '\n' | bash "$REPO_ROOT/incus.proxy" new box-proxy >/dev/null
  incus config set box-proxy user.incs.proxy-owner=box
  incus config set box user.incs.owned-proxy=box-proxy
}
proxy_exists() { incus info box-proxy >/dev/null 2>&1 && echo yes || echo no; }

fresh_box
make_owned_proxy
run 'false' <<< ""
assert_eq "delete failed build: agent removed" "no" "$(exists)"
assert_eq "delete failed build: owned proxy removed" "no" "$(proxy_exists)"

fresh_box
make_owned_proxy
run 'false' <<< "n"
assert_eq "keep failed build: agent remains" "yes" "$(exists)"
assert_eq "keep failed build: owned proxy remains" "yes" "$(proxy_exists)"

fresh_box
make_owned_proxy
export FAKE_INCUS_FAIL_CALL='^delete --force box$'
run 'false' <<< ""
assert_eq "failed cleanup delete: agent remains" "yes" "$(exists)"
assert_eq "failed cleanup delete: proxy remains" "yes" "$(proxy_exists)"
assert_contains "failed cleanup delete: says proxy was kept" "its proxy was kept" "$(cat "$SANDBOX/out")"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
