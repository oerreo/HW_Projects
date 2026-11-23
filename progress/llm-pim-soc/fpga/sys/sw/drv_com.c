/*
 * Common driver code (system.md 2.4): register writes through a shadow (only changed
 * descriptor registers are written), start + STATUS polling with a time limit, ERR handling
 * (W1C) and the IPERR log line.
 */
#include <string.h>
#include "hal.h"
#include "out.h"
#include "plat.h"
#include "sx.h"

static const char *const IPN[SLOT_N] = {"ga", "pi", "at", "ve"};

void dw(sx_t *x, int slot, uint32_t off, uint32_t v) {
  if (off >= 0x40u && off < 0x80u) {
    unsigned i = (off - 0x40u) / 4u;
    if (((x->shok[slot] >> i) & 1u) && x->shv[slot][i] == v) return;
    x->shv[slot][i] = v;
    x->shok[slot] |= 1u << i;
  }
  hal_wr(slot, off, v);
}

void dw_reset(sx_t *x, int slot) { x->shok[slot] = 0; }

/* response error bits per IP (ERR register layouts of the four spec documents) */
static uint32_t resp_bits(int slot) { return slot == SLOT_PI ? 0x60u : 0x30u; }

static void iperr_line(sx_t *x, int slot, const char *kind, uint32_t err) {
  x->iperr++;
  if (x->iperr_lines >= 16) return; /* bound the log; the count stays exact */
  x->iperr_lines++;
  o_key("IPERR");
  o_s("m", x->mname);
  o_s("v", x->vname);
  o_s("run", RK_NAME[x->kind]);
  o_x("mask", x->mask);
  o_x("opt", x->opt);
  o_s("ip", IPN[slot]);
  o_s("kind", kind);
  o_x("err", err);
  o_i("pos", x->pos);
  o_u("op", (uint64_t)x->nops);
  o_end();
}

int64_t sx_cyc_ticks(const sx_t *x, uint64_t cyc) {
  (void)x;
  return (int64_t)(cyc * plat_tps() / (uint64_t)SYS_FCLK_HZ);
}

int drv_go(sx_t *x, int slot, uint32_t op, uint64_t est_cyc, dres_t *r) {
  uint64_t tps = plat_tps(), lim, t;
  uint32_t st, err = 0;
  lim = est_cyc * 100u * tps / (uint64_t)SYS_FCLK_HZ;
  if (lim < tps / 1000000u * SYS_POLL_MIN_US) lim = tps / 1000000u * SYS_POLL_MIN_US;
  x->nops++; /* op counter of the run (IPERR reference) */
  hal_dsb();
  hal_wr(slot, R_CTRL, CTRL_GO(op));
  t = plat_now();
  do {
    st = hal_rd(slot, R_STATUS);
  } while ((st & ST_BUSY) && plat_now() - t < lim);
  if (x->meas && r) r->t3 = plat_now();
  if (st & ST_BUSY) {
    iperr_line(x, slot, "timeout", 0);
    x->sys->dead[slot] = 1;
    dw_reset(x, slot);
    return DRV_TIMEOUT;
  }
  if (st & ST_ERR) err = hal_rd(slot, R_ERR);
  if (r) {
    r->cyc = r->rd = r->wr = 0;
    if (x->meas) {
      r->cyc = hal_rd(slot, R_CYCLES);
      r->rd = hal_rd(slot, R_RD_STALL);
      r->wr = hal_rd(slot, R_WR_STALL);
    }
  }
  if (err) {
    hal_wr(slot, R_ERR, err); /* W1C */
    iperr_line(x, slot, "err", err);
    return ((err & ~resp_bits(slot)) == 0 && (st & ST_DONE)) ? DRV_RESP : DRV_ERR;
  }
  if (!(st & ST_DONE)) {
    iperr_line(x, slot, "nodone", st);
    return DRV_ERR;
  }
  return DRV_OK;
}
