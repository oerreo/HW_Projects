#!/usr/bin/env python3
"""Independent FIPS 203 check of polynomial vector files.

Usage: python3 -I check_fips203.py <vector_dir>

Implements FIPS 203 Algorithm 9 (NTT), 10 (NTT^-1), 11 (MultiplyNTTs) and
12 (BaseCaseMultiply) directly from the standard text with plain Python
integers. It shares no code with the pq-crystals ref implementation, with the
C++ golden model in model/, or with make_ext_vectors.py. The zeta values are
computed as 17^BitRev7(i) mod q here, not read from any table.

Checks, for every polynomial i in the files:
  ntt_out[i]     == NTT(ntt_in[i])
  intt_out[i]    == NTT^-1(intt_in[i])
  basemul_out[i] == MultiplyNTTs(basemul_a[i], basemul_b[i])
and that every line is a 3-digit hex value in [0, q).
Prints per-file comparison counts and mismatches, then PASS/FAIL.
"""
import os
import sys

Q = 3329
N = 256
ZETA = 17


def bitrev7(i):
    r = 0
    for b in range(7):
        r |= ((i >> b) & 1) << (6 - b)
    return r


ZETAS = [pow(ZETA, bitrev7(i), Q) for i in range(128)]
GAMMAS = [pow(ZETA, 2 * bitrev7(i) + 1, Q) for i in range(128)]
INV128 = pow(128, -1, Q)
assert INV128 == 3303
assert pow(ZETA, 128, Q) == Q - 1  # 17 is a primitive 256-th root of unity


def ntt(f):  # Algorithm 9
    f = list(f)
    i = 1
    length = 128
    while length >= 2:
        for start in range(0, 256, 2 * length):
            zeta = ZETAS[i]
            i += 1
            for j in range(start, start + length):
                t = (zeta * f[j + length]) % Q
                f[j + length] = (f[j] - t) % Q
                f[j] = (f[j] + t) % Q
        length //= 2
    return f


def ntt_inv(f):  # Algorithm 10
    f = list(f)
    i = 127
    length = 2
    while length <= 128:
        for start in range(0, 256, 2 * length):
            zeta = ZETAS[i]
            i -= 1
            for j in range(start, start + length):
                t = f[j]
                f[j] = (t + f[j + length]) % Q
                f[j + length] = (zeta * (f[j + length] - t)) % Q
        length *= 2
    return [(x * INV128) % Q for x in f]


def base_case_multiply(a0, a1, b0, b1, gamma):  # Algorithm 12
    c0 = (a0 * b0 + a1 * b1 * gamma) % Q
    c1 = (a0 * b1 + a1 * b0) % Q
    return c0, c1


def multiply_ntts(f, g):  # Algorithm 11
    h = [0] * N
    for i in range(128):
        h[2 * i], h[2 * i + 1] = base_case_multiply(f[2 * i], f[2 * i + 1],
                                                    g[2 * i], g[2 * i + 1], GAMMAS[i])
    return h


def read_polys(path):
    vals = []
    with open(path, "r", encoding="ascii") as fh:
        for ln, line in enumerate(fh, 1):
            s = line.strip()
            if len(s) != 3:
                raise ValueError("%s:%d: not a 3-digit hex value: %r" % (path, ln, s))
            v = int(s, 16)
            if v >= Q:
                raise ValueError("%s:%d: value %d >= q" % (path, ln, v))
            vals.append(v)
    if len(vals) % N:
        raise ValueError("%s: %d lines, not a multiple of 256" % (path, len(vals)))
    return [vals[k:k + N] for k in range(0, len(vals), N)]


def check(name, fn, ins, outs):
    n = len(outs)
    assert all(len(x) == n for x in ins), "%s: file length mismatch" % name
    bad_poly = bad_coef = 0
    first = None
    for i in range(n):
        exp = fn(*[x[i] for x in ins])
        diff = [k for k in range(N) if exp[k] != outs[i][k]]
        if diff:
            bad_poly += 1
            bad_coef += len(diff)
            if first is None:
                first = (i, diff[0], outs[i][diff[0]], exp[diff[0]])
    msg = "%-8s polynomials=%d coefficients=%d mismatch_polys=%d mismatch_coefs=%d" % (
        name, n, n * N, bad_poly, bad_coef)
    if first:
        msg += " first(poly=%d coef=%d file=%d fips=%d)" % first
    print(msg)
    return bad_poly


def self_test():
    # NTT^-1(NTT(f)) == f and NTT-domain product == negacyclic schoolbook product.
    import random
    rng = random.Random(203)
    for _ in range(20):
        f = [rng.randrange(Q) for _ in range(N)]
        g = [rng.randrange(Q) for _ in range(N)]
        assert ntt_inv(ntt(f)) == f
        h = [0] * N
        for a in range(N):
            for b in range(N):
                k = a + b
                if k < N:
                    h[k] += f[a] * g[b]
                else:
                    h[k - N] -= f[a] * g[b]
        h = [x % Q for x in h]
        assert ntt_inv(multiply_ntts(ntt(f), ntt(g))) == h
    print("self-test: inverse identity and schoolbook product, 20 random pairs OK")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    d = sys.argv[1]
    self_test()
    p = lambda n: read_polys(os.path.join(d, n))
    fails = 0
    fails += check("ntt", ntt, [p("ntt_in.hex")], p("ntt_out.hex"))
    fails += check("intt", ntt_inv, [p("intt_in.hex")], p("intt_out.hex"))
    fails += check("basemul", multiply_ntts, [p("basemul_a.hex"), p("basemul_b.hex")],
                   p("basemul_out.hex"))
    print("OVERALL %s" % ("PASS" if fails == 0 else "FAIL"))
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
