# `--vm` flag for incus.init — design

**Date:** 2026-07-18
**Status:** approved (design), pending implementation plan
**Type:** agent-incus core feature (`incus.init`)

## Goal

Let `incs` provision an Incus **virtual machine** (KVM, own kernel) instead of a
system container, via an opt-in `--vm` flag. VMs are the user's intended
long-term default ("all-in on VMs" with sealed workspaces); this change ships VM
support opt-in now so it can be dogfooded before the default is flipped in a
later change.

The container path is unchanged. The VM path reuses ~90% of the existing flow
(provisioning, user creation, shell, plugins, mise) and diverges only at launch,
readiness, and the workspace.

## Key insight: VMs make the workspace *simpler*

The container workspace machinery — `mount_workspace`, `shift=true`,
`raw.idmap`, `ensure_subid_entries`, and the subuid/subgid plumbing — exists
solely to correct unprivileged-userns UID remapping on a bind mount. **VMs have
no userns**, so none of it applies. Combined with the user's decision to use a
**copy / no-copy (sealed)** model rather than a live mount, the VM workspace
reduces to: *copy the host tree in (or don't), then `chown`*. All idmap code is
simply never reached when `IS_VM=1`.

## Decisions (settled during brainstorming)

1. **Opt-in now.** `--vm` sets `IS_VM=1`; container remains the default. A future
   change may flip the default and add `--container`. Not in scope here.
2. **Workspace: copy / no-copy only.** VMs never live-mount. Default copies the
   host working tree in (including `.git`, via the existing tar-pipe);
   `--no-copy` starts with an empty, sealed `/workspace`.
3. **`--no-mount` on a VM is an alias for the default copy.** VMs always copy, so
   passing `--no-mount` with `--vm` is accepted and behaves as the default (no
   error) — preserves muscle memory.
4. **Resources: sensible defaults + override flags.** `--vm-disk` (default
   `20GiB`), `--vm-memory` (default `4GiB`), `--vm-cpus` (default `4`). The
   20GiB root gives headroom for pre-warmed toolchains (NvChad, mise) that the
   default 10GiB profile disk would cram.
5. **Image-type mismatch is detected early** with a friendly message rather than
   letting a cryptic Incus error surface.

## Flags

| Flag | Effect | Default |
|------|--------|---------|
| `--vm` | Provision a VM (`IS_VM=1`) | off (container) |
| `--no-copy` | VM only: empty sealed workspace, skip the copy | off (copy) |
| `--vm-disk SIZE` | VM root disk size | `20GiB` |
| `--vm-memory SIZE` | VM memory | `4GiB` |
| `--vm-cpus N` | VM vCPUs | `4` |

- `--no-copy` and `--vm-disk/memory/cpus` are **VM-only**. If passed without
  `--vm`, warn that they are ignored (do not error — keeps the flag forgiving).
- `--no-mount` + `--vm`: accepted, treated as the default copy (decision 3).
- Sizes are passed to Incus verbatim (Incus accepts `GiB`/`GB` suffixes); no
  validation beyond non-empty. `--vm-cpus` must be a positive integer.

## Launch

```bash
incus launch "$BASE_IMAGE" "$CONTAINER_NAME" --vm \
  -c limits.memory="$VM_MEMORY" \
  -c limits.cpu="$VM_CPUS" \
  -d root,size="$VM_DISK"
```

Container launch is the existing `incus launch "$BASE_IMAGE" "$CONTAINER_NAME"`
(no `--vm`, no resource args).

### Image-type mismatch (decision 5)

VMs cannot launch from a container-type image and vice-versa. Before launching,
check the resolved base image's type and compare to `IS_VM`:

- Ubuntu remote images (`images:ubuntu/24.04`) exist in both variants; Incus
  picks the matching one from `--vm`, so no check needed there.
- **Local templates** (`--from`, i.e. `BASE_IMAGE != images:*`) are single-type.
  Query `incus image info "$BASE_IMAGE"` for its type and, on mismatch, error
  with: `Template '<img>' is a <type> image; <cannot use --vm / needs --vm>.`

VM templates saved via `--template` carry their VM-ness implicitly (the published
image is a VM image); re-launching them simply requires `--vm`, which the check
enforces with a clear message.

## Readiness

VM `incus exec` requires the **guest agent**, which comes up several seconds
after the VM boots a full kernel — noticeably slower than a container's ~2s.

- `wait_for_container`'s probe (`incus exec ... true`) already returns non-zero
  until the agent answers, so the **poll loop works unchanged**; only the
  timeout needs raising for VMs.
- Introduce a readiness timeout that is VM-aware: `READY_TIMEOUT=90` when
  `IS_VM=1`, else the current default. Pass it into `wait_for_container` /
  `wait_for_network` at the call sites (or via a global the helpers read).

No change to the polling logic itself.

## Workspace

Gate on `IS_VM`. When `IS_VM=1`, the mount/idmap branch is never entered:

- **Default (copy):** identical to today's `--no-mount` copy branch — tar-pipe
  the host tree in (incl. `.git`), extract `--no-same-owner`, `chown -R` to the
  launching user, register `git config --global --add safe.directory`. Sets
  `IDMAP_METHOD="copy"`.
- **`--no-copy` (sealed):** `mkdir -p "$MOUNT_PATH"`, `chown` to the user, mark
  git-safe. No tar-pipe. Sets `IDMAP_METHOD="none"` (reported as `sealed`).
- Template launches into an already-populated `/workspace` re-own the tree to the
  launching user, exactly as the container path does today.

`mount_workspace`, `shift=true`, `raw.idmap`, and `ensure_subid_entries` remain
in the file, called **only** on the container path. They are dead code for VMs
by construction, not by refactor — the container path is untouched.

## Shared, unchanged

Everything between launch and the final summary is backend-agnostic and runs
identically for VMs and containers: package provisioning (apt, mise, gh), user
creation (`$HOST_UID`/`$HOST_GID`), zsh/Oh-My-Zsh, plugin installs, workspace
mise-install, shim-sync. The plugin capture-into-template story (NvChad, etc.)
works the same — arguably better on VMs, since `$HOME` lives in the VM's own
disk image.

## Reporting

- **usage()** gains the five flags under a "VM options" grouping.
- **Dry-run** and the **final summary** gain a `Type:` line:
  - container: `Type: container`
  - VM: `Type: VM (disk=20GiB memory=4GiB cpus=4)`
- Workspace line for VMs shows `copy host tree into <path> incl .git` or
  `sealed (empty <path>)`.

## Error handling

- `--vm-cpus` non-integer or `<1` → error before launch.
- Local template + type mismatch → error before launch with a clear message
  (decision 5).
- VM-only flags without `--vm` → warn and ignore (decision 3-style forgiveness).
- KVM availability: if the host cannot run VMs, `incus launch --vm` fails with
  Incus's own error. We surface it as-is (the existing cleanup trap offers to
  delete the partial instance). A pre-flight KVM check is **out of scope** for
  this change (YAGNI — Incus's error is already clear, e.g. missing
  `/dev/kvm`).

## Verification

Full end-to-end needs an Incus host with KVM (not available in the authoring
env), so:

- **Static:** `bash -n incus.init`; `--dry-run` with `--vm` prints the `Type: VM
  (...)` line and correct workspace description; `--dry-run --vm --no-copy`
  shows `sealed`; VM-only flags without `--vm` emit the ignore warning.
- **On-host acceptance:**
  - `incs -vm foo` → a VM boots, `incs foo` shells in, `/workspace` contains the
    copied tree owned by you, `git status` works (safe.directory registered).
  - `incs -vm --no-copy foo` → `/workspace` is empty and owned by you.
  - `incs -vm --vm-memory 8GiB --vm-cpus 8 foo` → `incus config show foo`
    reflects the overrides.
  - `incs -vm -t base` then `incs -vm --from base bar` → template round-trips;
    `incs --from base bar` (no `--vm`) errors with the mismatch message.
  - Container path unchanged: `incs foo` still mounts/idmaps exactly as before.

## Out of scope

- Flipping the default to VM / adding `--container` (a later change).
- KVM host pre-flight check (rely on Incus's error).
- Live virtiofs mounting for VMs (explicitly rejected in favor of copy/sealed).
- macOS/Colima VM-nesting specifics beyond what `incus launch --vm` already does.
- Removing the now-VM-unused idmap code (still needed by the container path).

## Assumptions

- Host Incus supports VMs (KVM present); if not, launch fails clearly.
- Base images resolve to a VM variant when `--vm` is passed (true for the
  `images:` Ubuntu remote).
- The guest agent is present in the standard Ubuntu VM images (it is), so
  `incus exec` becomes available within the 90s readiness window.
