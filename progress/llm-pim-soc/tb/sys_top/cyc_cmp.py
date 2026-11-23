#!/usr/bin/env python3
"""CYCLES of the host IP models (fpga/sys/test, spec-based closed forms and estimates) against
the RTL system testbench, op by op (S5-4).

Inputs (environment variables, no arguments, process-privacy rule):
  CC_HOST  trace of the host program  (fpga/sys/test/build/t with SX_CYCTRACE=<file>)
  CC_RTL   trace of the RTL testbench (tb_sys_fwd +CYCTRACE=<file>, hal_dpi.c)
  CC_TAG   label printed in the table
Both traces have one line "slot ctrl cycles" per CYCLES read of a driver, in program order. The
same program with the same settings makes the same op sequence on both; the script checks that
(slot, ctrl) agree line by line and then compares the cycles per op class:
  ga    gemv_acc GEMV          (gemv_acc.md 5 closed form)
  pi    pim RUN (LDW / WRGB / MACAB command lists; pim.md has a closed form only for one MACAB)
  at    attn ATTN op            (estimate from attn.md 6.1 / 6.2)
  kvw   attn KVW op
  ve_*  vec RMSNORM / SWIGLU / ACTQ / ARGMAX (vec.md 6.2 closed form)
Output: one line per class: ops, exact matches, host sum, RTL sum, sum difference in percent,
largest per-op difference. Exit code 1 if the op sequences differ.
"""
import os
import sys

NAMES = {(0, 1): "ga", (1, 1): "pi", (2, 1): "at", (2, 2): "kvw",
         (3, 1): "ve_rms", (3, 2): "ve_swi", (3, 3): "ve_actq", (3, 4): "ve_amax"}


def load(path):
    out = []
    with open(path) as f:
        for line in f:
            p = line.split()
            if len(p) == 3:
                out.append((int(p[0]), int(p[1], 16), int(p[2])))
    return out


def main():
    h = load(os.environ["CC_HOST"])
    r = load(os.environ["CC_RTL"])
    tag = os.environ.get("CC_TAG", "-")
    if len(h) != len(r) or any(a[:2] != b[:2] for a, b in zip(h, r)):
        n = min(len(h), len(r))
        i = next((k for k in range(n) if h[k][:2] != r[k][:2]), n)
        print(f"CYCCMP {tag} SEQUENCE_DIFFERS host={len(h)} rtl={len(r)} first={i}")
        return 1
    st = {}
    for (s, c, ch), (_, _, cr) in zip(h, r):
        k = NAMES.get((s, (c >> 4) & 0xF), f"s{s}_op{(c >> 4) & 0xF}")
        e = st.setdefault(k, [0, 0, 0, 0, 0])
        e[0] += 1
        e[1] += ch == cr
        e[2] += ch
        e[3] += cr
        if abs(cr - ch) > abs(e[4]):
            e[4] = cr - ch
    for k in sorted(st):
        n, eq, sh, sr, mx = st[k]
        pct = 100.0 * (sr - sh) / sh if sh else 0.0
        print(f"CYCCMP {tag} {k} ops={n} exact={eq} host={sh} rtl={sr} diff={sr - sh} "
              f"pct={pct:+.2f} max_op_diff={mx}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
