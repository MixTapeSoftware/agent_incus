#!/bin/bash
# tests/mixtape_skills_test.sh
# The MixTape Skills plugin is opt-in, clones the repository as the instance
# user, links each skill for Claude Code and for Codex and Grok, updates its
# own checkout on a rerun, and leaves skills and checkouts it doesn't own
# alone. Runs the script the plugin sends into the container, with git
# stubbed so nothing is downloaded.
# Run: bash tests/mixtape_skills_test.sh

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
# git: clone makes a checkout with one skill and one directory that isn't a
# skill; remote get-url reads the origin back; pull is counted.
cat > "$SANDBOX/bin/git" <<'EOF'
#!/bin/bash
if [[ "$1" == clone ]]; then
  url="${@: -2:1}"; dst="${@: -1}"
  mkdir -p "$dst/.git" "$dst/botfight" "$dst/notes"
  echo "$url" > "$dst/.git/origin"; echo "# botfight" > "$dst/botfight/SKILL.md"
  exit 0
fi
if [[ "$1" == -C ]]; then
  dir="$2"; shift 2
  case "$*" in
    "remote get-url origin") cat "$dir/.git/origin" 2>/dev/null || exit 2 ;;
    pull*) echo pulled >> "$dir/.git/pulls" ;;
    *) exit 1 ;;
  esac
  exit 0
fi
exit 1
EOF
chmod +x "$SANDBOX/bin/git"

log() { :; }
incus() {
  [[ "$*" == "exec box -- su - dev -c bash -s" ]] || return 1
  cat > "$SANDBOX/script"
}
# shellcheck source=../plugins/50-mixtape-skills.sh
source "$REPO_ROOT/plugins/50-mixtape-skills.sh"
CONTAINER_NAME=box HOST_USER=dev

echo "defaults"
assert_eq "it's opt-in" "0" "$PLUGIN_DEFAULT"
assert_eq "with a flag to opt in" "--mixtape-skills" "$PLUGIN_CLI_FLAGS"

H="$SANDBOX/home"
run() { plugin_install; env -i HOME="$H" PATH="$SANDBOX/bin:/usr/bin:/bin" bash "$SANDBOX/script" 2>&1; }
CO="$H/.local/share/mixtape-skills"

echo "a fresh install"
out="$(run)"
assert_eq "it clones the MixTape skills repository" "https://github.com/MixTapeSoftware/skills.git" "$(cat "$CO/.git/origin")"
assert_eq "Codex and Grok get the skill" "$CO/botfight" "$(readlink "$H/.agents/skills/botfight")"
assert_eq "Claude Code gets the skill" "$CO/botfight" "$(readlink "$H/.claude/skills/botfight")"
assert_eq "a directory without SKILL.md isn't linked" "no" "$([[ -e "$H/.agents/skills/notes" ]] && echo yes || echo no)"

echo "a rerun"
out="$(run)"
assert_eq "it updates its own checkout" "pulled" "$(cat "$CO/.git/pulls")"
assert_eq "the links stay" "$CO/botfight" "$(readlink "$H/.claude/skills/botfight")"
assert_eq "and it says nothing" "" "$out"

echo "what it doesn't own"
rm -rf "$H"; mkdir -p "$H/.claude/skills/botfight" "$H/.agents/skills"
echo mine > "$H/.claude/skills/botfight/SKILL.md"
ln -s /elsewhere "$H/.agents/skills/botfight"
out="$(run)"
assert_eq "a skill folder of the user's is left alone" "mine" "$(cat "$H/.claude/skills/botfight/SKILL.md")"
assert_eq "a link to somewhere else is left alone" "/elsewhere" "$(readlink "$H/.agents/skills/botfight")"
assert_contains "and it says so" "isn't from MixTape Skills; left it alone" "$out"
rm -rf "$H"; mkdir -p "$CO/.git"; echo "https://example.com/other.git" > "$CO/.git/origin"; echo keep > "$CO/file"
out="$(run)"
assert_eq "another checkout at the path is moved aside" "keep" "$(cat "$CO".backup.*/file)"
assert_eq "and replaced with ours" "https://github.com/MixTapeSoftware/skills.git" "$(cat "$CO/.git/origin")"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
