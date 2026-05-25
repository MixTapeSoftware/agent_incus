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
echo "format_env_warning_lines:"

# Helper: build a temp fixture with given files, then run format_env_warning_lines.
fmt_warning_for() {
  local workspace="$1"; shift
  local f
  for f in "$@"; do
    mkdir -p "$workspace/$(dirname "$f")"
    : > "$workspace/$f"
  done
  detect_env_files "$workspace" | format_env_warning_lines "$workspace" 2>&1 || true
}

# Strip ANSI color codes via bash ANSI-C quoting so the pattern is a literal
# ESC byte. GNU sed's \xNN escape is not portable to BSD/macOS sed.
strip_ansi() {
  sed $'s/\033\\[[0-9;]*m//g'
}

# Small list — no truncation
fixture="$(mktemp -d)"
actual="$(fmt_warning_for "$fixture" .env apps/web/.env.local services/api/.env.production)"
actual="$(printf '%s' "$actual" | strip_ansi)"

# Check that the output contains the expected header and footer
header_ok=0
footer_ok=0
[[ "$actual" == *"[!] The workspace mount will expose these .env files inside the container:"* ]] && header_ok=1
[[ "$actual" == *"[!] Safer pattern: use the 1Password CLI to hydrate env at runtime"* ]] && footer_ok=1

# Check that all three files are present in the output
files_ok=0
[[ "$actual" == *"[!]       .env"* ]] && \
[[ "$actual" == *"[!]       apps/web/.env.local"* ]] && \
[[ "$actual" == *"[!]       services/api/.env.production"* ]] && \
files_ok=1

# Check that the count is 3 (just 3 file lines, not truncated)
file_count="$(printf '%s\n' "$actual" | grep -cE '^\[!\]       [a-zA-Z0-9/.._-]+' || true)"
if (( file_count == 3 && header_ok == 1 && footer_ok == 1 && files_ok == 1 )); then
  PASS=$((PASS+1))
  echo "  ok  small list, no truncation"
else
  FAIL=$((FAIL+1))
  echo "  FAIL small list, no truncation"
  echo "    expected: all three files present, no truncation"
  echo "    actual:"
  printf '      %s\n' "$actual" | head -20
fi
rm -rf "$fixture"

# Long list — truncates after 20, appends "…and N more"
fixture="$(mktemp -d)"
files=()
for i in $(seq 1 25); do files+=("dir$i/.env"); done
actual="$(fmt_warning_for "$fixture" "${files[@]}")"
actual="$(printf '%s' "$actual" | strip_ansi)"
truncation_line="$(printf '%s' "$actual" | grep -E '…and [0-9]+ more' || true)"
assert_eq "long list shows truncation marker" "[!]       …and 5 more" "$truncation_line"
# Count listed file entries (lines that start with "[!]       dir...")
listed_count="$(printf '%s\n' "$actual" | grep -cE '^\[!\]       dir[0-9]+/\.env$' || true)"
assert_eq "long list shows exactly 20 entries" "20" "$listed_count"
rm -rf "$fixture"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
