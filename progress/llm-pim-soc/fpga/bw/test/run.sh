#!/bin/sh
# Runs the host builds of the bandwidth program against the software model of the IP:
# normal configurations must end with "BWTEST RESULT: PASS", every injected fault (BW_FAULT,
# see bw_hal_host.c) with "BWTEST RESULT: FAIL". Logs in build/logs/. Settings by environment.
cd "$(dirname "$0")" || exit 2
mkdir -p build/logs
items=0
fails=0
check() { # $1 log, $2 expected result word, $3 description
  items=$((items + 1))
  if grep -q "^BWTEST RESULT: $2" "$1" && grep -q "^BWTEST END" "$1"; then
    echo "HOSTTEST $3: ok"
  else
    echo "HOSTTEST $3: FAILED (expected $2, see $1)"
    fails=$((fails + 1))
  fi
}
BW_P=1 BW_OUTS=4 BW_MAXB=16 ./build/t > build/logs/p1.log 2>&1; check build/logs/p1.log PASS "P=1 b16 o4"
BW_P=2 BW_OUTS=4 BW_MAXB=16 ./build/t > build/logs/p2.log 2>&1; check build/logs/p2.log PASS "P=2 b16 o4"
BW_P=2 BW_OUTS=2 BW_MAXB=256 ./build/t > build/logs/p2b256.log 2>&1; check build/logs/p2b256.log PASS "P=2 b256 o2"
BW_P=2 BW_OUTS=4 BW_MAXB=16 ./build/t32 > build/logs/p2_32.log 2>&1; check build/logs/p2_32.log PASS "P=2 -m32"
for f in 1 2 3 4 5 6; do
  BW_P=2 BW_FAULT=$f ./build/t > build/logs/fault$f.log 2>&1; check build/logs/fault$f.log FAIL "fault $f detected"
done
# the run count of the normal P=2 log must match the sweep definition (90 + 54 with the quick sweep)
items=$((items + 1))
n=$(grep -c "^BW run=" build/logs/p2.log)
neg=$(grep -c "^BWNEG .* chk=OK" build/logs/p2.log)
if [ "$n" = 144 ] && [ "$neg" = 4 ]; then echo "HOSTTEST run count 144, negative 4: ok"
else echo "HOSTTEST run count $n (exp 144), negative ok $neg (exp 4): FAILED"; fails=$((fails + 1)); fi
echo "HOSTTEST items=$items fail=$fails"
if [ $fails = 0 ]; then echo "HOSTTEST RESULT: PASS"; else echo "HOSTTEST RESULT: FAIL"; fi
