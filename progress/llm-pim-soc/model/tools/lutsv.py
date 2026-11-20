# Writes rtl/pkg/lut_pkg.sv (lut_lerp tables) from model/src/tabs.c (S4-6).
# Run from the project directory without arguments: python3 -I model/tools/lutsv.py
import re

s = open('model/src/tabs.c').read()
m = re.search(r'exp_8\[257\] = \{(.*?)\};', s, re.S)
v = [int(x.rstrip('u')) for x in re.findall(r'\d+u', m.group(1))]
assert len(v) == 257 and v[0] == 65536 and v[256] == 32768
out = ["// lut_pkg: constant tables of lut_lerp (hierarchy.md 3.2). Generated from model/src/tabs.c",
       "// (exp_8: round(65536 * 2^(-i/256)), i = 0..256, the table k_exp_lut(8) of the golden model) by",
       "// model/tools/lutsv.py; the lut_lerp testbench compares every entry with k_exp_lut(8).",
       "package lut_pkg;",
       "  localparam int EXP2N_B = 8;  // index bits (257 entries)",
       "  localparam logic [16:0] EXP2N_TAB [257] = '{"]
lines = ["    " + ", ".join("17'd%d" % x for x in v[i:i + 8]) for i in range(0, 257, 8)]
out.append(",\n".join(lines))
out.append("  };")
out.append("endpackage")
open('rtl/pkg/lut_pkg.sv', 'w').write("\n".join(out) + "\n")
