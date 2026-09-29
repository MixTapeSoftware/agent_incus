# Credential proxy — design

## Problem

A GitHub token placed in a container can be read by anything running there,
including an AI agent that has been prompted into looking for it. Today the
GitHub Auth plugin writes the real token into `~/.zshenv` and the Incus
environment. The goal is that an agent container never holds a real
credential. Restricting which sites a container can reach is a secondary goal
and is out of scope here.

## Decision

A credential proxy runs in its own Incus container. Agent containers hold a
random **placeholder**; the proxy swaps it for the real token on the way to
the upstream host. The proxy is [iron-proxy](https://github.com/paradigmxyz/iron-proxy),
pinned by version and checksum.

Two capabilities, as requested:

1. **Create a proxy** (`incs proxy new`). More than one can exist, because a
   proxy process reads a single 1Password service account token. Separate
   1Password accounts therefore need separate proxies.
2. **Attach a container to a proxy** (`incs proxy add`, or `incs -i --proxy`).

Alternatives considered and rejected:

- **Adopting coi.** It has no credential swapping, and its network model
  gives up the tagged Tailscale node per container.
- **Caddy or Tailscale Aperture.** Both are stand-in servers. Each tool must
  be repointed at them, and neither can carry `git` or the `gh` CLI.
- **Writing a proxy in Go.** iron-proxy already does header, body, and
  basic-auth swapping with per-host binding. An earlier attempt
  (`agent_proxy`, mitmproxy) was a filter only.
- **Enforced or transparent capture** (nftables redirect, TPROXY). It would
  intercept tailscaled's control and relay connections, which switch to a
  custom protocol and are likely to break. Enforcement only buys the site
  allowlist, which is the secondary goal.
- **Running the proxy on the host.** A container isolates the component that
  parses agent-controlled traffic, and gives it its own address on the bridge.

## Capture model: unenforced

Attach writes `HTTPS_PROXY` and friends to the container user's `~/.zshenv`
only. A process can ignore them. That is safe for credentials: a request that
skips the proxy carries the placeholder, which the upstream rejects.

The Incus environment receives only `GH_TOKEN` (the placeholder), because it
must overwrite any real token the GitHub Auth plugin left there. Proxy
settings are deliberately kept out of it, so root sessions (`incs -u`,
nightly updates) and daemons (tailscaled, dockerd) connect directly.

## Layout

`incus.proxy` is both the `incs proxy` command and a sourceable library
(`proxy_attach` and friends), following the sibling-file pattern of
`incus.network` and `incus.envscan`.

Inside a proxy container:

| Path | Purpose |
|---|---|
| `/etc/iron-proxy/base.yaml` | Config up to the empty `secrets:` list |
| `/etc/iron-proxy/entries/<container>--<service>.yaml` | One list item per attachment |
| `/etc/iron-proxy/tokens/<container>--<service>` | Real token, `--token` mode only |
| `/etc/iron-proxy/proxy.yaml` | Built by `iron-rebuild`: base plus all entries |
| `/etc/iron-proxy/env` | Service account token, mode 0600 |
| `/etc/iron-proxy/ca.{crt,key}` | This proxy's certificate authority |

State is kept in Incus config, not in files on the host:

| Key | On | Meaning |
|---|---|---|
| `user.incs.role=proxy` | proxy | Identifies a proxy |
| `user.incs.proxy-ip` | proxy | Pinned address |
| `user.incs.proxy-vault` | proxy | Default vault for references |
| `user.incs.proxy-1password` | proxy | Whether a service account was given |
| `user.incs.proxy` | agent container | Name of the proxy it is attached to |

Proxies are **not** tagged `user.managed-by=agent-incus`, so `incs -ka` and
`incs -ua` skip them without any change to those commands.

## Decisions worth recording

- **Address pinning.** `proxy new` starts the container, reads the address the
  bridge leased, stops it, and pins that address with a device override. No
  address has to be chosen by hand. Container DNS names are avoided because
  Tailscale can take over name resolution inside agent containers.
- **Pasted values are cleaned.** Terminals can wrap a paste in escape
  sequences the user never sees: focus reporting (`ESC [ O`, `ESC [ I`) and
  bracketed paste. A token saved with them fails with a bare 401, and a
  reference with them would make the proxy config unparseable. `incus.prompt`
  provides `read_secret` and `read_value`, which strip them; every prompt that
  takes a pasted value uses them, including the existing GitHub Auth,
  1Password, and Tailscale plugins and `incs -e`.
- **Secrets never travel in argv.** The service account token and `--token`
  values are pushed over stdin with `incus file push -`.
- **Tag before registering.** Attach sets `user.incs.proxy` before it touches
  the proxy, so a failure partway through can be undone with `incs proxy rm`.
- **Failed `proxy new` cleans up.** A half-built proxy holds a secret and is
  removed.
- **GitHub Auth conflict.** The plugin is named "Credential Proxy" so that it
  sorts, prompts, and installs before "GitHub Auth", and it deselects GitHub
  Auth in its prompt. Otherwise GitHub Auth would overwrite the placeholder
  with a real token.
- **Templates.** `save_template` strips lines marked `# incs-proxy` along with
  the token lines, then restores them to the running container. The plugin
  sets `PLUGIN_NEEDS_PROMPT=1`, so a template launch re-runs the attach and
  each container gets its own placeholder.
- **Errexit in cleanup loops.** `proxy_try` records a step's status in a
  variable instead of being used as a condition. Bash ignores `set -e` for
  everything run inside an `if` or `&&` condition, even a subshell that sets
  it again, so a failure partway through would otherwise be masked.
- **`incs` resolves its own symlink.** `install_shortcuts` links `incs` into
  `~/.local/bin`. Without resolving the link, `incs -d` could not find
  `incus.proxy` for anyone who installed before this change.
- **Changes restart the service.** Attach and detach rebuild the config and
  restart iron-proxy, which drops connections in flight for every container
  on that proxy. The management reload API would avoid this but needs its own
  key; not worth it yet.
- **Provisioning runs through the proxy.** Plugins sorted after "Credential
  Proxy", and the `mise install` step, run as the user through `su -`, which
  reads `~/.zshenv`. Verified in Docker that git, curl, mise, npm, pip, Node
  fetch, and Python urllib all work through the proxy with the variables
  attach sets.
- **`require: true` is not used.** It rejects requests to a bound host that
  lack the placeholder. git's first request is unauthenticated, so it would
  likely break git. Untested.

## Known limitations

- Responses are not scrubbed. An upstream that echoes request headers would
  reveal the real token. GitHub does not; take care before binding other hosts.
- iron-proxy intercepts every HTTPS connection sent to it. It has no per-host
  passthrough. A tool that pins certificates must be added to `NO_PROXY`.
- A template built from an attached container still trusts that proxy's
  certificate authority.
- Every container on the bridge can reach every proxy. The placeholder is what
  grants use of a token, so a leaked placeholder works from any container
  until `incs proxy rm` or a re-attach rotates it.
- Only GitHub is wired up. Entry files are named `<container>--<service>` to
  leave room for more.
- Claude's own login and the 1Password CLI plugin still place real
  credentials in the container.

## Testing

- `tests/proxy_test.sh` runs the real `incs` entrypoint against
  `tests/lib/fake_incus`, a stand-in that keeps real config and file state and
  runs the real `iron-rebuild` script. Assertions are on outcomes: file
  contents, config keys, exit codes.
- `tests/proxy_e2e_docker_test.sh` runs the real provisioning script and the
  real iron-proxy binary in an Ubuntu container, against a local HTTPS
  upstream. It covers TLS interception, bearer and git-style basic auth, two
  containers on one proxy, and detach. Skipped without Docker.
- Not covered by automation: real Incus behavior (the device override, file
  push and pull, config filters) and a live 1Password fetch. Real-host smoke
  test: manual.
