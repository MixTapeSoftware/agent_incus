#!/bin/bash
cd "$(dirname "$0")"
echo "-- tighten: end every generation, open streams included"
python3 -I pc.py hammer h1.proto.test 8 > hammer3.out & H=$!
sleep 1
./proto-ctl gen 10 enforce h1.proto.test
t=$EPOCHREALTIME; ./proto-ctl tighten 10
echo "  tighten took $(python3 -c "print(f'{($EPOCHREALTIME - $t)*1000:.0f}ms')")"
sleep 1
for i in 1 2 3; do echo "  stream via gen $i: $(cat s$i.status)"; done
echo "  h4 now: $(python3 -I pc.py once h4.proto.test) (allowed before)"
./proto-ctl status
wait $H; echo "  new connections during the tighten: $(cat hammer3.out)"

echo "-- limit of six draining generations"
declare -a SP
for n in 11 12 13 14 15 16; do
  python3 -I pc.py stream h1.proto.test 300 "d$((n-1)).status" & SP[$((n-1))]=$!
  sleep 0.5
  ./proto-ctl gen "$n" enforce h1.proto.test "h$((n-9)).proto.test" >/dev/null
  ./proto-ctl widen "$n" | tail -1
done
./proto-ctl gen 17 enforce h1.proto.test h9.proto.test
./proto-ctl widen 17; echo "  exit: $?"
echo "  end gen 10's only stream"
kill "${SP[10]}"; sleep 2
./proto-ctl status
./proto-ctl widen 17; echo "  exit: $?"
./proto-ctl status
kill "${SP[@]}" 2>/dev/null; true
