#!/usr/bin/env python3
"""Generate zeta_rom_pkg.sv (synthesizable constant ROM tables) from the
golden-model ROM dumps.

Source of the values: the golden model vector generator (model/README.md,
"vector generator additional files"). Regenerate everything with, from the
project directory:

    make -C model vectors
    cp model/vectors/rom_zeta_*.hex model/vectors/rom_gamma_*.hex \
       model/vectors/rom_k2_*.hex rtl/l2/rom/
    python3 rtl/l2/rom/gen_rom_pkg.py

Input files (in this script's directory unless --dir is given):
    rom_zeta_<algo>.hex   128 lines, zeta_i * S^-1 mod q
    rom_gamma_<algo>.hex  128 lines, gamma_i (S = 1) or gamma_i * S^-2 (S != 1)
    rom_k2_<algo>.hex     1 line, K2 = S^-2 mod q
with <algo> in the arch.md ALGO order: barrett, mont12, shiftadd, k2red.

Output: zeta_rom_pkg.sv with packed constant arrays indexed [algo][address].
Packed localparam arrays are used instead of $readmemh so that the tables are
plain constants for every tool (DC, Vivado, Questa) and need no file I/O at
elaboration.
"""
import argparse
import os
import sys

Q = 3329
ALGOS = ["barrett", "mont12", "shiftadd", "k2red"]  # mlkem_pkg::algo_e order
DEPTH = 128
COEF_W = 12


def read_hex(path, n_expected):
    vals = []
    with open(path, "r", encoding="ascii") as f:
        for lineno, line in enumerate(f, 1):
            s = line.strip()
            if not s or s.startswith("//"):
                continue
            v = int(s, 16)
            if not 0 <= v < Q:
                sys.exit(f"{path}:{lineno}: value {v} outside [0, {Q})")
            vals.append(v)
    if len(vals) != n_expected:
        sys.exit(f"{path}: {len(vals)} values, expected {n_expected}")
    return vals


def fmt_table(name, tables, comment):
    # tables: list (one per algo) of lists of DEPTH values. Element [0][0] is
    # the leftmost item of the concatenation (ascending packed ranges).
    out = [f"  // {comment}",
           f"  localparam logic [0:ZR_N_ALGO-1][0:ZR_DEPTH-1][ZR_W-1:0] {name} = {{"]
    items = []
    for a, vals in enumerate(tables):
        for i in range(0, DEPTH, 8):
            chunk = ", ".join(f"12'h{v:03x}" for v in vals[i:i + 8])
            items.append((a, i, chunk))
    for k, (a, i, chunk) in enumerate(items):
        sep = "," if k != len(items) - 1 else ""
        out.append(f"    {chunk}{sep}  // {ALGOS[a]} [{i}..{i + 7}]")
    out.append("  };")
    return out


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dir", default=here, help="directory of the rom_*.hex files")
    ap.add_argument("--out", default=os.path.join(here, "zeta_rom_pkg.sv"))
    args = ap.parse_args()

    zeta = [read_hex(os.path.join(args.dir, f"rom_zeta_{a}.hex"), DEPTH) for a in ALGOS]
    gamma = [read_hex(os.path.join(args.dir, f"rom_gamma_{a}.hex"), DEPTH) for a in ALGOS]
    k2 = [read_hex(os.path.join(args.dir, f"rom_k2_{a}.hex"), 1)[0] for a in ALGOS]

    lines = [
        "// zeta_rom_pkg: constant ROM tables of zeta_rom (L2), one set per ALGO.",
        "//",
        "// GENERATED FILE, do not edit. Generator: rtl/l2/rom/gen_rom_pkg.py",
        "// Source: golden model ROM dumps rtl/l2/rom/rom_{zeta,gamma,k2}_<algo>.hex,",
        "// copied from model/vectors after 'make -C model vectors' (see the generator).",
        "//",
        "// Index order: [algo][address], algo = mlkem_pkg::algo_e value",
        "// (0 BARRETT, 1 MONT12, 2 SHIFTADD, 3 K2RED).",
        "//   ZETA_ROM_TBL [a][i] = zeta_i * S^-1 mod q          (i = zeta index)",
        "//   GAMMA_ROM_TBL[a][i] = gamma_i (S = 1), gamma_i * S^-2 (S != 1) (i = pair)",
        "//   K2_TBL[a]           = S^-2 mod q (1 when S = 1, unused there)",
        "package zeta_rom_pkg;",
        "",
        f"  localparam int ZR_N_ALGO = {len(ALGOS)};",
        f"  localparam int ZR_DEPTH  = {DEPTH};",
        f"  localparam int ZR_W      = {COEF_W};",
        "",
    ]
    lines += fmt_table("ZETA_ROM_TBL", zeta, "zeta ROM, pre-scaled by S^-1")
    lines.append("")
    lines += fmt_table("GAMMA_ROM_TBL", gamma, "gamma ROM, pre-scaled by S^-2 when S != 1")
    lines.append("")
    lines.append("  // K2 = S^-2 mod q")
    lines.append("  localparam logic [0:ZR_N_ALGO-1][ZR_W-1:0] K2_TBL = {")
    lines.append("    " + ", ".join(f"12'h{v:03x}" for v in k2) + "  // "
                 + " ".join(ALGOS))
    lines.append("  };")
    lines.append("")
    lines.append("endpackage")
    with open(args.out, "w", encoding="ascii") as f:
        f.write("\n".join(lines) + "\n")
    print(f"wrote {args.out}: {len(ALGOS)} algos x (zeta {DEPTH} + gamma {DEPTH} + K2 1)")


if __name__ == "__main__":
    main()
