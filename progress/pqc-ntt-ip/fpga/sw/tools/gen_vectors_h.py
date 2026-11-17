#!/usr/bin/env python3
"""Generate fpga/sw/vectors.h (C arrays) for the PS test program.

Three kinds of vectors per operation (project-flow.md "Test data"):
  ext  external vectors, a subset of data/vectors/ext (ACVP-derived,
       expected values from the files, independent of model/)
  dir  directed cases of the golden model generator: all_zero, all_qm1,
       impulse_1_at_0, impulse_1_at_255, impulse_qm1_at_128, all_one
  rnd  full-range random cases of the golden model generator (seeded)

Golden-model cases are read from a vector directory written by
`make vectors` of model/ (model/ itself is not modified; use
`make -C fpga/sw/test vectors-h`, which writes that directory under
fpga/sw/build/ and then runs this script).

Operations: NTT, INTT, BASEMUL (MultiplyNTTs) and POLYMUL (f * g mod
X^256 + 1, schoolbook-checked by the generator; ext data has no polymul).

The vectors do not depend on ALGO (IP contract: every ALGO is bit-exact with
FIPS 203). Expected cycle counts are not stored; the test program computes
them from the VERSION register.

Only standard library. Paths written into the header are relative to the
project root.
"""

import argparse
import csv
import hashlib
import os
import sys

Q = 3329
N = 256
DIRECTED = ["all_zero", "all_qm1", "impulse_1_at_0", "impulse_1_at_255",
            "impulse_qm1_at_128", "all_one"]

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJ_ROOT = os.path.normpath(os.path.join(SCRIPT_DIR, "..", "..", ".."))


def rel(path):
    """Project-relative path for messages and the header comment."""
    return os.path.relpath(os.path.abspath(path), PROJ_ROOT)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def read_hex(path):
    vals = []
    with open(path) as f:
        for ln, line in enumerate(f, 1):
            s = line.strip()
            if not s:
                continue
            v = int(s, 16)
            if not 0 <= v < Q:
                sys.exit("%s:%d: value %d outside [0, q)" % (rel(path), ln, v))
            vals.append(v)
    if len(vals) % N:
        sys.exit("%s: %d values, not a multiple of %d" % (rel(path), len(vals), N))
    return [vals[i:i + N] for i in range(0, len(vals), N)]


def spread(items, n):
    """n items evenly spaced over the list (deterministic)."""
    if n <= 0 or not items:
        return []
    n = min(n, len(items))
    return [items[(k * len(items)) // n] for k in range(n)]


def read_ext_manifest(ext_dir):
    rows = {}
    with open(os.path.join(ext_dir, "manifest.csv")) as f:
        for r in csv.DictReader(f):
            rows.setdefault(r["op"], []).append(r)
    for op in rows:
        rows[op].sort(key=lambda r: int(r["index"]))
    return rows


def ext_name(op, r):
    ps = r["param_set"].replace("ML-KEM-", "mlkem")
    return "ext_%s_%s_%s_%s_tc%s" % (op, r["index"], ps, r["acvp_function"], r["tcId"])


def select_ext(rows, op, n):
    if op == "ntt":
        # 765 of 855 NTT inputs are CBD noise (|x| <= 3); take half of the
        # subset from the full-range inputs (decapsulation u').
        full = [r for r in rows if int(r["raw_in_min"]) < -3 or int(r["raw_in_max"]) > 3]
        small = [r for r in rows if r not in full]
        nf = min(len(full), n // 2)
        return sorted(spread(full, nf) + spread(small, n - nf), key=lambda r: int(r["index"]))
    return spread(rows, n)


def read_model_manifest(vec_dir):
    info = {"cases": {}}
    with open(os.path.join(vec_dir, "manifest.txt")) as f:
        for line in f:
            p = line.split()
            if len(p) >= 3 and p[0] == "case":
                info["cases"][int(p[1])] = p[2]
            elif len(p) >= 2 and p[0] in ("seed", "count"):
                info[p[0]] = int(p[1])
    for i, name in enumerate(DIRECTED):
        if info["cases"].get(i) != name:
            sys.exit("%s: case %d is %r, expected %r" %
                     (rel(vec_dir), i, info["cases"].get(i), name))
    return info


def c_array(name, coeffs):
    lines = []
    for i in range(0, N, 16):
        lines.append("  " + ", ".join("0x%03x" % v for v in coeffs[i:i + 16]))
    return "static const uint16_t %s[%d] = {\n%s\n};\n" % (name, N, ",\n".join(lines))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--ext-dir", default=os.path.join(PROJ_ROOT, "data", "vectors", "ext"))
    ap.add_argument("--model-vec-dir",
                    default=os.path.join(PROJ_ROOT, "fpga", "sw", "build", "model_vec"),
                    help="output directory of model/ `make vectors`")
    ap.add_argument("--n-ext", type=int, default=16, help="external vectors per op (default 16)")
    ap.add_argument("--n-random", type=int, default=8,
                    help="golden random vectors per op (default 8)")
    ap.add_argument("--n-polymul-random", type=int, default=4,
                    help="golden random polynomial products (default 4)")
    ap.add_argument("--no-directed", action="store_true", help="omit the 6 directed cases")
    ap.add_argument("--out", default=os.path.join(PROJ_ROOT, "fpga", "sw", "vectors.h"))
    a = ap.parse_args()

    minfo = read_model_manifest(a.model_vec_dir)
    nrnd_avail = minfo.get("count", 0)
    if a.n_random > nrnd_avail or a.n_polymul_random > nrnd_avail:
        sys.exit("model vectors have %d random cases, need %d" %
                 (nrnd_avail, max(a.n_random, a.n_polymul_random)))
    ext_rows = read_ext_manifest(a.ext_dir)

    def ext_file(name):
        return os.path.join(a.ext_dir, name)

    def mod_file(name):
        return os.path.join(a.model_vec_dir, name)

    # op -> (ext files (a, b, out), model files (a, b, out), ext manifest op)
    spec = [
        ("ntt", ("ntt_in.hex", None, "ntt_out.hex"), ("ntt_in.hex", None, "ntt_out.hex")),
        ("intt", ("intt_in.hex", None, "intt_out.hex"), ("intt_in.hex", None, "intt_out.hex")),
        ("basemul", ("basemul_a.hex", "basemul_b.hex", "basemul_out.hex"),
         ("mul_a.hex", "mul_b.hex", "mul_out.hex")),
        ("polymul", None, ("polymul_f.hex", "polymul_g.hex", "polymul_h.hex")),
    ]

    used_files = []
    cache = {}

    def load(path):
        if path not in cache:
            cache[path] = read_hex(path)
            used_files.append(path)
        return cache[path]

    ops = []
    for op, ext_f, mod_f in spec:
        cases = []  # (name, a, b, out)
        if ext_f is not None and a.n_ext > 0:
            fa, fb, fo = (load(ext_file(x)) if x else None for x in ext_f)
            for r in select_ext(ext_rows[op], op, a.n_ext):
                i = int(r["index"])
                cases.append((ext_name(op, r), fa[i], fb[i] if fb else None, fo[i]))
        ma, mb, mo = (load(mod_file(x)) if x else None for x in mod_f)
        if not a.no_directed:
            for i, name in enumerate(DIRECTED):
                cases.append(("dir_%s" % name, ma[i], mb[i] if mb else None, mo[i]))
        nr = a.n_polymul_random if op == "polymul" else a.n_random
        for k in range(nr):
            i = len(DIRECTED) + k
            cases.append(("rnd_s%d_%s" % (minfo["seed"], minfo["cases"][i].replace("random_", "")),
                          ma[i], mb[i] if mb else None, mo[i]))
        ops.append((op, cases))

    out = []
    out.append("/* vectors.h: generated by fpga/sw/tools/gen_vectors_h.py. Do not edit.\n")
    out.append(" *\n * Regenerate: make -C fpga/sw/test vectors-h\n")
    out.append(" * Arguments: --n-ext %d --n-random %d --n-polymul-random %d%s\n" %
               (a.n_ext, a.n_random, a.n_polymul_random, " --no-directed" if a.no_directed else ""))
    out.append(" * Golden model vectors: seed %d, count %d (model/ `make vectors`)\n" %
               (minfo["seed"], minfo["count"]))
    out.append(" * Expected values: ext_* from data/vectors/ext (ACVP-derived, FIPS 203),\n")
    out.append(" *   dir_* / rnd_* from the golden model generator. Independent of ALGO.\n")
    out.append(" * Source files (sha256):\n")
    for p in used_files:
        out.append(" *   %s  %s\n" % (sha256(p), rel(p)))
    out.append(" */\n#ifndef PQC_VECTORS_H\n#define PQC_VECTORS_H\n\n#include <stdint.h>\n#include <stddef.h>\n\n")
    out.append("typedef struct {\n  const char *name;\n  const uint16_t *a;   /* input (f for POLYMUL) */\n"
               "  const uint16_t *b;   /* second input (BASEMUL, POLYMUL), else NULL */\n"
               "  const uint16_t *out; /* expected output */\n} pqc_vec_t;\n\n")
    total = 0
    for op, cases in ops:
        for k, (name, va, vb, vo) in enumerate(cases):
            out.append(c_array("vec_%s_%d_a" % (op, k), va))
            if vb is not None:
                out.append(c_array("vec_%s_%d_b" % (op, k), vb))
            out.append(c_array("vec_%s_%d_out" % (op, k), vo))
            total += 1
        out.append("\n#define VEC_%s_COUNT %d\n" % (op.upper(), len(cases)))
        out.append("static const pqc_vec_t vec_%s[VEC_%s_COUNT] = {\n" % (op, op.upper()))
        for k, (name, va, vb, vo) in enumerate(cases):
            bname = "vec_%s_%d_b" % (op, k) if vb is not None else "NULL"
            out.append("  {\"%s\", vec_%s_%d_a, %s, vec_%s_%d_out},\n" % (name, op, k, bname, op, k))
        out.append("};\n\n")
    out.append("#endif /* PQC_VECTORS_H */\n")
    text = "".join(out)
    with open(a.out, "w") as f:
        f.write(text)
    print("wrote %s: %s, %d cases, %d bytes" %
          (rel(a.out), ", ".join("%s %d" % (op, len(c)) for op, c in ops), total, len(text)))


if __name__ == "__main__":
    main()
