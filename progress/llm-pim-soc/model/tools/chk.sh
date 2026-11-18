#!/bin/sh
# Proves that the H inference path (kernels, H forward, bank model, LUT constants)
# contains no floating point and no libm call:
#  1. compiles each file with -mgeneral-regs-only (any float/double operation is a
#     compile error because no FP/SIMD register may be used),
#  2. lists undefined symbols of the objects and rejects libm/libgcc float helpers,
#  3. rejects the keywords float/double in the comment-stripped source.
# Writes build/chk.res ("items N mismatch M") for the test summary.
cd "$(dirname "$0")/.." || exit 1
B=build
FILES="kern fwd_h bank tabs"
items=0
bad=0
for f in $FILES; do
  items=$((items + 3))
  if ! ${CC:-gcc} -std=c99 -O2 -mgeneral-regs-only -Werror -c src/$f.c -o $B/ci_$f.o 2> $B/ci_$f.log; then
    echo "chk: $f does not compile without FP registers"; cat $B/ci_$f.log; bad=$((bad + 1))
  fi
  und=$(nm -u $B/ci_$f.o | awk '{print $2}' | tr '\n' ' ')
  if echo " $und " | grep -Eq ' (sqrt|sqrtf|exp|expf|exp2|exp2f|log|logf|pow|powf|cos|cosf|sin|sinf|tanh|tanhf|floor|ceil|round|roundf|rint|fabs|fabsf|__aeabi_[fd][a-z0-9]*|__(add|sub|mul|div)[sdt]f3|__float[a-z]*|__fix[a-z]*)[ @]'; then
    echo "chk: $f references float helpers: $und"; bad=$((bad + 1))
  fi
  if ${CC:-gcc} -fpreprocessed -dD -E src/$f.c 2>/dev/null | grep -Ewq 'float|double'; then
    echo "chk: $f uses float or double"; bad=$((bad + 1))
  fi
  echo "chk: $f undefined symbols: ${und:-none}"
done
# negative control: the method must reject a file that uses float
items=$((items + 1))
printf 'int f(int a) { float x = (float)a * 0.5f; return (int)x; }\n' > $B/ci_neg.c
if ${CC:-gcc} -std=c99 -O2 -mgeneral-regs-only -c $B/ci_neg.c -o $B/ci_neg.o 2> /dev/null; then
  echo "chk: negative control compiled, method is not effective"; bad=$((bad + 1))
else
  echo "chk: negative control rejected as expected"
fi
echo "items $items mismatch $bad" > $B/chk.res
echo "check-int items $items mismatch $bad"
[ $bad -eq 0 ]
