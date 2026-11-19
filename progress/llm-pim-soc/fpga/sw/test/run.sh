#!/bin/sh
# Host test sequence of the ARM baseline program (called by `make test`). One
# process at a time. Logs in build/logs/. Last line: HOSTTEST RESULT: PASS|FAIL.
#   1. committed expected values (../expect) equal a fresh generation from the PC
#      golden driver (detects model/src changes that the headers do not follow)
#   2. t   (64-bit) both models, all runs: exit 0, RESULT PASS, parser PASS
#   3. t32 (-m32, 32-bit size_t/long/pointers) the same
#   4. tc  corrupted expected values: exactly 5 mismatches per model, FAIL
#   5. td  (15M only, run E only): data absent -> skipped, corrupt tokenizer image
#          -> FAIL with 1 mismatch, correct data -> PASS
#   6. parser: truncated log INCOMPLETE, boot noise + earlier partial run PASS,
#      tampered kernel time INCOMPLETE, CSV and per-position CSV row counts
#   7. bin2c round trip (Python read-back and C program writing the arrays back)
#   8. plat_xil.c syntax check against stub BSP headers (make prerequisite)
#   9. XSCT script stub check (tclsh)
#  10. stack usage report of the -m32 build (informational, build/logs/stack.txt)
set -u
cd "$(dirname "$0")" || exit 1
L=build/logs
P="python3 -I ../tools/parse_log.py"
M=../../../data/third_party/models
mkdir -p "$L"
items=0
fail=0
ok() { items=$((items + 1)); echo "PASS: $*"; }
bad() { items=$((items + 1)); fail=$((fail + 1)); echo "FAIL: $*"; }
field() { sed -n "s/.* $1=\([^ ]*\).*/\1/p" | tail -1; }

printf '0x10000000 %s/stories15M.bin\n0x14000000 %s/tokenizer.bin\n' "$M" "$M" > build/map_ok.txt
: > build/map_none.txt

echo "== 1. expected values up to date"
mkdir -p build/expn
for m in 1 2; do
  if CFG=../tools/m$m.cfg out=build/expn/exp_m$m.h ./build/gen > $L/gen_m$m.log 2>&1 &&
     cmp -s build/expn/exp_m$m.h ../expect/exp_m$m.h; then
    ok "exp_m$m.h equals a fresh generation"
  else
    bad "exp_m$m.h differs from a fresh generation (run: make gen, review the diff)"
  fi
done

run_main() { # name binary map expect_rc expect_result
  DDRMAP=$3 ./build/$2 > $L/$1.log 2>&1
  rc=$?
  $P $L/$1.log > $L/$1.parse 2>&1
  prc=$?
  pl=$(grep '^PARSE' $L/$1.parse)
  echo "   $pl"
  if [ $rc -eq $4 ] && grep -q "^RESULT .*result=$5" $L/$1.log && echo "$pl" | grep -q "result=$5"; then
    ok "$1 rc=$rc result=$5"
  else
    bad "$1 rc=$rc (want $4), expected result=$5"; grep -E '^PROBLEM' $L/$1.parse
  fi
}

echo "== 2-3. full runs (64-bit, -m32)"
run_main t t build/map_ok.txt 0 PASS
[ "$(field mismatches < $L/t.parse)" = 0 ] && [ "$(field models_run < $L/t.parse)" = 2 ] &&
  ok "t: mismatches 0, 2 models" || bad "t: mismatch count or model count"
grep -q '^CHECK .*run=P .*self_mis=0' $L/t.log && ! grep -q 'self_mis=[1-9]' $L/t.log &&
  ok "t: F/Q probe copies bit-identical to model/src (self_mis 0)" || bad "t: self check"
run_main t32 t32 build/map_ok.txt 0 PASS
grep -q '^BUILD .*ptr_bits=32' $L/t32.log && [ "$(field mismatches < $L/t32.parse)" = 0 ] &&
  ok "t32: 32-bit build, mismatches 0" || bad "t32: not 32-bit or mismatches"

echo "== 4. corrupted expected values"
run_main tc tc build/map_ok.txt 1 FAIL
n1=$(grep '^MSUM m=260K' $L/tc.log | field mismatches)
n2=$(grep '^MSUM m=15M' $L/tc.log | field mismatches)
[ "$n1" = 5 ] && [ "$n2" = 5 ] && [ "$(field mismatches < $L/tc.parse)" = 10 ] &&
  ok "tc: 5 + 5 mismatches found (E/T/P token of F, T/P hash of the H variant per model)" || bad "tc: mismatches $n1 $n2"

echo "== 5. DDR image handling (15M only, run E)"
run_main td_absent td build/map_none.txt 1 FAIL
grep -q '^DATA m=15M .*status=absent' $L/td_absent.log && grep -q 'models_skipped=1' $L/td_absent.log &&
  ok "td_absent: status=absent, skipped" || bad "td_absent"
cp $M/tokenizer.bin build/tok_bad.bin
printf '\377' | dd of=build/tok_bad.bin bs=1 seek=1000 conv=notrunc 2> /dev/null
printf '0x10000000 %s/stories15M.bin\n0x14000000 build/tok_bad.bin\n' "$M" > build/map_bad.txt
run_main td_corrupt td build/map_bad.txt 1 FAIL
grep -q '^DATA m=15M .*status=corrupt' $L/td_corrupt.log && [ "$(field mismatches < $L/td_corrupt.parse)" = 1 ] &&
  ok "td_corrupt: status=corrupt, 1 mismatch" || bad "td_corrupt"
run_main td_ok td build/map_ok.txt 0 PASS
! grep -q '^KERN' $L/td_ok.log && grep -q '^RUN m=15M v=K12V8 run=E' $L/td_ok.log &&
  ok "td_ok: RUN_MASK=1 runs E only" || bad "td_ok: run selection"

echo "== 6. parser"
head -n 80 $L/t.log > build/trunc.log
$P build/trunc.log > $L/p_trunc.log 2>&1
[ $? -eq 2 ] && ok "parser: truncated log INCOMPLETE" || bad "parser: truncated log"
{ printf 'Xilinx First Stage Boot Loader\r\nLMBASE BEGIN fmt=1\r\nBUILD plat=xil\r\n'; cat $L/t.log; } > build/noise.log
$P build/noise.log > $L/p_noise.log 2>&1
[ $? -eq 0 ] && ok "parser: boot noise and earlier partial run ignored" || bad "parser: noise log"
sed '0,/^KERN m=15M v=K12V8 k=gemv_w1 calls=\([0-9]*\) ticks=\([0-9]*\)/s//KERN m=15M v=K12V8 k=gemv_w1 calls=\1 ticks=1\2/' $L/t.log > build/tamper.log
$P build/tamper.log > $L/p_tamper.log 2>&1
[ $? -eq 2 ] && grep -q 'KERN ticks sum' $L/p_tamper.log && ok "parser: tampered kernel time INCOMPLETE" || bad "parser: tamper"
$P --csv build/k.csv --pos-csv build/pos.csv $L/t.log $L/t32.log > $L/p_csv.log 2>&1
nk=$(grep -c ',' build/k.csv)
npos=$(($(wc -l < build/pos.csv) - 1))
nkern=$(grep -c '^KERN' $L/t.log)
nkern32=$(grep -c '^KERN' $L/t32.log)
nrun=$(grep -c '^RUN' $L/t.log)
[ "$nk" -eq $((1 + nkern + nkern32 + 2 * nrun)) ] && [ "$npos" -eq $((2 * (3 * 512 + 3 * 256))) ] &&
  ok "parser: CSV rows $nk, per-position rows $npos" || bad "parser: CSV rows $nk pos $npos"

echo "== 7. bin2c round trip"
BIN2C_CHECK=1 BIN2C_OUT=../gen/m1_data.c BIN2C_IN="$M/stories260K.bin:m1_ck $M/tok512.bin:m1_tk" \
  python3 -I ../tools/bin2c.py > $L/bin2c.log 2>&1 &&
  ok "bin2c: Python read-back equal" || bad "bin2c: Python read-back"
./build/rt && cmp -s build/rt_ck.bin $M/stories260K.bin && cmp -s build/rt_tk.bin $M/tok512.bin &&
  ok "bin2c: compiled arrays equal the files" || bad "bin2c: compiled arrays"

echo "== 8. plat_xil.c syntax (stub BSP headers)"
[ -f build/xilsyntax.ok ] && ok "plat_xil.c compiles with -fsyntax-only -Werror" || bad "plat_xil.c syntax"

echo "== 9. XSCT stub check"
if command -v tclsh > /dev/null 2>&1; then
  tclsh stub_check.tcl > $L/stub.log 2>&1
  grep -q 'STUBCHECK RESULT: PASS' $L/stub.log && ok "xsct_build.tcl stub check ($(grep -c '^STUB scenario' $L/stub.log) scenarios)" ||
    { bad "xsct_build.tcl stub check"; grep 'result=FAIL' $L/stub.log; }
else
  echo "SKIP: no tclsh"
fi

echo "== 10. stack usage (-m32, informational)"
sort -t'	' -k2 -n -r build/su/*.su 2> /dev/null | head -n 25 > $L/stack.txt
echo "   top frames in $L/stack.txt"

echo "HOSTTEST items=$items fail=$fail"
echo "HOSTTEST RESULT: $([ $fail -eq 0 ] && echo PASS || echo FAIL)"
[ $fail -eq 0 ]
