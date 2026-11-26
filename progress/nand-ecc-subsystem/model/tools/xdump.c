/* Fixed-point decoder trace dump through the dec_fix hook (kernel boundaries: shifter output, CNU
 * state, R_new, APP write-back, iteration end). Used by tools/fixref.py (independent Python
 * implementation of docs/spec/numeric.md) and later by the RTL test benches. No arguments; CFG keys:
 *   code, tlc_tab, out, seed, frames, alpha, levels (3, 5, 7), dstep, scale,
 *   dfix "wc wm wa corr(0 NMS, 1 OMS) nms_num oms_beta iters et(0 none, 1 A, 2 B)"
 * Text format (one record per line):
 *   C <wc> <wm> <wa> <corr> <num> <beta> <iters> <et>     decoder config
 *   F <frame>                                              frame start
 *   LLR <n values>                                         decoder input (int8)
 *   LI <iter> <layer> <lane_in...>                         APP after the read shifter, layer edge order
 *   Q <q...>                                               Q = sat_m(APP - R_old)
 *   CN <min1 min2 idx sgn> x Z                             new compressed check state (corrected)
 *   RN <rnew...>                                           R_new per edge
 *   LO <lane_out...>                                       APP written back (before the inverse shift)
 *   IE <iter> <app...>                                     APP at the end of the iteration
 *   D <iters_used> <ok> <hard bits as a string> */
#include <stdlib.h>
#include <string.h>
#include "io.h"
#include "../src/chan.h"
#include "../src/dec_fix.h"
#include "../src/enc.h"
#include "../src/llr.h"
#include "../src/rng.h"
#include "../src/sense.h"

static void pr16(FILE *f, const int16_t *a, int n)
{
  int i;
  for (i = 0; i < n; i++) fprintf(f, " %d", a[i]);
  fputc('\n', f);
}

static void hook(void *user, int ev, const dfix_t *d, int it, int L)
{
  FILE *f = user;
  const code_t *c = d->c;
  int i;
  if (ev == DF_EV_LAYER_IN) {
    fprintf(f, "LI %d %d", it, L); pr16(f, d->lane_in, d->layer_edges);
    fprintf(f, "Q"); pr16(f, d->q, d->layer_edges);
    fprintf(f, "CN");
    for (i = 0; i < c->Z; i++) {
      int ck = L * c->Z + i;
      fprintf(f, " %d %d %d %d", d->min1[ck], d->min2[ck], d->idx[ck], d->sgn[ck]);
    }
    fputc('\n', f);
  } else if (ev == DF_EV_LAYER_OUT) {
    fprintf(f, "RN"); pr16(f, d->rnew, d->layer_edges);
    fprintf(f, "LO"); pr16(f, d->lane_out, d->layer_edges);
  } else if (ev == DF_EV_ITER_END) {
    fprintf(f, "IE %d", it); pr16(f, d->app, c->n);
  }
}

int main(void)
{
  code_t c;
  chan_t ch;
  grid_t g;
  rdcfg_t rc;
  llrlut_t L;
  dfix_cfg_t fc;
  dfix_t df;
  double mu[8], sg[8];
  char *tab;
  FILE *f;
  uint8_t *u, *cw, *q;
  int8_t *lq;
  int fr, i, nfr;
  long seed;
  if (cfg_load() || io_code(&c, cfg_s("code", "")) || !c.ddiag) { fprintf(stderr, "config/code\n"); return 1; }
  if (sscanf(cfg_s("dfix", ""), "%d %d %d %d %d %d %d %d", &fc.wc, &fc.wm, &fc.wa, &fc.corr, &fc.nms_num,
             &fc.oms_beta, &fc.iters, &fc.et) != 8 || dfix_init(&df, &c, &fc)) { fprintf(stderr, "dfix\n"); return 1; }
  tab = io_read(cfg_s("tlc_tab", ""), NULL);
  if (!tab || chan_tlc_lookup(tab, 15, 500, mu, sg) || chan_tlc(&ch, mu, sg, cfg_d("alpha", 2.4))) return 1;
  grid_build(&g, &ch, 0, 15, 2.0, NULL);
  if (rdcfg_make(&rc, &g, (int)cfg_i("levels", 7), (int)cfg_i("dstep", 2), NULL)) return 1;
  llr_build(&L, &g, &ch, &rc, fc.wc, cfg_d("scale", 3.0));
  f = fopen(cfg_s("out", "build/x.txt"), "w");
  if (!f) return 1;
  df.hook = hook;
  df.user = f;
  u = calloc(c.n, 1); cw = calloc(c.n, 1); q = calloc(c.n, 1); lq = calloc(c.n, 1);
  nfr = (int)cfg_i("frames", 10);
  seed = cfg_i("seed", 5);
  fprintf(f, "C %d %d %d %d %d %d %d %d\n", fc.wc, fc.wm, fc.wa, fc.corr, fc.nms_num, fc.oms_beta, fc.iters, fc.et);
  for (fr = 0; fr < nfr; fr++) {
    rng_t r;
    int ok;
    rng_seed(&r, (uint64_t)seed, (uint64_t)fr);
    for (i = 0; i < c.k; i++) u[i] = rng_next(&r) >> 31;
    enc_qc(&c, u, cw);
    chan_sample(&g, cw, c.n, &r, q);
    llr_map(&L, q, c.n, lq);
    fprintf(f, "F %d\nLLR", fr);
    for (i = 0; i < c.n; i++) fprintf(f, " %d", lq[i]);
    fputc('\n', f);
    ok = dfix_decode(&df, lq);
    fprintf(f, "D %d %d ", df.iters_used, ok);
    for (i = 0; i < c.n; i++) fputc('0' + df.hard[i], f);
    fputc('\n', f);
  }
  fclose(f);
  return 0;
}
