# Neovim Import Plugin — Design

**Date:** 2026-05-24
**Status:** Approved (pending user review of this spec)
**Author:** Chad Fennell (with Claude)

## Motivation

The current workflow mounts `~/.config/nvim` from the host into the container. This couples the container to the host's nvim install (version drift, missing plugin deps in the container) and prevents running nvim cleanly inside the container as the user's primary editor.

This change replaces "mount the host's nvim" with "install nvim inside the container and import a config." It treats nvim like any other optional component in `plugins/`.

## Goals

- Install a recent Neovim inside the container so that NvChad / LazyVim / vanilla configs all work.
- Let the user pick a distro (NvChad, LazyVim, or "just nvim") with a single TUI prompt at provision time.
- Let the user optionally layer their own config on top of the canonical distro install, sourced from either a git URL or a host-directory copy.
- Drive everything non-interactively via CLI flags as well, so templates and automation work.
- Match the existing plugin contract — no new abstractions.

## Non-goals

- Replacing the host-mount workflow for *other* configs (zshrc, tmux, etc.) — chadmux covers tmux already, and zsh/oh-my-zsh is in the base.
- Bootstrapping lazy.nvim's plugins automatically during provisioning. Distros do that on first `nvim` launch; driving it from a script is fragile.
- Supporting private repos via gh-auth. Out of scope — the user can re-run with a public mirror or use the host-copy option.
- Supporting arbitrary repo layouts for the LazyVim overlay (see Caveats).

## Architecture

A new plugin file `plugins/50-nvim.sh` following the existing contract used by `50-chadmux.sh`. Discovery, ordering, prompting, and CLI-flag plumbing all reuse the existing plugin machinery — no changes to `incus.init` or `incs` are required.

```
plugins/50-nvim.sh
  PLUGIN_ID="nvim"
  PLUGIN_NAME="Neovim"
  PLUGIN_DESC="Install nvim via mise + import config (NvChad/LazyVim/vanilla)"
  PLUGIN_DEFAULT=0
  PLUGIN_NEEDS_PROMPT=1
  PLUGIN_CLI_FLAGS="--nvim"

  plugin_is_installed()  { ... }
  plugin_prompt()        { ... }   # only runs if CLI flags didn't pre-set answers
  plugin_install()       { ... }
```

### CLI flags

For non-interactive use (templates, CI, scripted runs):

| Flag | Effect |
|---|---|
| `--nvim` | Enable the plugin. |
| `--nvim-distro={nvchad\|lazyvim\|none}` | Skip the distro prompt. |
| `--nvim-overlay=URL` | Skip the overlay prompt; use this git URL as the overlay source. |
| `--nvim-overlay=host` | Skip the overlay prompt; copy from host `~/.config/nvim`. |

If `--nvim-distro` is omitted, the distro prompt runs. If `--nvim-overlay` is omitted, the overlay prompt runs. Omit both (with just `--nvim`) and you get a fully interactive install.

## Install Flow

All container-side work runs as `HOST_USER` via `incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c '...'`, matching the chadmux pattern.

### Stage A — Install nvim (always)

```
mise use -g neovim@stable
```

Mise is already installed in every container. `neovim@stable` is used (not a pin) because LazyVim requires ≥0.11.2 and the version surface drifts; users who want a pin can edit the plugin. Mise persists into templates.

### Stage B — Distro-specific dependencies and canonical clone

| Distro | apt deps | Clone |
|---|---|---|
| `nvchad` | `ripgrep` | `git clone https://github.com/NvChad/starter ~/.config/nvim && rm -rf ~/.config/nvim/.git` |
| `lazyvim` | `ripgrep fd-find lazygit` | `git clone https://github.com/LazyVim/starter ~/.config/nvim && rm -rf ~/.config/nvim/.git` |
| `none` | — | — |

`fzf` and the C compiler that LazyVim wants for tree-sitter are already present in the base image (`fzf` is in the default packages; `build-essential` covers the compiler).

`.git` is removed from both starters so the user's overlay (or future personal repo work) isn't tracking an upstream remote they didn't choose. LazyVim's docs explicitly recommend this; NvChad's don't but it's cleaner.

### Stage C — Overlay (only if user provided one)

| Distro | Overlay destination | URL behavior | Host-copy behavior |
|---|---|---|---|
| `nvchad` | `~/.config/nvim/lua/custom/` | `git clone URL ~/.config/nvim/lua/custom` | Tar-stream host `~/.config/nvim/lua/custom/` (if present) into the same path. |
| `lazyvim` | `~/.config/nvim/lua/` (merged) | Clone URL to a temp dir; copy its top-level `plugins/` and `config/` subdirs into `~/.config/nvim/lua/`; delete the temp dir. | Tar-stream host `~/.config/nvim/lua/` into the same path. |
| `none` | `~/.config/nvim/` | `git clone URL ~/.config/nvim` | Tar-stream host `~/.config/nvim/` into the same path. |

**Host-copy mechanic.** No shared mount and no temp files on the host:

```
tar -C "$HOME/.config/nvim" -cf - . \
  | incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" -c \
      'mkdir -p ~/.config/nvim && tar -C ~/.config/nvim -xf -'
```

(Source directory and destination path vary per the table above.)

**Pre-existing `~/.config/nvim` in container.** If the path already exists at install time (re-running the plugin, or distro install raced with an overlay step), move it to `~/.config/nvim.bak-$(date +%s)` before proceeding. Matches LazyVim's documented backup advice; forgiving for retries.

### What the plugin does NOT do

- It does not run nvim during provisioning. Lazy.nvim bootstraps plugins on the user's first `nvim` invocation inside the container. Trying to drive that headlessly is fragile (TUI prompts, plugin compile errors during install) and offers little value.
- It does not configure shell aliases or set `EDITOR`. Out of scope.

## Interactive Prompts

Sketch of `plugin_prompt()` — only runs when neither `--nvim-distro` nor `--nvim-overlay` were passed. Sets shell variables that `plugin_install()` reads.

```
plugin_prompt() {
  echo ""
  echo "Pick a Neovim distro:"
  echo "  1) NvChad"
  echo "  2) LazyVim"
  echo "  3) Just nvim (no distro)"
  read -rp "Choice [1-3]: " choice
  case "$choice" in
    1) NVIM_DISTRO=nvchad  ;;
    2) NVIM_DISTRO=lazyvim ;;
    3) NVIM_DISTRO=none    ;;
    *) NVIM_DISTRO=none    ;;   # invalid -> none, with a warning
  esac

  echo ""
  read -rp "Add your own config on top? [y/N]: " add
  if [[ "$add" =~ ^[Yy]$ ]]; then
    echo "  1) Git URL"
    echo "  2) Copy host ~/.config/nvim"
    read -rp "Source [1-2]: " src
    case "$src" in
      1) read -rp "Repo URL: " NVIM_OVERLAY_URL ;;
      2)
        if [[ ! -d "$HOME/.config/nvim" ]]; then
          warn "Host has no ~/.config/nvim — skipping overlay"
        else
          NVIM_OVERLAY_HOST=1
        fi
        ;;
    esac
  fi
}
```

### Validation

- **URL:** light syntactic check (`https?://...` or `git@...`). The real error comes from `git clone`.
- **Host copy:** verify `$HOME/.config/nvim` exists on the host before promising to copy; skip with a warning if it doesn't.
- **Distro:** invalid input falls back to `none` with a warning — no re-prompt loop, to keep the TUI flow predictable.

## End-to-end example (NvChad + custom overlay)

```
[+] Installing Neovim...

Pick a Neovim distro:
  1) NvChad
  2) LazyVim
  3) Just nvim (no distro)
Choice [1-3]: 1

Add your own config on top? [y/N]: y
  1) Git URL
  2) Copy host ~/.config/nvim
Source [1-2]: 1
Repo URL: https://github.com/chad/nvchad-custom

[+] Installing nvim via mise (neovim@stable)...
[+] Installing apt deps: ripgrep
[+] Cloning NvChad/starter into ~/.config/nvim...
[+] Cloning chad/nvchad-custom into ~/.config/nvim/lua/custom...
[+] Done. Run `nvim` in the container for first-time plugin bootstrap.
```

## Templates

`~/.config/nvim` lives under `HOST_USER`'s home directory inside the container, so `incus publish`-based templates capture it. The mise-installed nvim binary also persists. **No `PLUGIN_RUN_ON_LAUNCH` is needed** — launching from a template gives you nvim + config out of the box.

If a user wants the template to be config-free (so different containers can have different overlays), they should publish the template before running the nvim plugin, or delete `~/.config/nvim` before publishing.

## Idempotency / `plugin_is_installed`

```
plugin_is_installed() {
  incus exec "$CONTAINER_NAME" -- su - "$HOST_USER" \
    -c 'command -v nvim >/dev/null && test -d ~/.config/nvim' &>/dev/null
}
```

If both nvim is on PATH and `~/.config/nvim` exists, the plugin reports installed and is skipped. To re-run, delete `~/.config/nvim` in the container first (the plugin's backup-on-conflict behavior also covers this case).

## Caveats

1. **LazyVim overlay assumes a specific repo layout.** The overlay merges top-level `plugins/` and `config/` directories from the user's repo into `~/.config/nvim/lua/`. Users with different layouts (e.g., the repo IS a full LazyVim fork) won't fit this model — they'd need a "replace canonical clone with my fork" option, which is deferred.
2. **No private-repo support.** `git clone` runs without credentials. Private repos fail; the user can use the host-copy option or mirror to a public URL.
3. **First-launch bootstrap is the user's problem.** The plugin doesn't run `nvim --headless +"Lazy! sync" +qa` or similar. First `nvim` launch may take 30–90 seconds while lazy.nvim downloads plugins.

## Out of scope / future work

- A "replace canonical with my fork URL" mode for users whose personal config is a full fork of a starter.
- Private repo support via gh-auth integration.
- A `--nvim-version=` flag to pin a specific nvim version (today users edit the plugin).
- Removing the host-mount workflow from documentation — separate change, after this lands and is shaken out.
