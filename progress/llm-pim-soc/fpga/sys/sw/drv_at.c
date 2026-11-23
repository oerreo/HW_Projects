/*
 * attn_top driver (attn.md 2, 4.4, system.md 2.4). ATTN op over heads HEAD0 .. HEAD0 + NHEAD - 1
 * of one layer; q records are written by the executor (sx_exec.c, at_qrec) and flushed here.
 * DDR KV (KV_SRC 1): layer base of the golden kc/vc/kcs/vcs arrays and SEQ. BRAM KV (KV_SRC 0):
 * KVW of the new position before the first ATTN of a layer.
 */
#include "hal.h"
#include "plat.h"
#include "sx.h"

static uint32_t fmt(const sx_t *x, int p_en) {
  return ((uint32_t)x->kb & 0x1Fu) | (((uint32_t)x->vb & 0x1Fu) << 8) | (p_en ? 0x10000u : 0u);
}

/* layer base of the four golden KV arrays: slot ((l nkv + j) seq + t) */
static void kv_base(const sx_t *x, int l, uint32_t a[4]) {
  size_t slot0 = (size_t)l * (size_t)x->nkv * (size_t)x->seq;
  a[0] = hal_pa((const int8_t *)x->s->kc + slot0 * (size_t)x->hs * (size_t)x->ek);
  a[1] = hal_pa((const int8_t *)x->s->vc + slot0 * (size_t)x->hs * (size_t)x->ev);
  a[2] = hal_pa(x->s->kcs + slot0);
  a[3] = hal_pa(x->s->vcs + slot0);
}

static void kv_regs(sx_t *x, int l) {
  uint32_t a[4];
  kv_base(x, (FAULT(x, FX_KVBASE) && x->sys->at_kvsrc) ? (l + 1) % x->L : l, a);
  dw(x, SLOT_AT, AT_K_ADDR, a[0]);
  dw(x, SLOT_AT, AT_V_ADDR, a[1]);
  dw(x, SLOT_AT, AT_KS_ADDR, a[2]);
  dw(x, SLOT_AT, AT_VS_ADDR, a[3]);
  dw(x, SLOT_AT, AT_SEQ, (uint32_t)x->seq);
}

int at_kvw(sx_t *x, int l, int pos, dres_t *r) {
  if (x->meas) r->t0 = r->t1 = plat_now();
  kv_regs(x, l);
  dw(x, SLOT_AT, AT_LAYER, (uint32_t)l);
  dw(x, SLOT_AT, AT_POS, (uint32_t)pos);
  dw(x, SLOT_AT, AT_KVH, ((uint32_t)x->nkv << 8) | 0u);
  dw(x, SLOT_AT, AT_HS, (uint32_t)x->hs);
  dw(x, SLOT_AT, AT_FMT, fmt(x, 0));
  return drv_go(x, SLOT_AT, AT_OP_KVW, 64u + 8u * (uint64_t)x->nkv, r);
}

int at_attn(sx_t *x, int l, int T, int h0, int nhd, dres_t *r) {
  uint32_t ps = 8u * (((uint32_t)T + 1u) / 2u);
  uint64_t est = (uint64_t)nhd * ((uint64_t)T * (4u + (uint32_t)x->hs / 4u) + 2u * (uint32_t)x->hs + 200u);
  /* t0 (entry) is set by the executor before the q record copies */
  hal_flush(x->qrec + (size_t)h0 * x->qb, (size_t)nhd * x->qb); /* q records: producer rule */
  if (x->opt & OPT_COH_STRICT) {
    hal_flush(x->s->att + (size_t)h0 * (size_t)x->hs, 4u * (size_t)x->hs * (size_t)nhd);
    if (x->kmode) hal_flush((uint8_t *)x->pbuf + (size_t)h0 * ps, (size_t)nhd * ps);
  }
  if (x->meas) r->t1 = plat_now();
  dw(x, SLOT_AT, AT_Q_ADDR, hal_pa(x->qrec));
  dw(x, SLOT_AT, AT_O_ADDR, hal_pa(x->s->att));
  if (x->kmode) dw(x, SLOT_AT, AT_P_ADDR, hal_pa(x->pbuf));
  dw(x, SLOT_AT, AT_T, (uint32_t)T);
  dw(x, SLOT_AT, AT_HS, (uint32_t)x->hs);
  dw(x, SLOT_AT, AT_FMT, fmt(x, x->kmode));
  dw(x, SLOT_AT, AT_HEAD, ((uint32_t)h0 & 0xFFu) | (((uint32_t)nhd & 0xFFu) << 8) |
                              (((uint32_t)x->kvmul & 0xFFu) << 16));
  if (x->sys->at_kvsrc) kv_regs(x, l);
  else dw(x, SLOT_AT, AT_LAYER, (uint32_t)l);
  return drv_go(x, SLOT_AT, AT_OP_ATTN, est, r);
}
