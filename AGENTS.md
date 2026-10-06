# Working on AgentIncus

AgentIncus provisions Incus containers and VMs for coding agents. The host-side
scripts share container lifecycle, workspace, and plugin setup across agents.

- Keep shell code compatible with Bash 3.2 for macOS; avoid associative arrays.
- Coding agents are optional plugins. Declare `PLUGIN_AGENT_COMMAND` and keep
  shared provisioning independent of a particular agent.
- Install system packages using host-side `incus exec` as root. Install agent
  tools as the instance user without relying on sudo, so `--no-sudo` works.
- Never print credentials or interpolate them into remote shell commands.
- Run `bash -n` on changed shell files and the relevant scripts in `tests/`.
- Shared OpenSpec skills live in `.agents/skills/`; `.claude/skills` and
  `.grok/skills` link there for each agent's native discovery.
