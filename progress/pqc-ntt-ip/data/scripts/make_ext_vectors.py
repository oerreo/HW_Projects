#!/usr/bin/env python3
"""Convert raw pq-crystals ref dumps into canonical FIPS 203 polynomial vectors.

Usage: python3 -I make_ext_vectors.py <build_dir> <out_dir>

Reads <build_dir>/raw_dump_{512,768,1024}.txt (written by acvp_harness) and
<build_dir>/acvp_result_{512,768,1024}.log (only polynomials from PASSing ACVP
cases are kept). Writes into <out_dir>:
  ntt_in.hex ntt_out.hex intt_in.hex intt_out.hex
  basemul_a.hex basemul_b.hex basemul_out.hex
  manifest.csv   one row per polynomial (op, index, provenance, raw range)
  manifest.json  per-file counts and per-parameter-set breakdown

Representation conversion (q = 3329, R = 2^16, see data/README.md):
  ntt      : in_c = in mod q              out_c = out mod q
  invntt   : in_c = in mod q              out_c = out * R^-1 mod q   (R^-1 = 169)
  basemul  : a_c = a mod q, b_c = b mod q out_c = out * R mod q      (R mod q = 2285)
"""
import csv
import json
import os
import re
import sys

Q = 3329
R_MOD_Q = (1 << 16) % Q          # 2285
R_INV = pow(R_MOD_Q, -1, Q)      # 169
assert R_MOD_Q == 2285 and R_INV == 169

PARAM_SETS = ("512", "768", "1024")
ACVP_FILE = {"keygen": "ML-KEM-keyGen-FIPS203",
             "encap": "ML-KEM-encapDecap-FIPS203",
             "decap": "ML-KEM-encapDecap-FIPS203"}
RESULT_RE = re.compile(r"^RESULT ML-KEM-(\d+) (\w+) tcId=(\d+) (PASS|FAIL)")


def canon(v):
    return v % Q  # Python % is non-negative for positive Q


def convert(op, polys):
    """Return (inputs, output) in canonical form. polys = list of raw int lists."""
    if op == "ntt":
        return [[canon(x) for x in polys[0]]], [canon(x) for x in polys[1]]
    if op == "invntt":
        return [[canon(x) for x in polys[0]]], [canon(x * R_INV) for x in polys[1]]
    if op == "basemul":
        return ([[canon(x) for x in polys[0]], [canon(x) for x in polys[1]]],
                [canon(x * R_MOD_Q) for x in polys[2]])
    raise ValueError(op)


def passing_cases(path):
    ok = set()
    with open(path, "r", encoding="ascii") as fh:
        for line in fh:
            m = RESULT_RE.match(line)
            if m and m.group(4) == "PASS":
                ok.add((m.group(1), m.group(2), m.group(3)))
    return ok


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    build_dir, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)

    files = {
        "ntt": ("ntt_in.hex", None, "ntt_out.hex"),
        "invntt": ("intt_in.hex", None, "intt_out.hex"),
        "basemul": ("basemul_a.hex", "basemul_b.hex", "basemul_out.hex"),
    }
    handles = {}
    for op, names in files.items():
        handles[op] = [open(os.path.join(out_dir, n), "w", encoding="ascii") if n else None
                       for n in names]
    counts = {op: 0 for op in files}
    breakdown = {op: {} for op in files}
    seen = {op: set() for op in files}
    dropped = 0
    rows = []

    for ps in PARAM_SETS:
        ok = passing_cases(os.path.join(build_dir, "acvp_result_%s.log" % ps))
        with open(os.path.join(build_dir, "raw_dump_%s.txt" % ps), "r", encoding="ascii") as fh:
            for line in fh:
                f = line.split()
                op, dps, tc, ctx, seq = f[0], f[1], f[2], f[3], int(f[4])
                vals = [int(x) for x in f[5:]]
                npoly = 3 if op == "basemul" else 2
                if dps != ps or len(vals) != npoly * 256:
                    raise ValueError("malformed dump line: %s ..." % line[:60])
                if (ps, ctx, tc) not in ok:
                    dropped += 1
                    continue
                raw = [vals[i * 256:(i + 1) * 256] for i in range(npoly)]
                ins, out = convert(op, raw)
                idx = counts[op]
                for h, p in zip([h for h in handles[op][:2] if h], ins):
                    h.writelines("%03x\n" % c for c in p)
                handles[op][2].writelines("%03x\n" % c for c in out)
                counts[op] += 1
                key = "ML-KEM-%s" % ps
                breakdown[op][key] = breakdown[op].get(key, 0) + 1
                seen[op].add(tuple(tuple(p) for p in ins))
                raw_in = [x for p in raw[:-1] for x in p]
                rows.append({
                    "op": {"invntt": "intt"}.get(op, op), "index": idx,
                    "line_first": idx * 256, "line_last": idx * 256 + 255,
                    "param_set": key, "acvp_vector_set": ACVP_FILE[ctx],
                    "acvp_function": ctx, "tcId": tc, "call_seq_in_case": seq,
                    "raw_in_min": min(raw_in), "raw_in_max": max(raw_in),
                    "raw_out_min": min(raw[-1]), "raw_out_max": max(raw[-1]),
                })

    for hs in handles.values():
        for h in hs:
            if h:
                h.close()

    with open(os.path.join(out_dir, "manifest.csv"), "w", newline="", encoding="ascii") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)

    summary = {"description": "Polynomial vectors extracted from pq-crystals/kyber ref "
                              "(commit 3edd5af59919) while running NIST ACVP ML-KEM "
                              "vector sets (ACVP-Server commit 975de31eb83d). "
                              "Canonical [0,q) coefficients, FIPS 203 Alg. 9/10/11.",
               "format": "one 3-digit hex coefficient per line, 256 lines per polynomial, "
                         "polynomial i at lines [256*i, 256*i+255], coefficient index 0 first",
               "files": {}}
    for op, names in files.items():
        for n in names:
            if n:
                summary["files"][n] = {"polynomials": counts[op],
                                       "unique_inputs": len(seen[op]),
                                       "by_param_set": breakdown[op]}
    summary["dropped_from_failing_cases"] = dropped
    with open(os.path.join(out_dir, "manifest.json"), "w", encoding="ascii") as fh:
        json.dump(summary, fh, indent=2)
        fh.write("\n")
    for op in files:
        print("%-8s polynomials=%d unique_inputs=%d %s" % (op, counts[op], len(seen[op]),
                                                           breakdown[op]))
    print("dropped (from failing ACVP cases): %d" % dropped)


if __name__ == "__main__":
    main()
