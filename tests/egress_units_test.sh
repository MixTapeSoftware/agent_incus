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
    "$REPO_ROOT/egress/incs-egress-ctl" > "$SANDBOX/ctl"
bash "$SANDBOX/ctl" add api 4750
bash "$SANDBOX/ctl" add api-v2 4751
slice='incs-agent_api\x2dv2.slice'
[[ -f "$SANDBOX/units/$slice" ]]
[[ ! -f "$SANDBOX/units/incs-agent_api-v2.slice" ]]
for unit in incs-gen_api-v2@.service incs-check_api-v2@.service; do
  grep -qxF "Slice=$slice" "$SANDBOX/units/$unit"
done
[[ -f "$SANDBOX/units/incs-agent_api.slice" ]]
echo 'ok: dashed agent has its own escaped slice in both unit templates'
bash "$SANDBOX/ctl" remove api-v2
[[ ! -f "$SANDBOX/units/$slice" ]]
[[ -f "$SANDBOX/units/incs-agent_api.slice" ]]
echo 'ok: removal deletes the escaped slice and keeps the other agent'
