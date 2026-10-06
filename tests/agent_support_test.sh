#!/bin/bash
# Exercise agent selection, discovery overrides, launch guidance, and shell defaults.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/data/agent_incus/plugins"
export XDG_DATA_HOME="$fixture/data"
cat > "$fixture/bin/incus" <<'INCUS'
#!/bin/bash
case "$1" in
  info) exit 1 ;;
  list) printf 'RUNNING\n' ;;
  exec)
    case "$*" in
      *' -- id -G '*) printf '1000\n' ;;
      *) printf 'instance=%s\n' "$2" ;;
    esac ;;
  *) echo "Unexpected incus call: $*" >&2; exit 1 ;;
esac
INCUS
cat > "$fixture/bin/sudo" <<'SUDO'
#!/bin/bash
echo 'Unexpected sudo call' >&2
exit 1
SUDO
chmod +x "$fixture/bin/incus" "$fixture/bin/sudo"
export PATH="$fixture/bin:$PATH"
PASS=0
assert_contains() {
  [[ "$3" == *"$2"* ]] || { printf 'FAIL: %s\n%s\n' "$1" "$3"; exit 1; }
  PASS=$((PASS+1))
}
assert_absent() {
  [[ "$3" != *"$2"* ]] || { printf 'FAIL: %s\n%s\n' "$1" "$3"; exit 1; }
  PASS=$((PASS+1))
}
dry_run() { bash "$REPO_ROOT/incus.init" audit --no-tui --vm --no-copy --dry-run "$@"; }

out="$(dry_run --agent claude --agent codex --agent grok)"
for agent in 'Claude Code' Codex 'Grok Build'; do
  assert_contains "select $agent" "[x] $agent" "$out"
done
out="$(dry_run --claude --codex --grokbot)"
for agent in 'Claude Code' Codex 'Grok Build'; do
  assert_contains "flag for $agent" "[x] $agent" "$out"
done
out="$(dry_run --agent grokbot)"
assert_contains 'Grokbot alias' '[x] Grok Build' "$out"
out="$(dry_run)"
for agent in 'Claude Code' Codex 'Grok Build'; do
  assert_contains "$agent stays optional" "[ ] $agent" "$out"
done
if out="$(dry_run --agent nonexistent 2>&1)"; then echo 'FAIL: unknown agent accepted'; exit 1; fi
assert_contains 'unknown agent error' 'Unknown coding agent: nonexistent' "$out"
if out="$(dry_run --agent docker 2>&1)"; then echo 'FAIL: non-agent accepted'; exit 1; fi
assert_contains 'reject non-agent plugin' 'Unknown coding agent: docker' "$out"
if out="$(dry_run --agent 2>&1)"; then echo 'FAIL: missing agent accepted'; exit 1; fi
assert_contains 'missing argument' '--agent requires an argument' "$out"

# A user agent without optional flags exercises empty metadata fields and sorting.
cat > "$XDG_DATA_HOME/agent_incus/plugins/00-extra.sh" <<'EXTRA'
PLUGIN_ID="extra"
PLUGIN_NAME="AAA Extra Agent"
PLUGIN_DESC="Test custom agent"
PLUGIN_DEFAULT=0
PLUGIN_AGENT_COMMAND="extra-cli"
EXTRA
out="$(dry_run --agent extra-cli)"
assert_contains 'discover user agent executable' '[x] AAA Extra Agent' "$out"
out="$(dry_run --agent extra)"
assert_contains 'discover user agent ID' '[x] AAA Extra Agent' "$out"

# User overrides replace agent metadata instead of inheriting the built-in's.
cat > "$XDG_DATA_HOME/agent_incus/plugins/50-codex.sh" <<'OVERRIDE'
PLUGIN_ID="codex"
PLUGIN_NAME="Custom Codex Tool"
PLUGIN_DESC="A non-agent override"
PLUGIN_DEFAULT=0
OVERRIDE
if out="$(dry_run --agent codex 2>&1)"; then echo 'FAIL: inherited agent metadata'; exit 1; fi
assert_contains 'override clears agent metadata' 'Unknown coding agent: codex' "$out"

# Run the summary helper with multiple agents and an install failure.
eval "$(awk '/^print_agent_launches\(\)/ {capture=1} capture {print} capture && /^}/ {exit}' "$REPO_ROOT/incus.init")"
PLUGIN_COUNT=3
_P_SELECTED=(1 1 1)
_P_AGENT_COMMAND=(claude codex grok)
_P_NAME=('Claude Code' Codex 'Grok Build')
_plugin_failed() { [[ "$1" == Codex ]]; }
CONTAINER_NAME=audit MOUNT_PATH='/work tree'
out="$(print_agent_launches)"
assert_contains 'launch Claude' 'Start Claude Code:' "$out"
assert_contains 'launch Grok' 'Start Grok Build:' "$out"
assert_absent 'failed agents get no launch command' 'Start Codex:' "$out"
# Replay a printed command through a harmless incs function to check quoting.
incs() { printf 'launch_arg=%s\n' "$3"; }
line="$(printf '%s\n' "$out" | sed -n '2p')"
out="$(eval "$line")"
assert_contains 'launch command quotes custom workspace' 'launch_arg=cd /work\ tree && claude' "$out"

out="$(INCS_CONTAINER=generic CLAUDE_CONTAINER=legacy bash "$REPO_ROOT/incus.shell")"
assert_contains 'generic default instance' 'instance=generic' "$out"
out="$(INCS_CONTAINER=generic CLAUDE_CONTAINER=legacy bash "$REPO_ROOT/incus.shell" explicit)"
assert_contains 'explicit instance wins' 'instance=explicit' "$out"
out="$(INCS_CONTAINER='' CLAUDE_CONTAINER=legacy bash "$REPO_ROOT/incus.shell")"
assert_contains 'legacy default still works' 'instance=legacy' "$out"

for agent_dir in .agents .claude .grok; do
  [[ -f "$REPO_ROOT/$agent_dir/skills/openspec-apply-change/SKILL.md" ]] || {
    echo "FAIL: skills unavailable to $agent_dir"; exit 1;
  }
  PASS=$((PASS+1))
done
printf 'Passed: %s\n' "$PASS"
