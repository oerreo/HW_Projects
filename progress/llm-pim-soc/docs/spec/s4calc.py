# S4-0 arch.md의 [계산] 값(행 수, 가속기형 cycle, PIM bank 배치와 BRAM36 수, KV BRAM, attention cycle). 표준 라이브러리만, 인자 없음.
# 실행: python3 -I docs/spec/s4calc.py
import math
M = {"260K": dict(D=64, H=172, L=5, nh=8, nkv=4, voc=512, seq=512),
     "15M": dict(D=288, H=768, L=6, nh=6, nkv=6, voc=32000, seq=256)}
cd = lambda a, b: -(-a // b)

def mats(m):
    D, H, L = m["D"], m["H"], m["L"]
    hs = D // m["nh"]; kv = hs * m["nkv"]
    one = [("wq", D, D), ("wk", kv, D), ("wv", kv, D), ("wo", D, D), ("w1", H, D), ("w3", H, D), ("w2", D, H)]
    out = []
    for l in range(L):
        out += [(f"{n}{l}", r, c) for n, r, c in one]
    out.append(("cls", m["voc"], D))
    return out

for name, m in M.items():
    ms = mats(m)
    rows = sum(r for _, r, _ in ms)
    mac = sum(r * c for _, r, c in ms)
    pad8 = sum(r * cd(c, 8) * 8 for _, r, c in ms)
    print(name, "rows", rows, "mac", mac, "pad8 bytes", pad8, "pad8+hdr", pad8 + 8 * rows,
          "hdr ovh %.2f%%" % (100 * 8 * rows / pad8))
    # accel 1 port: beats = rows*(1+nw) + per-call x nw
    for P in (1, 2):
        beats = sum(cd(r, P) * (1 + cd(c, 8)) + cd(c, 8) for _, r, c in ms)
        print("  accel ports", P, "cycles/token (eta=1, rec fmt)", beats, "ms@100MHz %.3f" % (beats / 1e5))
    cls = [x for x in ms if x[0] == "cls"][0]
    print("  cls cycles 1port", cls[1] * (1 + cd(cls[2], 8)))

# PIM layouts for 260K
m = M["260K"]; ms = mats(m)
def pim(N, LB, mode):
    banks = [0] * N
    cyc = 0
    g = 0
    for _, r, c in ms:
        w = cd(c, LB)
        per = [0] * N
        for i in range(r):
            b = (i % N) if mode == "row" else ((g + i) % N)
            per[b] += 1
        if mode == "row":
            for b in range(N):
                banks[b] += cd(r, N) * w  # aligned base
        else:
            for b in range(N):
                banks[b] += per[b] * w
        g += r
        cyc += max(per) * w
    D = max(banks)
    wide = cd(LB * 8, 64)
    deep = cd(D, 512)
    return D, wide * deep * N, cyc

for N, LB in ((4, 16), (8, 8), (16, 8), (8, 16), (32, 8)):
    for mode in ("row", "glob"):
        D, b36, cyc = pim(N, LB, mode)
        print(f"PIM N={N} LB={LB} {mode}: depth {D} BRAM36 {b36} MACcyc/token {cyc} lanes {N*LB}")

# KV 260K
L, nkv, seq, hs = 5, 4, 512, 8
# word = K hs x 12 + V hs x 8 + ks + vs, each scale = m 17 bits (unsigned, m < 2^17) + e E_W bits.
# E_W = 8 (hierarchy.md 3.1; S4-1 range of ke/ve over the K12V8 dumps is 21..27, model/results/
# range_k12v8.txt) -> 25 bits per scale, 210 bits (arch.md 4.2). The old 24 + 24 (= 208) took the
# 24-bit scale of cost.py (e in 7 bits); both fit 216 = 3 x 72, the BRAM36 count is the same.
E_W = 8
bits = hs * 12 + hs * 8 + 2 * (17 + E_W)
print("KV word bits", bits, "BRAM36 (x72) per kvbank", cd(bits, 72) * cd(L * seq, 512), "total", nkv * cd(bits, 72) * cd(L * seq, 512))

# attention cycles
def attn(T, hs, KL, VL, kcyc=None, vcyc=None, C=80):
    p1 = T * (kcyc if kcyc else cd(hs, KL)); p3 = T * (vcyc if vcyc else cd(hs, VL))
    return p1 + T + p3 + C
for T in (1, 64, 256, 512):
    h = attn(T, 8, 8, 8)
    print("260K attn T", T, "per head", h, "per token HPAR2", 20 * h, "HPAR4", 10 * h)
for T in (1, 128, 256):
    h = attn(T, 48, 8, 8, kcyc=cd(48 * 2 + 16, 8), vcyc=cd(48, 8))
    print("15M attn T", T, "per head (DDR 1port)", h, "per token", 36 * h)
avg260 = sum(20 * attn(T, 8, 8, 8) for T in range(1, 513)) / 512
avg15 = sum(36 * attn(T, 48, 8, 8, kcyc=14, vcyc=6) for T in range(1, 257)) / 256
print("avg attn per token 260K HPAR2", avg260, "15M", avg15)
