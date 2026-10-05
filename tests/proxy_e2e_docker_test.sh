#!/bin/bash
# tests/proxy_e2e_docker_test.sh
# End-to-end check of what a proxy container actually runs: the real
# provisioning script, the real rebuild script, and the real iron-proxy binary
# serving the config incs generates. The fake incus in proxy_test.sh cannot
# cover any of that.
#
# Runs in a throwaway Ubuntu container. Skipped when Docker is unavailable.
# Needs network access (apt and the iron-proxy release download).
# Run: bash tests/proxy_e2e_docker_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "SKIP: docker is not available"
  exit 0
fi

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

# shellcheck source=../incus.proxy
source "$REPO_ROOT/incus.proxy"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PH_A="ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
PH_B="ghp_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
PH_K="incs_kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk"
PH_UNKNOWN="ghp_cccccccccccccccccccccccccccccccccccc"
REAL_A="github_pat_REAL_for_container_a"
REAL_B="github_pat_REAL_for_container_b"
REAL_K="sk-REAL-api-key-for-container-a"

# Everything below is produced by the code under test.
proxy_base_config      > "$WORK/base.yaml"
proxy_rebuild_script   > "$WORK/iron-rebuild"
proxy_provision_script > "$WORK/provision.sh"
# a and b as GitHub attaches them (Authorization only); a--api as any other
# API is attached (whichever header carries the placeholder).
proxy_render_entry "$PH_A" "$PROXY_DIR/tokens/a--github" Authorization upstream.test > "$WORK/a--github.yaml"
proxy_render_entry "$PH_B" "$PROXY_DIR/tokens/b--github" Authorization upstream.test > "$WORK/b--github.yaml"
proxy_render_entry "$PH_K" "$PROXY_DIR/tokens/a--api"    ""            upstream.test > "$WORK/a--api.yaml"

cat > "$WORK/echo_server.py" <<'PY'
# Two upstreams standing in for an API host. The HTTPS one reports the
# credentials it received. The plain-HTTP one records them: a real key must
# never arrive there.
import http.server, ssl, threading
class Tls(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = ("AUTH=" + self.headers.get("Authorization", "")
                + "|KEY=" + self.headers.get("x-api-key", "")).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
class Plain(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open("/tmp/plain_upstream.log", "a") as f:
            f.write(self.headers.get("Authorization", "") + " "
                    + self.headers.get("x-api-key", "") + "\n")
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()
    def log_message(self, *a): pass
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain("/tmp/up/server.crt", "/tmp/up/server.key")
tls = http.server.HTTPServer(("127.0.0.1", 443), Tls)
tls.socket = ctx.wrap_socket(tls.socket, server_side=True)
threading.Thread(target=tls.serve_forever, daemon=True).start()
http.server.HTTPServer(("127.0.0.1", 80), Plain).serve_forever()
PY

cat > "$WORK/run.sh" <<EOF
set -eu
PH_A="$PH_A" PH_B="$PH_B" PH_K="$PH_K" PH_UNKNOWN="$PH_UNKNOWN"
REAL_A="$REAL_A" REAL_B="$REAL_B" REAL_K="$REAL_K"
EOF
cat >> "$WORK/run.sh" <<'EOF'
exec 3>&1 1>/tmp/run.log 2>&1
result() { echo "RESULT $1" >&3; }
trap 'rc=$?; [ $rc -eq 0 ] || { echo "--- run.log" >&3; tail -40 /tmp/run.log >&3; }' EXIT

# No systemd in this container; the scripts only need these calls to succeed.
printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/systemctl
chmod +x /usr/local/bin/systemctl

# What `incs proxy new` pushes before provisioning.
mkdir -p /etc/iron-proxy
install -m 0644 /work/base.yaml /etc/iron-proxy/base.yaml
install -m 0755 /work/iron-rebuild /usr/local/bin/iron-rebuild

bash /work/provision.sh
result "binary_runs=$(/usr/local/bin/iron-proxy -h 2>&1 | grep -q -- '-config' && echo yes || echo no)"
result "ca_is_a_ca=$(openssl x509 -in /etc/iron-proxy/ca.crt -noout -text | grep -c 'CA:TRUE')"
result "ca_key_mode=$(stat -c %a /etc/iron-proxy/ca.key)"
result "tokens_dir_mode=$(stat -c %a /etc/iron-proxy/tokens)"
result "config_mode=$(stat -c %a /etc/iron-proxy/proxy.yaml)"
result "empty_config_is_base_only=$(grep -c 'proxy_value' /etc/iron-proxy/proxy.yaml || true)"

before="$(sha256sum < /etc/iron-proxy/ca.crt)"
bash /work/provision.sh
result "reprovision_keeps_ca=$([ "$before" = "$(sha256sum < /etc/iron-proxy/ca.crt)" ] && echo yes || echo no)"

# An upstream the proxy trusts, standing in for github.com.
apt-get install -y -qq python3 >/dev/null
mkdir -p /tmp/up && cd /tmp/up
openssl req -x509 -newkey rsa:2048 -nodes -keyout upca.key -out upca.crt -days 1 \
  -subj "/CN=upstream test CA" -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj "/CN=upstream.test" 2>/dev/null
printf 'subjectAltName=DNS:upstream.test\n' > san.cnf
openssl x509 -req -in server.csr -CA upca.crt -CAkey upca.key -CAcreateserial \
  -out server.crt -days 1 -extfile san.cnf 2>/dev/null
cp upca.crt /usr/local/share/ca-certificates/upstream-test.crt
# What `incs proxy add` installs in an agent container.
cp /etc/iron-proxy/ca.crt /usr/local/share/ca-certificates/incs-proxy.crt
update-ca-certificates >/dev/null
python3 /work/echo_server.py &

# What `incs proxy add --token` does: stage, then commit. Two containers with
# GitHub, and a second, generic service for container a.
stage() {
  printf '%s' "$2" > /etc/iron-proxy/tokens/$1.new
  chmod 600 /etc/iron-proxy/tokens/$1.new
  install -m 0600 /work/$1.yaml /etc/iron-proxy/entries/$1.yaml.new
  iron-rebuild commit $1 token
}
stage a--github "$REAL_A"
stage b--github "$REAL_B"
stage a--api    "$REAL_K"
result "staged_files_left=$(ls /etc/iron-proxy/entries /etc/iron-proxy/tokens | grep -c '\.new$' || true)"

# Another container's entry upload is cut off partway. A rebuild that runs
# meanwhile must not publish it: the real binary refuses such a config.
printf '        - source:\n            type: fi' > /etc/iron-proxy/entries/c--github.yaml.new
iron-rebuild
result "half_written_entry_published=$(grep -c 'type: fi$' /etc/iron-proxy/proxy.yaml || true)"

# In a real proxy container the TLS listener is 0.0.0.0:443. Here the stand-in
# upstream already holds 127.0.0.1:443, so the proxy takes 127.0.0.2:443 and
# clients are pointed there, the way /etc/hosts points an agent container.
PROXY_ADDR=127.0.0.2
start_proxy() {
  # Loopback is denied as an upstream by default; this test's upstream is local.
  IRON_METRICS_LISTEN=127.0.0.1:9090 IRON_PROXY_UPSTREAM_DENY_CIDRS=169.254.169.254/32 \
  IRON_PROXY_HTTPS_LISTEN=$PROXY_ADDR:443 \
    /usr/local/bin/iron-proxy -config /etc/iron-proxy/proxy.yaml >/tmp/proxy.log 2>&1 &
  PROXY_PID=$!
  for i in $(seq 1 50); do
    if curl -sk -o /dev/null --max-time 2 --resolve upstream.test:443:$PROXY_ADDR https://upstream.test/ 2>/dev/null; then break; fi
    if ! kill -0 $PROXY_PID 2>/dev/null; then cat /tmp/proxy.log; exit 1; fi
    sleep 0.2
  done
}
start_proxy
result "proxy_accepts_generated_config=$(kill -0 $PROXY_PID 2>/dev/null && echo yes || echo no)"

via_proxy() { curl -s --max-time 20 --resolve upstream.test:443:$PROXY_ADDR "$@" https://upstream.test/; }
basic() { via_proxy -u "x-access-token:$1" | sed -e 's/^AUTH=Basic //' -e 's/|KEY=.*//' | base64 -d; }

result "bearer_a=$(via_proxy -H "Authorization: Bearer $PH_A")"
result "bearer_b=$(via_proxy -H "Authorization: Bearer $PH_B")"
result "git_basic_a=$(basic "$PH_A")"
result "gh_token_scheme_a=$(via_proxy -H "Authorization: token $PH_A")"
result "unknown_placeholder=$(via_proxy -H "Authorization: Bearer $PH_UNKNOWN")"
result "api_key_header=$(via_proxy -H "x-api-key: $PH_K")"
result "github_placeholder_in_other_header=$(via_proxy -H "x-api-key: $PH_A")"
result "intercepted_by=$(curl -sv --max-time 20 --resolve upstream.test:443:$PROXY_ADDR https://upstream.test/ 2>&1 \
  | grep -i 'issuer:' | grep -o 'incs proxy CA' | head -1)"

# Plain HTTP must have no way to the swap. curl exit 7 = nothing listening.
# Each probe carries both placeholders: GitHub's in Authorization and the
# generic service's in x-api-key.
both() { curl -s -o /dev/null --max-time 5 -H "Authorization: Bearer $PH_A" -H "x-api-key: $PH_K" "$@"; }
rc=0; both -x http://$PROXY_ADDR:8888 http://upstream.test/ || rc=$?
result "old_tunnel_port=$rc"
rc=0; both -p -x http://$PROXY_ADDR:8888 http://upstream.test/ || rc=$?
result "old_tunnel_port_connect=$rc"
rc=0; both --connect-to upstream.test:80:$PROXY_ADDR:80 http://upstream.test/ || rc=$?
result "plain_port_80=$rc"
# Plain HTTP spoken to the TLS port itself.
both --connect-to upstream.test:80:$PROXY_ADDR:443 http://upstream.test/ || true
# A request that arrives over TLS but names an http:// target, or port 80.
both --resolve upstream.test:443:$PROXY_ADDR --request-target 'http://upstream.test/' https://upstream.test/ || true
both --resolve upstream.test:443:$PROXY_ADDR -H "Host: upstream.test:80" https://upstream.test/ || true
# The plain-HTTP listener exists, but only on loopback inside the proxy.
rc=0; curl -s -o /dev/null --max-time 5 http://$PROXY_ADDR:18080/ || rc=$?
result "plain_listener_off_loopback=$rc"
# Control: the plain upstream does record what reaches it.
curl -s -o /dev/null --max-time 5 -H "Authorization: control-auth" -H "x-api-key: control-key" http://127.0.0.1:80/ || true
result "plain_upstream_records=$(grep -c 'control-auth control-key' /tmp/plain_upstream.log 2>/dev/null || true)"
result "plain_upstream_saw_a_real_key=$(grep -c REAL /tmp/plain_upstream.log 2>/dev/null || true)"

# What `incs proxy rm a` does on the proxy side.
iron-rebuild drop a--github a--api
result "after_rm_a_files=$(ls /etc/iron-proxy/entries /etc/iron-proxy/tokens | grep -c '^a--' || true)"
kill $PROXY_PID; wait $PROXY_PID 2>/dev/null || true
start_proxy
result "after_rm_a=$(via_proxy -H "Authorization: Bearer $PH_A")"
result "after_rm_a_api=$(via_proxy -H "x-api-key: $PH_K")"
result "after_rm_b_still_works=$(via_proxy -H "Authorization: Bearer $PH_B")"
EOF

echo "proxy end to end (docker, takes about a minute)"
OUT="$(docker run --rm --add-host upstream.test:127.0.0.1 -v "$WORK:/work:ro" \
  ubuntu:24.04 bash /work/run.sh 2>&1)" || { echo "$OUT"; echo "FAIL: container run failed"; exit 1; }

r() { printf '%s\n' "$OUT" | sed -n "s/^RESULT $1=//p"; }

assert_eq "provisioning installs a working iron-proxy binary"      "yes" "$(r binary_runs)"
assert_eq "generated certificate is a certificate authority"       "1"   "$(r ca_is_a_ca)"
assert_eq "certificate authority key is private"                   "600" "$(r ca_key_mode)"
assert_eq "stored tokens directory is private"                     "700" "$(r tokens_dir_mode)"
assert_eq "built config is private"                                "600" "$(r config_mode)"
assert_eq "a proxy with no entries builds a config with no swaps"  "0"   "$(r empty_config_is_base_only)"
assert_eq "provisioning again keeps the same certificate authority" "yes" "$(r reprovision_keeps_ca)"
assert_eq "commit leaves no staged files behind"                    "0"   "$(r staged_files_left)"
assert_eq "a half-written entry is not published by a rebuild"      "0"   "$(r half_written_entry_published)"
assert_eq "iron-proxy starts on the config incs generates"         "yes" "$(r proxy_accepts_generated_config)"
assert_eq "container a's placeholder becomes a's token"   "AUTH=Bearer $REAL_A|KEY=" "$(r bearer_a)"
assert_eq "container b's placeholder becomes b's token"   "AUTH=Bearer $REAL_B|KEY=" "$(r bearer_b)"
assert_eq "git-style basic auth is swapped"               "x-access-token:$REAL_A" "$(r git_basic_a)"
assert_eq "gh's 'token' auth scheme is swapped"           "AUTH=token $REAL_A|KEY=" "$(r gh_token_scheme_a)"
assert_eq "an unknown placeholder is passed through as is" "AUTH=Bearer $PH_UNKNOWN|KEY=" "$(r unknown_placeholder)"
assert_eq "a generic service's placeholder is swapped in x-api-key" "AUTH=|KEY=$REAL_K" "$(r api_key_header)"
assert_eq "GitHub's placeholder is swapped in Authorization only" "AUTH=|KEY=$PH_A" "$(r github_placeholder_in_other_header)"
assert_eq "HTTPS is intercepted by this proxy's authority" "incs proxy CA" "$(r intercepted_by)"
assert_eq "nothing listens on the old tunnel port"          "7" "$(r old_tunnel_port)"
assert_eq "…for CONNECT either"                             "7" "$(r old_tunnel_port_connect)"
assert_eq "nothing listens for plain HTTP on the proxy's address" "7" "$(r plain_port_80)"
assert_eq "the plain-HTTP listener is not reachable off loopback" "7" "$(r plain_listener_off_loopback)"
assert_eq "the plain-HTTP upstream records both headers that reach it (control)" "1" "$(r plain_upstream_records)"
assert_eq "no real key ever reached a plain-HTTP upstream"  "0" "$(r plain_upstream_saw_a_real_key)"
assert_eq "detaching a removes its entries and stored keys" "0" "$(r after_rm_a_files)"
assert_eq "after detaching a, its other placeholder stops working too" "AUTH=|KEY=$PH_K" "$(r after_rm_a_api)"
assert_eq "after detaching a, its placeholder stops working" "AUTH=Bearer $PH_A|KEY=" "$(r after_rm_a)"
assert_eq "after detaching a, b is unaffected"            "AUTH=Bearer $REAL_B|KEY=" "$(r after_rm_b_still_works)"

echo ""
echo "Passed: $PASS    Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
