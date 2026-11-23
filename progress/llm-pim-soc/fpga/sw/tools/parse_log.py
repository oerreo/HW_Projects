#!/usr/bin/env python3
"""Parse the UART log of the ARM baseline program (fpga/sw) or of the system program
(fpga/sys, "LMSYS" blocks, S5-1) into tables and CSV.

    python3 -I parse_log.py uart.log                     # Markdown tables to stdout
    python3 -I parse_log.py --csv k.csv a.log b.log      # kernel/run rows of several logs
    python3 -I parse_log.py --pos-csv p.csv uart.log     # per-token times (run T)

Only the last "LMBASE BEGIN" .. "LMBASE END" (or "LMSYS BEGIN" .. "LMSYS END") block of
each file is read; boot messages, CR characters and other lines are ignored. The parser
recomputes the mismatch sums from the CHECK/VAR/PROMPT/DATA lines and the kernel time sums
from the KERN lines and compares them with the program's MSUM/RESULT/RUN lines. System logs:
also the CHECK requirement sums (tokens, hashes, KCMP, COH, fallback, IPERR), KCMP and COH
totals against CHECK, and KSPLIT (arm + pl + mv + call) <= KERN per category (system.md 2.6).

Exit status: 0 PASS, 1 FAIL, 2 INCOMPLETE (no END or RESULT, or inconsistent sums).
"""
import csv
import re
import sys

LINE = re.compile(r"^([A-Z][A-Z0-9]*)((?: [A-Za-z_][A-Za-z0-9_]*=\S*)*)\s*$")
PAIR = re.compile(r" ([A-Za-z_][A-Za-z0-9_]*)=(\S*)")
GEMV = ("gemv_q", "gemv_k", "gemv_v", "gemv_o", "gemv_w1", "gemv_w2", "gemv_w3", "gemv_cls")


def num(v):
    try:
        if v.startswith("0x"):
            return int(v, 16)
        if re.fullmatch(r"-?\d+", v):
            return int(v)
        return float(v)
    except ValueError:
        return v


class Log:
    def __init__(self, path):
        self.path = path
        self.recs = []
        self.begin = self.end = False
        self.problems = []
        self.prog = "base"
        lines = open(path, "rb").read().decode("utf-8", "replace").replace("\r", "").split("\n")
        start = None
        for i, ln in enumerate(lines):
            if ln.startswith("LMBASE BEGIN") or ln.startswith("LMSYS BEGIN"):
                start = i
        if start is None:
            return
        self.begin = True
        if lines[start].startswith("LMSYS"):
            self.prog = "sys"
        endkey = "LMSYS END" if self.prog == "sys" else "LMBASE END"
        for ln in lines[start + 1:]:
            if ln.startswith(endkey):
                self.end = True
                break
            m = LINE.match(ln)
            if not m:
                continue
            d = {k: num(v) for k, v in PAIR.findall(m.group(2))}
            d["_key"] = m.group(1)
            self.recs.append(d)

    def get(self, key, **flt):
        return [r for r in self.recs if r["_key"] == key and all(r.get(k) == v for k, v in flt.items())]

    def one(self, key, **flt):
        r = self.get(key, **flt)
        return r[-1] if r else None

    def tps(self):
        c = self.one("CLK")
        return float(c["tps"]) if c else None

    def models(self):
        return [r["m"] for r in self.get("MODEL")]

    def variants(self, m):
        return [r["v"] for r in self.get("VAR", m=m)]


def check_sums(lg):
    """Recompute mismatch counts and kernel sums. Returns a list of problems."""
    probs = []
    total = 0
    for m in lg.models():
        mis = 0
        data = lg.one("DATA", m=m)
        if data and data.get("status") == "absent":
            continue
        if data and data.get("status") == "corrupt":
            mis += 1
        for r in lg.get("VAR", m=m):
            mis += int(r.get("wmis", 0))
        for r in lg.get("PROMPT", m=m):
            mis += int(r.get("mis", 0))
        for r in lg.get("ROPE", m=m):
            if r.get("diff", 0) and not r.get("replaced", 0):
                mis += 1
        for r in lg.get("CHECK", m=m):
            req = int(r["tok_mis"]) + (int(r["hash_mis"]) if r.get("hash_req") else 0)
            if isinstance(r.get("self_mis"), int):
                req += r["self_mis"]
            if (req == 0) != (r.get("result") == "PASS"):
                probs.append(f"CHECK {m} {r.get('v')} {r.get('run')}: result field disagrees")
            mis += req
        ms = lg.one("MSUM", m=m)
        if ms is None:
            probs.append(f"model {m}: no MSUM line")
        elif ms["mismatches"] != mis:
            probs.append(f"model {m}: MSUM mismatches {ms['mismatches']} != recomputed {mis}")
        total += mis
        for v in lg.variants(m):
            kr = lg.get("KERN", m=m, v=v)
            p = lg.one("RUN", m=m, v=v, run="P")
            if p and kr:
                s = sum(int(k["ticks"]) for k in kr)
                if s != int(p["ticks"]):
                    probs.append(f"{m} {v}: KERN ticks sum {s} != RUN P ticks {p['ticks']}")
    res = lg.one("RESULT")
    if res and res["mismatches"] != total:
        probs.append(f"RESULT mismatches {res['mismatches']} != recomputed {total}")
    return probs


def compared(lg):
    """number of individual comparisons behind the result (tokens, hashes, weights)"""
    if lg.prog == "sys":
        return compared_sys(lg)
    n = 0
    for r in lg.get("CHECK"):
        n += int(r["n"]) * (1 + (1 if r.get("hash_req") else 0) + (1 if isinstance(r.get("self_mis"), int) else 0))
    n += sum(1 for r in lg.get("VAR") if r.get("kind") in ("Q", "H"))
    n += sum(int(r.get("n_exp", 0)) for r in lg.get("PROMPT"))
    n += sum(1 for r in lg.get("DATA") if r.get("status") in ("ok", "corrupt"))
    return n


def status(lg):
    if not lg.begin or not lg.end or lg.one("RESULT") is None:
        return "INCOMPLETE", ["log has no BEGIN/END/RESULT (truncated?)"]
    probs = check_sys(lg) if lg.prog == "sys" else check_sums(lg)
    if probs:
        return "INCOMPLETE", probs
    return lg.one("RESULT")["result"], []


def us(ticks, tps, steps=1):
    return 1e6 * float(ticks) / tps / steps


def table(rows, head):
    out = ["| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
    out += ["| " + " | ".join(str(c) for c in r) + " |" for r in rows]
    return "\n".join(out)


def report(lg):
    tps = lg.tps()
    out = [f"# {lg.path}"]
    b = lg.one("BUILD") or {}
    p = lg.one("PLAT") or {}
    clk = lg.one("CLK") or {}
    out.append(f"build: plat={b.get('plat')} opt={b.get('opt')} neon={b.get('neon')} cc={b.get('cc')}")
    if clk:
        hz = 10 * clk.get("cyc_per_100ms", 0) * clk["tps"] / max(clk.get("ticks", 1), 1) / 10
        out.append(f"time base: {clk['tps']} ticks/s, cycle counter rate {hz / 1e6:.1f} MHz "
                   f"(cpu_hz from BSP: {p.get('cpu_hz', '-')})")
    ovh = [[r["kind"], r.get("n"), r.get("min_ticks", "-"), r.get("avg_ticks"), r.get("avg_cyc", "-"),
            f"{us(r['avg_ticks'], tps) * 1000:.1f}"] for r in lg.get("OVH")]
    if ovh:
        out += ["", "## Probe overhead", table(ovh, ["kind", "n", "min ticks", "avg ticks", "avg cyc", "avg ns"])]
    lap = lg.one("OVH", kind="lap")
    hook = lg.one("OVH", kind="hook_pair")
    for m in lg.models():
        data = lg.one("DATA", m=m)
        out += ["", f"## Model {m}"]
        if data:
            out.append(f"data: src={data.get('src')} status={data.get('status')}")
        if data and data.get("status") != "ok":
            continue
        rows = []
        for v in lg.variants(m):
            var = lg.one("VAR", m=m, v=v)
            e = lg.one("RUN", m=m, v=v, run="E")
            t = lg.one("RUN", m=m, v=v, run="T")
            pr = lg.one("RUN", m=m, v=v, run="P")
            tp = lg.one("TOKPOS", m=m, v=v)
            steps = (e or t or pr or {}).get("steps", 1)
            est = "-"
            if pr and lap:
                per = float(hook["avg_ticks"]) / 2 if (var and var.get("kind") == "H" and hook) else float(lap["avg_ticks"])
                est = f"{100.0 * pr['probes'] * per / float(pr['ticks']):.2f}"
            rows.append([
                v, var.get("kind") if var else "-", var.get("init_ms") if var else "-",
                f"{us(e['ticks'], tps, steps) / 1000:.3f}" if e else "-",
                e.get("tok_s") if e else "-",
                f"{us(t['ticks'], tps, steps) / 1000:.3f}" if t else "-",
                f"{us(tp['first'], tps) / 1000:.3f}" if tp else "-",
                f"{us(tp['mid8'], tps) / 1000:.3f}" if tp else "-",
                f"{us(tp['last8'], tps) / 1000:.3f}" if tp else "-",
                f"{us(pr['ticks'], tps, steps) / 1000:.3f}" if pr else "-",
                f"{100.0 * (float(pr['ticks']) - float(e['ticks'])) / float(e['ticks']):+.2f}" if (pr and e) else "-",
                est])
        out += ["", "### Time per token (ms)",
                table(rows, ["variant", "kind", "init ms", "E ms/tok", "E tok/s", "T ms/tok", "T first",
                             "T mid (8 avg)", "T last (8 avg)", "P ms/tok", "P vs E %", "probe est %"])]
        vs = lg.variants(m)
        names = []
        for v in vs:
            for k in lg.get("KERN", m=m, v=v):
                if k["k"] not in names:
                    names.append(k["k"])
        krow = []
        for name in names + ["gemv_all"]:
            row = [name]
            for v in vs:
                pr = lg.one("RUN", m=m, v=v, run="P")
                steps = pr["steps"] if pr else 1
                if name == "gemv_all":
                    ks = [k for k in lg.get("KERN", m=m, v=v) if k["k"] in GEMV]
                    calls = sum(k["calls"] for k in ks)
                    ticks = sum(k["ticks"] for k in ks)
                    if not ks:
                        row += ["-", "-", "-"]
                        continue
                else:
                    k = lg.one("KERN", m=m, v=v, k=name)
                    if not k:
                        row += ["-", "-", "-"]
                        continue
                    calls, ticks = k["calls"], k["ticks"]
                tot = float(pr["ticks"]) if pr else 1.0
                row += [f"{calls / steps:.1f}", f"{us(ticks, tps, steps):.2f}", f"{100.0 * ticks / tot:.2f}"]
            krow.append(row)
        head = ["kernel"]
        for v in vs:
            head += [f"{v} calls/tok", f"{v} us/tok", f"{v} %"]
        out += ["", "### Kernels (run P)", table(krow, head)]
        crow = [[r.get("v"), r.get("run"), r.get("n"), r.get("tok_mis"), r.get("hash_mis"), r.get("hash_req"),
                 r.get("self_mis"), r.get("result")] for r in lg.get("CHECK", m=m)]
        out += ["", "### Checks", table(crow, ["variant", "run", "n", "tok_mis", "hash_mis", "hash_req", "self_mis", "result"])]
        txt = lg.get("TXT", m=m)
        if txt:
            out += ["", "### Generated text (run E, first 200 printable bytes, spaces shown as _)"]
            out += [f"- {r['v']}: {r['s']}" for r in txt]
    return "\n".join(out)


def csv_rows(lg):
    tps = lg.tps()
    b = lg.one("BUILD") or {}
    for m in lg.models():
        for v in lg.variants(m):
            for run in ("E", "T", "P"):
                r = lg.one("RUN", m=m, v=v, run=run)
                if r:
                    yield [lg.path, b.get("opt"), b.get("neon"), m, v, f"_run{run}", "", r["steps"], r["ticks"],
                           f"{us(r['ticks'], tps, r['steps']):.3f}", ""]
            pr = lg.one("RUN", m=m, v=v, run="P")
            for k in lg.get("KERN", m=m, v=v):
                st = pr["steps"] if pr else 1
                tot = float(pr["ticks"]) if pr else 1.0
                yield [lg.path, b.get("opt"), b.get("neon"), m, v, k["k"], k["calls"], st, k["ticks"],
                       f"{us(k['ticks'], tps, st):.3f}", f"{100.0 * k['ticks'] / tot:.3f}"]


# ---------------------------------------------------------------- system program (LMSYS)
# KSPLIT categories (sx.h) -> KERN categories (prof.h): actq is split into head / output
SK2PC = {"actq_h": "actq", "actq_a": "actq"}
# mask bits (system.md 2.2) -> KSPLIT categories
BITS = [("G", 0x01, ("gemv_q", "gemv_k", "gemv_v", "gemv_o", "gemv_w1", "gemv_w2", "gemv_w3")),
        ("C", 0x02, ("gemv_cls",)), ("A", 0x04, ("attn",)), ("R", 0x08, ("rmsnorm",)),
        ("S", 0x10, ("swiglu",)), ("Qh", 0x20, ("actq_h",)), ("Qa", 0x40, ("actq_a",)),
        ("M", 0x80, ("argmax",))]


def runkey(r):
    return (r.get("m"), r.get("v"), r.get("run"), r.get("mask"), r.get("opt"))


def check_sys(lg):
    probs = []
    total = 0
    for m in lg.models():
        mis = 0
        data = lg.one("DATA", m=m)
        if data and data.get("status") == "absent":
            continue
        if data and data.get("status") == "corrupt":
            mis += 1
        for r in lg.get("VAR", m=m):
            mis += int(r.get("wmis", 0))
        for r in lg.get("PROMPT", m=m):
            mis += int(r.get("mis", 0))
        for r in lg.get("ROPE", m=m):
            if r.get("diff", 0) and not r.get("replaced", 0):
                mis += 1
        checks = lg.get("CHECK", m=m)
        mis += len([r for r in lg.get("RUN", m=m) if r.get("status")])  # runs stopped by a kernel error
        for r in checks:
            req = (int(r["tok_mis"]) + (int(r["hash_mis"]) if r.get("hash_req") else 0) + int(r["kmis"]) +
                   int(r["coh"]) + int(r["fb"]) + int(r["iperr"]))
            if (req == 0) != (r.get("result") == "PASS"):
                probs.append(f"CHECK {m} {r.get('run')} mask {r.get('mask'):#x}: result field disagrees")
            mis += r.get("result") != "PASS"
            key = runkey(r)
            kc = [k for k in lg.get("KCMP", m=m) if runkey(k) == key]
            if r.get("run") == "K" and sum(int(k["mis"]) for k in kc) != int(r["kmis"]):
                probs.append(f"{m} K mask {r.get('mask'):#x}: KCMP mis sum != CHECK kmis")
            ch = [c for c in lg.get("COH", m=m) if runkey(c) == key]
            if sum(int(c["n"]) for c in ch) != int(r["coh"]):
                probs.append(f"{m} {r.get('run')} mask {r.get('mask'):#x}: COH n != CHECK coh")
        for r in lg.get("RUN", m=m):
            if r.get("run") != "P":
                continue
            key = runkey(r)
            kern = [k for k in lg.get("KERN", m=m) if runkey(k) == key]
            ks = [k for k in lg.get("KSPLIT", m=m) if runkey(k) == key]
            if sum(int(k["ticks"]) for k in kern) != int(r["ticks"]):
                probs.append(f"{m} P mask {r.get('mask'):#x}: KERN ticks sum != RUN P ticks")
            byk = {}
            for k in ks:
                pc = SK2PC.get(k["k"], k["k"])
                byk[pc] = byk.get(pc, 0) + int(k["arm"]) + int(k["pl"]) + int(k["mv"]) + int(k["call"])
            kt = {k["k"]: int(k["ticks"]) for k in kern}
            for pc, v in byk.items():
                if v > kt.get(pc, 0):
                    probs.append(f"{m} P mask {r.get('mask'):#x}: KSPLIT {pc} {v} > KERN {kt.get(pc, 0)}")
        ms = lg.one("MSUM", m=m)
        if ms is None:
            probs.append(f"model {m}: no MSUM line")
        else:
            if ms["mismatches"] != mis:
                probs.append(f"model {m}: MSUM mismatches {ms['mismatches']} != recomputed {mis}")
            if int(ms.get("runs", -1)) != len(checks) + len([r for r in lg.get("RUN", m=m) if r.get("status")]):
                probs.append(f"model {m}: MSUM runs {ms.get('runs')} != CHECK lines {len(checks)}")
            if int(ms.get("skipped", -1)) != len(lg.get("SKIP", m=m)):
                probs.append(f"model {m}: MSUM skipped != SKIP lines")
        total += mis
    res = lg.one("RESULT")
    if res and res["mismatches"] != total:
        probs.append(f"RESULT mismatches {res['mismatches']} != recomputed {total}")
    return probs


def compared_sys(lg):
    n = 0
    for r in lg.get("CHECK"):
        n += int(r["n"]) * (1 + (1 if r.get("hash_req") else 0))
    n += sum(int(k["calls"]) for k in lg.get("KCMP"))
    n += sum(1 for r in lg.get("VAR"))
    n += sum(int(r.get("n_exp", 0)) for r in lg.get("PROMPT"))
    return n


def amdahl(lg, m, v):
    """system.md 4.2: S_ideal and S_cost of each mask from mask 0 (run P) and the single-bit
    runs P (KSPLIT), next to the measured run E. Returns table rows."""
    p0 = [r for r in lg.get("RUN", m=m, v=v, run="P") if r.get("mask") == 0]
    e0 = [r for r in lg.get("RUN", m=m, v=v, run="E") if r.get("mask") == 0]
    if not p0:
        return []
    p0 = p0[-1]
    tot = float(p0["ticks"])
    arm = {k["k"]: float(k["arm"]) for k in lg.get("KSPLIT", m=m, v=v) if runkey(k) == runkey(p0)}
    single = {}
    for name, bit, cats in BITS:
        rs = [r for r in lg.get("RUN", m=m, v=v, run="P") if r.get("mask") == bit and r.get("opt") == p0.get("opt")]
        if not rs:
            continue
        ks = [k for k in lg.get("KSPLIT", m=m, v=v) if runkey(k) == runkey(rs[-1]) and k["k"] in cats]
        pl = sum(float(k["pl"]) for k in ks)
        cost = sum(float(k["pl"]) + float(k["mv"]) + float(k["call"]) for k in ks)
        single[bit] = (cats, pl, cost)
    rows = []
    for r in lg.get("RUN", m=m, v=v, run="E"):
        mask = r.get("mask")
        if not mask or not e0:
            continue
        ideal = 1.0 - 0.0
        f_rest, f_acc, t_new, ok = 1.0, 0.0, tot, True
        for name, bit, cats in BITS:
            if not mask & bit:
                continue
            if bit not in single:
                ok = False
                break
            cats, pl, cost = single[bit]
            a = sum(arm.get(c, 0.0) for c in cats)
            f = a / tot
            f_rest -= f
            f_acc += f * (pl / a) if a > 0 else 0.0
            t_new += cost - a
        meas = float(e0[-1]["ticks"]) / float(r["ticks"])
        if ok:
            ideal = 1.0 / (f_rest + f_acc) if (f_rest + f_acc) > 0 else float("inf")
            scost = tot / t_new if t_new > 0 else float("inf")
            rows.append([f"{mask:#04x}", f"{r.get('opt'):#04x}", f"{ideal:.3f}", f"{scost:.3f}", f"{meas:.3f}",
                         f"{meas / scost:.3f}" if scost not in (0.0, float("inf")) else "-"])
        else:
            rows.append([f"{mask:#04x}", f"{r.get('opt'):#04x}", "-", "-", f"{meas:.3f}", "-"])
    return rows


def report_sys(lg):
    tps = lg.tps()
    out = [f"# {lg.path} (system program)"]
    b = lg.one("BUILD") or {}
    sysl = lg.one("SYS") or {}
    out.append(f"build: plat={b.get('plat')} hal={b.get('hal')} opt={b.get('opt')} cc={b.get('cc')}")
    out.append(f"PL build {sysl.get('build')}: ga={sysl.get('ga')} pi={sysl.get('pi')} at={sysl.get('at')} "
               f"ve={sysl.get('ve')} kv_src={sysl.get('kv_src')} h_par={sysl.get('h_par')} "
               f"fclk_mhz={sysl.get('fclk_mhz')} fclk_hz(build)={sysl.get('fclk_hz')}")
    if b.get("hal") == "host_model":
        out.append("NOTE: host_model log. Times are PC times, pl comes from the IP models' CYCLES "
                   "forms (latency 1), so call can be negative. Not a measurement.")
    for m in lg.models():
        out += ["", f"## Model {m}"]
        for r in lg.get("AVAIL", m=m):
            out.append(f"avail {r.get('avail'):#x} why={r.get('why')} rrec_bytes={r.get('rrec_bytes')} "
                       f"bank_words={r.get('bank_words')}")
        for r in lg.get("INIT", m=m):
            out.append(f"init {r.get('kind')}: {us(r['ticks'], tps) / 1000:.3f} ms, {r.get('bytes')} B"
                       + (f", PL cyc {r.get('cyc')}" if "cyc" in r else ""))
        vs = lg.variants(m)
        for v in vs:
            e0 = [r for r in lg.get("RUN", m=m, v=v, run="E") if r.get("mask") == 0]
            rows = []
            seen = []
            for r in lg.get("CHECK", m=m, v=v):
                key = (r.get("mask"), r.get("opt"))
                if key in seen:
                    continue
                seen.append(key)
                row = [f"{key[0]:#04x}", f"{key[1]:#04x}"]
                for run in ("E", "T", "P"):
                    x = [q for q in lg.get("RUN", m=m, v=v, run=run) if (q.get("mask"), q.get("opt")) == key]
                    row.append(f"{us(x[-1]['ticks'], tps, x[-1]['steps']) / 1000:.3f}" if x and "ticks" in x[-1] else "-")
                x = [q for q in lg.get("RUN", m=m, v=v, run="E") if (q.get("mask"), q.get("opt")) == key]
                row.append(f"{float(e0[-1]['ticks']) / float(x[-1]['ticks']):.3f}" if (x and e0) else "-")
                cs = [q for q in lg.get("CHECK", m=m, v=v) if (q.get("mask"), q.get("opt")) == key]
                row.append(" ".join(f"{q['run']}:{q['result']}" for q in cs))
                rows.append(row)
            out += ["", f"### {v}: time per token (ms) and checks",
                    table(rows, ["mask", "opt", "E", "T", "P", "E speed-up vs mask 0", "checks"])]
            for r in lg.get("RUN", m=m, v=v, run="P"):
                ks = [k for k in lg.get("KSPLIT", m=m, v=v) if runkey(k) == runkey(r)]
                if not ks or not r.get("mask"):
                    continue
                st = r["steps"]
                krow = [[k["k"], k["calls_ip"], k["calls_arm"], k["calls_fb"], k["ops"],
                         f"{us(k['arm'], tps, st):.2f}", f"{us(k['pl'], tps, st):.2f}", f"{us(k['mv'], tps, st):.2f}",
                         f"{us(k['call'], tps, st):.2f}", k["cyc"]] for k in ks]
                out += ["", f"#### KSPLIT mask {r.get('mask'):#04x} opt {r.get('opt'):#04x} (us/token)",
                        table(krow, ["k", "ip", "arm", "fb", "ops", "arm", "pl", "mv", "call", "PL cyc"])]
            am = amdahl(lg, m, v)
            if am:
                out += ["", f"### {v}: Amdahl estimate (system.md 4.2) vs measured run E",
                        table(am, ["mask", "opt", "S_ideal", "S_cost", "measured", "measured/S_cost"])]
        kc = [k for k in lg.get("KCMP", m=m) if int(k["mis"])]
        if kc:
            out += ["", "### KCMP mismatches",
                    table([[f"{k['mask']:#04x}", k["k"], k["mis"], k["first_pos"], k["first_call"], k["first_idx"],
                            k["exp"], k["got"]] for k in kc],
                          ["mask", "k", "mis", "pos", "call", "idx", "exp", "got"])]
        for c in lg.get("COH", m=m):
            out.append(f"COH {c.get('run')} mask {c.get('mask'):#04x}: n={c.get('n')} old={c.get('old')} "
                       f"{c.get('kind')} {c.get('what')} at {c.get('k')} pos {c.get('pos')}")
        for c in lg.get("IPERR", m=m):
            out.append(f"IPERR {c.get('run')} mask {c.get('mask'):#04x}: {c.get('ip')} {c.get('kind')} "
                       f"err={c.get('err'):#x} pos {c.get('pos')}")
    return "\n".join(out)


def csv_rows_sys(lg):
    tps = lg.tps()
    b = lg.one("BUILD") or {}
    s = lg.one("SYS") or {}
    for r in lg.get("RUN"):
        if "ticks" not in r:
            continue
        yield [lg.path, b.get("opt"), s.get("build"), r.get("m"), r.get("v"), r.get("run"), f"{r.get('mask'):#04x}",
               f"{r.get('opt'):#04x}", "_run", r["steps"], r["ticks"], "", "", "", "",
               f"{us(r['ticks'], tps, r['steps']):.3f}"]
    for k in lg.get("KSPLIT"):
        yield [lg.path, b.get("opt"), s.get("build"), k.get("m"), k.get("v"), k.get("run"), f"{k.get('mask'):#04x}",
               f"{k.get('opt'):#04x}", k["k"], "", k["arm"], k["pl"], k["mv"], k["call"], k["cyc"], ""]


def main(argv):
    csv_out = pos_out = None
    files = []
    i = 0
    while i < len(argv):
        if argv[i] == "--csv":
            csv_out = argv[i + 1]
            i += 2
        elif argv[i] == "--pos-csv":
            pos_out = argv[i + 1]
            i += 2
        else:
            files.append(argv[i])
            i += 1
    if not files:
        raise SystemExit(__doc__)
    worst = 0
    logs = []
    for f in files:
        lg = Log(f)
        st, probs = status(lg)
        logs.append(lg)
        if csv_out is None and pos_out is None:
            print(report_sys(lg) if lg.prog == "sys" else report(lg))
            print()
        for p in probs:
            print(f"PROBLEM {f}: {p}")
        res = lg.one("RESULT") or {}
        print(f"PARSE file={f} result={st} compared={compared(lg)} mismatches={res.get('mismatches', '-')} "
              f"errors={res.get('errors', '-')} "
              f"models_run={res.get('models_run', '-')} models_skipped={res.get('models_skipped', '-')}")
        worst = max(worst, {"PASS": 0, "FAIL": 1}.get(st, 2))
    if csv_out:
        with open(csv_out, "w", newline="") as fh:
            w = csv.writer(fh)
            if logs and logs[0].prog == "sys":
                w.writerow(["log", "opt", "build", "model", "variant", "run", "mask", "mask_opt", "kernel",
                            "steps", "ticks_or_arm", "pl", "mv", "call", "cyc", "us_per_token"])
            else:
                w.writerow(["log", "opt", "neon", "model", "variant", "kernel", "calls", "steps", "ticks",
                            "us_per_token", "pct_of_P"])
            n = 0
            for lg in logs:
                for row in (csv_rows_sys(lg) if lg.prog == "sys" else csv_rows(lg)):
                    w.writerow(row)
                    n += 1
        print(f"CSV rows={n} file={csv_out}")
    if pos_out:
        with open(pos_out, "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(["log", "model", "variant", "pos", "ticks", "us"])
            n = 0
            for lg in logs:
                tps = lg.tps()
                for r in lg.get("POS"):
                    w.writerow([lg.path, r["m"], r["v"], r["pos"], r["ticks"], f"{us(r['ticks'], tps):.3f}"])
                    n += 1
        print(f"POSCSV rows={n} file={pos_out}")
    return worst


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
