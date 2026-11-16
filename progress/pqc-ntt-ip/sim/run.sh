#!/usr/bin/env bash
# Questa compile and run for module testbenches.
#
#   ./sim/run.sh <name>      compile and run every run of sim/tests/<name>.cfg
#   ./sim/run.sh all         all tests in sim/tests/*.cfg, strictly sequential
#   ./sim/run.sh list        list test names
#
# Each test runs in sim/<name>/ (own work library). The full transcript
# (compile + every run) is written to sim/<name>/run.log, one line per run is
# appended to sim/<name>/summary.txt and printed.
#
# Test config (sim/tests/<name>.cfg, bash syntax):
#   TOP=tb_mod_add                         testbench top module
#   RTL_FILES="pkg/mlkem_pkg.sv l0/mod_add.sv"   relative to $RTL_DIR
#   TB_FILES="common/tb_util_pkg.sv l0/tb_mod_add.sv"  relative to $TB_DIR
#   DPI=1                                  1: compile golden model C++ via vlog
#   RUNS=( "label|vsim args|expect" ... )
#     expect: pass          log has "TB_RESULT: PASS", no Error/Fatal lines
#             oor:<n>       as pass, but exactly <n> "L0_RANGE" assertion errors
#                           and no other Error lines
#             elab_fail:<pattern>  vsim must fail and the log must contain <pattern>
#
# Environment overrides:
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

usage() { sed -n '2,8p' "$0"; exit 2; }

# env.sh is not nounset-clean: source it with -u off.
set +u
# shellcheck disable=SC1091
source "$R/scripts/env.sh" questa >/dev/null 2>&1 || { echo "env.sh questa failed"; exit 2; }
set -u
command -v vsim >/dev/null || { echo "vsim not found after env.sh"; exit 2; }

run_test() {
  local name=$1
  local cfg=$SIM_ROOT/tests/$name.cfg
  [[ -f $cfg ]] || { echo "no config $cfg"; return 2; }

  local TOP="" RTL_FILES="" TB_FILES="" DPI=0
  local -a RUNS=()
  # shellcheck disable=SC1090
  source "$cfg"

  local dir=$SIM_ROOT/$name$SIM_TAG
  mkdir -p "$dir"
  local log=$dir/run.log
  local summary=$dir/summary.txt
  : > "$log"
  : > "$summary"
  cd "$dir" || return 2

  local srcs=() f
  for f in $RTL_FILES; do srcs+=("$RTL_DIR/$f"); done
  for f in $TB_FILES;  do srcs+=("$TB_DIR/$f"); done
  local cfiles=()
  [[ $DPI == 1 ]] && cfiles=($MODEL_CPP)

  echo "### $name: compile (RTL_DIR=$RTL_DIR)" | tee -a "$log"
  rm -rf work
  vlib work >>"$log" 2>&1
  local t0=$SECONDS
  if ! vlog -sv -lint -work work +incdir+"$RTL_DIR" "${srcs[@]}" \
        ${cfiles[@]+"${cfiles[@]}"} ${cfiles[@]+-ccflags "$DPI_CCFLAGS"} >>"$log" 2>&1; then
    echo "$name compile FAIL (see $log)" | tee -a "$summary"
    return 1
  fi
  echo "### $name: compile done in $((SECONDS - t0)) s" | tee -a "$log"

  local fails=0 entry label args expect
  for entry in "${RUNS[@]}"; do
    IFS='|' read -r label args expect <<<"$entry"
    [[ $label =~ $ONLY ]] || continue
    local rlog=$dir/$label.log
    echo "### $name/$label: vsim $TOP $args (expect $expect)" | tee -a "$log"
    t0=$SECONDS
    # shellcheck disable=SC2086
    vsim -c -l "$rlog" -onfinish exit work."$TOP" $args \
      -do "$SIM_ROOT/common/batch.do" \
      >/dev/null 2>&1
    local rc=$? dt=$((SECONDS - t0))
    cat "$rlog" >>"$log"

    local verdict=FAIL n_err n_range
    n_err=$(grep -cE '^# \*\* (Error|Fatal)' "$rlog")
    n_range=$(grep -c 'L0_RANGE' "$rlog")
    case $expect in
      pass)
        [[ $rc == 0 && $n_err == 0 ]] && grep -q 'TB_RESULT: PASS' "$rlog" && verdict=PASS ;;
      oor:*)
        local want=${expect#oor:}
        [[ $rc == 0 && $n_range == "$want" && $n_err == "$want" ]] \
          && grep -q 'TB_RESULT: PASS' "$rlog" && verdict=PASS ;;
      elab_fail:*)
        local pat=${expect#elab_fail:}
        [[ $rc != 0 ]] && grep -q -- "$pat" "$rlog" \
          && ! grep -q 'TB_RESULT' "$rlog" && verdict=PASS ;;
      *) echo "unknown expect '$expect'" ;;
    esac
    local line
    line="$name/$label: $verdict (rc=$rc errors=$n_err L0_RANGE=$n_range wall=${dt}s) $(grep -h 'CHECKS \[' "$rlog" | sed 's/^# //' | tr '\n' ' ')"
    echo "$line" | tee -a "$summary" | tee -a "$log"
    [[ $verdict == PASS ]] || fails=$((fails + 1))
  done
  return $((fails > 0))
}

[[ $# -eq 1 ]] || usage
mkdir -p "$SIM_ROOT"
exec 9>"$SIM_ROOT/.run.lock"
flock 9

case $1 in
  list) for c in "$SIM_ROOT"/tests/*.cfg; do basename "$c" .cfg; done ;;
  all)
    total_fail=0
    for c in "$SIM_ROOT"/tests/*.cfg; do
      n=$(basename "$c" .cfg)
      run_test "$n" || total_fail=$((total_fail + 1))
    done
    echo "### regression: $total_fail test(s) failed"
    exit $((total_fail > 0)) ;;
  -h|--help) usage ;;
  *) run_test "$1"; exit $? ;;
esac
