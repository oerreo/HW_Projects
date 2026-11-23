/*
 * vec_top driver (vec.md 2, 4.4, system.md 2.4). The golden buffers are used as they are:
 * IN0 = x / h1 / v, IN1 = g / h3, OUT = q (ARGMAX: idx), SCL = scale.
 * ARGMAX: the index is read from ARGMAX_IDX and written to s->argmax[0] by the ARM.
 */
#include "hal.h"
#include "plat.h"
#include "sx.h"

int ve_call(sx_t *x, const kcall_t *c, dres_t *r) {
  const int32_t *P = c->prm;
  uint32_t op, n = (uint32_t)P[0], fmt = 0x0801007Fu, ex = 0, epsc = 0;
  uint32_t in0 = hal_pa(c->b[0].p), in1 = 0, out, scl = 0;
  uint64_t est;
  int rc;
  switch (c->kid) {
  case K_RMSNORM: /* prm n fx ge epsc fy mode; b x g | q s */
    op = VE_OP_RMS;
    in1 = hal_pa(c->b[1].p);
    out = hal_pa(c->b[2].p);
    scl = hal_pa(c->b[3].p);
    fmt = 127u | ((uint32_t)P[5] << 16) | (8u << 24);
    ex = ((uint32_t)P[4] & 0xFFu) | (((uint32_t)P[2] & 0xFFu) << 8);
    epsc = (uint32_t)P[3];
    est = 4u * n + 200u;
    break;
  case K_SWIGLU: /* prm n sb mode; b h1 h3 lut | q s */
    op = VE_OP_SWI;
    in1 = hal_pa(c->b[1].p);
    out = hal_pa(c->b[3].p);
    scl = hal_pa(c->b[4].p);
    fmt = 127u | ((uint32_t)P[2] << 16) | (((uint32_t)P[1] & 0xFu) << 24);
    est = 3u * n + 200u;
    break;
  case K_ACTQ: /* prm n f mode qmax; b v | q s */
    op = VE_OP_ACTQ;
    out = hal_pa(c->b[1].p);
    scl = hal_pa(c->b[2].p);
    fmt = ((uint32_t)P[3] & 0xFFFFu) | ((uint32_t)P[2] << 16) | (8u << 24);
    ex = (uint32_t)P[1] & 0xFFu;
    est = 2u * n + 200u;
    break;
  default: /* K_ARGMAX: prm n; b v | idx */
    op = VE_OP_AMAX;
    out = hal_pa(c->b[1].p);
    est = n + 64u;
    break;
  }
  if (x->opt & OPT_COH_STRICT) {
    int i;
    for (i = 0; i < c->nb; i++)
      if (c->b[i].out) hal_flush(c->b[i].p, (size_t)c->b[i].esz * (size_t)c->b[i].n);
  }
  if (x->meas) r->t0 = r->t1 = plat_now();
  dw(x, SLOT_VE, VE_IN0, in0);
  if (op == VE_OP_RMS || op == VE_OP_SWI) dw(x, SLOT_VE, VE_IN1, in1);
  dw(x, SLOT_VE, VE_OUT, out);
  if (op != VE_OP_AMAX) {
    dw(x, SLOT_VE, VE_SCL, scl);
    dw(x, SLOT_VE, VE_FMT, fmt);
    dw(x, SLOT_VE, VE_EXP, ex);
  }
  if (op == VE_OP_RMS) dw(x, SLOT_VE, VE_EPSC, epsc);
  if (FAULT(x, FX_REGORDER)) { /* register order: N written after the start */
    rc = drv_go(x, SLOT_VE, op, est, r);
    dw(x, SLOT_VE, VE_N, n);
  } else {
    dw(x, SLOT_VE, VE_N, n);
    rc = drv_go(x, SLOT_VE, op, est, r);
  }
  if (op == VE_OP_AMAX && (rc == DRV_OK || rc == DRV_RESP)) {
    uint32_t msk = x->sys->ve_idxw >= 32 ? 0xFFFFFFFFu : ((1u << x->sys->ve_idxw) - 1u);
    x->s->argmax[0] = (int32_t)(hal_rd(SLOT_VE, VE_AM_IDX) & msk);
    hal_arm_wr(x->s->argmax, 4);
    hal_flush(x->s->argmax, 4); /* ARM write: producer rule */
  }
  return rc;
}
