/*
 * Host model of attn_top from docs/spec/attn.md (layout 2, registers 3, CTRL 4.1, descriptor
 * check 4.2). Not the RTL. ATTN: for each head h of HEAD0 .. HEAD0 + NHEAD - 1 the q record at
 * Q_ADDR + h QB ({int32 qm, int32 qe, int16 q[hs]}), K/V of kv head h / KVMUL from the DDR
 * layout (KV_SRC 1) or from the model's kv store (KV_SRC 0, filled by KVW), k_attn2_st
 * (model/src) with the exp2 table of 8 bits (the IP ROM); o to O_ADDR + 4 hs h, p (p_en) to
 * P_ADDR + 8 ceil(T/2) h. KVW: K row, V row, K and V scale of slot j SEQ + POS for the kv heads
 * KVH0 .. KVH0 + NKVH - 1 into store[j][LAYER][POS].
 * CYCLES [estimate built from the attn.md 6.1 core form and the 6.2 fits]: per head
 * C = (T + 1) ceil(hs/8) + T + T b3 + hs + 60 + 8 (BRAM) or T b1 + ... + 18 (DDR, b1 = K beats
 * + 2 scale beats per position, b3 = V beats), heads of one engine in sequence, the busiest
 * engine + 31 + CHK_CYC (10 BRAM, 18 DDR). KVW: 48.
 */
#include <stdlib.h>
#include <string.h>
#include "ipm.h"
#include "ipregs.h"
#include "llm.h"

#define E_START_BUSY 0x01u
#define E_BAD_OP 0x02u
#define E_BAD_DESC 0x04u
#define E_MISALIGN 0x08u
#define E_RD_RESP 0x10u
#define E_WR_RESP 0x20u
#define KL 8

typedef struct {
  int16_t k[KL], v[KL];
  kscl_t ks, vs;
} kvw_t;

static struct {
  uint32_t q, o, p, k, v, ks, vs, t, hs, fmt, head, layer, seq, pos, kvh;
  int busy, done;
  uint32_t err, cyc, ops;
  kvw_t *store; /* [NKV][NL][TMAX] */
} A;

static uint32_t cdiv(uint32_t a, uint32_t b) { return (a + b - 1u) / b; }
static int okb(uint32_t b) { return b == 8u || b == 12u || b == 16u; }

static int init(void) {
  memset(&A, 0, sizeof(A));
  if (!IPC.at_kvsrc) {
    size_t n = (size_t)IPC.at_nkv * (size_t)IPC.at_nl * (size_t)IPC.at_tmax;
    A.store = ipm_scr(6, sizeof(kvw_t) * n);
    if (!A.store) return 1;
    memset(A.store, 0, sizeof(kvw_t) * n);
  }
  return 0;
}

static kvw_t *slot(uint32_t j, uint32_t l, uint32_t t) {
  return A.store + ((size_t)j * (size_t)IPC.at_nl + l) * (size_t)IPC.at_tmax + t;
}

/* attn.md 4.2; returns error bits */
static uint32_t check(int kvw) {
  uint32_t kb = A.fmt & 0x1Fu, vb = (A.fmt >> 8) & 0x1Fu, hs = A.hs, T = A.t, pen = (A.fmt >> 16) & 1u;
  uint32_t h0 = A.head & 0xFFu, nh = (A.head >> 8) & 0xFFu, kvmul = (A.head >> 16) & 0xFFu;
  uint32_t ek = kb > 8u ? 2u : 1u, ev = vb > 8u ? 2u : 1u, e = 0, qb = 8u + 2u * hs;
  int bad = 0;
  if (!okb(kb) || !okb(vb) || hs == 0 || hs % 8u || hs > (uint32_t)IPC.at_hsmax) bad = 1;
  if (!kvw) {
    uint32_t kvl = kvmul ? (h0 + nh - 1u) / kvmul : 0u;
    if (T < 1 || T > (uint32_t)IPC.at_tmax || nh < 1 || kvmul < 1 || h0 + nh > 256u) bad = 1;
    if ((uint64_t)A.q + (uint64_t)(h0 + nh) * qb > 0x100000000ull ||
        (uint64_t)A.o + 4ull * hs * (h0 + nh) > 0x100000000ull ||
        (pen && (uint64_t)A.p + 8ull * cdiv(T, 2u) * (h0 + nh) > 0x100000000ull))
      bad = 1;
    if (!IPC.at_kvsrc) {
      if (hs > KL || kb > (uint32_t)IPC.at_kw || vb > (uint32_t)IPC.at_vw || A.layer >= (uint32_t)IPC.at_nl ||
          (nh >= 1 && kvmul >= 1 && kvl >= (uint32_t)IPC.at_nkv))
        bad = 1;
    } else if (!bad) {
      uint64_t last = (uint64_t)kvl * A.seq + T; /* slots up to position T - 1 */
      if (T > A.seq || (uint64_t)A.k + last * hs * ek > 0x100000000ull ||
          (uint64_t)A.v + last * hs * ev > 0x100000000ull || (uint64_t)A.ks + 8u * last > 0x100000000ull ||
          (uint64_t)A.vs + 8u * last > 0x100000000ull)
        bad = 1;
    }
    if ((A.q & 7u) || (A.o & 7u) || (pen && (A.p & 7u)) ||
        (IPC.at_kvsrc && ((A.k | A.v | A.ks | A.vs) & 7u)))
      e |= E_MISALIGN;
  } else {
    uint32_t k0 = A.kvh & 0xFFu, nk = (A.kvh >> 8) & 0xFFu;
    uint64_t last = (uint64_t)(k0 + nk - 1u) * A.seq + A.pos + 1u;
    if (hs > KL || kb > (uint32_t)IPC.at_kw || vb > (uint32_t)IPC.at_vw || nk < 1 ||
        k0 + nk > (uint32_t)IPC.at_nkv || A.pos >= (uint32_t)IPC.at_tmax || A.pos >= A.seq ||
        A.layer >= (uint32_t)IPC.at_nl)
      bad = 1;
    if (!bad && ((uint64_t)A.k + last * hs * ek > 0x100000000ull ||
                 (uint64_t)A.v + last * hs * ev > 0x100000000ull ||
                 (uint64_t)A.ks + 8u * last > 0x100000000ull || (uint64_t)A.vs + 8u * last > 0x100000000ull))
      bad = 1;
    if ((A.k | A.v | A.ks | A.vs) & 7u) e |= E_MISALIGN;
  }
  return e | (bad ? E_BAD_DESC : 0u);
}

static int16_t ld(const uint8_t *p, int esz) {
  if (esz == 1) return (int16_t)(int8_t)p[0];
  return (int16_t)(uint16_t)(p[0] | (p[1] << 8));
}

static void kvw(int fault) {
  uint32_t kb = A.fmt & 0x1Fu, vb = (A.fmt >> 8) & 0x1Fu, hs = A.hs, j;
  uint32_t ek = kb > 8u ? 2u : 1u, ev = vb > 8u ? 2u : 1u;
  uint32_t k0 = A.kvh & 0xFFu, nk = (A.kvh >> 8) & 0xFFu;
  for (j = k0; j < k0 + nk; j++) {
    uint64_t s = (uint64_t)j * A.seq + A.pos;
    const uint8_t *K = mem_rd(A.k + (uint32_t)(s * hs * ek), hs * ek);
    const uint8_t *V = mem_rd(A.v + (uint32_t)(s * hs * ev), hs * ev);
    const uint8_t *KS = mem_rd(A.ks + (uint32_t)(8u * s), 8u), *VS = mem_rd(A.vs + (uint32_t)(8u * s), 8u);
    kvw_t *w = slot(j, A.layer, A.pos);
    uint32_t i;
    if (!K || !V || !KS || !VS || fault == 1) A.err |= E_RD_RESP;
    memset(w, 0, sizeof(*w));
    for (i = 0; i < hs; i++) {
      w->k[i] = K ? ld(K + i * ek, (int)ek) : 0;
      w->v[i] = V ? ld(V + i * ev, (int)ev) : 0;
    }
    if (KS) memcpy(&w->ks, KS, 8);
    if (VS) memcpy(&w->vs, VS, 8);
  }
  A.cyc = 48;
}

static void attn(int fault) {
  uint32_t kb = A.fmt & 0x1Fu, vb = (A.fmt >> 8) & 0x1Fu, hs = A.hs, T = A.t, pen = (A.fmt >> 16) & 1u;
  uint32_t h0 = A.head & 0xFFu, nh = (A.head >> 8) & 0xFFu, kvmul = (A.head >> 16) & 0xFFu;
  uint32_t ek = kb > 8u ? 2u : 1u, ev = vb > 8u ? 2u : 1u, qb = 8u + 2u * hs, h, t, i;
  uint32_t ps = 8u * cdiv(T, 2u), eng[8] = {0}, nhb = cdiv(hs, 8u), mx = 0;
  int8_t *q8 = ipm_scr(0, 2u * hs);
  uint8_t *K = ipm_scr(1, (size_t)T * hs * 2u), *V = ipm_scr(2, (size_t)T * hs * 2u);
  kscl_t *ks = ipm_scr(3, 8u * (size_t)T), *vs = ipm_scr(4, 8u * (size_t)T);
  int32_t *p = ipm_scr(5, 4u * (size_t)T), o[256];
  for (h = h0; h < h0 + nh; h++) {
    const uint8_t *rec = mem_rd(A.q + h * qb, qb);
    uint32_t kvh = h / kvmul;
    kscl_t qs;
    uint8_t *d;
    if (!rec || fault == 1) A.err |= E_RD_RESP;
    qs.m = qs.e = 0;
    memset(q8, 0, 2u * hs);
    if (rec) {
      memcpy(&qs.m, rec, 4);
      memcpy(&qs.e, rec + 4, 4);
      for (i = 0; i < hs; i++) {
        int16_t v = ld(rec + 8 + 2 * i, 2);
        if (ek == 1) q8[i] = (int8_t)v;
        else memcpy(q8 + 2 * i, &v, 2);
      }
    }
    if (IPC.at_kvsrc) {
      uint64_t s = (uint64_t)kvh * A.seq;
      const uint8_t *Kd = mem_rd(A.k + (uint32_t)(s * hs * ek), T * hs * ek);
      const uint8_t *Vd = mem_rd(A.v + (uint32_t)(s * hs * ev), T * hs * ev);
      const uint8_t *KS = mem_rd(A.ks + (uint32_t)(8u * s), 8u * T), *VS = mem_rd(A.vs + (uint32_t)(8u * s), 8u * T);
      if (!Kd || !Vd || !KS || !VS) A.err |= E_RD_RESP;
      if (Kd) memcpy(K, Kd, (size_t)T * hs * ek); else memset(K, 0, (size_t)T * hs * ek);
      if (Vd) memcpy(V, Vd, (size_t)T * hs * ev); else memset(V, 0, (size_t)T * hs * ev);
      if (KS) memcpy(ks, KS, 8u * T); else memset(ks, 0, 8u * T);
      if (VS) memcpy(vs, VS, 8u * T); else memset(vs, 0, 8u * T);
    } else {
      for (t = 0; t < T; t++) {
        const kvw_t *w = slot(kvh, A.layer, t);
        for (i = 0; i < hs; i++) {
          if (ek == 1) ((int8_t *)K)[t * hs + i] = (int8_t)w->k[i];
          else ((int16_t *)K)[t * hs + i] = w->k[i];
          if (ev == 1) ((int8_t *)V)[t * hs + i] = (int8_t)w->v[i];
          else ((int16_t *)V)[t * hs + i] = w->v[i];
        }
        ks[t] = w->ks;
        vs[t] = w->vs;
      }
    }
    k_attn2_st((int)T, (int)hs, (int)kb, (int)vb, q8, qs, K, ks, V, vs, 8, k_exp_lut(8), p, o, NULL);
    d = mem_wr(A.o + 4u * hs * h, 4u * hs);
    if (d) memcpy(d, o, 4u * hs);
    else A.err |= E_WR_RESP;
    if (pen) {
      d = mem_wr(A.p + ps * h, 4u * T);
      if (d) memcpy(d, p, 4u * T);
      else A.err |= E_WR_RESP;
    }
    { /* cycle estimate of this head on its engine */
      uint32_t b1 = IPC.at_kvsrc ? cdiv(hs * ek, 8u) + 2u : nhb, b3 = IPC.at_kvsrc ? cdiv(hs * ev, 8u) : nhb;
      uint32_t c = nhb + T * b1 + T + T * b3 + hs + 60u + (IPC.at_kvsrc ? 18u : 8u);
      uint32_t e = (kvh % (uint32_t)(IPC.at_hpar ? IPC.at_hpar : 1));
      eng[e & 7u] += c;
    }
  }
  for (i = 0; i < 8; i++)
    if (eng[i] > mx) mx = eng[i];
  A.cyc = mx + 31u + (IPC.at_kvsrc ? 18u : 10u);
}

static void wr(uint32_t off, uint32_t v) {
  switch (off) {
  case R_CTRL: {
    uint32_t op = (v >> 4) & 0xFu, bad;
    int okop = op == AT_OP_ATTN || (op == AT_OP_KVW && !IPC.at_kvsrc), f;
    if (A.busy) {
      if (v & 1u) A.err |= E_START_BUSY | (okop ? 0u : E_BAD_OP);
      return;
    }
    if (!(v & 1u)) {
      A.done = 0;
      return;
    }
    if (!okop) {
      A.err |= E_BAD_OP;
      return;
    }
    A.done = 0;
    A.cyc = 0;
    bad = check(op == AT_OP_KVW);
    if (bad) {
      A.err |= bad;
      A.cyc = IPC.at_kvsrc ? 18u : 10u;
      return;
    }
    f = ipm_fault(SLOT_AT);
    if (f == 2) {
      A.busy = 1;
      return;
    }
    if (op == AT_OP_KVW) kvw(f);
    else attn(f);
    A.done = 1;
    A.ops++;
    return;
  }
  case R_ERR: A.err &= ~v; return;
  case AT_Q_ADDR: A.q = v; return;
  case AT_O_ADDR: A.o = v; return;
  case AT_P_ADDR: A.p = v; return;
  case AT_K_ADDR: A.k = v; return;
  case AT_V_ADDR: A.v = v; return;
  case AT_KS_ADDR: A.ks = v; return;
  case AT_VS_ADDR: A.vs = v; return;
  case AT_T: A.t = v & 0xFFFFu; return;
  case AT_HS: A.hs = v & 0xFFu; return;
  case AT_FMT: A.fmt = v & 0x11F1Fu; return;
  case AT_HEAD: A.head = v & 0xFFFFFFu; return;
  case AT_LAYER: A.layer = v & 0xFFu; return;
  case AT_SEQ: A.seq = v & 0xFFFFu; return;
  case AT_POS: A.pos = v & 0xFFFFu; return;
  case AT_KVH: A.kvh = v & 0xFFFFu; return;
  default: return;
  }
}

static uint32_t rd(uint32_t off) {
  switch (off) {
  case R_ID: return AT_ID;
  case R_CONFIG:
    return (uint32_t)IPC.fclk | ((uint32_t)IPC.at_hpar << 8) | ((uint32_t)IPC.at_kvsrc << 11) | (3u << 12) |
           ((uint32_t)IPC.at_tmax << 16);
  case R_STATUS: return (A.busy ? ST_BUSY : 0u) | (A.done ? ST_DONE : 0u) | (A.err ? ST_ERR : 0u);
  case R_ERR: return A.err;
  case R_CYCLES: return A.cyc;
  case R_RD_STALL: return 0;
  case R_WR_STALL: return 0;
  case R_OPS: return A.ops;
  case AT_CONFIG2:
    return IPC.at_kvsrc ? (uint32_t)IPC.at_hsmax
                        : (uint32_t)IPC.at_hsmax | ((uint32_t)IPC.at_nkv << 8) | ((uint32_t)IPC.at_nl << 16);
  case AT_CONFIG3:
    return IPC.at_kvsrc ? 0u : (uint32_t)IPC.at_kw | ((uint32_t)IPC.at_vw << 8) | ((uint32_t)IPC.at_tmax << 16);
  case AT_Q_ADDR: return A.q;
  case AT_O_ADDR: return A.o;
  case AT_P_ADDR: return A.p;
  case AT_K_ADDR: return A.k;
  case AT_V_ADDR: return A.v;
  case AT_KS_ADDR: return A.ks;
  case AT_VS_ADDR: return A.vs;
  case AT_T: return A.t;
  case AT_HS: return A.hs;
  case AT_FMT: return A.fmt;
  case AT_HEAD: return A.head;
  case AT_LAYER: return A.layer;
  case AT_SEQ: return A.seq;
  case AT_POS: return A.pos;
  case AT_KVH: return A.kvh;
  default: return 0;
  }
}

const ipm_t IPM_AT = {rd, wr, init};
