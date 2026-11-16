#!/usr/bin/env python3
"""Self check of docs/viewer/ntt_player.html.

  1. Embedded JSON vs the source traces (every field of every step), step counts.
  2. Independent replay of the raw text traces in Python: reads must match the
     bank state, layer-end states must equal the model's reference layers
     (aux.json), the final state must equal the golden output files.
     The per-position bank state and "written in scope" mask are hashed and
     written to build/check_expected.json.
  3. tools/check_engine.mjs (Node) runs the viewer's own engine script from
     the HTML and compares stateAt / writtenAt at every position with those
     hashes (skipped with a message if node is missing).
  4. No external URL / resource reference in the HTML.

usage: python3 check_viewer.py [--html FILE] [--model DIR]
Exit status 0 only if every check passes.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import build_viewer as bv  # noqa: E402

stats = {}
fails = []


def check(group, cond, msg):
    stats[group] = stats.get(group, 0) + 1
    if not cond:
        fails.append("%s: %s" % (group, msg))
        if len(fails) < 30:
            print("FAIL " + group + ": " + msg)


def extract_json(html):
    m = re.search(r'<script type="application/json" id="trace-data">(.*?)</script>', html, re.S)
    return json.loads(m.group(1))


def decode(d, idx):
    s = d["pool"][idx]
    return [int(s[i:i + 3], 16) for i in range(0, len(s), 3)]


def read_hex_case(path, c):
    with open(path) as f:
        lines = f.read().split()
    return [int(x, 16) for x in lines[c * 256:(c + 1) * 256]]


def h(state):
    return hashlib.sha256(struct.pack("<512H", *state)).hexdigest()[:16]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--html", default=os.path.join(bv.VIEWER, "ntt_player.html"))
    ap.add_argument("--model", default=os.path.join(bv.PROJECT, "model"))
    args = ap.parse_args()
    vec = os.path.join(args.model, "vectors")
    man = bv.read_manifest(vec)
    with open(args.html) as f:
        html = f.read()
    d = extract_json(html)
    with open(os.path.join(bv.DUMP_DIR, "aux.json")) as f:
        aux = json.load(f)

    # Sources of the inputs and golden outputs, independent of the JSON.
    tc = man["trace_case"]
    src_in = {
        "random": {"f": read_hex_case(os.path.join(vec, "ntt_in.hex"), tc),
                   "ma": read_hex_case(os.path.join(vec, "mul_a.hex"), tc),
                   "mb": read_hex_case(os.path.join(vec, "mul_b.hex"), tc)},
        "simple": {"f": read_hex_case(os.path.join(vec, "ntt_in.hex"), man["impulse"]),
                   "ma": read_hex_case(os.path.join(vec, "ntt_in.hex"), man["all_one"]),
                   "mb": read_hex_case(os.path.join(vec, "ntt_in.hex"), man["all_one"])},
    }
    golden = {
        "random": {"ntt": read_hex_case(os.path.join(vec, "ntt_out.hex"), tc),
                   "intt": read_hex_case(os.path.join(vec, "intt_out.hex"), tc),
                   "basemul": read_hex_case(os.path.join(vec, "mul_out.hex"), tc)},
        "simple": {"ntt": read_hex_case(os.path.join(vec, "ntt_out.hex"), man["impulse"]),
                   "intt": read_hex_case(os.path.join(vec, "intt_out.hex"), man["impulse"]),
                   # no golden file for a = b = all_one; use the model reference multiply_ntts
                   "basemul": aux["inputs"]["simple"]["ref_basemul"]},
    }

    expected = {}
    for inp in bv.INPUTS:
        din = d["inputs"][inp]
        ax = aux["inputs"][inp]
        # inputs embedded == source files
        check("json", decode(d, din["banks_init"]["ntt"][0]) == src_in[inp]["f"], inp + " NTT input")
        check("json", decode(d, din["banks_init"]["ntt"][1]) == [0] * 256, inp + " bank1 zero")
        check("json", decode(d, din["banks_init"]["basemul"][0]) == src_in[inp]["ma"], inp + " basemul a")
        check("json", decode(d, din["banks_init"]["basemul"][1]) == src_in[inp]["mb"], inp + " basemul b")
        for op in bv.OPS:
            check("json", decode(d, din["expected"][op]) == golden[inp][op], "%s %s expected output" % (inp, op))
            for ai, an in enumerate(bv.ALGOS):
                path = bv.trace_path(vec, op, inp, an)
                runs = din["runs"][op][an]
                fld = {k: decode(d, v) for k, v in runs.items()}
                it = ax["internals"][an]
                alg = d["algos"][ai]
                # ROM / constants vs model vector files
                zr = [int(x, 16) for x in open(os.path.join(vec, "rom_zeta_%s.hex" % an)).read().split()]
                gr = [int(x, 16) for x in open(os.path.join(vec, "rom_gamma_%s.hex" % an)).read().split()]
                k2 = int(open(os.path.join(vec, "rom_k2_%s.hex" % an)).read().split()[0], 16)
                check("json", decode(d, alg["zeta_rom"]) == zr, an + " zeta ROM")
                check("json", decode(d, alg["gamma_rom"]) == gr, an + " gamma ROM")
                check("json", alg["K2"] == k2, an + " K2")
                if op == "basemul":
                    c = bv.parse_basemul_trace(path)
                    n = len(c["op"])
                    want_n = 640 if alg["S"] == 1 else 896
                    check("count", n == want_n and len(fld["x"]) == want_n,
                          "%s %s %s: %d steps, expected %d" % (inp, op, an, n, want_n))
                    for k in ("a", "b", "z", "x"):
                        check("json", fld[k] == c[k], "%s %s %s field %s" % (inp, op, an, k))
                    check("json", fld["t"] == it["basemul_t"], "%s basemul %s t" % (inp, an))
                    nops = len(alg["program"])
                    for i in range(n):
                        check("json", [c["a_src"][i], c["b_src"][i], c["z_src"][i], c["dst"][i]] ==
                              alg["program"][i % nops] and c["pair"][i] == i // nops,
                              "%s basemul %s src/dst line %d" % (inp, an, i))
                else:
                    c = bv.parse_bfu_trace(path)
                    n = len(c["a"])
                    check("count", n == 896 and len(fld["x"]) == 896, "%s %s %s: %d steps" % (inp, op, an, n))
                    s = d["sched"][op]
                    for k in ("layer", "len", "rd", "wr", "addr0", "addr1", "zaddr", "mode"):
                        check("json", s[k] == c[k], "%s %s %s sched %s" % (inp, op, an, k))
                    for k in ("a", "b", "z", "x", "y"):
                        check("json", fld[k] == c[k], "%s %s %s field %s" % (inp, op, an, k))
                    for i in range(n):
                        check("json", c["z"][i] == zr[c["zaddr"][i]], "%s %s %s z == ROM[zaddr] %d" % (inp, op, an, i))
                    if op == "ntt":
                        check("json", fld["t"] == it["ntt_t"], "%s ntt %s t" % (inp, an))
                    else:
                        for k in ("s", "d", "m"):
                            check("json", fld[k] == it["intt_" + k], "%s intt %s %s" % (inp, an, k))

                # ---- independent replay from the raw text trace ----
                st = [0] * 512
                if op == "basemul":
                    st[0:256] = src_in[inp]["ma"]
                    st[256:512] = src_in[inp]["mb"]
                else:
                    st[0:256] = src_in[inp]["f"]
                states = [h(st)]
                masks = [h([0] * 512)]
                written = [0] * 512
                prev_scope = None
                layers_exp = ax["layers_" + op] if op != "basemul" else None
                nops = len(alg["program"])
                latched = None
                for i in range(n):
                    if op == "basemul":
                        p = c["pair"][i]
                        if c["op"][i] == 0:
                            latched = {"A0": st[2 * p], "A1": st[2 * p + 1], "B0": st[256 + 2 * p], "B1": st[256 + 2 * p + 1]}
                        for fk, sk in (("a", "a_src"), ("b", "b_src"), ("z", "z_src")):
                            if c[sk][i] in latched:
                                check("replay", c[fk][i] == latched[c[sk][i]],
                                      "%s basemul %s step %d operand %s" % (inp, an, i, c[sk][i]))
                        ws = []
                        if c["dst"][i] == "C0":
                            ws = [(0, 2 * p, c["x"][i])]
                        elif c["dst"][i] == "C1":
                            ws = [(0, 2 * p + 1, c["x"][i])]
                        scope = 0
                    else:
                        rd, wr = c["rd"][i], c["wr"][i]
                        check("replay", st[rd * 256 + c["addr0"][i]] == c["a"][i] and
                              st[rd * 256 + c["addr1"][i]] == c["b"][i],
                              "%s %s %s step %d read mismatch" % (inp, op, an, i))
                        check("replay", rd != wr, "%s %s rd == wr at %d" % (inp, op, i))
                        ws = [(wr, c["addr0"][i], c["x"][i]), (wr, c["addr1"][i], c["y"][i])]
                        scope = c["layer"][i]
                    if scope != prev_scope:
                        written = [0] * 512
                        prev_scope = scope
                    for b, a, v in ws:
                        st[b * 256 + a] = v
                        written[b * 256 + a] = 1
                    states.append(h(st))
                    masks.append(h(written))
                    if op != "basemul" and (i + 1 == n or c["layer"][i + 1] != c["layer"][i]):
                        L = c["layer"][i]
                        wr = c["wr"][i]
                        check("replay", sum(written[wr * 256:(wr + 1) * 256]) == 256,
                              "%s %s %s layer %d writes every address" % (inp, op, an, L))
                        check("replay", st[wr * 256:(wr + 1) * 256] == layers_exp[L],
                              "%s %s %s layer %d state == model reference layer" % (inp, op, an, L))
                res_bank = 1 if op != "basemul" else 0
                check("final", st[res_bank * 256:(res_bank + 1) * 256] == golden[inp][op],
                      "%s %s %s final bank == golden" % (inp, op, an))
                expected["%s/%s/%s" % (inp, op, an)] = {"state": states, "written": masks}

    exp_path = os.path.join(bv.BUILD, "check_expected.json")
    with open(exp_path, "w") as f:
        json.dump(expected, f)

    # ---- engine check in node ----
    node = shutil.which("node")
    if node:
        r = subprocess.run([node, os.path.join(HERE, "check_engine.mjs"), args.html, exp_path],
                           capture_output=True, text=True)
        sys.stdout.write(r.stdout)
        sys.stderr.write(r.stderr)
        m = re.search(r"ENGINE checks (\d+) mismatches (\d+)", r.stdout)
        if not m or r.returncode != 0:
            fails.append("engine: node check failed")
        else:
            stats["engine"] = int(m.group(1))
            if int(m.group(2)):
                fails.append("engine: %s mismatches" % m.group(2))
    else:
        print("node not found: engine check SKIPPED")

    # ---- external references ----
    allowed = {"http://www.w3.org/2000/svg"}  # SVG namespace string, not a request
    urls = [u for u in re.findall(r"(?:https?:)?//[A-Za-z0-9.-]+\.[a-z]{2,}[^\s\"'<>)]*", html) if u not in allowed]
    check("external", not urls, "external URL(s): %s" % urls[:5])
    for pat in (r"<link\b", r"<[a-zA-Z][^>]*\ssrc\s*=", r"<[a-zA-Z][^>]*\shref\s*=\s*[\"']?(?!#)", r"@import", r"\bfetch\s*\(", r"XMLHttpRequest", r"\bimport\s*\("):
        check("external", not re.search(pat, html), "pattern %s present" % pat)

    total = sum(stats.values())
    for g in sorted(stats):
        print("check %-9s %8d" % (g, stats[g]))
    print("TOTAL checks %d mismatches %d -> %s" % (total, len(fails), "PASS" if not fails else "FAIL"))
    sys.exit(0 if not fails else 1)


if __name__ == "__main__":
    main()
