#!/usr/bin/env bash
# Spike: answer the open questions before an incs --sprite backend.
#
#   Q1  Does `sprite exec` run as root or as `sprite`? Passwordless sudo?
#   Q2  Does exec forward stdin? Do --file and --env work?
#   Q3  systemd, or only `sprite-env services`?
#   Q4  Does Docker run inside a sprite?          (DOCKER=1, slow)
#   Q5  Can a new sprite start from a checkpoint?
#   Q6  What does the network-policy API look like?
#
# Usage: ./sprite-spike.sh [sprite-name]
#   ORG=<org>   pass -o to every sprite command
#   KEEP=1      don't destroy the sprite at the end
#   DOCKER=1    install Docker and run hello-world (several minutes)
#
# Read-only apart from the probe sprite it creates. Prints no credentials:
# `sprite api` adds the token itself, and no probe runs curl verbosely.

set -u

S="${1:-incs-spike-$(date +%s)}"
LOG="./sprite-spike-$S.log"
ORG_ARGS=()
[[ -n "${ORG:-}" ]] && ORG_ARGS=(-o "$ORG")
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/sprite-spike.XXXXXX")"

RESULTS=()
note()    { printf '\n=== %s\n' "$*" | tee -a "$LOG"; }
result()  { RESULTS+=("$1: $2"); printf '  -> %s: %s\n' "$1" "$2" | tee -a "$LOG"; }
run()     { printf '$ %s\n' "$*" >>"$LOG"; "$@" 2>&1 | tee -a "$LOG"; return "${PIPESTATUS[0]}"; }
sx()      { sprite exec "${ORG_ARGS[@]+"${ORG_ARGS[@]}"}" -s "$S" -- "$@"; }
sxq()     { sx "$@" 2>>"$LOG"; }   # stdout only, stderr to the log

cleanup() {
  rm -rf "$TMPD"
  if [[ "${KEEP:-0}" == "1" ]]; then
    echo "Kept sprite $S. Destroy it with: sprite destroy -s $S --force"
  else
    sprite destroy "${ORG_ARGS[@]+"${ORG_ARGS[@]}"}" -s "$S" --force >>"$LOG" 2>&1 \
      || echo "Could not destroy $S; run: sprite destroy -s $S --force"
  fi
}

command -v sprite >/dev/null || { echo "sprite CLI not found" >&2; exit 1; }
: >"$LOG"
echo "Logging to $LOG"

note "CLI version and help (for flags the docs don't list)"
run sprite --version
run sprite --help
run sprite create --help
run sprite checkpoint --help
run sprite api --help

note "Create $S"
run sprite create "${ORG_ARGS[@]+"${ORG_ARGS[@]}"}" --skip-console "$S" \
  || { echo "sprite create failed; see $LOG" >&2; exit 1; }
trap cleanup EXIT
run sx true || { echo "sprite exec failed; see $LOG" >&2; exit 1; }

# ---------------------------------------------------------------------------
note "Q1: exec user, sudo, OS"
run sx sh -c 'id; echo "HOME=$HOME SHELL=$SHELL PWD=$PWD"; uname -a; cat /etc/os-release'
who="$(sxq id -un | tr -d '\r')"
result "Q1 exec user" "${who:-unknown}"
if [[ "$who" == "root" ]]; then
  result "Q1 root" "yes, exec is root"
elif sxq sudo -n true; then
  result "Q1 root" "via passwordless sudo"
  run sx sudo -n id
else
  result "Q1 root" "NO root and no passwordless sudo"
fi
run sx sh -c 'ls -ld /home/*; getent passwd sprite || true'

# ---------------------------------------------------------------------------
note "Q2: stdin, --file, --env, exit codes"
got="$(printf 'stdin-ok\n' | sx cat 2>>"$LOG" | tr -d '\r')"
[[ "$got" == "stdin-ok" ]] && result "Q2 stdin pipe" "forwarded" || result "Q2 stdin pipe" "NOT forwarded (got '${got}')"

got="$(sx bash -s 2>>"$LOG" <<'EOF' | tr -d '\r'
echo heredoc-ok
EOF
)"
[[ "$got" == "heredoc-ok" ]] && result "Q2 heredoc" "works" || result "Q2 heredoc" "fails (got '${got}')"

# A tar stream, the way copy_workspace pipes the tree in today.
mkdir -p "$TMPD/tree/sub" && echo x >"$TMPD/tree/sub/f"
got="$(tar -C "$TMPD/tree" -cf - . | sx sh -c 'd=$(mktemp -d); tar -C "$d" -xf - && cat "$d/sub/f"' 2>>"$LOG" | tr -d '\r')"
[[ "$got" == "x" ]] && result "Q2 tar over stdin" "works" || result "Q2 tar over stdin" "fails"

printf 'echo file-ok\n' >"$TMPD/probe.sh"
got="$(sprite exec "${ORG_ARGS[@]+"${ORG_ARGS[@]}"}" -s "$S" --file "$TMPD/probe.sh:/tmp/probe.sh" -- \
  sh -c 'ls -l /tmp/probe.sh >&2; sh /tmp/probe.sh; rm -f /tmp/probe.sh' 2>>"$LOG" | tr -d '\r')"
[[ "$got" == "file-ok" ]] && result "Q2 --file" "works" || result "Q2 --file" "fails (got '${got}')"

got="$(sprite exec "${ORG_ARGS[@]+"${ORG_ARGS[@]}"}" -s "$S" --env SPIKE_A=1,SPIKE_B=two -- \
  sh -c 'echo "$SPIKE_A/$SPIKE_B"' 2>>"$LOG" | tr -d '\r')"
[[ "$got" == "1/two" ]] && result "Q2 --env" "works" || result "Q2 --env" "fails (got '${got}')"

sx sh -c 'exit 7' >>"$LOG" 2>&1; rc=$?
[[ "$rc" == "7" ]] && result "Q2 exit code" "propagated" || result "Q2 exit code" "NOT propagated (got $rc)"

# ---------------------------------------------------------------------------
note "Q3: init system and services"
pid1="$(sxq sh -c 'cat /proc/1/comm' | tr -d '\r')"
result "Q3 PID 1" "${pid1:-unknown}"
run sx sh -c 'command -v systemctl && systemctl is-system-running; true'
if sxq sh -c 'command -v sprite-env' >/dev/null; then
  run sx sprite-env --help
  run sx sprite-env services --help
  run sx sprite-env services create --help
  run sx sprite-env services list
  result "Q3 sprite-env" "present; see the help output in the log for create's flags"
else
  result "Q3 sprite-env" "not on PATH"
fi

# ---------------------------------------------------------------------------
note "Q4: Docker prerequisites"
run sx sh -c 'uname -r; stat -fc %T /sys/fs/cgroup; grep -E "overlay|nf_tables|ip_tables" /proc/filesystems /proc/modules 2>/dev/null; ls -l /dev/net/tun 2>&1; ls -l /dev/kvm 2>&1'
if [[ "${DOCKER:-0}" == "1" ]]; then
  SUDO=""; [[ "$who" != "root" ]] && SUDO="sudo -n"
  run sx sh -c "curl -fsSL https://get.docker.com | $SUDO sh"
  # Without systemd, start dockerd detached and see whether it survives exec.
  run sx sh -c "$SUDO sh -c 'pgrep dockerd || (setsid nohup dockerd >/tmp/dockerd.log 2>&1 &)'; sleep 5; $SUDO docker info >/dev/null && echo dockerd-up"
  if sxq sh -c "$SUDO docker run --rm hello-world" | grep -q 'Hello from Docker'; then
    result "Q4 docker" "hello-world runs"
    run sx sh -c "$SUDO docker run --rm -p 18080:80 -d --name spike-nginx nginx:alpine && sleep 3 && curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18080"
  else
    result "Q4 docker" "FAILED; see /tmp/dockerd.log in the log"
    run sx sh -c 'tail -40 /tmp/dockerd.log'
  fi
else
  result "Q4 docker" "skipped (rerun with DOCKER=1)"
fi

# ---------------------------------------------------------------------------
note "Q5: checkpoints"
sx sh -c 'echo checkpoint-marker > ~/spike-marker'
run sprite checkpoint create "${ORG_ARGS[@]+"${ORG_ARGS[@]}"}" -s "$S" --comment "incs spike"
run sprite checkpoint list "${ORG_ARGS[@]+"${ORG_ARGS[@]}"}" -s "$S"
run sprite api "${ORG_ARGS[@]+"${ORG_ARGS[@]}"}" -s "$S" "/v1/sprites/$S/checkpoints"
if sprite --help 2>&1 | grep -Eiq 'clone|fork|from-checkpoint'; then
  result "Q5 seed from checkpoint" "CLI mentions clone/fork; check the help in the log"
else
  result "Q5 seed from checkpoint" "no clone/fork in CLI help; check API docs/forum by hand"
fi
# Restore round trip: the marker must come back after deletion.
ver="$(sprite checkpoint list "${ORG_ARGS[@]+"${ORG_ARGS[@]}"}" -s "$S" 2>/dev/null | grep -i 'incs spike' | grep -Eo 'v[0-9]+' | head -1)"
if [[ -n "$ver" ]]; then
  sx rm -f ~/spike-marker 2>>"$LOG"
  run sprite restore "${ORG_ARGS[@]+"${ORG_ARGS[@]}"}" -s "$S" "$ver"
  got="$(sxq sh -c 'cat ~/spike-marker 2>/dev/null' | tr -d '\r')"
  [[ "$got" == "checkpoint-marker" ]] && result "Q5 restore" "round trip works ($ver)" || result "Q5 restore" "marker missing after restore"
else
  result "Q5 restore" "could not find the checkpoint version in the list output"
fi

# ---------------------------------------------------------------------------
note "Q6: network policy API"
for p in policy network-policy policy/network network; do
  echo "--- GET /v1/sprites/$S/$p" | tee -a "$LOG"
  run sprite api "${ORG_ARGS[@]+"${ORG_ARGS[@]}"}" -s "$S" "/v1/sprites/$S/$p" -- -s -w '\nHTTP %{http_code}\n'
done
result "Q6 policy API" "see which GET above returned 200 and its JSON shape"
# Baseline egress before any policy, to compare against after one is applied.
for u in https://github.com https://api.anthropic.com https://example.com https://1.1.1.1; do
  code="$(sxq curl -s -o /dev/null -m 8 -w '%{http_code}' "$u" | tr -d '\r')"
  result "Q6 egress $u" "${code:-no response}"
done

# ---------------------------------------------------------------------------
printf '\n========== SUMMARY (%s) ==========\n' "$S" | tee -a "$LOG"
for r in "${RESULTS[@]}"; do printf '%s\n' "$r"; done | tee -a "$LOG"
echo "Full log: $LOG"
