#include "llr.h"
#include <math.h>
#include <string.h>

int llr_quant(double x, double scale, int w)
{
  const int mx = (1 << (w - 1)) - 1;
  double a = fabs(x) * scale;
  int q;
  if (!(a < 1e6)) q = mx;   /* also catches inf */
  else q = (int)floor(a + 0.5);
  if (q > mx) q = mx;
  return x < 0 ? -q : q;
}

void llr_build(llrlut_t *L, const grid_t *g, const chan_t *nominal, const rdcfg_t *rc, int w, double scale)
{
  int r, s, q;
  memset(L, 0, sizeof *L);
  L->nreg = rc->nreg; L->w = w; L->scale = scale;
  for (r = 0; r < rc->nreg; r++) {
    double p0 = 0, p1 = 0, x;
    for (s = 0; s < g->nstate; s++) {
      double lo = r > 0 ? chan_cdf(nominal, s, g->e[rc->gidx[r - 1]]) : 0.0;
      double hi = r < rc->nthr ? chan_cdf(nominal, s, g->e[rc->gidx[r]]) : 1.0;
      double p = hi - lo;
      if (p < 0) p = 0;
      if (g->pbit[s]) p1 += p; else p0 += p;
    }
    if (p0 <= 0 && p1 <= 0) x = 0;
    else if (p1 <= 0) x = HUGE_VAL;
    else if (p0 <= 0) x = -HUGE_VAL;
    else x = log(p0 / p1);
    L->llr[r] = x;
    L->lut[r] = (int8_t)llr_quant(x, scale, w);
  }
  for (q = 0; q <= g->npt; q++) L->full[q] = L->lut[rc->map[q]];
}

void llr_build_hard(llrlut_t *L, const rdcfg_t *rc, int w, int A)
{
  int r, q;
  memset(L, 0, sizeof *L);
  L->nreg = rc->nreg; L->w = w; L->scale = 0;
  for (r = 0; r < rc->nreg; r++) {
    L->lut[r] = (int8_t)(rc->hbit[r] ? -A : A);
    L->llr[r] = L->lut[r];
  }
  for (q = 0; q <= GRID_MAX; q++) L->full[q] = L->lut[rc->map[q]];
}

void llr_map(const llrlut_t *L, const uint8_t *q, int n, int8_t *out)
{
  int i;
  for (i = 0; i < n; i++) out[i] = L->full[q[i]];
}

void llr_map_f(const llrlut_t *L, const rdcfg_t *rc, const uint8_t *q, int n, double *out)
{
  int i;
  for (i = 0; i < n; i++) {
    double x = L->llr[rc->map[q[i]]];
    if (x > 50) x = 50;
    if (x < -50) x = -50;
    out[i] = x;
  }
}
