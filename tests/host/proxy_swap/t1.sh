#!/bin/bash
# Case 1: three allows while a stream stays open through each earlier generation.
cd "$(dirname "$0")"; rm -f s*.status hammer.out
hosts_upto() { local i; for i in $(seq 1 "$1"); do echo -n "h$i.proto.test "; done; }
python3 -I pc.py stream h1.proto.test 90 s1.status &
python3 -I pc.py hammer h1.proto.test 25 > hammer.out & H=$!
sleep 2
for n in 2 3 4; do
  ./proto-ctl gen "$n" enforce $(hosts_upto "$n")
  t=$EPOCHREALTIME; ./proto-ctl widen "$n"
  echo "  widen $n took $(python3 -c "print(f'{($EPOCHREALTIME - $t)*1000:.0f}ms')")"
  [[ $n -lt 4 ]] && { python3 -I pc.py stream "h$n.proto.test" 90 "s$n.status" & }
  sleep 3
done
echo "after: h4 $(python3 -I pc.py once h4.proto.test), h5 $(python3 -I pc.py once h5.proto.test)"
./proto-ctl status
for i in 1 2 3; do echo "stream opened via gen $i: $(cat s$i.status)"; done
wait $H; echo "new connections during the swaps (h1, every ~10ms): $(cat hammer.out)"
