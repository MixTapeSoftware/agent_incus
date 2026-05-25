#!/bin/bash
# tests/env_scan_test.sh
# Smoke tests for detect_env_files and format_env_warning_lines.
# Run: bash tests/env_scan_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../incus.envscan
source "$REPO_ROOT/incus.envscan"

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
    echo "    expected:"
    printf '      %s\n' "$expected" | sed 's/^      $/      <empty>/'
    echo "    actual:"
    printf '      %s\n' "$actual" | sed 's/^      $/      <empty>/'
  fi
}

# ---------------------------------------------------------------------------
# Fixture builder
# ---------------------------------------------------------------------------
make_fixture() {
  local root
  root="$(mktemp -d)"
  mkdir -p "$root/apps/web" "$root/services/api" \
           "$root/node_modules/somepkg" "$root/.git/hooks" \
           "$root/vendor/lib" "$root/dist" "$root/build" "$root/target"
  : > "$root/.env"
  : > "$root/.env.local"
  : > "$root/.env.example"           # excluded by basename
  : > "$root/.env.sample"             # excluded by basename
  : > "$root/.env.template"           # excluded by basename
  : > "$root/.env.dist"               # excluded by basename
  : > "$root/apps/web/.env.production"
  : > "$root/services/api/.env"
  : > "$root/node_modules/somepkg/.env"   # excluded by path
  : > "$root/.git/hooks/.env"             # excluded by path
  : > "$root/vendor/lib/.env"             # excluded by path
  : > "$root/dist/.env"                   # excluded by path
  : > "$root/build/.env"                  # excluded by path
  : > "$root/target/.env"                 # excluded by path
  echo "$root"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
echo "detect_env_files:"

fixture="$(make_fixture)"
actual="$(detect_env_files "$fixture" | sort)"
expected="$(printf '%s\n' \
  "$fixture/.env" \
  "$fixture/.env.local" \
  "$fixture/apps/web/.env.production" \
  "$fixture/services/api/.env" \
  | sort)"
assert_eq "finds .env* respecting exclusions" "$expected" "$actual"
rm -rf "$fixture"

# Empty directory
fixture="$(mktemp -d)"
actual="$(detect_env_files "$fixture")"
assert_eq "empty dir produces empty output" "" "$actual"
rm -rf "$fixture"

# Directory with only excluded files
fixture="$(mktemp -d)"
: > "$fixture/.env.example"
: > "$fixture/.env.sample"
actual="$(detect_env_files "$fixture")"
assert_eq "only-excluded dir produces empty output" "" "$actual"
rm -rf "$fixture"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
