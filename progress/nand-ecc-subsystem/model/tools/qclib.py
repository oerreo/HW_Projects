"""QC-LDPC base matrix helpers shared by gen.py and chk.py (standard library only).

Shift convention (docs/spec/code.md 2.1):
  entry s >= 0 of the base matrix is the Z x Z circulant P^s whose row i has its single 1 at
  column (i + s) mod Z.  Applied to a block x (bit i = x[i]): (P^s x)[i] = x[(i + s) mod Z],
  i.e. a cyclic rotation of the Z-bit block toward index 0 by s.  -1 = all-zero block.
Columns 0 .. nb-mb-1 are information blocks, nb-mb .. nb-1 parity blocks p0 .. p_{mb-1}.
"""


def read_table(path):
    """Return (mb, nb, Z, S, meta) with S[r][c] in {-1, 0..Z-1}."""
    meta = {}
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith('#'):
                if '=' in line:
                    k, v = line[1:].split('=', 1)
                    meta[k.strip()] = v.strip()
                continue
            rows.append([int(t) for t in line.split()])
    mb, nb, Z = rows[0]
    S = rows[1:]
    assert len(S) == mb and all(len(r) == nb for r in S), 'bad table shape'
    assert all(-1 <= s < Z for r in S for s in r), 'shift out of range'
    return mb, nb, Z, S, meta


def write_table(path, mb, nb, Z, S, meta, comments):
    with open(path, 'w') as f:
        for c in comments:
            f.write('# ' + c + '\n')
        for k, v in meta.items():
            f.write('# %s = %s\n' % (k, v))
        f.write('%d %d %d\n' % (mb, nb, Z))
        w = len(str(Z - 1)) + 1
        for r in range(mb):
            f.write(' '.join(('%d' % s).rjust(w) for s in S[r]) + '\n')


def rot(x, s, Z):
    """(P^s x) for a Z-bit block x."""
    if s == 0:
        return x
    m = (1 << Z) - 1
    return ((x >> s) | (x << (Z - s))) & m


def base_cycles(mb, nb, Z, S):
    """Count base-graph cycles of length 4 and 6 whose alternating shift sum is 0 mod Z.
    Each such base cycle lifts to Z cycles of the same length in the expanded graph.
    Returns (n4, n6) counted once per cycle."""
    E = [(r, c) for r in range(mb) for c in range(nb) if S[r][c] >= 0]
    rows_of = [[r for r in range(mb) if S[r][c] >= 0] for c in range(nb)]
    cols_of = [[c for c in range(nb) if S[r][c] >= 0] for r in range(mb)]
    colset = [set(x) for x in cols_of]
    n4 = n6 = 0
    for (r, c) in E:
        s0 = S[r][c]
        for r2 in rows_of[c]:
            if r2 == r:
                continue
            a = s0 - S[r2][c]
            for c2 in cols_of[r2]:
                if c2 == c:
                    continue
                b = a + S[r2][c2]
                if c2 in colset[r] and (b - S[r][c2]) % Z == 0:
                    n4 += 1
                for r3 in rows_of[c2]:
                    if r3 == r or r3 == r2:
                        continue
                    d = b - S[r3][c2]
                    for c3 in colset[r] & colset[r3]:
                        if c3 == c or c3 == c2:
                            continue
                        if (d + S[r3][c3] - S[r][c3]) % Z == 0:
                            n6 += 1
    # each 4-cycle is found once per edge (4 edges); each 6-cycle once per edge (6 edges)
    assert n4 % 4 == 0 and n6 % 6 == 0
    return n4 // 4, n6 // 6
