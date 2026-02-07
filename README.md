# AgentIncus

AgentIncus, inspired by [Code in Incus (COI)](https://github.com/mensfeld/code-on-incus), is a set of shell scripts that automate the creation of [Incus](https://linuxcontainers.org/incus/) containers for AI agents and secure development. See COI's [Why Incus](https://github.com/mensfeld/code-on-incus?tab=readme-ov-file#why-incus-over-docker) for why Incus over Docker.

Why shell scripts? They introduce no dependencies, are ergonomic enough for simple systems administration tasks, and transparently convey their purpose. They're meant to be copied and tailored to your needs.

## Prerequisites

- [Incus](https://linuxcontainers.org/incus/docs/main/installing/) installed and initialized (`incus admin init`)
- `~/.local/bin` in your `PATH`

## Install

```bash
git clone <repo-url> agentincus
cd agentincus
./incus_agent_init.sh
```

This symlinks the helper scripts into `~/.local/bin`.

## Scripts

| Script | Purpose |
|---|---|
| `incus.init` | Create and provision a container |
| `incus.shell` | Open a login shell (or run a command) in a container |
| `incus_agent_init.sh` | Install script (symlinks helpers to `~/.local/bin`) |

## Quick Start

```bash
# Create a container with the current directory mounted as /workspace
incus.init my-project

# Open a shell
incus.shell my-project

# Run a command (e.g. Claude Code)
incus.shell my-project claude
```

## incus.init Options

```
Usage: incus.init [OPTIONS] <container-name>

Options:
  -p, --path PATH           Host directory to mount (default: current directory)
  -m, --mount-path PATH     Container mount point (default: /workspace)
  -i, --image IMAGE         Base image override
  --ubuntu                  Use Ubuntu 24.04 instead of Alpine 3.23
  --docker                  Install Docker inside the container
  --proxy                   Enable HTTP(S) proxy env vars
  --proxy-port PORT         Required when --proxy is set
  --proxy-ip IP             Proxy IP override (default: container gateway)
  --1pass                   Install 1Password CLI (prompts for service account token)
  --dry-run                 Show what would be done without doing it
```

### What incus.init does

1. Launches an Alpine 3.23 container (or Ubuntu 24.04 with `--ubuntu`)
2. Installs build tools, dev libraries, Python, and Node.js
3. Creates a user matching your host UID/GID with passwordless sudo
4. Mounts your host directory into the container (tries `shift=true`, falls back to `raw.idmap`)
5. Installs vim, neovim, Oh My Zsh, mise (runtime version manager), fzf, bat, and Claude Code
6. Optionally installs Docker, 1Password CLI, and/or proxy configuration

## The Development Workflow

A recommended setup uses two containers sharing the same workspace:

```
 Host (your machine)
 ├── Editor open on ./project
 ├── Git credentials stay here
 │
 ├── Agent Container (Alpine, minimal)
 │   ├── Claude Code + API key only
 │   ├── No other credentials
 │   └── /workspace ──┐
 │                     ├── shared directory
 └── Dev Container (Ubuntu, full)
     ├── API keys, dev tools, Docker
     ├── Port forwarded to host
     └── /workspace ──┘
```

```bash
# Agent container — lean, no sensitive env vars
incus.init project-agent

# Dev container — API keys, Docker, 1Password
incus.init --ubuntu --docker --1pass project-dev
```

The host, agent, and dev containers all read and write the same `/workspace` directory. Your editor, the AI agent, and your dev tools all see the same files.

### Expose Container Ports

Forward a port from a container to your host:

```bash
incus config device add project-dev web proxy \
  listen=tcp:0.0.0.0:4000 \
  connect=tcp:127.0.0.1:4000
```

### Snapshots

Capture environment state for rollback:

```bash
incus snapshot project-dev before-refactor
incus restore project-dev before-refactor
incus info project-dev   # list snapshots
```

## Runtime Management

Containers come with [mise](https://mise.jdx.dev/) pre-installed. Install runtimes per-project:

```bash
cd /workspace
mise use python@3.12 node@20
```

Or add a `mise.toml` to your project — `incus.init` runs `mise install` automatically if one exists.
