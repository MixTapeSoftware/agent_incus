#!/bin/bash
cd "$(dirname "$0")"
./proto-ctl status
python3 -I pc.py stream h1.proto.test 120 x1.status & A=$!
sleep 0.5
./proto-ctl gen 20 enforce h1.proto.test h2.proto.test >/dev/null; ./proto-ctl widen 20 | tail -1
python3 -I pc.py stream h2.proto.test 120 x2.status & B=$!
sleep 1
python3 -I pc.py hammer h1.proto.test 8 > hammer4.out & H=$!
sleep 1
./proto-ctl gen 21 enforce h1.proto.test
t=$EPOCHREALTIME; ./proto-ctl tighten 21 2>&1 | grep -v 'triggering units\|^incs-proto-a.socket$'
echo "  tighten took $(python3 -c "print(f'{($EPOCHREALTIME - $t)*1000:.0f}ms')")"
sleep 0.5
echo "  stream h1: $(cat x1.status)   stream h2: $(cat x2.status)"
echo "  h2 now: $(python3 -I pc.py once h2.proto.test)"
./proto-ctl status
wait $H; echo "  new connections during the tighten: $(cat hammer4.out)"
kill $A $B 2>/dev/null; true
