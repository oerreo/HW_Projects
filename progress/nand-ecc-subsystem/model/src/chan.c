#include "chan.h"
#include "plat.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

/* [R5] Table 1 (P0..P7): MSB 1,0,0,1,1,0,0,1 / CSB 1,1,0,0,0,0,1,1 / LSB 1,1,1,1,0,0,0,0 */
static const unsigned char TLC_BITS[3][8] = {
  {1, 1, 1, 1, 0, 0, 0, 0},   /* page 0 LSB */
  {1, 1, 0, 0, 0, 0, 1, 1},   /* page 1 CSB */
  {1, 0, 0, 1, 1, 0, 0, 1},   /* page 2 MSB */
};
/* [R4] Gray E,P1,P2,P3 = 11,10,00,01: first bit 1,1,0,0 (one boundary) -> lower page,
 * second bit 1,0,0,1 (two boundaries) -> upper page (assignment [estimate], channel.md 1.1) */
static const unsigned char MLC_BITS[2][4] = {
  {1, 1, 0, 0},
  {1, 0, 0, 1},
};

void mlc_param_default(mlc_param_t *p)
{
  p->mu_e = 1.4; p->sig_e = 0.35; p->dvpp = 0.3;
  p->vp[0] = 2.85; p->vp[1] = 3.55; p->vp[2] = 4.25;
  p->k_lambda = 4e-4;
  p->gam_y = 0.08; p->gam_xy = 0.0048; p->wc_rel = 0.1; p->sc_rel = 0.4;
  p->ks = 0.333; p->x0 = 1.4; p->kd = 4e-4; p->km = 2e-6; p->t0 = 1.0;
  p->cci = 1;
}

int chan_npages(const chan_t *c) { return c->bits; }

int chan_page_bit(const chan_t *c, int page, int s)
{
  return c->model == CH_TLC ? TLC_BITS[page][s] : MLC_BITS[page][s];
}

int chan_bounds(const chan_t *c, int page, int *bstate)
{
  int s, nb = 0;
  for (s = 0; s + 1 < c->nstate; s++)
    if (chan_page_bit(c, page, s) != chan_page_bit(c, page, s + 1)) bstate[nb++] = s;
  return nb;
}

int chan_tlc(chan_t *c, const double mu[8], const double sig[8], double alpha)
{
  int s;
  memset(c, 0, sizeof *c);
  c->model = CH_TLC; c->nstate = 8; c->bits = 3; c->alpha = alpha;
  for (s = 0; s < 8; s++) { c->mu[s] = mu[s]; c->sig[s] = sig[s]; if (sig[s] <= 0) return -1; }
  return alpha > 0 ? 0 : -1;
}

void chan_free(chan_t *c)
{
  int s;
  for (s = 0; s < 4; s++) plat_free(c->cdf[s]);
  memset(c, 0, sizeof *c);
}

/* add mass m at position x (grid coordinates) by linear interpolation */
static void deposit(double *f, int ng, double pos, double m)
{
  int i = (int)floor(pos);
  double fr = pos - i;
  if (i < 0) { f[0] += m; return; }
  if (i >= ng - 1) { f[ng - 1] += m; return; }
  f[i] += m * (1.0 - fr);
  f[i + 1] += m * fr;
}

static double ncdf(double z) { return 0.5 * erfc(-z / sqrt(2.0)); }

/* out = a (*) k, kernel k indexed by offset k0 + j (j = 0..nk-1 -> shift (j + k0) bins) */
static void conv(const double *a, double *out, int ng, const double *k, int nk, int k0)
{
  int i, j;
  memset(out, 0, sizeof(double) * ng);
  for (i = 0; i < ng; i++) {
    if (a[i] == 0.0) continue;
    for (j = 0; j < nk; j++) {
      int o = i + j + k0;
      if (o < 0) o = 0;
      if (o >= ng) o = ng - 1;
      out[o] += a[i] * k[j];
    }
  }
}

int chan_mlc(chan_t *c, const mlc_param_t *p, double N, double t_hours)
{
  const double x_lo = -1.5, x_hi = 8.0, h = 0.002;
  const int ng = (int)((x_hi - x_lo) / h) + 1;
  double *f0 = plat_alloc(sizeof(double) * ng), *f1 = plat_alloc(sizeof(double) * ng);
  double *kr = NULL, *kc = NULL;
  int nkr = 0, kr0 = 0, nkc = 0, s, i, j;
  const double L = log(1.0 + t_hours / p->t0);
  const double lam = p->k_lambda * sqrt(N);
  memset(c, 0, sizeof *c);
  c->model = CH_MLC; c->nstate = 4; c->bits = 2; c->x_lo = x_lo; c->h = h; c->ng = ng;
  c->N = N; c->t_h = t_hours;
  if (!f0 || !f1) goto fail;
  /* RTN kernel: Laplace(0, lam), bins via CDF differences over +-20 lam */
  if (lam > h / 4) {
    int half = (int)ceil(20.0 * lam / h);
    nkr = 2 * half + 1; kr0 = -half;
    kr = plat_alloc(sizeof(double) * nkr);
    for (j = 0; j < nkr; j++) {
      double a = (j + kr0 - 0.5) * h, b = (j + kr0 + 0.5) * h;
      double Fa = a < 0 ? 0.5 * exp(a / lam) : 1.0 - 0.5 * exp(-a / lam);
      double Fb = b < 0 ? 0.5 * exp(b / lam) : 1.0 - 0.5 * exp(-b / lam);
      kr[j] = Fb - Fa;
    }
  }
  /* CCI kernel: next word line, 1 vertical + 2 diagonal neighbours, states uniform, neighbour
   * shift dV = (Vp_k + dVpp/2) - mu_e for P_k, 0 for E [estimate]; gamma ~ bounded Gaussian
   * (mean mu_c, sd sc_rel*mu_c, |x - mu_c| <= wc_rel*mu_c) by 9-point quadrature. */
  if (p->cci) {
    double dv[4], gq[9], gw[9], wsum = 0, maxs;
    int a, b, d, ia, ib, id;
    dv[0] = 0;
    for (i = 0; i < 3; i++) dv[i + 1] = p->vp[i] + p->dvpp / 2 - p->mu_e;
    for (i = 0; i < 9; i++) {
      double z = (i - 4) / 4.0 * p->wc_rel / p->sc_rel;   /* in units of sigma_c */
      gq[i] = 1.0 + (i - 4) / 4.0 * p->wc_rel;           /* multiple of mu_c */
      gw[i] = exp(-0.5 * z * z);
      wsum += gw[i];
    }
    for (i = 0; i < 9; i++) gw[i] /= wsum;
    maxs = 1.1 * (p->gam_y + 2 * p->gam_xy) * dv[3];
    nkc = (int)ceil(maxs / h) + 2;
    kc = plat_alloc(sizeof(double) * nkc);
    for (a = 0; a < 4; a++) for (b = 0; b < 4; b++) for (d = 0; d < 4; d++)
      for (ia = 0; ia < 9; ia++) for (ib = 0; ib < 9; ib++) for (id = 0; id < 9; id++) {
        double sh = gq[ia] * p->gam_y * dv[a] + gq[ib] * p->gam_xy * dv[b] + gq[id] * p->gam_xy * dv[d];
        deposit(kc, nkc, sh / h, gw[ia] * gw[ib] * gw[id] / 64.0);
      }
  }
  for (s = 0; s < 4; s++) {
    double acc = 0;
    memset(f0, 0, sizeof(double) * ng);
    /* ideal programmed Vth xp on the grid, then retention reduction d ~ N(mu_d(xp), sd_d(xp)^2) */
    for (i = 0; i < ng; i++) {
      double xp = x_lo + i * h, m, md, vd, sd;
      if (s == 0) m = ncdf((xp + h / 2 - p->mu_e) / p->sig_e) - ncdf((xp - h / 2 - p->mu_e) / p->sig_e);
      else {
        double lo = p->vp[s - 1], hi = lo + p->dvpp;
        double a = xp - h / 2 > lo ? xp - h / 2 : lo, b = xp + h / 2 < hi ? xp + h / 2 : hi;
        m = b > a ? (b - a) / p->dvpp : 0.0;
      }
      if (m <= 0) continue;
      {
        double u = xp - p->x0;
        if (u < 0) u = 0;   /* x < x0: no retention shift [estimate, channel.md 2.1] */
        md = p->ks * u * p->kd * sqrt(N) * L;
        vd = p->ks * u * p->km * pow(N, 0.6) * L;
        sd = sqrt(vd);
      }
      if (sd < h / 2) deposit(f0, ng, (xp - md - x_lo) / h, m);
      else {
        int lo = (int)floor((xp - md - 8 * sd - x_lo) / h), hi = (int)ceil((xp - md + 8 * sd - x_lo) / h), k;
        double prev = ncdf(((x_lo + (lo - 0.5) * h) - (xp - md)) / sd);
        for (k = lo; k <= hi; k++) {
          double cur = ncdf(((x_lo + (k + 0.5) * h) - (xp - md)) / sd);
          int o = k < 0 ? 0 : (k >= ng ? ng - 1 : k);
          f0[o] += m * (cur - prev);
          prev = cur;
        }
      }
    }
    if (kr) { conv(f0, f1, ng, kr, nkr, kr0); memcpy(f0, f1, sizeof(double) * ng); }
    if (kc) { conv(f0, f1, ng, kc, nkc, 0); memcpy(f0, f1, sizeof(double) * ng); }
    c->cdf[s] = plat_alloc(sizeof(double) * ng);
    if (!c->cdf[s]) goto fail;
    for (i = 0; i < ng; i++) { acc += f0[i]; c->cdf[s][i] = acc; }
    for (i = 0; i < ng; i++) c->cdf[s][i] /= acc;
  }
  plat_free(f0); plat_free(f1); plat_free(kr); plat_free(kc);
  return 0;
fail:
  plat_free(f0); plat_free(f1); plat_free(kr); plat_free(kc);
  chan_free(c);
  return -1;
}

double chan_cdf(const chan_t *c, int s, double x)
{
  if (c->model == CH_TLC) return ncdf((x - c->mu[s]) / (c->alpha * c->sig[s]));
  {
    /* mass of bin i sits at x_i; C_i = CDF at x_i + h/2, linear between those points */
    double pos = (x - c->x_lo) / c->h - 0.5;
    int i = (int)floor(pos);
    double fr = pos - i;
    if (i < 0) return pos < -1 ? 0.0 : c->cdf[s][0] * (pos + 1);
    if (i >= c->ng - 1) return 1.0;
    return c->cdf[s][i] * (1 - fr) + c->cdf[s][i + 1] * fr;
  }
}

double chan_mean(const chan_t *c, int s)
{
  int i;
  double m = 0, prev = 0;
  if (c->model == CH_TLC) return c->mu[s];
  for (i = 0; i < c->ng; i++) { m += (c->cdf[s][i] - prev) * (c->x_lo + i * c->h); prev = c->cdf[s][i]; }
  return m;
}

double chan_ref_opt(const chan_t *c, int s)
{
  const int NS = 4000;
  double a = chan_mean(c, s), b = chan_mean(c, s + 1), best = 2.0;
  int i, i0 = 0, i1 = 0;
  for (i = 0; i <= NS; i++) {
    double x = a + (b - a) * i / NS;
    double e = 1.0 - chan_cdf(c, s, x) + chan_cdf(c, s + 1, x);
    if (e < best * (1 - 1e-12) - 1e-300) { best = e; i0 = i1 = i; }
    else if (e <= best * (1 + 1e-12) + 1e-300) i1 = i;
  }
  return a + (b - a) * (0.5 * (i0 + i1)) / NS;
}

int chan_tlc_lookup(const char *text, int days, int pe, double mu[8], double sig[8])
{
  const char *p = text;
  while (*p) {
    const char *e = strchr(p, '\n');
    size_t len = e ? (size_t)(e - p) : strlen(p);
    if (len > 0 && p[0] != '#') {
      char buf[512];
      char *q, *end;
      double v[18];
      int k = 0;
      if (len >= sizeof buf) len = sizeof buf - 1;
      memcpy(buf, p, len); buf[len] = 0;
      q = buf;
      while (k < 18) {
        v[k] = strtod(q, &end);
        if (end == q) break;
        q = end; k++;
      }
      if (k == 18 && (int)v[0] == days && (int)v[1] == pe) {
        for (k = 0; k < 8; k++) { mu[k] = v[2 + k]; sig[k] = v[10 + k]; }
        return 0;
      }
    }
    if (!e) break;
    p = e + 1;
  }
  return -1;
}
