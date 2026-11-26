"""Verify every model/code/qc_*.txt (docs/spec/code.md 4).  Standard library only, no arguments.

Run from the project root:  python3 -I model/tools/chk.py
Checks, per table:
  1. base-level 4-/6-cycle counts (zero alternating shift sum) -> lifted counts x Z
  2. girth of the expanded Tanner graph: BFS from variable node 0 of every block column
     (the cyclic automorphism maps every variable node to one of these), exact minimum
  3. lifted 6-cycle count by direct path enumeration in the expanded graph (cross-check of 1)
  4. row / column weight distribution of the expanded H
  5. GF(2) rank of the expanded H -> k = n - rank, design rate
  6. encoding: structured (dual-diagonal back substitution) encoder on NENC random messages
     (seeded), H c = 0 checked on the expanded edge list, independent of the encoder;
     negative control: one random bit flipped per codeword must give a nonzero syndrome
  7. layers: one layer = one base row; every variable node is touched at most once per layer;
     shared block columns of consecutive layers (pipeline hazard input for docs/spec/s1calc.py)
"""
import glob
import hashlib
import os
import random
import sys
from collections import Counter, deque

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qclib  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
NENC = 1000
ENC_SEED = 2026


def expand(mb, nb, Z, S):
    """check node (r, i) -> index r*Z + i; variable (c, t) -> c*Z + t, t = (i + s) mod Z."""
    chk = [[] for _ in range(mb * Z)]
    var = [[] for _ in range(nb * Z)]
    for r in range(mb):
        for c in range(nb):
            s = S[r][c]
            if s < 0:
                continue
            for i in range(Z):
                v = c * Z + (i + s) % Z
                chk[r * Z + i].append(v)
                var[v].append(r * Z + i)
    return chk, var


def girth(nb, Z, chk, var):
    """Bipartite graph, node ids: variable v -> v, check u -> NV + u."""
    NV = len(var)
    g = None
    for c in range(nb):
        src = c * Z
        dist = {src: 0}
        par = {src: -1}
        q = deque([src])
        best = None
        while q:
            x = q.popleft()
            if best is not None and 2 * dist[x] + 1 >= best:
                break
            nbr = [NV + u for u in var[x]] if x < NV else chk[x - NV]
            for y in nbr:
                if y == par[x]:
                    continue
                if y in dist:
                    L = dist[x] + dist[y] + 1
                    if best is None or L < best:
                        best = L
                else:
                    dist[y] = dist[x] + 1
                    par[y] = x
                    q.append(y)
        if best is not None and (g is None or best < g):
            g = best
    return g


def lifted6(nb, Z, chk, var):
    """Count 6-cycles through variable node 0 of each block column; total = sum * Z / (2 * 3)."""
    tot = 0
    for c in range(nb):
        v0 = c * Z
        cnt = 0
        for u1 in var[v0]:
            for v1 in chk[u1]:
                if v1 == v0:
                    continue
                for u2 in var[v1]:
                    if u2 == u1:
                        continue
                    for v2 in chk[u2]:
                        if v2 == v1 or v2 == v0:
                            continue
                        for u3 in var[v2]:
                            if u3 == u2 or u3 == u1:
                                continue
                            if v0 in chk[u3]:
                                cnt += 1
        tot += cnt
    assert (tot * Z) % 6 == 0
    return tot * Z // 6


def rank_gf2(mb, nb, Z, chk):
    piv = {}
    for row in chk:
        x = 0
        for v in row:
            x ^= 1 << v
        while x:
            h = x.bit_length() - 1
            p = piv.get(h)
            if p is None:
                piv[h] = x
                break
            x ^= p
    return len(piv)


def encode(mb, nb, Z, S, u):
    """u: list of nb-mb Z-bit blocks -> list of nb blocks (systematic)."""
    ninfo = nb - mb
    p0c = ninfo
    # structure assertions (the encoder relies on them)
    col0 = [(r, S[r][p0c]) for r in range(mb) if S[r][p0c] >= 0]
    assert len(col0) == 3 and col0[0][0] == 0 and col0[2][0] == mb - 1, 'p0 rows'
    assert col0[0][1] == col0[2][1] and col0[1][1] == 0, 'p0 shifts (a, 0, a)'
    j = col0[1][0]
    for k in range(1, mb):
        for r in range(mb):
            want = 0 if r in (k - 1, k) else -1
            assert S[r][p0c + k] == want, 'dual diagonal'
    lam = []
    for r in range(mb):
        x = 0
        for c in range(ninfo):
            if S[r][c] >= 0:
                x ^= qclib.rot(u[c], S[r][c], Z)
        lam.append(x)
    p = [0] * mb
    for x in lam:
        p[0] ^= x
    a = S[0][p0c]
    p[1] = lam[0] ^ qclib.rot(p[0], a, Z)
    for r in range(1, mb - 1):
        p[r + 1] = lam[r] ^ p[r] ^ (p[0] if r == j else 0)
    return list(u) + p


def enc_test(mb, nb, Z, S, chk):
    rng = random.Random(ENC_SEED)
    n = nb * Z
    ninfo = nb - mb
    var = [0] * n  # bit t of var[v] = bit v of codeword t
    flip = [0] * n
    for t in range(NENC):
        u = [rng.getrandbits(Z) for _ in range(ninfo)]
        cw = encode(mb, nb, Z, S, u)
        bt = 1 << t
        for c, x in enumerate(cw):
            base = c * Z
            while x:
                low = x & -x
                var[base + low.bit_length() - 1] |= bt
                x ^= low
        flip[rng.randrange(n)] |= bt
    fail = 0
    detect = 0
    for row in chk:
        s = 0
        sf = 0
        for v in row:
            s ^= var[v]
            sf ^= var[v] ^ flip[v]
        fail |= s
        detect |= sf
    return NENC - bin(fail).count('1'), bin(detect).count('1')


def main():
    paths = sorted(glob.glob(os.path.join(ROOT, 'model', 'code', 'qc_*.txt')))
    allok = True
    for path in paths:
        mb, nb, Z, S, meta = qclib.read_table(path)
        n = nb * Z
        print('== %s (mb %d, nb %d, Z %d, n %d, seed %s, sha256 %s)' %
              (os.path.relpath(path, ROOT), mb, nb, Z, n, meta.get('seed'),
               hashlib.sha256(open(path, 'rb').read()).hexdigest()[:16]))
        n4, n6 = qclib.base_cycles(mb, nb, Z, S)
        print('  base cycles with zero shift sum: 4-cycles %d, 6-cycles %d -> lifted 4-cycles %d, 6-cycles %d'
              % (n4, n6, n4 * Z, n6 * Z))
        chk, var = expand(mb, nb, Z, S)
        g = girth(nb, Z, chk, var)
        print('  girth (BFS, expanded graph): %s' % g)
        l6 = lifted6(nb, Z, chk, var)
        print('  lifted 6-cycles by path enumeration: %d (%s base x Z)' % (l6, 'matches' if l6 == n6 * Z else 'DIFFERS FROM'))
        bw_r = Counter(sum(1 for s in S[r] if s >= 0) for r in range(mb))
        bw_c = Counter(sum(1 for r in range(mb) if S[r][c] >= 0) for c in range(nb))
        ew_r = Counter(len(x) for x in chk)
        ew_c = Counter(len(x) for x in var)
        print('  base row weight {weight: rows} %s, base column weight {weight: cols} %s' %
              (dict(sorted(bw_r.items())), dict(sorted(bw_c.items()))))
        print('  expanded H: %d x %d, row weight {w: count} %s, column weight {w: count} %s, edges %d' %
              (mb * Z, n, dict(sorted(ew_r.items())), dict(sorted(ew_c.items())), sum(len(x) for x in chk)))
        rk = rank_gf2(mb, nb, Z, chk)
        k = n - rk
        print('  GF(2) rank %d of %d rows -> k = %d, rate %.6f (design %d/%d = %.6f)' %
              (rk, mb * Z, k, k / n, (nb - mb), nb, (nb - mb) / nb))
        ok, det = enc_test(mb, nb, Z, S, chk)
        print('  encoding: %d / %d random messages (seed %d) give H c = 0; single-bit-flip control detected %d / %d'
              % (ok, NENC, ENC_SEED, det, NENC))
        lay_ok = True
        for r in range(mb):
            cnt = Counter(v for i in range(Z) for v in chk[r * Z + i])
            if max(cnt.values()) > 1:
                lay_ok = False
        print('  layers: %d layers of %d checks, every variable node at most once per layer: %s' %
              (mb, Z, 'yes' if lay_ok else 'NO'))
        cols = [set(c for c in range(nb) if S[r][c] >= 0) for r in range(mb)]
        sh = [len(cols[r] & cols[(r + 1) % mb]) for r in range(mb)]
        print('  shared block columns of consecutive layers (r, r+1 mod mb): %s' % sh)
        print('  shared block columns, all layer pairs: min %d max %d' %
              (min(len(cols[a] & cols[b]) for a in range(mb) for b in range(a + 1, mb)),
               max(len(cols[a] & cols[b]) for a in range(mb) for b in range(a + 1, mb))))
        good = (n4 == 0 and l6 == n6 * Z and rk == mb * Z and ok == NENC and det == NENC and lay_ok)
        allok &= good
        print('  RESULT: %s' % ('PASS' if good else 'FAIL'))
    print('ALL: %s (%d tables)' % ('PASS' if allok and paths else 'FAIL', len(paths)))


if __name__ == '__main__':
    main()
