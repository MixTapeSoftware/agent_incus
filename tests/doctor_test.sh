#!/bin/bash
# tests/doctor_test.sh
# Runs `bxn doctor` against the fake incus: a healthy host first, then one
# thing broken at a time, checking each is reported with its fix.
# Run: bash tests/doctor_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
exec </dev/null

PASS=0
FAIL=0
assert_eq() {
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); echo "  ok  $1"
  else FAIL=$((FAIL+1)); echo "  FAIL $1"; echo "    expected: $2"; echo "    actual:   $3"; fi
}
assert_contains() {
  if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); echo "  ok  $1"
  else FAIL=$((FAIL+1)); echo "  FAIL $1"; echo "    expected to contain: $2"; echo "    actual: $3"; fi
}
assert_not_contains() {
  if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); echo "  ok  $1"
  else FAIL=$((FAIL+1)); echo "  FAIL $1"; echo "    expected not to contain: $2"; echo "    actual: $3"; fi
}

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin" "$SANDBOX/sys/boxenbr0" "$SANDBOX/proc/net/ipv4"
cp "$SCRIPT_DIR/lib/fake_incus" "$SANDBOX/bin/incus"
# The host's routes, and the processes pgrep finds, as a test wrote them.
cat > "$SANDBOX/bin/ip" <<'EOF'
#!/bin/sh
cat "$FAKE_INCUS_STATE/routes" 2>/dev/null
EOF
cat > "$SANDBOX/bin/pgrep" <<'EOF'
#!/bin/bash
pat="${*: -1}"
grep -qE -- "$pat" "$FAKE_INCUS_STATE/procs" 2>/dev/null
EOF
chmod +x "$SANDBOX/bin/"*
echo 1 > "$SANDBOX/proc/net/ipv4/ip_forward"

export PATH="$SANDBOX/bin:$PATH"
export HOME="$SANDBOX/home"
export BOXEN_NET_SUBNET=10.201.0.1/16
export BOXEN_UFW_CONF="$SANDBOX/no-ufw.conf"
export BOXEN_DOCTOR_SYS_NET="$SANDBOX/sys"
export BOXEN_DOCTOR_PROC_SYS="$SANDBOX/proc"
export FAKE_EGRESS_CTL="$SCRIPT_DIR/lib/fake_egress_ctl"
export FAKE_INCUS_STATE="$SANDBOX/state"
export BOXEN_LOCK_DIR="$SANDBOX/lock"
export BOXEN_CONFIG_DIR="$SANDBOX/config"
export FAKE_INCUS_VERSION=7.5.1
export NO_COLOR=1
mkdir -p "$FAKE_INCUS_STATE"
printf 'default via 192.168.1.1 dev wlan0\n10.201.0.0/16 dev boxenbr0 proto kernel scope link src 10.201.0.1\n192.168.1.0/24 dev wlan0\n' > "$FAKE_INCUS_STATE/routes"
echo "dnsmasq --keep-in-foreground --interface=boxenbr0 --dhcp-range 10.201.255.10" > "$FAKE_INCUS_STATE/procs"

doctor() { OUT="$(bash "$REPO_ROOT/bxn" doctor 2>&1)" && RC=0 || RC=$?; }
cfg() { cat "$FAKE_INCUS_STATE/instances/$1/config/$2" 2>/dev/null; }

echo "before anything exists"
doctor
assert_eq "nothing blocks" "0" "$RC"
assert_contains "the bridge comes with the first create" "boxenbr0 doesn't exist yet" "$OUT"
assert_contains "and so does the egress container" "No egress container yet" "$OUT"

# A host as bxn leaves it: the bridge, and box allowlisted through the egress container.
bash -c 'log(){ :; }; warn(){ :; }; error(){ exit 1; }; source "$1/boxen.net"; ensure_net' _ "$REPO_ROOT"
incus launch img box -p default -p boxen-net -d "eth0,ipv4.address=10.201.0.50" >/dev/null
incus config set box user.managed-by=boxen user.boxen.net=isolated
bash "$REPO_ROOT/bxn" egress mode box enforce >/dev/null 2>&1

echo "a healthy host"
doctor
assert_eq "it passes" "0" "$RC"
assert_contains "it says so" "All clear." "$OUT"
assert_contains "the bridge is checked" "boxenbr0 is 10.201.0.1/16" "$OUT"
assert_contains "box's proxy is checked" "box's proxy in boxen-egress is in place" "$OUT"
assert_not_contains "nothing fails" "FAIL" "$OUT"

before="$(grep -c '' "$FAKE_INCUS_STATE/calls.log")"
doctor
writes="$(tail -n +"$((before + 1))" "$FAKE_INCUS_STATE/calls.log" |
  grep -E '^(config (set|unset|device (set|add|remove))|network (set|create|acl (create|edit|delete))|start|stop|restart|delete|launch|init) ' || true)"
assert_eq "a run makes no changes" "" "$writes"

echo "Incus"
FAKE_INCUS_VERSION=7.4 doctor
assert_eq "an old Incus fails" "1" "$RC"
assert_contains "and says why" "Incus 7.4 is older than 7.5.1" "$OUT"
FAKE_INCUS_FIREWALL=xtables doctor
assert_contains "an xtables firewall fails" "firewall driver is xtables, not nftables" "$OUT"
FAKE_INCUS_FAIL_CALL='^query /1.0$' doctor
assert_eq "an unreachable server fails" "1" "$RC"
assert_contains "and says so" "Can't reach the Incus server" "$OUT"
assert_not_contains "and stops there" "Network (boxenbr0)" "$OUT"

echo "the lock"
mkdir -p "$BOXEN_LOCK_DIR"
doctor
assert_contains "a lock with no owner blocks" "names no owner" "$OUT"
assert_contains "with how to clear it" "rm -rf $BOXEN_LOCK_DIR" "$OUT"
echo 999999 > "$BOXEN_LOCK_DIR/pid"
doctor
assert_eq "an exited owner blocks nothing" "0" "$RC"
assert_contains "the next command takes it over" "the next one takes it over" "$OUT"
sleep 30 & sleeper=$!
echo "$sleeper" > "$BOXEN_LOCK_DIR/pid"
doctor
assert_eq "an owner that isn't bxn blocks" "1" "$RC"
assert_contains "and names what it is now" "which is now sleep 30, not bxn" "$OUT"
kill "$sleeper" 2>/dev/null || true
wait "$sleeper" 2>/dev/null || true
rm -rf "$BOXEN_LOCK_DIR"

echo "instances that can't be listed"
FAKE_INCUS_FAIL_CALL='^list --format csv --columns ns$' doctor
assert_eq "a list that fails is a failure, not all clear" "1" "$RC"
assert_contains "and says nothing was checked" "Incus wouldn't list its instances, so none of them was checked" "$OUT"
assert_not_contains "never all clear" "All clear" "$OUT"

echo "the bridge"
printf '10.0.0.0/8 dev tun0 scope link\n' >> "$FAKE_INCUS_STATE/routes"
doctor
assert_eq "an overlapping route fails" "1" "$RC"
assert_contains "and names it" "overlaps 10.0.0.0/8 on tun0" "$OUT"
FAKE_INCUS_REMOTE=other doctor
assert_not_contains "a remote server isn't judged by this host's routes" "overlaps 10.0.0.0/8 on tun0" "$OUT"
sed -i '/tun0/d' "$FAKE_INCUS_STATE/routes"

rmdir "$SANDBOX/sys/boxenbr0"
doctor
assert_contains "a missing host interface fails" "the host has no such interface" "$OUT"
mkdir "$SANDBOX/sys/boxenbr0"

echo 0 > "$SANDBOX/proc/net/ipv4/ip_forward"
doctor
assert_contains "forwarding off fails" "IPv4 forwarding is off" "$OUT"
echo 1 > "$SANDBOX/proc/net/ipv4/ip_forward"

mv "$FAKE_INCUS_STATE/procs" "$FAKE_INCUS_STATE/procs.off"
doctor
assert_contains "no DHCP server fails" "No DHCP server runs for boxenbr0" "$OUT"
assert_contains "with the fix" "sudo systemctl restart incus" "$OUT"
FAKE_INCUS_REMOTE=other doctor
assert_contains "a remote server's interfaces aren't checked" "isn't on this machine" "$OUT"
assert_not_contains "so it isn't blamed" "No DHCP server" "$OUT"
mv "$FAKE_INCUS_STATE/procs.off" "$FAKE_INCUS_STATE/procs"

echo "ENABLED=yes" > "$SANDBOX/ufw.conf"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/ufw"; chmod +x "$SANDBOX/bin/ufw"
BOXEN_UFW_CONF="$SANDBOX/ufw.conf" doctor
assert_contains "ufw without bxn's rules fails" "ufw is on, but bxn hasn't added its rules" "$OUT"
rm -f "$SANDBOX/bin/ufw"

incus launch img twin -p default -p boxen-net -d "eth0,ipv4.address=$(cfg box devices.eth0.ipv4.address)" >/dev/null
incus config set twin user.managed-by=boxen
doctor
assert_contains "two containers on one address fail" "box, twin share the address" "$OUT"
incus delete --force twin

incus init img half -p default -p boxen-net -d "eth0,ipv4.address=10.201.0.90" >/dev/null
doctor
assert_eq "an unlabelled container is only a warning" "0" "$RC"
assert_contains "it's named" "half is on boxenbr0 but isn't labelled" "$OUT"
incus delete --force half

echo "egress"
incus stop boxen-egress
doctor
assert_eq "a stopped egress container fails" "1" "$RC"
assert_contains "with the fix" "incus start boxen-egress" "$OUT"
incus start boxen-egress

incus config unset boxen-egress boot.autostart
doctor
assert_contains "no autostart is a warning" "doesn't start when the host boots" "$OUT"
incus config set boxen-egress boot.autostart=true

incus launch img gone -p default -p boxen-net -d "eth0,ipv4.address=10.201.0.91" >/dev/null
incus config set gone user.managed-by=boxen user.boxen.net=isolated
bash "$REPO_ROOT/bxn" egress mode gone enforce >/dev/null 2>&1
incus delete --force gone
doctor
assert_eq "a proxy left for a deleted container blocks nothing" "0" "$RC"
assert_contains "it's named" "still runs a proxy (port 10001) for gone" "$OUT"
assert_contains "with how to remove it" "boxen-egress-ctl remove gone" "$OUT"
assert_contains "and its rule set too" "Network rule set boxen-a-gone belongs to a container that's gone" "$OUT"

rm -rf "$FAKE_INCUS_STATE/ctl/boxen-egress/box"
doctor
assert_contains "a container with no proxy fails" "boxen-egress has no proxy for box" "$OUT"
assert_contains "with how to add it back" "boxen-egress-ctl add box 10000; then bxn egress refresh box" "$OUT"
FAKE_EGRESS_CTL_FAIL='^status$' doctor
assert_contains "a proxy manager that doesn't answer fails" "The proxy manager in boxen-egress doesn't answer" "$OUT"

incus config set box user.boxen.egress.transition=enforce:10.201.0.60
doctor
assert_contains "an interrupted lockdown fails" "box is partway through turning its allowlist on" "$OUT"
assert_contains "with the fix" "bxn egress refresh box" "$OUT"

echo "plugins"
assert_contains "the built-in plugins are reported" "ok    Optional plugins are the built-in ones" "$OUT"
mkdir -p "$SANDBOX/plugins-dir"
printf 'PLUGIN_ID="one"; PLUGIN_NAME="One"; PLUGIN_DESC="a plugin"\n' > "$SANDBOX/plugins-dir/50-one.sh"
printf 'PLUGIN_ID="two"; PLUGIN_NAME="Two"; PLUGIN_DESC="another"\n' > "$SANDBOX/plugins-dir/50-two.sh"
mkdir -p "$BOXEN_CONFIG_DIR"
echo "$SANDBOX/plugins-dir" > "$BOXEN_CONFIG_DIR/plugins-source"
doctor
assert_contains "a directory source is counted" "ok    Optional plugins from $SANDBOX/plugins-dir ($BOXEN_CONFIG_DIR/plugins-source): 2" "$OUT"
rm "$SANDBOX/plugins-dir"/*.sh
doctor
assert_contains "one without plugins fails" "FAIL  The plugin source $SANDBOX/plugins-dir ($BOXEN_CONFIG_DIR/plugins-source) has no plugins in $SANDBOX/plugins-dir" "$OUT"
assert_contains "with the fix" "bxn plugins update, or bxn plugins set builtin" "$OUT"
echo "$SANDBOX/gone" > "$BOXEN_CONFIG_DIR/plugins-source"
doctor
assert_eq "a source that isn't there blocks" "1" "$RC"
assert_contains "and says so" "FAIL  The plugin source $SANDBOX/gone ($BOXEN_CONFIG_DIR/plugins-source) isn't a repository or a directory on this host" "$OUT"
export XDG_DATA_HOME="$SANDBOX/data"
echo "acme/boxen-plugins" > "$BOXEN_CONFIG_DIR/plugins-source"
doctor
assert_contains "a repository not fetched yet warns" "warn  The plugins from acme/boxen-plugins haven't been fetched yet" "$OUT"
assert_contains "with the fix" "fix: bxn plugins update" "$OUT"
BOXEN_PLUGINS_SOURCE=builtin doctor
assert_contains "the variable beats the file" "ok    Optional plugins are the built-in ones" "$OUT"
rm "$BOXEN_CONFIG_DIR/plugins-source"

echo "help"
out="$(bash "$REPO_ROOT/bxn" doctor --help)"
assert_contains "doctor -h explains it" "Usage: bxn doctor" "$out"
assert_contains "bxn -h lists it" "doctor" "$(bash "$REPO_ROOT/bxn" -h)"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
