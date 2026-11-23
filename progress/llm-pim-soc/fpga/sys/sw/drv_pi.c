/*
 * pim_top driver (pim.md 2, 4.3, system.md 2.3 step 4, 2.4). Commands are built in CMD0..3
 * (shadowed: unchanged words are not rewritten) and pushed; before every push STATUS is read
 * for the FIFO level and push_busy (pim.md 4.3 push rule). RUN executes the FIFO; commands
 * that were pushed after the run ended start a second RUN.
 */
#include "hal.h"
#include "plat.h"
#include "sx.h"

static uint32_t cdiv(uint32_t a, uint32_t b) { return (a + b - 1u) / b; }

int pi_push(sx_t *x, uint32_t op, int n, int rows, int32_t xm, long base, uint32_t addr, int we,
            int xe, int fo) {
  uint32_t st;
  uint64_t t = plat_now();
  do {
    st = hal_rd(SLOT_PI, R_STATUS);
  } while ((st & PI_ST_PUSHBUSY) && plat_now() - t < plat_tps() / 1000u);
  if ((st & PI_ST_PUSHBUSY) || PI_ST_LEVEL(st) >= (uint32_t)x->sys->pi_cmdd) return DRV_FULL;
  dw(x, SLOT_PI, PI_CMD0, (op & 0xFu) | (((uint32_t)n & 0xFFFu) << 4) | ((uint32_t)rows << 16));
  dw(x, SLOT_PI, PI_CMD1, ((uint32_t)xm & 0x1FFFFu) | ((uint32_t)base << 17));
  dw(x, SLOT_PI, PI_CMD2, addr);
  dw(x, SLOT_PI, PI_CMD3,
     ((uint32_t)we & 0xFFu) | (((uint32_t)xe & 0xFFu) << 8) | (((uint32_t)fo & 0xFFu) << 16));
  hal_wr(SLOT_PI, PI_CMD_PUSH, 1u);
  return DRV_OK;
}

int pi_run(sx_t *x, uint64_t est_cyc, dres_t *r) {
  int rc, k;
  uint32_t cyc = 0, rd = 0, wr = 0;
  for (k = 0; k < 64; k++) {
    rc = drv_go(x, SLOT_PI, PI_OP_RUN, est_cyc, r);
    if (r) {
      cyc += r->cyc;
      rd += r->rd;
      wr += r->wr;
    }
    if (rc != DRV_OK) break;
    if (PI_ST_LEVEL(hal_rd(SLOT_PI, R_STATUS)) == 0) break; /* pushed after the run ended */
  }
  if (r) {
    r->cyc = cyc;
    r->rd = rd;
    r->wr = wr;
  }
  return rc;
}

/* system.md 2.3 step 4: one LDW per matrix (bank bases from sx_init), FIFO-sized pieces */
int pi_ldw_all(sx_t *x, uint64_t *cyc, uint32_t st[3]) {
  int i, rc = DRV_OK, meas = x->meas;
  uint32_t s0[3];
  dres_t r;
  uint64_t est = 0;
  x->meas = 1; /* read the counters */
  *cyc = 0;
  s0[0] = hal_rd(SLOT_PI, PI_ST_WRGB);
  s0[1] = hal_rd(SLOT_PI, PI_ST_MAC);
  s0[2] = hal_rd(SLOT_PI, PI_ST_RDMAC);
  for (i = 0; i < x->nmat && rc == DRV_OK; i++) {
    const smat_t *m = &x->mat[i];
    uint32_t rb = 8u * (1u + cdiv((uint32_t)m->n, 8u));
    if (!m->ok || m->base < 0) continue;
    if (FAULT(x, FX_BANK) && i == 1) { /* bank base overlap: matrix 1 on matrix 0 */
      rc = pi_push(x, PI_C_LDW, m->n, m->rows, 0, x->mat[0].base, hal_pa(m->rrec), 0, 0, 0);
    } else {
      rc = pi_push(x, PI_C_LDW, m->n, m->rows, 0, m->base, hal_pa(m->rrec), 0, 0, 0);
    }
    est += (uint64_t)m->rows * rb / 8u + 64u;
    if (rc == DRV_FULL) {
      rc = pi_run(x, est, &r);
      *cyc += r.cyc;
      est = 0;
      i--; /* push it again */
    }
  }
  if (rc == DRV_OK) {
    rc = pi_run(x, est + 64u, &r);
    *cyc += r.cyc;
  }
  st[0] = hal_rd(SLOT_PI, PI_ST_WRGB) - s0[0];
  st[1] = hal_rd(SLOT_PI, PI_ST_MAC) - s0[1];
  st[2] = hal_rd(SLOT_PI, PI_ST_RDMAC) - s0[2];
  x->meas = meas;
  return rc;
}
