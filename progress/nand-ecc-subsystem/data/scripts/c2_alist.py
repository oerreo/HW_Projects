"""Build the CCSDS C2 (8176, 7156) parity-check matrix as an alist file from CCSDS 131.1-O-2 Table 2-1.

Run from the project directory (standard library only, no arguments; pdftotext must exist):
    python3 -I data/scripts/c2_alist.py
Input : data/third_party/docs/ccsds_131x1o2e2s.pdf (data/scripts/fetch.sh)
Output: data/third_party/alist/ccsds_c2_7156_8176.alist (git-ignored, regenerated on demand)

Table 2-1 gives, for each of the 2 x 16 circulants A_{i,j} (511 x 511, row weight 2), the two
positions of the 1s in its first row and the absolute positions in the first row of H. Section 2.1:
every row of a circulant is the previous row cyclically shifted right by one, so row t of A_{i,j}
has its 1s at columns (p + t) mod 511. The script checks the relative and absolute columns against
each other, then the row/column weights (32 and 4).
"""
import os
import re
import subprocess
import sys

PDF = 'data/third_party/docs/ccsds_131x1o2e2s.pdf'
OUT = 'data/third_party/alist/ccsds_c2_7156_8176.alist'
Z = 511


def main():
    txt = subprocess.run(['pdftotext', '-layout', PDF, '-'], check=True, capture_output=True).stdout.decode()
    pat = re.compile(r'A([12]),(\d+)\s+(\d+),\s*(\d+)\s+(\d+),\s*(\d+)')
    circ = {}
    for m in pat.finditer(txt):
        i, j, p1, p2, a1, a2 = (int(x) for x in m.groups())
        if (i, j) in circ:
            continue
        assert 1 <= j <= 16
        assert a1 == (j - 1) * Z + p1 and a2 == (j - 1) * Z + p2, 'relative/absolute mismatch at A%d,%d' % (i, j)
        circ[(i, j)] = (p1, p2)
    assert len(circ) == 32, 'found %d circulants' % len(circ)
    n, m = 16 * Z, 2 * Z
    rows = [[] for _ in range(m)]
    for (i, j), ps in sorted(circ.items()):
        for t in range(Z):
            for p in ps:
                rows[(i - 1) * Z + t].append((j - 1) * Z + (p + t) % Z)
    for r in rows:
        r.sort()
        assert len(set(r)) == len(r)
    cols = [[] for _ in range(n)]
    for r, vs in enumerate(rows):
        for v in vs:
            cols[v].append(r)
    dc = {len(r) for r in rows}
    dv = {len(c) for c in cols}
    assert dc == {32} and dv == {4}, (dc, dv)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, 'w') as f:
        f.write('%d %d\n%d %d\n' % (n, m, 4, 32))
        f.write(' '.join('4' for _ in range(n)) + '\n')
        f.write(' '.join('32' for _ in range(m)) + '\n')
        for c in cols:
            f.write(' '.join(str(r + 1) for r in c) + '\n')
        for r in rows:
            f.write(' '.join(str(v + 1) for v in r) + '\n')
    print('wrote %s: n %d m %d, row weight 32, column weight 4, first row %s' % (OUT, n, m, rows[0][:4]))


if __name__ == '__main__':
    sys.exit(main())
