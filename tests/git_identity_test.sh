#!/bin/bash
# tests/git_identity_test.sh
# The git identity a container commits with: what git would use in the folder
# being copied (its own config, an includeIf for its path), else the global
# one; set in the container on every build with the values on stdin, never in
# a command string; nothing for a template; a warning when the host has none.
# Runs boxen.init's functions with a sandbox HOME and real git.
# Run: bash tests/git_identity_test.sh

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
export HOME="$SANDBOX/host" GIT_CONFIG_NOSYSTEM=1
unset XDG_CONFIG_HOME GIT_CONFIG_GLOBAL
mkdir -p "$HOME" "$SANDBOX/plain" "$SANDBOX/work/repo" "$SANDBOX/mine"
git config --global user.name "Global Person"
git config --global user.email global@example.com
# A work identity for everything under work/, as many people set it up.
git config --global "includeIf.gitdir:$SANDBOX/work/.path" "$HOME/.gitconfig-work"
git config --file "$HOME/.gitconfig-work" user.email ada@work.example
git -C "$SANDBOX/work/repo" init -q
git -C "$SANDBOX/mine" init -q
git -C "$SANDBOX/mine" config user.name "Repo Person"
git -C "$SANDBOX/mine" config user.email repo@example.com

eval "$(awk '/^GIT_NAME="" GIT_EMAIL=""/ {c=1} c {print} c && /^write_git_identity\(\) \{/ {w=1} w && /^}/ {exit}' "$REPO_ROOT/boxen.init")"
log() { echo "[+] $1"; }
warn() { echo "[!] $1"; }
read_value() { :; }
# The fake container: the command it was given, and what came on stdin.
incus() { printf '%s\n' "$*" > "$SANDBOX/args"; cat > "$SANDBOX/stdin"; }
CONTAINER_NAME=box HOST_USER=dev SAVE_TEMPLATE=0 NO_COPY=0 DRY_RUN=0

capture() { WORKSPACE_PATH="$1"; GIT_NAME="" GIT_EMAIL="" GIT_ID_SOURCE=""; capture_git_identity; }

echo "capture"
capture "$SANDBOX/plain"
assert_eq "a folder with no git setup of its own uses the global name" "Global Person" "$GIT_NAME"
assert_eq "and the global email" "global@example.com" "$GIT_EMAIL"
assert_eq "and says so" "your global git config" "$GIT_ID_SOURCE"
capture "$SANDBOX/work/repo"
assert_eq "an includeIf for the folder's path wins" "ada@work.example" "$GIT_EMAIL"
assert_eq "keeping the global name it doesn't set" "Global Person" "$GIT_NAME"
assert_contains "and the source is the folder" "work/repo's git config" "$GIT_ID_SOURCE"
capture "$SANDBOX/mine"
assert_eq "a repository's own identity wins" "Repo Person <repo@example.com>" "$GIT_NAME <$GIT_EMAIL>"
NO_COPY=1 capture "$SANDBOX/mine"
assert_eq "with nothing copied, the global identity" "global@example.com" "$GIT_EMAIL"
NO_COPY=0

# An identity kept in a file the global config includes, as dotfiles often do.
mv "$HOME/.gitconfig" "$HOME/.gitconfig.main"
git config --file "$HOME/.gitconfig" include.path "$HOME/.gitconfig.main"
NO_COPY=1 capture "$SANDBOX/plain"
assert_eq "a global identity in an included file is found" "Global Person <global@example.com>" "$GIT_NAME <$GIT_EMAIL>"
capture "$SANDBOX/plain"
assert_eq "and still called global" "your global git config" "$GIT_ID_SOURCE"
mv "$HOME/.gitconfig.main" "$HOME/.gitconfig"
NO_COPY=0

# Git accepts an email written as <foo@example.com>; the brackets aren't part of it.
git config --global user.email "<foo@users.noreply.github.com>"
capture "$SANDBOX/plain"
assert_eq "an email in angle brackets loses them" "foo@users.noreply.github.com" "$GIT_EMAIL"
assert_eq "and is still the global one" "your global git config" "$GIT_ID_SOURCE"
git config --global user.email "  < spaced@example.com >  "
capture "$SANDBOX/plain"
assert_eq "spaces around and inside the brackets go too" "spaced@example.com" "$GIT_EMAIL"
git config --global user.email "a<b>@example.com"
capture "$SANDBOX/plain"
assert_eq "brackets that don't wrap it are left alone" "a<b>@example.com" "$GIT_EMAIL"
git config --global user.email global@example.com

echo "write"
capture "$SANDBOX/plain"
GIT_NAME="Zoë O'Brien; rm -rf ~" GIT_EMAIL='z@example.com'
out="$(write_git_identity)"
assert_eq "the name is never in the command" "no" "$(grep -q 'Zo' "$SANDBOX/args" && echo yes || echo no)"
assert_eq "it goes in on stdin" "Zoë O'Brien; rm -rf ~" "$(head -1 "$SANDBOX/stdin")"
assert_contains "and the build says what it set" "Git identity: Zoë O'Brien; rm -rf ~ <z@example.com>" "$out"
# Run what the container would: the command, as the user, with that stdin.
script="$(sed -n "s/^exec box -- su - dev -s \/bin\/sh -c //p" "$SANDBOX/args")"
mkdir -p "$SANDBOX/inside"
HOME="$SANDBOX/inside" sh -c "$script" < "$SANDBOX/stdin"
assert_eq "the container's git has the name, intact" "Zoë O'Brien; rm -rf ~" "$(HOME="$SANDBOX/inside" git config --global user.name)"
assert_eq "and the email" "z@example.com" "$(HOME="$SANDBOX/inside" git config --global user.email)"

echo "template and none"
rm -f "$SANDBOX/args"
SAVE_TEMPLATE=1 write_git_identity
assert_eq "a template build sets no identity" "no" "$([[ -f "$SANDBOX/args" ]] && echo yes || echo no)"
GIT_NAME="" GIT_EMAIL=""
out="$(write_git_identity)"
assert_eq "with none, nothing is set" "no" "$([[ -f "$SANDBOX/args" ]] && echo yes || echo no)"
assert_contains "and it says how to set one" "git config --global user.name" "$out"
mv "$HOME/.gitconfig" "$HOME/.gitconfig.off"
capture "$SANDBOX/plain"
assert_eq "a host with no identity captures none" "" "$GIT_NAME$GIT_EMAIL"
prompt_git_identity
assert_eq "and off a terminal nothing is asked" "" "$GIT_NAME$GIT_EMAIL"

echo "GitHub Auth"
assert_eq "it no longer asks for a name or email" "no" \
  "$(grep -q -E 'GH_USER_(NAME|EMAIL)' "$REPO_ROOT/plugins/60-gh-auth.sh" && echo yes || echo no)"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
