COMPONENT_ID="docker"
COMPONENT_NAME="Docker"
COMPONENT_DESC="Container runtime & compose"
COMPONENT_DEFAULT=1
COMPONENT_RUN_ON_LAUNCH=1

component_is_installed() {
  incus exec "$CONTAINER_NAME" -- sh -c 'command -v docker' &>/dev/null
}

component_install() {
  # Container config is always needed -- not preserved in templates.
  #
  # Security tradeoff: Docker-in-Incus requires relaxing the inner container's
  # sandbox so Docker can manage its own containers. Specifically:
  #   - nesting:  lets the container create cgroups/namespaces (container primitives)
  #   - mknod:    lets it create device nodes in /dev/ (kernel driver access)
  #   - setxattr: lets it set security labels on files
  #
  # A normal Incus container can't do any of this. Enabling these means a process
  # that escapes Docker inside the container has more capabilities than it would
  # in a plain Incus container. The Incus boundary still protects the host -- it's
  # one wall instead of two. For dev containers this is fine; for untrusted code,
  # consider using --no-sudo to limit what the container user can do.
  log "Configuring container for Docker..."
  incus config set "$CONTAINER_NAME" security.nesting=true
  incus config set "$CONTAINER_NAME" security.syscalls.intercept.mknod=true
  incus config set "$CONTAINER_NAME" security.syscalls.intercept.setxattr=true

  # AppArmor (mandatory access control) causes two problems for Docker-in-Incus:
  #   1. runc fails with "ip_unprivileged_port_start: permission denied"
  #      because AppArmor's default profile restricts nested containers.
  #   2. Docker checks if AppArmor is enabled, sees "Y", and tries to load
  #      its "docker-default" profile via securityfs -- which isn't accessible
  #      inside an Incus container, so it fails.
  #
  # Fix: run unconfined (removes restriction #1), then mask the AppArmor
  # enabled flag so Docker thinks it's not available (removes #2).
  #
  # Security tradeoff: Docker's AppArmor profile normally restricts containers
  # from writing to /proc/sys, mounting filesystems, and accessing raw kernel
  # interfaces. We lose that layer here, but Incus compensates with its own
  # isolation: user namespaces (container root maps to an unprivileged host
  # UID), seccomp syscall filtering, PID/network/mount namespaces, and cgroup
  # resource limits. An attacker would need to escape both Docker and Incus to
  # reach the host. Loading the profile from outside is impractical -- Docker
  # expects to manage AppArmor profiles dynamically, and exposing securityfs
  # into the container would let it weaken the host's own confinement.
  incus config set "$CONTAINER_NAME" raw.lxc "lxc.apparmor.profile=unconfined"
  # raw.lxc is only read at container start, so restart to apply it.
  incus restart "$CONTAINER_NAME"
  wait_for_container "$CONTAINER_NAME"
  wait_for_network "$CONTAINER_NAME"

  if component_is_installed; then
    log "Docker binary already installed, skipping package install"
    incus restart "$CONTAINER_NAME"
    wait_for_container "$CONTAINER_NAME"
    wait_for_network "$CONTAINER_NAME"
    return
  fi

  log "Installing Docker..."

  # Mask AppArmor enabled flag so Docker skips it entirely.
  incus exec "$CONTAINER_NAME" -- sh -s <<'APPARMOR_EOF'
    if [ -f /sys/module/apparmor/parameters/enabled ] && \
       grep -q Y /sys/module/apparmor/parameters/enabled 2>/dev/null; then
      echo N > /run/apparmor_disabled
      mount --bind /run/apparmor_disabled /sys/module/apparmor/parameters/enabled

      # Make the mask persistent across reboots.
      cat > /etc/systemd/system/mask-apparmor.service <<'UNIT'
[Unit]
Description=Mask AppArmor enabled flag for Docker-in-Incus
DefaultDependencies=no
Before=docker.service containerd.service docker.socket

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo N > /run/apparmor_disabled && mount --bind /run/apparmor_disabled /sys/module/apparmor/parameters/enabled'

[Install]
WantedBy=multi-user.target
UNIT
      systemctl daemon-reload
      systemctl enable mask-apparmor.service
    fi
APPARMOR_EOF

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
  incus exec "$CONTAINER_NAME" -- sh -c "usermod -aG docker $HOST_USER"
  wait_for_container "$CONTAINER_NAME"
}

# Docker container config (nesting, apparmor) isn't preserved in templates.
component_on_launch() {
  component_install
}
