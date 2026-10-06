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
  printf '127.0.0.1 localhost\n' | incus file push -p - "$name/etc/hosts"
}
hosts_of() { cat "$(fs "$1" /etc/hosts)" 2>/dev/null || true; }

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
assert_eq "base config exposes the TLS listener to containers" \
  '  https_listen: "0.0.0.0:443"' \
  "$(grep 'https_listen' "$(fs work /etc/iron-proxy/base.yaml)" 2>/dev/null || true)"
# The tunnel port accepts plain HTTP and would swap placeholders on it.
assert_eq "base config has no tunnel listener" \
  "" "$(grep '^ *tunnel_listen' "$(fs work /etc/iron-proxy/base.yaml)" 2>/dev/null || true)"
assert_eq "base config keeps the plain-HTTP listener on loopback" \
  '  http_listen: "127.0.0.1:18080"' \
  "$(grep 'http_listen' "$(fs work /etc/iron-proxy/base.yaml)" 2>/dev/null || true)"
assert_eq "launches with the hardened agent-incus profile" \
  "default agent-incus" "$(paste -sd' ' "$FAKE_INCUS_STATE/instances/work/profiles")"
assert_eq "profile isolates the idmap" \
  "true" "$(cat "$FAKE_INCUS_STATE/profiles/agent-incus/security.idmap.isolated")"
assert_eq "profile does not tag instances as agent containers" \
  "no" "$([[ -e "$FAKE_INCUS_STATE/profiles/agent-incus/user.managed-by" ]] && echo yes || echo no)"
assert_eq "proxy gets a small memory limit" "512MB" "$(cfg work limits.memory)"
assert_eq "proxy gets a small CPU limit"    "1"     "$(cfg work limits.cpu)"

# A host whose profile predates this change still carries the managed-by tag.
fresh_state
incus profile create agent-incus
incus profile set agent-incus user.managed-by=agent-incus security.nesting=true
printf 'tok\n' | incs proxy new legacy >/dev/null 2>&1 || true
assert_eq "existing profile: stale managed-by tag is removed" \
  "no" "$([[ -e "$FAKE_INCUS_STATE/profiles/agent-incus/user.managed-by" ]] && echo yes || echo no)"
assert_eq "existing profile: drifted keys are reset" \
  "false" "$(cat "$FAKE_INCUS_STATE/profiles/agent-incus/security.nesting")"
assert_eq "existing profile: proxy is still created" "proxy" "$(cfg legacy user.incs.role)"

fresh_state
incus launch images:ubuntu/24.04 taken
out="$(printf 'tok\n' | incs proxy new taken 2>&1)" && rc=0 || rc=$?
assert_eq "refuses a name already in use: exit code" "1" "$rc"
assert_contains "refuses a name already in use: message" "already exists" "$out"

fresh_state
out="$(printf 'tok\n' | incs proxy new one two 2>&1)" && rc=0 || rc=$?
assert_eq "new: a second name is refused" "1" "$rc"
assert_eq "new: …and nothing is created" "" "$(incus list --format csv --columns n)"

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
assert_contains "entry is bound to uploads.github.com (release assets)" \
  '- host: "uploads.github.com"' "$entry"
assert_eq "no staged files are left in the proxy" \
  "" "$(compgen -G "$(fs work /etc/iron-proxy)/*/*.new" || true)"
assert_contains "rebuilt config includes the entry"       "proxy_value: \"$ph\"" "$built"
assert_contains "rebuilt config keeps the base settings"  'https_listen: "0.0.0.0:443"' "$built"

assert_not_contains "real token removed from ~/.zshenv"   "$REAL_TOKEN" "$zshenv"
assert_contains "~/.zshenv exports the placeholder"       "export GH_TOKEN=$ph" "$zshenv"
hosts="$(hosts_of proj)"
assert_contains "/etc/hosts sends the GitHub hosts to the proxy" \
  "10.99.0.7 github.com api.github.com uploads.github.com # incs-proxy:github" "$hosts"
assert_contains "/etc/hosts keeps its own lines" "127.0.0.1 localhost" "$hosts"
assert_eq "/etc/hosts gains exactly one line" "2" "$(grep -c . <<<"$hosts")"
# Nothing else is routed to the proxy: no proxy variables at all.
assert_eq "~/.zshenv sets no proxy variables" \
  "" "$(grep -iE '^export (https?_proxy|no_proxy)=' <<<"$zshenv" || true)"
assert_contains "~/.zshenv points tools with their own trust store at the system bundle" \
  "export NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt # incs-proxy" "$zshenv"
assert_eq "container records what is attached" "github=GH_TOKEN" "$(cfg proj user.incs.proxy-services)"
assert_contains "~/.zshenv keeps unrelated settings (before)" "export EDITOR=nvim" "$zshenv"
assert_contains "~/.zshenv keeps unrelated settings (after)"  "export FOO=bar" "$zshenv"
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
ph="$(cfg proj environment.GH_TOKEN)"
incs proxy add proj work >/dev/null 2>&1
ph2="$(cfg proj environment.GH_TOKEN)"
zshenv="$(cat "$(fs proj "$ZSHENV")")"
assert_eq "re-add: placeholder rotates" "rotated" "$([[ -n "$ph2" && "$ph2" != "$ph" ]] && echo rotated || echo same)"
assert_eq "re-add: one GH_TOKEN line"   "1" "$(grep -c '^export GH_TOKEN=' <<<"$zshenv")"
assert_eq "re-add: one line per trust-store variable" "1" "$(grep -c '^export SSL_CERT_FILE=' <<<"$zshenv")"
assert_eq "re-add: one /etc/hosts line" "1" "$(grep -c 'incs-proxy:github' <<<"$(hosts_of proj)")"
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

# Switching a container from a stored token to 1Password removes the token.
fresh_state
make_proxy work
make_agent proj
printf 'github_pat_STORED\n' | incs proxy add proj work --token >/dev/null 2>&1
incs proxy add proj work >/dev/null 2>&1
assert_contains "switching to 1Password: entry now reads the vault" \
  "type: 1password" "$(cat "$(fs work /etc/iron-proxy/entries/proj--github.yaml)")"
assert_eq "switching to 1Password: the stored token is deleted" \
  "gone" "$([[ -e "$(fs work /etc/iron-proxy/tokens/proj--github)" ]] && echo present || echo gone)"

fresh_state
make_proxy work
make_agent proj
out="$(printf 'github_pat_with a_space\n' | incs proxy add proj work --token 2>&1)" && rc=0 || rc=$?
assert_eq "--token containing whitespace is refused" "1" "$rc"
assert_eq "--token containing whitespace stores nothing" \
  "gone" "$([[ -e "$(fs work /etc/iron-proxy/tokens/proj--github)" ]] && echo present || echo gone)"

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

# ~/.zshenv is rewritten in place; a failure must never lose the user's lines.
fresh_state
make_proxy work
make_agent proj
printf 'export EDITOR=nvim\nexport SECRET_SAUCE=1\n' | incus file push -p - "proj$ZSHENV"
out="$(FAKE_INCUS_FAIL_CALL='^file pull .*\.zshenv' incs proxy add proj work 2>&1)" && rc=0 || rc=$?
assert_contains "~/.zshenv survives a failed read: user's first line kept"  "export EDITOR=nvim" "$(cat "$(fs proj "$ZSHENV")")"
assert_contains "~/.zshenv survives a failed read: user's second line kept" "export SECRET_SAUCE=1" "$(cat "$(fs proj "$ZSHENV")")"

# Mode 000 only makes a file unreadable for a process without root or the
# DAC override capability, so check that the read really fails before relying on it.
fresh_state
make_proxy work
make_agent proj
printf 'export EDITOR=nvim\n' | incus file push -p - "proj$ZSHENV"
chmod 000 "$(fs proj "$ZSHENV")"
if ! cat "$(fs proj "$ZSHENV")" >/dev/null 2>&1; then
  out="$(incs proxy add proj work 2>&1)" && rc=0 || rc=$?
  chmod 600 "$(fs proj "$ZSHENV")"
  assert_eq "unreadable ~/.zshenv: attach fails rather than overwriting" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
  assert_eq "unreadable ~/.zshenv: the user's lines are untouched" "export EDITOR=nvim" "$(cat "$(fs proj "$ZSHENV")")"
else
  chmod 600 "$(fs proj "$ZSHENV")"
  echo "  skip  unreadable ~/.zshenv (this process can read mode 000 files)"
fi

# A stopped container or proxy is started rather than failing.
fresh_state
make_proxy work
make_agent proj
incus stop proj; incus stop work
out="$(incs proxy add proj work 2>&1)" && rc=0 || rc=$?
assert_eq "stopped container and proxy: attach still succeeds" "0" "$rc"
assert_eq "stopped proxy is started" "RUNNING" "$(incus list '^work$' --format csv --columns s)"

# ===========================================================================
echo "proxy add (any API)"
# ===========================================================================
fresh_state
FAKE_INCUS_NEXT_IP=10.99.0.7 make_proxy work
make_agent proj
printf 'export OPENAI_API_KEY=sk-REAL-key-from-before\nexport EDITOR=nvim\n' | incus file push -p - "proj$ZSHENV"
incs proxy add proj work >/dev/null 2>&1
gh_ph="$(cfg proj environment.GH_TOKEN)"
out="$(incs proxy add proj work --env OPENAI_API_KEY --host api.openai.com 2>&1)" && rc=0 || rc=$?
assert_eq "add --env/--host: succeeds" "0" "$rc"

ph="$(cfg proj environment.OPENAI_API_KEY)"
entry="$(cat "$(fs work /etc/iron-proxy/entries/proj--openai-api-key.yaml)" 2>/dev/null || true)"
zshenv="$(cat "$(fs proj "$ZSHENV")")"
hosts="$(hosts_of proj)"
built="$(cat "$(fs work /etc/iron-proxy/proxy.yaml)")"
assert_eq "generic placeholder is random and recognisable" \
  "match" "$([[ "$ph" =~ ^incs_[0-9a-f]{40}$ ]] && echo match || echo "no match: $ph")"
assert_contains "service is named after the variable"       "proxy_value: \"$ph\"" "$entry"
assert_contains "key is read from a field named after the variable" \
  'secret_ref: "op://agent-tokens/proj/OPENAI_API_KEY"' "$entry"
assert_contains "entry is bound to the given host"          '- host: "api.openai.com"' "$entry"
assert_not_contains "entry is not bound to GitHub"          'github.com' "$entry"
# No header named: the proxy swaps it in whichever header carries it.
assert_not_contains "entry does not restrict which header"  'match_headers' "$entry"
assert_contains "rebuilt config holds the new placeholder"  "$ph" "$built"
assert_contains "rebuilt config still holds GitHub's"       "$gh_ph" "$built"

assert_contains "~/.zshenv exports the placeholder under the given name" \
  "export OPENAI_API_KEY=$ph # incs-proxy:openai-api-key" "$zshenv"
assert_not_contains "a real key already in ~/.zshenv is replaced" "sk-REAL-key-from-before" "$zshenv"
assert_eq "…leaving one line for the variable" "1" "$(grep -c '^export OPENAI_API_KEY=' <<<"$zshenv")"
assert_contains "GitHub's line is left alone"               "export GH_TOKEN=$gh_ph" "$zshenv"
assert_contains "the user's own lines are left alone"       "export EDITOR=nvim" "$zshenv"
assert_eq "trust-store variables are not duplicated" "1" "$(grep -c '^export SSL_CERT_FILE=' <<<"$zshenv")"
assert_contains "/etc/hosts sends the host to the proxy" \
  "10.99.0.7 api.openai.com # incs-proxy:openai-api-key" "$hosts"
assert_contains "/etc/hosts keeps GitHub's line"            "# incs-proxy:github" "$hosts"
assert_eq "container records both services" \
  "github=GH_TOKEN openai-api-key=OPENAI_API_KEY" "$(cfg proj user.incs.proxy-services)"
assert_eq "git credential setup runs for GitHub only" \
  "1" "$(grep -c 'auth setup-git' "$FAKE_INCUS_STATE/gh.log")"
assert_not_contains "placeholder is not printed" "$ph" "$out"
assert_contains "list shows every service" "proj(github,openai-api-key)" "$(incs proxy list 2>&1)"

# Re-adding one service rotates only that service.
incs proxy add proj work --env OPENAI_API_KEY --host api.openai.com >/dev/null 2>&1
ph2="$(cfg proj environment.OPENAI_API_KEY)"
assert_eq "re-add: that placeholder rotates" "rotated" "$([[ -n "$ph2" && "$ph2" != "$ph" ]] && echo rotated || echo same)"
assert_eq "re-add: GitHub's placeholder does not" "$gh_ph" "$(cfg proj environment.GH_TOKEN)"
assert_eq "re-add: one /etc/hosts line for it" "1" "$(grep -c 'incs-proxy:openai-api-key' <<<"$(hosts_of proj)")"
assert_eq "re-add: the list is unchanged" \
  "github=GH_TOKEN openai-api-key=OPENAI_API_KEY" "$(cfg proj user.incs.proxy-services)"

# Name, prefix, several hosts, key stored in the proxy.
out="$(printf 'sk-ant-REAL-key\n' | incs proxy add proj work --service anthropic --env ANTHROPIC_API_KEY \
  --host api.anthropic.com --host console.anthropic.com --prefix sk-ant- --token 2>&1)" && rc=0 || rc=$?
assert_eq "add --service/--prefix/--token: succeeds" "0" "$rc"
ph="$(cfg proj environment.ANTHROPIC_API_KEY)"
entry="$(cat "$(fs work /etc/iron-proxy/entries/proj--anthropic.yaml)" 2>/dev/null || true)"
assert_eq "--prefix shapes the placeholder" \
  "match" "$([[ "$ph" =~ ^sk-ant-[0-9a-f]{40}$ ]] && echo match || echo "no match: $ph")"
assert_eq "--token stores the key in the proxy, under the service's name" \
  "sk-ant-REAL-key" "$(cat "$(fs work /etc/iron-proxy/tokens/proj--anthropic)" 2>/dev/null; echo)"
assert_contains "--token: entry reads the stored key" 'path: "/etc/iron-proxy/tokens/proj--anthropic"' "$entry"
assert_contains "every --host is bound (first)"  '- host: "api.anthropic.com"' "$entry"
assert_contains "every --host is bound (second)" '- host: "console.anthropic.com"' "$entry"
assert_contains "every --host goes to the proxy" \
  "10.99.0.7 api.anthropic.com console.anthropic.com # incs-proxy:anthropic" "$(hosts_of proj)"
assert_not_contains "the key never appears in argv" "sk-ant-REAL-key" "$(cat "$FAKE_INCUS_STATE/calls.log")"

incs proxy add proj work --service stripe --env STRIPE_KEY --host api.stripe.com --ref "op://Shared/Stripe test/key" >/dev/null 2>&1
assert_contains "--ref overrides the default reference" \
  'secret_ref: "op://Shared/Stripe test/key"' "$(cat "$(fs work /etc/iron-proxy/entries/proj--stripe.yaml)")"

# Anything that cannot be attached safely is refused before any change.
before="$(cfg proj user.incs.proxy-services)"
refused() {
  local label="$1" needle="$2"; shift 2
  out="$(incs proxy add proj work "$@" 2>&1 </dev/null)" && rc=0 || rc=$?
  assert_eq "refused: $label" "1" "$rc"
  [[ -z "$needle" ]] || assert_contains "refused: $label (says why)" "$needle" "$out"
}
refused "--env without --host"               "--host is required"  --env SOME_KEY
refused "--host without --env"               "--env is required"   --host api.example.com
refused "a wildcard host"                    "Wildcard"            --env SOME_KEY --host '*.example.com'
refused "a host with a path"                 "Invalid host"        --env SOME_KEY --host 'api.example.com/v1'
refused "a host with a space"                "Invalid host"        --env SOME_KEY --host 'api example.com'
refused "a variable name with a hyphen"      "Invalid environment" --env SOME-KEY --host api.example.com
refused "a prefix with a space"              "Invalid placeholder" --env SOME_KEY --host api.example.com --prefix 'sk ant'
refused "a service name with a slash"        "Invalid service"     --service 'a/b' --env SOME_KEY --host api.example.com
refused "github with --env"                  "built in"            --service github --env SOME_KEY --host api.example.com
refused "a new service name with nothing else" "needs --env"       --service mystery
refused "a variable another service already uses" "already belongs" --service other --env OPENAI_API_KEY --host api.example.com
refused "a variable incs itself sets"         "set by incs itself"  --env SSL_CERT_FILE --host api.example.com
assert_eq "refused attaches change nothing" "$before" "$(cfg proj user.incs.proxy-services)"
assert_not_contains "refused attaches add no /etc/hosts line" "example.com" "$(hosts_of proj)"

# A container attached before services existed: tagged, no list, proxy
# variables in ~/.zshenv.
fresh_state
FAKE_INCUS_NEXT_IP=10.99.0.7 make_proxy work
make_agent proj
incus config set proj user.incs.proxy=work
incus config set proj environment.GH_TOKEN=ghp_old
printf 'export EDITOR=nvim\nexport GH_TOKEN=ghp_old # incs-proxy\nexport HTTPS_PROXY=http://10.99.0.7:8888 # incs-proxy\n' \
  | incus file push -p - "proj$ZSHENV"
out="$(incs proxy add proj work --env OPENAI_API_KEY --host api.openai.com 2>&1)" && rc=0 || rc=$?
assert_eq "older attachment: another service is refused until GitHub is re-attached" "1" "$rc"
assert_contains "older attachment: …with the command to run" "incs proxy add proj work" "$out"
out="$(incs proxy add proj work 2>&1)" && rc=0 || rc=$?
zshenv="$(cat "$(fs proj "$ZSHENV")")"
assert_eq "older attachment: re-attaching GitHub succeeds" "0" "$rc"
assert_not_contains "older attachment: the proxy variables are removed" "HTTPS_PROXY" "$zshenv"
assert_eq "older attachment: one GH_TOKEN line remains" "1" "$(grep -c '^export GH_TOKEN=' <<<"$zshenv")"
assert_contains "older attachment: the user's lines are kept" "export EDITOR=nvim" "$zshenv"
out="$(incs proxy add proj work --env OPENAI_API_KEY --host api.openai.com 2>&1)" && rc=0 || rc=$?
assert_eq "older attachment: other services can then be added" "0" "$rc"

# ===========================================================================
echo "proxy apply (services file)"
# ===========================================================================
fresh_state
FAKE_INCUS_NEXT_IP=10.99.0.7 make_proxy work
make_agent proj
SVC="$SANDBOX/services.yaml"
cat > "$SVC" <<'YAML'
# what proj needs
github:
openai:
  env: OPENAI_API_KEY
  host: api.openai.com          # one host
anthropic:
  env: ANTHROPIC_API_KEY
  hosts: [api.anthropic.com, "console.anthropic.com"]
  prefix: sk-ant-
  ref: "op://Shared/Anthropic key/credential"   # a space needs quotes
stripe:
  env: STRIPE_KEY
  hosts:
    - api.stripe.com
    - files.stripe.com
YAML
out="$(incs proxy apply proj work "$SVC" 2>&1)" && rc=0 || rc=$?
assert_eq "apply: succeeds" "0" "$rc"
assert_eq "apply: attaches every service in the file, in order" \
  "github=GH_TOKEN openai=OPENAI_API_KEY anthropic=ANTHROPIC_API_KEY stripe=STRIPE_KEY" \
  "$(cfg proj user.incs.proxy-services)"
entry_of() { cat "$(fs work "/etc/iron-proxy/entries/proj--$1.yaml")" 2>/dev/null || true; }
assert_contains "apply: github uses its default reference" \
  'secret_ref: "op://agent-tokens/proj/credential"' "$(entry_of github)"
assert_contains "apply: no ref means the field named after the variable" \
  'secret_ref: "op://agent-tokens/proj/OPENAI_API_KEY"' "$(entry_of openai)"
assert_contains "apply: a trailing comment is not part of the host" \
  '- host: "api.openai.com"' "$(entry_of openai)"
assert_contains "apply: a quoted ref keeps its space" \
  'secret_ref: "op://Shared/Anthropic key/credential"' "$(entry_of anthropic)"
assert_contains "apply: an inline list binds its first host"  '- host: "api.anthropic.com"' "$(entry_of anthropic)"
assert_contains "apply: an inline list binds its second host" '- host: "console.anthropic.com"' "$(entry_of anthropic)"
assert_eq "apply: prefix shapes the placeholder" \
  "match" "$([[ "$(cfg proj environment.ANTHROPIC_API_KEY)" =~ ^sk-ant-[0-9a-f]{40}$ ]] && echo match || echo "no match")"
assert_contains "apply: a block list sends every host to the proxy" \
  "10.99.0.7 api.stripe.com files.stripe.com # incs-proxy:stripe" "$(hosts_of proj)"

# Running it again changes nothing: shells already open keep working.
placeholders() { echo "$(cfg proj environment.GH_TOKEN) $(cfg proj environment.OPENAI_API_KEY) $(cfg proj environment.ANTHROPIC_API_KEY) $(cfg proj environment.STRIPE_KEY)"; }
before="$(placeholders)"
out="$(incs proxy apply proj work "$SVC" 2>&1)" && rc=0 || rc=$?
assert_eq "apply again: succeeds" "0" "$rc"
assert_eq "apply again: no placeholder rotates" "$before" "$(placeholders)"
assert_eq "apply again: says each service is unchanged" "4" "$(grep -c 'unchanged' <<<"$out")"

# The same hosts in another order are not a change.
sed 's/hosts: \[api.anthropic.com, "console.anthropic.com"\]/hosts: [console.anthropic.com, api.anthropic.com]/' "$SVC" > "$SVC.tmp" && mv "$SVC.tmp" "$SVC"
assert_contains "(the file now lists the hosts in the other order)" "[console.anthropic.com, api.anthropic.com]" "$(cat "$SVC")"
out="$(incs proxy apply proj work "$SVC" 2>&1)" && rc=0 || rc=$?
assert_eq "apply with hosts reordered: succeeds" "0" "$rc"
assert_eq "apply with hosts reordered: no placeholder rotates" "$before" "$(placeholders)"

# Edit one service: only that one is re-attached.
gh_before="$(cfg proj environment.GH_TOKEN)"
openai_before="$(cfg proj environment.OPENAI_API_KEY)"
sed 's/host: api.openai.com.*/host: eu.api.openai.com/' "$SVC" > "$SVC.tmp" && mv "$SVC.tmp" "$SVC"
out="$(incs proxy apply proj work "$SVC" 2>&1)" && rc=0 || rc=$?
assert_eq "apply after an edit: succeeds" "0" "$rc"
assert_contains "apply after an edit: the edited service points at its new host" \
  "10.99.0.7 eu.api.openai.com # incs-proxy:openai" "$(hosts_of proj)"
assert_not_contains "apply after an edit: …and no longer at the old one" " api.openai.com " "$(hosts_of proj)"
assert_eq "apply after an edit: its placeholder rotates" \
  "rotated" "$([[ "$(cfg proj environment.OPENAI_API_KEY)" != "$openai_before" ]] && echo rotated || echo same)"
assert_eq "apply after an edit: the others are untouched" "$gh_before" "$(cfg proj environment.GH_TOKEN)"

# Take a service out of the file.
stripe_ph="$(cfg proj environment.STRIPE_KEY)"
awk '/^stripe:/{skip=1; next} /^[^[:space:]#]/{skip=0} !skip' "$SVC" > "$SVC.tmp" && mv "$SVC.tmp" "$SVC"
out="$(incs proxy apply proj work "$SVC" 2>&1)" && rc=0 || rc=$?
assert_eq "apply without --prune: succeeds" "0" "$rc"
assert_eq "apply without --prune: a service missing from the file stays attached" \
  "$stripe_ph" "$(cfg proj environment.STRIPE_KEY)"
out="$(incs proxy apply proj work "$SVC" --prune 2>&1)" && rc=0 || rc=$?
assert_eq "apply --prune: succeeds" "0" "$rc"
assert_eq "apply --prune: detaches what the file no longer lists" \
  "github=GH_TOKEN openai=OPENAI_API_KEY anthropic=ANTHROPIC_API_KEY" "$(cfg proj user.incs.proxy-services)"
assert_not_contains "apply --prune: its placeholder is revoked" \
  "$stripe_ph" "$(cat "$(fs work /etc/iron-proxy/proxy.yaml)")"
assert_not_contains "apply --prune: its /etc/hosts line is removed" "stripe" "$(hosts_of proj)"
assert_eq "apply --prune: what the file still lists is untouched" "$gh_before" "$(cfg proj environment.GH_TOKEN)"

# hosts: with a single name is accepted.
make_agent single
printf 'openai:\n  env: OPENAI_API_KEY\n  hosts: api.openai.com\n' > "$SANDBOX/single.yaml"
out="$(incs proxy apply single work "$SANDBOX/single.yaml" 2>&1)" && rc=0 || rc=$?
assert_eq "apply: hosts: with one name is accepted" "0" "$rc"
assert_contains "apply: …as that one host" "10.99.0.7 api.openai.com # incs-proxy:openai" "$(hosts_of single)"

# A file saved with Windows line endings.
make_agent crlf
printf 'github:\r\nopenai:\r\n  env: OPENAI_API_KEY\r\n  host: api.openai.com\r\n' > "$SANDBOX/crlf.yaml"
out="$(incs proxy apply crlf work "$SANDBOX/crlf.yaml" 2>&1)" && rc=0 || rc=$?
assert_eq "apply: CRLF line endings are accepted" "0" "$rc"
assert_contains "apply: …and do not end up in a host name" \
  "10.99.0.7 api.openai.com # incs-proxy:openai" "$(hosts_of crlf)"

# A file with a mistake is refused whole, before anything is attached.
make_agent clean
bad_file() {
  local label="$1" needle="$2" content="$3"
  printf '%b' "$content" > "$SANDBOX/bad.yaml"
  out="$(incs proxy apply clean work "$SANDBOX/bad.yaml" 2>&1)" && rc=0 || rc=$?
  assert_eq "bad file: $label" "1" "$rc"
  assert_contains "bad file: $label (says why)" "$needle" "$out"
}
bad_file "an unknown setting"        "unknown setting 'hots'"   'openai:\n  env: X_KEY\n  hots: a.example.com\n'
assert_contains "bad file: …and names the line" "bad.yaml:3:" "$out"
bad_file "no env"                    "needs env"                'openai:\n  host: a.example.com\n'
bad_file "no host"                   "needs host"               'openai:\n  env: X_KEY\n'
bad_file "a wildcard host"           "Wildcard"                 "openai:\n  env: X_KEY\n  host: '*.example.com'\n"
# A second word must never become a second host the key is bound to.
bad_file "two hosts on a host: line" "host: takes one host"     'openai:\n  env: X_KEY\n  host: api.example.com other.example.com\n'
bad_file "a list on a host: line"    "host: takes one host"     'openai:\n  env: X_KEY\n  host: [api.example.com, other.example.com]\n'
bad_file "hosts without brackets"    "hosts: [a, b]"            'openai:\n  env: X_KEY\n  hosts: api.example.com, other.example.com\n'
bad_file "hosts missing a comma"     "one host between commas"  'openai:\n  env: X_KEY\n  hosts: [api.example.com other.example.com]\n'
bad_file "an empty item in hosts"    "one host between commas"  'openai:\n  env: X_KEY\n  hosts: [api.example.com, ]\n'
bad_file "a service listed twice"    "listed twice"             'a:\n  env: A_KEY\n  host: a.example.com\na:\n  env: B_KEY\n  host: b.example.com\n'
bad_file "one variable used twice"   "both use X_KEY"           'a:\n  env: X_KEY\n  host: a.example.com\nb:\n  env: X_KEY\n  host: b.example.com\n'
bad_file "github given an env"       "built in"                 'github:\n  env: X_KEY\n'
bad_file "a ref that is not op://"   "must start with op://"    'github:\n  ref: vault/item/field\n'
bad_file "a value on the name line"  "lines below its name"     'openai: yes\n'
bad_file "a list outside hosts"      "only allowed under hosts" 'openai:\n  env: X_KEY\n  - a.example.com\n'
bad_file "an unbalanced quote"       "unbalanced quote"         'openai:\n  env: "X_KEY\n  host: a.example.com\n'
bad_file "a setting before any name" "before any service name"  '  env: X_KEY\n'
bad_file "nothing but comments"      "lists no services"        '# nothing here\n\n'
bad_file "a good service before a bad one" "needs host"         'github:\nopenai:\n  env: X_KEY\n'
assert_eq "bad files attach nothing, not even their good services" "" "$(cfg clean user.incs.proxy)"
out="$(incs proxy apply clean work "$SANDBOX/no-such-file.yaml" 2>&1)" && rc=0 || rc=$?
assert_eq "apply: a missing file is refused" "1" "$rc"
out="$(incs proxy apply clean work 2>&1)" && rc=0 || rc=$?
assert_eq "apply: no file is refused" "1" "$rc"

# A wildcard host must be reported, not expanded against files in the
# directory incs runs from.
mkdir -p "$SANDBOX/globdir" && touch "$SANDBOX/globdir/evil.example.com"
printf 'openai:\n  env: X_KEY\n  host: *.example.com\n' > "$SANDBOX/bad.yaml"
out="$(cd "$SANDBOX/globdir" && incs proxy apply clean work "$SANDBOX/bad.yaml" 2>&1)" && rc=0 || rc=$?
assert_contains "apply: a wildcard is refused even where it matches a file name" "Wildcard" "$out"
assert_eq "apply: …and nothing is attached" "" "$(cfg clean user.incs.proxy)"

# The container belongs to another proxy.
make_proxy other
out="$(incs proxy apply proj other "$SVC" 2>&1)" && rc=0 || rc=$?
assert_eq "apply: a container attached elsewhere is refused" "1" "$rc"

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
incs proxy add keep work >/dev/null 2>&1
out="$(incs proxy rm keep proj 2>&1)" && rc=0 || rc=$?
assert_eq "rm: a second container name is refused" "1" "$rc"
assert_eq "rm: …and nothing is detached" "work" "$(cfg keep user.incs.proxy)"
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

# Incus cannot say whether the proxy exists (daemon down, transient error).
# That is not the proxy being gone: the placeholder may still be honored, so
# rm must fail and keep the container's record of it, or nothing could find
# and revoke the entry later.
fresh_state
make_proxy work
make_agent proj
printf 'github_pat_TYPED_in\n' | incs proxy add proj work --token >/dev/null 2>&1
ph="$(cfg proj environment.GH_TOKEN)"
out="$(FAKE_INCUS_FAIL_CALL='^list \^work\$ ' incs proxy rm proj 2>&1)" && rc=0 || rc=$?
assert_eq "rm, Incus unreachable: fails" "1" "$rc"
assert_contains     "rm, Incus unreachable: says the container is still attached" "still attached" "$out"
assert_not_contains "rm, Incus unreachable: does not report a detach" "Detached" "$out"
assert_eq "rm, Incus unreachable: tag is kept, so rm can be run again" "work" "$(cfg proj user.incs.proxy)"
assert_eq "rm, Incus unreachable: container side is left as it was" "$ph" "$(cfg proj environment.GH_TOKEN)"
assert_contains "rm, Incus unreachable: the proxy still has the entry" "$ph" "$(cat "$(fs work /etc/iron-proxy/proxy.yaml)")"
out="$(incs proxy rm proj 2>&1)" && rc=0 || rc=$?
assert_eq "rm once Incus answers: succeeds" "0" "$rc"
assert_not_contains "rm once Incus answers: placeholder is revoked" "$ph" "$(cat "$(fs work /etc/iron-proxy/proxy.yaml)")"
assert_eq "rm once Incus answers: tag is cleared" "" "$(cfg proj user.incs.proxy)"

# The proxy cannot revoke (broken, disk error): rm must not claim it did.
fresh_state
make_proxy work
make_agent proj
printf 'github_pat_TYPED_in\n' | incs proxy add proj work --token >/dev/null 2>&1
ph="$(cfg proj environment.GH_TOKEN)"
out="$(FAKE_INCUS_FAIL_EXEC='^iron-rebuild drop' incs proxy rm proj 2>&1)" && rc=0 || rc=$?
assert_eq "rm, proxy cannot revoke: fails" "1" "$rc"
assert_contains     "rm, proxy cannot revoke: says the container is still attached" "still attached" "$out"
assert_not_contains "rm, proxy cannot revoke: does not report a detach" "Detached" "$out"
assert_eq "rm, proxy cannot revoke: tag is kept, so rm can be run again" "work" "$(cfg proj user.incs.proxy)"
assert_eq "rm, proxy cannot revoke: container side is left as it was" "$ph" "$(cfg proj environment.GH_TOKEN)"
out="$(incs proxy rm proj 2>&1)" && rc=0 || rc=$?
assert_eq "rm run again once the proxy works: succeeds" "0" "$rc"
assert_not_contains "rm run again: placeholder is revoked" "$ph" "$(cat "$(fs work /etc/iron-proxy/proxy.yaml)")"
assert_eq "rm run again: tag is cleared" "" "$(cfg proj user.incs.proxy)"

# A real deletion failure inside the proxy, not an injected one. A directory
# where the token file should be makes `rm -f` fail for any user, root included.
fresh_state
make_proxy work
make_agent proj
printf 'github_pat_TYPED_in\n' | incs proxy add proj work --token >/dev/null 2>&1
ph="$(cfg proj environment.GH_TOKEN)"
token_path="$(fs work /etc/iron-proxy/tokens/proj--github)"
rm -f "$token_path" && mkdir "$token_path"
out="$(incs proxy rm proj 2>&1)" && rc=0 || rc=$?
assert_eq "rm, stored token cannot be deleted: fails" "1" "$rc"
assert_eq "rm, stored token cannot be deleted: tag is kept" "work" "$(cfg proj user.incs.proxy)"
assert_contains "rm, stored token cannot be deleted: says the container is still attached" \
  "still attached" "$out"
rmdir "$token_path"
out="$(incs proxy rm proj 2>&1)" && rc=0 || rc=$?
assert_eq "rm run again after the fix: succeeds" "0" "$rc"
assert_eq "rm run again after the fix: tag is cleared" "" "$(cfg proj user.incs.proxy)"
assert_not_contains "rm run again after the fix: placeholder is revoked" \
  "$ph" "$(cat "$(fs work /etc/iron-proxy/proxy.yaml)")"

# A proxy created before commit/drop existed carries a helper that ignores
# them: attach would publish nothing and rm would revoke nothing.
old_helper() {
  cat <<'OLD'
#!/bin/sh
set -eu
dir="${IRON_PROXY_DIR:-/etc/iron-proxy}"
tmp="$(mktemp "$dir/proxy.yaml.XXXXXX")"
cat "$dir/base.yaml" > "$tmp"
for f in "$dir"/entries/*.yaml; do
  if [ -f "$f" ]; then cat "$f" >> "$tmp"; fi
done
mv "$tmp" "$dir/proxy.yaml"
systemctl restart iron-proxy
OLD
}
fresh_state
make_proxy work
make_agent proj
old_helper | incus file push - work/usr/local/bin/iron-rebuild
# ...and a base config that still opens the tunnel port.
printf 'proxy:\n  tunnel_listen: "0.0.0.0:8888"\ntransforms:\n  - name: secrets\n    config:\n      secrets:\n' \
  | incus file push - work/etc/iron-proxy/base.yaml
# Two more containers on it: one attached the old way, one not attached.
make_agent oldway; make_agent bystander
incus config set oldway user.incs.proxy=work
out="$(incs proxy add proj work 2>&1)" && rc=0 || rc=$?
ph="$(cfg proj environment.GH_TOKEN)"
assert_eq "older proxy: add succeeds" "0" "$rc"
assert_contains "older proxy: says which containers must be re-attached" "re-attached: oldway" "$out"
assert_not_contains "older proxy: …and not the one being attached" "re-attached: proj" "$out"
assert_not_contains "older proxy: …nor unattached containers" "bystander" "$out"
out2="$(incs proxy add proj work 2>&1)"
assert_not_contains "older proxy: the notice is given once" "re-attached" "$out2"
ph="$(cfg proj environment.GH_TOKEN)"   # the second add rotated it
assert_not_contains "older proxy: add closes the tunnel port" \
  "tunnel_listen" "$(cat "$(fs work /etc/iron-proxy/proxy.yaml)")"
assert_contains "older proxy: add opens the TLS listener" \
  'https_listen: "0.0.0.0:443"' "$(cat "$(fs work /etc/iron-proxy/proxy.yaml)")"
assert_contains "older proxy: add really publishes the entry" \
  "$ph" "$(cat "$(fs work /etc/iron-proxy/proxy.yaml)")"
# The attach fails after the proxy is brought up to date: the old port must
# already be closed in the config the proxy runs, not just in base.yaml.
fresh_state
make_proxy work
make_agent proj
old_tunnel_base() {
  printf 'proxy:\n  tunnel_listen: "0.0.0.0:8888"\ntransforms:\n  - name: secrets\n    config:\n      secrets:\n'
}
old_tunnel_base | incus file push - work/etc/iron-proxy/base.yaml
old_tunnel_base | incus file push - work/etc/iron-proxy/proxy.yaml
out="$(FAKE_INCUS_FAIL_EXEC='^iron-rebuild commit' incs proxy add proj work 2>&1)" && rc=0 || rc=$?
assert_eq "older proxy, attach fails partway: exits non-zero" "1" "$rc"
assert_not_contains "older proxy, attach fails partway: the running config has no tunnel port" \
  "tunnel_listen" "$(cat "$(fs work /etc/iron-proxy/proxy.yaml)")"
out="$(FAKE_INCUS_FAIL_EXEC='^iron-rebuild$' incs proxy add proj work 2>&1)" && rc=0 || rc=$?
assert_eq "older proxy already migrated: no extra restart is needed" "0" "$rc"

# The proxy cannot be restarted on its new config: say the port may be open.
fresh_state
make_proxy work
make_agent proj
old_tunnel_base | incus file push - work/etc/iron-proxy/base.yaml
out="$(FAKE_INCUS_FAIL_EXEC='^iron-rebuild$' incs proxy add proj work 2>&1)" && rc=0 || rc=$?
assert_eq "older proxy that cannot restart: attach fails" "1" "$rc"
assert_contains "older proxy that cannot restart: says the old port may still be open" \
  "old port may still be open" "$out"

fresh_state
make_proxy work
make_agent proj
incs proxy add proj work >/dev/null 2>&1
ph="$(cfg proj environment.GH_TOKEN)"
old_helper | incus file push - work/usr/local/bin/iron-rebuild
old_tunnel_base | incus file push - work/etc/iron-proxy/base.yaml
out="$(incs proxy rm proj 2>&1)" && rc=0 || rc=$?
assert_eq "older proxy: rm succeeds" "0" "$rc"
# Only an attach migrates the proxy; a detach must not cut off the others.
assert_contains "older proxy: rm leaves the proxy's listeners alone" \
  "tunnel_listen" "$(cat "$(fs work /etc/iron-proxy/base.yaml)")"
assert_not_contains "older proxy: rm really revokes the placeholder" \
  "$ph" "$(cat "$(fs work /etc/iron-proxy/proxy.yaml)")"

# One service out of several.
fresh_state
FAKE_INCUS_NEXT_IP=10.99.0.7 make_proxy work
make_agent proj
printf 'export EDITOR=nvim\n' | incus file push -p - "proj$ZSHENV"
incs proxy add proj work >/dev/null 2>&1
printf 'sk-REAL\n' | incs proxy add proj work --service openai --env OPENAI_API_KEY --host api.openai.com --token >/dev/null 2>&1
gh_ph="$(cfg proj environment.GH_TOKEN)"
ph="$(cfg proj environment.OPENAI_API_KEY)"
out="$(incs proxy rm proj --service nope 2>&1)" && rc=0 || rc=$?
assert_eq "rm --service: an unknown service is refused" "1" "$rc"
out="$(incs proxy rm proj --service openai 2>&1)" && rc=0 || rc=$?
built="$(cat "$(fs work /etc/iron-proxy/proxy.yaml)")"
zshenv="$(cat "$(fs proj "$ZSHENV")")"
assert_eq "rm --service: succeeds" "0" "$rc"
assert_not_contains "rm --service: that placeholder is revoked"   "$ph" "$built"
assert_contains     "rm --service: the others still work"         "$gh_ph" "$built"
assert_eq "rm --service: its stored key is deleted" \
  "gone" "$([[ -e "$(fs work /etc/iron-proxy/tokens/proj--openai)" ]] && echo present || echo gone)"
assert_not_contains "rm --service: its variable leaves ~/.zshenv" "OPENAI_API_KEY" "$zshenv"
assert_contains     "rm --service: the others stay in ~/.zshenv"  "export GH_TOKEN=$gh_ph" "$zshenv"
assert_contains     "rm --service: trust-store variables stay"    "export SSL_CERT_FILE=" "$zshenv"
assert_eq "rm --service: its variable leaves the incus environment" "" "$(cfg proj environment.OPENAI_API_KEY)"
assert_not_contains "rm --service: its /etc/hosts line is removed" "api.openai.com" "$(hosts_of proj)"
assert_contains     "rm --service: the others keep their /etc/hosts line" "# incs-proxy:github" "$(hosts_of proj)"
assert_eq "rm --service: the list is updated" "github=GH_TOKEN" "$(cfg proj user.incs.proxy-services)"
assert_eq "rm --service: the container stays attached" "work" "$(cfg proj user.incs.proxy)"
assert_eq "rm --service: the proxy's authority stays trusted" \
  "present" "$([[ -e "$(fs proj /usr/local/share/ca-certificates/incs-proxy.crt)" ]] && echo present || echo gone)"

out="$(incs proxy rm proj --service github 2>&1)" && rc=0 || rc=$?
assert_eq "rm --service on the last one: succeeds" "0" "$rc"
assert_eq "rm --service on the last one: detaches the container" "" "$(cfg proj user.incs.proxy)"
assert_eq "rm --service on the last one: ~/.zshenv is the user's own again" \
  "export EDITOR=nvim" "$(cat "$(fs proj "$ZSHENV")")"
assert_eq "rm --service on the last one: /etc/hosts is its own again" \
  "127.0.0.1 localhost" "$(hosts_of proj)"
assert_eq "rm --service on the last one: authority is no longer trusted" \
  "gone" "$([[ -e "$(fs proj /usr/local/share/ca-certificates/incs-proxy.crt)" ]] && echo present || echo gone)"

# Everything at once.
fresh_state
make_proxy work
make_agent proj
printf 'export EDITOR=nvim\n' | incus file push -p - "proj$ZSHENV"
incs proxy add proj work >/dev/null 2>&1
incs proxy add proj work --env OPENAI_API_KEY --host api.openai.com >/dev/null 2>&1
out="$(incs proxy rm proj 2>&1)" && rc=0 || rc=$?
assert_eq "rm with several services: succeeds" "0" "$rc"
assert_eq "rm with several services: the proxy honors none of them" \
  "0" "$(grep -c 'proxy_value:' "$(fs work /etc/iron-proxy/proxy.yaml)" || true)"
assert_eq "rm with several services: ~/.zshenv is the user's own again" \
  "export EDITOR=nvim" "$(cat "$(fs proj "$ZSHENV")")"
assert_eq "rm with several services: /etc/hosts is its own again" "127.0.0.1 localhost" "$(hosts_of proj)"
assert_eq "rm with several services: no variable is left in the incus environment" \
  "" "$(cfg proj environment.GH_TOKEN)$(cfg proj environment.OPENAI_API_KEY)"
assert_eq "rm with several services: the list is cleared" "" "$(cfg proj user.incs.proxy-services)"
assert_eq "rm with several services: tag is cleared" "" "$(cfg proj user.incs.proxy)"

# An attachment from before services existed can still be removed.
fresh_state
make_proxy work
make_agent proj
incs proxy add proj work >/dev/null 2>&1
ph="$(cfg proj environment.GH_TOKEN)"
incus config unset proj user.incs.proxy-services
printf 'export EDITOR=nvim\nexport GH_TOKEN=%s # incs-proxy\nexport HTTPS_PROXY=http://10.99.0.7:8888 # incs-proxy\n' "$ph" \
  | incus file push -p - "proj$ZSHENV"
out="$(incs proxy rm proj 2>&1)" && rc=0 || rc=$?
assert_eq "rm of an older attachment: succeeds" "0" "$rc"
assert_not_contains "rm of an older attachment: placeholder is revoked" "$ph" "$(cat "$(fs work /etc/iron-proxy/proxy.yaml)")"
assert_eq "rm of an older attachment: ~/.zshenv is the user's own again" \
  "export EDITOR=nvim" "$(cat "$(fs proj "$ZSHENV")")"

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
assert_contains "list: shows the proxy's address"        "10.99.0.7:443" "$work_line"
assert_contains "list: shows what each container has attached" "proj(github)" "$work_line"
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

make_proxy other
out="$(incs proxy delete work --force other 2>&1)" && rc=0 || rc=$?
assert_eq "delete: a second proxy name is refused" "1" "$rc"
assert_eq "delete: …and neither proxy is deleted" \
  "other work" "$(incus list user.incs.role=proxy --format csv --columns n | sort | tr '\n' ' ' | sed 's/ $//')"

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

make_agent survivor
printf 'github_pat_KEEP\n' | incs proxy add survivor work --token >/dev/null 2>&1
out="$(FAKE_INCUS_FAIL_CALL='^delete --force survivor$' incs -d survivor 2>&1)" && rc=0 || rc=$?
assert_eq "incs -d, delete fails: reports failure" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
assert_eq "incs -d, delete fails: container keeps its proxy" "work" "$(cfg survivor user.incs.proxy)"
assert_eq "incs -d, delete fails: its stored token is kept" \
  "github_pat_KEEP" "$(cat "$(fs work /etc/iron-proxy/tokens/survivor--github)" 2>/dev/null; echo)"
assert_contains "incs -d, delete fails: its entry is still honored" \
  "survivor--github" "$(cat "$(fs work /etc/iron-proxy/proxy.yaml)")"

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
assert_contains "incs -d: …with the command that revokes the placeholder" \
  "iron-rebuild drop keep--github" "$out"

# Incus cannot say whether the shared proxy still exists. The delete still
# happens, but the hook must not pass that off as a revocation.
make_agent flaky
printf 'github_pat_FLAKY\n' | incs proxy add flaky work --token >/dev/null 2>&1
out="$(FAKE_INCUS_FAIL_CALL='^list \^work\$ ' incs -d flaky 2>&1)" && rc=0 || rc=$?
assert_eq "incs -d, Incus cannot check the proxy: container is still deleted" "" "$(incus list '^flaky$' --format csv --columns n)"
assert_contains "incs -d, Incus cannot check the proxy: warns the placeholder may still work" "may still work" "$out"
assert_contains "incs -d, Incus cannot check the proxy: names the revoke command" "iron-rebuild drop flaky--github" "$out"
assert_not_contains "incs -d, Incus cannot check the proxy: does not claim removal" "Removed flaky from proxy" "$out"
assert_eq "incs -d, Incus cannot check the proxy: the entry is kept for the manual revoke" \
  "present" "$([[ -f "$(fs work /etc/iron-proxy/entries/flaky--github.yaml)" ]] && echo present || echo gone)"
assert_eq "incs -d, Incus cannot check the proxy: …and its token" \
  "github_pat_FLAKY" "$(cat "$(fs work /etc/iron-proxy/tokens/flaky--github)" 2>/dev/null; echo)"

# ===========================================================================
echo "concurrent changes to one proxy"
# ===========================================================================
if command -v flock >/dev/null 2>&1; then
  fresh_state
  make_proxy work
  make_agent proj
  incs proxy add proj work >/dev/null 2>&1
  lockdir="$(fs work /etc/iron-proxy)"
  # Another attach or detach is mid-rebuild and holds the lock.
  flock "$lockdir/.rebuild.lock" -c 'sleep 2' &
  holder=$!
  sleep 0.5
  start=$(date +%s)
  incus exec work -- iron-rebuild
  elapsed=$(( $(date +%s) - start ))
  wait "$holder"
  assert_eq "a rebuild waits for one already in progress" "waited" "$([[ $elapsed -ge 1 ]] && echo waited || echo "did not wait (${elapsed}s)")"
  assert_eq "a rebuild leaves no temporary files behind" \
    "" "$(compgen -G "$lockdir/proxy.yaml.*" || true)"
else
  echo "  skip  concurrent rebuilds (flock not installed)"
fi

# An entry upload that is still in flight, or was cut off, must never be live.
fresh_state
make_proxy work
make_agent proj; make_agent other
incs proxy add proj work >/dev/null 2>&1
printf '        - source:\n            type: HALF-WRITTEN' \
  | incus file push -p - work/etc/iron-proxy/entries/other--github.yaml.new
incus exec work -- iron-rebuild
assert_not_contains "a half-uploaded entry is not published by someone else's rebuild" \
  "HALF-WRITTEN" "$(cat "$(fs work /etc/iron-proxy/proxy.yaml)")"
incs proxy add other work >/dev/null 2>&1
built="$(cat "$(fs work /etc/iron-proxy/proxy.yaml)")"
assert_contains     "the finished upload is published" "op://agent-tokens/other/credential" "$built"
assert_not_contains "…and replaces the cut-off one"    "HALF-WRITTEN" "$built"

out="$(incus exec work -- iron-rebuild commit ghost--github ref 2>&1)" && rc=0 || rc=$?
assert_eq "commit with nothing staged is refused" "1" "$rc"
out="$(incus exec work -- iron-rebuild drop ../base 2>&1)" && rc=0 || rc=$?
assert_eq "an entry name with a path in it is refused" "2" "$rc"
assert_contains "…and the proxy config is untouched" \
  "https_listen" "$(cat "$(fs work /etc/iron-proxy/base.yaml)")"

# ===========================================================================
echo "incs without realpath (macOS 12 and earlier)"
# ===========================================================================
fresh_state
make_proxy work
norp="$SANDBOX/no-realpath-bin"
mkdir -p "$norp" "$SANDBOX/linkbin"
ln -sf "$REPO_ROOT/incs" "$SANDBOX/linkbin/incs"
IFS=: read -r -a _dirs <<< "$PATH"
for _d in "${_dirs[@]}"; do
  [[ -d "$_d" ]] || continue
  for _f in "$_d"/*; do
    _n="$(basename "$_f")"
    [[ "$_n" == "realpath" || -e "$norp/$_n" || ! -x "$_f" ]] && continue
    ln -s "$_f" "$norp/$_n"
  done
done
out="$(cd "$SANDBOX" && PATH="$norp" "$SANDBOX/linkbin/incs" -h 2>&1)" && rc=0 || rc=$?
assert_eq "incs -h works without realpath" "0" "$rc"
out="$(cd "$SANDBOX" && PATH="$norp" "$SANDBOX/linkbin/incs" proxy list 2>&1)" && rc=0 || rc=$?
assert_eq "incs proxy works without realpath" "0" "$rc"
assert_contains "…and finds the proxy" "work" "$out"

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
echo "default proxy lifecycle (incs -i)"
# Run the real init CLI through creation of the pair, stopping before guest
# package installation. This exercises parsing, dry-run, templates, and the
# actual init exit trap without pretending the fake can provision an OS.
INIT_FIXTURE="$SANDBOX/init"
mkdir -p "$INIT_FIXTURE/plugins" "$SANDBOX/workspace"
cp "$REPO_ROOT"/incus.{proxy,prompt,profile,macos.setup,envscan} "$INIT_FIXTURE/"
cp "$REPO_ROOT"/plugins/*.sh "$INIT_FIXTURE/plugins/"
awk '/^# Provision \(skipped/ {exit} {print}' "$REPO_ROOT/incus.init" > "$INIT_FIXTURE/incus.init"
printf 'trap - EXIT INT TERM HUP\n' >> "$INIT_FIXTURE/incus.init"
cat >> "$INIT_FIXTURE/incus.init" <<'CHECK_ENV'
if [[ -n "${EXPECT_NO_PROXY:-}" ]]; then
  [[ "${NO_PROXY:-}" == "$EXPECT_NO_PROXY" ]]
fi
CHECK_ENV
# Only command-presence checks use these during the creation phase.
for cmd in sudo curl; do
  printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/bin/$cmd"
  chmod +x "$SANDBOX/bin/$cmd"
done
run_init() {
  bash "$INIT_FIXTURE/incus.init" --no-tui --ack-env --path "$SANDBOX/workspace" "$@"
}

fresh_state
out="$(run_init proj 2>&1)" && rc=0 || rc=$?
assert_eq "default init succeeds without input" "0" "$rc"
assert_eq "default proxy is running" "RUNNING" "$(incus list '^proj-proxy$' --format csv --columns s)"
assert_eq "container records its owned proxy" "proj-proxy" "$(cfg proj user.incs.owned-proxy)"
assert_eq "proxy records its owner" "proj" "$(cfg proj-proxy user.incs.proxy-owner)"
assert_eq "empty proxy needs no 1Password account" "false" "$(cfg proj-proxy user.incs.proxy-1password)"
assert_eq "no services are attached at creation" "" "$(cfg proj user.incs.proxy)"
assert_eq "no GitHub credential is set at creation" "" "$(cfg proj environment.GH_TOKEN)"
assert_not_contains "no secret is requested at creation" "1Password service account token" "$out"
assert_contains "list identifies an empty proxy's owner" "owner:proj" "$(incs proxy list)"
incs -d proj >/dev/null
assert_eq "deleting an empty pair removes both instances" "" "$(incus list --format csv --columns n)"

fresh_state
run_init plain --no-proxy > "$SANDBOX/out" 2>&1
assert_eq "--no-proxy creates only the container" "plain" "$(incus list --format csv --columns n)"
assert_eq "opt-out has no ownership pointer" "" "$(cfg plain user.incs.owned-proxy)"
out="$(NO_PROXY=127.0.0.1 EXPECT_NO_PROXY=127.0.0.1 run_init network-env 2>&1)" && rc=0 || rc=$?
assert_eq "default proxy creation preserves the host's NO_PROXY setting" "0" "$rc"


fresh_state
out="$(run_init preview --dry-run 2>&1)"
assert_contains "dry-run describes the default proxy" "preview-proxy (empty)" "$out"
assert_eq "dry-run creates nothing" "" "$(incus list --format csv --columns n)"
out="$(run_init preview --dry-run --no-proxy 2>&1)"
assert_contains "dry-run shows opt-out" "Proxy:       none" "$out"

fresh_state
mkdir -p "$FAKE_INCUS_STATE/images/incus-init/base/root"
run_init child --from base > "$SANDBOX/out" 2>&1
run_init sibling --from base > "$SANDBOX/out" 2>&1
assert_eq "template child gets its own proxy" "child-proxy" "$(cfg child user.incs.owned-proxy)"
assert_eq "another launch gets a different proxy" "sibling-proxy" "$(cfg sibling user.incs.owned-proxy)"
run_init bare --from base --no-proxy > "$SANDBOX/out" 2>&1
assert_eq "template supports opt-out" "" "$(cfg bare user.incs.owned-proxy)"
run_init vm --vm --no-copy > "$SANDBOX/out" 2>&1
assert_eq "VM also gets a proxy" "vm-proxy" "$(cfg vm user.incs.owned-proxy)"

fresh_state
make_agent proj-proxy
out="$(run_init proj 2>&1)" && rc=0 || rc=$?
assert_eq "name collision stops creation" "1" "$rc"
assert_eq "collision leaves the existing instance alone" "proj-proxy" "$(incus list --format csv --columns n)"
assert_eq "collision never claims the existing instance" "" "$(cfg proj-proxy user.incs.proxy-owner)"

fresh_state
out="$(FAKE_INCUS_FAIL_EXEC='^bash -s' run_init broken 2>&1)" && rc=0 || rc=$?
assert_eq "proxy provisioning failure stops init" "1" "$rc"
assert_eq "failed proxy is rolled back; unanswered cleanup keeps the agent" "broken" "$(incus list --format csv --columns n)"
assert_eq "failed proxy is not recorded as ready" "" "$(cfg broken user.incs.owned-proxy)"
assert_contains "init's cleanup trap survives proxy rollback" "Container 'broken' was partially created" "$out"

fresh_state
run_init proj > "$SANDBOX/out" 2>&1
echo CERT > "$(fs proj-proxy /etc/iron-proxy/ca.crt)"
printf '127.0.0.1 localhost\n' | incus file push -p - proj/etc/hosts
printf 'github_pat_LATER\n' | incs proxy add proj --token > "$SANDBOX/out" 2>&1
assert_eq "add infers the owned proxy" "proj-proxy" "$(cfg proj user.incs.proxy)"
assert_eq "key is stored in the proxy" "github_pat_LATER" "$(cat "$(fs proj-proxy /etc/iron-proxy/tokens/proj--github)")"
assert_not_contains "agent receives only a placeholder" "github_pat_LATER" "$(cfg proj environment.GH_TOKEN)"
incs proxy rm proj >/dev/null
assert_eq "detaching services preserves proxy ownership" "proj-proxy" "$(cfg proj user.incs.owned-proxy)"

out="$(printf '\033[Oops_LATER\033[I\n' | incs proxy configure proj-proxy --vault later-vault 2>&1)" && rc=0 || rc=$?
assert_eq "configure enables 1Password later" "0" "$rc"
assert_eq "configured vault" "later-vault" "$(cfg proj-proxy user.incs.proxy-vault)"
assert_eq "configured proxy can read 1Password" "true" "$(cfg proj-proxy user.incs.proxy-1password)"
assert_contains "configure cleans pasted escapes" "OP_SERVICE_ACCOUNT_TOKEN=ops_LATER" "$(cat "$(fs proj-proxy /etc/iron-proxy/env)")"
assert_not_contains "configure does not echo the token" "ops_LATER" "$out"
assert_not_contains "configure does not pass the token in argv" "ops_LATER" "$(cat "$FAKE_INCUS_STATE/calls.log")"
printf 'github:\n' > "$SANDBOX/default-services.yaml"
incs proxy apply proj "$SANDBOX/default-services.yaml" >/dev/null
assert_contains "apply infers the owned proxy and configured vault" "op://later-vault/proj/credential" "$(cat "$(fs proj-proxy /etc/iron-proxy/entries/proj--github.yaml)")"
make_agent other
out="$(incs proxy add other proj-proxy 2>&1)" && rc=0 || rc=$?
assert_eq "owned proxies cannot be shared" "1" "$rc"
assert_eq "rejected sharing leaves other unattached" "" "$(cfg other user.incs.proxy)"

out="$(FAKE_INCUS_FAIL_CALL='^delete --force proj$' incs -d proj 2>&1)" && rc=0 || rc=$?
assert_eq "failed agent deletion fails the command" "1" "$rc"
assert_eq "failed agent deletion keeps its proxy" "RUNNING" "$(incus list '^proj-proxy$' --format csv --columns s)"
assert_eq "failed agent deletion keeps attachments" "proj-proxy" "$(cfg proj user.incs.proxy)"
incs -d proj >/dev/null
assert_eq "successful agent deletion removes the owned proxy with its credentials" "" "$(incus list '^proj-proxy$' --format csv --columns n)"

fresh_state
run_init proj > "$SANDBOX/out" 2>&1
out="$(FAKE_INCUS_FAIL_CALL='^delete --force proj-proxy$' incs -d proj 2>&1)" && rc=0 || rc=$?
assert_eq "proxy deletion failure is reported" "1" "$rc"
assert_contains "proxy deletion failure gives recovery command" "incs proxy delete proj-proxy" "$out"
assert_eq "remaining proxy retains ownership for diagnosis" "proj" "$(cfg proj-proxy user.incs.proxy-owner)"

fresh_state
make_agent proj
make_proxy shared
incus config set proj user.incs.owned-proxy=shared
out="$(incs -d proj 2>&1)" && rc=0 || rc=$?
assert_eq "invalid ownership does not delete someone else's proxy" "1" "$rc"
assert_eq "shared proxy survives incorrect pointer" "RUNNING" "$(incus list '^shared$' --format csv --columns s)"

fresh_state
run_init proj > "$SANDBOX/out" 2>&1
incs proxy delete proj-proxy >/dev/null
assert_eq "explicit proxy deletion clears ownership on the agent" "" "$(cfg proj user.incs.owned-proxy)"

# ===========================================================================
echo "GitHub Auth plugin (incs -i --gh-token)"
# ===========================================================================
# Runs the plugin's hooks the way incus.init does after creating the container
# and its proxy. Answers to prompts arrive on stdin: token, git name, email.
run_gh_auth() {
  local container="$1" skip="${2:-0}"
  (
    set -euo pipefail
    log()   { echo "[+] $1"; }
    warn()  { echo "[!] $1"; }
    error() { echo "[ERROR] $1" >&2; exit 1; }
    # shellcheck disable=SC1091
    source "$REPO_ROOT/incus.prompt"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/incus.proxy"
    SCRIPT_DIR="$REPO_ROOT" CONTAINER_NAME="$container" HOST_USER="$USER_NAME"
    SKIP_CREDENTIAL_PROXY="$skip"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/plugins/60-gh-auth.sh"
    plugin_prompt
    plugin_install
  )
}
gitconfig_of() { cat "$(fs "$1" "/home/$USER_NAME/.gitconfig")" 2>/dev/null || true; }

fresh_state
FAKE_INCUS_NEXT_IP=10.99.0.9 run_init proj > "$SANDBOX/out" 2>&1
echo CERT > "$(fs proj-proxy /etc/iron-proxy/ca.crt)"
printf '127.0.0.1 localhost\n' | incus file push -p - proj/etc/hosts
out="$(printf 'github_pat_FROM_INIT\nAda Lovelace\nada@example.com\n' | run_gh_auth proj 2>&1)" && rc=0 || rc=$?
assert_eq "gh-auth with a proxy: succeeds" "0" "$rc"
assert_eq "gh-auth with a proxy: the token is stored in the container's proxy" \
  "github_pat_FROM_INIT" "$(cat "$(fs proj-proxy /etc/iron-proxy/tokens/proj--github)" 2>/dev/null; echo)"
assert_eq "gh-auth with a proxy: GitHub is attached to it" "proj-proxy" "$(cfg proj user.incs.proxy)"
assert_eq "gh-auth with a proxy: the container holds a placeholder" \
  "match" "$([[ "$(cfg proj environment.GH_TOKEN)" =~ ^ghp_[0-9a-f]{36}$ ]] && echo match || echo "no match")"
assert_not_contains "gh-auth with a proxy: the real token is not in ~/.zshenv" \
  "github_pat_FROM_INIT" "$(cat "$(fs proj "$ZSHENV")" 2>/dev/null)"
assert_not_contains "gh-auth with a proxy: the real token never appears in argv" \
  "github_pat_FROM_INIT" "$(cat "$FAKE_INCUS_STATE/calls.log")"
assert_not_contains "gh-auth with a proxy: the real token is not echoed" "github_pat_FROM_INIT" "$out"
assert_contains "gh-auth with a proxy: GitHub hosts go to the proxy" \
  "10.99.0.9 github.com api.github.com uploads.github.com # incs-proxy:github" "$(hosts_of proj)"
assert_contains "gh-auth with a proxy: git name is set"  "Ada Lovelace"    "$(gitconfig_of proj)"
assert_contains "gh-auth with a proxy: git email is set" "ada@example.com" "$(gitconfig_of proj)"
assert_contains "gh-auth with a proxy: the prompt says where the token goes" "credential proxy" "$out"

# --no-proxy keeps the old behavior, and says so.
fresh_state
run_init plain --no-proxy > "$SANDBOX/out" 2>&1
out="$(printf 'github_pat_DIRECT\nAda Lovelace\nada@example.com\n' | run_gh_auth plain 1 2>&1)" && rc=0 || rc=$?
assert_eq "gh-auth with --no-proxy: succeeds" "0" "$rc"
assert_eq "gh-auth with --no-proxy: the token goes into the container" "github_pat_DIRECT" "$(cfg plain environment.GH_TOKEN)"
assert_contains "gh-auth with --no-proxy: warns that the real token is in the container" \
  "real token will be stored inside the container" "$out"
assert_contains "gh-auth with --no-proxy: git email is set" "ada@example.com" "$(gitconfig_of plain)"

# The dry run says GitHub will go to the proxy.
fresh_state
# Plugin prompts run before the dry run exits, so they need answers.
out="$(printf 'github_pat_DRY\nAda\nada@example.com\n' | run_init preview --gh-token --dry-run 2>&1)" || true
assert_contains "dry-run with --gh-token: GitHub goes to the proxy" "preview-proxy (github, from GitHub Auth)" "$out"

# ===========================================================================
echo "templates (incs -i --template)"
# ===========================================================================
# save_template lives in incus.init, which cannot be sourced without running.
# Pull the function out, with the Tailscale stash/restore it calls, and run it
# against the fake.
save_template_src="$(awk '
  /^(save_template|stash_tailscale_state|restore_tailscale_state)\(\)/ {capture=1}
  capture {print}
  capture && /^}/ {capture=0}
' "$REPO_ROOT/incus.init")"

run_save_template() {
  local container="$1"
  (
    set -euo pipefail
    log()  { :; }
    warn() { :; }
    wait_for_container() { :; }
    wait_for_network()   { :; }
    CONTAINER_NAME="$container" HOST_USER="$USER_NAME" CONTAINER_WORKSPACE="/workspace" READY_TIMEOUT=1 TS_STATE_BACKUP=""
    eval "$save_template_src"
    save_template
  )
}

fresh_state
make_proxy work
make_agent base
printf 'export EDITOR=nvim\n' | incus file push -p - "base$ZSHENV"
incs proxy add base work >/dev/null 2>&1
incs proxy add base work --env OPENAI_API_KEY --host api.openai.com >/dev/null 2>&1
ph="$(cfg base environment.GH_TOKEN)"
ph_openai="$(cfg base environment.OPENAI_API_KEY)"
run_save_template base >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "template: save succeeds" "0" "$rc"

image_zshenv="$(cat "$FAKE_INCUS_STATE/images/incus-init/base/root$ZSHENV" 2>/dev/null || echo MISSING)"
live_zshenv="$(cat "$(fs base "$ZSHENV")")"
assert_not_contains "template: image holds no placeholder"      "$ph" "$image_zshenv"
assert_not_contains "template: image holds no other service's placeholder" "$ph_openai" "$image_zshenv"
assert_not_contains "template: image has none of our lines"     "# incs-proxy" "$image_zshenv"
assert_contains "template: image keeps the user's own settings"  "export EDITOR=nvim" "$image_zshenv"
assert_contains "template: the running container keeps its placeholder" "export GH_TOKEN=$ph" "$live_zshenv"
image_hosts="$(cat "$FAKE_INCUS_STATE/images/incus-init/base/root/etc/hosts" 2>/dev/null || echo MISSING)"
assert_not_contains "template: image does not send any host to a proxy" "incs-proxy" "$image_hosts"
assert_contains "template: image keeps the rest of /etc/hosts" "127.0.0.1 localhost" "$image_hosts"
assert_contains "template: the running container keeps its /etc/hosts lines" \
  "github.com api.github.com uploads.github.com # incs-proxy:github" "$(hosts_of base)"
assert_contains "template: the running container keeps its other services" \
  "export OPENAI_API_KEY=$ph_openai" "$live_zshenv"
assert_contains "template: …and their /etc/hosts lines" \
  "api.openai.com # incs-proxy:openai-api-key" "$(hosts_of base)"

# /etc/hosts cannot be read: its proxy lines might end up in the image.
fresh_state
make_proxy work
make_agent base
incs proxy add base work >/dev/null 2>&1
ph="$(cfg base environment.GH_TOKEN)"
rm -f "$(fs base /etc/hosts)"
out="$( (
  error() { echo "[ERROR] $1" >&2; exit 1; }
  log()  { :; }; warn() { :; }; wait_for_container() { :; }; wait_for_network() { :; }
  set -euo pipefail
  CONTAINER_NAME=base HOST_USER="$USER_NAME" CONTAINER_WORKSPACE="/workspace" READY_TIMEOUT=1
  eval "$save_template_src"
  save_template
) 2>&1)" && rc=0 || rc=$?
assert_eq "template, /etc/hosts unreadable: save fails" "1" "$rc"
assert_contains "template, /etc/hosts unreadable: says why" "No template saved" "$out"
assert_eq "template, /etc/hosts unreadable: no image is published" \
  "none" "$([[ -d "$FAKE_INCUS_STATE/images/incus-init/base" ]] && echo published || echo none)"
assert_contains "template, /etc/hosts unreadable: the container keeps its placeholder" \
  "export GH_TOKEN=$ph" "$(cat "$(fs base "$ZSHENV")")"

# The Tailscale stash refuses (tailscaled will not stop): nothing else in the
# builder may have been scrubbed by then.
fresh_state
make_proxy work
make_agent base
incs proxy add base work >/dev/null 2>&1
ph="$(cfg base environment.GH_TOKEN)"
mkdir -p "$(fs base /var/lib/tailscale)" "$FAKE_INCUS_STATE/still-active"
echo NODE-KEY > "$(fs base /var/lib/tailscale/tailscaled.state)"
touch "$FAKE_INCUS_STATE/still-active/tailscaled"
out="$( (
  error() { echo "[ERROR] $1" >&2; exit 1; }
  log()  { :; }; warn() { :; }; wait_for_container() { :; }; wait_for_network() { :; }
  set -euo pipefail
  CONTAINER_NAME=base HOST_USER="$USER_NAME" CONTAINER_WORKSPACE="/workspace" READY_TIMEOUT=1 TS_STATE_BACKUP=""
  eval "$save_template_src"
  save_template
) 2>&1)" && rc=0 || rc=$?
assert_eq "template, stash refuses: save fails" "1" "$rc"
assert_contains "template, stash refuses: says why" "Could not stop tailscaled" "$out"
assert_contains "template, stash refuses: the builder keeps its placeholder" \
  "export GH_TOKEN=$ph" "$(cat "$(fs base "$ZSHENV")")"
assert_contains "template, stash refuses: …and its /etc/hosts lines" \
  "# incs-proxy:github" "$(hosts_of base)"

echo ""
echo "Passed: $PASS    Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
