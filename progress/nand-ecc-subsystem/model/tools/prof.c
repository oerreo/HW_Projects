/* Per-kernel PC time (no arguments, CFG keys code, tlc_tab, out, frames). m128 on the TLC channel
 * (P/E 3000, 30 days, LSB): workload B (FER simulation: message, encode, channel sample, sense, LLR,
 * decode, syndrome) at a hard-read and a soft-read condition, and the BCH kernels at the hard one.
 * For the N3 ARM baseline: same kernel boundaries (scope.md 2, K_*). Wall clock, one core, -O2. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "io.h"
#include "../src/bch.h"
#include "../src/dec_fix.h"
#include "../src/dec_ref.h"
#include "../src/enc.h"
#include "../src/llr.h"
#include "../src/rng.h"
#include "../src/sense.h"

enum { K_MSG, K_ENC, K_CHAN, K_SENSE, K_LLR, K_DEC, K_SYND, K_DECF, K_BENC, K_BSYND, K_BBM, K_BCHIEN, NK };
static const char *KN[NK] = {"K_MSG", "K_ENC", "K_CHAN", "K_SENSE", "K_LLR", "K_DEC(fix 6,7,8)", "K_SYND",
                             "(float NMS layered)", "K_BCH_ENC", "K_BCH_SYND", "K_BCH_BM", "K_BCH_CHIEN"};

int main(void)
{
  code_t c;
  char *tab;
  double mu[8], sg[8];
  FILE *f;
  int nf, ci;
  double alphas[2] = {1.4, 2.1};
  int levels[2] = {1, 7};
  bch_t b;
  if (cfg_load() || io_code(&c, cfg_s("code", "")) || !(tab = io_read(cfg_s("tlc_tab", ""), NULL))) return 1;
  f = fopen(cfg_s("out", "results/prof.txt"), "w");
  nf = (int)cfg_i("frames", 300);
  bch_init(&b, 14, 0x4443, 73, 8192);
  chan_tlc_lookup(tab, 30, 3000, mu, sg);
  fprintf(f, "# PC per-kernel wall time, ms per codeword (mean over %d frames), code n %d k %d\n", nf, c.n, c.k);
  for (ci = 0; ci < 2; ci++) {
    chan_t ch;
    grid_t g;
    rdcfg_t rc;
    llrlut_t L;
    dfix_cfg_t fc = {6, 7, 8, DF_NMS, 12, 0, 20, DF_ET_A};
    dref_cfg_t rcf = {DR_NMS, 1, 20, 0.75, 0, 1};
    dfix_t df;
    dref_t dr;
    double t[NK] = {0}, t0, tot = 0;
    uint8_t *u = calloc(9216, 1), *cw = calloc(9216, 1), *q = calloc(9216, 1), *reg = calloc(9216, 1), *h = calloc(9216, 1);
    int8_t *lq = calloc(9216, 1);
    double *lf = calloc(9216, sizeof(double));
    long its = 0, fe = 0;
    int fr, i, k;
    uint16_t S[300], lam[200];
    int pos[200];
    chan_tlc(&ch, mu, sg, alphas[ci]);
    grid_build(&g, &ch, 0, 15, 2.0, NULL);
    rdcfg_make(&rc, &g, levels[ci], 2, NULL);
    if (levels[ci] == 1) llr_build_hard(&L, &rc, 6, 15); else llr_build(&L, &g, &ch, &rc, 6, 2.0);
    dfix_init(&df, &c, &fc);
    dref_init(&dr, &c, &rcf);
    for (fr = 0; fr < nf; fr++) {
      rng_t r;
      rng_seed(&r, 9, fr);
      t0 = io_now();
      for (i = 0; i < c.k; i += 32) { uint32_t w = rng_next(&r); int j; for (j = 0; j < 32; j++) u[i + j] = (w >> j) & 1; }
      t[K_MSG] += io_now() - t0; t0 = io_now();
      enc_qc(&c, u, cw);
      t[K_ENC] += io_now() - t0; t0 = io_now();
      chan_sample(&g, cw, c.n, &r, q);
      t[K_CHAN] += io_now() - t0; t0 = io_now();
      sense_read(&rc, q, c.n, reg);
      t[K_SENSE] += io_now() - t0; t0 = io_now();
      for (i = 0; i < c.n; i++) lq[i] = L.lut[reg[i]];
      t[K_LLR] += io_now() - t0; t0 = io_now();
      dfix_decode(&df, lq);
      t[K_DEC] += io_now() - t0; t0 = io_now();
      fe += code_syndrome(&c, df.hard) != 0 || memcmp(df.hard, cw, c.n);
      t[K_SYND] += io_now() - t0;
      its += df.iters_used;
      llr_map_f(&L, &rc, q, c.n, lf);
      t0 = io_now();
      dref_decode(&dr, lf, h);
      t[K_DECF] += io_now() - t0;
      if (ci == 0) {
        int deg, nr;
        t0 = io_now();
        bch_encode(&b, u, cw);
        t[K_BENC] += io_now() - t0;
        chan_sample(&g, cw, b.n, &r, q);
        for (i = 0; i < b.n; i++) cw[i] = L.full[q[i]] < 0;
        t0 = io_now();
        bch_syndromes(&b, cw, S);
        t[K_BSYND] += io_now() - t0; t0 = io_now();
        deg = bch_bm(&b, S, lam);
        t[K_BBM] += io_now() - t0; t0 = io_now();
        if (deg <= b.t) nr = bch_chien(&b, lam, deg, pos);
        t[K_BCHIEN] += io_now() - t0;
        (void)nr;
      }
    }
    fprintf(f, "\n## condition alpha %.1f, sense levels %d, raw BER %.3e, avg iterations %.2f, FE %ld / %d\n",
            alphas[ci], levels[ci], rber_analytic(&g, &ch, &rc), (double)its / nf, fe, nf);
    for (k = K_MSG; k <= K_SYND; k++) tot += t[k];
    for (k = 0; k < NK; k++) {
      if (ci == 1 && k >= K_BENC) continue;
      fprintf(f, "%-22s %9.4f ms", KN[k], 1e3 * t[k] / nf);
      if (k <= K_SYND) fprintf(f, "  %5.1f %%", 100 * t[k] / tot);
      fprintf(f, "\n");
    }
    fprintf(f, "%-22s %9.4f ms (LDPC chain K_MSG..K_SYND)\n", "total", 1e3 * tot / nf);
    if (ci == 0) fprintf(f, "%-22s %9.4f ms\n", "BCH decode total", 1e3 * (t[K_BSYND] + t[K_BBM] + t[K_BCHIEN]) / nf);
    dfix_free(&df); dref_free(&dr);
  }
  fclose(f);
  return 0;
}
