/*
 * Test program (make test). Settings come from test.cfg (env CFG).
 * Prints one line per test group and a final summary: items, mismatches, PASS/FAIL.
 * Every error bound below is derived in the comment next to it; a bound is never
 * relaxed to make a test pass.
 */
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "../tools/io.h"
#include "ref.h"

static long ITEMS, MISM;
static uint64_t RNG = 20261118u;

static uint64_t rnd64(void) {
  RNG ^= RNG << 13;
  RNG ^= RNG >> 7;
  RNG ^= RNG << 17;
  return RNG;
}
static int32_t rndi(int32_t lo, int32_t hi) { return lo + (int32_t)(rnd64() % (uint64_t)(hi - lo + 1)); }
static double rndu(void) { return (double)(rnd64() >> 11) / 9007199254740992.0; }

static void check(const char *grp, long items, long bad, const char *fmt, double a, double b) {
  ITEMS += items;
  MISM += bad;
  printf("%-28s items %7ld mismatch %5ld  ", grp, items, bad);
  printf(fmt, a, b);
  printf("\n");
  fflush(stdout);
}

static double deq(int32_t q, kscl_t s) { return (double)q * s.m * pow(2.0, -s.e); }

/* ---------------- scalar helpers ---------------- */
static void t_rsqrt(void) {
  long n = 0, bad = 0;
  double worst = 0;
  int i, k;
  for (k = 0; k < 64; k++)
    for (i = 0; i < 4000; i++) {
      uint64_t u;
      int re;
      double rel;
      if (i == 0) u = (uint64_t)1 << k;
      else if (i == 1) u = ((uint64_t)1 << k) - 1 + (k == 0);
      else u = ((uint64_t)1 << k) | (rnd64() & (((uint64_t)1 << k) - 1));
      if (u == 0 || u > ((uint64_t)1 << 62)) continue;
      rel = fabs(k_rsqrt(u, &re) * pow(2.0, -re) * sqrt((double)u) - 1.0);
      if (rel > worst) worst = rel;
      /* 6-bit seed (1.5%) + 2 Newton steps -> < 1e-7 analytically; 16-bit result: 2^-15 */
      bad += rel > 3.1e-5;
      n++;
    }
  check("rsqrt rel err", n, bad, "max %.3g (bound %.3g)", worst, 3.1e-5);
}

static void t_exp(void) {
  int eb;
  for (eb = 4; eb <= 8; eb++) {
    const uint32_t *lut = k_exp_lut(eb);
    double h = 1.0 / (1 << eb), worst = 0;
    /* linear interpolation of 2^-x: |err| <= ln2^2 * h^2 / 8 (relative, x in [0,1)),
       plus 0.5 LSB table rounding, 0.5 LSB interpolation rounding, 0.5 LSB final shift */
    double bound_rel = 0.4805 * h * h / 8.0;
    long bad = 0, n = 0;
    uint32_t u;
    char nm[32];
    for (u = 0; u < (16u << 16); u++) {
      double ex = 65536.0 * pow(2.0, -(double)u / 65536.0);
      double err = fabs((double)k_exp2neg(u, eb, lut) - ex);
      double lim = ex * bound_rel + 1.5;
      if (err - lim > worst) worst = err - lim;
      bad += err > lim;
      n++;
    }
    sprintf(nm, "exp2 LUT b=%d", eb);
    check(nm, n, bad, "max over bound %.3g LSB (rel bound %.3g)", worst, bound_rel);
  }
}

static void t_sigmoid(void) {
  int sb;
  for (sb = 4; sb <= 8; sb++) {
    const uint32_t *lut = k_sig_lut(sb);
    double h = 16.0 / (1 << sb), worst = 0;
    /* |sigmoid''| <= 0.0962 -> interpolation err <= 0.0962 h^2 / 8; tail beyond 16: 1.2e-7 */
    double bound = 65536.0 * (0.0962 * h * h / 8.0 + 1.2e-7) + 1.0;
    long bad = 0, n = 0;
    int32_t a;
    char nm[32];
    for (a = -(20 << 16); a <= (20 << 16); a += 3) {
      double ex = 65536.0 / (1.0 + exp(-(double)a / 65536.0));
      double err = fabs((double)k_sigmoid(a, sb, lut) - ex);
      if (err > worst) worst = err;
      bad += err > bound;
      n++;
    }
    sprintf(nm, "sigmoid LUT b=%d", sb);
    check(nm, n, bad, "max %.3g LSB (bound %.3g)", worst, bound);
  }
}

/* ---------------- activation quantizer ---------------- */
static void fill_vec(int32_t *v, int n, int kind) {
  int i, mag = rndi(0, 30);
  for (i = 0; i < n; i++) {
    switch (kind) {
    case 0: v[i] = 0; break;
    case 1: v[i] = (rnd64() & 1) ? 2147483647 : (-2147483647 - 1); break;
    case 2: v[i] = rndi(-1, 1); break;
    default: v[i] = (int32_t)((int64_t)rndi(-(1 << 30), (1 << 30)) >> (30 - mag)); break;
    }
  }
}

static void t_actq(void) {
  int32_t v[300];
  int8_t q8[300];
  int16_t q16[300];
  long n = 0, bad = 0;
  double worst = 0;
  int it, mode, qi;
  for (it = 0; it < 4000; it++)
    for (mode = 0; mode < 2; mode++)
      for (qi = 0; qi < 2; qi++) {
        int len = rndi(1, 300), kind = it < 40 ? it % 4 : 3, i, qmax = qi ? 32767 : 127;
        double amax = 0, sc;
        int32_t mq = 0;
        kscl_t s;
        fill_vec(v, len, kind);
        k_actq(v, len, 16, mode, qmax, qi ? (void *)q16 : (void *)q8, &s);
        for (i = 0; i < len; i++) if (fabs((double)v[i]) > amax) amax = fabs((double)v[i]);
        sc = s.m * pow(2.0, -s.e) * 65536.0; /* scale in v units */
        for (i = 0; i < len; i++) {
          int32_t q = qi ? q16[i] : q8[i];
          /* dequantization error <= half a step plus the 2^-23 relative reciprocal error */
          double err = fabs(q * sc - v[i]), lim = 0.5 * sc + fabs((double)v[i]) * 1.2e-7 + 1e-9;
          if (abs(q) > mq) mq = abs(q);
          if (amax == 0) lim = 0, err = fabs((double)q);
          if (err / (sc > 0 ? sc : 1) > worst && amax > 0) worst = err / sc;
          bad += err > lim || abs(q) > qmax;
          n++;
        }
        /* range use: mantissa mode maps amax to >= qmax - 1, pow2 mode to > qmax / 2 */
        if (amax > 0) {
          bad += mode == ACT_MANT ? mq < qmax - 1 : mq <= qmax / 2;
          n++;
        }
      }
  check("actq dequant err", n, bad, "max %.4f step (bound 0.5 step) %g", worst, 0.0);
}

/* ---------------- gemv ---------------- */
static void t_gemv(void) {
  long n = 0, bad = 0;
  double worst = 0;
  int it;
  for (it = 0; it < 600; it++) {
    int rows = rndi(1, 40), nn = rndi(1, 64) * (it < 4 ? 256 : 4), gs = lm_group(nn, it % 3 ? 64 : 0);
    int ng = nn / gs, we = rndi(10, 24), fo = 16, r, i;
    int8_t *W = malloc((size_t)rows * nn), x[16384];
    uint16_t *m = malloc(sizeof(uint16_t) * rows * ng);
    int32_t y[64];
    kscl_t xs;
    int extreme = it < 4;
    for (i = 0; i < rows * nn; i++) W[i] = extreme ? (it & 1 ? 127 : -127) : (int8_t)rndi(-127, 127);
    for (i = 0; i < rows * ng; i++) m[i] = extreme ? 65535 : (uint16_t)rndi(1, 65535);
    for (i = 0; i < nn; i++) x[i] = extreme ? 127 : (int8_t)rndi(-127, 127);
    xs.m = extreme ? 131071 : rndi(0, 131071);
    xs.e = rndi(10, 30) + (extreme ? 30 : 0);
    k_gemv(W, m, we, rows, nn, gs, x, xs, fo, y);
    for (r = 0; r < rows; r++) {
      long double S = 0, ex;
      double err;
      for (i = 0; i < nn; i++) S += (long double)W[r * nn + i] * x[i] * m[r * ng + i / gs];
      ex = S * xs.m * powl(2.0L, -(we + xs.e - fo));
      if (ex > 2147483647.0L) ex = 2147483647.0L;
      if (ex < -2147483648.0L) ex = -2147483648.0L;
      err = (double)fabsl((long double)y[r] - ex);
      if (err > worst) worst = err;
      bad += err > 0.5 + 1e-9; /* exact integer path: only the final rounding */
      n++;
    }
    free(W);
    free(m);
  }
  check("gemv vs exact", n, bad, "max %.3f LSB (bound 0.5) %g", worst, 0.0);
}

/* ---------------- rmsnorm ---------------- */
static void t_rmsnorm(void) {
  long n = 0, bad = 0;
  double worst = 0;
  int it;
  for (it = 0; it < 3000; it++) {
    int len = it % 2 ? 288 : 64, i, mode = it % 3 == 0 ? ACT_POW2 : ACT_MANT, ge = rndi(8, 14);
    int32_t x[288];
    int16_t g[288];
    int8_t q[288];
    kscl_t s;
    double ss = 0, ymax = 0, y[288], sc, epsr = 1e-5;
    int32_t epsc = (int32_t)floor(len * 1e-5 * 4294967296.0 + 0.5);
    fill_vec(x, len, it < 12 ? it % 4 : 3);
    for (i = 0; i < len; i++) g[i] = (int16_t)rndi(-32767, 32767);
    k_rmsnorm(x, len, 16, g, ge, epsc, 16, mode, q, &s);
    for (i = 0; i < len; i++) ss += ((double)x[i] / 65536.0) * ((double)x[i] / 65536.0);
    for (i = 0; i < len; i++) {
      /* g holds gain * sqrt(n): y = x / sqrt(mean + eps) * g / sqrt(n) */
      y[i] = (double)x[i] / 65536.0 / sqrt(ss / len + epsr) * g[i] * pow(2.0, -ge) / sqrt((double)len);
      if (fabs(y[i]) > ymax) ymax = fabs(y[i]);
    }
    sc = s.m * pow(2.0, -s.e);
    for (i = 0; i < len; i++) {
      /* half a step; x reduced to 16 bits (2^-15 of max|x|, i.e. 2^-15 sqrt(n) of rms),
         rsqrt 3.1e-5, Q16 output rounding 2^-16 */
      double err = fabs(deq(q[i], s) - y[i]);
      double lim = 0.5 * sc + ymax * (3.1e-5 + 2.0 * pow(2.0, -15)) +
                   fabs(g[i] * pow(2.0, -ge)) * pow(2.0, -15) + 2.0 * pow(2.0, -16);
      if (ymax == 0) lim = 0;
      if (err - lim > worst) worst = err - lim;
      bad += err > lim;
      n++;
    }
  }
  check("rmsnorm vs float", n, bad, "max over bound %.3g %g", worst, 0.0);
}

/* ---------------- rope ---------------- */
static void t_rope(void) {
  long n = 0, bad = 0;
  double worst = 0;
  int it;
  for (it = 0; it < 2000; it++) {
    int hs = it % 2 ? 48 : 8, len = hs * rndi(1, 6), i;
    int32_t v[288], o[288];
    int16_t cs[48];
    double ang[24];
    fill_vec(v, len, it < 8 ? it % 4 : 3);
    for (i = 0; i < hs / 2; i++) {
      ang[i] = rndu() * 6.2831853;
      cs[2 * i] = (int16_t)floor(cos(ang[i]) * 16384.0 + 0.5);
      cs[2 * i + 1] = (int16_t)floor(sin(ang[i]) * 16384.0 + 0.5);
    }
    k_rope(v, len, hs, cs, o);
    for (i = 0; i < len; i += 2) {
      int j = (i % hs) / 2;
      double c = cos(ang[j]), s = sin(ang[j]);
      double e0 = v[i] * c - v[i + 1] * s, e1 = v[i] * s + v[i + 1] * c;
      /* Q14 table rounding 2^-15 per coefficient + 0.5 LSB output rounding (+ saturation) */
      double lim = (fabs((double)v[i]) + fabs((double)v[i + 1])) * pow(2.0, -15) + 0.5 + 1e-6;
      double d0, d1;
      if (e0 > 2147483647.0) e0 = 2147483647.0;
      if (e0 < -2147483648.0) e0 = -2147483648.0;
      if (e1 > 2147483647.0) e1 = 2147483647.0;
      if (e1 < -2147483648.0) e1 = -2147483648.0;
      d0 = fabs(o[i] - e0);
      d1 = fabs(o[i + 1] - e1);
      if (d0 - lim > worst) worst = d0 - lim;
      if (d1 - lim > worst) worst = d1 - lim;
      bad += (d0 > lim) + (d1 > lim);
      n += 2;
    }
  }
  check("rope vs float", n, bad, "max over bound %.3g %g", worst, 0.0);
}

/* ---------------- attention ---------------- */
static void t_attn(void) {
  long n = 0, bad = 0;
  double worst = 0;
  int it;
  for (it = 0; it < 3000; it++) {
    int esz = it % 2 ? 2 : 1, qmax = esz == 2 ? 32767 : 127, hs = it % 3 ? 48 : 8;
    int T = it < 20 ? 1 + it : rndi(1, 512), eb = it % 5 == 0 ? 4 : 8, t, i;
    int32_t qv[48], kv[48], p[512], o[48];
    static int8_t K8[512 * 48], V8[512 * 48];
    static int16_t K16[512 * 48], V16[512 * 48];
    int8_t q8[48];
    int16_t q16[48];
    static kscl_t ks[512], vs[512];
    kscl_t qs;
    double sc[512], pr[512], mx = -1e300, sum = 0, ex[48], vmax = 0, h = 1.0 / (1 << eb);
    /* magnitudes keep |score| < 2^15 (Q16 range): |q|, |k| <= 8, hs <= 48 */
    int mode = it % 4 == 0 ? ACT_POW2 : ACT_MANT, big = rndi(0, 12);
    for (i = 0; i < hs; i++) qv[i] = rndi(-(1 << 16), 1 << 16) << (big / 4);
    k_actq(qv, hs, 16, mode, qmax, esz == 2 ? (void *)q16 : (void *)q8, &qs);
    for (t = 0; t < T; t++) {
      int sh = rndi(0, 3);
      for (i = 0; i < hs; i++) kv[i] = (it < 20 && t > 0) ? 0 : rndi(-(1 << 16), 1 << 16) << sh;
      k_actq(kv, hs, 16, mode, qmax, esz == 2 ? (void *)(K16 + t * hs) : (void *)(K8 + t * hs), &ks[t]);
      for (i = 0; i < hs; i++) kv[i] = rndi(-(1 << 17), 1 << 17) >> rndi(0, 4);
      k_actq(kv, hs, 16, mode, qmax, esz == 2 ? (void *)(V16 + t * hs) : (void *)(V8 + t * hs), &vs[t]);
    }
    k_attn(T, hs, esz, esz == 2 ? (void *)q16 : (void *)q8, qs, esz == 2 ? (void *)K16 : (void *)K8, ks,
           esz == 2 ? (void *)V16 : (void *)V8, vs, eb, k_exp_lut(eb), p, o);
    /* float reference on the same quantized inputs */
    for (t = 0; t < T; t++) {
      double d = 0;
      for (i = 0; i < hs; i++) {
        double a = esz == 2 ? deq(q16[i], qs) : deq(q8[i], qs);
        double b = esz == 2 ? deq(K16[t * hs + i], ks[t]) : deq(K8[t * hs + i], ks[t]);
        d += a * b;
      }
      sc[t] = d;
      if (d > mx) mx = d;
    }
    for (t = 0; t < T; t++) sum += (pr[t] = exp(sc[t] - mx));
    for (i = 0; i < hs; i++) ex[i] = 0;
    for (t = 0; t < T; t++)
      for (i = 0; i < hs; i++) {
        double vv = esz == 2 ? deq(V16[t * hs + i], vs[t]) : deq(V8[t * hs + i], vs[t]);
        if (fabs(vv) > vmax) vmax = fabs(vv);
        ex[i] += pr[t] / sum * vv;
      }
    for (i = 0; i < hs; i++) {
      /* Per numerator e_t: relative error r from the score and exponent rounding
         (ln2 * 2.45 * 2^-17), the rounded log2(e) constant (5e-6 |d|, weighted mean |d| <= 8,
         4e-5) and LUT interpolation (ln2^2 h^2 / 8); absolute error 1.5 LSB (Q16).
         p_t = e_t / sum: sum(|dp|) <= 2 r + T (1.5 + 1.5 + 0.5) / 2^16 (numerators, sum,
         p rounding). V alignment with guard bits: T 2^-30 vmax. Output rounding 2^-17. */
      double r = 2.45 * 0.6931 * pow(2.0, -17) + 4e-5 + 0.4805 * h * h / 8.0;
      double lim = vmax * (2.0 * r + 3.5 * T / 65536.0 + T * pow(2.0, -30)) + pow(2.0, -17);
      double err = fabs(o[i] / 65536.0 - ex[i]);
      if (err - lim > worst) worst = err - lim;
      bad += err > lim;
      n++;
    }
  }
  check("attn vs float", n, bad, "max over bound %.3g %g", worst, 0.0);
}

/* ---------------- swiglu ---------------- */
static void t_swiglu(void) {
  long n = 0, bad = 0;
  double worst = 0;
  int it;
  for (it = 0; it < 2000; it++) {
    int len = it % 2 ? 768 : 172, i, sb = it % 3 ? 8 : 5, mode = it % 4 == 0 ? ACT_POW2 : ACT_MANT;
    static int32_t a[768], b[768];
    int8_t q[768];
    kscl_t s;
    double y[768], ymax = 0, h = 16.0 / (1 << sb), sigerr = 0.0962 * h * h / 8.0 + 1.2e-7 + 1.0 / 65536.0;
    int sh = rndi(0, 8);
    for (i = 0; i < len; i++) {
      a[i] = it < 2 ? 0 : rndi(-(1 << 20), 1 << 20) << (sh / 2);
      b[i] = it < 2 ? 0 : rndi(-(1 << 18), 1 << 18) << (sh / 2);
    }
    k_swiglu(a, b, len, sb, k_sig_lut(sb), mode, q, &s);
    for (i = 0; i < len; i++) {
      double x = a[i] / 65536.0;
      y[i] = x / (1.0 + exp(-x)) * (b[i] / 65536.0);
      if (fabs(y[i]) > ymax) ymax = fabs(y[i]);
    }
    for (i = 0; i < len; i++) {
      /* half a step; sigmoid error times |a b|; two Q16 roundings scaled by |b| and 1 */
      double lim = 0.5 * s.m * pow(2.0, -s.e) + fabs(a[i] / 65536.0 * b[i] / 65536.0) * sigerr +
                   (fabs(b[i] / 65536.0) + 1.0) * pow(2.0, -17) + ymax * 1.2e-7;
      double err = fabs(deq(q[i], s) - y[i]);
      if (ymax == 0) lim = 0;
      if (err - lim > worst) worst = err - lim;
      bad += err > lim;
      n++;
    }
  }
  check("swiglu vs float", n, bad, "max over bound %.3g %g", worst, 0.0);
}

/* ---------------- add, argmax, topk, k_exec range checks ---------------- */
static void t_misc(void) {
  long n = 0, bad = 0;
  int32_t a[4] = {2147483647, -2147483647 - 1, 5, -7}, b[4] = {1, -1, -5, 7}, o[4];
  int it;
  k_add(a, b, 4, o);
  bad += o[0] != 2147483647 || o[1] != -2147483647 - 1 || o[2] != 0 || o[3] != 0;
  n++;
  for (it = 0; it < 2000; it++) {
    int len = rndi(1, 600), k = rndi(1, len < 40 ? len : 40), i, j;
    int32_t v[600], idx[40], val[40];
    int mi = 0;
    for (i = 0; i < len; i++) v[i] = it % 2 ? rndi(-3, 3) : rndi(-1000000, 1000000);
    for (i = 1; i < len; i++) if (v[i] > v[mi]) mi = i;
    bad += k_argmax(v, len) != mi;
    n++;
    k_topk(v, len, k, idx, val);
    for (j = 0; j < k; j++) { /* reference: repeated first-max selection */
      int best = -1;
      for (i = 0; i < len; i++) {
        int used = 0, u;
        for (u = 0; u < j; u++) used |= idx[u] == i;
        if (!used && (best < 0 || v[i] > v[best])) best = i;
      }
      bad += idx[j] != best || val[j] != v[best];
      n++;
    }
  }
  { /* descriptor range checks must reject */
    kcall_t c;
    static int8_t W[4], x[K_NMAX + 1];
    static uint16_t m[4];
    static int32_t y[4];
    memset(&c, 0, sizeof(c));
    c.kid = K_GEMV;
    c.np = 7;
    c.prm[0] = 1; c.prm[1] = K_NMAX + 1; c.prm[2] = K_NMAX + 1;
    c.nb = 4;
    c.b[0].p = W; c.b[0].esz = 1; c.b[0].n = K_NMAX + 1;
    c.b[1].p = m; c.b[1].esz = 2; c.b[1].n = 1;
    c.b[2].p = x; c.b[2].esz = 1; c.b[2].n = K_NMAX + 1;
    c.b[3].p = y; c.b[3].esz = 4; c.b[3].n = 1;
    bad += k_exec(&c) == 0;
    c.prm[1] = 6; c.prm[2] = 4; /* group does not divide the row */
    bad += k_exec(&c) == 0;
    c.kid = 99;
    bad += k_exec(&c) == 0;
    n += 3;
  }
  check("add/argmax/topk/ranges", n, bad, "%g%g", 0.0, 0.0);
}

/* ---------------- F vs reference ---------------- */
static void t_ref(const char *ck, const char *tk, char **pr, int np, int steps, const char *tag) {
  bundle_t b;
  ref_t *r;
  int V, S, i, k;
  long tokn = 0, bad = 0, items = 0, exact = 0, nlog = 0;
  double maxerr = 0;
  int *t1 = malloc(sizeof(int) * 4096), *t2 = malloc(sizeof(int) * 4096);
  float *l = NULL, *lr = malloc(4);
  char nm[64];
  if (bundle_load(&b, ck, tk, "F")) { check("ref load", 1, 1, "%g%g", 0, 0); return; }
  r = ref_open(ck, tk, &V, &S);
  l = malloc(sizeof(float) * V);
  free(lr);
  lr = malloc(sizeof(float) * V);
  if (steps > S) steps = S;
  /* decode of every token after BOS and after an ordinary token */
  {
    long dbad = 0;
    for (k = 0; k < V; k++) {
      dbad += strcmp(lm_tok_decode(&b.tok, 1, k), ref_decode(r, 1, k)) != 0;
      dbad += strcmp(lm_tok_decode(&b.tok, 5, k), ref_decode(r, 5, k)) != 0;
    }
    sprintf(nm, "%s decode all ids", tag);
    check(nm, 2L * V, dbad, "%g%g", 0, 0);
  }
  for (i = 0; i < np; i++) {
    int n1, n2, pos, cur, pbad = 0;
    lm_tok_encode(&b.tok, pr[i], 1, 0, t1, &n1);
    ref_encode(r, pr[i], t2, &n2);
    if (n1 != n2) pbad = 1;
    for (k = 0; k < n1 && !pbad; k++) pbad |= t1[k] != t2[k];
    cur = t1[0];
    for (pos = 0; pos < steps && !pbad; pos++) {
      const float *rl = ref_forward(r, cur, pos);
      int am, ar, next;
      memcpy(lr, rl, sizeof(float) * V);
      am = bundle_step(&b, 0, cur, pos, l, NULL);
      for (k = 0; k < V; k++) {
        double d = fabs((double)l[k] - lr[k]);
        if (d > maxerr) maxerr = d;
        exact += l[k] == lr[k];
        nlog++;
      }
      ar = ref_sample(r, lr); /* reference temperature-0 sampler */
      next = pos < n1 - 1 ? t1[pos + 1] : am;
      if (pos >= n1 - 1) {
        tokn++;
        if (am != ar) pbad = 1;
      }
      if (next == 1) break;
      if (strcmp(lm_tok_decode(&b.tok, cur, next), ref_decode(r, cur, next))) pbad = 1;
      cur = next;
    }
    bad += pbad;
    items++;
  }
  sprintf(nm, "%s F vs ref (prompts)", tag);
  check(nm, items, bad, "gen tokens %.0f, logits max abs err %.3g", (double)tokn, maxerr);
  printf("    %s logits bit-identical %ld of %ld\n", tag, exact, nlog);
  ref_close(r);
  free(b.mem);
  free(b.ck);
  free(b.tk);
  free(l);
  free(lr);
  free(t1);
  free(t2);
}

/* ---------------- bank split ---------------- */
static void t_bank(const char *ck, const char *tk, const char *fmt, const char *tag) {
  bundle_t b;
  long n = 0, bad = 0;
  int banks[] = {1, 2, 3, 4, 5, 8, 16, 32}, bi, mode, l, mi;
  char nm[64];
  if (bundle_load(&b, ck, tk, fmt)) { check("bank load", 1, 1, "%g%g", 0, 0); return; }
  for (l = 0; l < b.c.n_layers + 1; l++)
    for (mi = 0; mi < 7; mi++) {
      lm_hw_t *w = &b.v[0].hw;
      const lm_hm_t *m = l == b.c.n_layers ? &w->cls
                         : mi == 0 ? &w->wq[l] : mi == 1 ? &w->wk[l] : mi == 2 ? &w->wv[l]
                         : mi == 3 ? &w->wo[l] : mi == 4 ? &w->w1[l] : mi == 5 ? &w->w2[l] : &w->w3[l];
      int8_t *x = malloc((size_t)m->n), *gb = malloc((size_t)m->n);
      int32_t *y0 = malloc(4 * (size_t)m->rows), *y1 = malloc(4 * (size_t)m->rows);
      int32_t *part = malloc(4 * (size_t)32 * m->rows * (m->n / m->gs));
      kscl_t xs;
      int i, rep;
      if (l == b.c.n_layers && mi > 0) { free(x); free(gb); free(y0); free(y1); free(part); continue; }
      for (rep = 0; rep < 3; rep++) {
        for (i = 0; i < m->n; i++) x[i] = rep == 0 ? 127 : (int8_t)rndi(-127, 127);
        xs.m = rep == 0 ? 131071 : rndi(1, 131071);
        xs.e = rndi(20, 34);
        k_gemv(m->q, m->m, m->we, m->rows, m->n, m->gs, x, xs, K_FX, y0);
        for (bi = 0; bi < 8; bi++)
          for (mode = 0; mode < 2; mode++) {
            lm_arena_t a;
            bank_mat_t bm;
            bank_stat_t st = {0, 0, 0};
            void *mem;
            memset(&a, 0, sizeof(a));
            bank_pack(&bm, m, banks[bi], mode, &a);
            {
              size_t need = a.off + 64;
              mem = malloc(need);
              memset(&a, 0, sizeof(a));
              a.base = mem;
              a.cap = need;
            }
            bank_pack(&bm, m, banks[bi], mode, &a);
            memset(y1, 0x5A, 4 * (size_t)m->rows);
            bank_gemv(&bm, x, xs, K_FX, y1, gb, part, &st);
            bad += memcmp(y0, y1, 4 * (size_t)m->rows) != 0;
            n++;
            free(mem);
          }
      }
      free(x); free(gb); free(y0); free(y1); free(part);
    }
  sprintf(nm, "%s bank==gemv %s", tag, fmt);
  check(nm, n, bad, "banks 1..32, ROW and COL %g%g", 0, 0);
  free(b.mem);
  free(b.ck);
  free(b.tk);
}

/* ---------------- dump and replay ---------------- */
static void t_dump(const char *ck, const char *tk, const char *fmt, const char *path, int cap, const char *tag) {
  bundle_t b;
  dump_t d;
  k_hook_t hk;
  FILE *f;
  int pos, cur = 1, rc;
  long n = 0, bad = 0, kinds[K_NKERN] = {0};
  float *l;
  char nm[64];
  if (bundle_load(&b, ck, tk, fmt)) { check("dump load", 1, 1, "%g%g", 0, 0); return; }
  l = malloc(sizeof(float) * b.c.vocab_size);
  memset(&d, 0, sizeof(d));
  d.cap = cap;
  d.f = fopen(path, "wb");
  hk.fn = dump_hook;
  hk.user = &d;
  for (pos = 0; pos < 6; pos++) {
    int a = bundle_step(&b, 0, cur, pos, l, &hk);
    bad += a < 0;
    cur = a;
  }
  fclose(d.f);
  f = fopen(path, "rb");
  for (;;) {
    kcall_t c;
    void *rec[KB_MAX];
    int i;
    rc = dump_read(f, &c, rec);
    if (rc <= 0) break;
    if (k_exec(&c)) bad++;
    for (i = 0; i < c.nb; i++)
      if (c.b[i].out) bad += memcmp(c.b[i].p, rec[i], (size_t)c.b[i].n * c.b[i].esz) != 0;
    kinds[c.kid]++;
    n++;
    dump_free(&c, rec);
  }
  fclose(f);
  bad += rc < 0;
  bad += n != d.recs;
  {
    int k, nk = 0;
    for (k = 1; k < K_NKERN; k++) nk += kinds[k] > 0;
    sprintf(nm, "%s dump replay %s", tag, fmt);
    check(nm, n, bad, "kernel kinds %g, records written %g", (double)nk, (double)d.recs);
  }
  free(l);
  free(b.mem);
  free(b.ck);
  free(b.tk);
}

/* ---------------- H forward runs clean, Q builds ---------------- */
static void t_build(const char *ck, const char *tk, const char *tag) {
  bundle_t b;
  char nm[64];
  int rc = bundle_load(&b, ck, tk, "Qr,Qg,HA,HB,HC,HD,HE,HF,HG,HH"), v, pos, bad = rc != 0;
  float *l;
  if (!rc) {
    l = malloc(sizeof(float) * b.c.vocab_size);
    for (v = 0; v < b.nv; v++) {
      int cur = 1;
      for (pos = 0; pos < 4; pos++) {
        cur = bundle_step(&b, v, cur, pos, l, NULL);
        bad += cur < 0;
        if (cur < 0) break;
      }
    }
    free(l);
    free(b.mem);
  }
  sprintf(nm, "%s build+run all variants", tag);
  check(nm, 1, bad > 0, "rc %g %g", (double)rc, 0.0);
}

int main(void) {
  char **pr;
  int np;
  if (cfg_load()) { printf("no test config\nFAIL\n"); return 1; }
  RNG = (uint64_t)cfg_i("seed", 20261118);
  printf("seed %llu\n", (unsigned long long)RNG);
  if ((-5 >> 1) != -3) { printf("arithmetic right shift required\nFAIL\n"); return 1; }
  t_rsqrt();
  t_exp();
  t_sigmoid();
  t_actq();
  t_gemv();
  t_rmsnorm();
  t_rope();
  t_attn();
  t_swiglu();
  t_misc();
  np = io_prompts(cfg_s("pf", ""), &pr);
  if (np <= 0) { printf("no prompts\nFAIL\n"); return 1; }
  if (!cfg_i("quick", 0)) {
    t_ref(cfg_s("ck1", ""), cfg_s("tk1", ""), pr, np, (int)cfg_i("steps1", 512), "m1");
    t_ref(cfg_s("ck2", ""), cfg_s("tk2", ""), pr, np, (int)cfg_i("steps2", 256), "m2");
  }
  t_build(cfg_s("ck1", ""), cfg_s("tk1", ""), "m1");
  t_build(cfg_s("ck2", ""), cfg_s("tk2", ""), "m2");
  t_bank(cfg_s("ck1", ""), cfg_s("tk1", ""), "HB", "m1");
  t_bank(cfg_s("ck1", ""), cfg_s("tk1", ""), "HC", "m1");
  t_bank(cfg_s("ck2", ""), cfg_s("tk2", ""), "HB", "m2");
  t_dump(cfg_s("ck1", ""), cfg_s("tk1", ""), "HB", cfg_s("dumpf", "k.bin"), 1000000, "m1");
  t_dump(cfg_s("ck1", ""), cfg_s("tk1", ""), "HD", cfg_s("dumpf", "k.bin"), 1000000, "m1");
  t_dump(cfg_s("ck2", ""), cfg_s("tk2", ""), "HA", cfg_s("dumpf", "k.bin"), 24, "m2");
  {
    FILE *f = fopen(cfg_s("chkres", "build/chk.res"), "r");
    long ci = 0, cb = 1;
    if (f) {
      if (fscanf(f, "items %ld mismatch %ld", &ci, &cb) != 2) cb = 1;
      fclose(f);
    }
    check("H path integer-only (chk)", ci ? ci : 1, cb, "%g%g", 0.0, 0.0);
  }
  printf("TOTAL items %ld mismatches %ld\n%s\n", ITEMS, MISM, MISM ? "FAIL" : "PASS");
  return MISM ? 1 : 0;
}
