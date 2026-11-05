#!/bin/bash
# tests/repo_clone_test.sh
# `bxn create <project> <github-url>`: the workspace is a clone of the
# repository, made inside the container once the plugins are in. Nothing is
# copied from the host, and GitHub Auth is selected for its token.
# Runs boxen.init's dry run and its clone_repo against the fake `incus`, with
# a stand-in for git.
# Run: bash tests/repo_clone_test.sh

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
mkdir -p "$SANDBOX/bin" "$SANDBOX/data" "$SANDBOX/state"
cp "$SCRIPT_DIR/lib/fake_incus" "$SANDBOX/bin/incus"
printf '#!/bin/bash\necho "Unexpected sudo call" >&2\nexit 1\n' > "$SANDBOX/bin/sudo"
chmod +x "$SANDBOX/bin/incus" "$SANDBOX/bin/sudo"
export PATH="$SANDBOX/bin:$PATH"
export XDG_DATA_HOME="$SANDBOX/data" BOXEN_HANDLE=tester
export FAKE_INCUS_STATE="$SANDBOX/state"

# A host directory with a .env in it: copied, it would be warned about.
HOST="$SANDBOX/project"
mkdir -p "$HOST"
echo "SECRET=1" > "$HOST/.env"
TOKEN="github_pat_FAKE123"
# The dry run, from that directory, answering GitHub Auth's prompt.
dry_run() {
  (cd "$HOST" && printf '%s\n' "$TOKEN" | bash "$REPO_ROOT/boxen.init" --no-tui --dry-run "$@") > "$SANDBOX/out" 2>&1 && RC=0 || RC=$?
  OUT="$(cat "$SANDBOX/out")"
}

# ===========================================================================
echo "a repository URL"
# ===========================================================================
dry_run notes https://github.com/MixTapeSoftware/bxn
assert_eq "it's accepted" "0" "$RC"
assert_contains "the project names the container" "Container:   tester-shell-notes" "$OUT"
assert_contains "the workspace is a clone of it" \
  "Workspace:   clone https://github.com/MixTapeSoftware/bxn into /workspace" "$OUT"
assert_contains "GitHub Auth is selected" "[x] GitHub Auth" "$OUT"
assert_not_contains "the host directory isn't copied, so its .env isn't warned about" ".env" "$OUT"
assert_not_contains "the token isn't shown" "$TOKEN" "$OUT"

dry_run https://github.com/MixTapeSoftware/bxn notes
assert_contains "the URL can come first" \
  "Workspace:   clone https://github.com/MixTapeSoftware/bxn into /workspace" "$OUT"

dry_run notes https://github.com/MixTapeSoftware/bxn -w /src
assert_contains "--workspace says where the clone goes" \
  "Workspace:   clone https://github.com/MixTapeSoftware/bxn into /src" "$OUT"

# Every form GitHub hands out is the same repository, cloned over HTTPS.
for url in https://github.com/MixTapeSoftware/bxn.git https://github.com/MixTapeSoftware/bxn/ \
           git@github.com:MixTapeSoftware/bxn.git ssh://git@github.com/MixTapeSoftware/bxn.git \
           github.com/MixTapeSoftware/bxn https://www.github.com/MixTapeSoftware/bxn; do
  dry_run notes "$url"
  assert_contains "$url is cloned over HTTPS" \
    "Workspace:   clone https://github.com/MixTapeSoftware/bxn into /workspace" "$OUT"
done
dry_run notes https://github.com/some-one/my.dotted_repo-1
assert_contains "dots, underscores and hyphens in a repository's name" \
  "clone https://github.com/some-one/my.dotted_repo-1 into" "$OUT"

dry_run notes --ack-env
assert_contains "without one, the host directory is copied as before" "Workspace:   copy $HOST into /workspace" "$OUT"
assert_contains "and GitHub Auth is left alone" "[ ] GitHub Auth" "$OUT"

# ===========================================================================
echo "what isn't taken"
# ===========================================================================
for url in https://github.com/MixTapeSoftware/bxn/tree/main https://github.com/MixTapeSoftware \
           https://gitlab.com/a/b http://github.com/a/b https://github.com/a/.. 'https://github.com/a/b;id'; do
  dry_run notes "$url"
  assert_eq "$url: refused" "1" "$RC"
  assert_contains "$url: as not a GitHub repository" "Not a GitHub repository: $url" "$OUT"
done
dry_run notes "https://$TOKEN@github.com/a/b"
assert_eq "a URL with a token in it: refused" "1" "$RC"
assert_contains "and told where the token goes" "Leave credentials out of the repository URL" "$OUT"
assert_not_contains "without repeating the token" "$TOKEN" "$OUT"

dry_run notes https://github.com/a/b https://github.com/a/c
assert_contains "two repositories: refused" "Two repositories given" "$OUT"
dry_run notes https://github.com/a/b -p "$HOST"
assert_eq "with --path: refused" "1" "$RC"
assert_contains "one source for the workspace" "a workspace holds one" "$OUT"
dry_run notes https://github.com/a/b --template
assert_eq "with --template: refused" "1" "$RC"
assert_contains "a template's workspace is empty" "A template's workspace is empty" "$OUT"
dry_run https://github.com/a/b
assert_eq "a URL alone: refused" "1" "$RC"
assert_contains "the project still needs a name" "Project name required" "$OUT"

# ===========================================================================
echo "the clone"
# ===========================================================================
extract_fn() {
  awk -v name="$1" '$0 ~ "^" name "\\(\\)" {c=1} c {print} c && /^}/ {exit}' "$REPO_ROOT/boxen.init"
}
log()   { echo "[+] $1"; }
warn()  { echo "[!] $1"; }
error() { echo "[ERROR] $1" >&2; exit 1; }
for fn in clone_repo workspace_has_mise_config; do
  eval "$(extract_fn "$fn")"
  declare -F "$fn" >/dev/null || { echo "$fn not found in boxen.init"; exit 1; }
done

# git, as the user runs it in the container: it says where and how it was
# run, and clones a repository with a mise config unless told to fail.
GITBIN="$SANDBOX/gitbin"
mkdir -p "$GITBIN"
cat > "$GITBIN/git" <<EOF
#!/bin/sh
echo "\$PWD :: user=\$USER prompt=\${GIT_TERMINAL_PROMPT:-unset} :: git \$*" >> "$SANDBOX/git.log"
[ -f "$SANDBOX/git-fail" ] && { echo "fatal: repository not found" >&2; exit 128; }
mkdir .git && echo 'node = "22"' > mise.toml
EOF
chmod +x "$GITBIN/git"
PATH="$GITBIN:$PATH"

incus launch images:ubuntu/24.04 box
# The fake runs `su` commands on this machine, so the workspace is a real
# directory; its name has a space, as --workspace allows.
WS="$SANDBOX/the ws"
mkdir -p "$WS"
CONTAINER_NAME=box HOST_USER=dev CONTAINER_WORKSPACE="$WS"
printf -v WORKSPACE_Q '%q' "$WS"
SAVE_TEMPLATE=0 NO_COPY=1 WORKSPACE_PATH="$HOST"
REPO_URL=https://github.com/MixTapeSoftware/bxn REPO_CLONED=0

# Not in a subshell: it records whether the clone worked.
clone_repo > "$SANDBOX/out" 2>&1
OUT="$(cat "$SANDBOX/out")"
assert_contains "says what it clones, and where" "Cloning $REPO_URL into $WS" "$OUT"
assert_eq "as the user, in the workspace, into it, never waiting at a prompt" \
  "$WS :: user=dev prompt=0 :: git clone $REPO_URL ." "$(tail -n 1 "$SANDBOX/git.log")"
assert_eq "the repository is in the workspace" "yes" "$([[ -d "$WS/.git" ]] && echo yes || echo no)"
assert_eq "and the build knows it" "1" "$REPO_CLONED"
workspace_has_mise_config && has=yes || has=no
assert_eq "the clone's mise config is installed from" "yes" "$has"
rm "$WS/mise.toml"
workspace_has_mise_config && has=yes || has=no
assert_eq "not when the clone has none" "no" "$has"

rm -rf "$WS/.git"
touch "$SANDBOX/git-fail" "$WS/mise.toml"
REPO_CLONED=0
clone_repo > "$SANDBOX/out" 2>&1 && RC=0 || RC=$?
OUT="$(cat "$SANDBOX/out")"
assert_eq "a clone that fails doesn't stop the build" "0" "$RC"
assert_contains "it says so, with the command to try again" \
  "Could not clone $REPO_URL: box has an empty workspace. Once the cause is fixed: bxn box 'git clone $REPO_URL .'" "$OUT"
assert_eq "and the build knows that too" "0" "$REPO_CLONED"
workspace_has_mise_config && has=yes || has=no
assert_eq "nothing is installed from a workspace that didn't clone" "no" "$has"

# The host directory's mise config counts only when it was copied in.
REPO_URL="" NO_COPY=0
echo 'node = "22"' > "$HOST/mise.toml"
workspace_has_mise_config && has=yes || has=no
assert_eq "a copied workspace: the host's mise config counts" "yes" "$has"
NO_COPY=1
workspace_has_mise_config && has=yes || has=no
assert_eq "--no-copy: it doesn't" "no" "$has"

# No test runs a whole build, so the order is read from the script: the clone
# comes after every plugin install (GitHub Auth among them) and before the
# workspace's mise install.
line_of() { grep -n -F -- "$1" "$REPO_ROOT/boxen.init" | tail -n 1 | cut -d: -f1; }
installs="$(line_of '_run_plugin_installs "$FROM_BASE_IMAGE"')"
clone="$(line_of '|| clone_repo')"
mise="$(line_of 'if workspace_has_mise_config; then')"
assert_eq "the build clones after the plugins are installed" "yes" \
  "$([[ -n "$installs" && -n "$clone" && "$installs" -lt "$clone" ]] && echo yes || echo no)"
assert_eq "and before it installs from the workspace's mise config" "yes" \
  "$([[ -n "$clone" && -n "$mise" && "$clone" -lt "$mise" ]] && echo yes || echo no)"

# ===========================================================================
echo "the help"
# ===========================================================================
help="$(bash "$REPO_ROOT/boxen.init" --help 2>&1 || true)"
assert_contains "create takes a URL" "bxn create [OPTIONS] <project> [<github-url>]" "$help"
assert_contains "and says what it does with it" "a clone of it, made inside the container" "$help"
assert_contains "bxn's own help shows it" "bxn create web https://github.com/OWNER/REPO" "$(bash "$REPO_ROOT/bxn" --help 2>&1 || true)"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
