/* Channel tables (no arguments, CFG keys tlc_tab, out): analytic hard raw BER and optimal references
 * for every [R5] condition and page, the alpha sweep of the LSB page, the MLC model over (N, t), and
 * the retry offsets (grid steps) of each TLC condition relative to the P/E 500 / 15 day references. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include "io.h"
#include "../src/chan.h"
#include "../src/sense.h"

static double rber(const chan_t *ch, int page, const double *ref)
{
  grid_t g;
  rdcfg_t rc;
  if (grid_build(&g, ch, page, 15, 2.0, ref)) return -1;
  rdcfg_make(&rc, &g, 1, 1, NULL);
  return rber_analytic(&g, ch, &rc);
}

int main(void)
{
  char *tab;
  FILE *f;
  int days[3] = {15, 30, 90}, pes[6] = {500, 1000, 2000, 3000, 4000, 5000}, di, pi, pg, s;
  double mu[8], sg[8], ref0[7];
  chan_t ch;
  if (cfg_load() || !(tab = io_read(cfg_s("tlc_tab", ""), NULL))) return 1;
  f = fopen(cfg_s("out", "results/rtab.txt"), "w");
  if (!f) return 1;
  chan_tlc_lookup(tab, 15, 500, mu, sg);
  chan_tlc(&ch, mu, sg, 1.0);
  for (s = 0; s < 7; s++) ref0[s] = chan_ref_opt(&ch, s);
  fprintf(f, "# TLC [R5] alpha 1: hard raw BER per page with optimal refs, and with the P/E 500 15 d refs (no retry)\n");
  fprintf(f, "# days pe | LSB CSB MSB (opt) | LSB CSB MSB (fixed refs) | R0..R6 opt | offsets vs P/E500/15d in grid steps (2.0)\n");
  for (di = 0; di < 3; di++)
    for (pi = 0; pi < 6; pi++) {
      double r[7], fx[4];
      chan_tlc_lookup(tab, days[di], pes[pi], mu, sg);
      chan_tlc(&ch, mu, sg, 1.0);
      fprintf(f, "%3d %5d |", days[di], pes[pi]);
      for (pg = 0; pg < 3; pg++) fprintf(f, " %.3e", rber(&ch, pg, NULL));
      fprintf(f, " |");
      for (pg = 0; pg < 3; pg++) {
        int b[4], nb = chan_bounds(&ch, pg, b), k;
        for (k = 0; k < nb; k++) fx[k] = ref0[b[k]];
        fprintf(f, " %.3e", rber(&ch, pg, fx));
      }
      fprintf(f, " |");
      for (s = 0; s < 7; s++) { r[s] = chan_ref_opt(&ch, s); fprintf(f, " %.2f", r[s]); }
      fprintf(f, " |");
      for (s = 0; s < 7; s++) fprintf(f, " %+d", (int)floor((r[s] - ref0[s]) / 2.0 + 0.5));
      fprintf(f, "\n");
    }
  fprintf(f, "# TLC P/E 3000, 30 days: hard raw BER vs alpha (sigma scale, project knob)\n# alpha LSB CSB MSB\n");
  chan_tlc_lookup(tab, 30, 3000, mu, sg);
  {
    double a;
    for (a = 1.0; a <= 2.6001; a += 0.1) {
      chan_tlc(&ch, mu, sg, a);
      fprintf(f, "%.1f %.3e %.3e %.3e\n", a, rber(&ch, 0, NULL), rber(&ch, 1, NULL), rber(&ch, 2, NULL));
    }
  }
  fprintf(f, "# MLC [R3] model: hard raw BER (optimal refs) lower / upper page, N = P/E, t = retention\n# N t_h lower upper refs\n");
  {
    mlc_param_t mp;
    double Ns[5] = {0, 1000, 3000, 5000, 10000}, ts[4] = {1, 24, 720, 8760};
    int ni, ti;
    mlc_param_default(&mp);
    for (ni = 0; ni < 5; ni++)
      for (ti = 0; ti < 4; ti++) {
        chan_t cm;
        grid_t g;
        rdcfg_t rc;
        double lo, up;
        if (chan_mlc(&cm, &mp, Ns[ni], ts[ti])) return 1;
        grid_build(&g, &cm, 0, 15, 0.02, NULL); rdcfg_make(&rc, &g, 1, 1, NULL); lo = rber_analytic(&g, &cm, &rc);
        grid_build(&g, &cm, 1, 15, 0.02, NULL); rdcfg_make(&rc, &g, 1, 1, NULL); up = rber_analytic(&g, &cm, &rc);
        fprintf(f, "%5.0f %5.0f %.3e %.3e %.3f %.3f %.3f\n", Ns[ni], ts[ti], lo, up, chan_ref_opt(&cm, 0),
                chan_ref_opt(&cm, 1), chan_ref_opt(&cm, 2));
        chan_free(&cm);
      }
  }
  fclose(f);
  return 0;
}
