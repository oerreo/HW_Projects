#!/usr/bin/env python3
"""Summarize the Catapult L0 builds (hls/l0/out/*/rtl.rpt) and their RTL
simulation results (sim/hls_l0_*/summary.txt) into hls/l0/report/.

    python3 hls/l0/report/hls_l0_report.py

Writes summary.csv (one row per block x library x configuration) and
summary.md. All area and timing values are Catapult estimates from its own
component library (no RTL synthesis was run).
"""
import csv
import re
import sys
from pathlib import Path

HLS_DIR = Path(__file__).resolve().parent.parent
PRJ = HLS_DIR.parent.parent
OUT = HLS_DIR / "out"
REPORT = HLS_DIR / "report"
SIM = PRJ / "sim"

BLOCKS = [f"mod_{k}_{a}" for k in ("red", "mul")
          for a in ("barrett", "mont12", "shiftadd", "k2red")]
LIBS = ["fpga", "asic"]
CFGS = ["c0", "p1", "p2"]
REQ_LAT = {"c0": 0, "p1": 1, "p2": 2}
LIB_NAME = {"fpga": "mgc_Xilinx-ZYNQ-1_beh (xc7z020clg400-1)",
            "asic": "nangate-45nm_beh (Nangate 45 nm open cell library)"}
SIM_LABEL = {"pipe0": "c0", "pipe1": "p1", "pipe2": "p2",
             "lat0": "c0", "lat1": "p1", "lat2": "p2"}


def section(text, title):
    """Lines of a top-level report section (title at column 0)."""
    m = re.search(r"^" + re.escape(title) + r".*?$(.*?)(?=^\S)", text, re.M | re.S)
    return m.group(1).splitlines() if m else []


def parse_rpt(path):
    text = path.read_text()
    r = {}
    m = re.search(r"^\s*Design Total:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)", text, re.M)
    if m:
        r["latency"] = int(m.group(2))
        r["throughput"] = int(m.group(3))
        r["ii"] = int(m.group(5))
    else:
        r["latency"], r["throughput"], r["ii"] = None, None, None

    # Bill of materials: area columns are named in the header.
    bom = section(text, "Bill Of Materials")
    header = next((ln for ln in bom if "Component Name" in ln), "")
    area_cols = re.findall(r"Area[^ ]*(?: Score)?", header)
    total = next((ln for ln in bom if "TOTAL AREA" in ln), "")
    vals = [float(v) for v in re.findall(r"[-\d.]+", total.split(":", 1)[1])] if total else []
    r["area"] = dict(zip(area_cols, vals))
    ops = []
    for ln in bom:
        mm = re.match(r"\s+((?:mgc|ccs)_\w+)\(([\d,]*)\)\s+.*\s(\d+)\s*$", ln)
        if not mm:
            continue
        name, params, n_assign = mm.group(1), mm.group(2), int(mm.group(3))
        if n_assign == 0 or name in ("ccs_in", "mgc_out_dreg", "mgc_not"):
            continue
        ops.append(f"{name}({params})x{n_assign}")
    r["ops"] = " ".join(ops)

    m = re.search(r"Register-to-Variable Mappings.*?^\s+Total:\s+(\d+)", text, re.M | re.S)
    r["reg_bits"] = int(m.group(1)) if m else 0
    m = re.search(r"Max Delay:\s+([-\d.]+)", text)
    r["max_delay"] = float(m.group(1)) if m else None
    m = re.search(r"Slack:\s+([-\d.]+)", text)
    r["slack"] = float(m.group(1)) if m else None
    m = re.search(r"Clock period or pin-to-reg delay constraint \(clk\)\s*:\s*([\d.]+)", text)
    r["clk"] = float(m.group(1)) if m else None
    m = re.search(r"^-- Version:\s+(\S+)", text, re.M)
    r["version"] = m.group(1) if m else ""
    return r


def comb_check(netlist):
    """True when the netlist has no clocked process (expected for c0)."""
    return "always @(posedge" not in netlist.read_text()


def parse_sim():
    """{(block, lib, cfg): dict(verdict, data_checks, data_mm, valid_checks, valid_mm)}"""
    res = {}
    for summ in SIM.glob("hls_l0_*/summary.txt"):
        for ln in summ.read_text().splitlines():
            m = re.match(r"hls_l0_(mod_\w+?)_(fpga|asic)/(\w+): (PASS|FAIL)", ln)
            if not m or m.group(3) not in SIM_LABEL:
                continue
            checks = {k: (int(c), int(mm)) for k, c, mm in
                      re.findall(r"CHECKS \[(\w+)\]: checks=(\d+) mismatches=(\d+)", ln)}
            res[(m.group(1), m.group(2), SIM_LABEL[m.group(3)])] = {
                "verdict": m.group(4),
                "data_checks": checks.get("data", (0, 0))[0],
                "data_mm": checks.get("data", (0, 0))[1],
                "valid_checks": checks.get("valid_align", (0, 0))[0],
                "valid_mm": checks.get("valid_align", (0, 0))[1],
            }
    return res


def parse_ctest():
    log = HLS_DIR / "run" / "ctest" / "test_hls_c.log"
    res = {}
    if log.exists():
        for ln in log.read_text().splitlines():
            m = re.match(r"ITEM (\S+)\s+checks=(\d+) \(expected \d+\) mismatches=(\d+) (PASS|FAIL)", ln)
            if m:
                res[m.group(1)] = (int(m.group(2)), int(m.group(3)), m.group(4))
    return res


def main():
    sim = parse_sim()
    ctest = parse_ctest()
    rows = []
    for b in BLOCKS:
        for lib in LIBS:
            for cfg in CFGS:
                top = f"{b}_{lib}_{cfg}"
                rpt = OUT / top / "rtl.rpt"
                if not rpt.exists():
                    rows.append({"block": b, "lib": lib, "cfg": cfg, "status": "missing"})
                    continue
                r = parse_rpt(rpt)
                lat = r["latency"]
                if lat is None and cfg == "c0" and comb_check(OUT / top / "concat_rtl.v"):
                    lat = 0
                s = sim.get((b, lib, cfg), {})
                c = ctest.get(b, ("", "", ""))
                a = r["area"]
                rows.append({
                    "block": b, "lib": lib, "cfg": cfg, "status": "ok",
                    "req_latency": REQ_LAT[cfg], "latency": lat,
                    "ii": r["ii"] if r["ii"] is not None else "",
                    "clk_ns": r["clk"],
                    "area_score": a.get("Area Score", ""),
                    "area_comb": a.get("Area(Combinational)", ""),
                    "area_seq": a.get("AreaSeq", ""),
                    "luts": a.get("Area(LUTs)", ""),
                    "dsp": a.get("Area(DSP)", 0.0 if lib == "fpga" else ""),
                    "mux_carry": a.get("Area(MUX_CARRYs)", ""),
                    "reg_bits": r["reg_bits"],
                    "max_delay_ns": r["max_delay"], "slack_ns": r["slack"],
                    "ops": r["ops"],
                    "ctest_checks": c[0], "ctest_mm": c[1],
                    "sim_verdict": s.get("verdict", "not run"),
                    "sim_data_checks": s.get("data_checks", ""),
                    "sim_data_mm": s.get("data_mm", ""),
                    "sim_valid_checks": s.get("valid_checks", ""),
                    "sim_valid_mm": s.get("valid_mm", ""),
                    "rpt": f"hls/l0/out/{top}/rtl.rpt",
                    "version": r["version"],
                })

    REPORT.mkdir(exist_ok=True)
    fields = ["block", "lib", "cfg", "status", "req_latency", "latency", "ii", "clk_ns",
              "area_score", "area_comb", "area_seq", "luts", "dsp", "mux_carry", "reg_bits",
              "max_delay_ns", "slack_ns", "ops", "ctest_checks", "ctest_mm", "sim_verdict",
              "sim_data_checks", "sim_data_mm", "sim_valid_checks", "sim_valid_mm", "rpt",
              "version"]
    with open(REPORT / "summary.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        w.writeheader()
        for row in rows:
            w.writerow(row)

    def fmt(v, nd=2):
        if v is None or v == "":
            return "-"
        if isinstance(v, float):
            return f"{v:.{nd}f}"
        return str(v)

    version = next((r["version"] for r in rows if r.get("version")), "?")
    md = []
    md.append("# Catapult HLS L0 builds: summary\n")
    md.append("**All area and timing numbers below are Catapult HLS estimates from its own "
              "component library (rtl.rpt after `go extract`). They are not RTL synthesis "
              "results.** No downstream synthesis (Vivado, DC, RTL Compiler, Oasys) was run, "
              "and the Ultra datapath estimation (`ADVANCED_DPOPT`) was off. "
              "No comparison with the hand RTL is made here.\n")
    md.append(f"- Catapult version: {version}")
    md.append("- Generated by `hls/l0/report/hls_l0_report.py` from `hls/l0/out/*/rtl.rpt`, "
              "`sim/hls_l0_*/summary.txt` and the C test log.")
    md.append("- Flow and settings: `hls/l0/tcl/hls_l0.tcl` (OPT_CONST_MULTS full, "
              "RESET_CLEARS_ALL_REGS no, clock overhead default 20%).")
    for lib in LIBS:
        md.append(f"- `{lib}`: {LIB_NAME[lib]}")
    md.append("- cfg: c0 = combinational CCORE (latency 0), p1 / p2 = sequential CCORE, II = 1, "
              "output write fixed at c-step 1 / 2.")
    md.append("- FPGA area: LUTs, DSP and MUX_CARRYs as estimated by the Zynq-7000 (-1) library; "
              "flip-flops are not in the FPGA area score, see reg bits. ASIC area: Catapult area "
              "score of nangate-45nm_beh (the report prints no unit; not converted).")
    md.append("- reg bits: total register bits of the generated module (Register-to-Variable "
              "Mappings). The adapter valid flops (LATENCY bits) are not included.")
    md.append("- Simulation: unchanged tb_mod_red / tb_mod_mul via `sim/run.sh hls_l0_<block>_<lib>`; "
              "data = output data checks (exhaustive), valid = valid_o alignment checks.\n")
    for lib in LIBS:
        md.append(f"## {lib}\n")
        if lib == "fpga":
            md.append("| block | cfg | req lat | lat | II | clk ns | LUTs | DSP | MUX_CARRY | "
                      "reg bits | max delay ns | slack ns | C test mm | sim data checks / mm | "
                      "sim valid checks / mm | operators (post assign) |")
            md.append("|" + "---|" * 16)
        else:
            md.append("| block | cfg | req lat | lat | II | clk ns | area score | comb | seq | "
                      "reg bits | max delay ns | slack ns | C test mm | sim data checks / mm | "
                      "sim valid checks / mm | operators (post assign) |")
            md.append("|" + "---|" * 16)
        for r in rows:
            if r["lib"] != lib:
                continue
            if r["status"] != "ok":
                md.append(f"| {r['block']} | {r['cfg']} | missing |" + " |" * 13)
                continue
            if lib == "fpga":
                area = f"{fmt(r['luts'], 0)} | {fmt(r['dsp'], 0)} | {fmt(r['mux_carry'], 0)}"
            else:
                area = f"{fmt(r['area_score'], 1)} | {fmt(r['area_comb'], 1)} | {fmt(r['area_seq'], 1)}"
            md.append(
                f"| {r['block']} | {r['cfg']} | {r['req_latency']} | {fmt(r['latency'])} | "
                f"{fmt(r['ii'])} | {fmt(r['clk_ns'], 1)} | {area} | {r['reg_bits']} | "
                f"{fmt(r['max_delay_ns'])} | {fmt(r['slack_ns'])} | {fmt(r['ctest_mm'])} | "
                f"{fmt(r['sim_data_checks'])} / {fmt(r['sim_data_mm'])} | "
                f"{fmt(r['sim_valid_checks'])} / {fmt(r['sim_valid_mm'])} | {r['ops']} |")
        md.append("")
    md.append("Raw reports: `hls/l0/out/<block>_<lib>_<cfg>/rtl.rpt`, `cycle.rpt`; netlist "
              "`concat_rtl.v` (the `Generated by:` header value is redacted, nothing else "
              "changed).")
    (REPORT / "summary.md").write_text("\n".join(md) + "\n")
    n_bad = sum(1 for r in rows if r["status"] != "ok"
                or r["latency"] != r["req_latency"])
    print(f"rows={len(rows)} missing_or_latency_mismatch={n_bad}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
