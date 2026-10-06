#!/bin/bash
# tests/git_guard_test.sh
# incus.init mounts .git/config and .git/hooks read-only on top of the
# workspace, so a process in the container cannot plant a command for the
# host's git to run. These tests run the real function against the fake
# `incus` and real repositories on disk.
# Run: bash tests/git_guard_test.sh

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

# The real function, lifted out of incus.init.
extract_fn() {
  awk -v name="$1" '$0 ~ "^" name "\\(\\)" {c=1} c {print} c && /^}/ {exit}' "$REPO_ROOT/incus.init"
}
log()  { echo "[+] $1"; }
warn() { echo "[!] $1"; }
eval "$(extract_fn guard_git_dir)"
declare -F guard_git_dir >/dev/null || { echo "guard_git_dir not found in incus.init"; exit 1; }

fresh_box() {
  export FAKE_INCUS_STATE="$SANDBOX/state-$RANDOM$RANDOM"
  mkdir -p "$FAKE_INCUS_STATE"
  incus launch images:ubuntu/24.04 box
}
# dev <device> <key>
dev() { cat "$FAKE_INCUS_STATE/instances/box/config/devices.$1.$2" 2>/dev/null || true; }
# How many read-only git mounts were added.
mounts() { ls "$FAKE_INCUS_STATE/instances/box/config" | grep -c '^devices\.git-ro-[0-9]*\.type$' || true; }
# All mounted container paths, one per line, in device order.
paths() {
  local f
  for f in $(ls "$FAKE_INCUS_STATE/instances/box/config" | grep '^devices\.git-ro-[0-9]*\.path$' | sort -t- -k3 -n); do
    cat "$FAKE_INCUS_STATE/instances/box/config/$f"; echo
  done
}
new_repo() { rm -rf "$1"; git init -q "$1"; }

# ===========================================================================
echo "a plain repository"
# ===========================================================================
fresh_box
W="$SANDBOX/repo"; new_repo "$W"
out="$(guard_git_dir box "$W" /workspace 2>&1)"
assert_eq "config and hooks are mounted, nothing else" "2" "$(mounts)"
assert_eq "config: source is the host file"       "$W/.git/config"      "$(dev git-ro-1 source)"
assert_eq "config: mounted at the container path" "/workspace/.git/config" "$(dev git-ro-1 path)"
assert_eq "config: read-only"                     "true"                "$(dev git-ro-1 readonly)"
assert_eq "config: not shifted, like the workspace" ""                  "$(dev git-ro-1 shift)"
assert_eq "config: a disk device"                 "disk"                "$(dev git-ro-1 type)"
assert_eq "hooks: source is the host directory"   "$W/.git/hooks"       "$(dev git-ro-2 source)"
assert_eq "hooks: mounted at the container path"  "/workspace/.git/hooks" "$(dev git-ro-2 path)"
assert_eq "hooks: read-only"                      "true"                "$(dev git-ro-2 readonly)"
assert_contains "says what it did" "read-only in the container (2 mounts" "$out"
assert_contains "names the way out" "--git-rw" "$out"

# A different mount point.
fresh_box
guard_git_dir box "$W" /src >/dev/null
assert_eq "honors the mount path" "/src/.git/config" "$(dev git-ro-1 path)"

# ===========================================================================
echo "a repository with no hooks directory"
# ===========================================================================
fresh_box
new_repo "$W"; rm -rf "$W/.git/hooks"
guard_git_dir box "$W" /workspace >/dev/null
assert_eq "hooks directory is created on the host" "yes" "$([[ -d "$W/.git/hooks" ]] && echo yes || echo no)"
assert_eq "…and mounted read-only, so the container cannot create it" "/workspace/.git/hooks" "$(dev git-ro-2 path)"

# ===========================================================================
echo "a worktree config"
# ===========================================================================
fresh_box
new_repo "$W"; touch "$W/.git/config.worktree"
guard_git_dir box "$W" /workspace >/dev/null
assert_eq "config.worktree is mounted too" "3" "$(mounts)"
assert_eq "…at its path" "/workspace/.git/config.worktree" "$(dev git-ro-3 path)"

# ===========================================================================
echo "submodules"
# ===========================================================================
fresh_box
new_repo "$W"
mkdir -p "$W/.git/modules/zeta" "$W/.git/modules/lib/alpha/hooks"
touch "$W/.git/modules/zeta/config" "$W/.git/modules/lib/alpha/config"
# A stray file named config somewhere that is not a gitdir must not matter
# beyond one harmless extra mount; objects never contain one in practice.
guard_git_dir box "$W" /workspace >/dev/null
assert_eq "each submodule gets config and hooks" "6" "$(mounts)"
assert_eq "paths, in a stable order" \
"/workspace/.git/config
/workspace/.git/hooks
/workspace/.git/modules/lib/alpha/config
/workspace/.git/modules/lib/alpha/hooks
/workspace/.git/modules/zeta/config
/workspace/.git/modules/zeta/hooks" "$(paths)"
assert_eq "a submodule without a hooks directory gets one" "yes" "$([[ -d "$W/.git/modules/zeta/hooks" ]] && echo yes || echo no)"

# ===========================================================================
echo "nothing to guard"
# ===========================================================================
fresh_box
rm -rf "$SANDBOX/plain"; mkdir -p "$SANDBOX/plain"
out="$(guard_git_dir box "$SANDBOX/plain" /workspace 2>&1)" && rc=0 || rc=$?
assert_eq "not a repository: succeeds" "0" "$rc"
assert_eq "not a repository: no mounts" "0" "$(mounts)"
assert_eq "not a repository: says nothing" "" "$out"

# A linked worktree: .git is a file naming a gitdir outside the mount.
fresh_box
rm -rf "$SANDBOX/wt"; mkdir -p "$SANDBOX/wt"
echo "gitdir: $W/.git/worktrees/wt" > "$SANDBOX/wt/.git"
out="$(guard_git_dir box "$SANDBOX/wt" /workspace 2>&1)" && rc=0 || rc=$?
assert_eq "linked worktree: succeeds" "0" "$rc"
assert_eq "linked worktree: no mounts" "0" "$(mounts)"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
