#!/bin/bash
# tests/proxy_test.sh
# Behavior tests for `incs proxy` against a stateful fake `incus`.
# Run: bash tests/proxy_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Anything that reads stdin gets an explicit pipe. Without this, a command that
# reads stdin would block on whatever the test runner happened to inherit.
exec </dev/null

PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS+1)); echo "  ok  $label"
  else
    FAIL=$((FAIL+1)); echo "  FAIL $label"
    echo "    expected: $expected"
    echo "    actual:   $actual"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS+1)); echo "  ok  $label"
  else
    FAIL=$((FAIL+1)); echo "  FAIL $label"
    echo "    expected to contain: $needle"
    echo "    actual: $haystack"
  fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS=$((PASS+1)); echo "  ok  $label"
  else
    FAIL=$((FAIL+1)); echo "  FAIL $label"
    echo "    expected NOT to contain: $needle"
  fi
}

# ---------------------------------------------------------------------------
# Harness: each scenario gets a fresh fake incus state.
# ---------------------------------------------------------------------------
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin"
cp "$SCRIPT_DIR/lib/fake_incus" "$SANDBOX/bin/incus"
chmod +x "$SANDBOX/bin/incus"
export PATH="$SANDBOX/bin:$PATH"

fresh_state() {
  export FAKE_INCUS_STATE="$SANDBOX/state-$RANDOM$RANDOM"
  mkdir -p "$FAKE_INCUS_STATE"
  unset FAKE_INCUS_FAIL_EXEC FAKE_INCUS_NEXT_IP
}

incs() { bash "$REPO_ROOT/incs" "$@"; }
cfg()  { incus config get "$1" "$2"; }
fs()   { echo "$FAKE_INCUS_STATE/instances/$1/root$2"; }

# An agent container as incus.init leaves it: tagged, running, with a user.
make_agent() {
  local name="$1"
  incus launch images:ubuntu/24.04 "$name"
  incus config set "$name" user.managed-by=agent-incus
}

# A proxy as `incs proxy new` leaves it, including what provisioning creates
# inside the container (the fake cannot run apt/openssl).
make_proxy() {
  local name="$1"
  printf 'ops_token_for_%s\n' "$name" | incs proxy new "$name" >/dev/null 2>&1
  mkdir -p "$(fs "$name" /etc/iron-proxy)"
  echo "CERT-OF-$name" > "$(fs "$name" /etc/iron-proxy/ca.crt)"
}

USER_NAME="$(id -un)"

# ===========================================================================
echo "proxy new"
# ===========================================================================
fresh_state
FAKE_INCUS_NEXT_IP=10.99.0.42 \
  bash -c 'printf "ops_SECRET_service_token\n" | bash "$0/incs" proxy new work' "$REPO_ROOT" \
  > "$SANDBOX/out" 2>&1 || { echo "  (proxy new exited non-zero)"; cat "$SANDBOX/out"; }

assert_eq "creates the instance"            "RUNNING" "$(incus list '^work$' --format csv --columns s)"
assert_eq "tags it as a proxy"              "proxy"   "$(cfg work user.incs.role)"
assert_eq "is not tagged as an agent container (kill-all/update-all skip it)" \
                                            ""        "$(cfg work user.managed-by)"
assert_eq "pins the leased address"         "10.99.0.42" "$(cfg work devices.eth0.ipv4.address)"
assert_eq "records the address"             "10.99.0.42" "$(cfg work user.incs.proxy-ip)"
assert_eq "default vault"                   "agent-tokens" "$(cfg work user.incs.proxy-vault)"
assert_eq "service token lands in the env file" \
  "OP_SERVICE_ACCOUNT_TOKEN=ops_SECRET_service_token" \
  "$(grep '^OP_SERVICE_ACCOUNT_TOKEN=' "$(fs work /etc/iron-proxy/env)" 2>/dev/null || true)"
assert_not_contains "service token never appears in argv" \
  "ops_SECRET_service_token" "$(cat "$FAKE_INCUS_STATE/calls.log")"
assert_not_contains "service token is not echoed to the terminal" \
  "ops_SECRET_service_token" "$(cat "$SANDBOX/out")"
assert_eq "base config listens for containers on the tunnel port" \
  '  tunnel_listen: "0.0.0.0:8888"' \
  "$(grep 'tunnel_listen' "$(fs work /etc/iron-proxy/base.yaml)" 2>/dev/null || true)"

fresh_state
incus launch images:ubuntu/24.04 taken
out="$(printf 'tok\n' | incs proxy new taken 2>&1)" && rc=0 || rc=$?
assert_eq "refuses a name already in use: exit code" "1" "$rc"
assert_contains "refuses a name already in use: message" "already exists" "$out"

fresh_state
out="$(printf 'tok\n' | incs proxy new 'bad name!' 2>&1)" && rc=0 || rc=$?
assert_eq "rejects an invalid name" "1" "$rc"
assert_eq "invalid name creates nothing" "" "$(incus list --format csv --columns n)"

fresh_state
printf 'tok\n' | incs proxy new acme --vault acme-agents >/dev/null 2>&1 || true
assert_eq "--vault overrides the default vault" "acme-agents" "$(cfg acme user.incs.proxy-vault)"

# Terminals can wrap a paste in focus-reporting escape sequences.
fresh_state
printf '\033[Oops_PASTED_token\033[I\n' | incs proxy new pasted >/dev/null 2>&1 || true
assert_eq "service token pasted with terminal escapes is stored clean" \
  "OP_SERVICE_ACCOUNT_TOKEN=ops_PASTED_token" \
  "$(grep '^OP_SERVICE_ACCOUNT_TOKEN=' "$(fs pasted /etc/iron-proxy/env)" 2>/dev/null || true)"

fresh_state
printf '\n' | incs proxy new plain >/dev/null 2>&1 || true
assert_eq "blank token: no 1Password line in the env file" \
  "" "$(grep 'OP_SERVICE_ACCOUNT_TOKEN' "$(fs plain /etc/iron-proxy/env)" 2>/dev/null || true)"
assert_eq "blank token: proxy is still created" "proxy" "$(cfg plain user.incs.role)"

fresh_state
out="$(printf 'ops_SECRET\n' | FAKE_INCUS_FAIL_EXEC='^bash -s' incs proxy new broken 2>&1)" && rc=0 || rc=$?
assert_eq "provisioning failure: exits non-zero" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
assert_eq "provisioning failure: half-built proxy (holding a token) is removed" \
  "" "$(incus list '^broken$' --format csv --columns n)"

fresh_state
out="$(printf 'ops_SECRET\n' | FAKE_INCUS_FAIL_EXEC='^systemctl is-active' incs proxy new dead 2>&1)" && rc=0 || rc=$?
assert_eq "service not running after setup: exits non-zero" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
assert_contains "service not running after setup: says so" "not running" "$out"
assert_eq "service not running after setup: proxy is removed" \
  "" "$(incus list '^dead$' --format csv --columns n)"

# ===========================================================================
echo "proxy add"
# ===========================================================================
REAL_TOKEN="github_pat_REAL_token_from_before"
ZSHENV="/home/$USER_NAME/.zshenv"

# A container the way the GitHub auth plugin leaves it: real token in both
# the incus environment and ~/.zshenv, next to unrelated settings.
make_agent_with_real_token() {
  local name="$1"
  make_agent "$name"
  incus config set "$name" "environment.GH_TOKEN=$REAL_TOKEN"
  printf 'export EDITOR=nvim\nexport GH_TOKEN=%s\nexport FOO=bar\n' "$REAL_TOKEN" \
    | incus file push -p - "$name$ZSHENV"
}

fresh_state
FAKE_INCUS_NEXT_IP=10.99.0.7 make_proxy work
make_agent_with_real_token proj
out="$(incs proxy add proj work 2>&1)" && rc=0 || rc=$?
assert_eq "add: succeeds" "0" "$rc"

ph="$(cfg proj environment.GH_TOKEN)"
entry="$(cat "$(fs work /etc/iron-proxy/entries/proj--github.yaml)" 2>/dev/null || true)"
zshenv="$(cat "$(fs proj "$ZSHENV")" 2>/dev/null || true)"
built="$(cat "$(fs work /etc/iron-proxy/proxy.yaml)" 2>/dev/null || true)"

assert_eq "placeholder is shaped like a GitHub token" \
  "match" "$([[ "$ph" =~ ^ghp_[0-9a-f]{36}$ ]] && echo match || echo "no match: $ph")"
assert_contains "proxy entry maps that placeholder"       "proxy_value: \"$ph\"" "$entry"
assert_contains "entry reads from the default vault path" 'secret_ref: "op://agent-tokens/proj/credential"' "$entry"
assert_contains "entry is a 1Password source"             "type: 1password" "$entry"
assert_contains "entry is bound to github.com"            '- host: "github.com"' "$entry"
assert_contains "entry is bound to api.github.com"        '- host: "api.github.com"' "$entry"
assert_contains "rebuilt config includes the entry"       "proxy_value: \"$ph\"" "$built"
assert_contains "rebuilt config keeps the base settings"  'tunnel_listen: "0.0.0.0:8888"' "$built"

assert_not_contains "real token removed from ~/.zshenv"   "$REAL_TOKEN" "$zshenv"
assert_contains "~/.zshenv exports the placeholder"       "export GH_TOKEN=$ph" "$zshenv"
assert_contains "~/.zshenv routes HTTPS through the proxy" "export HTTPS_PROXY=http://10.99.0.7:8888" "$zshenv"
assert_contains "~/.zshenv keeps unrelated settings (before)" "export EDITOR=nvim" "$zshenv"
assert_contains "~/.zshenv keeps unrelated settings (after)"  "export FOO=bar" "$zshenv"
assert_contains "tailnet names bypass the proxy"          ".ts.net" "$(grep '^export NO_PROXY=' <<<"$zshenv" || true)"
assert_eq "real token is replaced in the incus environment too" \
  "placeholder" "$([[ "$ph" != "$REAL_TOKEN" && -n "$ph" ]] && echo placeholder || echo "real or empty")"
# Root sessions (nightly apt updates) and daemons must keep connecting directly.
assert_eq "proxy settings stay out of the incus environment" \
  "" "$(cfg proj environment.HTTPS_PROXY)$(cfg proj environment.https_proxy)$(cfg proj environment.HTTP_PROXY)"

assert_eq "container trusts this proxy's certificate authority" \
  "CERT-OF-work" "$(cat "$(fs proj /usr/local/share/ca-certificates/incs-proxy.crt)" 2>/dev/null || true)"
assert_contains "trust store is refreshed" \
  "proj :: update-ca-certificates" "$(cat "$FAKE_INCUS_STATE/exec.log")"
assert_eq "container is tagged with its proxy" "work" "$(cfg proj user.incs.proxy)"
assert_not_contains "placeholder is not printed" "$ph" "$out"

# Real credentials stored outside GH_TOKEN are left alone, but reported.
fresh_state
make_proxy work
make_agent proj
printf 'github.com:\n    oauth_token: gho_REAL\n    user: ada\n' \
  | incus file push -p - "proj/home/$USER_NAME/.config/gh/hosts.yml"
printf 'https://ada:ghp_REAL@github.com\n' | incus file push -p - "proj/home/$USER_NAME/.git-credentials"
out="$(incs proxy add proj work 2>&1)" && rc=0 || rc=$?
assert_contains "warns about a token stored by gh auth login" ".config/gh/hosts.yml" "$out"
assert_contains "warns about git's plain-text credential store" ".git-credentials" "$out"
assert_eq "does not delete the user's files" \
  "kept" "$([[ -f "$(fs proj "/home/$USER_NAME/.git-credentials")" ]] && echo kept || echo deleted)"

fresh_state
make_proxy work
make_agent proj
out="$(incs proxy add proj work 2>&1)"
assert_not_contains "no warning when no other credentials exist" "hosts.yml" "$out"

# Re-adding rotates the placeholder and leaves no duplicates behind.
incs proxy add proj work >/dev/null 2>&1
ph2="$(cfg proj environment.GH_TOKEN)"
zshenv="$(cat "$(fs proj "$ZSHENV")")"
assert_eq "re-add: placeholder rotates" "rotated" "$([[ -n "$ph2" && "$ph2" != "$ph" ]] && echo rotated || echo same)"
assert_eq "re-add: one GH_TOKEN line"   "1" "$(grep -c '^export GH_TOKEN=' <<<"$zshenv")"
assert_eq "re-add: one HTTPS_PROXY line" "1" "$(grep -c '^export HTTPS_PROXY=' <<<"$zshenv")"
assert_eq "re-add: one entry in the rebuilt config" \
  "1" "$(grep -c 'proxy_value:' "$(fs work /etc/iron-proxy/proxy.yaml)")"
assert_not_contains "re-add: old placeholder no longer honored" \
  "$ph" "$(cat "$(fs work /etc/iron-proxy/proxy.yaml)")"

# Two containers on one proxy.
make_agent other
incs proxy add other work >/dev/null 2>&1
ph_other="$(cfg other environment.GH_TOKEN)"
built="$(cat "$(fs work /etc/iron-proxy/proxy.yaml)")"
assert_eq "two containers get different placeholders" \
  "different" "$([[ -n "$ph_other" && "$ph_other" != "$ph2" ]] && echo different || echo same)"
assert_contains "config holds the first container's entry"  "op://agent-tokens/proj/credential" "$built"
assert_contains "config holds the second container's entry" "op://agent-tokens/other/credential" "$built"

# --ref and the proxy's vault.
fresh_state
printf 'tok\n' | incs proxy new acme --vault acme-agents >/dev/null 2>&1
echo CERT > "$(fs acme /etc/iron-proxy/ca.crt)"
make_agent a1; make_agent a2
incs proxy add a1 acme >/dev/null 2>&1
incs proxy add a2 acme --ref "op://Shared Vault/My Item/token" >/dev/null 2>&1
assert_contains "default ref uses the proxy's vault" \
  'secret_ref: "op://acme-agents/a1/credential"' "$(cat "$(fs acme /etc/iron-proxy/entries/a1--github.yaml)")"
assert_contains "--ref overrides the reference (spaces allowed)" \
  'secret_ref: "op://Shared Vault/My Item/token"' "$(cat "$(fs acme /etc/iron-proxy/entries/a2--github.yaml)")"

out="$(incs proxy add a1 acme --ref 'op://v/i/f"
  injected: true' 2>&1)" && rc=0 || rc=$?
assert_eq "--ref that could break out of the YAML string is rejected" "1" "$rc"
out="$(incs proxy add a1 acme --ref 'https://example.com/x' 2>&1)" && rc=0 || rc=$?
assert_eq "--ref must be an op:// reference" "1" "$rc"

# --token: real token is stored in the proxy, never in the agent container.
fresh_state
make_proxy work
make_agent proj
out="$(printf 'github_pat_TYPED_in\n' | incs proxy add proj work --token 2>&1)" && rc=0 || rc=$?
assert_eq "--token: succeeds" "0" "$rc"
entry="$(cat "$(fs work /etc/iron-proxy/entries/proj--github.yaml)" 2>/dev/null || true)"
assert_eq "--token: stored in the proxy exactly, no trailing newline" \
  "github_pat_TYPED_in" "$(cat "$(fs work /etc/iron-proxy/tokens/proj--github)" 2>/dev/null; echo)"
assert_eq "--token: stored byte count matches" \
  "19" "$(wc -c < "$(fs work /etc/iron-proxy/tokens/proj--github)" 2>/dev/null | tr -d ' ')"
assert_contains "--token: entry is a file source"   "type: file" "$entry"
assert_contains "--token: entry points at the file" 'path: "/etc/iron-proxy/tokens/proj--github"' "$entry"
assert_not_contains "--token: never appears in argv" "github_pat_TYPED_in" "$(cat "$FAKE_INCUS_STATE/calls.log")"
assert_not_contains "--token: not echoed"            "github_pat_TYPED_in" "$out"
assert_eq "--token: nothing in the agent container holds the real token" \
  "" "$(grep -rl 'github_pat_TYPED_in' "$FAKE_INCUS_STATE/instances/proj" 2>/dev/null || true)"

fresh_state
make_proxy work
make_agent proj
printf '\033[200~github_pat_PASTED\033[201~\n' | incs proxy add proj work --token >/dev/null 2>&1
assert_eq "--token pasted with terminal escapes is stored clean" \
  "github_pat_PASTED" "$(cat "$(fs work /etc/iron-proxy/tokens/proj--github)" 2>/dev/null; echo)"

out="$(incs proxy add proj work --ref "$(printf 'op://v/i/f\033[I')" 2>&1)" && rc=0 || rc=$?
assert_eq "--ref containing a control character is refused" "1" "$rc"

# Refusals.
fresh_state
make_proxy work
make_proxy other
make_agent proj
incus launch images:ubuntu/24.04 plainbox
out="$(incs proxy add nope work 2>&1)" && rc=0 || rc=$?
assert_eq "unknown container is refused" "1" "$rc"
out="$(incs proxy add proj nope 2>&1)" && rc=0 || rc=$?
assert_eq "unknown proxy is refused" "1" "$rc"
out="$(incs proxy add proj plainbox 2>&1)" && rc=0 || rc=$?
assert_eq "a target that is not a proxy is refused" "1" "$rc"
assert_contains "…with a message saying so" "not a proxy" "$out"
out="$(incs proxy add other work 2>&1)" && rc=0 || rc=$?
assert_eq "attaching a proxy to a proxy is refused" "1" "$rc"
assert_eq "refused attach leaves no entry behind" \
  "" "$(ls "$(fs work /etc/iron-proxy/entries)" 2>/dev/null || true)"

incs proxy add proj work >/dev/null 2>&1
out="$(incs proxy add proj other 2>&1)" && rc=0 || rc=$?
assert_eq "switching proxies without detaching is refused" "1" "$rc"
assert_contains "…and points at proxy rm" "incs proxy rm proj" "$out"
assert_eq "…and the original attachment is untouched" "work" "$(cfg proj user.incs.proxy)"

# A container that lacks the expected user is refused before the proxy changes.
fresh_state
make_proxy work
make_agent proj
out="$(FAKE_INCUS_FAIL_EXEC='^getent passwd' incs proxy add proj work 2>&1)" && rc=0 || rc=$?
assert_eq "container without the user: refused" "1" "$rc"
assert_eq "container without the user: proxy is left untouched" \
  "" "$(ls "$(fs work /etc/iron-proxy/entries)" 2>/dev/null || true)"

# A failure partway through must leave something `proxy rm` can clean up.
fresh_state
make_proxy work
make_agent proj
out="$(FAKE_INCUS_FAIL_EXEC='^update-ca-certificates' incs proxy add proj work 2>&1)" && rc=0 || rc=$?
assert_eq "failure partway: exits non-zero" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
out="$(incs proxy rm proj 2>&1)" && rc=0 || rc=$?
assert_eq "failure partway: proxy rm can still clean up" "0" "$rc"
assert_eq "failure partway: no entry is left on the proxy" \
  "0" "$(grep -c 'proxy_value' "$(fs work /etc/iron-proxy/proxy.yaml)" || true)"

# A stopped container or proxy is started rather than failing.
fresh_state
make_proxy work
make_agent proj
incus stop proj; incus stop work
out="$(incs proxy add proj work 2>&1)" && rc=0 || rc=$?
assert_eq "stopped container and proxy: attach still succeeds" "0" "$rc"
assert_eq "stopped proxy is started" "RUNNING" "$(incus list '^work$' --format csv --columns s)"

# ===========================================================================
echo "proxy rm"
# ===========================================================================
fresh_state
make_proxy work
make_agent proj; make_agent keep
printf 'export EDITOR=nvim\n' | incus file push -p - "proj$ZSHENV"
printf 'github_pat_TYPED_in\n' | incs proxy add proj work --token >/dev/null 2>&1
incs proxy add keep work >/dev/null 2>&1
ph="$(cfg proj environment.GH_TOKEN)"
out="$(incs proxy rm proj 2>&1)" && rc=0 || rc=$?
assert_eq "rm: succeeds" "0" "$rc"

built="$(cat "$(fs work /etc/iron-proxy/proxy.yaml)")"
zshenv="$(cat "$(fs proj "$ZSHENV")")"
assert_not_contains "rm: placeholder is no longer honored by the proxy" "$ph" "$built"
assert_contains "rm: other containers on the proxy are unaffected" "op://agent-tokens/keep/credential" "$built"
assert_eq "rm: stored token is deleted from the proxy" \
  "gone" "$([[ -e "$(fs work /etc/iron-proxy/tokens/proj--github)" ]] && echo present || echo gone)"
assert_eq "rm: ~/.zshenv is back to the user's own lines" "export EDITOR=nvim" "$zshenv"
assert_eq "rm: incus environment no longer sets GH_TOKEN"  "" "$(cfg proj environment.GH_TOKEN)"
assert_eq "rm: certificate authority is no longer trusted" \
  "gone" "$([[ -e "$(fs proj /usr/local/share/ca-certificates/incs-proxy.crt)" ]] && echo present || echo gone)"
assert_contains "rm: trust store is rebuilt" \
  "proj :: update-ca-certificates --fresh" "$(cat "$FAKE_INCUS_STATE/exec.log")"
assert_eq "rm: tag is cleared" "" "$(cfg proj user.incs.proxy)"

out="$(incs proxy rm proj 2>&1)" && rc=0 || rc=$?
assert_eq "rm: a container with no proxy is refused" "1" "$rc"
out="$(incs proxy rm nope 2>&1)" && rc=0 || rc=$?
assert_eq "rm: unknown container is refused" "1" "$rc"

# The proxy is already gone: the container side must still be cleaned up.
fresh_state
make_proxy work
make_agent proj
incs proxy add proj work >/dev/null 2>&1
incus delete --force work
out="$(incs proxy rm proj 2>&1)" && rc=0 || rc=$?
assert_eq "rm with the proxy gone: succeeds" "0" "$rc"
assert_eq "rm with the proxy gone: container is detached" "" "$(cfg proj user.incs.proxy)"
assert_eq "rm with the proxy gone: placeholder is removed" "" "$(cfg proj environment.GH_TOKEN)"
assert_not_contains "rm with the proxy gone: proxy settings are removed" \
  "HTTPS_PROXY" "$(cat "$(fs proj "$ZSHENV")")"

# ===========================================================================
echo "proxy list"
# ===========================================================================
fresh_state
out="$(incs proxy list 2>&1)"
assert_contains "list: says so when there are none" "No proxies" "$out"

FAKE_INCUS_NEXT_IP=10.99.0.7 make_proxy work
make_proxy idle
make_agent proj; make_agent other; make_agent loner
incs proxy add proj work >/dev/null 2>&1
incs proxy add other work >/dev/null 2>&1
out="$(incs proxy list 2>&1)"
work_line="$(grep -E '^work\b' <<<"$out" || true)"
idle_line="$(grep -E '^idle\b' <<<"$out" || true)"
assert_contains "list: shows the proxy's address"        "10.99.0.7:8888" "$work_line"
assert_contains "list: shows its status"                 "RUNNING" "$work_line"
assert_contains "list: shows the first attached container"  "proj" "$work_line"
assert_contains "list: shows the second attached container" "other" "$work_line"
assert_not_contains "list: a proxy with nothing attached lists no containers" "proj" "$idle_line"
assert_not_contains "list: unattached containers are not shown" "loner" "$out"
assert_eq "list: agent containers are not listed as proxies" "" "$(grep -E '^(proj|other|loner)\b' <<<"$out" || true)"

# ===========================================================================
echo "proxy delete"
# ===========================================================================
fresh_state
make_proxy work
make_agent proj
printf 'export EDITOR=nvim\n' | incus file push -p - "proj$ZSHENV"
incs proxy add proj work >/dev/null 2>&1

out="$(incs proxy delete work 2>&1)" && rc=0 || rc=$?
assert_eq "delete: refused while containers are attached" "1" "$rc"
assert_contains "delete: names the attached container" "proj" "$out"
assert_eq "delete: refused delete leaves the proxy in place" "work" "$(incus list '^work$' --format csv --columns n)"

out="$(incs proxy delete work --force 2>&1)" && rc=0 || rc=$?
assert_eq "delete --force: succeeds" "0" "$rc"
assert_eq "delete --force: proxy is gone" "" "$(incus list '^work$' --format csv --columns n)"
assert_eq "delete --force: attached container is detached" "" "$(cfg proj user.incs.proxy)"
assert_eq "delete --force: container no longer points at a dead proxy" \
  "export EDITOR=nvim" "$(cat "$(fs proj "$ZSHENV")")"

fresh_state
make_proxy work
make_agent proj
incs proxy add proj work >/dev/null 2>&1
out="$(FAKE_INCUS_FAIL_EXEC='^update-ca-certificates' incs proxy delete work --force 2>&1)" && rc=0 || rc=$?
assert_eq "delete --force, cleanup fails partway: proxy is still deleted" "" "$(incus list '^work$' --format csv --columns n)"
assert_contains "delete --force, cleanup fails partway: says so" "incs proxy rm proj" "$out"
assert_eq "delete --force, cleanup fails partway: container keeps its tag so rm can retry" \
  "work" "$(cfg proj user.incs.proxy)"
out="$(incs proxy rm proj 2>&1)" && rc=0 || rc=$?
assert_eq "delete --force, cleanup fails partway: a later rm finishes the job" "" "$(cfg proj user.incs.proxy)"

make_proxy empty
out="$(incs proxy delete empty 2>&1)" && rc=0 || rc=$?
assert_eq "delete: a proxy with nothing attached is removed" "" "$(incus list '^empty$' --format csv --columns n)"

out="$(incs proxy delete proj 2>&1)" && rc=0 || rc=$?
assert_eq "delete: refuses to delete something that is not a proxy" "1" "$rc"
assert_eq "delete: the non-proxy container survives" "proj" "$(incus list '^proj$' --format csv --columns n)"

# ===========================================================================
echo "incs -d (container delete hook)"
# ===========================================================================
fresh_state
make_proxy work
make_agent proj; make_agent keep; make_agent plain
printf 'github_pat_TYPED_in\n' | incs proxy add proj work --token >/dev/null 2>&1
incs proxy add keep work >/dev/null 2>&1
ph="$(cfg proj environment.GH_TOKEN)"

out="$(incs -d proj 2>&1)" && rc=0 || rc=$?
assert_eq "incs -d: attached container is deleted" "" "$(incus list '^proj$' --format csv --columns n)"
built="$(cat "$(fs work /etc/iron-proxy/proxy.yaml)")"
assert_not_contains "incs -d: its placeholder stops working" "$ph" "$built"
assert_eq "incs -d: its stored token is deleted from the proxy" \
  "gone" "$([[ -e "$(fs work /etc/iron-proxy/tokens/proj--github)" ]] && echo present || echo gone)"
assert_contains "incs -d: other containers keep their entries" "op://agent-tokens/keep/credential" "$built"

out="$(incs -d plain 2>&1)" && rc=0 || rc=$?
assert_eq "incs -d: a container with no proxy is still deleted" "" "$(incus list '^plain$' --format csv --columns n)"

out="$(incs -d work 2>&1)" && rc=0 || rc=$?
assert_eq "incs -d: refuses to delete a proxy" "1" "$rc"
assert_contains "incs -d: points at proxy delete" "incs proxy delete work" "$out"
assert_eq "incs -d: the proxy survives" "work" "$(incus list '^work$' --format csv --columns n)"

# The proxy cannot be updated (e.g. it is broken): the delete must still happen.
out="$(FAKE_INCUS_FAIL_EXEC='^iron-rebuild' incs -d keep 2>&1)" && rc=0 || rc=$?
assert_eq "incs -d: proxy update failure does not block the delete" "" "$(incus list '^keep$' --format csv --columns n)"
assert_contains "incs -d: …but is reported" "proxy" "$out"

# ===========================================================================
echo "incs through a symlink"
# ===========================================================================
fresh_state
make_proxy work
mkdir -p "$SANDBOX/linkbin"
ln -sf "$REPO_ROOT/incs" "$SANDBOX/linkbin/incs"
out="$("$SANDBOX/linkbin/incs" proxy list 2>&1)" && rc=0 || rc=$?
assert_eq "proxy commands work when incs is run through a symlink" "0" "$rc"
assert_contains "…and reach the real script" "work" "$out"
make_agent proj
out="$("$SANDBOX/linkbin/incs" -d proj 2>&1)" && rc=0 || rc=$?
assert_eq "incs -d works when incs is run through a symlink" "" "$(incus list '^proj$' --format csv --columns n)"

# ===========================================================================
echo "existing commands leave proxies alone"
# ===========================================================================
fresh_state
make_proxy work
make_agent proj
incs -ka >/dev/null 2>&1
assert_eq "kill-all stops agent containers" "STOPPED" "$(incus list '^proj$' --format csv --columns s)"
assert_eq "kill-all leaves proxies running" "RUNNING" "$(incus list '^work$' --format csv --columns s)"

# ===========================================================================
echo "proxies without a 1Password account"
# ===========================================================================
fresh_state
make_proxy with1p
printf '\n' | incs proxy new bare >/dev/null 2>&1
echo CERT > "$(fs bare /etc/iron-proxy/ca.crt)"
make_agent proj
assert_eq "new: records that 1Password is configured"     "true"  "$(cfg with1p user.incs.proxy-1password)"
assert_eq "new: records that 1Password is not configured" "false" "$(cfg bare user.incs.proxy-1password)"

out="$(incs proxy add proj bare 2>&1)" && rc=0 || rc=$?
assert_eq "add without --token is refused when the proxy cannot read a vault" "1" "$rc"
assert_contains "…and says to use --token" "--token" "$out"
assert_eq "…and leaves the container unattached" "" "$(cfg proj user.incs.proxy)"
out="$(incs proxy add proj bare --ref op://v/i/f 2>&1)" && rc=0 || rc=$?
assert_eq "--ref is refused when the proxy cannot read a vault" "1" "$rc"
out="$(printf 'github_pat_x\n' | incs proxy add proj bare --token 2>&1)" && rc=0 || rc=$?
assert_eq "--token works on such a proxy" "0" "$rc"

# ===========================================================================
echo "plugin (incs -i --proxy)"
# ===========================================================================
# Runs the plugin's prompt and install hooks the way incus.init does, with the
# framework's helpers stubbed. Answers to prompts arrive on stdin.
run_plugin() {
  local container="$1" gh_auth_selected="${2:-0}"
  (
    set -euo pipefail
    log()   { echo "[+] $1"; }
    warn()  { echo "[!] $1"; }
    error() { echo "[ERROR] $1" >&2; exit 1; }
    selected_get() { if [[ "$1" == "gh-auth" ]]; then echo "$gh_auth_selected"; else echo 0; fi; }
    selected_set() { echo "$1=$2" >> "$FAKE_INCUS_STATE/selected.log"; }
    SCRIPT_DIR="$REPO_ROOT" CONTAINER_NAME="$container" HOST_USER="$USER_NAME"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/plugins/60-proxy.sh"
    plugin_prompt
    plugin_install
  )
}

fresh_state
FAKE_INCUS_NEXT_IP=10.99.0.7 make_proxy work
make_agent proj
# Answers: reference (blank = default), git name, git email.
out="$(printf '\nAda Lovelace\nada@example.com\n' | run_plugin proj 2>&1)" && rc=0 || rc=$?
assert_eq "plugin: succeeds" "0" "$rc"
assert_eq "plugin: a single proxy is chosen without asking" "work" "$(cfg proj user.incs.proxy)"
assert_contains "plugin: default reference is used" \
  "op://agent-tokens/proj/credential" "$(cat "$(fs work /etc/iron-proxy/entries/proj--github.yaml)" 2>/dev/null || true)"
gitconfig="$(fs proj "/home/$USER_NAME/.gitconfig")"
assert_eq "plugin: git identity name is configured for the container user" \
  "Ada Lovelace" "$(git config --file "$gitconfig" user.name 2>/dev/null || true)"
assert_eq "plugin: git identity email is configured for the container user" \
  "ada@example.com" "$(git config --file "$gitconfig" user.email 2>/dev/null || true)"
assert_contains "plugin: git is told to get credentials from gh" \
  "auth setup-git" "$(cat "$FAKE_INCUS_STATE/gh.log" 2>/dev/null || true)"

fresh_state
make_proxy work; make_proxy acme
make_agent proj
# Answers: which proxy, reference, git name, git email.
out="$(printf 'acme\n\nAda\nada@example.com\n' | run_plugin proj 2>&1)" && rc=0 || rc=$?
assert_eq "plugin: with several proxies, the named one is used" "acme" "$(cfg proj user.incs.proxy)"
assert_contains "plugin: …after listing the choices" "work" "$out"

out="$(printf 'nope\n\nAda\nada@example.com\n' | run_plugin proj 2>&1)" && rc=0 || rc=$?
assert_eq "plugin: an unknown proxy name is refused" "1" "$rc"

fresh_state
make_proxy work; make_proxy acme
make_agent proj
out="$(printf 'Ada\nada@example.com\n' \
  | INCS_PROXY=acme INCS_PROXY_REF="op://X/Y/z" run_plugin proj 2>&1)" && rc=0 || rc=$?
assert_eq "plugin: INCS_PROXY selects the proxy without a prompt" "acme" "$(cfg proj user.incs.proxy)"
assert_contains "plugin: INCS_PROXY_REF sets the reference without a prompt" \
  'secret_ref: "op://X/Y/z"' "$(cat "$(fs acme /etc/iron-proxy/entries/proj--github.yaml)" 2>/dev/null || true)"

fresh_state
make_agent proj
out="$(printf '\n' | run_plugin proj 2>&1)" && rc=0 || rc=$?
assert_eq "plugin: with no proxies, it stops" "1" "$rc"
assert_contains "plugin: …and says how to create one" "incs proxy new" "$out"

fresh_state
make_proxy work
make_agent proj
out="$(printf '\nAda\nada@example.com\n' | run_plugin proj 1 2>&1)" && rc=0 || rc=$?
assert_eq "plugin: GitHub Auth is deselected so it cannot write a real token" \
  "gh-auth=0" "$(cat "$FAKE_INCUS_STATE/selected.log" 2>/dev/null || true)"
assert_eq "plugin: …and the container holds the placeholder" \
  "match" "$([[ "$(cfg proj environment.GH_TOKEN)" =~ ^ghp_[0-9a-f]{36}$ ]] && echo match || echo no)"

# Pasted answers arrive wrapped in terminal escapes.
fresh_state
make_proxy work; make_proxy acme
make_agent proj
out="$(printf '\033[Oacme\033[I\n\033[Oop://Shared/GitHub proj/token\033[I\nAda\nada@example.com\n' \
  | run_plugin proj 2>&1)" && rc=0 || rc=$?
assert_eq "plugin: a pasted proxy name is cleaned" "acme" "$(cfg proj user.incs.proxy)"
assert_contains "plugin: a pasted reference is cleaned" \
  'secret_ref: "op://Shared/GitHub proj/token"' "$(cat "$(fs acme /etc/iron-proxy/entries/proj--github.yaml)" 2>/dev/null || true)"

fresh_state
printf '\n' | incs proxy new bare >/dev/null 2>&1
echo CERT > "$(fs bare /etc/iron-proxy/ca.crt)"
make_agent proj
printf '\033[Ogithub_pat_PLUGIN_PASTED\033[I\nAda\nada@example.com\n' | run_plugin proj >/dev/null 2>&1 || true
assert_eq "plugin: a pasted token is stored clean" \
  "github_pat_PLUGIN_PASTED" "$(cat "$(fs bare /etc/iron-proxy/tokens/proj--github)" 2>/dev/null; echo)"

fresh_state
printf '\n' | incs proxy new bare >/dev/null 2>&1
echo CERT > "$(fs bare /etc/iron-proxy/ca.crt)"
make_agent proj
# Answers: token (hidden), git name, git email.
out="$(printf 'github_pat_PLUGIN\nAda\nada@example.com\n' | run_plugin proj 2>&1)" && rc=0 || rc=$?
assert_eq "plugin: a proxy without 1Password asks for the token instead" \
  "github_pat_PLUGIN" "$(cat "$(fs bare /etc/iron-proxy/tokens/proj--github)" 2>/dev/null; echo)"
assert_not_contains "plugin: …without echoing it" "github_pat_PLUGIN" "$out"

# ===========================================================================
echo "templates (incs -i --template)"
# ===========================================================================
# save_template lives in incus.init, which cannot be sourced without running.
# Pull the function out and run it against the fake.
save_template_src="$(awk '
  /^save_template\(\)/ {capture=1}
  capture {print}
  capture && /^}/ {exit}
' "$REPO_ROOT/incus.init")"

run_save_template() {
  local container="$1"
  (
    set -euo pipefail
    log()  { :; }
    warn() { :; }
    wait_for_container() { :; }
    wait_for_network()   { :; }
    CONTAINER_NAME="$container" HOST_USER="$USER_NAME" MOUNT_PATH="/workspace" READY_TIMEOUT=1
    eval "$save_template_src"
    save_template
  )
}

fresh_state
make_proxy work
make_agent base
printf 'export EDITOR=nvim\n' | incus file push -p - "base$ZSHENV"
incs proxy add base work >/dev/null 2>&1
ph="$(cfg base environment.GH_TOKEN)"
run_save_template base >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "template: save succeeds" "0" "$rc"

image_zshenv="$(cat "$FAKE_INCUS_STATE/images/incus-init/base/root$ZSHENV" 2>/dev/null || echo MISSING)"
live_zshenv="$(cat "$(fs base "$ZSHENV")")"
assert_not_contains "template: image holds no placeholder"      "$ph" "$image_zshenv"
assert_not_contains "template: image does not route through a proxy" "HTTPS_PROXY" "$image_zshenv"
assert_not_contains "template: image has none of our lines"     "# incs-proxy" "$image_zshenv"
assert_contains "template: image keeps the user's own settings"  "export EDITOR=nvim" "$image_zshenv"
assert_contains "template: the running container keeps its placeholder" "export GH_TOKEN=$ph" "$live_zshenv"
assert_contains "template: the running container keeps its proxy"  "export HTTPS_PROXY=" "$live_zshenv"

echo ""
echo "Passed: $PASS    Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
