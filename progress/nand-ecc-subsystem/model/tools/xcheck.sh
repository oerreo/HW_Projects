#!/bin/sh
# Fixed-point decoder: C trace (build/xdump) against the independent Python implementation
# (tools/fixref.py), every kernel-boundary value of every layer and iteration. Run from model/.
# Configurations cover NMS/OMS, ET-A/ET-B/none, widths 4..6 and strong saturation (LUT scale 3-4
# at alpha 2.4-2.8 on a TLC LSB page with 7 sense levels). With wa >= wm + 1 the APP cannot saturate
# (|APP| <= mmax + f(mmax)), so the last two lines use wa = wm to exercise the APP saturation.
set -e
mkdir -p build/xc
fail=0
i=0
while read code frames alpha scale dfix; do
  i=$((i + 1))
  cat > build/xc/c$i.cfg <<EOF
code $code
tlc_tab ../data/params/tlc_cui2021.txt
out build/xc/t$i.txt
frames $frames
alpha $alpha
scale $scale
seed $i
dfix $dfix
EOF
  CFG=build/xc/c$i.cfg ./build/xdump
  if X_CODE=$code X_TRACE=build/xc/t$i.txt python3 -I tools/fixref.py; then :; else fail=1; fi
done <<EOF
code/qc_t8.txt 40 2.6 3.0 6 6 8 0 12 0 20 1
code/qc_t8.txt 40 2.8 4.0 4 4 6 1 0 1 10 2
code/qc_t8.txt 20 2.8 4.0 5 5 6 0 13 0 6 0
code/qc_s32.txt 6 2.4 3.0 6 6 8 0 12 0 20 1
code/qc_s32.txt 6 2.6 4.0 5 5 7 1 0 1 15 2
code/qc_s32.txt 4 2.8 4.0 4 4 5 0 14 0 8 0
code/qc_t8.txt 40 2.6 4.0 5 5 5 0 12 0 12 1
code/qc_s32.txt 4 2.4 3.0 6 6 6 0 16 0 10 2
EOF
if [ $fail = 0 ]; then echo "xcheck: PASS"; else echo "xcheck: FAIL"; exit 1; fi
