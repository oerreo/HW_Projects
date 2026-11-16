#!/usr/bin/env python3
"""Build docs/viewer/ntt_player.html from golden-model traces.

Steps
  1. Read model/vectors/manifest.txt (trace case, boundary case numbers).
  2. Build and run tools/dump_viewer_trace.cpp (g++, single process). It writes
     traces in the model's own text format for the "random" and "simple"
     inputs plus aux.json (ROMs, constants, bfu internals, reference outputs).
  3. Check that the dumped random-input traces equal model/vectors/hw_*_trace.
  4. Parse the traces, pack them (shared schedule, value pool with
     de-duplication) and embed the JSON into tools/template.html.

No modular arithmetic is done here: every value comes from a trace or from
aux.json written by the model. Python only parses, compares and packs.

usage: python3 build_viewer.py [--model DIR] [--out FILE] [--no-dump]
"""
import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
VIEWER = os.path.dirname(HERE)
PROJECT = os.path.dirname(os.path.dirname(VIEWER))
BUILD = os.path.join(HERE, "build")
DUMP_DIR = os.path.join(BUILD, "dump")
DUMP_BIN = os.path.join(BUILD, "dump_viewer_trace")
DUMP_SRC = os.path.join(HERE, "dump_viewer_trace.cpp")

ALGOS = ["barrett", "mont12", "shiftadd", "k2red"]
OPS = ["ntt", "intt", "basemul"]
INPUTS = ["random", "simple"]
PLACEHOLDER = "/*__TRACE_DATA__*/"

# Display text of the basemul programs, keyed by the program signature from
# the model (src/dst names). The builder refuses unknown programs.
PROGRAM_TEXT = {
    "ZERO,A1,B1,R0|ZERO,R0,GAMMA,R0|R0,A0,B0,C0|ZERO,A0,B1,R0|R0,A1,B0,C1": [
        "t = a1*b1",
        "p = t*gamma = a1*b1*gamma",
        "c0 = p + a0*b0",
        "u = a0*b1",
        "c1 = u + a1*b0",
    ],
    "ZERO,A1,B1,R0|ZERO,R0,GAMMA,R0|ZERO,A0,B0,R1|R0,R1,K2,C0|ZERO,A0,B1,R0|R0,A1,B0,R0|ZERO,R0,K2,C1": [
        "t = a1*b1*S",
        "p = t*(gamma*S^-2)*S = a1*b1*gamma",
        "v = a0*b0*S",
        "c0 = p + v*K2*S = a1*b1*gamma + a0*b0",
        "u = a0*b1*S",
        "w = u + a1*b0*S = (a0*b1 + a1*b0)*S",
        "c1 = w*K2*S = a0*b1 + a1*b0",
    ],
}


def die(msg):
    sys.stderr.write("build_viewer: ERROR: " + msg + "\n")
    sys.exit(1)


def read_manifest(vec):
    cases = {}
    trace_case = None
    seed = None
    with open(os.path.join(vec, "manifest.txt")) as f:
        for line in f:
            p = line.split()
            if not p:
                continue
            if p[0] == "trace_case":
                trace_case = int(p[1])
            elif p[0] == "seed":
                seed = int(p[1])
            elif p[0] == "case":
                cases[p[2]] = int(p[1])
    if trace_case is None:
        die("manifest has no trace_case")
    for need in ("impulse_1_at_0", "all_one"):
        if need not in cases:
            die("manifest has no case " + need)
    name_of = {v: k for k, v in cases.items()}
    return {"seed": seed, "trace_case": trace_case, "trace_name": name_of[trace_case],
            "impulse": cases["impulse_1_at_0"], "all_one": cases["all_one"]}


def run_dump(model, vec, man):
    os.makedirs(DUMP_DIR, exist_ok=True)
    srcs = [DUMP_SRC, os.path.join(model, "src", "mlkem_ntt.cpp")]
    inc = os.path.join(model, "include")
    deps = srcs + [os.path.join(inc, n) for n in os.listdir(inc)]
    if not os.path.exists(DUMP_BIN) or any(os.path.getmtime(d) > os.path.getmtime(DUMP_BIN) for d in deps):
        cmd = ["g++", "-std=c++17", "-O2", "-Wall", "-Wextra", "-I" + inc] + srcs + ["-o", DUMP_BIN]
        print("build_viewer: " + " ".join(cmd))
        subprocess.run(cmd, check=True)
    cmd = [DUMP_BIN, "--vec", vec, "--out", DUMP_DIR,
           "--random-case", str(man["trace_case"]),
           "--simple-tr-case", str(man["impulse"]),
           "--simple-mul-a-case", str(man["all_one"]),
           "--simple-mul-b-case", str(man["all_one"])]
    print("build_viewer: " + " ".join(cmd))
    subprocess.run(cmd, check=True)


def trace_lines(path):
    with open(path) as f:
        return [ln.split() for ln in f if ln.strip() and not ln.startswith("//")]


def trace_path(vec, op, inp, algo):
    """Source trace of (op, input, algo). The random input uses the model's own
    vector files, the simple input uses the dump program output."""
    if inp == "random":
        return os.path.join(vec, "hw_%s_trace_%s.txt" % (op, algo))
    return os.path.join(DUMP_DIR, "trace_%s_%s_%s.txt" % (op, inp, algo))


def parse_bfu_trace(path):
    """layer step len rd_bank wr_bank addr0 addr1 zeta_addr mode a b z x y"""
    cols = {k: [] for k in ("layer", "step", "len", "rd", "wr", "addr0", "addr1", "zaddr", "mode",
                            "a", "b", "z", "x", "y")}
    for p in trace_lines(path):
        if len(p) != 14:
            die("bad bfu trace line in %s: %s" % (path, p))
        for i, k in enumerate(("layer", "step", "len", "rd", "wr", "addr0", "addr1", "zaddr", "mode")):
            cols[k].append(int(p[i]))
        for i, k in enumerate(("a", "b", "z", "x", "y")):
            cols[k].append(int(p[9 + i], 16))
    return cols


def parse_basemul_trace(path):
    """pair op a_src b_src z_src dst a b z x"""
    cols = {k: [] for k in ("pair", "op", "a_src", "b_src", "z_src", "dst", "a", "b", "z", "x")}
    for p in trace_lines(path):
        if len(p) != 10:
            die("bad basemul trace line in %s: %s" % (path, p))
        cols["pair"].append(int(p[0]))
        cols["op"].append(int(p[1]))
        for i, k in enumerate(("a_src", "b_src", "z_src", "dst")):
            cols[k].append(p[2 + i])
        for i, k in enumerate(("a", "b", "z", "x")):
            cols[k].append(int(p[6 + i], 16))
    return cols


def hex3(vals):
    for v in vals:
        if not 0 <= v < 4096:
            die("value out of 12-bit range: %d" % v)
    return "".join("%03x" % v for v in vals)


class Pool:
    """Hex3-encoded value arrays, stored once and referenced by index."""

    def __init__(self):
        self.items = []
        self.index = {}
        self.refs = 0

    def ref(self, vals):
        s = hex3(vals)
        self.refs += 1
        if s not in self.index:
            self.index[s] = len(self.items)
            self.items.append(s)
        return self.index[s]


def build_data(vec, man):
    with open(os.path.join(DUMP_DIR, "aux.json")) as f:
        aux = json.load(f)
    pool = Pool()
    share_log = []

    # Algorithm constants and ROMs (from the model via aux.json).
    algos = []
    for i, an in enumerate(ALGOS):
        a = aux["algos"][i]
        if a["name"] != an:
            die("aux algo order")
        sig = "|".join(",".join(op) for op in a["program"])
        if sig not in PROGRAM_TEXT:
            die("unknown basemul program for %s: %s" % (an, sig))
        algos.append({"name": an, "S": a["S"], "S_inv": a["S_inv"], "S_inv2": a["S_inv2"], "K2": a["K2"],
                      "zeta_rom": pool.ref(a["zeta_rom"]), "gamma_rom": pool.ref(a["gamma_rom"]),
                      "program": a["program"], "program_text": PROGRAM_TEXT[sig]})

    # Schedules: data independent, must be identical for every input and ALGO.
    sched = {}
    for op in ("ntt", "intt"):
        ref = None
        for inp in INPUTS:
            for an in ALGOS:
                c = parse_bfu_trace(trace_path(vec, op, inp, an))
                key = {k: c[k] for k in ("layer", "len", "rd", "wr", "addr0", "addr1", "zaddr", "mode")}
                if ref is None:
                    ref = key
                elif key != ref:
                    die("schedule of %s differs between traces (%s %s)" % (op, inp, an))
        if len(ref["layer"]) != 896:
            die("%s trace has %d steps, expected 896" % (op, len(ref["layer"])))
        sched[op] = ref
    share_log.append("schedule (layer len rd wr addr0 addr1 zeta_addr mode): 1 copy per op, "
                     "identical over 2 inputs x 4 ALGO")

    inputs = {}
    for inp in INPUTS:
        ax = aux["inputs"][inp]
        d = {"banks_init": {}, "expected": {}, "runs": {}}
        d["banks_init"]["ntt"] = [pool.ref(ax["f"]), pool.ref([0] * 256)]
        d["banks_init"]["intt"] = d["banks_init"]["ntt"]
        d["banks_init"]["basemul"] = [pool.ref(ax["mul_a"]), pool.ref(ax["mul_b"])]
        d["expected"] = {"ntt": pool.ref(ax["ref_ntt"]), "intt": pool.ref(ax["ref_intt"]),
                         "basemul": pool.ref(ax["ref_basemul"])}
        for op in OPS:
            runs = {}
            for an in ALGOS:
                path = trace_path(vec, op, inp, an)
                it = ax["internals"][an]
                if op == "basemul":
                    c = parse_basemul_trace(path)
                    prog = algos[ALGOS.index(an)]["program"]
                    n = len(c["op"])
                    if n != 128 * len(prog):
                        die("basemul %s %s: %d ops" % (inp, an, n))
                    for i in range(n):
                        if c["pair"][i] != i // len(prog) or c["op"][i] != i % len(prog):
                            die("basemul order %s %s line %d" % (inp, an, i))
                        if [c["a_src"][i], c["b_src"][i], c["z_src"][i], c["dst"][i]] != prog[c["op"][i]]:
                            die("basemul src/dst differ from program %s %s line %d" % (inp, an, i))
                    fields = {"a": c["a"], "b": c["b"], "z": c["z"], "x": c["x"], "t": it["basemul_t"]}
                else:
                    c = parse_bfu_trace(path)
                    fields = {"a": c["a"], "b": c["b"], "z": c["z"], "x": c["x"], "y": c["y"]}
                    if op == "ntt":
                        fields["t"] = it["ntt_t"]
                    else:
                        fields["s"] = it["intt_s"]
                        fields["d"] = it["intt_d"]
                        fields["m"] = it["intt_m"]
                runs[an] = {k: pool.ref(v) for k, v in fields.items()}
            inputs_runs = runs
            # Report which fields are shared over the 4 ALGO.
            shared = [k for k in inputs_runs["barrett"]
                      if len({inputs_runs[a][k] for a in ALGOS}) == 1]
            per = [k for k in inputs_runs["barrett"] if k not in shared]
            share_log.append("%s/%s: same for all 4 ALGO: %s; differs per ALGO: %s" %
                             (inp, op, " ".join(shared) or "-", " ".join(per) or "-"))
            d["runs"][op] = runs
        inputs[inp] = d

    tc, tn = man["trace_case"], man["trace_name"]
    meta_inputs = {
        "random": {"label": "random (%s)" % tn,
                   "desc": {"ntt": "model/vectors case %d (%s, seed %s)" % (tc, tn, man["seed"]),
                            "intt": "model/vectors case %d (%s, seed %s)" % (tc, tn, man["seed"]),
                            "basemul": "mul_a, mul_b case %d (%s, seed %s)" % (tc, tn, man["seed"])}},
        "simple": {"label": "simple (impulse / all_one)",
                   "desc": {"ntt": "case %d impulse_1_at_0: f[0] = 1" % man["impulse"],
                            "intt": "case %d impulse_1_at_0: f_hat[0] = 1" % man["impulse"],
                            "basemul": "a = b = case %d all_one" % man["all_one"]}},
    }
    data = {
        "format": 1,
        "q": aux["q"],
        "zeta_table": pool.ref(aux["zeta_table"]),
        "gamma_table": pool.ref(aux["gamma_table"]),
        "bitrev7": aux["bitrev7"],
        "algos": algos,
        "sched": sched,
        "inputs": inputs,
        "input_meta": meta_inputs,
        "pool": pool.items,
    }
    share_log.append("value pool: %d references, %d unique arrays" % (pool.refs, len(pool.items)))
    return data, share_log


def check_dump_matches_vectors(vec):
    n = 0
    for op in OPS:
        for an in ALGOS:
            a = trace_lines(os.path.join(vec, "hw_%s_trace_%s.txt" % (op, an)))
            b = trace_lines(os.path.join(DUMP_DIR, "trace_%s_random_%s.txt" % (op, an)))
            if a != b:
                die("dump program trace differs from model/vectors for %s %s" % (op, an))
            n += 1
    print("build_viewer: dump traces == model/vectors traces for random input (%d files)" % n)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=os.path.join(PROJECT, "model"))
    ap.add_argument("--out", default=os.path.join(VIEWER, "ntt_player.html"))
    ap.add_argument("--no-dump", action="store_true", help="reuse tools/build/dump")
    args = ap.parse_args()
    vec = os.path.join(args.model, "vectors")
    man = read_manifest(vec)
    if not args.no_dump:
        run_dump(args.model, vec, man)
    check_dump_matches_vectors(vec)
    data, share_log = build_data(vec, man)
    js = json.dumps(data, separators=(",", ":"))
    if "</" in js:
        die("JSON contains '</'")
    with open(os.path.join(HERE, "template.html")) as f:
        tpl = f.read()
    if tpl.count(PLACEHOLDER) != 1:
        die("template placeholder count")
    html = tpl.replace(PLACEHOLDER, js)
    with open(args.out, "w") as f:
        f.write(html)
    for s in share_log:
        print("build_viewer: share: " + s)
    print("build_viewer: wrote %s (%d bytes, JSON %d bytes)" % (args.out, len(html.encode()), len(js)))


if __name__ == "__main__":
    main()
