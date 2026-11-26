#include "dec_fix.h"
#include "plat.h"
#include <string.h>

int df_corr(const dfix_cfg_t *cfg, int m)
{
  if (cfg->corr == DF_NMS) return (m * cfg->nms_num) >> 4;
  m -= cfg->oms_beta;
  return m > 0 ? m : 0;
}

void dfix_free(dfix_t *d)
{
  plat_free(d->app); plat_free(d->hard);
  plat_free(d->min1); plat_free(d->min2); plat_free(d->idx); plat_free(d->sgn); plat_free(d->sq);
  plat_free(d->q); plat_free(d->rold); plat_free(d->rnew); plat_free(d->lane_in); plat_free(d->lane_out);
  memset(d, 0, sizeof *d);
}

int dfix_init(dfix_t *d, const code_t *c, const dfix_cfg_t *cfg)
{
  int r, e, L, maxle = 0;
  uint8_t *seen;
  memset(d, 0, sizeof *d);
  if (!c->qc || cfg->wc < 2 || cfg->wm < cfg->wc || cfg->wa < cfg->wm || cfg->wa > 15 ||
      cfg->iters < 1 || cfg->iters > 63 || c->dc_max > 255) return -1;
  if (cfg->corr == DF_NMS && (cfg->nms_num < 1 || cfg->nms_num > 16)) return -1;
  if (cfg->corr == DF_OMS && cfg->oms_beta < 0) return -1;
  /* every variable at most once per layer (weight-1 circulants) */
  seen = plat_alloc((size_t)c->n);
  if (!seen) return -1;
  for (L = 0; L < c->mb; L++) {
    int le = c->row_ptr[(L + 1) * c->Z] - c->row_ptr[L * c->Z];
    if (le > maxle) maxle = le;
    memset(seen, 0, (size_t)c->n);
    for (e = c->row_ptr[L * c->Z]; e < c->row_ptr[(L + 1) * c->Z]; e++) {
      if (seen[c->row_var[e]]++) { plat_free(seen); return -1; }
    }
  }
  plat_free(seen);
  d->c = c;
  d->cfg = *cfg;
  d->mmax = (1 << (cfg->wm - 1)) - 1;
  d->amax = (1 << (cfg->wa - 1)) - 1;
  d->app = plat_alloc(sizeof(int16_t) * c->n);
  d->hard = plat_alloc((size_t)c->n);
  d->min1 = plat_alloc(sizeof(int16_t) * c->m);
  d->min2 = plat_alloc(sizeof(int16_t) * c->m);
  d->idx = plat_alloc((size_t)c->m);
  d->sgn = plat_alloc((size_t)c->m);
  d->sq = plat_alloc((size_t)c->nedge);
  d->q = plat_alloc(sizeof(int16_t) * maxle);
  d->rold = plat_alloc(sizeof(int16_t) * maxle);
  d->rnew = plat_alloc(sizeof(int16_t) * maxle);
  d->lane_in = plat_alloc(sizeof(int16_t) * maxle);
  d->lane_out = plat_alloc(sizeof(int16_t) * maxle);
  if (!d->app || !d->hard || !d->min1 || !d->min2 || !d->idx || !d->sgn || !d->sq || !d->q ||
      !d->rold || !d->rnew || !d->lane_in || !d->lane_out) { dfix_free(d); return -1; }
  (void)r;
  return 0;
}

/* R of edge e (position j in check ck) from the stored compressed state */
static inline int r_of(const dfix_t *d, int ck, int j, int e)
{
  int m = (j == d->idx[ck]) ? d->min2[ck] : d->min1[ck];
  return (d->sgn[ck] ^ d->sq[e]) ? -m : m;
}

int dfix_decode(dfix_t *d, const int8_t *llr)
{
  const code_t *c = d->c;
  const int Z = c->Z, mb = c->mb;
  const int mmax = d->mmax, amax = d->amax;
  int v, it, L, i, j, e, k;
  memset(d->min1, 0, sizeof(int16_t) * c->m);   /* R = 0 before the first iteration */
  memset(d->min2, 0, sizeof(int16_t) * c->m);
  memset(d->idx, 0, (size_t)c->m);
  memset(d->sgn, 0, (size_t)c->m);
  memset(d->sq, 0, (size_t)c->nedge);
  for (v = 0; v < c->n; v++) {
    d->app[v] = (int16_t)llr[v];
    d->hard[v] = llr[v] < 0;
  }
  d->ok = 0;
  d->hard_changes = 0;
  if (d->hook) d->hook(d->user, DF_EV_START, d, -1, -1);
  for (it = 0; it < d->cfg.iters; it++) {
    d->etb_sat = 1;
    d->etb_chg = 0;
    for (L = 0; L < mb; L++) {
      const int eb = c->row_ptr[L * Z];
      d->layer_edges = c->row_ptr[(L + 1) * Z] - eb;
      /* phase 1: Q = sat_m(APP - R_old), check-wise min1/min2/idx/sign (strict <, first wins) */
      for (i = 0; i < Z; i++) {
        const int ck = L * Z + i, b = c->row_ptr[ck], dc = c->row_ptr[ck + 1] - b;
        int m1 = mmax, m2 = mmax, id = 0, sg = 0, par = 0;
        for (j = 0; j < dc; j++) {
          const int ed = b + j, le = ed - eb, var = c->row_var[ed];
          const int a = d->app[var];
          const int ro = r_of(d, ck, j, ed);
          const int q = df_sat(a - ro, mmax);
          const int mag = q < 0 ? -q : q;
          d->lane_in[le] = (int16_t)a;
          d->rold[le] = (int16_t)ro;
          d->q[le] = (int16_t)q;
          par ^= a < 0;
          sg ^= q < 0;
          if (mag < m1) { m2 = m1; m1 = mag; id = j; }
          else if (mag < m2) m2 = mag;
        }
        if (par) d->etb_sat = 0;
        /* new compressed state (corrected magnitudes) */
        d->min1[ck] = (int16_t)df_corr(&d->cfg, m1);
        d->min2[ck] = (int16_t)df_corr(&d->cfg, m2);
        d->idx[ck] = (uint8_t)id;
        d->sgn[ck] = (uint8_t)sg;
        for (j = 0; j < dc; j++) d->sq[b + j] = d->q[b + j - eb] < 0;
      }
      if (d->hook) d->hook(d->user, DF_EV_LAYER_IN, d, it, L);
      /* phase 2: R_new from the new state, APP = sat_a(Q + R_new) */
      for (i = 0; i < Z; i++) {
        const int ck = L * Z + i, b = c->row_ptr[ck], dc = c->row_ptr[ck + 1] - b;
        for (j = 0; j < dc; j++) {
          const int ed = b + j, le = ed - eb, var = c->row_var[ed];
          const int rn = r_of(d, ck, j, ed);
          const int a = df_sat(d->q[le] + rn, amax);
          const uint8_t h = a < 0;
          d->rnew[le] = (int16_t)rn;
          d->lane_out[le] = (int16_t)a;
          d->app[var] = (int16_t)a;
          if (h != d->hard[var]) { d->hard[var] = h; d->etb_chg = 1; d->hard_changes++; }
        }
      }
      if (d->hook) d->hook(d->user, DF_EV_LAYER_OUT, d, it, L);
    }
    if (d->hook) d->hook(d->user, DF_EV_ITER_END, d, it, -1);
    if (d->cfg.et == DF_ET_A) {
      if (code_syndrome(c, d->hard) == 0) { d->ok = 1; it++; break; }
    } else if (d->cfg.et == DF_ET_B) {
      if (d->etb_sat && !d->etb_chg) { d->ok = 1; it++; break; }
    }
  }
  d->iters_used = it;
  if (d->cfg.et == DF_ET_NONE) d->ok = code_syndrome(c, d->hard) == 0;
  if (d->hook) d->hook(d->user, DF_EV_DONE, d, it, -1);
  (void)e; (void)k;
  return d->ok;
}
