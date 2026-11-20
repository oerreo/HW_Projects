# Writes rtl/pkg/lut_pkg.sv (lut_lerp and rsqrt_nr tables) from model/src/tabs.c (S4-6 EXP2N,
# S4-7 SIGM and the rsqrt seed).
# Run from the project directory without arguments: python3 -I model/tools/lutsv.py
import re

s = open('model/src/tabs.c').read()


def table(name, first, last):
    m = re.search(name + r'\[257\] = \{(.*?)\};', s, re.S)
    v = [int(x.rstrip('u')) for x in re.findall(r'\d+u', m.group(1))]
    assert len(v) == 257 and v[0] == first and v[256] == last
    return v


def emit(out, name, v):
    out.append("  localparam logic [16:0] %s [257] = '{" % name)
    lines = ["    " + ", ".join("17'd%d" % x for x in v[i:i + 8]) for i in range(0, 257, 8)]
    out.append(",\n".join(lines))
    out.append("  };")


exp8 = table('exp_8', 65536, 32768)
sig8 = table('sig_8', 32768, 65536)
out = ["// lut_pkg: constant tables of lut_lerp (hierarchy.md 3.2). Generated from model/src/tabs.c by",
       "// model/tools/lutsv.py (do not edit):",
       "//   EXP2N_TAB = exp_8: round(65536 * 2^(-i/256)), i = 0..256, the table k_exp_lut(8)",
       "//   SIGM_TAB  = sig_8: round(65536 * sigmoid(16 i / 256)), i = 0..256, the table k_sig_lut(8)",
       "//   RSQ_TAB   = k_rsq_lut (rsqrt_nr seed)",
       "// The lut_lerp and rsqrt_nr testbenches compare every entry with the golden model's table (DPI).",
       "package lut_pkg;",
       "  localparam int EXP2N_B = 8;  // index bits (257 entries)"]
emit(out, "EXP2N_TAB", exp8)
out.append("  localparam int SIGM_B = 8;   // index bits (257 entries over [0, 16))")
emit(out, "SIGM_TAB", sig8)
m = re.search(r'k_rsq_lut\[48\] = \{(.*?)\};', s, re.S)
rsq = [int(x.rstrip('u')) for x in re.findall(r'\d+u', m.group(1))]
assert len(rsq) == 48 and rsq[0] == 64535 and max(rsq) < 65536
out.append("  // RSQ_TAB = k_rsq_lut: round(2^18 / sqrt(i + 16.5)), i = 0..47 (rsqrt_nr seed, S4-7)")
out.append("  localparam logic [15:0] RSQ_TAB [48] = '{")
out.append(",\n".join("    " + ", ".join("16'd%d" % x for x in rsq[i:i + 8]) for i in range(0, 48, 8)))
out.append("  };")
out.append("endpackage")
open('rtl/pkg/lut_pkg.sv', 'w').write("\n".join(out) + "\n")
