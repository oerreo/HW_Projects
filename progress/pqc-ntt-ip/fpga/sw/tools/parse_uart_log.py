#!/usr/bin/env python3
"""Parse the UART log of the PS test program (fpga/sw/main.c) into a table.

Usage:
  parse_uart_log.py LOG [LOG ...]            Markdown table per log
  parse_uart_log.py --csv LOG [LOG ...]      one CSV row per (log, op)

Log format (fpga/README.md, "UART output"): one item per line,
"KEY k=v k=v ...", between "PQCNTT BEGIN" and "PQCNTT END". Lines outside
that block (boot messages) and carriage returns are ignored. If the log
holds several runs, the last complete one is used.

The parser recomputes every SUMMARY from the CASE / CHECK lines and checks
that they agree with the program's own counts.

Exit code (worst over all logs): 0 PASS, 1 FAIL, 2 INCOMPLETE (no END /
RESULT, missing section, or counts that do not add up).
"""

import argparse
import csv
import os
import sys

OPS = ["CHECK", "NTT", "INTT", "BASEMUL", "POLYMUL"]
RC = {"PASS": 0, "FAIL": 1, "INCOMPLETE": 2}


def kv(line):
    """'KEY a=1 b=x' -> ('KEY', {'a': '1', 'b': 'x'}). 'RESULT: PASS' special."""
    if line.startswith("RESULT:"):
        return "RESULT", {"value": line.split(":", 1)[1].strip()}
    parts = line.split()
    d = {}
    for p in parts[1:]:
        if "=" in p:
            k, v = p.split("=", 1)
            d[k] = v
    return parts[0], d


def split_runs(lines):
    runs, cur = [], None
    for raw in lines:
        line = raw.replace("\r", "").strip()
        if line.startswith("PQCNTT BEGIN"):
            cur = []
            runs.append(cur)
            continue
        if cur is not None and line:
            cur.append(line)
    return runs


def parse_run(lines):
    r = {"version": None, "expect": {}, "cases": [], "mismatch": [], "summary": {},
         "checks": [], "abort": [], "result": None, "end": False, "info": {}}
    for line in lines:
        key, d = kv(line)
        if key == "VERSION":
            r["version"] = d
        elif key == "EXPECT":
            r["expect"][d.get("op")] = int(d.get("cycles", "0"))
        elif key == "CASE":
            r["cases"].append(d)
        elif key == "MISMATCH":
            r["mismatch"].append(d)
        elif key == "SUMMARY":
            r["summary"][d.get("op")] = d
        elif key == "CHECK":
            r["checks"].append(d)
        elif key == "ABORT":
            r["abort"].append(d)
        elif key == "INFO":
            r["info"].update(d)
        elif key == "RESULT":
            r["result"] = d["value"]
        elif key == "PQCNTT" and line.startswith("PQCNTT END"):
            r["end"] = True
    return r


def evaluate(r):
    """Return (status, problems, rows). rows: per-op recomputed counts."""
    problems = []
    rows = []
    if not r["end"] or r["result"] not in ("PASS", "FAIL"):
        problems.append("log incomplete: missing RESULT or PQCNTT END")
    aborted = bool(r["abort"])
    if r["version"] is None:
        problems.append("no VERSION line")
    for op in OPS:
        s = r["summary"].get(op)
        if op == "CHECK":
            lines = r["checks"]
            cases = len(lines)
            fail = sum(1 for c in lines if c.get("result") != "PASS")
            mism = cyc_bad = errs = 0
            cyc = set()
        else:
            lines = [c for c in r["cases"] if c.get("op") == op]
            cases = len(lines)
            errs = sum(1 for c in lines if c.get("rc") != "OK")
            mism = sum(int(c.get("mismatch", "0")) for c in lines if c.get("rc") == "OK")
            cyc_bad = sum(1 for c in lines if c.get("rc") == "OK" and c.get("cycles_ok") != "1")
            fail = sum(1 for c in lines if c.get("rc") != "OK" or c.get("mismatch") != "0"
                       or c.get("cycles_ok") != "1")
            cyc = {int(c["cycles"]) for c in lines if c.get("rc") == "OK"}
        row = {"op": op, "cases": cases, "fail_cases": fail, "mismatch": mism,
               "cycle_bad": cyc_bad, "errors": errs,
               "exp_cycles": r["expect"].get(op, ""),
               "cycles_seen": " ".join(str(x) for x in sorted(cyc)),
               "result": "PASS" if (cases > 0 and fail == 0) else "FAIL"}
        rows.append(row)
        if s is None:
            if not aborted:
                problems.append("no SUMMARY for %s" % op)
            continue
        for k in ("cases", "fail_cases", "mismatch", "cycle_bad", "errors"):
            if int(s.get(k, "-1")) != row[k]:
                problems.append("SUMMARY %s %s=%s but lines give %d" % (op, k, s.get(k), row[k]))
        if s.get("result") != row["result"]:
            problems.append("SUMMARY %s result=%s but lines give %s" % (op, s.get("result"), row["result"]))
    derived_pass = (not aborted and r["version"] is not None and r["version"].get("id_ok") == "1"
                    and all(x["result"] == "PASS" for x in rows))
    if problems:
        return "INCOMPLETE", problems, rows
    if r["result"] == "PASS" and not derived_pass:
        problems.append("RESULT: PASS but the lines do not support it")
        return "INCOMPLETE", problems, rows
    if r["result"] == "FAIL" and derived_pass:
        problems.append("RESULT: FAIL but every section passed")
        return "INCOMPLETE", problems, rows
    return ("PASS" if derived_pass else "FAIL"), problems, rows


def markdown(name, r, status, problems, rows, nruns):
    out = ["## %s" % name, ""]
    v = r["version"] or {}
    out.append("- status: **%s** (RESULT line: %s)" % (status, r["result"]))
    out.append("- VERSION: raw=%s id=%s id_ok=%s ALGO=%s (%s) BFU_LATENCY=%s" %
               (v.get("raw"), v.get("id"), v.get("id_ok"), v.get("algo"), v.get("algo_name"),
                v.get("bfu_latency")))
    if nruns > 1:
        out.append("- note: %d runs in the log, the last one is shown" % nruns)
    for a in r["abort"]:
        out.append("- ABORT: %s" % " ".join("%s=%s" % kv_ for kv_ in a.items()))
    out.append("")
    out.append("| op | cases | fail cases | coef mismatch | cycle mismatch | driver errors | expected cycles | observed cycles | result |")
    out.append("|---|---|---|---|---|---|---|---|---|")
    for x in rows:
        out.append("| %s | %d | %d | %d | %d | %d | %s | %s | %s |" %
                   (x["op"], x["cases"], x["fail_cases"], x["mismatch"], x["cycle_bad"],
                    x["errors"], x["exp_cycles"], x["cycles_seen"], x["result"]))
    bad_checks = [c for c in r["checks"] if c.get("result") != "PASS"]
    if bad_checks:
        out.append("")
        out.append("Failed register checks: " + ", ".join("%s (val=%s)" % (c.get("name"), c.get("val"))
                                                        for c in bad_checks))
    bad_cases = [c for c in r["cases"] if c.get("rc") != "OK" or c.get("mismatch") != "0"
                 or c.get("cycles_ok") != "1"]
    if bad_cases:
        out.append("")
        out.append("Failed cases (first 20):")
        out.append("")
        for c in bad_cases[:20]:
            out.append("- %s idx=%s name=%s rc=%s mismatch=%s cycles=%s exp=%s" %
                       (c.get("op"), c.get("idx"), c.get("name"), c.get("rc"), c.get("mismatch"),
                        c.get("cycles"), c.get("exp_cycles")))
    if r["mismatch"]:
        out.append("")
        out.append("First coefficient mismatches:")
        out.append("")
        for m in r["mismatch"][:20]:
            out.append("- %s idx=%s coef=%s exp=%s got=%s" %
                       (m.get("op"), m.get("idx"), m.get("coef"), m.get("exp"), m.get("got")))
    if problems:
        out.append("")
        out.append("Parser problems:")
        out.append("")
        out.extend("- " + p for p in problems)
    out.append("")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description="UART log of fpga/sw/main.c to a result table")
    ap.add_argument("logs", nargs="+")
    ap.add_argument("--csv", action="store_true", help="CSV rows instead of Markdown")
    a = ap.parse_args()
    worst = 0
    writer = csv.writer(sys.stdout) if a.csv else None
    if writer:
        writer.writerow(["log", "status", "algo", "bfu_latency", "op", "cases", "fail_cases",
                         "mismatch", "cycle_bad", "errors", "exp_cycles", "cycles_seen", "result"])
    for path in a.logs:
        with open(path, errors="replace") as f:
            runs = split_runs(f.readlines())
        name = os.path.basename(path)
        if not runs:
            status, problems, rows, r = "INCOMPLETE", ["no 'PQCNTT BEGIN' line"], [], parse_run([])
        else:
            r = parse_run(runs[-1])
            status, problems, rows = evaluate(r)
        worst = max(worst, RC[status])
        v = r["version"] or {}
        if writer:
            for x in rows:
                writer.writerow([name, status, v.get("algo_name"), v.get("bfu_latency"), x["op"],
                                 x["cases"], x["fail_cases"], x["mismatch"], x["cycle_bad"],
                                 x["errors"], x["exp_cycles"], x["cycles_seen"], x["result"]])
        else:
            print(markdown(name, r, status, problems, rows, len(runs)))
    return worst


if __name__ == "__main__":
    sys.exit(main())
