#!/usr/bin/env python3
"""Check that fpga/sw/pqc_ntt_regs.h matches its sources.

Compared:
  docs/spec/l4_axi.md  register table: offsets, names, field bit positions
  rtl/l2/ntt_l2_pkg.sv op_e:   op names, values, and CTRL.op width
  rtl/pkg/mlkem_pkg.sv algo_e: ALGO names and values
  fpga/vivado/create_project.tcl: PQC_BASEADDR / PQC_RANGE vs the header
Header naming rules (what the parser expects):
  PQC_NTT_REG_<REG>                       register offset
  PQC_NTT_<REG>_<FIELD>_BIT               1-bit field
  PQC_NTT_<REG>_<FIELD>_SHIFT / _WIDTH    multi-bit field
  enum pqc_ntt_op   PQC_NTT_OP_<NAME>     = ntt_l2_pkg OP_<NAME>
  enum pqc_ntt_algo PQC_NTT_ALGO_<NAME>   = mlkem_pkg ALGO_<NAME>

Usage: check_regs.py [--root DIR] [--selftest]
Exit 0 when everything matches. --selftest mutates the header text in
memory in several ways and checks that each mutation is reported.
"""

import argparse
import os
import re
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.normpath(os.path.join(SCRIPT_DIR, "..", "..", ".."))

# Unnamed field descriptions in l4_axi.md -> header field name.
UNNAMED = [
    ("busy 중 start", "START_BUSY"),
    ("아닐 때 DIN", "DIN"),
    ("아닐 때 DOUT", "DOUT"),
    ("고정 ID", "ID"),
    ("BFU_LATENCY", "BFU_LATENCY"),
    ("ALGO", "ALGO"),
    ("계수", "COEF"),
]


def parse_spec(text):
    """Return {REG: {"offset": int, "fields": {FIELD: (lsb, width)}}}."""
    regs = {}
    in_section = False
    for line in text.splitlines():
        if line.startswith("## "):
            in_section = "레지스터 맵" in line
            continue
        if not in_section:
            continue
        m = re.match(r"\|\s*(0x[0-9A-Fa-f]+)\s*\|\s*(\w+)\s*\|\s*([^|]+)\|\s*(.*)\|\s*$", line)
        if not m:
            continue
        off, name, _acc, content = m.group(1), m.group(2), m.group(3), m.group(4)
        fields = {}
        for fm in re.finditer(r"bit(?:\[(\d+):(\d+)\]|(\d+))\s+(.+?)(?=,\s*bit|$)", content.strip()):
            if fm.group(3) is not None:
                lsb, width = int(fm.group(3)), 1
            else:
                msb, lsb = int(fm.group(1)), int(fm.group(2))
                width = msb - lsb + 1
            desc = fm.group(4).strip()
            # Descriptive fields first (the ERR descriptions start with a
            # back-quoted STATUS name that is not the field name).
            fname = None
            for key, val in UNNAMED:
                if key in desc:
                    fname = val
                    break
            if fname is None:
                bm = re.match(r"`(\w+)`", desc)
                if bm:
                    fname = bm.group(1).upper()
            if fname is None:
                raise ValueError("cannot name field '%s' of %s" % (desc, name))
            fields[fname] = (lsb, width)
        regs[name.upper()] = {"offset": int(off, 16), "fields": fields}
    return regs


def parse_header(text):
    defs = {}
    for m in re.finditer(r"^#define\s+(PQC_NTT_\w+)\s+(0x[0-9A-Fa-f]+|\d+)u?\b", text, re.M):
        defs[m.group(1)] = int(m.group(2), 0)
    enums = {}
    for ename in ("pqc_ntt_op", "pqc_ntt_algo"):
        m = re.search(r"enum\s+%s\s*\{(.*?)\}" % ename, text, re.S)
        vals = {}
        if m:
            for em in re.finditer(r"(PQC_NTT_\w+)\s*=\s*(\d+)", m.group(1)):
                vals[em.group(1)] = int(em.group(2))
        enums[ename] = vals
    return defs, enums


def parse_sv_enum(text, typename, prefix):
    m = re.search(r"typedef\s+enum\s+logic\s*(?:\[(\d+):0\])?\s*\{([^{}]*)\}\s*%s\s*;" % typename, text)
    if not m:
        raise ValueError("enum %s not found" % typename)
    width = int(m.group(1)) + 1 if m.group(1) else 1
    vals = {}
    for em in re.finditer(r"\b%s(\w+)\s*=\s*\d+'[dD](\d+)" % prefix, m.group(2)):
        vals[em.group(1)] = int(em.group(2))
    return width, vals


def parse_tcl_addr(text):
    out = {}
    for key in ("PQC_BASEADDR", "PQC_RANGE"):
        m = re.search(r"^\s*set\s+%s\s+(0x[0-9A-Fa-f]+|\d+)" % key, text, re.M)
        if m:
            out[key] = int(m.group(1), 0)
    return out


def compare(spec, hdr_text, op_pkg, algo_pkg, tcl_addr):
    errors = []
    defs, enums = parse_header(hdr_text)

    # registers
    hdr_regs = {k[len("PQC_NTT_REG_"):]: v for k, v in defs.items() if k.startswith("PQC_NTT_REG_")}
    for name, r in spec.items():
        if name not in hdr_regs:
            errors.append("register %s (0x%02X) missing in header" % (name, r["offset"]))
        elif hdr_regs[name] != r["offset"]:
            errors.append("register %s: spec 0x%02X, header 0x%02X" % (name, r["offset"], hdr_regs[name]))
    for name in hdr_regs:
        if name not in spec:
            errors.append("header register %s not in spec" % name)
    offs = [r["offset"] for r in spec.values()]
    if len(set(offs)) != len(offs) or any(o % 4 for o in offs):
        errors.append("spec offsets not unique or not 32-bit aligned")

    # fields
    for name, r in spec.items():
        for fname, (lsb, width) in r["fields"].items():
            base = "PQC_NTT_%s_%s" % (name, fname)
            if width == 1:
                got = defs.get(base + "_BIT")
                if got != lsb:
                    errors.append("%s_BIT: spec %d, header %s" % (base, lsb, got))
            else:
                gs, gw = defs.get(base + "_SHIFT"), defs.get(base + "_WIDTH")
                if gs != lsb or gw != width:
                    errors.append("%s: spec [%d +: %d], header shift %s width %s" % (base, lsb, width, gs, gw))
        # header fields of this register that the spec does not have
        for k in defs:
            m = re.match(r"PQC_NTT_%s_(\w+?)_(BIT|SHIFT)$" % name, k)
            if m and m.group(1) not in r["fields"]:
                errors.append("header field %s not in spec register %s" % (k, name))

    # op encoding
    op_width, op_vals = op_pkg
    hop = {k[len("PQC_NTT_OP_"):]: v for k, v in enums["pqc_ntt_op"].items()}
    if hop != op_vals:
        errors.append("op encoding: pkg %s, header %s" % (sorted(op_vals.items()), sorted(hop.items())))
    if spec.get("CTRL", {}).get("fields", {}).get("OP", (0, 0))[1] != op_width:
        errors.append("CTRL.op width in spec differs from op_e width %d" % op_width)
    if defs.get("PQC_NTT_CTRL_OP_WIDTH") != op_width:
        errors.append("PQC_NTT_CTRL_OP_WIDTH %s differs from op_e width %d" % (defs.get("PQC_NTT_CTRL_OP_WIDTH"), op_width))
    if defs.get("PQC_NTT_OP_COUNT") != len(op_vals):
        errors.append("PQC_NTT_OP_COUNT %s, pkg has %d ops" % (defs.get("PQC_NTT_OP_COUNT"), len(op_vals)))

    # ALGO encoding
    _aw, algo_vals = algo_pkg
    halg = {k[len("PQC_NTT_ALGO_"):]: v for k, v in enums["pqc_ntt_algo"].items()}
    if halg != algo_vals:
        errors.append("ALGO encoding: pkg %s, header %s" % (sorted(algo_vals.items()), sorted(halg.items())))
    if defs.get("PQC_NTT_ALGO_COUNT") != len(algo_vals):
        errors.append("PQC_NTT_ALGO_COUNT %s, pkg has %d" % (defs.get("PQC_NTT_ALGO_COUNT"), len(algo_vals)))

    # address map vs Vivado script
    if tcl_addr is not None:
        if tcl_addr.get("PQC_BASEADDR") != defs.get("PQC_NTT_DEFAULT_BASEADDR"):
            errors.append("base address: tcl %s, header %s" % (tcl_addr.get("PQC_BASEADDR"), defs.get("PQC_NTT_DEFAULT_BASEADDR")))
        if tcl_addr.get("PQC_RANGE") != defs.get("PQC_NTT_ADDR_RANGE"):
            errors.append("address range: tcl %s, header %s" % (tcl_addr.get("PQC_RANGE"), defs.get("PQC_NTT_ADDR_RANGE")))
        top = max(offs) + 4 if offs else 0
        if defs.get("PQC_NTT_ADDR_RANGE", 0) < top:
            errors.append("address range smaller than the register map")
    return errors


def load_all(root):
    def rd(*p):
        with open(os.path.join(root, *p), encoding="utf-8") as f:
            return f.read()
    spec = parse_spec(rd("docs", "spec", "l4_axi.md"))
    hdr = rd("fpga", "sw", "pqc_ntt_regs.h")
    op_pkg = parse_sv_enum(rd("rtl", "l2", "ntt_l2_pkg.sv"), "op_e", "OP_")
    algo_pkg = parse_sv_enum(rd("rtl", "pkg", "mlkem_pkg.sv"), "algo_e", "ALGO_")
    tcl_path = os.path.join(root, "fpga", "vivado", "create_project.tcl")
    tcl_addr = parse_tcl_addr(rd("fpga", "vivado", "create_project.tcl")) if os.path.exists(tcl_path) else None
    return spec, hdr, op_pkg, algo_pkg, tcl_addr


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", default=DEFAULT_ROOT)
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    spec, hdr, op_pkg, algo_pkg, tcl_addr = load_all(a.root)

    if not a.selftest:
        nfields = sum(len(r["fields"]) for r in spec.values())
        print("spec: %d registers, %d fields; op_e: %d values (width %d); algo_e: %d values" %
              (len(spec), nfields, len(op_pkg[1]), op_pkg[0], len(algo_pkg[1])))
        if tcl_addr is None:
            print("note: create_project.tcl not found, address map not compared")
        errs = compare(spec, hdr, op_pkg, algo_pkg, tcl_addr)
        for e in errs:
            print("MISMATCH " + e)
        print("CHECK_REGS RESULT: %s (%d mismatches)" % ("PASS" if not errs else "FAIL", len(errs)))
        return 1 if errs else 0

    # self test: the unmodified header must pass, every mutation must fail
    mutations = [
        ("status out_valid bit", r"(PQC_NTT_STATUS_OUT_VALID_BIT\s+)4", r"\g<1>5"),
        ("ERR offset", r"(PQC_NTT_REG_ERR\s+)0x18u", r"\g<1>0x1Cu"),
        ("op INTT value", r"(PQC_NTT_OP_INTT\s*=\s*)2", r"\g<1>5"),
        ("ctrl op width", r"(PQC_NTT_CTRL_OP_WIDTH\s+)3", r"\g<1>2"),
        ("version id shift", r"(PQC_NTT_VERSION_ID_SHIFT\s+)16", r"\g<1>15"),
        ("algo K2RED value", r"(PQC_NTT_ALGO_K2RED\s*=\s*)3", r"\g<1>4"),
        ("register removed", r"#define PQC_NTT_REG_CYCLES .*\n", ""),
        ("extra field", r"(#define PQC_NTT_CTRL_BANK_BIT\s+4)", "\\1\n#define PQC_NTT_CTRL_IRQ_EN_BIT 5"),
        ("base address", r"(PQC_NTT_DEFAULT_BASEADDR\s+)0x43C00000u", r"\g<1>0x43C10000u"),
    ]
    ok = True
    base_errs = compare(spec, hdr, op_pkg, algo_pkg, tcl_addr)
    print("selftest unmodified: %d mismatches (%s)" % (len(base_errs), "ok" if not base_errs else "BAD"))
    ok &= not base_errs
    for desc, pat, rep in mutations:
        mutated, n = re.subn(pat, rep, hdr)
        if n != 1:
            print("selftest %s: pattern did not apply (BAD)" % desc)
            ok = False
            continue
        errs = compare(spec, mutated, op_pkg, algo_pkg, tcl_addr)
        print("selftest %s: %d mismatches (%s)" % (desc, len(errs), "ok" if errs else "BAD"))
        ok &= bool(errs)
    print("CHECK_REGS SELFTEST RESULT: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
