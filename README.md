# AgentIncus (Experimental)

AgentIncus, inspired by [Code in Incus (COI)](https://github.com/mensfeld/code-on-incus), is a set of shell scripts that automate the creation of [Incus](https://linuxcontainers.org/incus/) containers for AI agents and secure development. See COI's [Why Incus](https://github.com/mensfeld/code-on-incus?tab=readme-ov-file#why-incus-over-docker) for why Incus over Docker.

Why shell scripts? They introduce no dependencies, are ergonomic enough for simple systems administration tasks, and transparently convey their purpose. They're meant to be copied and tailored to your needs.

## Prerequisites

- Linux (Incus requires a Linux host; on macOS see [Incus on macOS with Colima](https://discuss.linuxcontainers.org/t/easy-way-to-try-incus-on-macos-with-colima/21153))
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
| `incus_agent_init.sh` | Symlink helpers into `~/.local/bin` |

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
  --dev-tools               Install Oh My Zsh, fzf, bat, and shell aliases
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
5. Installs mise (runtime version manager) and Claude Code
6. With `--dev-tools`: adds Oh My Zsh, fzf, bat, and shell aliases
7. Optionally installs Docker, 1Password CLI, and/or proxy configuration

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
# Agent container — lean, secure default
incus.init project-agent

# Dev container — the works
incus.init --ubuntu --docker --1pass --dev-tools project-dev
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

## Firewall (UFW)

If UFW is enabled on the host, its default DROP policy will block traffic on the Incus bridge. See the [Incus firewall documentation](https://linuxcontainers.org/incus/docs/main/howto/network_bridge_firewalld/#ufw-add-rules-for-the-bridge) for setup instructions. The things you'll need to allow:

- **DHCP + DNS** — containers need these to get an IP address and resolve names
- **Outbound forwarding** — containers need a route through the host to reach the internet. If you use `--proxy`, the proxy port on the host must also accept connections from the bridge
- **Inbound dev ports** — if you [expose a container port](#expose-container-ports) (e.g. a web app on 4000), the port must also be allowed through UFW

### IPv6 gotcha

If your host doesn't have IPv6 internet, [disable it on the bridge](https://linuxcontainers.org/incus/docs/main/reference/network_bridge/):

```bash
incus network set incusbr0 ipv6.address none
```

Without this, containers get an IPv6 address from Incus and prefer it (per RFC 6724). The symptom is confusing: `ping` works (resolves to IPv4) but `apt-get update` hangs trying to reach mirrors over IPv6.
