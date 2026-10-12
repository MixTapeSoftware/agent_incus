# incus.profile
# The agent-incus Incus profile: security hardening and default limits for
# agent containers.
#
# Sourced by incus.init. Defines functions only.

AGENT_PROFILE="agent-incus"

# Always (re)applies the keys this profile owns so hosts converge on the
# current definition; hand edits to these keys are overwritten. Instance-level
# config still wins (e.g. the docker plugin sets security.nesting=true).
ensure_profile() {
  if ! incus profile show "$AGENT_PROFILE" &>/dev/null; then
    log "Creating Incus profile: $AGENT_PROFILE"
    # A concurrent run may create it first; that's fine.
    incus profile create "$AGENT_PROFILE" >/dev/null 2>&1 ||
      incus profile show "$AGENT_PROFILE" &>/dev/null ||
      error "Could not create Incus profile: $AGENT_PROFILE"
  fi
  incus profile set "$AGENT_PROFILE" \
    security.nesting=false \
    security.privileged=false \
    security.idmap.isolated=true \
    limits.memory=6GB \
    limits.cpu=4
  # Tagging is per-instance (incus.init sets user.managed-by on each
  # container), so the profile itself never carries it.
  incus profile unset "$AGENT_PROFILE" user.managed-by 2>/dev/null || true
}
