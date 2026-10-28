#!/usr/bin/env bash
# Spike, round 3: what round 2 left open.
#
#   T1  The in-sprite API socket answered PUT /policy/network with 405, so
#       the route exists. Can the sprite read or POST its own policy?
#   T2  Which plugin install domains does the `defaults` preset cover?
#       (Feeds PLUGIN_EGRESS_DOMAINS.)
#   T3  Live tightening: is a download already in flight cut off when its
#       domain is removed from the policy?
#
# Usage: ./sprite-spike-3.sh [sprite-name]
#   ORG=<org>   pass -o to every sprite command
#   KEEP=1      don't destroy the sprite at the end
#
# No credentials are printed: `sprite api` adds the token itself.

set -u

S="${1:-incs-spike3-$(date +%s)}"
LOG="./sprite-spike-$S.log"
ORG_ARGS=()
[[ -n "${ORG:-}" ]] && ORG_ARGS=(-o "$ORG")
POLICY_PATH="/v1/sprites/$S/policy/network"
BIG_HOST="speed.cloudflare.com"

RESULTS=()
note()   { printf '\n=== %s\n' "$*" | tee -a "$LOG"; }
result() { RESULTS+=("$1: $2"); printf '  -> %s: %s\n' "$1" "$2" | tee -a "$LOG"; }
run()    { printf '$ %s\n' "$*" >>"$LOG"; "$@" 2>&1 | tee -a "$LOG"; return "${PIPESTATUS[0]}"; }
sx()     { sprite exec "${ORG_ARGS[@]+"${ORG_ARGS[@]}"}" -s "$S" -- "$@"; }
sxq()    { sx "$@" 2>>"$LOG"; }

# Prints only the HTTP status; the body goes to the log.
api() {
  local path="$1"; shift
  printf '$ sprite api %s -- %s\n' "$path" "$*" >>"$LOG"
  sprite api "${ORG_ARGS[@]+"${ORG_ARGS[@]}"}" -s "$S" "$path" -- -s -w '\nHTTP %{http_code}\n' "$@" 2>>"$LOG" \
    | tee -a "$LOG" | awk '/^HTTP [0-9]+$/ {c=$2} END {print c}'
}
set_policy() { api "$POLICY_PATH" -X POST -H 'Content-Type: application/json' -d "$1"; }

# The same from inside the sprite, over the sprite-env socket.
inner() {
  printf '$ (inside) sprite-env curl %s\n' "$*" >>"$LOG"
  sxq sprite-env curl -s -w '\nHTTP %{http_code}\n' "$@" | tr -d '\r' \
    | tee -a "$LOG" | awk '/^HTTP [0-9]+$/ {c=$2} END {print c}'
}

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

note "Create $S"
run sprite create "${ORG_ARGS[@]+"${ORG_ARGS[@]}"}" --skip-console "$S" \
  || { echo "sprite create failed; see $LOG" >&2; exit 1; }
trap cleanup EXIT
run sx true || { echo "sprite exec failed; see $LOG" >&2; exit 1; }

code="$(set_policy '{"rules":[{"include":"defaults"}]}')"
result "setup: defaults policy" "HTTP $code"
sleep 3
result "setup: example.com blocked" "$(egress https://example.com)"

# ---------------------------------------------------------------------------
note "T1: can the sprite change its own policy over the API socket?"
for p in /policy/network /policy /v1/policy/network; do
  result "T1 inside GET $p" "HTTP $(inner "$p")"
done
for body in '{"rules":[]}' '{"rules":[{"domain":"*","action":"allow"}]}' '{"rules":[{"include":"defaults"},{"domain":"example.com","action":"allow"}]}'; do
  for m in POST PATCH; do
    code="$(inner -X "$m" -d "$body" /policy/network)"
    sleep 2
    result "T1 inside $m $body" "HTTP $code; example.com now $(egress https://example.com)"
  done
done
# Same attempts as root, in case the socket checks the caller.
code="$(sxq sudo -n sprite-env curl -s -o /dev/null -w '%{http_code}' -X POST -d '{"rules":[]}' /policy/network | tr -d '\r')"
sleep 2
result "T1 inside POST as root" "HTTP ${code:-?}; example.com now $(egress https://example.com)"
api "$POLICY_PATH" >/dev/null
result "T1 policy as seen from outside" "$(sprite api "${ORG_ARGS[@]+"${ORG_ARGS[@]}"}" -s "$S" "$POLICY_PATH" 2>/dev/null | tr -d '\n ' | grep -o '{"rules".*' | head -c 200)"
# Put defaults back in case anything above loosened it.
set_policy '{"rules":[{"include":"defaults"}]}' >/dev/null
sleep 2

# ---------------------------------------------------------------------------
note "T2: plugin install domains under the defaults preset"
# One URL per host the plugins fetch from (plugins/*.sh and incus.init).
for u in \
  https://archive.ubuntu.com/ubuntu/ \
  https://security.ubuntu.com/ubuntu/ \
  https://claude.ai/install.sh \
  https://downloads.claude.ai/ \
  https://mise.jdx.dev/gpg-key.pub \
  https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  https://download.docker.com/linux/ubuntu/gpg \
  https://registry-1.docker.io/v2/ \
  https://tailscale.com/install.sh \
  https://pkgs.tailscale.com/ \
  https://x.ai/cli/install.sh \
  https://just.systems/install.sh \
  https://cache.agilebits.com/dist/1P/op2/pkg/ \
  https://repo.charm.sh/apt/gpg.key \
  https://registry.npmjs.org/ \
  https://pypi.org/simple/ \
  https://files.pythonhosted.org/ \
  https://proxy.golang.org/ \
  https://objects.githubusercontent.com/ \
  https://release-assets.githubusercontent.com/ \
  https://raw.githubusercontent.com/ \
  https://codeload.github.com/ \
  https://playwright.azureedge.net/ \
  https://cdn.playwright.dev/ \
  https://googlechromelabs.github.io/chrome-for-testing/ \
  https://storage.googleapis.com/chrome-for-testing-public/ \
  https://api.openai.com/ \
  https://api.x.ai/ \
  https://cubic.dev/ \
  ; do
  r="$(egress "$u")"
  case "$r" in "000 exit=6"*) v="BLOCKED" ;; "000"*) v="no answer ($r)" ;; *) v="allowed ($r)" ;; esac
  result "T2 $(printf '%s' "$u" | sed -E 's#https?://([^/]+).*#\1#')" "$v"
done

# ---------------------------------------------------------------------------
note "T3: live tightening cuts an in-flight download"
set_policy "{\"rules\":[{\"include\":\"defaults\"},{\"domain\":\"$BIG_HOST\",\"action\":\"allow\"}]}" >/dev/null
sleep 3
sxq sh -c "nohup curl -s -m 90 --limit-rate 1M -o /tmp/big -w '%{http_code} exit=%{exitcode}\n' 'https://$BIG_HOST/__down?bytes=2000000000' > /tmp/held.out 2>&1 &"
sleep 6
before="$(sxq stat -c %s /tmp/big 2>/dev/null | tr -d '\r')"
result "T3 bytes before tightening" "${before:-0}"
set_policy '{"rules":[{"include":"defaults"}]}' >/dev/null
sleep 10
mid="$(sxq stat -c %s /tmp/big | tr -d '\r')"
sleep 10
after="$(sxq stat -c %s /tmp/big | tr -d '\r')"
result "T3 bytes 10s / 20s after" "${mid:-?} / ${after:-?}"
if [[ -n "$mid" && "$mid" == "$after" ]]; then
  result "T3 verdict" "cut off (no growth after tightening); curl said: $(sxq cat /tmp/held.out | tr -d '\r')"
else
  result "T3 verdict" "STILL FLOWING after tightening"
fi
result "T3 new connection to $BIG_HOST" "$(egress "https://$BIG_HOST/")"

# ---------------------------------------------------------------------------
printf '\n========== SUMMARY (%s) ==========\n' "$S" | tee -a "$LOG"
for r in "${RESULTS[@]}"; do printf '%s\n' "$r"; done | tee -a "$LOG"
echo "Full log: $LOG"
