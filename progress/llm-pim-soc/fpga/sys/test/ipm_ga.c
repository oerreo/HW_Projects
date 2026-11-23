/*
 * Host model of gemv_acc_top from docs/spec/gemv_acc.md (register map 2, call rules 3,
 * CYCLES 5). Not the RTL. Result: rrec_unpack of the row records at W_ADDR, then k_gemv
 * (model/src) with x at X_ADDR; y to Y_ADDR (y_en), first maximum to ARGMAX_IDX/VAL
 * (argmax_en, k_argmax). CYCLES: closed forms of section 5 for P = 1 (latency 1, no stall,
 * the "usual" case without a W burst blocked by the previous one); P = 2 uses ceil(ROWS/2)
 * in the same form + 1 for even ROWS (section 5 item 6) [estimate; equal to the RTL on all
 * 260K calls of the S5-4 system TB, all with even ROWS]. RD_STALL = 5 per call (section 5
 * note), WR_STALL = 0.
 */
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
#define C_CHK 9u

static struct {
  uint32_t w, x, y, rows, n, xm, exp, flags, am_idx, am_val;
  int busy, done;
  uint32_t err, cyc, rds, wrs, ops;
} G;

static int init(void) {
  memset(&G, 0, sizeof(G));
  G.flags = GA_F_YEN;
  return 0;
}

static uint32_t cdiv(uint32_t a, uint32_t b) { return (a + b - 1u) / b; }
static int sx8(uint32_t v) { return (int)(int8_t)(uint8_t)(v & 0xFFu); }

/* returns 0 when the op ran, -1 when the descriptor was rejected */
static int run(int fault) {
  uint32_t rows = G.rows, n = G.n, yen = (G.flags >> 1) & 1u, amen = G.flags & 1u;
  uint64_t rb = 8u * (1u + (uint64_t)cdiv(n, 8u));
  int bad = 0, mis = 0;
  if (rows == 0 || rows > 65535u || n == 0 || n > (uint32_t)IPC.ga_nmax || !(G.flags & 3u)) bad = 1;
  if (!bad && ((uint64_t)G.w + rows * rb > 0x100000000ull || (uint64_t)G.x + n > 0x100000000ull ||
               (yen && (uint64_t)G.y + 4u * (uint64_t)rows > 0x100000000ull)))
    bad = 1;
  if ((G.w & 7u) || (G.x & 7u) || (yen && (G.y & 7u))) mis = 1;
  if (bad || mis) {
    G.err |= (bad ? E_BAD_DESC : 0u) | (mis ? E_MISALIGN : 0u);
    G.cyc = C_CHK;
    return -1;
  }
  {
    const uint8_t *rec = mem_rd(G.w, (uint32_t)(rows * rb)), *xv = mem_rd(G.x, n);
    int8_t *W = ipm_scr(0, (size_t)rows * n), *xx = ipm_scr(1, n);
    uint16_t *wm = ipm_scr(2, 2u * (size_t)rows);
    int32_t *y = ipm_scr(3, 4u * (size_t)rows);
    kscl_t xs;
    if (!rec || !xv || fault == 1) G.err |= E_RD_RESP;
    if (rec) rrec_unpack(rec, (int)rows, (int)n, W, wm);
    else {
      memset(W, 0, (size_t)rows * n);
      memset(wm, 0, 2u * (size_t)rows);
    }
    if (xv) memcpy(xx, xv, n);
    else memset(xx, 0, n);
    xs.m = (int32_t)G.xm;
    xs.e = sx8(G.exp >> 8);
    k_gemv(W, wm, sx8(G.exp), (int)rows, (int)n, (int)n, xx, xs, sx8(G.exp >> 16), y);
    if (yen) {
      uint8_t *d = mem_wr(G.y, 4u * rows);
      if (d) memcpy(d, y, 4u * (size_t)rows);
      else G.err |= E_WR_RESP;
    }
    if (amen) {
      int i = k_argmax(y, (int)rows);
      G.am_idx = (uint32_t)i & 0xFFFFu;
      G.am_val = (uint32_t)y[i];
    }
  }
  { /* CYCLES, gemv_acc.md 5 */
    uint32_t nb = cdiv(n, 8u), last = 0, R = IPC.ga_p == 2 ? cdiv(rows, 2u) : rows;
    int mx = ipm_nburst(G.x, nb, NULL);
    uint32_t xd = (uint32_t)mx + 1u > nb ? (uint32_t)mx + 1u - nb : 0u;
    if (yen) {
      ipm_nburst(G.y, cdiv(rows, 2u), &last);
      G.cyc = nb + R * (1u + nb) + 19u + xd + last + C_CHK;
    } else {
      G.cyc = nb + R * (1u + nb) + 15u + xd + C_CHK;
    }
    /* gemv_acc.md 5 item 6: P = 2 with even ROWS, the last row comes from slice 1 and the merge
       takes it one cycle later (S5-4: the RTL system TB showed +1 on every such call) */
    if (IPC.ga_p == 2 && !(rows & 1u)) G.cyc += 1u;
    G.rds = 5u;
    G.wrs = 0u;
  }
  return 0;
}

static void wr(uint32_t off, uint32_t v) {
  switch (off) {
  case R_CTRL: {
    uint32_t op = (v >> 4) & 0xFu;
    int f;
    if (G.busy) {
      if (v & 1u) G.err |= E_START_BUSY | (op != GA_OP_GEMV ? E_BAD_OP : 0u);
      return;
    }
    if (!(v & 1u)) {
      G.done = 0;
      return;
    }
    if (op != GA_OP_GEMV) {
      G.err |= E_BAD_OP;
      return;
    }
    G.done = 0;
    G.cyc = G.rds = G.wrs = 0;
    f = ipm_fault(SLOT_GA);
    if (f == 2) {
      G.busy = 1; /* never ends */
      return;
    }
    if (run(f) == 0) {
      G.done = 1;
      G.ops++;
    }
    return;
  }
  case R_ERR: G.err &= ~v; return;
  case GA_W_ADDR: G.w = v; return;
  case GA_X_ADDR: G.x = v; return;
  case GA_Y_ADDR: G.y = v; return;
  case GA_ROWS: G.rows = v; return;
  case GA_N: G.n = v; return;
  case GA_XM: G.xm = v & 0x1FFFFu; return;
  case GA_EXP: G.exp = v & 0xFFFFFFu; return;
  case GA_FLAGS: G.flags = v & 3u; return;
  default: return;
  }
}

static uint32_t rd(uint32_t off) {
  switch (off) {
  case R_ID: return GA_ID;
  case R_CONFIG:
    return (uint32_t)IPC.fclk | ((uint32_t)IPC.ga_p << 8) | (3u << 12) | ((uint32_t)IPC.ga_nmax << 16);
  case R_STATUS: return (G.busy ? ST_BUSY : 0u) | (G.done ? ST_DONE : 0u) | (G.err ? ST_ERR : 0u);
  case R_ERR: return G.err;
  case R_CYCLES: return G.cyc;
  case R_RD_STALL: return G.rds;
  case R_WR_STALL: return G.wrs;
  case R_OPS: return G.ops;
  case GA_W_ADDR: return G.w;
  case GA_X_ADDR: return G.x;
  case GA_Y_ADDR: return G.y;
  case GA_ROWS: return G.rows;
  case GA_N: return G.n;
  case GA_XM: return G.xm;
  case GA_EXP: return G.exp;
  case GA_FLAGS: return G.flags;
  case GA_AM_IDX: return G.am_idx;
  case GA_AM_VAL: return G.am_val;
  default: return 0;
  }
}

const ipm_t IPM_GA = {rd, wr, init};
