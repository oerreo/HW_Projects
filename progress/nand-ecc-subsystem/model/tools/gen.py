"""Construct the QC-LDPC shift tables (docs/spec/code.md).  Standard library only, no arguments.

Run from the project root:  python3 -I model/tools/gen.py
Writes model/code/qc_<name>.txt for every variant in VARIANTS and prints a log.

Structure (all variants):
  * mb x nb base matrix, weight-1 circulants of size Z.
  * information columns 0 .. nb-mb-1: column weight wc.  Row patterns (which wc rows) are
    chosen greedily to balance row weight and row-pair co-occurrence (seeded tie break).
  * parity columns: p0 = weight-3 column with shifts (a, 0, a) at rows (0, j, mb-1),
    p1 .. p_{mb-1} = dual diagonal of identities (802.11n-style), so the encoder is
    linear-time back substitution and the parity part is invertible.
Shift selection (information entries only):
  1. greedy, column by column: every candidate shift that would close a 4-cycle is forbidden;
     among the rest take the one closing the fewest 6-cycles (ties: seeded random).
  2. local improvement sweeps: remove one entry, re-pick it given all others, accept only a
     strict decrease of the 6-cycle count; repeat until a sweep changes nothing (or MAXSWEEP).
  Each seed in `seeds` is tried; the table with the fewest 6-cycles is kept (first seed on ties).
"""
import itertools
import os
import random
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qclib  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
OUT = os.path.join(ROOT, 'model', 'code')
MAXSWEEP = 30

# name, mb, nb, Z, wc, p0 shift a, p0 middle row j, seeds
VARIANTS = [
    ('m128', 8, 72, 128, 4, 1, 4, list(range(1, 33))),  # main code: n 9216, k 8192
    ('s32', 8, 72, 32, 4, 1, 4, list(range(1, 9))),     # same base shape, Z 32: n 1152, k 1024
    ('s16', 8, 72, 16, 4, 1, 4, list(range(1, 5))),     # same base shape, Z 16: infeasible (pigeonhole, code.md)
    ('t8', 4, 12, 8, 3, 1, 2, list(range(1, 9))),       # tiny: n 96, k 64
]


def row_patterns(mb, ninfo, wc, rng):
    subsets = list(itertools.combinations(range(mb), wc))
    rowc = [0] * mb
    pairc = {p: 0 for p in itertools.combinations(range(mb), 2)}
    used = {s: 0 for s in subsets}
    pats = []
    for _ in range(ninfo):
        best, cand = None, []
        for s in subsets:
            cost = (used[s] * 10 ** 6 + sum(rowc[r] for r in s) * 10 ** 3
                    + sum(pairc[p] for p in itertools.combinations(s, 2)))
            if best is None or cost < best:
                best, cand = cost, [s]
            elif cost == best:
                cand.append(s)
        s = rng.choice(cand)
        pats.append(s)
        used[s] += 1
        for r in s:
            rowc[r] += 1
        for p in itertools.combinations(s, 2):
            pairc[p] += 1
    return pats, rowc, pairc


class Builder:
    def __init__(self, mb, nb, Z):
        self.mb, self.nb, self.Z = mb, nb, Z
        self.S = [[-1] * nb for _ in range(mb)]
        self.rows_of = [set() for _ in range(nb)]
        self.cols_of = [set() for _ in range(mb)]

    def place(self, r, c, s):
        self.S[r][c] = s
        self.rows_of[c].add(r)
        self.cols_of[r].add(c)

    def remove(self, r, c):
        self.S[r][c] = -1
        self.rows_of[c].discard(r)
        self.cols_of[r].discard(c)

    def score(self, r, c):
        """For an unplaced entry (r, c): (forbidden set, 6-cycle histogram over shift values)."""
        S, Z = self.S, self.Z
        forb = set()
        h6 = [0] * Z
        for r2 in self.rows_of[c]:
            a = S[r2][c]
            for c2 in self.cols_of[r2]:
                if c2 == c:
                    continue
                b = a - S[r2][c2]
                if c2 in self.cols_of[r]:
                    forb.add((b + S[r][c2]) % Z)
                for r3 in self.rows_of[c2]:
                    if r3 == r or r3 == r2:
                        continue
                    d = b + S[r3][c2]
                    for c3 in self.cols_of[r] & self.cols_of[r3]:
                        if c3 == c or c3 == c2:
                            continue
                        h6[(d - S[r3][c3] + S[r][c3]) % Z] += 1
        return forb, h6


def build(mb, nb, Z, wc, a, j, seed):
    rng = random.Random(seed)
    ninfo = nb - mb
    pats, rowc, pairc = row_patterns(mb, ninfo, wc, rng)
    B = Builder(mb, nb, Z)
    p0 = ninfo
    B.place(0, p0, a)
    B.place(j, p0, 0)
    B.place(mb - 1, p0, a)
    for k in range(1, mb):
        B.place(k - 1, p0 + k, 0)
        B.place(k, p0 + k, 0)
    for c in range(ninfo):
        for r in pats[c]:
            forb, h6 = B.score(r, c)
            ok = [s for s in range(Z) if s not in forb]
            if not ok:
                return None, 'no 4-cycle-free shift at (%d,%d)' % (r, c)
            m = min(h6[s] for s in ok)
            B.place(r, c, rng.choice([s for s in ok if h6[s] == m]))
    greedy6 = qclib.base_cycles(mb, nb, Z, B.S)[1]
    sweeps = 0
    entries = [(r, c) for c in range(ninfo) for r in pats[c]]
    for sweeps in range(1, MAXSWEEP + 1):
        changed = 0
        order = entries[:]
        rng.shuffle(order)
        for (r, c) in order:
            cur = B.S[r][c]
            B.remove(r, c)
            forb, h6 = B.score(r, c)
            ok = [s for s in range(Z) if s not in forb]
            m = min(h6[s] for s in ok)
            if h6[cur] > m:
                B.place(r, c, rng.choice([s for s in ok if h6[s] == m]))
                changed += 1
            else:
                B.place(r, c, cur)
        if changed == 0:
            break
    return B.S, dict(greedy6=greedy6, sweeps=sweeps, rowc=rowc,
                     pairc=(min(pairc.values()), max(pairc.values())))


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, mb, nb, Z, wc, a, j, seeds in VARIANTS:
        print('== variant %s: mb %d nb %d Z %d wc %d p0 (a %d, j %d) n %d k %d' %
              (name, mb, nb, Z, wc, a, j, nb * Z, (nb - mb) * Z))
        best = None
        for sd in seeds:
            t0 = time.time()
            S, info = build(mb, nb, Z, wc, a, j, sd)
            if S is None:
                print('  seed %d: FAIL %s' % (sd, info))
                continue
            n4, n6 = qclib.base_cycles(mb, nb, Z, S)
            if sd == seeds[0]:
                # structural cycle counts of the base graph (every shift sum is 0 mod 1)
                s4, s6 = qclib.base_cycles(mb, nb, 1, [[0 if x >= 0 else -1 for x in row] for row in S])
                ov = max(sum(1 for c in range(nb) if S[a][c] >= 0 and S[b][c] >= 0)
                         for a in range(mb) for b in range(a + 1, mb))
                print('  structural base cycles: 4-cycles %d, 6-cycles %d (6-cycles / Z = %.1f); '
                      'max block columns shared by two rows %d' % (s4, s6, s6 / Z, ov))
            print('  seed %d: base 4-cycles %d, base 6-cycles greedy %d -> final %d (sweeps %d), '
                  'info row weights %s, row-pair co-occurrence %s..%s, %.1f s' %
                  (sd, n4, info['greedy6'], n6, info['sweeps'], sorted(set(info['rowc'])),
                   info['pairc'][0], info['pairc'][1], time.time() - t0))
            if n4 == 0 and (best is None or n6 < best[1]):
                best = (sd, n6, S)
        if best is None:
            print('  RESULT %s: no 4-cycle-free table found' % name)
            continue
        sd, n6, S = best
        path = os.path.join(OUT, 'qc_%s.txt' % name)
        qclib.write_table(
            path, mb, nb, Z, S,
            dict(name=name, generator='model/tools/gen.py', seed=sd, seeds_tried=','.join(map(str, seeds)),
                 wc=wc, p0_a=a, p0_j=j, base_6cycles=n6),
            ['QC-LDPC shift table (docs/spec/code.md).',
             'line 1: mb nb Z; then mb rows of nb shifts. -1 = zero block; s >= 0 = Z x Z identity',
             'cyclically shifted: row i has its 1 at column (i + s) mod Z.',
             'columns 0..nb-mb-1 information, nb-mb = p0 (shifts a,0,a at rows 0,j,mb-1), then dual diagonal.'])
        print('  RESULT %s: seed %d, base 6-cycles %d (lifted %d) -> %s' %
              (name, sd, n6, n6 * Z, os.path.relpath(path, ROOT)))


if __name__ == '__main__':
    main()
