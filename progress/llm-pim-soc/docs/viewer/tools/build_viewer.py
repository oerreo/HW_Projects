#!/usr/bin/env python3
"""Build docs/viewer/sys_player.html from the RTL system testbench trace (S4-8 viewer).

Inputs (no arguments; process-privacy rule): for each scene the files of one run of
sim/tests/sys_fwd.cfg in sim/sys_fwd/
  v_<label>.txt   viewer event trace (+VTRACE, tb/sys_top/hal_dpi.c header)
  c_<label>.txt   CYCLES trace (+CYCTRACE), cross-checked against v_<label>.txt
  <label>.log     simulator log (KSPLIT / RUN lines, SYSTB STALL, AXI_MEM)
Output: ../sys_player.html (template.html + embedded JSON), build/data.json (same JSON),
build/check.txt (check report, also printed).

No model arithmetic is done here. Every number in the JSON is a trace value, a difference
of two cumulative trace counters (beats, AXI-Lite accesses, ticks relative to the token
start), a register field (decoded with the bit fields of fpga/sys/sw/ipregs.h), or a sum /
ratio of those (totals, prefix sums, percentages). The build fails if a check fails:
  1. run P of the scene: per KSPLIT category, the sums of CYCLES, RD_STALL, WR_STALL and the
     op count of the trace ops == the KSPLIT line of the same run (log and trace)
  2. whole run: per slot, CYCLES / RD_STALL / WR_STALL sums == "SYSTB STALL" line
  3. CYCLES reads of the viewer trace == CYCTRACE file (slot, ctrl, value, line by line)
  4. HP beats: no beat between two ops (S beats == previous E beats), per port total of
     the ops == AXI_MEM line of the log
  5. attention ops: AT_LAYER register == layer derived from the kernel sequence
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
VIEWER = os.path.dirname(HERE)
PROJECT = os.path.dirname(os.path.dirname(VIEWER))
SIMDIR = os.path.join(PROJECT, "sim", "sys_fwd")
BUILD = os.path.join(HERE, "build")
TEMPLATE = os.path.join(HERE, "template.html")
OUT = os.path.join(VIEWER, "sys_player.html")
PLACEHOLDER = "/*__TRACE_DATA__*/"

# scene: run label of sys_fwd.cfg, position shown, short title
SCENES = [
    {"id": "p260", "label": "p_full", "pos": 1,
     "title": "빌드 P, 260K, mask ff",
     "mem": "latency 1, stall 없음 (TB 메모리 모델 PROF 0)"},
    {"id": "a260", "label": "a_m1", "pos": 1,
     "title": "빌드 A, 260K, mask ff",
     "mem": "latency 1, stall 없음 (TB 메모리 모델 PROF 0)"},
    {"id": "a15m", "label": "a_m2", "pos": 1,
     "title": "빌드 A, 15M, mask ff",
     "mem": "latency 1, stall 없음 (TB 메모리 모델 PROF 0)"},
    {"id": "pst", "label": "p_stall", "pos": 1,
     "title": "빌드 P, 260K, mask ff, 메모리 stall",
     "mem": "TB random 모델 PROF 2: AR/AW/W/R/B 50 % stall, R latency 1..60, B latency 1..40, "
            "AXI-Lite 간격 MAXD 1"},
]

SLOT_IP = {0: "ga", 1: "pi", 2: "at", 3: "ve"}
IP_NAME = {"ga": "gemv_acc", "pi": "pim", "at": "attn", "ve": "vec"}
# kernel category (KSPLIT name) -> colour group and one-letter label
GROUP = {"gemv_q": "gemv", "gemv_k": "gemv", "gemv_v": "gemv", "gemv_o": "gemv",
         "gemv_w1": "gemv", "gemv_w2": "gemv", "gemv_w3": "gemv", "gemv_cls": "gemv",
         "attn": "attn", "rmsnorm": "rms", "actq_h": "actq", "actq_a": "actq",
         "swiglu": "swi", "argmax": "amax", "embed": "arm", "rope": "arm", "add": "arm"}
VE_OP = {1: "RMSNORM", 2: "SWIGLU", 3: "ACTQ", 4: "ARGMAX"}
PI_CMD = {1: "LDW", 2: "WRGB", 3: "MACAB"}
R_ERR, R_CYCLES, R_RD_STALL, R_WR_STALL = 0x10, 0x14, 0x18, 0x1C


def die(msg):
    sys.stderr.write("build_viewer: ERROR: " + msg + "\n")
    sys.exit(1)


def kv(line):
    return dict(m.groups() for m in re.finditer(r"(\w+)=(\S+)", line))


# ---------------------------------------------------------------- parsing
def parse_trace(path):
    """Events in file order. Ops are built from S / E / R; P and K are kept in order."""
    ev = []
    with open(path) as f:
        for ln in f:
            ln = ln.rstrip("\n")
            if not ln:
                continue
            t = ln[0]
            if t == "L":
                ev.append(("L", ln[2:]))
                continue
            p = ln.split()
            if t == "K":
                ev.append(("K", int(p[1]), int(p[2]), p[3]))
            elif t == "S":
                if len(p) != 30:
                    die(f"{path}: bad S line: {ln}")
                ev.append(("S", int(p[1]), int(p[2]), int(p[3], 16), int(p[4]), int(p[5]),
                           [int(x) for x in p[6:14]], [int(x, 16) for x in p[14:30]]))
            elif t == "E":
                if len(p) != 14:
                    die(f"{path}: bad E line: {ln}")
                ev.append(("E", int(p[1]), int(p[2]), int(p[3], 16), int(p[4]), int(p[5]),
                           [int(x) for x in p[6:14]]))
            elif t == "R":
                ev.append(("R", int(p[1]), int(p[2]), int(p[3], 16), int(p[4]), int(p[5]), int(p[6])))
            elif t == "P":
                ev.append(("P", int(p[1]), [int(x, 16) for x in p[2:6]]))
            else:
                die(f"{path}: unknown event: {ln}")
    return ev


def parse_log(path):
    out = {"stall": {}, "axi": [], "model": None}
    with open(path) as f:
        for ln in f:
            ln = ln.rstrip("\n")
            if ln.startswith("# "):
                ln = ln[2:]
            if ln.startswith("SYSTB STALL"):
                d = kv(ln)
                out["stall"][int(d["slot"])] = (int(d["cycles"]), int(d["rd_stall"]), int(d["wr_stall"]),
                                                int(d["ops"]))
            elif ln.startswith("AXI_MEM hp:"):
                m = re.search(r"rd bursts \d+ beats (\d+) .* wr bursts \d+ beats (\d+)", ln)
                out["axi"].append((int(m.group(1)), int(m.group(2))))
            elif ln.startswith("MODEL "):
                out["model"] = kv(ln)
            elif ln.startswith("TB_RESULT"):
                out["result"] = ln.split()[-1]
    return out


def build_ops(ev):
    """List of ops (dict) in start order with their events; each op knows the index of the
    event that started it (for segment / position assignment)."""
    ops = []
    last = {}
    for i, e in enumerate(ev):
        if e[0] == "S":
            _, tick, slot, ctrl, axr, axw, b, regs = e
            op = {"i": i, "slot": slot, "ctrl": ctrl, "t0": tick, "b0": b, "regs": regs,
                  "ax_end": (axr, axw), "cyc": None, "rs": 0, "ws": 0, "err": 0}
            ops.append(op)
            last[slot] = op
        elif e[0] == "E":
            _, tick, slot, st, axr, axw, b = e
            op = last[slot]
            op["t1"], op["status"], op["b1"], op["ax_end"] = tick, st, b, (axr, axw)
        elif e[0] == "R":
            _, tick, slot, off, val, axr, axw = e
            op = last.get(slot)
            if op is None:
                continue
            op["ax_end"] = (axr, axw)
            if off == R_CYCLES:
                op["cyc"] = val
            elif off == R_RD_STALL:
                op["rs"] = val
            elif off == R_WR_STALL:
                op["ws"] = val
            elif off == R_ERR:
                op["err"] = val
    return ops


# ---------------------------------------------------------------- decoding
def reg(op, off):
    return op["regs"][(off - 0x40) // 4]


def describe(op, model):
    """op kind and size text from the descriptor registers (ipregs.h fields)."""
    ip = SLOT_IP[op["slot"]]
    code = (op["ctrl"] >> 4) & 0xF
    if ip == "ga":
        rows, n, flags = reg(op, 0x4C), reg(op, 0x50), reg(op, 0x5C)
        fl = [s for b, s in ((2, "y_en"), (1, "argmax_en")) if flags & b]
        return "GEMV", f"rows {rows} x n {n}" + (", " + " + ".join(fl) if fl else ""), {"argmax_en": flags & 1}
    if ip == "pi":
        return "RUN", "", {}
    if ip == "at":
        if code == 2:
            kvh = reg(op, 0x78)
            return "KVW", f"layer {reg(op, 0x6C)}, pos {reg(op, 0x74)}, kv heads {(kvh >> 8) & 0xFF}", {}
        head = reg(op, 0x68)
        h0, nh, km = head & 0xFF, (head >> 8) & 0xFF, (head >> 16) & 0xFF
        return "ATTN", (f"T {reg(op, 0x5C) & 0xFFFF}, hs {reg(op, 0x60) & 0xFF}, heads {h0}..{h0 + nh - 1} "
                        f"(NHEAD {nh}, KVMUL {km})"), {}
    name = VE_OP.get(code, f"op{code}")
    n = reg(op, 0x50)
    if code == 3:
        q = reg(op, 0x54) & 0xFFFF
        return name, f"n {n}, qmax {q} ({'int8' if q == 127 else 'int16'})", {}
    return name, f"n {n}", {}


def pim_cmd_text(c, ctx):
    op = c[0] & 0xF
    n = (c[0] >> 4) & 0xFFF
    rows = c[0] >> 16
    name = PI_CMD.get(op, f"cmd{op}")
    if op == 2:
        return f"WRGB n {n} ({ctx})"
    if op == 3:
        return f"MACAB {rows} x {n}, bank base {c[1] >> 17} ({ctx})"
    return f"{name} {rows} x {n}"


# ---------------------------------------------------------------- one scene
def build_scene(sc, chk):
    lab = sc["label"]
    vpath = os.path.join(SIMDIR, f"v_{lab}.txt")
    cpath = os.path.join(SIMDIR, f"c_{lab}.txt")
    lpath = os.path.join(SIMDIR, f"{lab}.log")
    for p in (vpath, cpath, lpath):
        if not os.path.exists(p):
            die(f"missing {os.path.relpath(p, PROJECT)} (run sim/tests/sys_fwd.cfg label {lab})")
    ev = parse_trace(vpath)
    log = parse_log(lpath)
    if log.get("result") != "PASS":
        die(f"{lab}: TB_RESULT is not PASS")
    ops = build_ops(ev)
    tag = sc["id"]

    # ---- check 3: CYCLES reads == CYCTRACE
    ctr = []
    with open(cpath) as f:
        for ln in f:
            p = ln.split()
            if len(p) == 3:
                ctr.append((int(p[0]), int(p[1], 16), int(p[2])))
    vt = [(o["slot"], o["ctrl"], o["cyc"]) for o in ops if o["cyc"] is not None]
    chk.append((tag, "CYCLES reads == CYCTRACE (lines)", len(ctr), len(vt), ctr == vt))

    # ---- check 2: per slot sums over the whole program == SYSTB STALL
    for s in range(4):
        got = [0, 0, 0, 0]
        for o in ops:
            if o["slot"] == s and o["cyc"] is not None:
                got[0] += o["cyc"]
                got[1] += o["rs"]
                got[2] += o["ws"]
                got[3] += 1
        exp = log["stall"][s]
        chk.append((tag, f"slot {s} cycles/rd/wr/ops == SYSTB STALL", exp, tuple(got), tuple(got) == exp))

    # ---- check 4: beats
    gaps = 0
    prev = None
    for o in ops:
        if "b1" not in o:
            die(f"{lab}: op without busy = 0 (event {o['i']})")
        if prev is not None and o["b0"] != prev["b1"]:
            gaps += 1
        prev = o
    chk.append((tag, "HP beats between two ops", 0, gaps, gaps == 0))
    for k in range(4):
        tr = sum(o["b1"][2 * k] - o["b0"][2 * k] for o in ops)
        tw = sum(o["b1"][2 * k + 1] - o["b0"][2 * k + 1] for o in ops)
        before = ops[0]["b0"][2 * k:2 * k + 2] if ops else [0, 0]
        exp = log["axi"][k]
        got = (tr + before[0], tw + before[1])
        chk.append((tag, f"HP{k} R/W beats of all ops == AXI_MEM", exp, got, got == exp))

    # ---- segments: split at "L RUN" lines; pick run P with mask ff
    seg_start = 0
    seg = None
    for i, e in enumerate(ev):
        if e[0] == "L" and e[1].startswith("RUN "):
            d = kv(e[1])
            if seg is None and d["run"] == "P" and int(d["mask"], 16) == 0xFF:
                seg = (seg_start, i, d)
            seg_start = i + 1
    if seg is None:
        die(f"{lab}: no run P with mask ff in the trace")
    a, b, rund = seg
    ksplit = {}
    for e in ev[a:b]:
        if e[0] == "L" and e[1].startswith("KSPLIT "):
            d = kv(e[1])
            ksplit[d["k"]] = d
    model = None
    for e in ev:
        if e[0] == "L" and e[1].startswith("MODEL "):
            model = kv(e[1])
            break
    sysd = None
    for e in ev:
        if e[0] == "L" and e[1].startswith("SYS "):
            sysd = kv(e[1])
            break
    L = int(model["layers"])
    arm_cat = set()
    for k, d in ksplit.items():
        if int(d["calls_fb"]) != 0:
            die(f"{lab}: fallback calls in category {k}")
        if int(d["calls_ip"]) == 0 and int(d["calls_arm"]) > 0:
            arm_cat.add(k)

    # ---- walk the run: kernel context, layer, pim pushes, steps
    first_k = next(i for i in range(a, b) if ev[i][0] == "K")
    ctx = None
    pos = None
    rms = 0
    layer = "embed"
    pushes = []
    last_pi_cat = None
    op_by_i = {o["i"]: o for o in ops}
    run_ops = []
    steps_by_pos = {}
    pos_t0 = {}
    pos_tend = {}
    arm_open = None
    layer_bad = 0
    deferred = {}
    fused = 0
    pending = []  # IP-category kernel calls not yet matched to an op (deferred / fused)
    for i in range(first_k, b):
        e = ev[i]
        if e[0] == "K":
            _, tick, p, name = e
            if p != pos:
                pos = p
                rms = 0
                pos_t0[p] = tick
                steps_by_pos[p] = []
                arm_open = None
                pending = []
            if name == "embed":
                layer = "embed"
            if name == "rmsnorm":
                rms += 1
                layer = (rms - 1) // 2 if rms - 1 < 2 * L else "final"
            ctx = name
            pos_tend[p] = tick
            if name in arm_cat:
                if arm_open is None:
                    arm_open = {"t": "arm", "k": name, "g": "arm", "lay": layer, "calls": [name],
                                "t0": tick, "t1": tick, "cyc": 0, "rs": 0, "ws": 0}
                    steps_by_pos[p].append(arm_open)
                else:
                    arm_open["calls"].append(name)
                    arm_open["t1"] = tick
            else:
                arm_open = None
                pending.append(name)
        elif e[0] == "P":
            pushes.append((e[2], ctx, layer))
            pos_tend[pos] = e[1]
        elif e[0] == "S":
            arm_open = None
            o = op_by_i[i]
            ip = SLOT_IP[o["slot"]]
            opk, size, extra = describe(o, model)
            o["pos"] = pos
            o["lay"] = layer
            if ip == "pi":
                cmds = [pim_cmd_text(c, cx) for c, cx, _ in pushes]
                mac = [(cx, ly) for c, cx, ly in pushes if (c[0] & 0xF) == 3]
                if mac:
                    cat = mac[0][0]
                    o["lay"] = mac[0][1]
                elif last_pi_cat is not None:
                    cat = last_pi_cat
                else:
                    die(f"{lab}: pim run without MACAB and no earlier run")
                last_pi_cat = cat
                o["cmds"] = cmds
                nw = sum(1 for c, _, _ in pushes if (c[0] & 0xF) == 2)
                size = f"명령 {len(cmds)}개 (WRGB {nw}, MACAB {len(mac)})"
                pushes = []
                pending = [x for x in pending if GROUP.get(x) != "gemv"]
            elif ip == "at":
                cat = "attn"
                if opk == "ATTN":
                    nd = sum(1 for x in pending if x == "attn")
                    deferred[nd] = deferred.get(nd, 0) + 1
                    pending = [x for x in pending if x != "attn"]
                if layer != reg(o, 0x6C):
                    layer_bad += 1
            else:
                cat = ctx
                if ctx in pending:
                    pending.remove(ctx)
            if ip == "ga" and extra.get("argmax_en"):
                o["note"] = "argmax_en = 1: 다음 ARGMAX 호출은 이 GEMV에 융합되어 별도 op가 없다"
            o["cat"], o["opk"], o["size"] = cat, opk, size
            run_ops.append(o)
            steps_by_pos[pos].append(o)
            pos_tend[pos] = max(pos_tend.get(pos, 0), o["t1"])
        elif e[0] in ("E", "R"):
            pos_tend[pos] = max(pos_tend.get(pos, 0), e[1])
    # fused ARGMAX calls: IP category, no op (build A, FUSE_AM)
    fused = sum(int(d["calls_ip"]) for k, d in ksplit.items() if k == "argmax" and int(d["ops"]) == 0)

    # ---- check 1: run P per category == KSPLIT
    agg = {}
    for o in run_ops:
        g = agg.setdefault(o["cat"], [0, 0, 0, 0])
        g[0] += o["cyc"]
        g[1] += o["rs"]
        g[2] += o["ws"]
        g[3] += 1
    bad = []
    for k, d in ksplit.items():
        exp = (int(d["cyc"]), int(d["rd_stall"]), int(d["wr_stall"]), int(d["ops"]))
        got = tuple(agg.get(k, [0, 0, 0, 0]))
        if exp != got:
            bad.append((k, exp, got))
    for k in agg:
        if k not in ksplit:
            bad.append((k, None, tuple(agg[k])))
    tot_ks = sum(int(d["cyc"]) for d in ksplit.values())
    tot_tr = sum(o["cyc"] for o in run_ops)
    chk.append((tag, f"run P: {len(ksplit)} KSPLIT categories cyc/rd/wr/ops == trace", "0 diff",
                f"{len(bad)} diff" + (f" {bad}" if bad else ""), not bad))
    chk.append((tag, "run P: KSPLIT cyc total == trace op CYCLES total", tot_ks, tot_tr, tot_ks == tot_tr))
    if sysd["build"] == "P":  # build A (KV_SRC 1): ATTN does not write AT_LAYER (drv_at.c)
        chk.append((tag, "attention ops: AT_LAYER reg == layer from kernel sequence", 0, layer_bad,
                    layer_bad == 0))

    # ---- the scene position
    P = sc["pos"]
    if P not in steps_by_pos:
        die(f"{lab}: position {P} not in run P")
    pos_sums = {p: sum(o.get("cyc") or 0 for o in st if o.get("t") != "arm") for p, st in steps_by_pos.items()}
    chk.append((tag, "run P: sum over positions of token CYCLES == KSPLIT total", tot_ks,
                sum(pos_sums.values()), sum(pos_sums.values()) == tot_ks))
    t0 = pos_t0[P]
    steps = []
    x0 = 0
    cats = [k for k in ksplit if int(ksplit[k]["ops"]) > 0]
    cum_c = {k: 0 for k in cats}
    cum_n = {k: 0 for k in cats}
    for s in steps_by_pos[P]:
        if s.get("t") == "arm":
            names = s["calls"]
            uniq = []
            for nm in names:
                if nm not in uniq:
                    uniq.append(nm)
            txt = ", ".join(f"{nm} x{names.count(nm)}" for nm in uniq)
            st = {"t": "arm", "ip": "arm", "op": "ARM", "k": "+".join(uniq), "g": "arm",
                  "lay": s["lay"], "size": f"ARM kernel 호출 {len(names)}개: {txt}",
                  "cyc": 0, "rs": 0, "ws": 0, "t0": s["t0"] - t0, "t1": s["t1"] - t0,
                  "axr": 0, "axw": 0, "hp": [0] * 8, "x0": x0}
        else:
            o = s
            st = {"t": "ip", "ip": SLOT_IP[o["slot"]], "op": o["opk"], "k": o["cat"],
                  "g": GROUP[o["cat"]], "lay": o["lay"], "size": o["size"],
                  "cyc": o["cyc"], "rs": o["rs"], "ws": o["ws"],
                  "t0": o["t0"] - t0, "t1": o["t1"] - t0,
                  "hp": [o["b1"][j] - o["b0"][j] for j in range(8)], "x0": x0}
            if "cmds" in o:
                st["cmds"] = o["cmds"]
            if "note" in o:
                st["note"] = o["note"]
            x0 += o["cyc"]
            cum_c[o["cat"]] += o["cyc"]
            cum_n[o["cat"]] += 1
        st["cc"] = [cum_c[k] for k in cats]
        st["cn"] = [cum_n[k] for k in cats]
        steps.append(st)
    # AXI-Lite accesses per IP op: from the previous op of the same slot to this op's last read
    prev_ax = {}
    for o in ops:
        pa = prev_ax.get(o["slot"], (0, 0))
        o["axd"] = (o["ax_end"][0] - pa[0], o["ax_end"][1] - pa[1])
        prev_ax[o["slot"]] = o["ax_end"]
    j = 0
    for s in steps_by_pos[P]:
        if s.get("t") != "arm":
            steps[j]["axr"], steps[j]["axw"] = s["axd"]
        j += 1
    tok_cyc = x0
    nxt = [pos_t0[p] for p in pos_t0 if p > P]
    t_end = (min(nxt) if nxt else pos_tend[P]) - t0
    rows = []
    for k in cats:
        c = cum_c[k]
        rs = sum(s["rs"] for s in steps if s["t"] == "ip" and s["k"] == k)
        ws = sum(s["ws"] for s in steps if s["t"] == "ip" and s["k"] == k)
        rows.append({"k": k, "g": GROUP[k], "n": cum_n[k], "cyc": c, "rs": rs, "ws": ws,
                     "pct": round(100.0 * c / tok_cyc, 1) if tok_cyc else 0.0})
    grp_tot = {}
    for s in steps:
        grp_tot[s["g"]] = grp_tot.get(s["g"], 0) + s["cyc"]
    chk.append((tag, f"position {P}: step CYCLES sum == op CYCLES of that position", pos_sums[P], tok_cyc,
                pos_sums[P] == tok_cyc))
    hp_map = ({"HP0": "gemv_acc R/W", "HP1": "attn R0/W", "HP2": "tie-off", "HP3": "vec R/W"}
              if sysd["build"] == "A" else
              {"HP0": "pim R/W", "HP1": "attn R0/W", "HP2": "attn R1", "HP3": "vec R/W"})
    n_ip = sum(1 for s in steps if s["t"] == "ip")
    return {
        "id": sc["id"], "label": lab, "title": sc["title"], "mem": sc["mem"],
        "build": sysd["build"], "model": model["m"], "dim": int(model["dim"]), "layers": L,
        "heads": int(model["heads"]), "kv_heads": int(model["kv_heads"]), "vocab": int(model["vocab"]),
        "pos": P, "mask": rund["mask"], "opt": rund["opt"], "run_steps": int(rund["steps"]),
        "slots": {"ga": sysd["ga"] == "1", "pi": sysd["pi"] == "1", "at": sysd["at"] == "1",
                  "ve": sysd["ve"] == "1"},
        "hp_map": hp_map, "cats": cats, "rows": rows, "grp": grp_tot,
        "tok_cyc": tok_cyc, "tok_ticks": t_end, "n_ip": n_ip, "n_arm": len(steps) - n_ip,
        "tok_rs": sum(s["rs"] for s in steps), "tok_ws": sum(s["ws"] for s in steps),
        "pos_cyc": {str(p): v for p, v in sorted(pos_sums.items())}, "run_cyc": tot_ks,
        "deferred_attn": {str(k): v for k, v in sorted(deferred.items())}, "fused_argmax": fused,
        "steps": steps,
    }


def main():
    os.makedirs(BUILD, exist_ok=True)
    chk = []
    scenes = [build_scene(sc, chk) for sc in SCENES]
    data = {"scenes": scenes,
            "source": "RTL system testbench tb/sys_top/tb_sys_fwd.sv (Questa), sim/tests/sys_fwd.cfg, "
                      "trace +VTRACE (tb/sys_top/hal_dpi.c)"}
    js = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    with open(os.path.join(BUILD, "data.json"), "w") as f:
        f.write(js)
    with open(TEMPLATE) as f:
        tpl = f.read()
    if tpl.count(PLACEHOLDER) != 1:
        die("template placeholder missing")
    html = tpl.replace(PLACEHOLDER, js.replace("</", "<\\/"))
    with open(OUT, "w") as f:
        f.write(html)
    nbad = 0
    lines = []
    for tag, what, exp, got, ok in chk:
        nbad += not ok
        lines.append(f"{'OK ' if ok else 'BAD'} {tag:5s} {what}: expected {exp} got {got}")
    for sc in scenes:
        lines.append(f"SCENE {sc['id']} ({sc['label']}, pos {sc['pos']}): steps {len(sc['steps'])} "
                     f"(IP ops {sc['n_ip']}, ARM {sc['n_arm']}) token CYCLES {sc['tok_cyc']} "
                     f"token ticks {sc['tok_ticks']} run P KSPLIT cyc {sc['run_cyc']} per position {sc['pos_cyc']}")
    lines.append(f"CHECKS {len(chk)} bad {nbad}; html {os.path.getsize(OUT)} bytes, json {len(js)} bytes")
    with open(os.path.join(BUILD, "check.txt"), "w") as f:
        f.write("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 1 if nbad else 0


if __name__ == "__main__":
    sys.exit(main())
