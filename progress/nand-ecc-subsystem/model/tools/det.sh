#!/bin/sh
# fer determinism: the same short run twice (and once interrupted by run_sec and resumed from the
# checkpoint) must give identical result lines apart from timing fields. Run from model/.
set -e
mkdir -p build/det
rm -f build/det/*.out build/det/*.ck
cat > build/det/d.cfg <<EOF
code code/qc_s32.txt
chan tlc
tlc_tab ../data/params/tlc_cui2021.txt
pts 2.0 2.3
page 0
sense 3
decs fix:w=6,6,8:nms=12:it=15:et=a ref:nms:layer:a=0.75:it=15 bch
max_fe 1000000
max_frames 120
seed 77
EOF
strip() { grep -v '^#' "$1" | sed -e 's/ sec [0-9.]*//' -e 's/ dec_ms [0-9.]*//' -e '/prof_ms/d'; }
CFG=build/det/d.cfg out=build/det/a.out ./build/fer
CFG=build/det/d.cfg out=build/det/b.out ./build/fer
# interrupted run: stop after the first checkpoint interval, then resume
CFG=build/det/d.cfg out=build/det/c.out ckpt=build/det/c.ck ck_sec=0 run_sec=0.3 ./build/fer 2>/dev/null
n=0
while [ -f build/det/c.ck ] && [ $n -lt 200 ]; do
  CFG=build/det/d.cfg out=build/det/c.out ckpt=build/det/c.ck ck_sec=0 run_sec=0.3 ./build/fer 2>/dev/null
  n=$((n + 1))
done
strip build/det/a.out > build/det/a.s
strip build/det/b.out > build/det/b.s
strip build/det/c.out > build/det/c.s
if cmp -s build/det/a.s build/det/b.s && cmp -s build/det/a.s build/det/c.s && [ -s build/det/a.s ]; then
  echo "det: PASS (identical results: two runs and one run resumed $n times from checkpoints)"
else
  echo "det: FAIL"; diff build/det/a.s build/det/b.s | head; diff build/det/a.s build/det/c.s | head; exit 1
fi
