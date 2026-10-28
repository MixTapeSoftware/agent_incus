#!/usr/bin/env bash
# Spike, round 2: what round 1 left open.
#
#   R1  Where does the sprite user's sudo come from, and can exec run as
#       another user? (Can we revoke root after provisioning?)
#   R2  What's preinstalled? (zsh, agents, gh, mise, node...)
#   R3  Docker on Ubuntu 26.04: does Docker's apt repo have it, and does
#       dockerd run as a sprite-env service?
#   R4  Network policy: how to write it, whether it's enforced (domains,
#       raw IPs, private IPs, SNI/Host tricks), and whether root inside the
#       sprite can loosen it.
#
# Usage: ./sprite-spike-2.sh [sprite-name]
#   ORG=<org>   pass -o to every sprite command
#   KEEP=1      don't destroy the sprite at the end
#   NO_DOCKER=1 skip R3 (it installs packages; a few minutes)
#
# Tamper tests run as root inside the probe sprite only. No credentials are
# printed: `sprite api` adds the token itself.

set -u

S="${1:-incs-spike2-$(date +%s)}"
LOG="./sprite-spike-$S.log"
ORG_ARGS=()
[[ -n "${ORG:-}" ]] && ORG_ARGS=(-o "$ORG")
POLICY_PATH="/v1/sprites/$S/policy/network"

RESULTS=()
note()   { printf '\n=== %s\n' "$*" | tee -a "$LOG"; }
result() { RESULTS+=("$1: $2"); printf '  -> %s: %s\n' "$1" "$2" | tee -a "$LOG"; }
run()    { printf '$ %s\n' "$*" >>"$LOG"; "$@" 2>&1 | tee -a "$LOG"; return "${PIPESTATUS[0]}"; }
sx()     { sprite exec "${ORG_ARGS[@]+"${ORG_ARGS[@]}"}" -s "$S" -- "$@"; }
sxq()    { sx "$@" 2>>"$LOG"; }

# sprite api with the HTTP status on a trailing line; prints only the status.
api() {
  local path="$1"; shift
  printf '$ sprite api %s -- %s\n' "$path" "$*" >>"$LOG"
  sprite api "${ORG_ARGS[@]+"${ORG_ARGS[@]}"}" -s "$S" "$path" -- -s -w '\nHTTP %{http_code}\n' "$@" 2>>"$LOG" \
    | tee -a "$LOG" | awk '/^HTTP [0-9]+$/ {c=$2} END {print c}'
}

# Egress from inside: "<http code> exit=<curl exit>". Exit 60 (bad cert) or
# 51 means the connection got through; 6/7/28/35/56 mean it was stopped.
egress() {
  sxq sh -c 'code=$(curl -s -o /dev/null -m 8 -w "%{http_code}" "$@"); echo "$code exit=$?"' _ "$@" | tr -d '\r'
}

cleanup() {
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

note "Help for the commands round 1 didn't cover"
run sprite exec --help
run sprite config --help
run sprite file --help

note "Create $S"
run sprite create "${ORG_ARGS[@]+"${ORG_ARGS[@]}"}" --skip-console "$S" \
  || { echo "sprite create failed; see $LOG" >&2; exit 1; }
trap cleanup EXIT
run sx true || { echo "sprite exec failed; see $LOG" >&2; exit 1; }

# ---------------------------------------------------------------------------
note "R1: where sudo comes from"
run sx sh -c 'sudo -n -l; sudo -n sh -c "ls -l /etc/sudoers.d; grep -rn . /etc/sudoers.d; grep -n sprite /etc/sudoers /etc/group"'
src="$(sxq sudo -n grep -rln 'sprite' /etc/sudoers /etc/sudoers.d | tr -d '\r' | tr '\n' ' ')"
result "R1 sudo granted by" "${src:-not found in sudoers (group? see log)}"
if sprite exec --help 2>&1 | grep -Eiq -- '--user|-u,'; then
  result "R1 exec as another user" "exec has a user flag; see help in log"
else
  result "R1 exec as another user" "no user flag: once sudo is revoked, exec has no way back to root"
fi

# ---------------------------------------------------------------------------
note "R2: preinstalled tools"
run sx bash -lc 'for c in zsh tmux git gh mise node npm python3 go rustc nvim rg fzf jq unzip claude codex gemini grok cursor-agent docker tailscale; do printf "%-14s %s\n" "$c" "$(command -v $c || echo -)"; done; getent passwd sprite'
have="$(sxq bash -lc 'for c in zsh gh mise claude docker; do command -v $c >/dev/null && printf "%s " $c; done' | tr -d '\r')"
result "R2 present (of zsh gh mise claude docker)" "${have:-none}"

# ---------------------------------------------------------------------------
note "R3: Docker"
if [[ "${NO_DOCKER:-0}" == "1" ]]; then
  result "R3 docker" "skipped (NO_DOCKER=1)"
else
  rel="$(sxq sh -c 'curl -s -o /dev/null -w "%{http_code}" https://download.docker.com/linux/ubuntu/dists/$(. /etc/os-release; echo $VERSION_CODENAME)/Release' | tr -d '\r')"
  result "R3 download.docker.com has this release" "HTTP ${rel:-?} (200 = yes)"
  # Ubuntu's own docker.io works whatever Docker's repo supports.
  run sx sh -c 'sudo -n DEBIAN_FRONTEND=noninteractive apt-get update -qq && sudo -n DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io >/dev/null && docker --version'
  run sx sprite-env services create dockerd --cmd /usr/bin/sudo --args -n,/usr/bin/dockerd --no-stream
  sleep 5
  run sx sprite-env services get dockerd
  if sxq sh -c 'for i in 1 2 3 4 5 6; do sudo -n docker info >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1'; then
    result "R3 dockerd as a service" "up"
    if sxq sudo -n docker run --rm hello-world | grep -q 'Hello from Docker'; then
      result "R3 docker run" "hello-world runs"
      got="$(sxq sh -c 'sudo -n docker run -d --rm -p 18080:80 --name spike-nginx nginx:alpine >/dev/null && sleep 3 && curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:18080; sudo -n docker rm -f spike-nginx >/dev/null' | tr -d '\r')"
      result "R3 port publish" "nginx answered ${got:-nothing}"
      got="$(sxq sh -c 'sudo -n docker run --rm alpine sh -c "echo inner-ok"' | tr -d '\r')"
      result "R3 container networking" "${got:-failed}"
    else
      result "R3 docker run" "FAILED"
    fi
  else
    result "R3 dockerd as a service" "did not come up"
  fi
  run sx sh -c 'tail -30 /.sprite/logs/services/dockerd.log 2>/dev/null'
fi

# ---------------------------------------------------------------------------
note "R4: network policy"
run sx sh -c 'ls -l /.sprite/policy/ 2>&1; cat /.sprite/policy/network.json 2>&1'
api "$POLICY_PATH" >/dev/null

POLICY='{"rules":[{"include":"defaults"},{"domain":"api.anthropic.com","action":"allow"}]}'
method=""
for m in PUT POST PATCH; do
  code="$(api "$POLICY_PATH" -X "$m" -H 'Content-Type: application/json' -d "$POLICY")"
  echo "  $m -> HTTP $code" | tee -a "$LOG"
  case "$code" in 2??) method="$m"; break ;; esac
done
result "R4 write method" "${method:-none of PUT/POST/PATCH worked; see log}"

if [[ -n "$method" ]]; then
  sleep 3
  api "$POLICY_PATH" >/dev/null
  run sx sh -c 'cat /.sprite/policy/network.json 2>&1'
  result "R4 github.com (defaults)"   "$(egress https://github.com)"
  result "R4 api.anthropic.com (rule)" "$(egress https://api.anthropic.com)"
  result "R4 example.com (not allowed)" "$(egress https://example.com)"
  result "R4 raw IP 1.1.1.1"          "$(egress https://1.1.1.1)"
  result "R4 metadata 169.254.169.254" "$(egress http://169.254.169.254/)"
  result "R4 private 10.0.0.1"        "$(egress -k https://10.0.0.1)"
  # Allowed IP, blocked name: is enforcement by DNS, by SNI, or both?
  result "R4 example.com via github's IP" "$(egress --connect-to example.com:443:github.com:443 https://example.com)"
  # Allowed name in SNI, blocked Host header.
  result "R4 Host: example.com to github" "$(egress -H 'Host: example.com' https://github.com)"
  run sx sh -c 'getent hosts example.com || echo "example.com does not resolve"'

  note "R4 tamper: root inside the sprite tries to loosen the policy"
  run sx sudo -n sh -c 'echo "{\"rules\":[]}" > /.sprite/policy/network.json; echo "write exit=$?"'
  sleep 3
  result "R4 after root rewrites network.json, example.com" "$(egress https://example.com)"
  run sx sprite-env curl --help
  for p in "$POLICY_PATH" /v1/policy/network /policy/network; do
    run sx sprite-env curl -s -w '\nHTTP %{http_code}\n' -X PUT -H 'Content-Type: application/json' -d '{"rules":[]}' "$p"
  done
  sleep 3
  result "R4 after sprite-env curl PUT, example.com" "$(egress https://example.com)"
  run sx sudo -n sh -c 'command -v nft && nft list ruleset; command -v iptables && iptables -S'
  run sx sudo -n sh -c '(command -v nft && nft flush ruleset); (command -v iptables && iptables -P OUTPUT ACCEPT && iptables -F); true'
  sleep 2
  result "R4 after flushing nft/iptables, example.com" "$(egress https://example.com)"
  api "$POLICY_PATH" >/dev/null

  note "R4 live tightening"
  # A connection held open across the change should be dropped.
  sx sh -c 'nohup curl -s -m 60 -o /dev/null -w "%{http_code} exit=%{exitcode}\n" https://speed.cloudflare.com/__down?bytes=500000000 > /tmp/held.out 2>&1 &' 2>>"$LOG"
  sleep 4
  api "$POLICY_PATH" -X "$method" -H 'Content-Type: application/json' \
    -d '{"rules":[{"domain":"github.com","action":"allow"}]}' >/dev/null
  sleep 8
  result "R4 held download after tightening" "$(sxq sh -c 'if pgrep -x curl >/dev/null; then echo "still running"; else cat /tmp/held.out; fi' | tr -d '\r')"
fi

# ---------------------------------------------------------------------------
printf '\n========== SUMMARY (%s) ==========\n' "$S" | tee -a "$LOG"
for r in "${RESULTS[@]}"; do printf '%s\n' "$r"; done | tee -a "$LOG"
echo "Full log: $LOG"
