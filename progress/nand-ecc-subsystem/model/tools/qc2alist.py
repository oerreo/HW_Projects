"""Export the QC tables model/code/qc_*.txt as alist files for the AFF3CT cross-check.

Run from the project directory, no arguments:  python3 -I model/tools/qc2alist.py
Output: model/build/alist/qc_<name>.alist (build directory, not committed). Check (r, i) = r*Z + i,
variable c*Z + (i + s) mod Z (docs/spec/code.md 2.1), same edge order as model/src/code.c.
"""
import glob
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qclib  # noqa: E402

OUT = 'model/build/alist'


def main():
    os.makedirs(OUT, exist_ok=True)
    for path in sorted(glob.glob('model/code/qc_*.txt')):
        mb, nb, Z, S, meta = qclib.read_table(path)
        n, m = nb * Z, mb * Z
        rows = [[] for _ in range(m)]
        for r in range(mb):
            for i in range(Z):
                for c in range(nb):
                    s = S[r][c]
                    if s >= 0:
                        rows[r * Z + i].append(c * Z + (i + s) % Z)
        cols = [[] for _ in range(n)]
        for r, vs in enumerate(rows):
            for v in vs:
                cols[v].append(r)
        dvm = max(len(c) for c in cols)
        dcm = max(len(r) for r in rows)
        name = os.path.basename(path)[:-4]
        out = os.path.join(OUT, name + '.alist')
        with open(out, 'w') as f:
            f.write('%d %d\n%d %d\n' % (n, m, dvm, dcm))
            f.write(' '.join(str(len(c)) for c in cols) + '\n')
            f.write(' '.join(str(len(r)) for r in rows) + '\n')
            for c in cols:
                f.write(' '.join([str(r + 1) for r in c] + ['0'] * (dvm - len(c))) + '\n')
            for r in rows:
                f.write(' '.join([str(v + 1) for v in r] + ['0'] * (dcm - len(r))) + '\n')
        print('wrote %s n %d m %d' % (out, n, m))


if __name__ == '__main__':
    sys.exit(main())
