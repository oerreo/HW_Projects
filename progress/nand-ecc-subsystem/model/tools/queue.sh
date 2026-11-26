#!/bin/sh
# Run fer configs one after another (serial, one core). Each fer invocation stops after run_sec
# (< 2 h) and is restarted from its checkpoint until the config is finished. Config list from the
# environment variable Q (space separated cfg paths), run from model/.
umask 077
for c in $Q; do
  ck=$(sed -n 's/^ckpt //p' $c)
  CFG=$c ./build/fer
  while [ -n "$ck" ] && [ -f "$ck" ]; do CFG=$c ./build/fer; done
  echo "done $c"
done
