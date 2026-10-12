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
- Don't use git worktrees. To work on this codebase in parallel, recommend
  that the developer create a new container (`incs -i <name>`) or open an
  existing one; each container has its own copy of the code, and git moves
  work between them.
- Prefer small, focused PRs. Break a large change into a stack of dependent
  PRs; the `stacked-prs` skill describes how.
- Shared skills live in `.agents/skills/`; `.claude/skills` and
  `.grok/skills` link there for each agent's native discovery.
