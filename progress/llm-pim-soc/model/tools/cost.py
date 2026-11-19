"""Memory cost of the H formats (calculation only, no measurement). Prints the tables of
numeric.md section 11. Standard library only, no arguments.

Assumptions (stated in numeric.md):
- weights: int8 per parameter, one 16-bit mantissa per (row, group), rmsnorm gains int16,
  RoPE table int16 [seq_len][head_size], exp/sigmoid LUT 257 x 17 bit each, rsqrt seed
  48 x 16 bit. The classifier shares the embedding.
- KV cache: kbits per K element and vbits per V element, packed (12 bit is packed three per
  36-bit BRAM word). One scale per (position, layer, kv head, K or V): 17-bit mantissa +
  7-bit exponent = 24 bit.
- BRAM: XC7Z020 140 x BRAM36. Data capacity 32 Kib per BRAM36 for 8/16-bit words
  (560 KiB total); 36 Kib when the parity bits carry data (9/18/36-bit words, e.g. three
  12-bit or 24-bit fields). A byte total is a lower bound: port and depth granularity and
  other users (buffers, FIFOs, DMA) are ignored.
"""

MODELS = {
    "260K": dict(dim=64, hid=172, L=5, nh=8, nkv=4, voc=512, seq=512),
    "15M": dict(dim=288, hid=768, L=6, nh=6, nkv=6, voc=32000, seq=256),
}


def lm_group(n, target):
    if target <= 0:
        return n
    for g in range(min(n, target), 0, -1):
        if n % g == 0:
            return g
    return 1


def weights(m, wgs):
    D, H, L = m["dim"], m["hid"], m["L"]
    hs = D // m["nh"]
    kv = hs * m["nkv"]
    mats = [(D, D), (kv, D), (kv, D), (D, D), (H, D), (D, H), (H, D)]  # (rows, n)
    params, mant = 0, 0
    for rows, n in mats:
        params += L * rows * n
        mant += L * rows * (n // lm_group(n, wgs))
    params += m["voc"] * D
    mant += m["voc"] * (D // lm_group(D, wgs))
    gains = (2 * L + 1) * D
    rope = m["seq"] * hs
    w_bits = params * 8
    other_bits = mant * 16 + gains * 16 + rope * 16 + 2 * 257 * 17 + 48 * 16
    return params, w_bits, other_bits


def kv_bits(m, ctx, kb, vb):
    hs = m["dim"] // m["nh"]
    slots = m["L"] * m["nkv"]
    k = ctx * slots * hs * kb
    v = ctx * slots * hs * vb
    s = ctx * slots * 2 * 24
    return k, v, s


def bram36(bits, width_bits):
    # 8 and 16 bit data words use 32 Kib per BRAM36, others are packed into 36-bit words
    per = 32768 if width_bits in (8, 16) else 36864
    return bits / per


def main():
    KiB = 8 * 1024
    print("# weights [calc]")
    print("# model wgs params int8_KiB mant+gain+rope+lut_KiB total_KiB BRAM36_lb")
    for name, m in MODELS.items():
        for wgs in (0, 64):
            p, wb, ob = weights(m, wgs)
            br = bram36(wb, 8) + bram36(ob, 16)
            print("w %s %s %d %.1f %.1f %.1f %.1f" % (name, "row" if wgs == 0 else "g64", p,
                                                 wb / KiB, ob / KiB, (wb + ob) / KiB, br))
    print("# KV cache [calc]: model ctx K V | K_KiB V_KiB scale_KiB total_KiB BRAM36_lb")
    for name, m in MODELS.items():
        ctxs = (512, 256, 128) if name == "260K" else (256, 128, 64)
        for ctx in ctxs:
            for kb, vb in ((8, 8), (8, 12), (8, 16), (12, 8), (12, 12), (12, 16), (16, 8),
                           (16, 12), (16, 16)):
                k, v, s = kv_bits(m, ctx, kb, vb)
                br = bram36(k, kb) + bram36(v, vb) + bram36(s, 24)
                print("kv %s %d %d %d %.1f %.1f %.1f %.1f %.1f" % (name, ctx, kb, vb, k / KiB,
                                                                  v / KiB, s / KiB,
                                                                  (k + v + s) / KiB, br))
    print("# DDR traffic per token at T = ctx [calc]: model ctx K V | KV_read_B weights_B ratio")
    for name, m in MODELS.items():
        ctx = m["seq"]
        p, wb, ob = weights(m, 0)
        for kb, vb in ((8, 8), (8, 12), (12, 12), (16, 16)):
            k, v, s = kv_bits(m, ctx, kb, vb)
            kvb = (k + v + s) / 8
            print("bw %s %d %d %d %.0f %.0f %.4f" % (name, ctx, kb, vb, kvb, p, kvb / p))


if __name__ == "__main__":
    main()
