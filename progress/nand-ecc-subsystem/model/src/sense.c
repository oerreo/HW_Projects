#include "sense.h"
#include <math.h>
#include <string.h>

static uint32_t to_u32(double p)
{
  double t = floor(p * 4294967296.0 + 0.5);
  if (t < 0) t = 0;
  if (t > 4294967295.0) t = 4294967295.0;
  return (uint32_t)t;
}

void grid_tables(grid_t *g, const chan_t *ch)
{
  int s, j;
  for (s = 0; s < g->nstate; s++)
    for (j = 0; j < g->npt; j++) g->T[s][j] = to_u32(chan_cdf(ch, s, g->e[j]));
}

int grid_build(grid_t *g, const chan_t *ch, int page, int G, double step, const double *ref)
{
  int b, k, s, cnt[2] = {0, 0};
  memset(g, 0, sizeof *g);
  if (G < 1 || !(G & 1) || page < 0 || page >= ch->bits) return -1;
  g->page = page; g->G = G; g->step = step; g->nstate = ch->nstate;
  g->other_bits = ch->bits - 1;
  g->B = chan_bounds(ch, page, g->bstate);
  g->npt = g->B * G;
  if (g->npt > GRID_MAX) return -1;
  for (b = 0; b < g->B; b++) {
    g->ref[b] = ref ? ref[b] : chan_ref_opt(ch, g->bstate[b]);
    for (k = 0; k < G; k++) g->e[b * G + k] = g->ref[b] + (k - (G - 1) / 2) * step;
  }
  for (k = 1; k < g->npt; k++) if (g->e[k] <= g->e[k - 1]) return -1;  /* overlapping boundaries */
  for (s = 0; s < g->nstate; s++) {
    int pb = chan_page_bit(ch, page, s);
    g->pbit[s] = (uint8_t)pb;
    g->state_of[pb][cnt[pb]++] = (uint8_t)s;
  }
  if (cnt[0] != (1 << g->other_bits) || cnt[1] != (1 << g->other_bits)) return -1;
  grid_tables(g, ch);
  return 0;
}

void chan_sample(const grid_t *g, const uint8_t *bits, int n, rng_t *r, uint8_t *q)
{
  const int sh = 32 - g->other_bits;
  int i, j;
  for (i = 0; i < n; i++) {
    const uint32_t r1 = rng_next(r), u = rng_next(r);
    const int s = g->state_of[bits[i] & 1][g->other_bits ? (int)(r1 >> sh) : 0];
    const uint32_t *T = g->T[s];
    int cnt = 0;
    for (j = 0; j < g->npt; j++) cnt += u >= T[j];
    q[i] = (uint8_t)cnt;
  }
}

void chan_sample_ref(const grid_t *g, const chan_t *ch, const uint8_t *bits, int n, rng_t *r, uint8_t *q)
{
  const int sh = 32 - g->other_bits;
  int i, j;
  for (i = 0; i < n; i++) {
    const uint32_t r1 = rng_next(r);
    const int s = g->state_of[bits[i] & 1][g->other_bits ? (int)(r1 >> sh) : 0];
    const double v = ch->mu[s] + ch->alpha * ch->sig[s] * rng_gauss(r);
    int cnt = 0;
    for (j = 0; j < g->npt; j++) cnt += v > g->e[j];
    q[i] = (uint8_t)cnt;
  }
}

int rdcfg_make(rdcfg_t *rc, const grid_t *g, int levels, int dstep, const int *off)
{
  int b, j, t = 0, q, half = (levels - 1) / 2, hg = (g->G - 1) / 2;
  memset(rc, 0, sizeof *rc);
  if (levels < 1 || !(levels & 1) || (levels > 1 && dstep < 1)) return -1;
  rc->levels = levels;
  for (b = 0; b < g->B; b++)
    for (j = -half; j <= half; j++) {
      int k = hg + (off ? off[b] : 0) + j * dstep;
      if (k < 0 || k >= g->G) return -1;
      rc->gidx[t++] = (uint8_t)(b * g->G + k);
    }
  rc->nthr = t;
  rc->nreg = t + 1;
  for (q = 0; q <= g->npt; q++) {
    int r = 0;
    for (j = 0; j < t; j++) r += q > rc->gidx[j];
    rc->map[q] = (uint8_t)r;
  }
  /* hard bit of a read region: the region lies between boundary groups; regions below the centre
   * threshold of boundary b and above that of b-1 carry the bit of state bstate[b] */
  for (q = 0; q < rc->nreg; q++) {
    int bb = q / levels;                 /* thresholds of boundary b occupy indices b*L .. b*L+L-1 */
    int within = q - bb * levels;        /* 0 .. L: position inside the group */
    int above = within > half;           /* above the centre threshold of boundary bb */
    int s;
    if (bb >= g->B) s = g->bstate[g->B - 1] + 1;
    else s = above ? g->bstate[bb] + 1 : g->bstate[bb];
    rc->hbit[q] = g->pbit[s];
  }
  return 0;
}

void sense_read(const rdcfg_t *rc, const uint8_t *q, int n, uint8_t *reg)
{
  int i;
  for (i = 0; i < n; i++) reg[i] = rc->map[q[i]];
}

double rber_analytic(const grid_t *g, const chan_t *ch, const rdcfg_t *rc)
{
  /* hard decision = bit of the side of the centre threshold of each boundary */
  int s, b, half = (rc->levels - 1) / 2;
  double err = 0;
  for (s = 0; s < g->nstate; s++) {
    double pprev = 0.0;
    for (b = 0; b <= g->B; b++) {
      double pc = b < g->B ? chan_cdf(ch, s, g->e[rc->gidx[b * rc->levels + half]]) : 1.0;
      int sb = b < g->B ? g->bstate[b] : g->bstate[g->B - 1] + 1;
      if (g->pbit[sb] != g->pbit[s]) err += pc - pprev;
      pprev = pc;
    }
  }
  return err / g->nstate;
}

double rber_table(const grid_t *g, const rdcfg_t *rc)
{
  int s, b, half = (rc->levels - 1) / 2;
  double err = 0;
  for (s = 0; s < g->nstate; s++) {
    double pprev = 0.0;
    for (b = 0; b <= g->B; b++) {
      /* P(q <= gidx) = P(u < T[gidx]) = T / 2^32 */
      double pc = b < g->B ? g->T[s][rc->gidx[b * rc->levels + half]] / 4294967296.0 : 1.0;
      int sb = b < g->B ? g->bstate[b] : g->bstate[g->B - 1] + 1;
      if (g->pbit[sb] != g->pbit[s]) err += pc - pprev;
      pprev = pc;
    }
  }
  return err / g->nstate;
}
