#!/bin/bash
# Generate the real ctl's units in a sandbox, without a running systemd.
# Run on a systemd host: bash tests/egress_units_test.sh
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin" "$SANDBOX/units" "$SANDBOX/run"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/systemctl"
chmod +x "$SANDBOX/bin/systemctl"
export PATH="$SANDBOX/bin:$PATH"
# Redirect only the ctl's filesystem locations; execute its real commands.
sed -e "s|^ETC=.*|ETC=$SANDBOX/etc|" \
    -e "s|^UNITS=.*|UNITS=$SANDBOX/units|" \
    -e "s|/run/|$SANDBOX/run/|g" \
    "$REPO_ROOT/egress/boxen-egress-ctl" > "$SANDBOX/ctl"
bash "$SANDBOX/ctl" add api 4750
bash "$SANDBOX/ctl" add api-v2 4751
slice='boxen-agent_api\x2dv2.slice'
[[ -f "$SANDBOX/units/$slice" ]]
[[ ! -f "$SANDBOX/units/boxen-agent_api-v2.slice" ]]
for unit in boxen-gen_api-v2@.service boxen-check_api-v2@.service; do
  grep -qxF "Slice=$slice" "$SANDBOX/units/$unit"
done
[[ -f "$SANDBOX/units/boxen-agent_api.slice" ]]
echo 'ok: dashed agent has its own escaped slice in both unit templates'
bash "$SANDBOX/ctl" remove api-v2
[[ ! -f "$SANDBOX/units/$slice" ]]
[[ -f "$SANDBOX/units/boxen-agent_api.slice" ]]
echo 'ok: removal deletes the escaped slice and keeps the other agent'

# A generation's upload limits and cap, from the lines gen reads after the hosts.
bash "$SANDBOX/ctl" setup 1.1.1.1 10.0.0.0/8 >/dev/null
gen="$(printf '%s\n' a.example 'upload-cap on' 'upload-limit default 262144000' 'upload-limit *.example.com off' |
  bash "$SANDBOX/ctl" gen api enforce 0123456789abcdef)"
d="$SANDBOX/etc/agents/api/gens/$gen"
[[ "$(cat "$d/upload-cap")" == on ]]
[[ "$(cat "$d/upload-limits")" == $'default 262144000\n*.example.com off' ]]
grep -qxF '    - "a.example"' "$d/acl.yaml"
if grep -q upload "$d/acl.yaml"; then echo "FAIL: upload lines in the allowlist"; exit 1; fi
echo 'ok: gen writes the upload limits and cap beside the allowlist'
for bad in 'upload-cap maybe' 'upload-limit default 0' 'upload-limit 10.0.0.1 5' 'upload-limit default 1G' 'upload-limit a.example 5 6'; do
  if printf '%s\n' "$bad" | bash "$SANDBOX/ctl" gen api enforce 0123456789abcdef >/dev/null 2>&1; then
    echo "FAIL: gen took: $bad"; exit 1
  fi
done
echo 'ok: gen refuses upload lines it does not read'
gen="$(echo a.example | bash "$SANDBOX/ctl" gen api enforce 0123456789abcdef)"
[[ ! -e "$SANDBOX/etc/agents/api/gens/$gen/upload-limits" ]]
echo 'ok: no upload lines, no limits file'

# The log rows and the totals, from journal records as journalctl prints them.
printf '#!/bin/sh\ncat "%s"\n' "$SANDBOX/journal.json" > "$SANDBOX/bin/journalctl"
chmod +x "$SANDBOX/bin/journalctl"
rec() { jq -c -n --arg m "$1" --arg u "boxen-gen_api@$2.service" '{MESSAGE: $m, _SYSTEMD_UNIT: $u}'; }
{
  rec '{"msg":"BOXEN-UPLOAD-LIMIT","time":"2026-11-06T10:00:00Z","connect_host":"up.example","connect_port":443,"window_bytes":327576371,"limit_bytes":262144000,"cut":false}' 4
  rec '{"msg":"BOXEN-UPLOAD-LIMIT","time":"2026-11-06T10:05:00Z","connect_host":"bad\u001b[31m.example","connect_port":443,"window_bytes":262000000,"limit_bytes":262144000,"cut":true}' 4
  rec '{"msg":"CANONICAL-PROXY-CN-CLOSE","requested_host":"up.example:443","bytes_out":1000,"bytes_in":5}' 4
  rec '{"msg":"CANONICAL-PROXY-CN-CLOSE","requested_host":"up.example:443","bytes_out":2500,"bytes_in":5}' 4
  rec '{"msg":"CANONICAL-PROXY-CN-CLOSE","requested_host":"big.example:443","bytes_out":9000,"bytes_in":5}' 4
  rec '{"msg":"CANONICAL-PROXY-CN-CLOSE","requested_host":"boxen-probe.invalid:443","bytes_out":1,"bytes_in":1}' 4
  rec '{"msg":"a CANONICAL-PROXY-CN-CLOSE look-alike","requested_host":"fake.example:443","bytes_out":99999}' 4
} > "$SANDBOX/journal.json"
log="$(bash "$SANDBOX/ctl" log api)"
[[ "$log" == *$'2026-11-06T10:00:00Z\tup.example\t443\tlarge-upload\t312.4M sent in an hour; limit 250M; let through\t4'* ]]
[[ "$log" == *$'bad?[31m.example\t443\tupload-cut\t249.8M sent in an hour; limit 250M; cut\t4'* ]]
echo 'ok: log shows the upload watch lines as large-upload and upload-cut, sanitised'
[[ "$(bash "$SANDBOX/ctl" uploads api)" == $'big.example\t9000\t1\nup.example\t3500\t2' ]]
echo 'ok: uploads adds bytes_out per host, largest first, without the probe or look-alikes'

# boxen-proxy-run passes the generation's limits and cap to the proxy.
sed -e "s|/etc/boxen-egress|$SANDBOX/etc|" -e "s|/usr/local/libexec/boxen/smokescreen|$SANDBOX/bin/fake-smokescreen|" \
  "$REPO_ROOT/egress/boxen-proxy-run" > "$SANDBOX/proxy-run"
printf '#!/bin/sh\nenv | grep "^BOXEN_" | sort\n' > "$SANDBOX/bin/fake-smokescreen"
chmod +x "$SANDBOX/bin/fake-smokescreen"
gen="$(printf '%s\n' a.example 'upload-cap on' 'upload-limit default 5' | bash "$SANDBOX/ctl" gen api enforce 0123456789abcdef)"
env="$(BOXEN_UPLOAD_LIMITS=/stale bash "$SANDBOX/proxy-run" api "$gen")"
[[ "$env" == *"BOXEN_UPLOAD_CAP=on"* && "$env" == *"BOXEN_UPLOAD_LIMITS=$SANDBOX/etc/agents/api/gens/$gen/upload-limits"* ]]
gen="$(echo a.example | bash "$SANDBOX/ctl" gen api report 0123456789abcdef)"
env="$(BOXEN_UPLOAD_LIMITS=/stale bash "$SANDBOX/proxy-run" api "$gen")"
[[ "$env" == *"BOXEN_UPLOAD_CAP=off"* && "$env" != *"BOXEN_UPLOAD_LIMITS"* ]]
echo 'ok: proxy-run passes the limits file and the cap, and none when the generation has none'
