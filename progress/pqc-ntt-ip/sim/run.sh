#!/usr/bin/env bash
# Questa compile and run for module testbenches.
#
#   export T=<name>; ./sim/run.sh   compile and run every run of sim/tests/<name>.cfg
#   ./sim/run.sh quick              quick tier: only the runs marked "q" in every cfg
#   ./sim/run.sh all                all runs of all tests in sim/tests/*.cfg
#   ./sim/run.sh list               list test names
#
# Process privacy (.claude/rules/process-privacy.md): no project, module or test
# name appears on a command line. The test name comes in the environment
# variable T, never as an argument. Each test runs in sim/<name>/ (own work
# library); the script changes into that directory and starts the tools with
# argument files only: "vlog -f c.f" and "vsim -f r.f" (top, generics,
# plusargs, log and -do macro are inside the files, paths relative). The
# simulator log of a run is r.log, copied to <label>.log by shell redirection.
# The full transcript (compile + every run) is sim/<name>/run.log, one line per
# run is appended to sim/<name>/summary.txt and printed. quick / all run the
# tests strictly sequentially, print one final line
#   REGRESSION: tier=<tier> runs=<n> fails=<n> wall=<s>s
# and keep the whole transcript in sim/regression_<tier>.log.
# Start the script with a relative path from the project directory
# ("./sim/run.sh"), so that its own command line shows no project path.
#
# Test config (sim/tests/<name>.cfg, bash syntax):
#   TOP=tb_mod_add                         testbench top module
#   RTL_FILES="pkg/mlkem_pkg.sv l0/mod_add.sv"   relative to $RTL_DIR
#   TB_FILES="common/tb_util_pkg.sv l0/tb_mod_add.sv"  relative to $TB_DIR
#   DPI=1                                  1: compile golden model C++ via vlog
#   RUNS=( "label|vsim args|expect[|tier]" ... )
#     expect: pass          log has "TB_RESULT: PASS", no Error/Fatal lines
#             oor:<n>       as pass, but exactly <n> range assertion errors
#                           (Error lines whose message starts with a tag
#                           L<digit>_RANGE, any level) and no other Error lines
#             assert:<TAG>=<n>[,<TAG>=<n>...]
#                           as pass, but exactly <n> Error lines with each
#                           listed assertion tag, and the sum of the listed
#                           counts equals the number of all Error/Fatal lines
#             elab_fail:<pattern>  vsim must fail and the log must contain <pattern>
#     tier:   empty  run only by "all" (and by a single test)
#             q      also part of the quick tier
#   An assertion tag is the first word of the assertion message
#   ("# ** Error: L1_RANGE bfu: ..." has tag L1_RANGE).
#   vsim args are written to r.f one token per whitespace; they must not
#   contain quotes or spaces inside a token.
#
# Environment:
#   T         test name for a single-test run (sim/tests/$T.cfg).
#   RTL_DIR   RTL source root (default <project>/rtl). Used for mutation tests.
#   SIM_TAG   suffix of the run directory (sim/<name><SIM_TAG>), default empty.
#   ONLY      run only the runs whose label matches this regex.
#
# Only one simulation runs at a time: runs are sequential, and concurrent
# invocations of this script are serialized with flock on sim/.run.lock.
set -u -o pipefail

SIM_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRJ=$(cd "$SIM_ROOT/.." && pwd)
R=/home/theo/work/research
RTL_DIR=${RTL_DIR:-$PRJ/rtl}
TB_DIR=$PRJ/tb
MODEL_DIR=$PRJ/model
SIM_TAG=${SIM_TAG:-}
ONLY=${ONLY:-.}

MODEL_CPP="$MODEL_DIR/src/mlkem_dpi.cpp $MODEL_DIR/src/mlkem_ntt.cpp $MODEL_DIR/src/mlkem_schoolbook.cpp"
DPI_CCFLAGS="-std=c++17 -O2 -I$MODEL_DIR/include"

# run counters of the current invocation (all tests)
N_RUNS=0
N_FAILS=0

usage() { sed -n '2,7p' "${BASH_SOURCE[0]}"; exit 2; }

# env.sh is not nounset-clean: source it with -u off. It sets umask 077 and a
# private TMPDIR; neither is changed here.
set +u
# shellcheck disable=SC1091
source "$R/scripts/env.sh" questa >/dev/null 2>&1 || { echo "env.sh questa failed"; exit 2; }
set -u
command -v vsim >/dev/null || { echo "vsim not found after env.sh"; exit 2; }

# Number of Error/Fatal lines of log $2 (relative name) whose assertion
# message starts with a tag matching the extended regex $1.
count_tag() {
  grep -cE "^# \*\* (Error|Fatal)[^:]*: ($1)( |\$)" "$2"
}

# True if cfg $1 has at least one run of tier $2 (empty tier: any run).
has_tier() {
  local cfg=$1 tier=$2
  [[ -z $tier ]] && return 0
  local -a RUNS=()
  local TOP="" RTL_FILES="" TB_FILES="" DPI=0
  # shellcheck disable=SC1090
  source "$cfg"
  local entry label args expect rtier
  for entry in "${RUNS[@]}"; do
    IFS='|' read -r label args expect rtier <<<"$entry"
    [[ ${rtier:-} == "$tier" ]] && return 0
  done
  return 1
}

# run_test <name> [tier]: tier empty = every run of the cfg. Runs inside
# sim/<name><SIM_TAG>/ and leaves the shell there.
run_test() {
  local name=$1 tier=${2:-}
  local cfg=$SIM_ROOT/tests/$name.cfg
  [[ -f $cfg ]] || { echo "no config for test '$name'"; N_FAILS=$((N_FAILS + 1)); return 2; }

  local TOP="" RTL_FILES="" TB_FILES="" DPI=0
  local -a RUNS=()
  # shellcheck disable=SC1090
  source "$cfg"

  cd "$SIM_ROOT" || return 2
  mkdir -p "$name$SIM_TAG"
  cd "$name$SIM_TAG" || return 2
  : > run.log
  : > summary.txt

  # compile argument file
  {
    echo "-sv -lint -work work"
    echo "+incdir+$RTL_DIR"
    local f
    for f in $RTL_FILES; do echo "$RTL_DIR/$f"; done
    for f in $TB_FILES;  do echo "$TB_DIR/$f"; done
    if [[ $DPI == 1 ]]; then
      for f in $MODEL_CPP; do echo "$f"; done
      echo "-ccflags \"$DPI_CCFLAGS\""
    fi
  } > c.f

  echo "### $name: compile (RTL_DIR=$RTL_DIR)" | tee -a run.log
  rm -rf work
  vlib work >>run.log 2>&1
  local t0=$SECONDS
  if ! vlog -f c.f >>run.log 2>&1; then
    echo "$name compile FAIL (see sim/$name$SIM_TAG/run.log)" | tee -a summary.txt
    N_RUNS=$((N_RUNS + 1))
    N_FAILS=$((N_FAILS + 1))
    return 1
  fi
  echo "### $name: compile done in $((SECONDS - t0)) s" | tee -a run.log

  local fails=0 entry label args expect rtier
  for entry in "${RUNS[@]}"; do
    IFS='|' read -r label args expect rtier <<<"$entry"
    [[ $label =~ $ONLY ]] || continue
    [[ -n $tier && ${rtier:-} != "$tier" ]] && continue
    echo "### $name/$label: vsim $TOP $args (expect $expect)" | tee -a run.log
    # elaboration (generics) and run (plusargs) argument files. vopt is run
    # explicitly into the generic design name "opt": a vopt started by vsim
    # shows the top module name on its command line (process-privacy.md).
    local a
    {
      echo "-work work"
      echo "-j 1"
      echo "work.$TOP"
      echo "-o opt"
      for a in $args; do [[ $a == -[gG]* ]] && echo "$a"; done
    } > o.f
    {
      echo "-c"
      echo "-l r.log"
      echo "-onfinish exit"
      echo "opt"
      for a in $args; do [[ $a == -[gG]* ]] || echo "$a"; done
      echo "-do \"../common/batch.do\""
    } > r.f
    rm -f r.log o.log
    t0=$SECONDS
    local rc
    vopt -f o.f >o.log 2>&1
    rc=$?
    if [[ $rc == 0 ]]; then
      vsim -f r.f >/dev/null 2>&1
      rc=$?
      [[ -f r.log ]] || : > r.log
      { sed 's/^/# /' o.log; cat r.log; } > r.tmp && mv r.tmp r.log
    else
      sed 's/^/# /' o.log > r.log
    fi
    local dt=$((SECONDS - t0))
    cat r.log >>run.log
    cat r.log >"$label.log"

    local verdict=FAIL n_err n_range
    n_err=$(grep -cE '^# \*\* (Error|Fatal)' r.log)
    n_range=$(count_tag 'L[0-9]_RANGE' r.log)
    local detail=""
    case $expect in
      pass)
        [[ $rc == 0 && $n_err == 0 ]] && grep -q 'TB_RESULT: PASS' r.log && verdict=PASS ;;
      oor:*)
        local want=${expect#oor:}
        [[ $rc == 0 && $n_range == "$want" && $n_err == "$want" ]] \
          && grep -q 'TB_RESULT: PASS' r.log && verdict=PASS ;;
      assert:*)
        local spec=${expect#assert:} item tag want_n got sum=0 ok=1
        local -a items
        IFS=',' read -r -a items <<<"$spec"
        for item in "${items[@]}"; do
          tag=${item%%=*}
          want_n=${item#*=}
          if [[ ! $tag =~ ^[A-Z][A-Z0-9_]*$ || ! $want_n =~ ^[0-9]+$ ]]; then
            echo "bad assert item '$item' in $name/$label"
            ok=0
            continue
          fi
          got=$(count_tag "$tag" r.log)
          detail+=" $tag=$got"
          [[ $got == "$want_n" ]] || ok=0
          sum=$((sum + want_n))
        done
        [[ $ok == 1 && $rc == 0 && $n_err == "$sum" ]] \
          && grep -q 'TB_RESULT: PASS' r.log && verdict=PASS ;;
      elab_fail:*)
        local pat=${expect#elab_fail:}
        # pattern matched in the shell, not as a grep argument (it names modules)
        local logtxt
        logtxt=$(<r.log)
        [[ $rc != 0 && $logtxt == *"$pat"* ]] \
          && ! grep -q 'TB_RESULT' r.log && verdict=PASS ;;
      *) echo "unknown expect '$expect'" ;;
    esac
    local line
    line="$name/$label: $verdict (rc=$rc errors=$n_err RANGE=$n_range${detail} wall=${dt}s) $(grep -h 'CHECKS \[' r.log | sed 's/^# //' | tr '\n' ' ')"
    echo "$line" | tee -a summary.txt | tee -a run.log
    N_RUNS=$((N_RUNS + 1))
    [[ $verdict == PASS ]] || { fails=$((fails + 1)); N_FAILS=$((N_FAILS + 1)); }
  done
  return $((fails > 0))
}

# run_tier <quick|all>: every cfg (quick: only runs of tier q), one summary line.
run_tier() {
  local tname=$1 tier=""
  [[ $tname == quick ]] && tier=q
  local t_start c n
  t_start=$(date +%s.%N)
  cd "$SIM_ROOT" || return 2
  {
    echo "### regression tier=$tname started $(date '+%Y-%m-%d %H:%M:%S')"
    for c in "$SIM_ROOT"/tests/*.cfg; do
      n=${c##*/}
      n=${n%.cfg}
      has_tier "$c" "$tier" || continue
      run_test "$n" "$tier"
    done
    local wall
    wall=$(awk -v a="$t_start" -v b="$(date +%s.%N)" 'BEGIN { printf "%.1f", b - a }')
    echo "REGRESSION: tier=$tname runs=$N_RUNS fails=$N_FAILS wall=${wall}s"
    [[ $N_FAILS == 0 ]]
  } > >(tee "regression_$tname.log") 2>&1
  local rc=$? tee_pid=$!
  # let tee flush the transcript before the script exits
  wait "$tee_pid" 2>/dev/null
  return $rc
}

exec 9>"$SIM_ROOT/.run.lock"
flock 9

case ${1:-} in
  list) for c in "$SIM_ROOT"/tests/*.cfg; do n=${c##*/}; echo "${n%.cfg}"; done ;;
  quick|all) [[ $# -eq 1 ]] || usage; run_tier "$1"; exit $? ;;
  -h|--help) usage ;;
  "")
    [[ -n ${T:-} ]] || usage
    run_test "$T"; exit $? ;;
  *) echo "run.sh: test names are passed in the environment (export T=<name>), not as arguments"; exit 2 ;;
esac
