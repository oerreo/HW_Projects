#!/usr/bin/env bash
# Run one Catapult configuration of one L0 block.
#
#   export HLS_BLOCK=<block> HLS_LIB=<lib> HLS_CFG=<cfg> HLS_CLK_NS=<ns>
#   ./hls/l0/tcl/run_cfg.sh
#     HLS_BLOCK  : mod_red_{barrett,mont12,shiftadd,k2red} | mod_mul_{...}
#     HLS_LIB    : fpga | asic
#     HLS_CFG    : c0 | p1 | p2
#     HLS_CLK_NS : clock period in ns
#
# Work directory: hls/l0/run/<top>/ with <top> = <block>_<lib>_<cfg> (also
# the generated top-level module name). Transcript: hls/l0/run/<top>/catapult.log.
# Only one Catapult runs at a time: concurrent invocations are serialized
# with flock on hls/l0/run/.catapult.lock.
#
# Process privacy (.claude/rules/process-privacy.md): the configuration comes
# in the environment, never as arguments; Catapult is started inside the work
# directory as "catapult -shell -f run.tcl", where run.tcl (written there)
# sources tcl/hls_l0.tcl. No block, algorithm or project path appears on any
# command line of this script or its children. Start it with a relative path
# from the project directory.
set -u -o pipefail

[[ $# -eq 0 ]] || { sed -n '2,20p' "$0"; exit 2; }
BLOCK=${HLS_BLOCK:-} LIB=${HLS_LIB:-} CFG=${HLS_CFG:-} CLK=${HLS_CLK_NS:-}
[[ -n $BLOCK && -n $LIB && -n $CFG && -n $CLK ]] || { echo "run_cfg.sh: set HLS_BLOCK, HLS_LIB, HLS_CFG, HLS_CLK_NS"; exit 2; }

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
# argument file: the flow script path stays off the command line
printf 'source {%s}\n' "$TCL_DIR/hls_l0.tcl" > run.tcl
t0=$SECONDS
catapult -shell -f run.tcl >catapult.log 2>&1
rc=$?
dt=$((SECONDS - t0))
n_err=$(grep -c '^# Error' catapult.log)
if [[ $rc == 0 && $n_err == 0 ]] && grep -q 'HLS_FLOW_DONE' catapult.log; then
  echo "$TOP: CATAPULT_OK (wall=${dt}s)"
else
  echo "$TOP: CATAPULT_FAIL rc=$rc errors=$n_err (wall=${dt}s, see $RUN/catapult.log)"
  exit 1
fi
