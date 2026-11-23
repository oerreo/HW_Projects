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

/* ================= S2b additions (run after all earlier groups, so the random
   sequence of the earlier groups is unchanged) ================= */

/* actq with qmax 2047 (12-bit values in int16): same bounds as t_actq */
static void t_actq12(void) {
  int32_t v[300];
  int16_t q16[300];
  long n = 0, bad = 0;
  double worst = 0;
  int it, mode;
  for (it = 0; it < 4000; it++)
    for (mode = 0; mode < 2; mode++) {
      int len = rndi(1, 300), kind = it < 40 ? it % 4 : 3, i, qmax = 2047;
      double amax = 0, sc;
      int32_t mq = 0;
      kscl_t s;
      fill_vec(v, len, kind);
      k_actq(v, len, 16, mode, qmax, q16, &s);
      for (i = 0; i < len; i++) if (fabs((double)v[i]) > amax) amax = fabs((double)v[i]);
      sc = s.m * pow(2.0, -s.e) * 65536.0;
      for (i = 0; i < len; i++) {
        int32_t q = q16[i];
        double err = fabs(q * sc - v[i]), lim = 0.5 * sc + fabs((double)v[i]) * 1.2e-7 + 1e-9;
        if (abs(q) > mq) mq = abs(q);
        if (amax == 0) lim = 0, err = fabs((double)q);
        if (amax > 0 && err / sc > worst) worst = err / sc;
        bad += err > lim || abs(q) > qmax;
        n++;
      }
      if (amax > 0) {
        bad += mode == ACT_MANT ? mq < qmax - 1 : mq <= qmax / 2;
        n++;
      }
    }
  check("actq 12-bit dequant err", n, bad, "max %.4f step (bound 0.5 step) %g", worst, 0.0);
}

/* k_attn2: (a) kb = vb = 8 and 16 are bit-exact with k_attn esz 1 and 2; (b) every
   (kb, vb) in {8, 12, 16}^2 meets the t_attn bound against float on the same quantized
   inputs. The bound carries over: the dot shift d0 = 2 kb - 17 keeps the dropped part
   2^d0 / qmax^2 at about 2^-15 of the score scale for 12 and 16 bits, the same as int16 in
   t_attn; V width enters only through the dequantized vmax. */
static void t_attn2(void) {
  long n = 0, bad = 0, nx = 0, bx = 0;
  double worst = 0;
  int it, bits[3] = {8, 12, 16};
  for (it = 0; it < 2700; it++) {
    int kb = bits[it % 3], vb = bits[(it / 3) % 3], hs = it % 2 ? 48 : 8;
    int qk = (1 << (kb - 1)) - 1, qv = (1 << (vb - 1)) - 1, ek = kb > 8 ? 2 : 1, ev = vb > 8 ? 2 : 1;
    int T = it < 27 ? 1 + it : rndi(1, 512), eb = it % 5 == 0 ? 4 : 8, t, i;
    int32_t qv32[48], kv[48], p[512], o[48], p2[512], o2[48];
    static int8_t K8[512 * 48], V8[512 * 48];
    static int16_t K16[512 * 48], V16[512 * 48];
    int8_t q8[48];
    int16_t q16[48];
    static kscl_t ks[512], vs[512];
    kscl_t qs;
    void *qp = ek == 2 ? (void *)q16 : (void *)q8, *Kp = ek == 2 ? (void *)K16 : (void *)K8;
    void *Vp = ev == 2 ? (void *)V16 : (void *)V8;
    double sc[512], pr[512], mx = -1e300, sum = 0, ex[48], vmax = 0, h = 1.0 / (1 << eb);
    int mode = it % 4 == 0 ? ACT_POW2 : ACT_MANT, big = rndi(0, 12);
    for (i = 0; i < hs; i++) qv32[i] = rndi(-(1 << 16), 1 << 16) << (big / 4);
    k_actq(qv32, hs, 16, mode, qk, qp, &qs);
    for (t = 0; t < T; t++) {
      int sh = rndi(0, 3);
      for (i = 0; i < hs; i++) kv[i] = (it < 27 && t > 0) ? 0 : rndi(-(1 << 16), 1 << 16) << sh;
      k_actq(kv, hs, 16, mode, qk, ek == 2 ? (void *)(K16 + t * hs) : (void *)(K8 + t * hs), &ks[t]);
      for (i = 0; i < hs; i++) kv[i] = rndi(-(1 << 17), 1 << 17) >> rndi(0, 4);
      k_actq(kv, hs, 16, mode, qv, ev == 2 ? (void *)(V16 + t * hs) : (void *)(V8 + t * hs), &vs[t]);
    }
    k_attn2(T, hs, kb, vb, qp, qs, Kp, ks, Vp, vs, eb, k_exp_lut(eb), p, o);
    if (kb == vb && kb != 12) { /* (a) equality with the original kernel */
      k_attn(T, hs, ek, qp, qs, Kp, ks, Vp, vs, eb, k_exp_lut(eb), p2, o2);
      bx += memcmp(p, p2, 4 * (size_t)T) != 0 || memcmp(o, o2, 4 * (size_t)hs) != 0;
      nx++;
    }
    for (t = 0; t < T; t++) {
      double d = 0;
      for (i = 0; i < hs; i++) {
        double a = ek == 2 ? deq(q16[i], qs) : deq(q8[i], qs);
        double b = ek == 2 ? deq(K16[t * hs + i], ks[t]) : deq(K8[t * hs + i], ks[t]);
        d += a * b;
      }
      sc[t] = d;
      if (d > mx) mx = d;
    }
    for (t = 0; t < T; t++) sum += (pr[t] = exp(sc[t] - mx));
    for (i = 0; i < hs; i++) ex[i] = 0;
    for (t = 0; t < T; t++)
      for (i = 0; i < hs; i++) {
        double vv = ev == 2 ? deq(V16[t * hs + i], vs[t]) : deq(V8[t * hs + i], vs[t]);
        if (fabs(vv) > vmax) vmax = fabs(vv);
        ex[i] += pr[t] / sum * vv;
      }
    for (i = 0; i < hs; i++) { /* same bound as t_attn */
      double r = 2.45 * 0.6931 * pow(2.0, -17) + 4e-5 + 0.4805 * h * h / 8.0;
      double lim = vmax * (2.0 * r + 3.5 * T / 65536.0 + T * pow(2.0, -30)) + pow(2.0, -17);
      double err = fabs(o[i] / 65536.0 - ex[i]);
      if (err - lim > worst) worst = err - lim;
      bad += err > lim;
      n++;
    }
  }
  check("attn2 == attn (8/8, 16/16)", nx, bx, "bit-exact %g%g", 0.0, 0.0);
  check("attn2 vs float (9 widths)", n, bad, "max over bound %.3g %g", worst, 0.0);
  { /* descriptor checks: bad widths and a bad actq qmax must be rejected */
    kcall_t c;
    static int32_t buf[64];
    long rn = 0, rb = 0;
    int kbad[3] = {10, 0, 32}, j, i;
    for (j = 0; j < 3; j++) {
      memset(&c, 0, sizeof(c));
      c.kid = K_ATTN2;
      c.np = 7;
      c.prm[0] = 1; c.prm[1] = 8; c.prm[2] = kbad[j]; c.prm[3] = 8; c.prm[6] = 8;
      c.nb = 8;
      for (i = 0; i < 8; i++) { c.b[i].p = buf; c.b[i].esz = 2; c.b[i].n = 8; }
      rb += k_exec(&c) == 0;
      rn++;
    }
    memset(&c, 0, sizeof(c));
    c.kid = K_ACTQ;
    c.np = 4;
    c.prm[0] = 8; c.prm[3] = 1000;
    c.nb = 3;
    c.b[0].p = buf; c.b[0].esz = 4; c.b[0].n = 8;
    c.b[1].p = buf + 16; c.b[1].esz = 2; c.b[1].n = 8;
    c.b[2].p = buf + 32; c.b[2].esz = 4; c.b[2].n = 2;
    rb += k_exec(&c) == 0;
    rn++;
    check("attn2/actq12 range reject", rn, rb, "%g%g", 0.0, 0.0);
  }
}

/* forward level: a K_ATTN2 format with the widths of an original format gives the same
   logits bit for bit, and a window gives the same logits as no window while T <= win */
static void t_fwd2(const char *ck, const char *tk, int steps, const char *tag) {
  /* pairs: (0,1) K8V8 vs HB, (2,3) K16V16 vs HD, (4,1) HBw64 vs HB for pos < 64 */
  bundle_t b;
  char nm[64];
  long n = 0, bad = 0, after = 0;
  int rc = bundle_load(&b, ck, tk, "K8V8,HB,K16V16,HD,HBw64"), pos, v, cur = 1;
  int32_t *L[5];
  if (rc) { check("fwd2 load", 1, 1, "%g%g", 0, 0); return; }
  for (pos = 0; pos < steps && pos < b.c.seq_len; pos++) {
    int next = -1;
    for (v = 0; v < 5; v++) {
      const int32_t *l = lm_h_forward(&b.v[v].hs, &b.c, &b.v[v].hw, cur, pos, NULL);
      bad += l == NULL;
      L[v] = b.v[v].hs.logits;
      if (v == 1 && l) next = b.v[v].hs.argmax[0];
    }
    bad += memcmp(L[0], L[1], 4 * (size_t)b.c.vocab_size) != 0;
    bad += memcmp(L[2], L[3], 4 * (size_t)b.c.vocab_size) != 0;
    n += 2;
    if (pos < 64) {
      bad += memcmp(L[4], L[1], 4 * (size_t)b.c.vocab_size) != 0;
      n++;
    } else {
      after += memcmp(L[4], L[1], 4 * (size_t)b.c.vocab_size) != 0;
    }
    cur = next == 1 || next < 0 ? 2 : next; /* keep going past BOS */
  }
  sprintf(nm, "%s fwd attn2/window", tag);
  check(nm, n, bad, "window differs after 64 at %g of %g positions", (double)after,
        (double)(steps > 64 ? steps - 64 : 0));
  free(b.mem);
  free(b.ck);
  free(b.tk);
}

/* every S2b format builds and runs */
static void t_build2(const char *ck, const char *tk, const char *vars, const char *tag) {
  bundle_t b;
  char nm[64];
  int rc = bundle_load(&b, ck, tk, vars), v, pos, bad = rc != 0;
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
    free(b.ck);
    free(b.tk);
  }
  sprintf(nm, "%s build+run S2b formats", tag);
  check(nm, 1, bad > 0, "rc %g %g", (double)rc, 0.0);
}

/* ================= S4-1 additions (after all earlier groups; they draw random numbers
   only after every earlier group, so the earlier sequence is unchanged) ================= */

/* stage functions and traces (hierarchy.md 4 A1..A7): every K12V8 kernel record of a short
   run is replayed through k_exec_st; the output must equal the recorded one, and the
   recorded output must follow from the trace through the exported stage functions. */
static void t_stage(const char *ck, const char *tk, int steps, const char *path, const char *tag) {
  bundle_t b;
  dump_t d;
  FILE *f;
  int tok[1] = {1}, rc;
  long n = 0, bad = 0, nrec = 0;
  char nm[64];
  if (bundle_load(&b, ck, tk, "K12V8")) { check("stage load", 1, 1, "%g%g", 0, 0); return; }
  memset(&d, 0, sizeof(d));
  d.cap = 1000000000;
  d.f = fopen(path, "wb");
  bad += dump_steps(&b, 0, tok, 1, steps, NULL, 1, &d, NULL, NULL) != steps;
  fclose(d.f);
  f = fopen(path, "rb");
  for (;;) {
    kcall_t c;
    void *rec[KB_MAX];
    const int32_t *P;
    int i, t;
    rc = dump_read(f, &c, rec);
    if (rc <= 0) break;
    P = c.prm;
    nrec++;
    switch (c.kid) {
    case K_GEMV: {
      int rows = P[0], nn = P[1], gs = P[2], sh = P[3] + P[5] - P[6];
      int64_t *S = malloc(sizeof(int64_t) * rows);
      const int8_t *W = c.b[0].p, *x = c.b[2].p;
      const uint16_t *wm = c.b[1].p;
      const int32_t *y = rec[3];
      bad += k_exec_st(&c, S) != 0;
      for (i = 0; i < rows; i++) {
        bad += y[i] != k_gemv_out(S[i], P[4], sh);
        bad += gs != nn || S[i] != (int64_t)k_dot8(W + (size_t)i * nn, x, nn) * wm[i];
        n += 2;
      }
      free(S);
      break;
    }
    case K_ACTQ: {
      k_actq_st_t st;
      const int32_t *v = c.b[0].p;
      const kscl_t *s = rec[2];
      memset(&st, 0, sizeof(st));
      bad += k_exec_st(&c, &st) != 0;
      for (i = 0; i < P[0]; i++) {
        int32_t q = P[3] == 127 ? ((int8_t *)rec[1])[i] : ((int16_t *)rec[1])[i];
        bad += q != (st.amax ? k_aq_one(&st.aq, v[i]) : 0);
        n++;
      }
      bad += st.amax ? (s->m != st.aq.M || s->e != st.aq.e + P[1]) : (s->m != 0 || s->e != 0);
      n++;
      break;
    }
    case K_RMSNORM: {
      k_rms_st_t st;
      const kscl_t *s = rec[3];
      int re2;
      memset(&st, 0, sizeof(st));
      st.y = malloc(sizeof(int32_t) * P[0]);
      bad += k_exec_st(&c, &st) != 0;
      for (i = 0; i < P[0]; i++) {
        bad += ((int8_t *)rec[2])[i] != (st.ymax ? k_aq_one(&st.aq, st.y[i]) : 0);
        n++;
      }
      bad += st.sh != P[2] + st.re - P[4];
      bad += k_rsqrt(st.u, &re2) != st.rm || re2 != st.re;
      bad += st.ymax ? (s->m != st.aq.M || s->e != st.aq.e + P[4]) : (s->m != 0 || s->e != 0);
      n += 3;
      free(st.y);
      break;
    }
    case K_SWIGLU: {
      k_swi_st_t st;
      const kscl_t *s = rec[4];
      memset(&st, 0, sizeof(st));
      st.g = malloc(sizeof(int32_t) * P[0]);
      bad += k_exec_st(&c, &st) != 0;
      for (i = 0; i < P[0]; i++) {
        bad += ((int8_t *)rec[3])[i] != (st.amax ? k_aq_one(&st.aq, st.g[i]) : 0);
        n++;
      }
      bad += st.amax ? (s->m != st.aq.M || s->e != st.aq.e + K_FX) : (s->m != 0 || s->e != 0);
      n++;
      free(st.g);
      break;
    }
    case K_ATTN2: {
      int T = P[0], hs = P[1];
      k_attn_st_t st;
      const kscl_t *ks = c.b[2].p;
      const int32_t *p = rec[6], *o = rec[7];
      uint64_t sum = 0;
      int32_t mx;
      memset(&st, 0, sizeof(st));
      st.dot = malloc(sizeof(int64_t) * T);
      st.s = malloc(sizeof(int32_t) * T);
      st.e = malloc(sizeof(uint32_t) * T);
      st.w = malloc(sizeof(int64_t) * T);
      st.acc = malloc(sizeof(int64_t) * hs);
      bad += k_exec_st(&c, &st) != 0;
      mx = st.s[0];
      for (t = 0; t < T; t++) {
        int64_t cc = (int64_t)P[4] * ks[t].m;
        bad += st.s[t] != k_sat32(k_rshr(k_rshr(st.dot[t], st.d0) * cc, P[5] + ks[t].e - st.d0 - K_FS));
        bad += p[t] != (int32_t)(((uint64_t)st.e[t] * st.R + ((uint64_t)1 << 31)) >> 32);
        if (st.s[t] > mx) mx = st.s[t];
        sum += st.e[t];
        n += 2;
      }
      bad += mx != st.mx || sum != st.sum || st.R != ((uint64_t)1 << 48) / st.sum;
      for (i = 0; i < hs; i++) bad += o[i] != (st.have ? k_sat32(k_rshr(st.acc[i], 16 + st.emin + st.G - K_FX)) : 0);
      n += 1 + hs;
      free(st.dot); free(st.s); free(st.e); free(st.w); free(st.acc);
      break;
    }
    default:
      bad += k_exec(&c) != 0;
      break;
    }
    for (i = 0; i < c.nb; i++)
      if (c.b[i].out) bad += memcmp(c.b[i].p, rec[i], (size_t)c.b[i].n * c.b[i].esz) != 0;
    n++;
    dump_free(&c, rec);
  }
  fclose(f);
  bad += rc < 0 || nrec != d.recs;
  sprintf(nm, "%s stage traces K12V8", tag);
  check(nm, n, bad, "records %g, positions %g", (double)nrec, (double)steps);
  free(b.mem);
  free(b.ck);
  free(b.tk);
}

static int t_mats(const bundle_t *b, const lm_hm_t **o) {
  const lm_hw_t *w = &b->v[0].hw;
  int l, n = 0;
  for (l = 0; l < b->c.n_layers; l++) {
    o[n++] = &w->wq[l]; o[n++] = &w->wk[l]; o[n++] = &w->wv[l]; o[n++] = &w->wo[l];
    o[n++] = &w->w1[l]; o[n++] = &w->w3[l]; o[n++] = &w->w2[l];
  }
  o[n++] = &w->cls;
  return n;
}

/* A6: PIM bank image (NB 4 x LB 16, depth 4096) of every 260K matrix. The image rebuilt
   into a bank_mat_t must equal bank_pack(BANK_ROW) array for array, bank_gemv on it must
   equal k_gemv, and the depth must be the 4072 words of arch.md 3.1. */
static void t_bimg(const char *ck, const char *tk, const char *tag) {
  bundle_t b;
  const lm_hm_t *ms[128];
  int nm, i, k, nb = 4;
  long n = 0, bad = 0, depth = 4096, base = 0;
  bimg_word_t *img[4];
  char nm2[64];
  if (bundle_load(&b, ck, tk, "K12V8")) { check("bimg load", 1, 1, "%g%g", 0, 0); return; }
  nm = t_mats(&b, ms);
  for (k = 0; k < nb; k++) img[k] = calloc((size_t)depth, sizeof(bimg_word_t));
  for (i = 0; i < nm; i++) {
    const lm_hm_t *m = ms[i];
    lm_arena_t a;
    bank_mat_t bu, bp;
    void *mu, *mp;
    int8_t *x = malloc((size_t)m->n), *gb = malloc((size_t)m->n);
    int32_t *y0 = malloc(4 * (size_t)m->rows), *y1 = malloc(4 * (size_t)m->rows);
    long w = bimg_pack(img, nb, depth, base, m->q, m->m, m->rows, m->n), viol;
    int rep;
    bad += m->gs != m->n || w != bimg_words(m->rows, m->n, nb);
    n++;
    memset(&a, 0, sizeof(a));
    bimg_unpack(&bu, (const bimg_word_t *const *)img, nb, base, m->rows, m->n, m->we, &a);
    mu = malloc(a.off + 64);
    memset(&a, 0, sizeof(a)); a.base = mu; a.cap = 1 << 30;
    viol = bimg_unpack(&bu, (const bimg_word_t *const *)img, nb, base, m->rows, m->n, m->we, &a);
    memset(&a, 0, sizeof(a));
    bank_pack(&bp, m, nb, BANK_ROW, &a);
    mp = malloc(a.off + 64);
    memset(&a, 0, sizeof(a)); a.base = mp; a.cap = 1 << 30;
    bank_pack(&bp, m, nb, BANK_ROW, &a);
    bad += viol != 0;
    n++;
    for (k = 0; k < nb; k++) {
      bad += bu.brows[k] != bp.brows[k];
      bad += memcmp(bu.bw[k], bp.bw[k], (size_t)bp.brows[k] * m->n) != 0;
      bad += memcmp(bu.bm[k], bp.bm[k], sizeof(uint16_t) * bp.brows[k]) != 0;
      n += 3;
    }
    for (rep = 0; rep < 3; rep++) {
      kscl_t xs;
      bank_stat_t s1 = {0, 0, 0}, s2 = {0, 0, 0};
      int j;
      for (j = 0; j < m->n; j++) x[j] = rep == 0 ? 127 : (int8_t)rndi(-127, 127);
      xs.m = rep == 0 ? 131071 : rndi(1, 131071);
      xs.e = rndi(20, 34);
      k_gemv(m->q, m->m, m->we, m->rows, m->n, m->gs, x, xs, K_FX, y0);
      memset(y1, 0x5A, 4 * (size_t)m->rows);
      bank_gemv(&bu, x, xs, K_FX, y1, gb, NULL, &s1);
      bad += memcmp(y0, y1, 4 * (size_t)m->rows) != 0;
      bank_gemv(&bp, x, xs, K_FX, y1, gb, NULL, &s2);
      bad += s1.wrgb != s2.wrgb || s1.mac != s2.mac || s1.rdmac != s2.rdmac;
      bad += s1.mac != (long)((m->rows + nb - 1) / nb) * ((m->n + 15) / 16);
      n += 3;
    }
    base += w > 0 ? w : 0;
    free(mu); free(mp); free(x); free(gb); free(y0); free(y1);
  }
  bad += base != 4072; /* arch.md 3.1 [calculated] */
  n++;
  { /* zero tags outside the used range and nothing written past it */
    long a2;
    for (k = 0; k < nb; k++)
      for (a2 = base; a2 < depth; a2++) {
        int l;
        bad += img[k][a2].tag != 0;
        for (l = 0; l < BIMG_LB; l++) bad += img[k][a2].d[l] != 0;
      }
    n++;
    bad += bimg_pack(img, nb, depth, depth - 1, ms[0]->q, ms[0]->m, ms[0]->rows, ms[0]->n) != -1;
    n++;
  }
  for (k = 0; k < nb; k++) free(img[k]);
  sprintf(nm2, "%s PIM bank image", tag);
  check(nm2, n, bad, "matrices %g, words per bank %g", (double)nm, (double)base);
  free(b.mem);
  free(b.ck);
  free(b.tk);
}

/* gemv row records (arch.md 2.2) of every matrix: pack, unpack, compare */
static void t_rrec(const char *ck, const char *tk, const char *tag) {
  bundle_t b;
  const lm_hm_t *ms[128];
  int nm, i;
  long n = 0, bad = 0, tot = 0, raw = 0;
  char nm2[64];
  if (bundle_load(&b, ck, tk, "K12V8")) { check("rrec load", 1, 1, "%g%g", 0, 0); return; }
  nm = t_mats(&b, ms);
  for (i = 0; i < nm; i++) {
    const lm_hm_t *m = ms[i];
    long nbt = rrec_bytes(m->rows, m->n);
    uint8_t *buf = malloc((size_t)nbt);
    int8_t *W = malloc((size_t)m->rows * m->n);
    uint16_t *wm = malloc(sizeof(uint16_t) * m->rows);
    bad += m->gs != m->n;
    bad += rrec_pack(buf, m->q, m->m, m->rows, m->n) != nbt;
    bad += nbt != (long)m->rows * (8 + ((m->n + 7) / 8) * 8);
    bad += rrec_unpack(buf, m->rows, m->n, W, wm) != 0;
    bad += memcmp(W, m->q, (size_t)m->rows * m->n) != 0;
    bad += memcmp(wm, m->m, sizeof(uint16_t) * m->rows) != 0;
    n += 6;
    tot += nbt;
    raw += (long)m->rows * ((m->n + 7) / 8) * 8;
    free(buf); free(W); free(wm);
  }
  sprintf(nm2, "%s gemv row records", tag);
  check(nm2, n, bad, "bytes %g, header overhead %.2f%%", (double)tot, 100.0 * (tot - raw) / raw);
  free(b.mem);
  free(b.ck);
  free(b.tk);
}

/* position filter of job dump: the filtered file equals the records of the selected
   positions of an unfiltered run, in order */
static void t_dumpf(const char *ck, const char *tk, const char *pa, const char *pb, const char *tag) {
  bundle_t b;
  dump_t d;
  int tok[1] = {1}, steps = 12, pos, i;
  long seg[13], n = 0, bad = 0, nsel = 0;
  const char *spec = "0-2,5,9-10";
  char nm[64];
  FILE *fa, *fb;
  /* parser */
  {
    static const struct { const char *s; int pos, want; } pc[] = {
      {NULL, 7, 1}, {"", 7, 1}, {"0-7,63", 63, 1}, {"0-7,63", 8, 0}, {"0-7,63", 0, 1},
      {"5", 5, 1}, {"5", 4, 0}, {"1-3, 9", 9, 1}, {"x", 0, 0}, {"2-", 2, 0}};
    for (i = 0; i < (int)(sizeof(pc) / sizeof(pc[0])); i++) {
      bad += pos_sel(pc[i].s, pc[i].pos) != pc[i].want;
      n++;
    }
  }
  if (bundle_load(&b, ck, tk, "K12V8")) { check("dumpf load", 1, 1, "%g%g", 0, 0); return; }
  memset(&d, 0, sizeof(d));
  d.cap = 1000000000;
  d.f = fopen(pa, "wb");
  bad += dump_steps(&b, 0, tok, 1, steps, NULL, 1, &d, seg, NULL) != steps;
  fclose(d.f);
  memset(&d, 0, sizeof(d));
  d.cap = 1000000000;
  d.f = fopen(pb, "wb");
  bad += dump_steps(&b, 0, tok, 1, steps, spec, 1, &d, NULL, &nsel) != steps;
  fclose(d.f);
  bad += nsel != 6;
  fa = fopen(pa, "rb");
  fb = fopen(pb, "rb");
  for (pos = 0; pos < steps; pos++) {
    long len = seg[pos + 1] - seg[pos], j;
    if (!pos_sel(spec, pos)) continue;
    fseek(fa, seg[pos], SEEK_SET);
    for (j = 0; j < len; j++) bad += fgetc(fa) != fgetc(fb);
    n++;
  }
  bad += fgetc(fb) != EOF;
  n++;
  fclose(fa);
  fclose(fb);
  sprintf(nm, "%s dump position filter", tag);
  check(nm, n, bad, "selected %g of %g positions", (double)nsel, (double)steps);
  free(b.mem);
  free(b.ck);
  free(b.tk);
}

/* ================= S5-1 addition: executor insertion point (lm_h_forward_x) =================
   Two copies of the K12V8 variant. Copy 0 runs lm_h_forward, copy 1 runs lm_h_forward_x with
   an executor that executes each call on private copies of its output buffers (k_exec on a
   descriptor whose outputs point to scratch memory, then copies them back). A hook on both
   records every call (kid, prm, buffer shape and FNV-1a of the buffer contents after the call).
   Items per position: the call stream, the logits and the argmax are identical; the executor
   is called once per call. No random numbers are drawn. */
typedef struct {
  long n, cap;
  uint32_t *h; /* one hash per call */
} xrec_t;
static uint32_t xfnv(uint32_t h, const void *p, size_t n) {
  const uint8_t *b = (const uint8_t *)p;
  size_t i;
  for (i = 0; i < n; i++) h = (h ^ b[i]) * 16777619u;
  return h;
}
static void xrec_hook(void *user, int phase, const kcall_t *c) {
  xrec_t *r = (xrec_t *)user;
  uint32_t h = 2166136261u;
  int i;
  if (phase != 1) return;
  h = xfnv(h, &c->kid, sizeof(c->kid));
  h = xfnv(h, &c->np, sizeof(c->np));
  h = xfnv(h, &c->nb, sizeof(c->nb));
  h = xfnv(h, c->prm, sizeof(int32_t) * (size_t)c->np);
  for (i = 0; i < c->nb; i++) {
    h = xfnv(h, &c->b[i].esz, sizeof(int32_t) * 3);
    h = xfnv(h, c->b[i].p, (size_t)c->b[i].esz * (size_t)c->b[i].n);
  }
  if (r->n < r->cap) r->h[r->n] = h;
  r->n++;
}
typedef struct {
  long calls;
  uint8_t *scr;
  size_t scrn;
} xexec_t;
static int xexec_fn(void *user, const kcall_t *c) {
  xexec_t *x = (xexec_t *)user;
  kcall_t d = *c;
  size_t off = 0, sz;
  int i, rc;
  x->calls++;
  for (i = 0; i < d.nb; i++)
    if (d.b[i].out) {
      sz = (size_t)d.b[i].esz * (size_t)d.b[i].n;
      if (off + sz > x->scrn) return -100;
      d.b[i].p = x->scr + off;
      memset(d.b[i].p, 0xA5, sz);
      off += (sz + 7u) & ~(size_t)7u;
    }
  rc = k_exec(&d);
  for (i = 0; i < d.nb; i++)
    if (d.b[i].out) memcpy(c->b[i].p, d.b[i].p, (size_t)d.b[i].esz * (size_t)d.b[i].n);
  return rc;
}
static void t_fwdx(const char *ck, const char *tk, int steps, const char *tag) {
  bundle_t b;
  char nm[64];
  long n = 0, bad = 0, ncall = 0;
  int pos, cur = 1, k;
  xrec_t r[2];
  xexec_t x;
  k_hook_t hk[2];
  k_exec_t ex;
  if (bundle_load(&b, ck, tk, "K12V8,K12V8")) { check("fwdx load", 1, 1, "%g%g", 0, 0); return; }
  memset(&x, 0, sizeof(x));
  x.scrn = 4u * (size_t)(b.c.vocab_size + b.c.hidden_dim + b.c.dim + b.c.seq_len) + 4096u;
  x.scr = malloc(x.scrn);
  ex.fn = xexec_fn;
  ex.user = &x;
  for (k = 0; k < 2; k++) {
    r[k].cap = 4096;
    r[k].h = malloc(sizeof(uint32_t) * (size_t)r[k].cap);
    hk[k].fn = xrec_hook;
    hk[k].user = &r[k];
  }
  for (pos = 0; pos < steps && pos < b.c.seq_len; pos++) {
    const int32_t *l0, *l1;
    long c0 = x.calls, i;
    r[0].n = r[1].n = 0;
    l0 = lm_h_forward(&b.v[0].hs, &b.c, &b.v[0].hw, cur, pos, &hk[0]);
    l1 = lm_h_forward_x(&b.v[1].hs, &b.c, &b.v[1].hw, cur, pos, &hk[1], &ex);
    bad += !l0 || !l1;
    if (!l0 || !l1) break;
    bad += r[0].n != r[1].n || r[0].n > r[0].cap || x.calls - c0 != r[0].n;
    for (i = 0; i < r[0].n && i < r[0].cap && i < r[1].n; i++) bad += r[0].h[i] != r[1].h[i];
    bad += memcmp(l0, l1, 4 * (size_t)b.c.vocab_size) != 0;
    bad += b.v[0].hs.argmax[0] != b.v[1].hs.argmax[0];
    n += r[0].n + 2;
    ncall += r[0].n;
    cur = b.v[0].hs.argmax[0];
    if (cur == 1 || cur < 0) cur = 2; /* keep going past BOS */
  }
  sprintf(nm, "%s forward_x executor", tag);
  check(nm, n, bad, "calls %.0f positions %.0f", (double)ncall, (double)pos);
  for (k = 0; k < 2; k++) free(r[k].h);
  free(x.scr);
  free(b.mem);
  free(b.ck);
  free(b.tk);
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
  t_actq12();
  t_attn2();
  t_fwd2(cfg_s("ck1", ""), cfg_s("tk1", ""), 160, "m1");
  t_fwd2(cfg_s("ck2", ""), cfg_s("tk2", ""), 72, "m2");
  {
    const char *v1 = "HI,K8V12,K8V16,K12V8,K12V12,K12V16,K16V8,K16V12,HBw256,HBw128,HDw256,HDw128";
    const char *v2 = "HDw64,K12V12w256,K12V12w128,K8V12w256,K8V12w128,K12V8s";
    t_build2(cfg_s("ck1", ""), cfg_s("tk1", ""), v1, "m1");
    t_build2(cfg_s("ck1", ""), cfg_s("tk1", ""), v2, "m1");
    t_build2(cfg_s("ck2", ""), cfg_s("tk2", ""), v1, "m2");
    t_build2(cfg_s("ck2", ""), cfg_s("tk2", ""), v2, "m2");
  }
  t_dump(cfg_s("ck1", ""), cfg_s("tk1", ""), "K12V8", cfg_s("dumpf", "k.bin"), 1000000, "m1");
  t_dump(cfg_s("ck2", ""), cfg_s("tk2", ""), "K8V12", cfg_s("dumpf", "k.bin"), 24, "m2");
  t_stage(cfg_s("ck1", ""), cfg_s("tk1", ""), 40, cfg_s("dumpf", "k.bin"), "m1");
  t_stage(cfg_s("ck2", ""), cfg_s("tk2", ""), 6, cfg_s("dumpf", "k.bin"), "m2");
  t_bimg(cfg_s("ck1", ""), cfg_s("tk1", ""), "m1");
  t_rrec(cfg_s("ck1", ""), cfg_s("tk1", ""), "m1");
  t_rrec(cfg_s("ck2", ""), cfg_s("tk2", ""), "m2");
  t_dumpf(cfg_s("ck1", ""), cfg_s("tk1", ""), cfg_s("dumpf", "k.bin"), cfg_s("dumpf2", "k2.bin"), "m1");
  t_fwdx(cfg_s("ck1", ""), cfg_s("tk1", ""), 64, "m1");
  t_fwdx(cfg_s("ck2", ""), cfg_s("tk2", ""), 16, "m2");
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
