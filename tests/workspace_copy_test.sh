#!/bin/bash
# tests/workspace_copy_test.sh
# The host directory is copied into the container once and never mounted.
# Runs the real copy_workspace from incus.init against the fake `incus`, and
# checks that the options for mounting are gone from the CLI.
# Run: bash tests/workspace_copy_test.sh

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
assert_not_contains() {
  if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); echo "  ok  $1"
  else FAIL=$((FAIL+1)); echo "  FAIL $1"; echo "    expected NOT to contain: $2"; fi
}

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin"
cp "$SCRIPT_DIR/lib/fake_incus" "$SANDBOX/bin/incus"
chmod +x "$SANDBOX/bin/incus"
export PATH="$SANDBOX/bin:$PATH"

extract_fn() {
  awk -v name="$1" '$0 ~ "^" name "\\(\\)" {c=1} c {print} c && /^}/ {exit}' "$REPO_ROOT/incus.init"
}
log()   { echo "[+] $1"; }
warn()  { echo "[!] $1"; }
error() { echo "[ERROR] $1" >&2; exit 1; }
eval "$(extract_fn copy_workspace)"
declare -F copy_workspace >/dev/null || { echo "copy_workspace not found in incus.init"; exit 1; }

# A host project: a git repo with a commit, an uncommitted edit and an
# untracked file, all of which should arrive.
HOST="$SANDBOX/project"
mkdir -p "$HOST"
git -C "$HOST" init -q
echo "committed" > "$HOST/README"
git -C "$HOST" add README
git -C "$HOST" -c user.name=t -c user.email=t@t commit -q -m first
echo "edited" > "$HOST/README"
echo "untracked" > "$HOST/notes.txt"

CONTAINER_NAME=box HOST_USER=dev BASE_IMAGE=images:ubuntu/24.04
CONTAINER_WORKSPACE=/workspace WORKSPACE_PATH="$HOST"
root()  { echo "$FAKE_INCUS_STATE/instances/box/root"; }
calls() { cat "$FAKE_INCUS_STATE/calls.log"; }
execs() { cat "$FAKE_INCUS_STATE/exec.log" 2>/dev/null || true; }
fresh_box() {
  export FAKE_INCUS_STATE="$SANDBOX/state-$RANDOM$RANDOM"
  mkdir -p "$FAKE_INCUS_STATE"
  incus launch images:ubuntu/24.04 box
  SAVE_TEMPLATE=0 NO_COPY=0 FROM_BASE_IMAGE=0
}
# copy_workspace ends in error() on a bad state, so run it in a subshell.
copy() { ( copy_workspace ) > "$SANDBOX/out" 2>&1 && RC=0 || RC=$?; OUT="$(cat "$SANDBOX/out")"; }

# ===========================================================================
echo "a fresh container"
# ===========================================================================
fresh_box
copy
assert_eq "copy: succeeds" "0" "$RC"
assert_eq "copy: uncommitted edits arrive" "edited" "$(cat "$(root)/workspace/README" 2>/dev/null)"
assert_eq "copy: …still uncommitted in the copy" " M README" "$(git -C "$(root)/workspace" status --porcelain README)"
assert_eq "copy: the commit arrives" "first" "$(git -C "$(root)/workspace" log -1 --format=%s)"
assert_eq "copy: untracked files arrive" "untracked" "$(cat "$(root)/workspace/notes.txt" 2>/dev/null)"
assert_eq "copy: .git arrives" "yes" "$([[ -f "$(root)/workspace/.git/HEAD" ]] && echo yes || echo no)"
assert_contains "copy: handed to the user" "box :: chown -R dev:dev /workspace" "$(execs)"
assert_contains "copy: says what it copies" "Copying $HOST into /workspace" "$OUT"
assert_not_contains "copy: nothing is mounted" "config device add" "$(calls)"
assert_contains "copy: git trusts the workspace" "safe.directory '/workspace'" "$(execs)"

# A different path inside the container.
fresh_box
CONTAINER_WORKSPACE=/src copy
assert_eq "--workspace: copies to that path" "edited" "$(cat "$(root)/src/README" 2>/dev/null)"

# ===========================================================================
echo "starting empty"
# ===========================================================================
fresh_box
NO_COPY=1 copy
assert_eq "--no-copy: succeeds" "0" "$RC"
assert_eq "--no-copy: the workspace exists" "yes" "$([[ -d "$(root)/workspace" ]] && echo yes || echo no)"
assert_eq "--no-copy: and is empty" "" "$(ls -A "$(root)/workspace")"
assert_not_contains "--no-copy: copies nothing" "Copying" "$OUT"

fresh_box
SAVE_TEMPLATE=1 copy
assert_eq "template build: the workspace is empty" "" "$(ls -A "$(root)/workspace")"

# ===========================================================================
echo "a workspace that already has files"
# ===========================================================================
fresh_box
mkdir -p "$(root)/workspace"; echo old > "$(root)/workspace/leftover"
FROM_BASE_IMAGE=1 copy
assert_eq "from a template: succeeds" "0" "$RC"
assert_contains "from a template: re-owns it" "box :: chown -R dev:dev /workspace" "$(execs)"
assert_eq "from a template: does not copy over it" "no" "$([[ -e "$(root)/workspace/README" ]] && echo yes || echo no)"

fresh_box
mkdir -p "$(root)/workspace"; echo old > "$(root)/workspace/leftover"
copy
assert_eq "not from a template: stops" "1" "$RC"
assert_contains "not from a template: says why" "is not empty inside the container" "$OUT"

# ===========================================================================
echo "Incus cannot be asked"
# ===========================================================================
fresh_box
FAKE_INCUS_FAIL_EXEC='test -d' copy
assert_eq "probe fails: stops" "1" "$RC"
assert_contains "probe fails: says why" "Could not check /workspace" "$OUT"
assert_eq "probe fails: copies nothing" "no" "$([[ -e "$(root)/workspace/README" ]] && echo yes || echo no)"

fresh_box
mkdir -p "$(root)/workspace"; echo old > "$(root)/workspace/leftover"
FAKE_INCUS_FAIL_EXEC='^ls -A' copy
assert_eq "listing fails: stops" "1" "$RC"
assert_contains "listing fails: says why" "Could not list /workspace" "$OUT"
assert_eq "listing fails: copies nothing over the files" "no" "$([[ -e "$(root)/workspace/README" ]] && echo yes || echo no)"

# ===========================================================================
echo "the CLI"
# ===========================================================================
help="$(bash "$REPO_ROOT/incus.init" --help 2>&1 || true)"
assert_contains "help: --path copies" "Host directory to copy in" "$help"
assert_contains "help: --workspace" "-w, --workspace PATH" "$help"
assert_contains "help: --no-copy is not VM-only" "Start with an empty workspace" "$help"
for gone in "--no-mount" "--git-rw" "--mount-path" "mount"; do
  assert_not_contains "help: no $gone" "$gone" "$help"
done
for flag in --no-mount --git-rw --mount-path; do
  out="$(bash "$REPO_ROOT/incus.init" "$flag" x box 2>&1)" && rc=0 || rc=$?
  assert_eq "$flag: rejected" "1" "$rc"
  assert_contains "$flag: as an unknown option" "Unknown option: $flag" "$out"
done

# --no-copy never touches the host path, so a missing one is fine.
for cmd in sudo curl; do printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/bin/$cmd"; chmod +x "$SANDBOX/bin/$cmd"; done
fresh_box
out="$(bash "$REPO_ROOT/incus.init" --no-tui --no-proxy --dry-run --no-copy --path "$SANDBOX/missing" fresh 2>&1)" && rc=0 || rc=$?
assert_eq "--no-copy with a missing --path: dry run succeeds" "0" "$rc"
assert_contains "--no-copy with a missing --path: empty workspace" "Workspace:   empty /workspace (--no-copy)" "$out"
out="$(bash "$REPO_ROOT/incus.init" --no-tui --no-proxy --dry-run --path "$SANDBOX/missing" fresh 2>&1)" && rc=0 || rc=$?
assert_eq "a missing --path is still an error when copying" "1" "$rc"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
