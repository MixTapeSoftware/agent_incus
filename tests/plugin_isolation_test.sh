#!/bin/bash
# tests/plugin_isolation_test.sh
# Verifies plugin metadata and functions do not leak between source calls
# in the install/prompt run loops.
# Run: bash tests/plugin_isolation_test.sh

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

# Pull _reset_plugin_state out of incus.init by sourcing the script with a
# guard that exits before any side effects. The script exits via `usage` when
# called with -h, but only after defining the helper functions we need.
extract_reset_helper() {
  awk '
    /^_reset_plugin_state\(\)/ {capture=1}
    capture {print}
    capture && /^}/ {exit}
  ' "$REPO_ROOT/incus.init"
}

helper_src="$(extract_reset_helper)"
if [[ -z "$helper_src" ]]; then
  echo "FAIL: _reset_plugin_state not found in incus.init"
  exit 1
fi
eval "$helper_src"

# ---------------------------------------------------------------------------
# Build two fake plugins: A declares prompt + run_on_launch + plugin_prompt
#                        B is bare-bones (no prompt, no launch hooks)
# ---------------------------------------------------------------------------
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

cat > "$fixture/plug_a.sh" <<'EOF'
PLUGIN_ID="a"
PLUGIN_NAME="A"
PLUGIN_DESC="A plugin"
PLUGIN_NEEDS_PROMPT=1
PLUGIN_RUN_ON_LAUNCH=1
plugin_prompt() { echo "A_PROMPT_FIRED"; }
plugin_is_installed() { return 0; }
plugin_install() { echo "A_INSTALL"; }
plugin_on_launch() { echo "A_ON_LAUNCH"; }
EOF

cat > "$fixture/plug_b.sh" <<'EOF'
PLUGIN_ID="b"
PLUGIN_NAME="B"
PLUGIN_DESC="B plugin"
plugin_install() { echo "B_INSTALL"; }
EOF

# Simulate run loop: source A, then reset, then source B.
PLUGIN_ID="" PLUGIN_NAME="" PLUGIN_DESC="" PLUGIN_DEFAULT=0
PLUGIN_CLI_FLAGS="" PLUGIN_NEEDS_PROMPT=0 PLUGIN_RUN_ON_LAUNCH=0

_reset_plugin_state
source "$fixture/plug_a.sh"
assert_eq "A: PLUGIN_NEEDS_PROMPT set"   "1" "${PLUGIN_NEEDS_PROMPT:-0}"
assert_eq "A: PLUGIN_RUN_ON_LAUNCH set"  "1" "${PLUGIN_RUN_ON_LAUNCH:-0}"
assert_eq "A: plugin_prompt defined"     "plugin_prompt" "$(declare -F plugin_prompt 2>/dev/null || echo "")"
assert_eq "A: plugin_on_launch defined"  "plugin_on_launch" "$(declare -F plugin_on_launch 2>/dev/null || echo "")"

_reset_plugin_state
source "$fixture/plug_b.sh"
assert_eq "B: PLUGIN_ID overwritten"      "b" "$PLUGIN_ID"
assert_eq "B: PLUGIN_NEEDS_PROMPT cleared"   "0" "${PLUGIN_NEEDS_PROMPT:-0}"
assert_eq "B: PLUGIN_RUN_ON_LAUNCH cleared"  "0" "${PLUGIN_RUN_ON_LAUNCH:-0}"
assert_eq "B: plugin_prompt unset"        "" "$(declare -F plugin_prompt 2>/dev/null || echo "")"
assert_eq "B: plugin_on_launch unset"     "" "$(declare -F plugin_on_launch 2>/dev/null || echo "")"
assert_eq "B: plugin_is_installed unset"  "" "$(declare -F plugin_is_installed 2>/dev/null || echo "")"

echo ""
echo "Passed: $PASS    Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
