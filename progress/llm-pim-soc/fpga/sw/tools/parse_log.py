#!/usr/bin/env python3
"""Parse the UART log of the ARM baseline program (fpga/sw) into tables and CSV.

    python3 -I parse_log.py uart.log                     # Markdown tables to stdout
    python3 -I parse_log.py --csv k.csv a.log b.log      # kernel/run rows of several logs
    python3 -I parse_log.py --pos-csv p.csv uart.log     # per-token times (run T)

Only the last "LMBASE BEGIN" .. "LMBASE END" block of each file is read; boot
messages, CR characters and other lines are ignored. The parser recomputes the
mismatch sums from the CHECK/VAR/PROMPT/DATA lines and the kernel time sums from
the KERN lines and compares them with the program's MSUM/RESULT/RUN lines.

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
        lines = open(path, "rb").read().decode("utf-8", "replace").replace("\r", "").split("\n")
        start = None
        for i, ln in enumerate(lines):
            if ln.startswith("LMBASE BEGIN"):
                start = i
        if start is None:
            return
        self.begin = True
        for ln in lines[start + 1:]:
            if ln.startswith("LMBASE END"):
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
    probs = check_sums(lg)
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
            print(report(lg))
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
            w.writerow(["log", "opt", "neon", "model", "variant", "kernel", "calls", "steps", "ticks",
                        "us_per_token", "pct_of_P"])
            n = 0
            for lg in logs:
                for row in csv_rows(lg):
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
