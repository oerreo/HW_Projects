#!/bin/sh
# Host test sequence (called by `make test`). Runs one process at a time.
#   1. check_regs.py (+ its self test)
#   2. t_main (main.c + driver + register model) for ALGO 0..3 x BFU_LATENCY
#      {0, 2, 5}: expect exit 0, RESULT: PASS, parser PASS
#   3. t_main with injected model faults: expect exit 1, RESULT: FAIL,
#      parser FAIL (shows that the comparisons are not vacuous)
#   4. parser on a truncated log: expect INCOMPLETE (exit 2)
#   5. t_drv negative tests
#   6. Tcl stub check of the Vivado / XSCT scripts (if tclsh exists)
# Logs: build/logs/. Prints "HOSTTEST RESULT: PASS|FAIL" at the end.
set -u
cd "$(dirname "$0")"
LOG=build/logs
TOOLS=../tools
mkdir -p "$LOG"
fail=0
note() { echo "$*"; }
bad() { echo "FAIL: $*"; fail=1; }

note "== check_regs"
if python3 -I $TOOLS/check_regs.py > $LOG/check_regs.log 2>&1; then note "check_regs PASS"; else bad "check_regs"; cat $LOG/check_regs.log; fi
if python3 -I $TOOLS/check_regs.py --selftest > $LOG/check_regs_selftest.log 2>&1; then note "check_regs selftest PASS"; else bad "check_regs selftest"; cat $LOG/check_regs_selftest.log; fi

note "== t_main, 4 ALGO x BFU_LATENCY {0,2,5}"
for a in 0 1 2 3; do
  for l in 0 2 5; do
    f=$LOG/main_a${a}_l${l}.log
    PQC_ALGO=$a PQC_BFU_LAT=$l PQC_MODEL_SEED=$((a * 10 + l + 1)) ./build/t_main > $f 2>&1
    rc=$?
    python3 -I $TOOLS/parse_uart_log.py $f > $f.table 2>&1
    prc=$?
    res=$(grep -c '^RESULT: PASS' $f)
    if [ $rc -eq 0 ] && [ $prc -eq 0 ] && [ "$res" = 1 ]; then
      note "algo=$a lat=$l PASS ($(grep -c '^CASE ' $f) cases)"
    else
      bad "algo=$a lat=$l rc=$rc parser=$prc"
    fi
  done
done

note "== t_main with injected faults (must FAIL)"
for flt in data cycles version rbank; do
  f=$LOG/fault_${flt}.log
  PQC_ALGO=1 PQC_BFU_LAT=2 PQC_MODEL_FAULT=$flt ./build/t_main > $f 2>&1
  rc=$?
  python3 -I $TOOLS/parse_uart_log.py $f > $f.table 2>&1
  prc=$?
  if [ $rc -eq 1 ] && [ $prc -eq 1 ] && grep -q '^RESULT: FAIL' $f; then
    note "fault=$flt detected (exit 1, parser FAIL)"
  else
    bad "fault=$flt not detected rc=$rc parser=$prc"
  fi
done
if grep -q '^MISMATCH ' $LOG/fault_data.log; then note "fault=data printed MISMATCH lines"; else bad "fault=data without MISMATCH lines"; fi

note "== parser on a truncated log (must be INCOMPLETE)"
head -n 40 $LOG/main_a0_l0.log > $LOG/truncated.log
python3 -I $TOOLS/parse_uart_log.py $LOG/truncated.log > $LOG/truncated.log.table 2>&1
prc=$?
if [ $prc -eq 2 ]; then note "truncated log -> INCOMPLETE"; else bad "truncated log parser exit $prc"; fi
# CRLF and boot noise must not matter
{ echo "Xilinx First Stage Boot Loader"; sed 's/$/\r/' $LOG/main_a3_l5.log; } > $LOG/crlf.log
if python3 -I $TOOLS/parse_uart_log.py $LOG/crlf.log > $LOG/crlf.log.table 2>&1; then note "CRLF log PASS"; else bad "CRLF log"; fi

note "== t_drv negative tests"
if ./build/t_drv > $LOG/t_drv.log 2>&1 && grep -q '^NEGTEST RESULT: PASS' $LOG/t_drv.log; then
  note "$(grep '^NEGTEST runs' $LOG/t_drv.log) PASS"
else
  bad "t_drv"; grep 'result=FAIL' $LOG/t_drv.log
fi

note "== Tcl stub check"
if command -v tclsh > /dev/null 2>&1; then
  if (cd ../../vivado/test && tclsh stub_check.tcl) > $LOG/tcl_stub.log 2>&1 && grep -q '^STUBCHECK RESULT: PASS' $LOG/tcl_stub.log; then
    note "$(grep '^STUBCHECK runs' $LOG/tcl_stub.log) PASS"
  else
    bad "tcl stub check"; tail -20 $LOG/tcl_stub.log
  fi
else
  note "tclsh not found: Tcl stub check skipped"
fi

if [ $fail -eq 0 ]; then echo "HOSTTEST RESULT: PASS"; else echo "HOSTTEST RESULT: FAIL"; fi
exit $fail
