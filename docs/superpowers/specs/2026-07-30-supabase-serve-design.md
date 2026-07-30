# Tailscale + Supabase serve preset — design

## Problem

Every project instance ends up with the same seven `tailscale serve` mappings,
applied by hand after each build: the app dev servers and the local Supabase
stack, exposed over tailnet HTTPS. This should be a single checkbox at
creation time.

## Decision

A new built-in plugin, **`supabase-serve`**, plus a minimal generic
**`PLUGIN_REQUIRES`** dependency mechanism in `incus.init` so one checkbox can
pull in the Tailscale plugin it depends on.

Alternatives considered and rejected:

- Extending the Tailscale plugin's prompt with a preset menu — not a checkbox,
  adds interaction to every tailscale build, invisible in the TUI list.
- A post-hoc `incs serve` command — solves retrofitting, not creation-time
  convenience; can be added later if ever needed.
- A per-project serve-map config file — the map is identical across projects,
  so config is overhead (YAGNI).

## Plugin: `plugins/55-supabase-serve.sh`

- `PLUGIN_ID="supabase-serve"`, `PLUGIN_NAME="Tailscale + Supabase serve"`.
  The name deliberately sorts immediately after `Tailscale` (install order is
  A–Z by name), guaranteeing tailscale is installed and up before the preset
  applies. No colon in the name — the TUI's `PLUGINS` entries are
  colon-delimited.
- `PLUGIN_CLI_FLAGS="--supabase-serve"`, `PLUGIN_DEFAULT=0`,
  `PLUGIN_REQUIRES="tailscale"`.
- Fixed map, HTTPS tailnet port → localhost target:
  `443:3000 4410:3010 4431:3001 5432:54321 5433:54323 5434:54324 8443:8000`
- `plugin_is_installed` returns false, so the map is (re)applied on fresh
  builds **and** template launches. `tailscale serve --bg` is idempotent and
  tailscaled persists the config, so re-applying converges.

## Mechanism: `PLUGIN_REQUIRES` in `incus.init`

After all selection input (CLI flags + TUI), before the "Plugins selected:"
echo and the prompt loop: source each *selected* plugin, and auto-select every
id listed in its `PLUGIN_REQUIRES`, logging each auto-selection. Because this
runs before `_run_plugin_prompts`, a required plugin's own prompt (tailscale's
auth key) still fires. Resolution is single-level: a required plugin's own
requirements are not chased. Unknown ids warn and are ignored.
`_reset_plugin_state` clears `PLUGIN_REQUIRES` so it cannot leak between
plugins; the `incs new-plugin` template documents the new field.

## Error handling

- Tailscale binary missing at install time (template edge cases): warn, skip
  the preset, do not fail the build.
- Machine not yet joined (auth key left blank): mappings are still attempted —
  serve config persists and goes live after a later `tailscale up` — and any
  per-mapping failure warns individually instead of aborting the build.

## Testing

- `tests/plugin_isolation_test.sh`: `PLUGIN_REQUIRES` is cleared by
  `_reset_plugin_state`.
- Stubbed-incus end-to-end simulation: selecting only `--supabase-serve`
  auto-selects tailscale, runs its auth-key prompt, and the call log shows all
  seven `tailscale serve` invocations ordered after `tailscale up`.
- Real-host smoke test: manual.
