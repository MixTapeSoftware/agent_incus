PLUGIN_ID="docker"
PLUGIN_NAME="Docker"
PLUGIN_DESC="Container runtime & compose (the docker group is root inside the container)"
# Off by default: the docker group is root inside the container, and while
# the workspace is mounted with shift=true, root inside is root over the
# mounted checkout on the host. Opt in with --docker.
PLUGIN_DEFAULT=0
PLUGIN_CLI_FLAGS="--docker"
PLUGIN_RUN_ON_LAUNCH=1

plugin_is_installed() {
  incus exec "$CONTAINER_NAME" -- sh -c 'command -v docker' &>/dev/null
}

plugin_install() {
  # VMs run their own kernel, so Docker installs natively — none of the
  # container sandbox relaxation below applies. More importantly, the config
  # keys it uses (security.nesting, security.syscalls.intercept.*, raw.lxc)
  # are container-only: Incus rejects them on a VM, which would abort the
  # whole build under set -e.
  if [[ "${IS_VM:-0}" == "1" ]]; then
    if plugin_is_installed; then
      log "Docker binary already installed, skipping package install"
    else
      log "Installing Docker (native, VM)..."
      _docker_install_packages
    fi
    incus exec "$CONTAINER_NAME" -- sh -c "usermod -aG docker $HOST_USER"
    return
  fi

  # Container config is always needed -- not preserved in templates.
  #
  # Security tradeoff: Docker-in-Incus relaxes the container's sandbox so
  # Docker can manage its own containers. Specifically:
  #   - nesting:  lets the container create cgroups/namespaces, and swaps its
  #               AppArmor profile for one that allows mount/pivot_root and
  #               gives the container its own AppArmor namespace, so dockerd
  #               loads docker-default inside it as usual
  #   - mknod:    lets it create a limited set of device nodes in /dev/
  #   - setxattr: lets it set a limited set of security labels on files
  #
  # A normal Incus container can't do any of this. Enabling these means a process
  # that escapes Docker inside the container has more capabilities than it would
  # in a plain Incus container. The Incus boundary still protects the host -- it's
  # one wall instead of two. For dev containers this is fine; for untrusted code,
  # consider using --no-sudo to limit what the container user can do.
  #
  # The container is NOT run unconfined. Older builds did, to get around an
  # AppArmor deny that broke runc under the nesting profile; Incus 6.19 fixed
  # that (lxc/incus#2624), and unconfined cost Docker its own AppArmor layer.
  log "Configuring container for Docker..."
  incus config set "$CONTAINER_NAME" security.nesting=true
  incus config set "$CONTAINER_NAME" security.syscalls.intercept.mknod=true
  incus config set "$CONTAINER_NAME" security.syscalls.intercept.setxattr=true
  _docker_warn_old_incus
  _docker_remove_apparmor_mask || return 1
  # The syscall interception keys are only read at container start.
  incus restart "$CONTAINER_NAME"
  wait_for_container "$CONTAINER_NAME" "${READY_TIMEOUT:-30}"
  wait_for_network "$CONTAINER_NAME" "${READY_TIMEOUT:-30}"

  if plugin_is_installed; then
    log "Docker binary already installed, skipping package install"
    incus exec "$CONTAINER_NAME" -- sh -c "usermod -aG docker $HOST_USER"
    return
  fi

  log "Installing Docker..."
  _docker_install_packages
  incus exec "$CONTAINER_NAME" -- sh -c "usermod -aG docker $HOST_USER"
  wait_for_container "$CONTAINER_NAME" "${READY_TIMEOUT:-30}"
}

# Before Incus 6.19 the nesting profile denied the sysctl writes runc makes
# for every container (lxc/incus#2623), and the only way around it was to run
# unconfined. Say so rather than do that.
_docker_warn_old_incus() {
  local v major minor
  v="$(incus version 2>/dev/null | awk -F': *' '/^Server version/ {print $2}')"
  [[ -n "$v" ]] || return 0
  major="${v%%.*}"; minor="${v#*.}"; minor="${minor%%[^0-9]*}"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || return 0
  if (( major < 6 || (major == 6 && minor < 19) )); then
    warn "Incus $v may predate the fix that lets Docker run under the nesting AppArmor profile (lxc/incus#2624, Incus 6.19).
    If containers fail to start with 'ip_unprivileged_port_start: permission denied', update Incus."
  fi
}

# Older builds hid AppArmor from dockerd behind a bind mount over
# /sys/module/apparmor/parameters/enabled, kept by a unit that templates of
# that era still carry. Take it out before the restart, so dockerd comes up
# with AppArmor and loads docker-default.
_docker_remove_apparmor_mask() {
  # An exec error must not read as "no mask": the restart would keep it.
  local mask
  mask="$(incus exec "$CONTAINER_NAME" -- sh -c 'test -f /etc/systemd/system/mask-apparmor.service && echo yes || echo no' </dev/null)" || mask=""
  case "$mask" in
    no)  return 0 ;;
    yes) ;;
    *)   warn "Could not check $CONTAINER_NAME for the AppArmor mask an older build left; not configuring Docker"
         return 1 ;;
  esac
  log "Removing the AppArmor mask an older build left in this image..."
  incus exec "$CONTAINER_NAME" -- systemctl disable mask-apparmor.service >/dev/null 2>&1 || true
  incus exec "$CONTAINER_NAME" -- umount /sys/module/apparmor/parameters/enabled >/dev/null 2>&1 || true
  incus file delete "$CONTAINER_NAME/etc/systemd/system/mask-apparmor.service"
  incus exec "$CONTAINER_NAME" -- systemctl daemon-reload >/dev/null 2>&1 || true
}

_docker_install_packages() {
  incus exec "$CONTAINER_NAME" -- sh -s <<'DOCKER_EOF'
    export DEBIAN_FRONTEND=noninteractive
    apt-get update && apt-get install -y ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable docker && systemctl start docker
DOCKER_EOF
}

# Docker container config (nesting, syscall interception) isn't preserved in templates.
plugin_on_launch() {
  plugin_install
}
