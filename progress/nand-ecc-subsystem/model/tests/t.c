/* make test: unit and property tests of the C model. No arguments; paths from CFG (test.cfg).
 * Prints one line per item and at the end "TOTAL items N, failed F, PASS|FAIL". */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../tools/io.h"
#include "../src/bch.h"
#include "../src/chan.h"
#include "../src/code.h"
#include "../src/dec_fix.h"
#include "../src/dec_ref.h"
#include "../src/enc.h"
#include "../src/llr.h"
#include "../src/policy.h"
#include "../src/rng.h"
#include "../src/sense.h"

static int n_items, n_fail;
static void item(const char *name, int ok, const char *fmt, ...);
#include <stdarg.h>
static void item(const char *name, int ok, const char *fmt, ...)
{
  va_list ap;
  n_items++;
  if (!ok) n_fail++;
  printf("%-4s %-34s ", ok ? "ok" : "FAIL", name);
  va_start(ap, fmt);
  vprintf(fmt, ap);
  va_end(ap);
  printf("\n");
  fflush(stdout);
}

static uint64_t fnv(uint64_t h, const void *p, size_t n)
{
  const unsigned char *b = p;
  size_t i;
  for (i = 0; i < n; i++) { h ^= b[i]; h *= 0x100000001B3ull; }
  return h;
}

static void rand_bits(rng_t *r, uint8_t *u, int k)
{
  int i;
  for (i = 0; i < k; i++) u[i] = rng_next(r) >> 31;
}

static int load(code_t *c, const char *key)
{
  const char *p = cfg_s(key, NULL);
  if (!p || io_code(c, p)) { printf("cannot load %s (%s); run data/scripts/fetch.sh and make ext\n", key, p ? p : "-"); return -1; }
  return 0;
}

/* ------------------------------------------------------------------------------------------ RNG */
static void t_rng(void)
{
  static const uint32_t kat1[8] = {0x2d00, 0x0, 0x5a7080, 0x4389d80, 0x79199d9b, 0x61963b24, 0x4cb9b57a, 0xde9d7431};
  static const uint32_t kat2s[4] = {0xed969347, 0x17b2aad3, 0xd22d8279, 0xd6b825ad};
  static const uint32_t kat2o[4] = {0x34038d93, 0xdb045804, 0xd0fc94cc, 0x2c3c4eec};
  rng_t r;
  int i, ok = 1;
  double m = 0, v = 0, gm = 0, gv = 0;
  const int N = 200000;
  r.s[0] = 1; r.s[1] = 2; r.s[2] = 3; r.s[3] = 4;
  for (i = 0; i < 8; i++) ok &= rng_next(&r) == kat1[i];
  item("rng xoshiro128** KAT", ok, "state {1,2,3,4}, 8 outputs vs independent Python");
  rng_seed(&r, 20261126, 7);
  ok = 1;
  for (i = 0; i < 4; i++) ok &= r.s[i] == kat2s[i];
  for (i = 0; i < 4; i++) ok &= rng_next(&r) == kat2o[i];
  item("rng splitmix seeding KAT", ok, "seed 20261126 stream 7");
  rng_seed(&r, 5, 0);
  for (i = 0; i < N; i++) {
    double u = rng_u01(&r), g = rng_gauss(&r);
    if (!(u > 0 && u < 1)) ok = 0;
    m += u; v += u * u; gm += g; gv += g * g;
  }
  m /= N; v = v / N - m * m; gm /= N; gv = gv / N - gm * gm;
  item("rng u01/gauss moments", ok && fabs(m - 0.5) < 0.005 && fabs(v - 1.0 / 12) < 0.002 && fabs(gm) < 0.01 &&
       fabs(gv - 1) < 0.015, "u mean %.4f var %.5f, g mean %.4f var %.4f (N %d)", m, v, gm, gv, N);
}

/* ----------------------------------------------------------------------------------- code, enc */
static void t_code(code_t *t8, code_t *s32, code_t *m128)
{
  int r, w34 = 0, w35 = 0;
  item("code t8 load", t8->n == 96 && t8->m == 32 && t8->ddiag && t8->k == 64, "n %d m %d edges %d ddiag %d", t8->n, t8->m, t8->nedge, t8->ddiag);
  item("code s32 load", s32->n == 2304 && s32->m == 256 && s32->ddiag && s32->nedge == 34944 / 4,
       "n %d m %d edges %d", s32->n, s32->m, s32->nedge);
  for (r = 0; r < m128->m; r++) {
    int d = m128->row_ptr[r + 1] - m128->row_ptr[r];
    w34 += d == 34; w35 += d == 35;
  }
  item("code m128 load", m128->n == 9216 && m128->m == 1024 && m128->nedge == 34944 && w34 == 896 && w35 == 128 &&
       m128->ddiag && m128->k == 8192, "n %d m %d edges %d rows w34 %d w35 %d (code.md: 896/128, 34944)",
       m128->n, m128->m, m128->nedge, w34, w35);
}

static void t_enc(code_t *cs[3], const char *names[3])
{
  int ci, i, j;
  rng_t r;
  uint8_t *u = malloc(9216), *u2 = malloc(9216), *c1 = malloc(9216), *c2 = malloc(9216), *c3 = malloc(9216);
  for (ci = 0; ci < 3; ci++) {
    code_t *c = cs[ci];
    int N = ci == 2 ? 300 : 1000, good = 0, bad = 0, lin = 1, flip = 0;
    char nm[64];
    rng_seed(&r, 11 + ci, 0);
    for (i = 0; i < N; i++) {
      rand_bits(&r, u, c->k);
      bad |= enc_qc(c, u, c1);
      good += code_syndrome(c, c1) == 0;
      c1[rng_next(&r) % c->n] ^= 1;
      flip += code_syndrome(c, c1) != 0;
    }
    snprintf(nm, sizeof nm, "enc %s random H c = 0", names[ci]);
    item(nm, good == N && !bad && flip == N, "%d / %d codewords, single flip detected %d / %d", good, N, flip, N);
    for (i = 0; i < 50; i++) {
      rand_bits(&r, u, c->k); rand_bits(&r, u2, c->k);
      enc_qc(c, u, c1); enc_qc(c, u2, c2);
      for (j = 0; j < c->k; j++) u[j] ^= u2[j];
      enc_qc(c, u, c3);
      for (j = 0; j < c->n; j++) lin &= (c1[j] ^ c2[j]) == c3[j];
    }
    memset(u, 0, (size_t)c->k);
    enc_qc(c, u, c1);
    for (j = 0; j < c->n; j++) lin &= c1[j] == 0;
    snprintf(nm, sizeof nm, "enc %s linear, zero", names[ci]);
    item(nm, lin, "enc(a^b) = enc(a)^enc(b) for 50 pairs, enc(0) = 0");
  }
  {
    code_t *c = cs[2];
    int b, pi, good = 0, tot = 0, pos[3] = {0, 63, 127};
    for (b = 0; b < c->nb - c->mb; b++)
      for (pi = 0; pi < 3; pi++) {
        memset(u, 0, (size_t)c->k);
        u[b * c->Z + pos[pi]] = 1;
        enc_qc(c, u, c1);
        good += code_syndrome(c, c1) == 0;
        tot++;
      }
    item("enc m128 unit messages", good == tot, "%d / %d (64 blocks x positions 0, 63, 127)", good, tot);
  }
  free(u); free(u2); free(c1); free(c2); free(c3);
}

static void t_genc(code_t *c, const char *name, int want_rank, int N)
{
  genc_t g;
  rng_t r;
  uint8_t *u, *cw;
  int i, good = 0;
  char nm[64];
  snprintf(nm, sizeof nm, "genc %s rank, codewords", name);
  if (genc_build(&g, c)) { item(nm, 0, "build failed"); return; }
  u = calloc(g.k + 1, 1); cw = calloc(c->n, 1);
  rng_seed(&r, 99, 0);
  for (i = 0; i < N; i++) {
    rand_bits(&r, u, g.k);
    genc_encode(&g, u, cw);
    good += code_syndrome(c, cw) == 0;
  }
  item(nm, g.rank == want_rank && good == N, "rank %d (expect %d), k %d, %d / %d H c = 0", g.rank, want_rank, g.k, good, N);
  genc_free(&g); free(u); free(cw);
}

/* -------------------------------------------------------------------------------------- decoders */
static void t_dec_noiseless(code_t *c)
{
  rng_t r;
  uint8_t *u = malloc(9216), *cw = malloc(9216), *h = malloc(9216);
  double *lf = malloc(sizeof(double) * 9216);
  int8_t *lq = malloc(9216);
  int i, ok = 1, d;
  dref_cfg_t rcs[5] = {{DR_SPA, 0, 50, 1, 0, 1}, {DR_SPA, 1, 50, 1, 0, 1}, {DR_NMS, 0, 20, 0.75, 0, 1},
                       {DR_NMS, 1, 20, 0.75, 0, 1}, {DR_OMS, 1, 20, 1, 0.5, 1}};
  dfix_cfg_t fcs[3] = {{6, 6, 8, DF_NMS, 12, 0, 20, DF_ET_A}, {6, 6, 8, DF_NMS, 12, 0, 20, DF_ET_B},
                       {5, 5, 7, DF_OMS, 0, 1, 20, DF_ET_NONE}};
  int its[8];
  rng_seed(&r, 3, 0);
  rand_bits(&r, u, c->k);
  enc_qc(c, u, cw);
  for (i = 0; i < c->n; i++) { lf[i] = cw[i] ? -8.0 : 8.0; lq[i] = cw[i] ? -15 : 15; }
  for (d = 0; d < 5; d++) {
    dref_t dr;
    dref_init(&dr, c, &rcs[d]);
    ok &= dref_decode(&dr, lf, h) && !memcmp(h, cw, c->n) && dr.iters_used == 1;
    its[d] = dr.iters_used;
    dref_free(&dr);
  }
  for (d = 0; d < 3; d++) {
    dfix_t df;
    int want = d == 0 ? 1 : d == 1 ? 1 : 20;
    dfix_init(&df, c, &fcs[d]);
    ok &= dfix_decode(&df, lq) && !memcmp(df.hard, cw, c->n) && df.iters_used == want;
    its[5 + d] = df.iters_used;
    dfix_free(&df);
  }
  item("dec noiseless, all decoders", ok, "iterations ref %d %d %d %d %d, fix ET-A %d ET-B %d none %d",
       its[0], its[1], its[2], its[3], its[4], its[5], its[6], its[7]);
  /* erasure: all-zero LLR -> hard decision all zero = a codeword -> ok after one iteration */
  {
    dfix_t df;
    int nz = 0;
    memset(lq, 0, (size_t)c->n);
    dfix_init(&df, c, &fcs[0]);
    ok = dfix_decode(&df, lq);
    for (i = 0; i < c->n; i++) nz += df.hard[i];
    item("dec fix erasure input", ok && nz == 0 && df.iters_used == 1, "ok %d iterations %d ones %d (all-zero word is a codeword)", ok, df.iters_used, nz);
    dfix_free(&df);
  }
  free(u); free(cw); free(h); free(lf); free(lq);
}

static void t_corr(void)
{
  dfix_cfg_t a = {6, 6, 8, DF_NMS, 12, 0, 20, DF_ET_A}, b = {6, 6, 8, DF_OMS, 0, 1, 20, DF_ET_A};
  int ok = df_corr(&a, 31) == 23 && df_corr(&a, 1) == 0 && df_corr(&a, 2) == 1 && df_corr(&a, 0) == 0 &&
           df_corr(&b, 0) == 0 && df_corr(&b, 1) == 0 && df_corr(&b, 5) == 4 && df_sat(40, 31) == 31 &&
           df_sat(-40, 31) == -31 && df_sat(-31, 31) == -31;
  a.nms_num = 13;
  ok &= df_corr(&a, 31) == 25;   /* 31 * 13 = 403 >> 4 = 25 */
  item("dec fix correction, saturation", ok, "NMS floor(m*num/16), OMS max(m-b,0), symmetric sat");
}

/* t8: every single and double error pattern with hard input +-A */
static void t_dec_t8(code_t *c)
{
  dfix_cfg_t fc = {6, 6, 8, DF_NMS, 12, 0, 20, DF_ET_A};
  dfix_t df;
  int8_t lq[96];
  int i, j, s1 = 0, s2 = 0, n2 = 0, und = 0, okflag_bad = 0;
  dfix_init(&df, c, &fc);
  for (i = 0; i < c->n; i++) {
    int ok;
    memset(lq, 15, sizeof lq);
    lq[i] = -15;
    ok = dfix_decode(&df, lq);
    for (j = 0; j < c->n && !df.hard[j]; j++) {}
    s1 += ok && j == c->n;
    if (ok && code_syndrome(c, df.hard)) okflag_bad++;
  }
  for (i = 0; i < c->n; i++)
    for (j = i + 1; j < c->n; j++) {
      int ok, k, z = 1;
      memset(lq, 15, sizeof lq);
      lq[i] = -15; lq[j] = -15;
      ok = dfix_decode(&df, lq);
      for (k = 0; k < c->n; k++) z &= !df.hard[k];
      s2 += ok && z;
      und += ok && !z;
      if (ok && code_syndrome(c, df.hard)) okflag_bad++;
      n2++;
    }
  item("dec fix t8 single errors", s1 == c->n && !okflag_bad, "corrected %d / %d (hard +-15, NMS 12/16, 20 it)", s1, c->n);
  item("dec fix t8 double errors (stat)", n2 == 4560 && !okflag_bad, "corrected %d / %d, converged to another codeword %d, ok-flag violations %d",
       s2, n2, und, okflag_bad);
  dfix_free(&df);
}

/* AWGN on s32: float vs fixed statistics, ET-A vs ET-B, layered vs flooding iterations */
static void t_dec_awgn(code_t *c)
{
  const int N = 400;
  const double ebn0 = 3.5, rate = (double)c->k / c->n, sg = sqrt(1.0 / (2 * rate * pow(10, ebn0 / 10)));
  dref_cfg_t cl = {DR_NMS, 1, 20, 0.75, 0, 1}, cf = {DR_NMS, 0, 20, 0.75, 0, 1};
  dfix_cfg_t fa = {6, 6, 8, DF_NMS, 12, 0, 20, DF_ET_A}, fb = fa;
  dref_t dl, dfl;
  dfix_t xa, xb;
  rng_t r;
  uint8_t *u = malloc(9216), *cw = malloc(9216), *h = malloc(9216);
  double *lf = malloc(sizeof(double) * 9216);
  int8_t *lq = malloc(9216);
  int i, f, fe_l = 0, fe_f = 0, fe_a = 0, fe_b = 0, dis = 0, itl = 0, itf = 0, okviol = 0, etord = 1, both = 0, sameout = 0;
  fb.et = DF_ET_B;
  dref_init(&dl, c, &cl); dref_init(&dfl, c, &cf);
  dfix_init(&xa, c, &fa); dfix_init(&xb, c, &fb);
  for (f = 0; f < N; f++) {
    int ol, oa, ob, el, ea, eb;
    rng_seed(&r, 777, f);
    rand_bits(&r, u, c->k);
    enc_qc(c, u, cw);
    for (i = 0; i < c->n; i++) {
      double y = (cw[i] ? -1.0 : 1.0) + sg * rng_gauss(&r);
      lf[i] = 2 * y / (sg * sg);
      lq[i] = (int8_t)llr_quant(lf[i], 2.0, 6);
    }
    ol = dref_decode(&dl, lf, h); el = memcmp(h, cw, c->n) != 0; fe_l += el; itl += dl.iters_used;
    dref_decode(&dfl, lf, h); fe_f += memcmp(h, cw, c->n) != 0; itf += dfl.iters_used;
    oa = dfix_decode(&xa, lq); ea = memcmp(xa.hard, cw, c->n) != 0; fe_a += ea;
    ob = dfix_decode(&xb, lq); eb = memcmp(xb.hard, cw, c->n) != 0; fe_b += eb;
    if (oa && code_syndrome(c, xa.hard)) okviol++;
    if (ob && code_syndrome(c, xb.hard)) okviol++;
    if (oa && ob) { both++; if (xb.iters_used < xa.iters_used) etord = 0; sameout += !memcmp(xa.hard, xb.hard, c->n); }
    dis += el != ea;
    (void)ol;
  }
  item("dec s32 AWGN float vs fixed (stat)", fe_a <= 3 * fe_l + 10, "Eb/N0 %.1f dB, %d frames: FE float NMS-layered %d, fixed(6,6,8) %d, disagree %d",
       ebn0, N, fe_l, fe_a, dis);
  item("dec layered converges faster", itl < itf, "avg iterations layered %.2f flooding %.2f (FE %d / %d)", (double)itl / N, (double)itf / N, fe_l, fe_f);
  item("dec fix ok flag => H x = 0", okviol == 0, "violations %d over %d decodes", okviol, 2 * N);
  item("dec fix ET-B stops no earlier", etord, "frames ok in both %d: ET-B iter >= ET-A iter on all; same output %d / %d (others: decoder left the ET-A codeword), FE A %d B %d",
       both, sameout, both, fe_a, fe_b);
  dref_free(&dl); dref_free(&dfl); dfix_free(&xa); dfix_free(&xb);
  free(u); free(cw); free(h); free(lf); free(lq);
}

/* -------------------------------------------------------------------------------------------- BCH */
static void t_bch(void)
{
  bch_t b;
  rng_t r;
  uint8_t *u = malloc(9216), *cw = malloc(9216), *rx = malloc(9216);
  uint16_t S[300];
  int i, f, ok, j, good, fail = 0, mis = 0, perm[9216];
  if (bch_init(&b, 14, 0x4443, 73, 8192)) { item("bch init", 0, "failed"); return; }
  item("bch GF(2^14) self check", bch_gf_check(&b) == 0, "poly 0x%x, alpha order 16383, a * a^-1 = 1 for all a", b.poly);
  ok = b.r == 1015 && b.n == 9207 && b.g[0] == 1 && b.g[b.r] == 1;
  for (j = 1; j <= 146; j++) {
    /* g(alpha^j) = 0 */
    uint16_t acc = 0;
    for (i = 0; i <= b.r; i++) if (b.g[i]) acc ^= b.exp_t[(int)(((long)i * j) % b.q1)];
    ok &= acc == 0;
  }
  item("bch generator", ok, "deg g %d (scope.md 1015), n %d, g(alpha^j) = 0 for j = 1..146", b.r, b.n);
  rng_seed(&r, 21, 0);
  good = 0;
  for (f = 0; f < 50; f++) {
    rand_bits(&r, u, b.k);
    bch_encode(&b, u, cw);
    good += bch_syndromes(&b, cw, S);
  }
  item("bch encode syndromes zero", good == 50, "%d / 50", good);
  good = 0;
  for (f = 0; f < 60; f++) {
    rand_bits(&r, u, b.k);
    bch_encode(&b, u, cw);
    memcpy(rx, cw, b.n);
    for (i = 0; i < b.n; i++) perm[i] = i;
    for (i = 0; i < 73; i++) { int k = i + rng_next(&r) % (b.n - i), t = perm[i]; perm[i] = perm[k]; perm[k] = t; rx[perm[i]] ^= 1; }
    good += bch_decode(&b, rx, NULL) == 0 && !memcmp(rx, cw, b.n);
  }
  item("bch t = 73 errors corrected", good == 60, "%d / 60 frames", good);
  {
    int pos[4] = {0, 1014, 1015, 9206};
    good = 0;
    for (i = 0; i < 4; i++) {
      memcpy(rx, cw, b.n);
      rx[pos[i]] ^= 1;
      good += bch_decode(&b, rx, NULL) == 0 && !memcmp(rx, cw, b.n);
    }
    item("bch boundary single errors", good == 4, "positions 0, 1014, 1015, 9206: %d / 4", good);
  }
  good = 0;
  for (f = 0; f < 60; f++) {
    int st;
    rand_bits(&r, u, b.k);
    bch_encode(&b, u, cw);
    memcpy(rx, cw, b.n);
    for (i = 0; i < b.n; i++) perm[i] = i;
    for (i = 0; i < 74; i++) { int k = i + rng_next(&r) % (b.n - i), t = perm[i]; perm[i] = perm[k]; perm[k] = t; rx[perm[i]] ^= 1; }
    st = bch_decode(&b, rx, NULL);
    if (st) { fail++; good += 1; }
    else if (memcmp(rx, cw, b.n)) { mis++; good += 1; }
  }
  item("bch t+1 = 74 errors (stat)", good == 60, "detected failure %d, miscorrection %d, never the sent word (%d / 60)", fail, mis, good);
  /* BSC Monte Carlo vs binomial tail */
  {
    const double p = 0.0068;
    const int N = 600;
    int fe = 0;
    double s = 0, sd, pf;
    for (f = 0; f < N; f++) {
      rand_bits(&r, u, b.k);
      bch_encode(&b, u, cw);
      memcpy(rx, cw, b.n);
      for (i = 0; i < b.n; i++) if (rng_u01(&r) < p) rx[i] ^= 1;
      bch_decode(&b, rx, NULL);
      fe += memcmp(rx, cw, b.n) != 0;
    }
    for (i = 74; i <= 400; i++)
      s += exp(lgamma(b.n + 1.0) - lgamma(i + 1.0) - lgamma(b.n - i + 1.0) + i * log(p) + (b.n - i) * log1p(-p));
    sd = sqrt(s * (1 - s) / N);
    pf = (double)fe / N;
    item("bch BSC FER vs binomial", fabs(pf - s) < 4 * sd + 1e-3, "p %.4f: MC %.4f (%d / %d), P(errors > 73) %.4f, |diff| %.1f sd", p, pf, fe, N, s, fabs(pf - s) / sd);
  }
  bch_free(&b);
  free(u); free(cw); free(rx);
}

/* ---------------------------------------------------------------------------------------- channel */
static void t_chan(const char *tab)
{
  double mu[8], sg[8];
  chan_t ch;
  grid_t g;
  rdcfg_t rh, r7;
  llrlut_t L;
  rng_t r;
  int i, s, ok;
  static const double ref_s1[7] = {13.90, 93.49, 151.45, 211.40, 262.47, 315.66, 369.00};
  ok = chan_tlc_lookup(tab, 15, 500, mu, sg) == 0 && mu[0] == -85 && mu[7] == 401.5 && sg[0] == 18.2 && sg[7] == 9.0;
  ok &= chan_tlc_lookup(tab, 90, 5000, mu, sg) == 0 && mu[7] == 404.2 && sg[0] == 19.7;
  item("chan TLC table lookup", ok, "[R5] A1 P/E 500 and A3 P/E 5000 rows");
  chan_tlc_lookup(tab, 15, 500, mu, sg);
  chan_tlc(&ch, mu, sg, 1.0);
  ok = 1;
  {
    double md = 0;
    for (s = 0; s < 7; s++) { double d = fabs(chan_ref_opt(&ch, s) - ref_s1[s]); if (d > md) md = d; }
    item("chan TLC optimal refs", md < 0.05, "max |R - s1calc| %.4f (s1calc.txt 7)", md);
  }
  {
    static const double want[3][2] = {{1.197e-4, 3.456e-3}, {2.769e-4, 7.340e-3}, {2.137e-4, 7.920e-3}};
    double worst = 0, al[2] = {1.0, 1.5};
    int pg, ai;
    for (pg = 0; pg < 3; pg++)
      for (ai = 0; ai < 2; ai++) {
        double rb;
        chan_tlc(&ch, mu, sg, al[ai]);
        grid_build(&g, &ch, pg, 15, 2.0, NULL);
        rdcfg_make(&rh, &g, 1, 1, NULL);
        rb = rber_analytic(&g, &ch, &rh);
        if (fabs(rb / want[pg][ai] - 1) > worst) worst = fabs(rb / want[pg][ai] - 1);
      }
    item("chan TLC raw BER vs s1calc", worst < 0.005, "6 values (3 pages x alpha 1, 1.5), max rel diff %.2e", worst);
  }
  chan_tlc(&ch, mu, sg, 1.5);
  grid_build(&g, &ch, 0, 15, 2.0, NULL);
  ok = 1;
  for (s = 0; s < 8; s++) for (i = 1; i < g.npt; i++) ok &= g.T[s][i] >= g.T[s][i - 1];
  item("chan table monotone", ok, "T[s][j] nondecreasing, %d grid points", g.npt);
  /* integer sampler vs table probabilities and vs the Box-Muller reference sampler (LSB, 16 grid regions) */
  {
    const int N = 400000;
    long hi[64] = {0}, hr[64] = {0};
    uint8_t *bits = malloc(N), *q = malloc(N), *q2 = malloc(N);
    double zmax = 0, zref = 0;
    rng_seed(&r, 31, 0);
    for (i = 0; i < N; i++) bits[i] = rng_next(&r) >> 31;
    chan_sample(&g, bits, N, &r, q);
    chan_sample_ref(&g, &ch, bits, N, &r, q2);
    for (i = 0; i < N; i++) { hi[q[i]]++; hr[q2[i]]++; }
    for (i = 0; i <= g.npt; i++) {
      double p = 0;
      for (s = 0; s < 8; s++) {
        double lo = i ? g.T[s][i - 1] / 4294967296.0 : 0, up = i < g.npt ? g.T[s][i] / 4294967296.0 : 1;
        p += (up - lo) / 8;
      }
      if (p * N > 5) {
        double sd = sqrt(N * p * (1 - p)), z = fabs(hi[i] - N * p) / sd, z2 = fabs(hr[i] - N * p) / sd;
        if (z > zmax) zmax = z;
        if (z2 > zref) zref = z2;
      }
    }
    item("chan sampler histogram", zmax < 5 && zref < 5, "%d cells, %d regions: max |z| integer sampler %.2f, Box-Muller reference %.2f",
         N, g.npt + 1, zmax, zref);
    /* hard raw BER measured vs table */
    {
      long err = 0;
      double pt, sd;
      rdcfg_make(&rh, &g, 1, 1, NULL);
      for (i = 0; i < N; i++) err += rh.hbit[rh.map[q[i]]] != bits[i];
      pt = rber_table(&g, &rh);
      sd = sqrt(pt * (1 - pt) / N);
      item("chan raw BER MC vs table", fabs((double)err / N - pt) < 5 * sd, "MC %.4e table %.4e analytic %.4e (alpha 1.5, LSB)", (double)err / N, pt, rber_analytic(&g, &ch, &rh));
    }
    free(bits); free(q); free(q2);
  }
  /* LLR LUT for +6 levels: sign and monotonicity, range */
  rdcfg_make(&r7, &g, 7, 2, NULL);
  llr_build(&L, &g, &ch, &r7, 6, 2.0);
  ok = r7.nreg == 8;
  for (i = 1; i < r7.nreg; i++) ok &= L.llr[i] > L.llr[i - 1] && L.lut[i] >= L.lut[i - 1];
  for (i = 0; i < r7.nreg; i++) ok &= abs(L.lut[i]) <= 31 && ((L.llr[i] < 0) == (r7.hbit[i] == 1) || fabs(L.llr[i]) < 1e-9);
  item("llr LUT +6 LSB", ok, "regions %d LLR %.2f %.2f %.2f %.2f %.2f %.2f %.2f %.2f -> %d %d %d %d %d %d %d %d", r7.nreg,
       L.llr[0], L.llr[1], L.llr[2], L.llr[3], L.llr[4], L.llr[5], L.llr[6], L.llr[7],
       L.lut[0], L.lut[1], L.lut[2], L.lut[3], L.lut[4], L.lut[5], L.lut[6], L.lut[7]);
  /* MSB page (4 boundaries) grid and hard bits */
  grid_build(&g, &ch, 2, 15, 2.0, NULL);
  rdcfg_make(&rh, &g, 1, 1, NULL);
  ok = g.B == 4 && rh.nreg == 5 && rh.hbit[0] == 1 && rh.hbit[1] == 0 && rh.hbit[2] == 1 && rh.hbit[3] == 0 && rh.hbit[4] == 1;
  item("sense MSB hard read map", ok, "boundaries %d, region bits %d%d%d%d%d (Table 1: 1,0,0,1,1,0,0,1)", g.B,
       rh.hbit[0], rh.hbit[1], rh.hbit[2], rh.hbit[3], rh.hbit[4]);
  /* MLC analytic model */
  {
    mlc_param_t mp;
    chan_t cm;
    double rb[3], Ns[3] = {1000, 5000, 10000}, rf[3];
    int k;
    mlc_param_default(&mp);
    ok = 1;
    for (k = 0; k < 3; k++) {
      grid_t gm;
      rdcfg_t rm;
      if (chan_mlc(&cm, &mp, Ns[k], 8760)) { ok = 0; break; }
      for (s = 0; s < 4; s++) ok &= fabs(chan_cdf(&cm, s, 9.0) - 1) < 1e-9 && chan_cdf(&cm, s, -2) < 1e-9;
      grid_build(&gm, &cm, 1, 15, 0.02, NULL);
      rdcfg_make(&rm, &gm, 1, 1, NULL);
      rb[k] = rber_analytic(&gm, &cm, &rm);
      rf[k] = gm.ref[0];
      chan_free(&cm);
    }
    item("chan MLC model", ok && rb[0] < rb[1] && rb[1] < rb[2], "upper page raw BER (1 year) N 1K %.3e, 5K %.3e, 10K %.3e; E|P1 ref %.3f %.3f %.3f",
         rb[0], rb[1], rb[2], rf[0], rf[1], rf[2]);
  }
}

/* ------------------------------------------------------------------------------- policy, determinism */
static void t_policy(code_t *c, const char *tab)
{
  double mu[8], sg[8];
  chan_t ch;
  grid_t g;
  pol_cfg_t pc;
  pol_t p;
  dfix_cfg_t fc = {6, 6, 8, DF_NMS, 12, 0, 20, DF_ET_A};
  dfix_t df;
  rng_t r;
  uint8_t *u = malloc(9216), *cw = malloc(9216), *q = malloc(9216);
  int8_t *lq = malloc(9216);
  int f, st[8] = {0}, ai, und = 0;
  double al[2] = {1.0, 2.0}, lat[2] = {0, 0};
  memset(&pc, 0, sizeof pc);
  pc.nretry = 1; pc.roff[0][0] = 1; pc.nsoft = 3; pc.soft_levels[0] = 3; pc.soft_levels[1] = 5; pc.soft_levels[2] = 7;
  pc.dstep = 2; pc.hardA = 15; pc.scale = 2.0;
  pc.t_sense_hard = 41; pc.t_sense_level = 14; pc.t_xfer_byte = 0.005; pc.t_dec_iter = 10;
  chan_tlc_lookup(tab, 15, 500, mu, sg);
  dfix_init(&df, c, &fc);
  for (ai = 0; ai < 2; ai++) {
    chan_tlc(&ch, mu, sg, al[ai]);
    grid_build(&g, &ch, 0, 15, 2.0, NULL);
    if (policy_init(&p, &pc, &g, &ch, 6)) { item("policy init", 0, ""); return; }
    for (f = 0; f < 20; f++) {
      pol_res_t res;
      rng_seed(&r, 41 + ai, f);
      rand_bits(&r, u, c->k);
      enc_qc(c, u, cw);
      chan_sample(&g, cw, c->n, &r, q);
      policy_run(&p, &df, q, cw, lq, &res);
      if (ai == 1) st[res.stage + 1]++;
      else st[7] += res.stage == 0;
      und += res.undetected;
      lat[ai] += res.latency_us / 20;
    }
  }
  item("policy stages", st[7] == 20 && und == 0, "alpha 1.0: %d / 20 at hard stage; alpha 2.0: fail %d hard %d retry %d soft+2 %d +4 %d +6 %d; mean latency %.0f / %.0f us",
       st[7], st[0], st[1], st[2], st[3], st[4], st[5], lat[0], lat[1]);
  dfix_free(&df);
  free(u); free(cw); free(q); free(lq);
}

static uint64_t mini_run(code_t *c, const char *tab, uint64_t seed)
{
  double mu[8], sg[8];
  chan_t ch;
  grid_t g;
  rdcfg_t r7;
  llrlut_t L;
  dfix_cfg_t fc = {6, 6, 8, DF_NMS, 12, 0, 15, DF_ET_A};
  dfix_t df;
  dref_cfg_t rc = {DR_NMS, 1, 15, 0.75, 0, 1};
  dref_t dr;
  rng_t r;
  uint8_t *u = malloc(9216), *cw = malloc(9216), *q = malloc(9216), *h = malloc(9216);
  int8_t *lq = malloc(9216);
  double *lf = malloc(sizeof(double) * 9216);
  uint64_t hh = 0xcbf29ce484222325ull;
  int f;
  chan_tlc_lookup(tab, 15, 500, mu, sg);
  chan_tlc(&ch, mu, sg, 2.2);
  grid_build(&g, &ch, 0, 15, 2.0, NULL);
  rdcfg_make(&r7, &g, 3, 2, NULL);
  llr_build(&L, &g, &ch, &r7, 6, 2.0);
  dfix_init(&df, c, &fc);
  dref_init(&dr, c, &rc);
  for (f = 0; f < 150; f++) {
    rng_seed(&r, seed, f);
    rand_bits(&r, u, c->k);
    enc_qc(c, u, cw);
    chan_sample(&g, cw, c->n, &r, q);
    llr_map(&L, q, c->n, lq);
    llr_map_f(&L, &r7, q, c->n, lf);
    hh = fnv(hh, q, c->n);
    dfix_decode(&df, lq);
    hh = fnv(hh, df.hard, c->n);
    hh = fnv(hh, &df.iters_used, sizeof df.iters_used);
    dref_decode(&dr, lf, h);
    hh = fnv(hh, h, c->n);
  }
  dfix_free(&df); dref_free(&dr);
  free(u); free(cw); free(q); free(h); free(lq); free(lf);
  return hh;
}

int main(void)
{
  code_t t8, s32, m128, eth, c2;
  char *tab;
  const char *names[3] = {"t8", "s32", "m128"};
  code_t *cs[3];
  if (cfg_load()) { printf("no config\n"); return 1; }
  if (load(&t8, "t8") || load(&s32, "s32") || load(&m128, "m128")) return 1;
  tab = io_read(cfg_s("tlc_tab", ""), NULL);
  if (!tab) { printf("no TLC table\n"); return 1; }
  cs[0] = &t8; cs[1] = &s32; cs[2] = &m128;
  t_rng();
  t_code(&t8, &s32, &m128);
  t_enc(cs, names);
  t_genc(&t8, "t8", 32, 200);
  t_genc(&s32, "s32", 256, 100);
  t_genc(&m128, "m128", 1024, 20);
  if (!load(&eth, "eth")) {
    item("code 802.3an alist", eth.n == 2048 && eth.m == 384 && eth.nedge == 12288 && eth.dv_max == 6 && eth.dc_max == 32,
         "n %d m %d edges %d dv %d dc %d", eth.n, eth.m, eth.nedge, eth.dv_max, eth.dc_max);
    t_genc(&eth, "802.3an", 325, 50);
  } else item("code 802.3an alist", 0, "missing");
  if (!load(&c2, "c2")) {
    item("code CCSDS C2 alist", c2.n == 8176 && c2.m == 1022 && c2.nedge == 32704 && c2.dv_max == 4 && c2.dc_max == 32,
         "n %d m %d edges %d dv %d dc %d", c2.n, c2.m, c2.nedge, c2.dv_max, c2.dc_max);
    t_genc(&c2, "CCSDS C2", 1020, 20);
  } else item("code CCSDS C2 alist", 0, "missing");
  t_corr();
  t_dec_noiseless(&m128);
  t_dec_noiseless(&s32);
  t_dec_t8(&t8);
  t_dec_awgn(&s32);
  t_bch();
  t_chan(tab);
  t_policy(&m128, tab);
  {
    uint64_t a = mini_run(&s32, tab, 1234), b = mini_run(&s32, tab, 1234), c = mini_run(&s32, tab, 1235);
    item("determinism (same seed)", a == b && a != c, "s32 TLC +2 levels, 150 frames: hash %016llx %016llx, other seed %016llx",
         (unsigned long long)a, (unsigned long long)b, (unsigned long long)c);
  }
  printf("TOTAL items %d, failed %d, %s\n", n_items, n_fail, n_fail ? "FAIL" : "PASS");
  return n_fail != 0;
}
