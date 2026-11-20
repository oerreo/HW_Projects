# S5-0 system.md의 [계산] 값(빌드 자원, HP 배정, 버퍼 배치와 정렬, 호출 수, PL 쪽 시간 표, 융합 이득).
# 표준 라이브러리만, 인자 없음. 실행: python3 -I docs/spec/s5calc.py
# 입력 중 시뮬레이션 측정값(Questa, axi_mem_slave latency 1, stall 없음, 보드 아님)은 SIM_* 상수로 두고
# 출처 문서를 주석에 적는다. 그 밖은 모두 구성에서 식으로 구한 값이다.
import math

cd = lambda a, b: -(-a // b)
F_PL = 100e6  # 가정: FCLK_CLK0 100 MHz (측정 아님)

M = {"260K": dict(D=64, H=172, L=5, nh=8, nkv=4, voc=512, seq=512),
     "15M": dict(D=288, H=768, L=6, nh=6, nkv=6, voc=32000, seq=256)}
for m in M.values():
    m["hs"] = m["D"] // m["nh"]
    m["kvmul"] = m["nh"] // m["nkv"]
KB, VB = 12, 8                      # K12V8 (numeric.md 4절)
EK, EV = (2 if KB > 8 else 1), (2 if VB > 8 else 1)


def mats(m):
    D, H, L = m["D"], m["H"], m["L"]
    kv = m["hs"] * m["nkv"]
    one = [("wq", D, D), ("wk", kv, D), ("wv", kv, D), ("wo", D, D), ("w1", H, D), ("w3", H, D), ("w2", D, H)]
    out = []
    for l in range(L):
        out += [(f"{n}{l}", r, c) for n, r, c in one]
    out.append(("cls", m["voc"], D))
    return out


def hdr(t):
    print()
    print("== " + t)


# ---------------------------------------------------------------- 1. 버퍼: 행 레코드, PIM bank, 정렬
hdr("1. 행 레코드와 PIM bank 적재 [계산]")
for name, m in M.items():
    ms = mats(m)
    rrec = sum(r * 8 * (1 + cd(c, 8)) for _, r, c in ms)
    w8 = sum(r * c for _, r, c in ms)
    print(f"{name}: 행 레코드 합 {rrec:,} B (int8 가중치 {w8:,} B 대비 +{rrec - w8:,} B)")
m = M["260K"]
words = sum(cd(r, 4) * cd(c, 16) for _, r, c in mats(m))
print(f"260K PIM bank word 합(BANK_ROW, NB 4, LB 16) {words:,} / DEPTH 4,096, LDW 읽기 = 행 레코드 합")

hdr("1b. golden sub-buffer offset (byte)와 8 B 정렬 [계산]")
for name, m in M.items():
    hs = m["hs"]
    items = {
        "kc slot stride hs*ek": hs * EK,
        "vc slot stride hs*ev": hs * EV,
        "kcs/vcs slot stride": 8,
        "att head stride 4*hs": 4 * hs,
        "kr/v/qr head stride 4*hs": 4 * hs,
        "q record QB = 8 + 2*hs": 8 + 2 * hs,
        "layer KV base kc (nkv*seq*hs*ek)": m["nkv"] * m["seq"] * hs * EK,
        "layer KV base vc (nkv*seq*hs*ev)": m["nkv"] * m["seq"] * hs * EV,
        "layer KV base kcs (nkv*seq*8)": m["nkv"] * m["seq"] * 8,
    }
    bad = [k for k, v in items.items() if v % 8]
    print(f"{name}: " + ", ".join(f"{k} {v}" for k, v in items.items()))
    print(f"  8의 배수가 아닌 것: {bad if bad else '없음'} (lm_take는 64 B 정렬, model/src/core.c)")
    print(f"  p stride PS = 8*ceil(T/2): T 1 -> 8, T {m['seq']} -> {8 * cd(m['seq'], 2)} (golden p는 [T] 하나를 head마다 덮어씀)")

# ---------------------------------------------------------------- 2. 호출 수
hdr("2. token당 kernel 호출 수 (fwd_h.c 순서) [계산]")
for name, m in M.items():
    L, nh, nkv = m["L"], m["nh"], m["nkv"]
    calls = dict(embed=1, rmsnorm=2 * L + 1, gemv=7 * L + 1, rope=2 * L,
                 actq_kv=2 * nkv * L, actq_q=nh * L, actq_att=L, attn=nh * L,
                 swiglu=L, add=2 * L, argmax=1)
    tot = sum(calls.values())
    print(f"{name}: " + ", ".join(f"{k} {v}" for k, v in calls.items()) + f", 합 {tot}")
    # IP 호출(run) 수: 호출 단위 dispatch와 묶음(지연 실행) 비교
    attn_head, attn_layer = nh * L, L
    pim_rec = 7 * L + 1                      # 레코드마다 WRGB + MACAB 한 run
    pim_wrgb_skip = 4 * L + 1                # 같은 x 재사용으로 WRGB 생략: layer당 WRGB 4회 + cls 1
    pim_batch_runs = 4 * L + 1               # 같은 x 묶음(qkv / o / w1w3 / w2) + cls
    print(f"  ATTN op: head 단위 {attn_head}, layer 단위 {attn_layer} (+ KVW layer당 1: {L})")
    print(f"  PIM: 호출 단위 run {pim_rec} (WRGB {pim_rec} 또는 생략 시 {pim_wrgb_skip}), 같은 x 묶음 run {pim_batch_runs}, MACAB {7 * L + 1}")
    cmd = lambda nw, nm: 5 * (nw + nm)
    print(f"  PIM CMD AXI-Lite 쓰기(명령당 5회): WRGB 매번 {cmd(pim_rec, pim_rec)}, WRGB 생략 {cmd(pim_wrgb_skip, pim_rec)}")

# ---------------------------------------------------------------- 3. 자원
hdr("3. 빌드별 자원 예산 (DSP, BRAM36 [계산], LUT [추정])")
DSP = dict(ga1=11, ga2=22, pim=67, at=33, ve=16)          # arch.md 8, pim.md 8, attn.md 8, vec.md 8
# BRAM36 (lo, hi): lo = 확실히 BRAM, hi = 작은 RAM이 BRAM18로 갈 때
kv_par = 4 * cd(210, 72) * cd(5 * 512, 512)
kv_nopar = 4 * cd(210, 64) * cd(5 * 512, 512)
pim_par = 4 * cd(144, 72) * cd(4096, 512)
pim_nopar = 4 * cd(144, 64) * cd(4096, 512)
BR = dict(ga=(0, 0.5),               # x buffer 128 x 64 (LUTRAM 또는 BRAM18)
          pim=(pim_par, pim_par + 1),  # bank 64 + pim_gb 2 x (64 x 64)
          at=(1, 1),                 # p buffer 512x32 + vs buffer 512x25 = BRAM18 2개
          kv=(kv_par, kv_par),
          kvrd=(0, 0),
          ve1024=(2, 2), ve256=(0, 1))
LUT = dict(ga1=(2.5, 4), ga2=(4, 6), pim=(3, 5), at=(3, 5), kv=(0.3, 0.5), kvrd=(0.5, 1),
           ve=(3, 5), ic=(2, 5), xbar=(0.1, 0.3))   # k LUT, arch.md 8 (xbar는 이 문서의 추정)
print(f"kv_store BRAM36 parity 사용 {kv_par} / 미사용 {kv_nopar}; pim bank parity 사용 {pim_par} / 미사용 {pim_nopar}")


def build(name, dsp, br, lut):
    d = sum(dsp)
    blo, bhi = sum(b[0] for b in br), sum(b[1] for b in br)
    llo, lhi = sum(x[0] for x in lut), sum(x[1] for x in lut)
    print(f"{name}: DSP {d}/220 ({100 * d / 220:.0f}%), BRAM36 {blo:g}~{bhi:g}/140 "
          f"({100 * blo / 140:.0f}~{100 * bhi / 140:.0f}%), LUT {llo:.1f}k~{lhi:.1f}k/53.2k "
          f"({100 * llo / 53.2:.0f}~{100 * lhi / 53.2:.0f}%)")


build("A  (ga P1 + at H1 DDR + ve1024)", [DSP["ga1"], DSP["at"], DSP["ve"]],
      [BR["ga"], BR["at"], BR["kvrd"], BR["ve1024"]],
      [LUT["ga1"], LUT["at"], LUT["kvrd"], LUT["ve"], LUT["ic"], LUT["xbar"]])
build("A' (ga P1 + at H2 DDR + ve1024)", [DSP["ga1"], 2 * DSP["at"], DSP["ve"]],
      [BR["ga"], BR["at"], BR["at"], BR["kvrd"], BR["kvrd"], BR["ve1024"]],
      [LUT["ga1"], LUT["at"], LUT["at"], LUT["kvrd"], LUT["kvrd"], LUT["ve"], LUT["ic"], LUT["xbar"]])
build("A2 (ga P2 + at H1 DDR + ve1024)", [DSP["ga2"], DSP["at"], DSP["ve"]],
      [(0, 1), BR["at"], BR["kvrd"], BR["ve1024"]],
      [LUT["ga2"], LUT["at"], LUT["kvrd"], LUT["ve"], LUT["ic"], LUT["xbar"]])
build("P  (pim + at H2 BRAM + ve1024)", [DSP["pim"], 2 * DSP["at"], DSP["ve"]],
      [BR["pim"], BR["at"], BR["at"], BR["kv"], BR["ve1024"]],
      [LUT["pim"], LUT["at"], LUT["at"], LUT["kv"], LUT["ve"], LUT["ic"], LUT["xbar"]])
build("P  (pim + at H2 BRAM + ve256)", [DSP["pim"], 2 * DSP["at"], DSP["ve"]],
      [BR["pim"], BR["at"], BR["at"], BR["kv"], BR["ve256"]],
      [LUT["pim"], LUT["at"], LUT["at"], LUT["kv"], LUT["ve"], LUT["ic"], LUT["xbar"]])
build("PD (pim + at H2 DDR + ve256)  [P의 BRAM 대안]", [DSP["pim"], 2 * DSP["at"], DSP["ve"]],
      [BR["pim"], BR["at"], BR["at"], BR["ve256"]],
      [LUT["pim"], LUT["at"], LUT["at"], LUT["kvrd"], LUT["kvrd"], LUT["ve"], LUT["ic"], LUT["xbar"]])
build("PC (P + ga P1, 병합안)", [DSP["pim"], 2 * DSP["at"], DSP["ve"], DSP["ga1"]],
      [BR["pim"], BR["at"], BR["at"], BR["kv"], BR["ve256"], BR["ga"]],
      [LUT["pim"], LUT["at"], LUT["at"], LUT["kv"], LUT["ve"], LUT["ga1"], LUT["ic"], LUT["xbar"]])
print("P의 parity 미사용 최악: BRAM36", kv_nopar + pim_nopar + 2 + 2, "/140")
print("참고: arch.md 126 (vec 1, attn 0.5x2), attn.md 127 (attn 1x2), vec.md 129 (= 127 + 2: vec 추정 1을 빼지 않은 값으로 보임), 재집계 64+60+2+2 =", 64 + 60 + 2 + 2)

hdr("3b. HP 포트 배정 검사 (HP 포트마다 read 채널 1, write 채널 1)")
HP = {"A": {"HP0": ("ga rd0", "ga wr"), "HP1": ("at rd0", "at wr"), "HP2": (None, None), "HP3": ("ve rd", "ve wr")},
      "P": {"HP0": ("pim rd", "pim wr"), "HP1": ("at rd0", "at wr"), "HP2": ("at rd1", None), "HP3": ("ve rd", "ve wr")}}
for b, ports in HP.items():
    nr = sum(1 for r, w in ports.values() if r)
    nw = sum(1 for r, w in ports.values() if w)
    print(f"{b}: read master {nr}, write master {nw}, 포트 4개 안: {nr <= 4 and nw <= 4}; " +
          "; ".join(f"{p} R={r or '-'} W={w or '-'}" for p, (r, w) in ports.items()))

# ---------------------------------------------------------------- 4. PL 쪽 시간 표
hdr("4. token당 PL 쪽 시간, 100 MHz 가정 [계산, 입력은 시뮬레이션 cycle]")
# 시뮬레이션 측정값(latency 1 메모리 모델, 보드 아님)
SIM = dict(
    pim_tok_run=(4499, 4506),        # pim.md 6.2: token 한 run
    pim_layer_run=(4663, 4676),      # layer마다 run
    pim_rec_run=(6950, 6950),        # 레코드마다 WRGB + MACAB 한 run (약)
    pim_ldw=(36629, 36629),          # LDW 36개 (초기화 1회)
    ga260_p1=(37903, 37938), ga260_p2=(19895, 19930),  # gemv_acc.md 5절
    ga15_p1=(1951992, 1951992), ga15_cls=(1184069, 1184077),
    ve260=(15680, 15680), ve15=(85741, 85741),          # vec.md 6.3
    ve260_argmax=(527, 527), ve15_argmax=(32015, 32015),
    kvw260_tok=(240, 240),                               # attn.md 6.2: KVW 48 x 5
)
# attention token 합: attn.md 6.2 표에 맞춘 직선 (각 점과 일치 확인)
AT = {"260K BRAM H2": ((1, 1810), (512, 32470)), "260K BRAM H1": ((1, 3415), (512, 64735)),
      "15M DDR H1": ((1, 5622), (128, 101634)), "15M DDR H2": ((1, 3210), (128, 51216))}
CHK = {"260K BRAM H2": [(8, 2230), (64, 5590), (128, 9430), (256, 17110)],
       "260K BRAM H1": [(8, 4255), (64, 10975), (128, 18655), (256, 34015)],
       "15M DDR H1": [(256, 198403)], "15M DDR H2": [(256, 99601)]}
fit = {}
for k, ((t0, c0), (t1, c1)) in AT.items():
    a = (c1 - c0) / (t1 - t0)
    b = c0 - a * t0
    fit[k] = (a, b)
    err = max(abs(a * t + b - c) for t, c in CHK[k])
    print(f"attention {k}: token CYCLES = {a:g} T + {b:g}  (표의 다른 점과 최대 차 {err:g})")


def us(c):
    return 1e6 * c / F_PL


def avg_attn(k, S):
    a, b = fit[k]
    return sum(a * T + b for T in range(1, S + 1)) / S


rows = []
rows.append(("260K", "PIM GEMV, token 한 run", SIM["pim_tok_run"]))
rows.append(("260K", "PIM GEMV, layer마다 run", SIM["pim_layer_run"]))
rows.append(("260K", "PIM GEMV, 레코드마다 run(호출 단위)", SIM["pim_rec_run"]))
rows.append(("260K", "가속기형 GEMV P1", SIM["ga260_p1"]))
rows.append(("260K", "가속기형 GEMV P2", SIM["ga260_p2"]))
for T in (1, 64, 256, 512):
    a, b = fit["260K BRAM H2"]
    c = a * T + b + SIM["kvw260_tok"][0]
    rows.append(("260K", f"attention BRAM H2 + KVW, T {T}", (c, c)))
c = avg_attn("260K BRAM H2", 512) + SIM["kvw260_tok"][0]
rows.append(("260K", "attention BRAM H2 + KVW, 위치 0..511 평균", (c, c)))
rows.append(("260K", "vec (RMSNORM, SWIGLU, ACTQ, ARGMAX)", SIM["ve260"]))
rows.append(("15M", "가속기형 GEMV P1 (cls 포함)", SIM["ga15_p1"]))
rows.append(("15M", "그중 cls (y_en, argmax_en)", SIM["ga15_cls"]))
for T in (1, 128, 256):
    a, b = fit["15M DDR H1"]
    rows.append(("15M", f"attention DDR H1, T {T}", (a * T + b,) * 2))
c = avg_attn("15M DDR H1", 256)
rows.append(("15M", "attention DDR H1, 위치 0..255 평균", (c, c)))
c2 = avg_attn("15M DDR H2", 256)
rows.append(("15M", "attention DDR H2, 위치 0..255 평균", (c2, c2)))
rows.append(("15M", "vec (ARGMAX 포함)", SIM["ve15"]))
rows.append(("15M", "vec (ARGMAX를 cls에 융합하면)", (SIM["ve15"][0] - SIM["ve15_argmax"][0],) * 2))
for mdl, what, (lo, hi) in rows:
    s = f"{lo:,.0f}" if lo == hi else f"{lo:,.0f}~{hi:,.0f}"
    t = f"{us(lo):,.1f}" if lo == hi else f"{us(lo):,.1f}~{us(hi):,.1f}"
    print(f"{mdl:5s} {what:42s} {s:>22s} cycle  {t:>16s} us")
print(f"260K PIM LDW 초기화 {SIM['pim_ldw'][0]:,} cycle = {us(SIM['pim_ldw'][0]):.1f} us (1회)")

hdr("4b. 전부 오프로드했을 때 token당 PL 합(위치 평균, 데이터 이동의 ARM 쪽과 호출 비용 제외) [계산]")
p_all = (SIM["pim_tok_run"][0], SIM["pim_rec_run"][0])
at260 = avg_attn("260K BRAM H2", 512) + SIM["kvw260_tok"][0]
print(f"260K 빌드 P: PIM {p_all[0]:,}~{p_all[1]:,} + attention {at260:,.0f} + vec {SIM['ve260'][0]:,} = "
      f"{p_all[0] + at260 + SIM['ve260'][0]:,.0f}~{p_all[1] + at260 + SIM['ve260'][0]:,.0f} cycle "
      f"= {us(p_all[0] + at260 + SIM['ve260'][0]):.1f}~{us(p_all[1] + at260 + SIM['ve260'][0]):.1f} us")
at15 = avg_attn("15M DDR H1", 256)
tot15 = SIM["ga15_p1"][0] + at15 + SIM["ve15"][0] - SIM["ve15_argmax"][0]
print(f"15M 빌드 A: GEMV {SIM['ga15_p1'][0]:,} + attention {at15:,.0f} + vec(argmax 융합) "
      f"{SIM['ve15'][0] - SIM['ve15_argmax'][0]:,} = {tot15:,.0f} cycle = {us(tot15) / 1000:.2f} ms")
print(f"15M GEMV 비중(PL 합 안에서) {100 * SIM['ga15_p1'][0] / tot15:.1f}%")
w15 = sum(r * 8 * (1 + cd(c, 8)) for _, r, c in mats(M["15M"]))
print(f"15M 행 레코드 {w15:,} B / 800 MB/s(HP 하나 이론) = {1e3 * w15 / 800e6:.2f} ms (eta = 1 하한)")

# ---------------------------------------------------------------- 5. 융합 후보 이득
hdr("5. 융합 후보 [계산, vec_top CYCLES 식 = 1 + core + 11 + max(L_last, 2), 보통의 경우]")


def ve_actq(n, qb):
    nbeat = cd(n * qb, 8)
    llast = nbeat % 16 if nbeat % 16 else 16  # OUT_ADDR가 128 B 정렬일 때의 마지막 burst
    return 1 + (2 * n + 59) + 11 + max(llast, 2)


for name, m in M.items():
    L, nh, nkv, hs, D = m["L"], m["nh"], m["nkv"], m["hs"], m["D"]
    k = ve_actq(hs, EK)
    v = ve_actq(hs, EV)
    q = ve_actq(hs, 2)
    att = ve_actq(D, 1)
    head = L * (nkv * (k + v) + nh * q)
    nhead = L * (2 * nkv + nh)
    print(f"{name}: ACTQ 호출 CYCLES K {k}, V {v}, q {q}, att(n {D}) {att}; head별 합 {head:,} ({nhead} 호출), "
          f"att 합 {L * att:,} ({L} 호출), ACTQ 합 {head + L * att:,}")
    core = 2 * hs + 59
    print(f"  F1(head별 ACTQ를 attention 앞단에): 제거되는 vec 호출 {nhead}, vec cycle {head:,}; "
          f"융합 단위가 순차로 하면 core {core} x {nhead} = {core * nhead:,} 추가 -> PL 순감 {head - core * nhead:,}; "
          f"앞 head 처리와 겹치면 PL 순감 최대 {head:,}")
    print(f"  F6(att ACTQ를 attention 출력단에): vec 호출 {L}, vec cycle {L * att:,}")
# F2: 생산자 경계 수와 그 데이터
for name, m in M.items():
    L, D, H = m["L"], m["D"], m["H"]
    nb = (2 * L + 1) + L + L
    byts = (2 * L + 1) * D + L * H + L * D
    print(f"{name}: F2(생산자 -> GEMV x 직결) 경계 {nb}개/token, q 데이터 {byts:,} B (+ scale 8 B씩), "
          f"쓰기+읽기 beat {2 * cd(byts, 8):,} 이하")
# F4: w1/w3 출력 -> SWIGLU, F5: IP로 보낼 수 있는 호출 수(embed, rope, add 제외)
for name, m in M.items():
    L, D, H, nh, nkv = m["L"], m["D"], m["H"], m["nh"], m["nkv"]
    print(f"{name}: F4 h1+h3 int32 {2 * 4 * H:,} B/layer; F5 IP 대상 호출 "
          f"{(2 * L + 1) + (7 * L + 1) + L * (2 * nkv + nh + 1) + nh * L + L + 1}/token "
          f"(embed 1, rope {2 * L}, add {2 * L} 제외)")
# 행 레코드의 header 비율(arch.md 2.2 정의: pad8 대비)과 int8 대비 증가
for name, m in M.items():
    ms = mats(m)
    pad8 = sum(r * cd(c, 8) * 8 for _, r, c in ms)
    rows = sum(r for _, r, _ in ms)
    w8 = sum(r * c for _, r, c in ms)
    print(f"{name}: header/pad8 {100 * 8 * rows / pad8:.2f}%, (header+padding)/int8 {100 * (pad8 + 8 * rows - w8) / w8:.2f}%")
