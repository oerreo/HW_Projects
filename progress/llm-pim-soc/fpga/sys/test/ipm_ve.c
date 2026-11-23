/*
 * Host model of vec_top from docs/spec/vec.md (layout 2, registers 3, CTRL 4.1, descriptor
 * check 4.2). Not the RTL. Ops: 1 RMSNORM k_rmsnorm, 2 SWIGLU k_swiglu with k_sig_lut(sb),
 * 3 ACTQ k_actq, 4 ARGMAX k_argmax (model/src); q to OUT_ADDR, {m, e} to SCL_ADDR, ARGMAX index
 * (int32) to OUT_ADDR and ARGMAX_IDX/VAL. fx of RMSNORM (not a register) is K_FX.
 * CYCLES: vec.md 6.2 closed form 1 + C + 11 + max(L_last, 2) with C of 6.1 (zero-output forms
 * when the pre-quantization maximum is 0), ARGMAX n + 15.
 * RD_STALL: vec.md 3, latency-1 value VE_RDST0 (the read start-up) for every op that runs;
 * WR_STALL 0.
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
#define VE_RDST0 4u /* RD_STALL of an op with no memory stall, latency 1 (vec.md 3) */

static struct {
  uint32_t in0, in1, out, scl, n, fmt, exp, epsc, am_idx, am_val;
  int busy, done;
  uint32_t err, cyc, rds, ops;
} V;

static uint32_t cdiv(uint32_t a, uint32_t b) { return (a + b - 1u) / b; }
static int sx8(uint32_t v) { return (int)(int8_t)(uint8_t)(v & 0xFFu); }

static int init(void) {
  memset(&V, 0, sizeof(V));
  V.fmt = 0x0801007Fu;
  return 0;
}

static uint32_t check(uint32_t op) {
  uint32_t n = V.n, qmax = V.fmt & 0xFFFFu, mode = (V.fmt >> 16) & 1u, sb = (V.fmt >> 24) & 0xFu;
  uint32_t ob = op == VE_OP_AMAX ? 4u : (op == VE_OP_ACTQ && qmax != 127u) ? 2u * n : n, e = 0;
  int bad = 0;
  uint64_t nlim = op == VE_OP_AMAX ? (1ull << IPC.ve_idxw) : (uint64_t)IPC.ve_nmax;
  if (n < 1 || n > nlim) bad = 1;
  if ((uint64_t)V.in0 + 4ull * n > 0x100000000ull || (uint64_t)V.out + ob > 0x100000000ull) bad = 1;
  if (op != VE_OP_AMAX) {
    if (mode != 1u || (uint64_t)V.scl + 8u > 0x100000000ull) bad = 1;
    if (op == VE_OP_ACTQ && qmax != 127u && qmax != 2047u && qmax != 32767u) bad = 1;
    if (op == VE_OP_SWI && sb != 8u) bad = 1;
    if (op == VE_OP_RMS && (int32_t)V.epsc < 0) bad = 1;
    if (op == VE_OP_RMS && (uint64_t)V.in1 + 2ull * n > 0x100000000ull) bad = 1;
    if (op == VE_OP_SWI && (uint64_t)V.in1 + 4ull * n > 0x100000000ull) bad = 1;
    if (V.scl & 7u) e |= E_MISALIGN;
  }
  if ((V.in0 & 7u) || (V.out & 7u) || ((op == VE_OP_RMS || op == VE_OP_SWI) && (V.in1 & 7u))) e |= E_MISALIGN;
  return e | (bad ? E_BAD_DESC : 0u);
}

static void run(uint32_t op, int fault) {
  uint32_t n = V.n, qmax = V.fmt & 0xFFFFu, mode = (V.fmt >> 16) & 1u, sb = (V.fmt >> 24) & 0xFu;
  uint32_t qb = (op == VE_OP_ACTQ && qmax != 127u) ? 2u : 1u, last = 0, C = 0;
  const uint8_t *a = mem_rd(V.in0, 4u * n), *b = NULL;
  int32_t *x = ipm_scr(0, 4u * (size_t)n), *y = ipm_scr(1, 4u * (size_t)n);
  int16_t *g = ipm_scr(2, 2u * (size_t)n);
  uint8_t *q = ipm_scr(3, 2u * (size_t)n), *d;
  kscl_t s;
  V.rds = VE_RDST0;
  if (!a || fault == 1) V.err |= E_RD_RESP;
  if (a) memcpy(x, a, 4u * n);
  else memset(x, 0, 4u * n);
  s.m = s.e = 0;
  if (op == VE_OP_RMS || op == VE_OP_SWI) {
    uint32_t bb = op == VE_OP_RMS ? 2u * n : 4u * n;
    b = mem_rd(V.in1, bb);
    if (!b) V.err |= E_RD_RESP;
    if (op == VE_OP_RMS) {
      if (b) memcpy(g, b, bb);
      else memset(g, 0, bb);
    } else {
      if (b) memcpy(y, b, bb);
      else memset(y, 0, bb);
    }
  }
  switch (op) {
  case VE_OP_RMS:
    k_rmsnorm(x, (int)n, K_FX, g, sx8(V.exp >> 8), (int32_t)V.epsc, sx8(V.exp), (int)mode, (int8_t *)q, &s);
    C = 4u * n + 87u;
    break;
  case VE_OP_SWI:
    k_swiglu(x, y, (int)n, (int)sb, k_sig_lut((int)sb), (int)mode, (int8_t *)q, &s);
    C = 3u * n + 67u;
    break;
  case VE_OP_ACTQ:
    k_actq(x, (int)n, sx8(V.exp), (int)mode, (int)qmax, q, &s);
    C = 2u * n + 59u;
    break;
  default: {
    int32_t idx = k_argmax(x, (int)n);
    V.am_idx = (uint32_t)idx & (IPC.ve_idxw >= 32 ? 0xFFFFFFFFu : ((1u << IPC.ve_idxw) - 1u));
    V.am_val = (uint32_t)x[idx];
    d = mem_wr(V.out, 4u);
    if (d) memcpy(d, &idx, 4);
    else V.err |= E_WR_RESP;
    V.cyc = n + 15u;
    return;
  }
  }
  /* zero output: the pre-quantization maximum is 0 (scale {0, 0}); vec.md 6.1 second column */
  if (s.m == 0) C -= 53u; /* 4n + 34, 3n + 14, 2n + 6 */
  d = mem_wr(V.out, n * qb);
  if (d) memcpy(d, q, n * qb);
  else V.err |= E_WR_RESP;
  d = mem_wr(V.scl, 8u);
  if (d) {
    memcpy(d, &s.m, 4);
    memcpy(d + 4, &s.e, 4);
  } else {
    V.err |= E_WR_RESP;
  }
  ipm_nburst(V.out, cdiv(n * qb, 8u), &last);
  V.cyc = 1u + C + 11u + (last > 2u ? last : 2u);
}

static void wr(uint32_t off, uint32_t v) {
  switch (off) {
  case R_CTRL: {
    uint32_t op = (v >> 4) & 0xFu, bad;
    int okop = op >= VE_OP_RMS && op <= VE_OP_AMAX, f;
    if (V.busy) {
      if (v & 1u) V.err |= E_START_BUSY | (okop ? 0u : E_BAD_OP);
      return;
    }
    if (!(v & 1u)) {
      V.done = 0;
      return;
    }
    if (!okop) {
      V.err |= E_BAD_OP;
      return;
    }
    V.done = 0;
    V.cyc = 0;
    V.rds = 0;
    bad = check(op);
    if (bad) {
      V.err |= bad;
      V.cyc = 1;
      return;
    }
    f = ipm_fault(SLOT_VE);
    if (f == 2) {
      V.busy = 1;
      return;
    }
    run(op, f);
    V.done = 1;
    V.ops++;
    return;
  }
  case R_ERR: V.err &= ~v; return;
  case VE_IN0: V.in0 = v; return;
  case VE_IN1: V.in1 = v; return;
  case VE_OUT: V.out = v; return;
  case VE_SCL: V.scl = v; return;
  case VE_N: V.n = v; return;
  case VE_FMT: V.fmt = v & 0x0F01FFFFu; return;
  case VE_EXP: V.exp = v & 0xFFFFu; return;
  case VE_EPSC: V.epsc = v; return;
  default: return;
  }
}

static uint32_t rd(uint32_t off) {
  switch (off) {
  case R_ID: return VE_ID;
  case R_CONFIG: return (uint32_t)IPC.fclk | ((uint32_t)IPC.ve_idxw << 8) | ((uint32_t)IPC.ve_nmax << 16);
  case R_STATUS: return (V.busy ? ST_BUSY : 0u) | (V.done ? ST_DONE : 0u) | (V.err ? ST_ERR : 0u);
  case R_ERR: return V.err;
  case R_CYCLES: return V.cyc;
  case R_RD_STALL: return V.rds;
  case R_WR_STALL: return 0;
  case R_OPS: return V.ops;
  case VE_AM_IDX: return V.am_idx;
  case VE_AM_VAL: return V.am_val;
  case VE_IN0: return V.in0;
  case VE_IN1: return V.in1;
  case VE_OUT: return V.out;
  case VE_SCL: return V.scl;
  case VE_N: return V.n;
  case VE_FMT: return V.fmt;
  case VE_EXP: return V.exp;
  case VE_EPSC: return V.epsc;
  default: return 0;
  }
}

const ipm_t IPM_VE = {rd, wr, init};
