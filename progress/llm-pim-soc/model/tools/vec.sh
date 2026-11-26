#!/bin/sh
# S4-1 test vectors for the RTL testbenches (make vec). Run from model/.
# Settings go through config files and environment variables only (process-privacy.md).
#   build/vec/d3.bin, d4.bin      K12V8 kernel dumps (cfg/d3.cfg 260K, cfg/d4.cfg 15M)
#   build/vec/m1/, m2/            per-kernel record files + manifest.txt (vt job split)
#   build/vec/d5.bin, d6.bin      K8V8 kernel dumps (cfg/d5.cfg 260K, cfg/d6.cfg 15M; kb 8 attention runs)
#   build/vec/m1k8/, m2k8/        their per-kernel split
#   build/vec/pim/                PIM bank images of 260K, NB 4 x LB 16 (vt job bimg)
#   build/vec/m1/rrec.bin, m2/    gemv row records of every matrix (vt job rrec)
#   results/range_k12v8.txt       A10 exponent and shift ranges (vt job range)
set -e
umask 077
B=build
mkdir -p $B/vec/m1 $B/vec/m2 $B/vec/pim $B/vec/m1k8 $B/vec/m2k8
CFG=cfg/d3.cfg ./$B/run
CFG=cfg/d4.cfg ./$B/run
CFG=/dev/null job=split in=$B/vec/d3.bin odir=$B/vec/m1 ./$B/vt
CFG=/dev/null job=split in=$B/vec/d4.bin odir=$B/vec/m2 ./$B/vt
CFG=cfg/d5.cfg ./$B/run
CFG=cfg/d6.cfg ./$B/run
CFG=/dev/null job=split in=$B/vec/d5.bin odir=$B/vec/m1k8 ./$B/vt
CFG=/dev/null job=split in=$B/vec/d6.bin odir=$B/vec/m2k8 ./$B/vt
CFG=cfg/d3.cfg job=bimg odir=$B/vec/pim nb=4 depth=4096 out= ./$B/vt
CFG=cfg/d3.cfg job=rrec odir=$B/vec/m1 out= ./$B/vt
CFG=cfg/d4.cfg job=rrec odir=$B/vec/m2 out= ./$B/vt
CFG=/dev/null job=range in="$B/vec/d3.bin $B/vec/d4.bin" lab="m1_260K m2_15M" out=results/range_k12v8.txt ./$B/vt
( cd $B/vec && sha256sum d3.bin d4.bin d5.bin d6.bin m1/*.bin m2/*.bin m1k8/*.bin m2k8/*.bin pim/*.hex > SHA256SUMS )
echo "vec done"
