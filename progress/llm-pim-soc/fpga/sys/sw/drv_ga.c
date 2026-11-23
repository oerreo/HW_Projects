/*
 * gemv_acc_top driver (gemv_acc.md 3 "PS 호출 순서", system.md 2.4). One K_GEMV call = one
 * op. The row records were built and flushed at init; x (a8) is clean by the producer rule;
 * xm, xe come from the descriptor (fwd_h.c read them from `as`). y is invalidated by the
 * executor's choice (out_inv).
 */
#include "hal.h"
#include "plat.h"
#include "sx.h"

int ga_gemv(sx_t *x, const kcall_t *c, const smat_t *m, int am_en, dres_t *r) {
  const int32_t *P = c->prm;
  int rows = P[0], n = P[1], rc;
  uint32_t flags = GA_F_YEN | (am_en ? GA_F_ARGMAX : 0u);
  uint64_t est = (uint64_t)rows * (1u + ((uint32_t)n + 7u) / 8u) + (uint32_t)n / 8u + 64u;
  if (x->meas) r->t0 = r->t1 = plat_now();
  if (x->opt & OPT_COH_STRICT) hal_flush(c->b[3].p, 4u * (size_t)rows);
  dw(x, SLOT_GA, GA_W_ADDR, hal_pa(m->rrec));
  dw(x, SLOT_GA, GA_X_ADDR, hal_pa(c->b[2].p));
  dw(x, SLOT_GA, GA_Y_ADDR, hal_pa(c->b[3].p));
  dw(x, SLOT_GA, GA_ROWS, (uint32_t)rows);
  dw(x, SLOT_GA, GA_N, (uint32_t)n);
  dw(x, SLOT_GA, GA_XM, (uint32_t)P[4]);
  dw(x, SLOT_GA, GA_EXP,
     ((uint32_t)P[3] & 0xFFu) | (((uint32_t)P[5] & 0xFFu) << 8) | (((uint32_t)P[6] & 0xFFu) << 16));
  dw(x, SLOT_GA, GA_FLAGS, flags);
  rc = drv_go(x, SLOT_GA, GA_OP_GEMV, est, r);
  if (rc == DRV_OK || rc == DRV_RESP) {
    if (am_en) {
      x->s->argmax[0] = (int32_t)(hal_rd(SLOT_GA, GA_AM_IDX) & 0xFFFFu);
      hal_arm_wr(x->s->argmax, 4);
      hal_flush(x->s->argmax, 4); /* ARM write: producer rule */
    }
  }
  return rc;
}
