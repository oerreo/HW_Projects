#!/bin/sh
# Host test of the system program (called by `make test`, S5-1, system.md 3.1). One process at
# a time. Settings reach the program through the environment only. Logs: build/logs/rNN.log
# (numbered; the case name of each number is printed below). Last line:
# SYSHOST RESULT: PASS|FAIL.
#   1. board files: -fsyntax-only -Werror against stub BSP headers (make prerequisite)
#   2. mask x opt x run matrix (E T P K W), 64-bit: 260K builds A and P all positions,
#      15M build A reduced positions for every entry and all positions for a subset,
#      15M build P (only the masks the build can serve; the others are SKIP)
#   3. the same with the -m32 build (reduced positions, 15M subset at all positions)
#   4. fault injection: every injected fault must end in FAIL with its own evidence
#   5. guard fallback, build without IPs, parser checks (truncation, tampering, FAIL log, CSV)
set -u
cd "$(dirname "$0")" || exit 1
L=build/logs
P="python3 -I ../../sw/tools/parse_log.py"
M=../../../data/third_party/models
mkdir -p "$L"
items=0
fail=0
nlog=0
ok() { items=$((items + 1)); echo "PASS: $*"; }
bad() { items=$((items + 1)); fail=$((fail + 1)); echo "FAIL: $*"; }
field() { sed -n "s/.* $1=\([^ ]*\).*/\1/p" | tail -1; }
printf '0x10000000 %s/stories15M.bin\n0x14000000 %s/tokenizer.bin\n' "$M" "$M" > build/map_ok.txt
export DDRMAP=build/map_ok.txt
unset SX_BUILD SX_LIST SX_RUNS SX_STEPS SX_MODELS SX_FAULT SX_IPFAULT SX_IPFAULT_OP SX_IPFAULT_SLOT SX_VE_NMAX SX_AT_HSMAX

# system.md 4.1 list + opt variants (DEFER_AT off, PIM_BATCH on, WRGB_SKIP off, COH_STRICT,
# FUSE_AM off, G+C with PIM_BATCH)
LIST="0,1,2,82,3,4,8,10,20,40,80,f8,7,ff,df,ff:0c,ff:0f,ff:09,ff:1d,ff:05,3:0f"
NLIST=21
LOG=""

# go <case> <binary> <expected rc> [VAR=value ...]: the settings are exported in a subshell
# only (no program arguments; nothing leaks into the next case)
go() {
  c=$1; bin=$2; want=$3
  shift 3
  nlog=$((nlog + 1))
  LOG=$L/r$(printf %02d $nlog).log
  s0=$(date +%s)
  ( for a in "$@"; do export "$a"; done; exec ./build/$bin ) > "$LOG" 2>&1
  rc=$?
  echo "   case $c -> $LOG rc=$rc $(($(date +%s) - s0)) s"
  [ "$rc" -eq "$want" ]
}

# matrix case: all CHECK PASS, parser PASS, expected number of runs, no COH/IPERR/fallback
mat() { # case binary expected_runs VAR=value ...
  c0=$1; b0=$2; n0=$3
  shift 3
  if go "$c0" "$b0" 0 "$@"; then :; else bad "$c0: rc"; fi
  set -- "$c0" "$b0" "$n0"
  $P "$LOG" > "$LOG.parse" 2>&1
  prc=$?
  nrun=$(grep -c '^CHECK' "$LOG")
  npass=$(grep -c '^CHECK .*result=PASS' "$LOG")
  nk=$(grep '^KCMP' "$LOG" | awk '{for(i=1;i<=NF;i++) if($i ~ /^calls=/){split($i,a,"=");s+=a[2]}} END{print s+0}')
  nmis=$(grep '^KCMP' "$LOG" | awk '{for(i=1;i<=NF;i++) if($i ~ /^mis=/){split($i,a,"=");s+=a[2]}} END{print s+0}')
  ncoh=$(grep -c '^COH' "$LOG")
  nerr=$(grep -c '^IPERR' "$LOG")
  nfb=$(grep '^CHECK' "$LOG" | grep -c -v ' fb=0 ')
  cmp=$(sed -n 's/.*compared=\([0-9]*\).*/\1/p' "$LOG.parse")
  echo "   SYSHOST case=$1 runs=$nrun pass=$npass compared=$cmp kcmp_calls=$nk kcmp_mis=$nmis coh_lines=$ncoh iperr=$nerr fb_runs=$nfb skip=$(grep -c '^SKIP' "$LOG")"
  if [ $prc -eq 0 ] && grep -q '^RESULT .*result=PASS' "$LOG" && [ "$nrun" -eq "$3" ] && [ "$npass" -eq "$nrun" ] &&
     [ "$nmis" -eq 0 ] && [ "$ncoh" -eq 0 ] && [ "$nerr" -eq 0 ] && [ "$nfb" -eq 0 ]; then
    ok "$1: $nrun runs PASS, KCMP $nk calls 0 mismatch, COH 0, fallback 0"
  else
    bad "$1: parse rc $prc, runs $nrun/$3, pass $npass"
    grep -E '^(PROBLEM|PARSE)' "$LOG.parse"
    grep -E '^(CHECK .*FAIL|COH|IPERR)' "$LOG" | head -5
  fi
}

# fault case: rc 1, RESULT FAIL, parser FAIL (consistent sums), and the evidence pattern
flt() { # case binary pattern description VAR=value ...
  c0=$1; b0=$2; pat=$3; d0=$4
  shift 4
  go "$c0" "$b0" 1 "$@"
  rc=$?
  set -- "$c0" "$b0" "$pat" "$d0"
  $P "$LOG" > "$LOG.parse" 2>&1
  prc=$?
  ev=$(grep -E "$3" "$LOG" | head -1)
  if [ $rc -eq 0 ] && [ $prc -eq 1 ] && grep -q '^RESULT .*result=FAIL' "$LOG" && [ -n "$ev" ]; then
    ok "$1 detected ($4): $(echo "$ev" | cut -c1-150)"
  else
    bad "$1 not detected as expected ($4): rc_ok=$rc parse=$prc"
    grep -E '^(PROBLEM|PARSE)' "$LOG.parse"
  fi
}

echo "== 1. board files (stub BSP syntax check)"
[ -f build/xilsyntax.ok ] && ok "hal_xil.c, plat_xil.c and all sys/sw sources compile with -fsyntax-only -Werror" ||
  bad "xil syntax"

echo "== 2. matrix, 64-bit"
R="SX_LIST=$LIST"
mat a260_full t $((NLIST * 5)) SX_BUILD=A SX_MODELS=1 "$R" SX_RUNS=ETPKW
mat p260_full t $((NLIST * 5)) SX_BUILD=P SX_MODELS=1 "$R" SX_RUNS=ETPKW
mat a15m_24 t $((NLIST * 5)) SX_BUILD=A SX_MODELS=2 "$R" SX_RUNS=ETPKW SX_STEPS=24
# build P serves only vec masks for 15M: 0, 8, 10, 20, 40, 80, f8 run, the rest SKIP
mat p15m_24 t $((7 * 5)) SX_BUILD=P SX_MODELS=2 "$R" SX_RUNS=ETPKW SX_STEPS=24
mat a15m_full t 6 SX_BUILD=A SX_MODELS=2 SX_LIST=0,ff SX_RUNS=ETK
mat a15m_full_e t 9 SX_BUILD=A SX_MODELS=2 SX_LIST=1,2,82,4,f8,ff:0c,ff:09,ff:1d,ff:05 SX_RUNS=E

echo "== 3. matrix, -m32"
mat a260_m32 t32 $((NLIST * 5)) SX_BUILD=A SX_MODELS=1 "$R" SX_RUNS=ETPKW SX_STEPS=64
mat p260_m32 t32 $((NLIST * 5)) SX_BUILD=P SX_MODELS=1 "$R" SX_RUNS=ETPKW SX_STEPS=64
mat a15m_m32 t32 $((NLIST * 5)) SX_BUILD=A SX_MODELS=2 "$R" SX_RUNS=ETPKW SX_STEPS=16
mat a15m_m32_full t32 4 SX_BUILD=A SX_MODELS=2 SX_LIST=0,ff SX_RUNS=EK
grep -q '^BUILD .*ptr_bits=32' $L/r$(printf %02d $nlog).log && ok "t32 is a 32-bit build" || bad "t32 pointer size"

echo "== 4. fault injection (system.md 3.1 (1)..(10) + register order)"
F="SX_MODELS=1 SX_STEPS=16"
flt f01_noflush t '^COH .*kind=ip_rd_dirty' "producer flush missing -> COH" $F SX_BUILD=A SX_LIST=ff SX_RUNS=E SX_FAULT=1
flt f02_noinval t '^COH .*kind=arm_rd_stale' "consumer invalidate missing -> COH" $F SX_BUILD=A SX_LIST=ff SX_RUNS=E SX_FAULT=2
flt f03_qrec t '^KCMP .*k=attn .*mis=[1-9]' "q record qm/qe order -> KCMP attn" $F SX_BUILD=A SX_LIST=4 SX_RUNS=EK SX_FAULT=3
flt f04_kvbase t '^KCMP .*k=attn .*mis=[1-9]' "DDR KV layer base off by one layer -> KCMP attn" $F SX_BUILD=A SX_LIST=4 SX_RUNS=EK SX_FAULT=4
flt f05_bank t '^KCMP .*k=gemv_q .*mis=[1-9]' "PIM bank base overlap -> KCMP gemv" $F SX_BUILD=P SX_LIST=1 SX_RUNS=EK SX_FAULT=5
flt f06_wrgb t '^KCMP .*k=gemv_.*mis=[1-9]' "WRGB skipped after x changed -> KCMP gemv" $F SX_BUILD=P SX_LIST=1 SX_RUNS=EK SX_FAULT=6
flt f07_barrier t '^CHECK .*tok_mis=[1-9]' "ACTQ(att) before the deferred ATTN -> token mismatch" $F SX_BUILD=A SX_LIST=44 SX_RUNS=EK SX_FAULT=7
flt f08_rdresp t '^IPERR .*kind=err .*err=0x000000[1-7]0' "IP RD_RESP -> IPERR" $F SX_BUILD=P SX_LIST=ff SX_RUNS=E SX_IPFAULT=rdresp SX_IPFAULT_OP=50
flt f09_timeout t '^IPERR .*kind=timeout' "IP never ends -> IPERR timeout" $F SX_BUILD=P SX_LIST=ff SX_RUNS=E SX_IPFAULT=hang SX_IPFAULT_OP=50
# S5-4: after a response error or a timeout the data must still be right: every CHECK has only
# iperr (and, after a timeout, fallback calls of the disabled IP); token, hash, K compare, COH 0
onlyip() { # case VAR=value ...
  c0=$1
  shift 1
  go "$c0" t 1 "$@"
  nbad=$(grep '^CHECK' "$LOG" | grep -c -v ' tok_mis=0 hash_mis=0 .*kmis=0 coh=0 ')
  ncoh=$(grep -c '^COH' "$LOG")
  if [ "$nbad" -eq 0 ] && [ "$ncoh" -eq 0 ] && [ "$(grep -c '^IPERR' "$LOG")" -eq 1 ]; then
    ok "$c0: one IPERR, token / hash / KCMP / COH clean after the fault"
  else
    bad "$c0: CHECK lines with data errors $nbad, COH lines $ncoh"
    grep -E '^(CHECK|COH|IPERR)' "$LOG" | head -4
  fi
}
onlyip f08b_rdresp_data $F SX_BUILD=P SX_LIST=ff SX_RUNS=TK SX_IPFAULT=rdresp SX_IPFAULT_OP=50
onlyip f09b_timeout_data $F SX_BUILD=P SX_LIST=ff SX_RUNS=T SX_IPFAULT=hang SX_IPFAULT_OP=50
flt f10_guard t '^IPERR .*ip=ve kind=err err=0x00000004' "guard bypassed -> BAD_DESC" $F SX_BUILD=A SX_LIST=40 SX_RUNS=E SX_FAULT=10 SX_VE_NMAX=32
flt f11_regorder t '^CHECK .*result=FAIL' "N written after CTRL" $F SX_BUILD=A SX_LIST=60 SX_RUNS=E SX_FAULT=11
flt f01_m32 t32 '^COH .*kind=ip_rd_dirty' "producer flush missing, -m32" $F SX_BUILD=A SX_LIST=ff SX_RUNS=E SX_FAULT=1
flt f02_m32 t32 '^COH .*kind=arm_rd_stale' "consumer invalidate missing, -m32" $F SX_BUILD=P SX_LIST=ff SX_RUNS=E SX_FAULT=2

echo "== 5. guard fallback, no-IP build, parser"
flt g_fallback t '^CHECK .*fb=[1-9]' "n > N_MAX stays on the ARM and is counted" $F SX_BUILD=A SX_LIST=40 SX_RUNS=E SX_VE_NMAX=32
go noip t 0 SX_BUILD=0 SX_LIST=0,ff SX_RUNS=E SX_MODELS=1 SX_STEPS=8
grep -q '^SKIP .*mask=0x000000ff' "$LOG" && grep -q '^SYS build=- .*ga=0 pi=0 at=0 ve=0' "$LOG" &&
  grep -q '^RESULT .*result=PASS' "$LOG" && ok "no IP: SYS shows no slot, mask ff SKIP, mask 0 PASS" || bad "no IP build"
REF=$L/r01.log
head -n 200 $REF > build/trunc.log
$P build/trunc.log > $L/p_trunc.txt 2>&1
[ $? -eq 2 ] && ok "parser: truncated log INCOMPLETE" || bad "parser: truncated log"
sed '0,/^CHECK \(.*\) tok_mis=0 /s//CHECK \1 tok_mis=1 /' $REF > build/tamper1.log
$P build/tamper1.log > $L/p_t1.txt 2>&1
[ $? -eq 2 ] && grep -q 'result field disagrees' $L/p_t1.txt && ok "parser: tampered CHECK INCOMPLETE" || bad "parser: tampered CHECK"
sed '0,/^\(KSPLIT .* k=gemv_q .*\) arm=0 /s//\1 arm=999999999999 /' $REF > build/tamper2.log
$P build/tamper2.log > $L/p_t2.txt 2>&1
[ $? -eq 2 ] && grep -q 'KSPLIT gemv_q' $L/p_t2.txt && ok "parser: tampered KSPLIT INCOMPLETE" || bad "parser: tampered KSPLIT"
sed '0,/^\(KCMP .* k=attn .*\) mis=0 /s//\1 mis=3 /' $REF > build/tamper3.log
$P build/tamper3.log > $L/p_t3.txt 2>&1
[ $? -eq 2 ] && grep -q 'KCMP mis sum' $L/p_t3.txt && ok "parser: tampered KCMP INCOMPLETE" || bad "parser: tampered KCMP"
{ printf 'boot noise\r\nLMSYS BEGIN fmt=1\r\nBUILD plat=xil\r\n'; cat $REF; } > build/noise.log
$P build/noise.log > $L/p_noise.txt 2>&1
[ $? -eq 0 ] && ok "parser: boot noise and earlier partial block ignored" || bad "parser: noise"
$P --csv build/s.csv $REF > $L/p_csv.txt 2>&1
nc=$(($(wc -l < build/s.csv) - 1))
nr=$(grep '^RUN' $REF | grep -c ' ticks=')
nks=$(grep -c '^KSPLIT' $REF)
[ "$nc" -eq $((nr + nks)) ] && ok "parser: CSV rows $nc = RUN $nr + KSPLIT $nks" || bad "parser: CSV rows $nc"
grep -q 'Amdahl estimate' $REF.parse && ok "parser: Amdahl table present" || bad "parser: Amdahl table"

echo "SYSHOST items=$items fail=$fail"
echo "SYSHOST RESULT: $([ $fail -eq 0 ] && echo PASS || echo FAIL)"
[ $fail -eq 0 ]
