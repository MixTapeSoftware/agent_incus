# NvChad user plugin — design

**Date:** 2026-07-15
**Status:** approved (design), pending implementation plan
**Type:** boxen **user** plugin (personal — not committed to this repo's `plugins/`)

## Goal

Provision a ready-to-use Neovim + personal NvChad setup inside an boxen
instance, so the editor is no longer a reason to stay on the host. When an
instance is created with the plugin selected, the first real `nvim` launch opens
**instantly and works offline** — plugins, treesitter parsers, and language
servers already installed.

The config is the user's own NvChad fork: `https://github.com/chadfennell/nvChad`
(public; NvChad v2.5 layout — `init.lua`, `lua/chadrc.lua`, `lua/mappings.lua`,
`lua/options.lua`, `lua/plugins/init.lua`, `lua/configs/*`, `lazy-lock.json`).

## Decisions (settled during brainstorming)

1. **Source:** clone the user's fork `chadfennell/nvChad` (public → no auth), not
   the vanilla `NvChad/starter`. The fork carries the user's Go/Elixir/keymap
   customizations.
2. **Bootstrap depth: pre-warm everything** at provision time (headless), so the
   first interactive launch is instant and offline-capable.
3. **Toolchains: Go + web LSPs; skip the Elixir runtime.** Install Go plus the
   web/Go editor tooling. The `elixir-tools` *plugin* still installs (it's Lua),
   but Erlang/Elixir + elixirls are **not** pre-provisioned — they load lazily
   only when editing Elixir, and the user installs the runtime themselves then.
4. **Approach A — self-contained.** The plugin installs everything it needs under
   `$HOME`; it changes nothing in the shared repo's core provisioning.
5. **Neovim acquisition:** official GitHub **release tarball**, pinned version,
   arch-detected. No build step, reproducible.

## Placement & plugin contract

A single user-plugin file:

```
${XDG_DATA_HOME:-~/.local/share}/boxen/plugins/50-nvchad.sh
```

Not committed to this repo's `plugins/` — it targets a personal config. Contract:

- `PLUGIN_ID="nvchad"`
- `PLUGIN_NAME="NvChad"`
- `PLUGIN_DESC="Neovim + personal NvChad config (chadfennell/nvChad)"`
- `PLUGIN_DEFAULT=1` — it is the user's main reason for leaving the host.
- `PLUGIN_CLI_FLAGS="--nvchad"` — pre-select without the TUI.
- No `PLUGIN_NEEDS_PROMPT`, no `PLUGIN_RUN_ON_LAUNCH` (see Templates below).

All work runs as `HOST_USER` via `su -`. The plugin is **fully sudo-free**: every
artifact lands under `$HOME`, so it works under `--no-sudo`. The only system
dependency — a C compiler for treesitter — is already provided by core
(`build-essential`).

Tunable variables at the top of the file:

- `NVIM_VERSION` — pinned Neovim release tag (e.g. `v0.11.3`; a recent stable
  ≥ 0.11, which NvChad requires). Bump to re-pin.
- `NVCHAD_REPO` — defaults to `https://github.com/chadfennell/nvChad`.

## Install sequence

All steps run as `HOST_USER` in a login shell (so `mise` shims and
`~/.local/bin` are on `PATH` — the base already appends both in `.zshrc`).

1. **Neovim** — detect arch (`uname -m`: `x86_64` → `x86_64`, `aarch64` →
   `arm64`; error on anything else). Download
   `nvim-linux-<arch>.tar.gz` for `NVIM_VERSION` from GitHub releases, extract to
   `~/.local/nvim`, symlink `~/.local/bin/nvim`. (Note: the linux asset was
   renamed from `nvim-linux64.tar.gz` to `nvim-linux-<arch>.tar.gz` around
   v0.10.4 — the implementation must use the name matching the pinned version.)
2. **ripgrep** + **lazygit** — install release binaries into `~/.local/bin`
   (telescope live-grep needs `rg`; `<leader>lg` needs `lazygit`).
3. **Go runtime** — `mise use -g go@latest` (runtime for gopls and Go projects).
4. **Config** — `git clone "$NVCHAD_REPO" ~/.config/nvim` (skip if the dir already
   exists and is non-empty).
5. **Pre-warm (headless, best-effort)** in order:
   - `nvim --headless "+Lazy! restore" +qa` — install plugins at the exact
     versions in `lazy-lock.json` (reproducible; `restore` respects the lockfile
     rather than updating it).
   - `nvim --headless "+MasonInstall gopls typescript-language-server html-lsp
     css-lsp stylua gofumpt golines delve" +qa` — the LSPs the config enables
     (gopls, ts_ls, html, cssls), the Lua formatter, and Go formatters/debugger.
     Mason places binaries where Neovim (and conform.nvim) can find them.
   - `nvim --headless "+TSUpdate" +qa` — compile treesitter parsers
     (`ensure_installed`: vim, lua, vimdoc, html, css, go, gomod, gowork).

## Idempotency & templates

- `plugin_is_installed` returns 0 (already installed) when **both**
  `~/.local/bin/nvim` and `~/.config/nvim/init.lua` exist.
- Everything the plugin creates lives under `$HOME` (`~/.local/nvim`,
  `~/.local/bin`, `~/.config/nvim`, `~/.local/share/nvim/{lazy,mason}`). `$HOME`
  is part of the instance rootfs, so it **is** captured by `incus publish`.
  Consequence: pre-warming once into a **base template** means every instance
  cloned from that template has Neovim ready and offline, with zero per-instance
  cost. This is the intended pairing with the template flow — and why no
  `PLUGIN_RUN_ON_LAUNCH` is needed (unlike the workspace, `$HOME` survives
  snapshots).

## Error handling

- **Hard-fail** (abort the build, non-zero exit) only for essentials:
  unsupported arch, Neovim download/extract failure, or config clone failure.
- **Best-effort** for the pre-warm steps (`Lazy! restore`, `MasonInstall`,
  `TSUpdate`): on failure, log a warning and continue. Neovim still works and
  finishes any missing installs on the first interactive launch, so a single
  flaky parser compile or Mason download must not abort the whole instance
  build.
- **Network** is required at provision (downloads, clone, Mason registry). That
  is inherent to pre-warm; fail the essential steps with a clear message if
  offline.
- **Nerd Font**: glyphs render on the *client terminal*, not inside the VM. The
  plugin cannot fix fonts — it prints a one-line reminder to install a Nerd Font
  on whatever terminal connects to the instance.

## Verification

Full end-to-end needs an incus host (not available in the authoring env), so:

- **Static:** `bash -n` the plugin; `curl -sIL` the pinned Neovim / ripgrep /
  lazygit release-asset URLs to confirm they resolve for the pinned versions.
- **On-host acceptance:** create an instance with `--nvchad`, then
  - `nvim` opens immediately with no lazy bootstrap screen,
  - `:Mason` lists gopls + typescript-language-server (installed),
  - opening a `.go` file → gopls attaches; `:checkhealth` is clean,
  - offline sanity: disconnect network, relaunch `nvim` — still fully functional.

## Out of scope

- Elixir/Erlang runtime and elixirls/nextls (load lazily; user installs the
  runtime on demand).
- Nerd Font installation (client-side).
- Committing the plugin file or the `nvim/` reference directory into this repo.
- Generalizing the plugin to arbitrary NvChad forks via a parameter — YAGNI for
  now; `NVCHAD_REPO` is a single tunable if that changes.

## Assumptions

- Target instances are `x86_64` or `arm64` Linux with core provisioning already
  applied (git, curl, unzip, build-essential, nodejs/npm, mise present).
- `chadfennell/nvChad` remains public and tracks a Neovim version compatible with
  the pinned `NVIM_VERSION`.
