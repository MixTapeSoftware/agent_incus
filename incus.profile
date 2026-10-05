# incus.profile
# The agent-incus Incus profile: security hardening and default limits shared
# by agent containers and credential proxies.
#
# Sourced by incus.init and incus.proxy. Defines functions only.

AGENT_PROFILE="agent-incus"

# Always (re)applies the keys this profile owns so hosts converge on the
# current definition; hand edits to these keys are overwritten. Instance-level
# config still wins (e.g. the docker plugin sets security.nesting=true).
ensure_profile() {
  incus profile show "$AGENT_PROFILE" &>/dev/null || {
    log "Creating Incus profile: $AGENT_PROFILE"
    incus profile create "$AGENT_PROFILE" >/dev/null
  }
  incus profile set "$AGENT_PROFILE" \
    security.nesting=false \
    security.privileged=false \
    security.idmap.isolated=true \
    limits.memory=4GB \
    limits.cpu=4
  # Tagging is per-instance: proxies use this profile but must not be
  # managed-by=agent-incus, or kill-all/update-all would sweep them up.
  incus profile unset "$AGENT_PROFILE" user.managed-by 2>/dev/null || true
}
