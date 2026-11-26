#!/bin/sh
# Run every cfg/aff/*.args through the patched AFF3CT (arguments from the file named by A_ARGS, the
# binary behind a private symlink, data/scripts/build_aff3ct.sh). One process, one thread (-t 1),
# each point capped at AFF_SEC seconds (the last progress line is kept). Run from model/.
umask 077
X=/tmp/.rt-$(id -u)/x
for a in cfg/aff/*.args; do
  o=results/aff/$(basename $a .args).txt
  [ -s $o ] && continue
  mkdir -p results/aff
  A_ARGS=$a timeout ${AFF_SEC:-900} $X 2>&1 | tr '\r' '\n' | grep -v '^ *$' > $o.part
  mv $o.part $o
done
