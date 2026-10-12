#!/bin/bash
# tests/prompt_test.sh
# Pasted secrets must be stored exactly as the user meant them. Terminals can
# wrap a paste in escape sequences: focus reporting (ESC [ O on leaving the
# window, ESC [ I on returning) and bracketed paste (ESC [ 200~ ... ESC [ 201~).
# A hidden prompt cannot show them, and a token saved with them fails with a
# bare 401.
# Run: bash tests/prompt_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

exec </dev/null

PASS=0
FAIL=0
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS+1)); echo "  ok  $label"
  else
    FAIL=$((FAIL+1)); echo "  FAIL $label"
    printf '    expected: %q\n' "$expected"
    printf '    actual:   %q\n' "$actual"
  fi
}

ESC=$'\e'
FOCUS_OUT="${ESC}[O"
FOCUS_IN="${ESC}[I"
PASTE_START="${ESC}[200~"
PASTE_END="${ESC}[201~"

# ===========================================================================
echo "clean_pasted_value"
# ===========================================================================
# shellcheck source=../incus.prompt
source "$REPO_ROOT/incus.prompt"

clean() { printf '%s' "$1" | clean_pasted_value; }

assert_eq "focus sequences around a token are removed" \
  "github_pat_11ABC_def" "$(clean "${FOCUS_OUT}github_pat_11ABC_def${FOCUS_IN}")"
assert_eq "bracketed paste markers are removed" \
  "ghp_0123456789abcdef" "$(clean "${PASTE_START}ghp_0123456789abcdef${PASTE_END}")"
assert_eq "focus and paste sequences together are removed" \
  "tskey-auth-kX1-Yz" "$(clean "${FOCUS_OUT}${PASTE_START}tskey-auth-kX1-Yz${PASTE_END}${FOCUS_IN}")"
assert_eq "a trailing carriage return is removed" \
  "ops_eyJhbGciOi" "$(clean $'ops_eyJhbGciOi\r')"
assert_eq "a bare escape byte is removed" \
  "abc" "$(clean "a${ESC}bc")"
assert_eq "other control characters are removed" \
  "abc" "$(clean $'a\x01b\x7fc')"
assert_eq "base64 and URL-safe characters are kept" \
  "ops_eyJ+/=.-_~:AZaz09" "$(clean "ops_eyJ+/=.-_~:AZaz09")"
assert_eq "an already clean value is unchanged" \
  "plain-token" "$(clean "plain-token")"
assert_eq "spaces inside a value are kept" \
  "op://Private/GitHub my-project/token" "$(clean "op://Private/GitHub my-project/token${FOCUS_IN}")"
assert_eq "spaces left at the ends after removal are trimmed" \
  "tok" "$(clean "${FOCUS_OUT} tok ${FOCUS_IN}")"
assert_eq "an empty value stays empty" \
  "" "$(clean "")"
assert_eq "a value that is only noise becomes empty" \
  "" "$(clean "${FOCUS_OUT}${FOCUS_IN}")"

# ===========================================================================
echo "read_secret / read_value"
# ===========================================================================
got=""
read_secret got "Token: " <<< "${FOCUS_OUT}secret-1${FOCUS_IN}"
assert_eq "read_secret stores the cleaned value" "secret-1" "$got"

got="unchanged"
read_secret got "Token: " < /dev/null
assert_eq "read_secret at end of input stores an empty value" "" "$got"

rc=0
( set -e; read_secret got "Token: " < /dev/null; echo reached ) >/dev/null || rc=$?
assert_eq "read_secret at end of input does not abort a set -e script" "0" "$rc"

got=""
read_value got "Reference: " <<< "op://V/Item name/f${FOCUS_IN}"
assert_eq "read_value stores the cleaned value" "op://V/Item name/f" "$got"

# ===========================================================================
echo "plugin prompts"
# ===========================================================================
# Each plugin's prompt runs the way incus.init runs it, with the framework's
# helpers stubbed and the pasted answer on stdin.
run_prompt() {
  local plugin="$1" var="$2" input="$3"
  (
    set -euo pipefail
    log() { :; }; warn() { :; }; error() { echo "ERROR: $1" >&2; exit 1; }
    selected_get() { echo 0; }
    # shellcheck source=../incus.prompt
    source "$REPO_ROOT/incus.prompt"
    # shellcheck disable=SC1090
    source "$REPO_ROOT/plugins/$plugin"
    plugin_prompt >/dev/null 2>&1 <<< "$input"
    printf '%s' "${!var}"
  )
}

assert_eq "GitHub Auth token is cleaned" "github_pat_GH" \
  "$(run_prompt 60-gh-auth.sh GH_TOKEN_VALUE "${FOCUS_OUT}github_pat_GH${FOCUS_IN}
Ada
ada@example.com")"
assert_eq "1Password service account token is cleaned" "ops_1P" \
  "$(run_prompt 60-1pass.sh ONEPASSWORD_SERVICE_KEY "${PASTE_START}ops_1P${PASTE_END}")"
assert_eq "Tailscale auth key is cleaned" "tskey-auth-TS" \
  "$(run_prompt 50-tailscale.sh TS_AUTH_KEY "${FOCUS_OUT}tskey-auth-TS${FOCUS_IN}
")"

# ===========================================================================
echo "incs -e"
# ===========================================================================
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin"
cp "$SCRIPT_DIR/lib/fake_incus" "$SANDBOX/bin/incus"
chmod +x "$SANDBOX/bin/incus"
export PATH="$SANDBOX/bin:$PATH"
export FAKE_INCUS_STATE="$SANDBOX/state"
mkdir -p "$FAKE_INCUS_STATE"
USER_NAME="$(id -un)"

incus launch images:ubuntu/24.04 proj
printf '%s\n' "${FOCUS_OUT}sk-live-VALUE${FOCUS_IN}" | bash "$REPO_ROOT/incs" -e proj OPENAI_API_KEY >/dev/null 2>&1
assert_eq "incs -e stores the cleaned value in the incus environment" \
  "sk-live-VALUE" "$(incus config get proj environment.OPENAI_API_KEY)"
assert_eq "incs -e writes the cleaned value to ~/.zshenv" \
  "export OPENAI_API_KEY=sk-live-VALUE" \
  "$(grep '^export OPENAI_API_KEY=' "$FAKE_INCUS_STATE/instances/proj/root/home/$USER_NAME/.zshenv" 2>/dev/null || true)"

out="$(printf '%s\n' "${FOCUS_OUT}${FOCUS_IN}" | bash "$REPO_ROOT/incs" -e proj EMPTY_ONE 2>&1)" && rc=0 || rc=$?
assert_eq "incs -e refuses a value that was only terminal noise" "1" "$rc"

echo ""
echo "Passed: $PASS    Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
