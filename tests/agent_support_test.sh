#!/bin/bash
# Exercise agent selection, discovery overrides, launch guidance, and shell defaults.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/data/boxen/plugins"
export XDG_DATA_HOME="$fixture/data"
cat > "$fixture/bin/incus" <<'INCUS'
#!/bin/bash
case "$1" in
  # A 64GiB host, so the VM dry runs don't depend on the runner's memory:
  # through the resources API where there's jq, else from incus info.
  info) [[ "${2:-}" == --resources ]] || exit 1
        printf 'Memory:\n  Total: 64.00GiB\n' ;;
  query) [[ "$2" == /1.0/resources ]] && printf '{"memory": {"total": 68719476736}}\n' ;;
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
export BOXEN_HANDLE=tester
dry_run() { bash "$REPO_ROOT/boxen.init" audit --no-tui --vm --no-copy --dry-run "$@"; }

# One agent per container, built into its name.
for pair in 'claude:Claude Code' 'codex:Codex' 'grok:Grok Build'; do
  out="$(dry_run --agent "${pair%%:*}")"
  assert_contains "select ${pair#*:}" "Agent:       ${pair#*:}" "$out"
  assert_contains "${pair#*:} is in the name" "Container:   tester-${pair%%:*}-audit" "$out"
done
out="$(dry_run --claude)"
assert_contains 'an agent flag chooses it' 'Agent:       Claude Code' "$out"
out="$(dry_run --agent grokbot)"
assert_contains 'Grokbot alias' 'Agent:       Grok Build' "$out"
out="$(dry_run --agent claude --claude)"
assert_contains 'naming the same agent twice is fine' 'Agent:       Claude Code' "$out"
out="$(dry_run)"
assert_contains 'with no agent chosen it is a shell' 'Agent:       Shell (no agent)' "$out"
assert_contains 'and the name says shell' 'Container:   tester-shell-audit' "$out"
out="$(dry_run --agent shell)"
assert_contains '--agent shell chooses none' 'Container:   tester-shell-audit' "$out"
for agent in 'Claude Code' Codex 'Grok Build'; do
  assert_absent "$agent isn't in the plugin list" "] $agent" "$out"
done
if out="$(dry_run --agent claude --agent codex 2>&1)"; then echo 'FAIL: two agents accepted'; exit 1; fi
assert_contains 'two agents are refused' 'One agent per container: Claude Code and Codex' "$out"
if out="$(dry_run --claude --grokbot 2>&1)"; then echo 'FAIL: two agent flags accepted'; exit 1; fi
assert_contains 'two agent flags are refused' 'One agent per container' "$out"
if out="$(dry_run --agent claude --agent shell 2>&1)"; then echo 'FAIL: agent and shell accepted'; exit 1; fi
assert_contains 'an agent and a shell are refused' 'One agent per container' "$out"
if out="$(dry_run --agent nonexistent 2>&1)"; then echo 'FAIL: unknown agent accepted'; exit 1; fi
assert_contains 'unknown agent error' 'Unknown coding agent: nonexistent' "$out"
if out="$(dry_run --agent docker 2>&1)"; then echo 'FAIL: non-agent accepted'; exit 1; fi
assert_contains 'reject non-agent plugin' 'Unknown coding agent: docker' "$out"
if out="$(dry_run --agent 2>&1)"; then echo 'FAIL: missing agent accepted'; exit 1; fi
assert_contains 'missing argument' '--agent requires an argument' "$out"

# A user agent without optional flags exercises empty metadata fields and sorting.
cat > "$XDG_DATA_HOME/boxen/plugins/00-extra.sh" <<'EXTRA'
PLUGIN_ID="extra"
PLUGIN_NAME="AAA Extra Agent"
PLUGIN_DESC="Test custom agent"
PLUGIN_DEFAULT=0
PLUGIN_AGENT_COMMAND="extra-cli"
EXTRA
out="$(dry_run --agent extra-cli)"
assert_contains 'discover user agent executable' 'Agent:       AAA Extra Agent' "$out"
assert_contains 'its command names the container' 'Container:   tester-extra-cli-audit' "$out"
out="$(dry_run --agent extra)"
assert_contains 'discover user agent ID' 'Agent:       AAA Extra Agent' "$out"

# User overrides replace agent metadata instead of inheriting the built-in's.
cat > "$XDG_DATA_HOME/boxen/plugins/50-codex.sh" <<'OVERRIDE'
PLUGIN_ID="codex"
PLUGIN_NAME="Custom Codex Tool"
PLUGIN_DESC="A non-agent override"
PLUGIN_DEFAULT=0
OVERRIDE
if out="$(dry_run --agent codex 2>&1)"; then echo 'FAIL: inherited agent metadata'; exit 1; fi
assert_contains 'override clears agent metadata' 'Unknown coding agent: codex' "$out"
if out="$(dry_run --codex 2>&1)"; then echo 'FAIL: inherited built-in CLI flag'; exit 1; fi
assert_contains 'override removes built-in CLI flag' 'Unknown option: --codex' "$out"
out="$(dry_run --claude)"
assert_contains 'override preserves other Claude flags' 'Agent:       Claude Code' "$out"
out="$(dry_run --grok)"
assert_contains 'override preserves other Grok flags' 'Agent:       Grok Build' "$out"

cat > "$XDG_DATA_HOME/boxen/plugins/50-grok.sh" <<'OVERRIDE'
PLUGIN_ID="grok"
PLUGIN_NAME="Custom Grok Agent"
PLUGIN_DESC="A replacement agent with its own alias"
PLUGIN_DEFAULT=0
PLUGIN_CLI_FLAGS="--custom-grok"
PLUGIN_AGENT_COMMAND="custom-grok-cli"
OVERRIDE
out="$(dry_run --custom-grok)"
assert_contains 'override registers replacement flags' 'Agent:       Custom Grok Agent' "$out"
out="$(dry_run --agent custom-grok)"
assert_contains 'replacement flags select replacement agents' 'Agent:       Custom Grok Agent' "$out"
if out="$(dry_run --agent grokbot 2>&1)"; then echo 'FAIL: inherited built-in agent alias'; exit 1; fi
assert_contains 'override removes built-in agent alias' 'Unknown coding agent: grokbot' "$out"

# Run the summary helper with multiple agents and an install failure.
eval "$(awk '/^print_agent_launches\(\)/ {capture=1} capture {print} capture && /^}/ {exit}' "$REPO_ROOT/boxen.init")"
PLUGIN_COUNT=3
_P_SELECTED=(1 1 1)
_P_ID=(claude-code codex grok)
_P_AGENT_COMMAND=(claude codex grok)
_P_NAME=('Claude Code' Codex 'Grok Build')
eval "$(awk '/^_plugin_failed\(\)/ {capture=1} capture {print} capture && /^}/ {exit}' "$REPO_ROOT/boxen.init")"
FAILED_PLUGIN_IDS=(codex)
FAILED_PLUGIN_NAMES=(Codex)
CONTAINER_NAME=audit CONTAINER_WORKSPACE='/work tree'
out="$(print_agent_launches)"
assert_contains 'launch Claude' 'Start Claude Code:' "$out"
assert_contains 'launch Grok' 'Start Grok Build:' "$out"
assert_absent 'failed agents get no launch command' 'Start Codex:' "$out"
# Replay a printed command through a harmless bxn function to check quoting.
bxn() { printf 'launch_arg=%s\n' "$3"; }
line="$(printf '%s\n' "$out" | sed -n '2p')"
out="$(eval "$line")"
assert_contains 'launch command quotes custom workspace' 'launch_arg=cd /work\ tree && claude' "$out"

# A distinct failed plugin sharing an agent's label must not hide its launch.
FAILED_PLUGIN_IDS=(other-claude)
FAILED_PLUGIN_NAMES=('Claude Code')
out="$(print_agent_launches)"
assert_contains 'duplicate display name keeps successful agent launch' 'Start Claude Code:' "$out"
assert_contains 'previously failed agent now launches after reset' 'Start Codex:' "$out"

out="$(BOXEN_CONTAINER=generic CLAUDE_CONTAINER=legacy bash "$REPO_ROOT/boxen.shell")"
assert_contains 'generic default instance' 'instance=generic' "$out"
out="$(BOXEN_CONTAINER=generic CLAUDE_CONTAINER=legacy bash "$REPO_ROOT/boxen.shell" explicit)"
assert_contains 'explicit instance wins' 'instance=explicit' "$out"
out="$(BOXEN_CONTAINER='' CLAUDE_CONTAINER=legacy bash "$REPO_ROOT/boxen.shell")"
assert_contains 'legacy default still works' 'instance=legacy' "$out"

for agent_dir in .agents .claude .grok; do
  [[ -f "$REPO_ROOT/$agent_dir/skills/botfight/SKILL.md" ]] || {
    echo "FAIL: skills unavailable to $agent_dir"; exit 1;
  }
  PASS=$((PASS+1))
done
printf 'Passed: %s\n' "$PASS"
