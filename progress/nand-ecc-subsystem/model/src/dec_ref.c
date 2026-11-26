#include "dec_ref.h"
#include "plat.h"
#include <float.h>
#include <math.h>
#include <string.h>

int dref_init(dref_t *d, const code_t *c, const dref_cfg_t *cfg)
{
  memset(d, 0, sizeof *d);
  d->c = c;
  d->cfg = *cfg;
  d->c2v = plat_alloc(sizeof(double) * c->nedge);
  d->v2c = plat_alloc(sizeof(double) * c->nedge);
  d->app = plat_alloc(sizeof(double) * c->n);
  d->tv = plat_alloc(sizeof(double) * (c->dc_max + 1));
  if (!d->c2v || !d->v2c || !d->app || !d->tv) { dref_free(d); return -1; }
  return 0;
}

void dref_free(dref_t *d)
{
  plat_free(d->c2v); plat_free(d->v2c); plat_free(d->app); plat_free(d->tv);
  memset(d, 0, sizeof *d);
}

/* check node: in[0..dc-1] variable-to-check values -> out[0..dc-1] check-to-variable */
static void chk_update(const dref_cfg_t *cfg, const double *in, double *out, int dc, double *tv)
{
  int j;
  if (cfg->rule == DR_SPA) {
    /* tanh rule with the zero handling and the 1 - eps clamp of AFF3CT Update_rule_SPA */
    double prod = 1.0;
    int sgn = 0, nz = 0;
    for (j = 0; j < dc; j++) {
      double t = tanh(fabs(in[j]) * 0.5);
      tv[j] = t;
      if (t == 0.0) nz++;
      else { prod *= t; sgn ^= signbit(in[j]) ? 1 : 0; }
    }
    for (j = 0; j < dc; j++) {
      int z = tv[j] == 0.0;
      double r = z ? prod : prod / tv[j];
      int s;
      if (r >= 1.0) r = 1.0 - DBL_EPSILON;
      r = 2.0 * atanh(r);
      s = z ? sgn : sgn ^ (signbit(in[j]) ? 1 : 0);
      out[j] = (nz == 0 || (nz == 1 && z)) ? (s ? -r : r) : 0.0;
    }
  } else {
    double m1 = DBL_MAX, m2 = DBL_MAX, c1, c2;
    int idx = 0, sgn = 0;
    for (j = 0; j < dc; j++) {
      double a = fabs(in[j]);
      sgn ^= signbit(in[j]) ? 1 : 0;
      if (a < m1) { m2 = m1; m1 = a; idx = j; }
      else if (a < m2) m2 = a;
    }
    if (cfg->rule == DR_NMS) { c1 = m1 * cfg->norm; c2 = m2 * cfg->norm; }
    else { c1 = m1 - cfg->offset; c2 = m2 - cfg->offset; if (c1 < 0) c1 = 0; if (c2 < 0) c2 = 0; }
    for (j = 0; j < dc; j++) {
      double r = (j == idx) ? c2 : c1;
      int s = sgn ^ (signbit(in[j]) ? 1 : 0);
      out[j] = s ? -r : r;
    }
  }
}

static int hard_synd(const code_t *c, const double *post, uint8_t *hard)
{
  int v;
  for (v = 0; v < c->n; v++) hard[v] = post[v] < 0.0;
  return code_syndrome(c, hard) == 0;
}

int dref_decode(dref_t *d, const double *llr, uint8_t *hard)
{
  const code_t *c = d->c;
  const dref_cfg_t *cfg = &d->cfg;
  int it, r, e, v, ok = 0;
  double in[1024], out[1024];
  if (c->dc_max > 1024) return 0;
  memset(d->c2v, 0, sizeof(double) * c->nedge);
  if (cfg->layered) memcpy(d->app, llr, sizeof(double) * c->n);
  for (it = 0; it < cfg->iters; it++) {
    if (!cfg->layered) {
      /* variable to check from the previous c2v */
      for (v = 0; v < c->n; v++) {
        double s = llr[v];
        int k;
        for (k = c->col_ptr[v]; k < c->col_ptr[v + 1]; k++) s += d->c2v[c->col_edge[k]];
        for (k = c->col_ptr[v]; k < c->col_ptr[v + 1]; k++) {
          int ed = c->col_edge[k];
          d->v2c[ed] = s - d->c2v[ed];
        }
      }
      for (r = 0; r < c->m; r++) {
        int b = c->row_ptr[r], dc = c->row_ptr[r + 1] - b;
        chk_update(cfg, d->v2c + b, d->c2v + b, dc, d->tv);
      }
      for (v = 0; v < c->n; v++) {
        double s = llr[v];
        int k;
        for (k = c->col_ptr[v]; k < c->col_ptr[v + 1]; k++) s += d->c2v[c->col_edge[k]];
        d->app[v] = s;
      }
    } else {
      for (r = 0; r < c->m; r++) {
        int b = c->row_ptr[r], dc = c->row_ptr[r + 1] - b, j;
        for (j = 0; j < dc; j++) in[j] = d->app[c->row_var[b + j]] - d->c2v[b + j];
        chk_update(cfg, in, out, dc, d->tv);
        for (j = 0; j < dc; j++) {
          d->c2v[b + j] = out[j];
          d->app[c->row_var[b + j]] = in[j] + out[j];
        }
      }
    }
    if (cfg->et && it != cfg->iters - 1) {
      if (hard_synd(c, d->app, hard)) { ok = 1; it++; break; }
    }
  }
  d->iters_used = it;
  if (!ok) ok = hard_synd(c, d->app, hard);
  (void)e;
  return ok;
}
