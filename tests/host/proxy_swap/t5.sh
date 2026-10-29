#!/bin/bash
cd "$(dirname "$0")"
D=/etc/incs-proto/a
no_dns() { echo 'resolver_addresses: ["127.0.0.1:9"]' | sudo tee -a "$D/$1/config.yaml" >/dev/null; }
skip_static() { echo 'INCS_PROTO_SKIP_STATIC=1' | sudo tee "$D/$1/env" >/dev/null; }
rec() { sudo journalctl -u "incs-proto-a-check@$1.service" -o cat --no-pager | grep 'incs-probe' | tail -1 \
  | python3 -c 'import json,sys; r=json.loads(sys.stdin.read() or "{}"); print({k: r.get(k) for k in ("allow","enforce_would_deny","decision_reason","error")})' 2>/dev/null; }

echo "== case 4: allowlist left out, wrapper on"
./proto-ctl gen 30 enforce h1.proto.test >/dev/null; sudo rm "$D/30/acl.yaml"
./proto-ctl widen 30; sudo journalctl -u incs-proto-a-check@30.service -o cat --no-pager | grep -m1 refusing

echo "== case 5, outside DNS unavailable; wrapper's own check bypassed for the bad ones"
./proto-ctl gen 31 enforce h1.proto.test >/dev/null; no_dns 31
echo "-- control, correct enforce:";      ./proto-ctl check 31; echo "   $(rec 31)"
./proto-ctl gen 32 report h1.proto.test >/dev/null; no_dns 32
echo "-- control, correct report:";       ./proto-ctl check 32; echo "   $(rec 32)"
./proto-ctl gen 33 off >/dev/null; no_dns 33; echo enforce | sudo tee "$D/33/mode" >/dev/null; skip_static 33
echo "-- deliberately open policy, expected enforce:"; ./proto-ctl check 33; echo "   $(rec 33)"
./proto-ctl gen 34 enforce h1.proto.test >/dev/null; no_dns 34; sudo rm "$D/34/acl.yaml"; skip_static 34
echo "-- missing allowlist, expected enforce:";        ./proto-ctl check 34; echo "   $(rec 34)"
./proto-ctl gen 35 report h1.proto.test >/dev/null; no_dns 35; echo enforce | sudo tee "$D/35/mode" >/dev/null; skip_static 35
echo "-- wrong default (report), expected enforce:";   ./proto-ctl check 35; echo "   $(rec 35)"
./proto-ctl gen 36 enforce h1.proto.test >/dev/null; no_dns 36; echo report | sudo tee "$D/36/mode" >/dev/null; skip_static 36
echo "-- wrong default (enforce), expected report:";   ./proto-ctl check 36; echo "   $(rec 36)"
./proto-ctl status
