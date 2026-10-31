#!/bin/bash
# tests/names_test.sh
# Container names: HANDLE-AGENT-PROJECT with one agent (or shell), numbered
# -1, -2 when taken, labelled user.boxen=1 with the handle, agent and project;
# the handle asked for once and kept; and commands finding a container from
# its project. Builds against the fake `incus`, from a template so nothing is
# provisioned.
# Run: bash tests/names_test.sh

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
mkdir -p "$SANDBOX/bin" "$SANDBOX/repo/plugins" "$SANDBOX/ws"
cp "$SCRIPT_DIR/lib/fake_incus" "$SANDBOX/bin/incus"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/curl"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/git"
chmod +x "$SANDBOX/bin/"*
cp "$REPO_ROOT"/boxen.* "$REPO_ROOT"/bxn "$REPO_ROOT"/bxn.* "$SANDBOX/repo/"
# One agent, so the picker has something besides a shell.
cat > "$SANDBOX/repo/plugins/10-fake-agent.sh" <<'EOF'
PLUGIN_ID="fake-agent"; PLUGIN_NAME="Fake Agent"; PLUGIN_DESC="an agent"; PLUGIN_DEFAULT=0
PLUGIN_CLI_FLAGS="--fake"; PLUGIN_AGENT_COMMAND="fakeagent"
plugin_install() { :; }
EOF
echo hello > "$SANDBOX/ws/README"

export PATH="$SANDBOX/bin:$PATH"
export HOME="$SANDBOX/home"
export FAKE_INCUS_STATE="$SANDBOX/state"
export BOXEN_LOCK_DIR="$SANDBOX/state/lock"
export BOXEN_CONFIG_DIR="$SANDBOX/config"
mkdir -p "$FAKE_INCUS_STATE/images/incus-init/base/root"

build() { bash "$SANDBOX/repo/boxen.init" "$@" --from base --no-tui --egress off --insecure-network -p "$SANDBOX/ws" >"$SANDBOX/out" 2>&1 && RC=0 || RC=$?; }
built() { sed -n 's/^Container:   //p' "$SANDBOX/out" | head -1; grep -o 'Creating container: [^ ]*' "$SANDBOX/out" | cut -d' ' -f3; }
cfg() { cat "$FAKE_INCUS_STATE/instances/$1/config/$2" 2>/dev/null; }
exists() { [[ -d "$FAKE_INCUS_STATE/instances/$1" ]] && echo yes || echo no; }
names() { bash -c 'set -euo pipefail; log() { echo "[+] $1"; }; error() { echo "[ERROR] $1" >&2; exit 1; }
  source "$1/boxen.names"; eval "$2"' _ "$SANDBOX/repo" "$1"; }

echo "the handle"
assert_eq "none saved yet" "no" "$(names 'names_saved_handle >/dev/null && echo yes || echo no')"
h="$(names 'names_handle' 2>/dev/null)"
assert_eq "off a terminal it is the login name, made safe" "$(id -un | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')" "$h"
assert_eq "and it is kept" "$h" "$(cat "$BOXEN_CONFIG_DIR/handle")"
rm -f "$BOXEN_CONFIG_DIR/handle"
names 'names_handle --no-save' >/dev/null 2>&1
assert_eq "--no-save keeps nothing" "no" "$([[ -f "$BOXEN_CONFIG_DIR/handle" ]] && echo yes || echo no)"
assert_eq "BOXEN_HANDLE wins" "sam" "$(BOXEN_HANDLE=sam names 'names_handle')"
out="$(bash "$SANDBOX/repo/bxn" handle 'Bad-Name' 2>&1)" && rc=0 || rc=$?
assert_eq "a handle with a hyphen or capital is refused" "1" "$rc"
bash "$SANDBOX/repo/bxn" handle chad >/dev/null
assert_eq "bxn handle sets it" "chad" "$(cat "$BOXEN_CONFIG_DIR/handle")"
assert_eq "bxn handle shows it" "chad" "$(bash "$SANDBOX/repo/bxn" handle)"

echo "names and labels"
build web
assert_eq "a shell container is HANDLE-shell-PROJECT" "yes" "$(exists chad-shell-web)"
assert_eq "it is labelled for boxen" "1" "$(cfg chad-shell-web user.boxen)"
assert_eq "with its handle" "chad" "$(cfg chad-shell-web user.boxen.handle)"
assert_eq "its agent" "shell" "$(cfg chad-shell-web user.boxen.agent)"
assert_eq "and its project" "web" "$(cfg chad-shell-web user.boxen.project)"
build web
assert_eq "the next one for the project is numbered" "yes" "$(exists chad-shell-web-1)"
build web
assert_eq "and the one after that" "yes" "$(exists chad-shell-web-2)"
build web --agent fakeagent
assert_eq "an agent is in the name" "yes" "$(exists chad-fakeagent-web)"
assert_eq "and in its label" "fakeagent" "$(cfg chad-fakeagent-web user.boxen.agent)"
build web --agent fakeagent --agent shell
assert_eq "two agents are refused" "1" "$RC"
assert_contains "and it says why" "One agent per container" "$(cat "$SANDBOX/out")"
build anything --name exact-one
assert_eq "--name is used as given" "yes" "$(exists exact-one)"
assert_eq "still labelled" "1" "$(cfg exact-one user.boxen)"
assert_eq "without a project to be found by" "" "$(cfg exact-one user.boxen.project)"
build x --name exact-one
assert_eq "an exact name that is taken is refused" "1" "$RC"
long="$(printf 'p%.0s' $(seq 1 60))"
build "$long"
assert_contains "a name past 63 characters is refused" "longer than Incus allows" "$(cat "$SANDBOX/out")"

echo "finding a container"
assert_eq "an exact name is itself" "chad-shell-web-1" "$(names 'names_resolve chad-shell-web-1')"
assert_eq "AGENT-PROJECT finds the one container" "chad-fakeagent-web" "$(names 'names_resolve fakeagent-web')"
out="$(names 'names_resolve web' 2>&1)" && rc=0 || rc=$?
assert_eq "a project with several containers is refused" "1" "$rc"
assert_contains "and they are listed" "chad-shell-web" "$out"
assert_eq "an unknown name is passed on" "nope" "$(names 'names_resolve nope')"
build solo
assert_eq "a project with one container finds it" "chad-shell-solo" "$(names 'names_resolve solo')"
assert_eq "another handle's containers aren't found" "solo" "$(BOXEN_HANDLE=sam names 'names_resolve solo')"
bash "$SANDBOX/repo/bxn" -k fakeagent-web >/dev/null
assert_eq "bxn commands take the short form" "stop chad-fakeagent-web" "$(grep -E '^stop ' "$FAKE_INCUS_STATE/calls.log" | tail -1)"
bash "$SANDBOX/repo/bxn" egress ls fakeagent-web >/dev/null 2>&1 || true
assert_eq "so does bxn egress" "yes" "$(grep -q 'chad-fakeagent-web' "$FAKE_INCUS_STATE/calls.log" && echo yes || echo no)"
build fakeagent-web
assert_eq "a project named like AGENT-PROJECT" "yes" "$(exists chad-shell-fakeagent-web)"
out="$(names 'names_resolve fakeagent-web' 2>&1)" && rc=0 || rc=$?
assert_eq "is two containers: the project and the agent's" "1" "$rc"
assert_contains "and both are listed" "chad-fakeagent-web chad-shell-fakeagent-web" "$out"
incus delete --force chad-shell-fakeagent-web

echo "the agent picker"
if script -qec true /dev/null >/dev/null 2>&1; then
  pick() { { sleep 1.5; for k in "$@"; do printf '%b' "$k"; sleep 0.5; done; sleep 0.5; printf '\r'; sleep 1; } |
    TERM=xterm script -qec "bash '$SANDBOX/repo/boxen.init' pick --from base --egress off --insecure-network --dry-run -p '$SANDBOX/ws'" /dev/null | sed $'s/\033\\[[0-9;?]*[A-Za-z]//g; s/\r//g'; }
  out="$(pick)"
  assert_contains "it lists a shell and the agents" "Fake Agent" "$out"
  assert_contains "Enter on the first row is a shell" "Container:   chad-shell-pick" "$out"
  out="$(pick j)"
  assert_contains "j then Enter picks the agent" "Container:   chad-fakeagent-pick" "$out"
  assert_contains "and the dry run names it" "Agent:       Fake Agent" "$out"
else
  echo "  skip (needs util-linux script)"
fi

echo "templates"
build base2 -t
assert_eq "a template keeps the name it's given" "yes" "$(exists base2)"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
