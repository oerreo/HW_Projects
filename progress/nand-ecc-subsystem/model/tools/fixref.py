"""Independent implementation of the fixed-point layered min-sum decoder (docs/spec/numeric.md 4) and
comparison against a C trace (tools/xdump.c). Standard library only. No arguments (process privacy):
environment X_CODE (QC table), X_TRACE (trace file). Prints the number of compared values and
mismatches; exit status 1 on any mismatch.

Structure differs on purpose from model/src/dec_fix.c: R is stored edge-wise per (layer, block
column, lane) instead of compressed, and every layer is processed block column by block column with
an explicit cyclic shift of the APP block (lane i of block column c with shift s reads APP[c*Z + (i+s)%Z]).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qclib  # noqa: E402


def sat(x, m):
    return m if x > m else (-m if x < -m else x)


class Dec:
    def __init__(self, mb, nb, Z, S, cfg):
        self.mb, self.nb, self.Z, self.S = mb, nb, Z, S
        (self.wc, self.wm, self.wa, self.corr, self.num, self.beta, self.iters, self.et) = cfg
        self.mmax = (1 << (self.wm - 1)) - 1
        self.amax = (1 << (self.wa - 1)) - 1
        self.cols = [[c for c in range(nb) if S[r][c] >= 0] for r in range(mb)]

    def f(self, m):
        if self.corr == 0:
            return (m * self.num) >> 4
        return max(m - self.beta, 0)

    def syndrome_ok(self, hard):
        Z = self.Z
        for r in range(self.mb):
            for i in range(Z):
                p = 0
                for c in self.cols[r]:
                    p ^= hard[c * Z + (i + self.S[r][c]) % Z]
                if p:
                    return False
        return True

    def decode(self, llr):
        """yields trace records in the order of tools/xdump.c, returns via the last record"""
        Z, mb = self.Z, self.mb
        app = list(llr)
        hard = [1 if v < 0 else 0 for v in llr]
        R = {(r, c): [0] * Z for r in range(mb) for c in self.cols[r]}
        ok = 0
        it = 0
        while it < self.iters:
            sat_all, changed = True, False
            for r in range(mb):
                cols = self.cols[r]
                # phase 1: shifter + Q per block column (lanes)
                lane_in, qv = {}, {}
                for c in cols:
                    s = self.S[r][c]
                    blk = [app[c * Z + (i + s) % Z] for i in range(Z)]
                    lane_in[c] = blk
                    qv[c] = [sat(blk[i] - R[(r, c)][i], self.mmax) for i in range(Z)]
                cn = []
                for i in range(Z):
                    mags = [abs(qv[c][i]) for c in cols]
                    m1 = min(mags)
                    idx = mags.index(m1)
                    m2 = min(mags[:idx] + mags[idx + 1:])
                    sg = 0
                    par = 0
                    for c in cols:
                        sg ^= 1 if qv[c][i] < 0 else 0
                        par ^= 1 if lane_in[c][i] < 0 else 0
                    if par:
                        sat_all = False
                    cn.append((self.f(m1), self.f(m2), idx, sg))
                yield ('LI', it, r, [lane_in[c][i] for i in range(Z) for c in cols])
                yield ('Q', [qv[c][i] for i in range(Z) for c in cols])
                yield ('CN', [v for t in cn for v in t])
                # phase 2: R_new, APP write-back through the inverse shift
                rn, lo = {}, {}
                for j, c in enumerate(cols):
                    s = self.S[r][c]
                    rn[c], lo[c] = [0] * Z, [0] * Z
                    for i in range(Z):
                        f1, f2, idx, sg = cn[i]
                        m = f2 if j == idx else f1
                        neg = sg ^ (1 if qv[c][i] < 0 else 0)
                        rv = -m if neg else m
                        a = sat(qv[c][i] + rv, self.amax)
                        rn[c][i] = rv
                        lo[c][i] = a
                        v = c * Z + (i + s) % Z
                        app[v] = a
                        h = 1 if a < 0 else 0
                        if h != hard[v]:
                            hard[v] = h
                            changed = True
                    R[(r, c)] = rn[c]
                yield ('RN', [rn[c][i] for i in range(Z) for c in cols])
                yield ('LO', [lo[c][i] for i in range(Z) for c in cols])
            yield ('IE', it, list(app))
            it += 1
            if self.et == 1 and self.syndrome_ok(hard):
                ok = 1
                break
            if self.et == 2 and sat_all and not changed:
                ok = 1
                break
        if self.et == 0:
            ok = 1 if self.syndrome_ok(hard) else 0
        yield ('D', it, ok, ''.join(str(h) for h in hard))


def main():
    mb, nb, Z, S, _ = qclib.read_table(os.environ['X_CODE'])
    lines = open(os.environ['X_TRACE']).read().split('\n')
    pos = 0
    nval = nmis = frames = 0
    first = None
    dec = None
    gen = None
    while pos < len(lines):
        ln = lines[pos].split()
        pos += 1
        if not ln:
            continue
        tag = ln[0]
        if tag == 'C':
            dec = Dec(mb, nb, Z, S, [int(x) for x in ln[1:9]])
            continue
        if tag == 'F':
            frames += 1
            continue
        if tag == 'LLR':
            gen = dec.decode([int(x) for x in ln[1:]])
            continue
        ref = next(gen)
        if ref[0] != tag:
            print('structure mismatch: C %s, Python %s (line %d)' % (tag, ref[0], pos))
            return 1
        if tag in ('LI',):
            got = [int(x) for x in ln[1:]]
            exp = [ref[1], ref[2]] + ref[3]
        elif tag == 'IE':
            got = [int(x) for x in ln[1:]]
            exp = [ref[1]] + ref[2]
        elif tag == 'D':
            got = [int(ln[1]), int(ln[2]), ln[3]]
            exp = [ref[1], ref[2], ref[3]]
        else:
            got = [int(x) for x in ln[1:]]
            exp = ref[1]
        nval += len(exp)
        bad = sum(1 for a, b in zip(got, exp) if a != b) + abs(len(got) - len(exp))
        if bad and first is None:
            first = 'line %d %s' % (pos, tag)
        nmis += bad
    print('fixref: frames %d, values compared %d, mismatches %d%s' %
          (frames, nval, nmis, '' if first is None else ', first at ' + first))
    return 1 if nmis or not nval else 0


if __name__ == '__main__':
    sys.exit(main())
