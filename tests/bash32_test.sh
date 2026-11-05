#!/bin/bash
# tests/bash32_test.sh
# macOS runs these scripts with Bash 3.2, which finds the end of a $(...) by
# scanning for it rather than parsing: an apostrophe in a comment in there
# opens a quote, and the script fails to parse hundreds of lines later, on
# macOS only. bash -n on a newer Bash can't see that, so tests/lib/bash32_scan.py
# looks for it: comments with quotes or parens in $(...), and case in $(...).
# Run: bash tests/bash32_test.sh

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

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
SCAN="$SCRIPT_DIR/lib/bash32_scan.py"
found() { python3 "$SCAN" "$1" | tail -n 1 | cut -d' ' -f1; }

echo "the scanner"
cat > "$SANDBOX/comment" <<'SH'
x="$(
  # this can't be parsed
  echo a
)"
SH
assert_eq "finds an apostrophe in a comment in \$(...)" "1" "$(found "$SANDBOX/comment")"
cat > "$SANDBOX/paren" <<'SH'
x=$(
  echo a  # one (of two)
)
SH
assert_eq "finds a paren in a trailing comment" "1" "$(found "$SANDBOX/paren")"
cat > "$SANDBOX/case" <<'SH'
x=$(
  case a in
    a) echo b ;;
  esac
)
SH
assert_eq "finds a case" "1" "$(found "$SANDBOX/case")"
cat > "$SANDBOX/clean" <<'SH'
# Outside it, this can't matter.
x="$(echo "it's" 'a (string)'; echo $((1 + 2)); echo case)"
cat <<TEXT
Here-documents aren't code (at all).
TEXT
y=$(cat <<TEXT
Nor here: it's text
TEXT
)
SH
assert_eq "leaves everything else alone" "0" "$(found "$SANDBOX/clean")"

echo "the scripts"
cd "$REPO_ROOT"
# Sourced files have no #! line, so they're named as well as found by it.
files=()
while IFS= read -r f; do
  head -n 1 "$f" | grep -qE '^#!.*\b(ba)?sh\b' && files+=("$f")
done < <(git ls-files | grep -vE '^(\.agents|\.claude|\.grok|docs)/|\.(md|txt|py)$|^plugins/.*\.sh$|^boxen\.')
while IFS= read -r f; do files+=("$f"); done < <(git ls-files 'plugins/*.sh' 'boxen.*')
assert_eq "there are scripts to check" "yes" "$([[ ${#files[@]} -ge 40 ]] && echo yes || echo no)"
out="$(python3 "$SCAN" "${files[@]}")"
assert_eq "none of them has it" "0 found" "$(printf '%s\n' "$out" | tail -n 1 | cut -d' ' -f1-2)"
[[ "$out" == "0 found"* ]] || printf '%s\n' "$out"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
