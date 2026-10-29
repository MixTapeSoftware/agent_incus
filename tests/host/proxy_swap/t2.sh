#!/bin/bash
# Case 2: a new generation that fails partway changes nothing.
cd "$(dirname "$0")"
before="$(./proto-ctl status)"
python3 -I pc.py hammer h1.proto.test 12 > hammer2.out & H=$!
sleep 1
echo "-- 2a: a bad allowlist entry (caught by the check copy)"
./proto-ctl gen 5 enforce h1.proto.test 'bad host.proto.test'
./proto-ctl widen 5; echo "  exit: $?"
echo "-- 2b: passes the check, but the real generation never acks"
./proto-ctl gen 5 enforce h1.proto.test h2.proto.test h3.proto.test h4.proto.test h5.proto.test
echo 'EINHORN_SOCK_PATH=/run/nonexistent.sock' | sudo tee /etc/incs-proto/a/5/env >/dev/null
./proto-ctl widen 5; echo "  exit: $?"
sudo rm /etc/incs-proto/a/5/env
wait $H
echo "before: $before"
echo "after:  $(./proto-ctl status)"
echo "h5 still denied: $(python3 -I pc.py once h5.proto.test); h4 still allowed: $(python3 -I pc.py once h4.proto.test)"
for i in 1 2 3; do echo "stream via gen $i: $(cat s$i.status)"; done
echo "new connections during the failures: $(cat hammer2.out)"
