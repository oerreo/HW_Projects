#!/usr/bin/env bash
# Run one Catapult configuration of one L0 block.
#
#   hls/l0/tcl/run_cfg.sh <block> <lib> <cfg> <clk_ns>
#     block : mod_red_{barrett,mont12,shiftadd,k2red} | mod_mul_{...}
#     lib   : fpga | asic
#     cfg   : c0 | p1 | p2
#
# Work directory: hls/l0/run/<top>/ with <top> = <block>_<lib>_<cfg> (also
# the generated top-level module name). Transcript: hls/l0/run/<top>/catapult.log.
# Only one Catapult runs at a time: concurrent invocations are serialized
# with flock on hls/l0/run/.catapult.lock.
set -u -o pipefail

[[ $# -eq 4 ]] || { sed -n '2,11p' "$0"; exit 2; }
BLOCK=$1 LIB=$2 CFG=$3 CLK=$4

TCL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HLS_DIR=$(cd "$TCL_DIR/.." && pwd)
R=/home/theo/work/research
TOP=${BLOCK}_${LIB}_${CFG}
RUN=$HLS_DIR/run/$TOP

[[ -f $HLS_DIR/src/$BLOCK.cpp ]] || { echo "no source $HLS_DIR/src/$BLOCK.cpp"; exit 2; }

mkdir -p "$HLS_DIR/run"
exec 9>"$HLS_DIR/run/.catapult.lock"
flock 9

# Machine limit: at most 2 heavy tool processes of this workspace at once
# (other agents may run Questa or Catapult here). Counted are processes of
# this user whose working directory is inside /home/theo/work/research; this
# script itself runs at most one Catapult (flock above).
heavy() {
  local n=0 pid cwd
  for pid in $(pgrep -u "$USER" -x 'catapult|vsimk|vopt|vlog|dc_shell|dc_shell-xg-t|irun|xrun|xmsim|ncsim'); do
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || continue
    [[ $cwd == "$R"/* ]] && n=$((n + 1))
  done
  echo "$n"
}
while (( $(heavy) >= 2 )); do sleep 10; done

set +u
# shellcheck disable=SC1091
source "$R/scripts/env.sh" hls >/dev/null 2>&1 || { echo "env.sh hls failed"; exit 2; }
set -u
command -v catapult >/dev/null || { echo "catapult not found after env.sh"; exit 2; }

rm -rf "$RUN"
mkdir -p "$RUN"
cd "$RUN" || exit 2

export HLS_BLOCK=$BLOCK HLS_LIB=$LIB HLS_CFG=$CFG HLS_CLK_NS=$CLK HLS_TOP=$TOP
t0=$SECONDS
catapult -shell -file "$TCL_DIR/hls_l0.tcl" >catapult.log 2>&1
rc=$?
dt=$((SECONDS - t0))
n_err=$(grep -c '^# Error' catapult.log)
if [[ $rc == 0 && $n_err == 0 ]] && grep -q 'HLS_FLOW_DONE' catapult.log; then
  echo "$TOP: CATAPULT_OK (wall=${dt}s)"
else
  echo "$TOP: CATAPULT_FAIL rc=$rc errors=$n_err (wall=${dt}s, see $RUN/catapult.log)"
  exit 1
fi
