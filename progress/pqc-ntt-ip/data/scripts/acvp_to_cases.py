#!/usr/bin/env python3
"""Flatten NIST ACVP ML-KEM JSON (prompt + expectedResults) into line-based text.

Usage: python3 -I acvp_to_cases.py <acvp_dir> <out_dir>

<acvp_dir> holds ML-KEM-keyGen-FIPS203/ and ML-KEM-encapDecap-FIPS203/.
Writes <out_dir>/acvp_cases_{512,768,1024}.txt, one test case per line:
  keygen  <tcId> <d> <z> <ek> <dk>
  encap   <tcId> <ek> <m> <c> <k>
  decap   <tcId> <dk> <c> <k>
  ekcheck <tcId> <ek> <0|1>
  dkcheck <tcId> <dk> <0|1>
All byte strings are hex. Only the JSON prompt and expectedResults files are
read (internalProjection is not used, it is the server-side answer key).
"""
import json
import os
import re
import sys

PARAM_SETS = {"ML-KEM-512": "512", "ML-KEM-768": "768", "ML-KEM-1024": "1024"}
HEX_RE = re.compile(r"^[0-9A-Fa-f]*$")


def load(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def hexfield(v):
    if not isinstance(v, str) or not HEX_RE.match(v) or len(v) % 2:
        raise ValueError("bad hex field: %r" % (v[:40],))
    return v.upper()


def boolfield(v):
    if v not in ("True", "False", True, False):
        raise ValueError("bad bool: %r" % (v,))
    return "1" if v in ("True", True) else "0"


def expected_map(doc):
    out = {}
    for g in doc["testGroups"]:
        for t in g["tests"]:
            out[str(t["tcId"])] = t
    return out


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    acvp_dir, out_dir = sys.argv[1], sys.argv[2]
    lines = {v: [] for v in PARAM_SETS.values()}

    kg_dir = os.path.join(acvp_dir, "ML-KEM-keyGen-FIPS203")
    prompt = load(os.path.join(kg_dir, "prompt.json"))
    exp = expected_map(load(os.path.join(kg_dir, "expectedResults.json")))
    for g in prompt["testGroups"]:
        ps = PARAM_SETS[g["parameterSet"]]
        for t in g["tests"]:
            e = exp[str(t["tcId"])]
            lines[ps].append("keygen %s %s %s %s %s" % (
                t["tcId"], hexfield(t["d"]), hexfield(t["z"]),
                hexfield(e["ek"]), hexfield(e["dk"])))

    ed_dir = os.path.join(acvp_dir, "ML-KEM-encapDecap-FIPS203")
    prompt = load(os.path.join(ed_dir, "prompt.json"))
    exp = expected_map(load(os.path.join(ed_dir, "expectedResults.json")))
    for g in prompt["testGroups"]:
        ps = PARAM_SETS[g["parameterSet"]]
        fn = g["function"]
        for t in g["tests"]:
            e = exp[str(t["tcId"])]
            tc = t["tcId"]
            if fn == "encapsulation":
                s = "encap %s %s %s %s %s" % (tc, hexfield(t["ek"]), hexfield(t["m"]),
                                              hexfield(e["c"]), hexfield(e["k"]))
            elif fn == "decapsulation":
                s = "decap %s %s %s %s" % (tc, hexfield(t["dk"]), hexfield(t["c"]),
                                           hexfield(e["k"]))
            elif fn == "encapsulationKeyCheck":
                s = "ekcheck %s %s %s" % (tc, hexfield(t["ek"]), boolfield(e["testPassed"]))
            elif fn == "decapsulationKeyCheck":
                s = "dkcheck %s %s %s" % (tc, hexfield(t["dk"]), boolfield(e["testPassed"]))
            else:
                raise ValueError("unknown function %r" % fn)
            lines[ps].append(s)

    os.makedirs(out_dir, exist_ok=True)
    for ps, ls in lines.items():
        path = os.path.join(out_dir, "acvp_cases_%s.txt" % ps)
        with open(path, "w", encoding="ascii") as fh:
            fh.write("\n".join(ls) + "\n")
        kinds = {}
        for s in ls:
            kinds[s.split()[0]] = kinds.get(s.split()[0], 0) + 1
        print("%s: %d cases %s" % (path, len(ls), kinds))


if __name__ == "__main__":
    main()
