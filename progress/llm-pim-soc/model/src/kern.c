/*
 * Integer kernels of the H variant. No float type and no libm call may appear in
 * this file (checked by `make check-int`, which compiles it with -mgeneral-regs-only).
 */
#include "kern.h"

#define I32MAX 2147483647LL
#define I32MIN (-2147483647LL - 1)
#define I64MAX 9223372036854775807LL

static int bl64(uint64_t v) { return v ? 64 - __builtin_clzll(v) : 0; }

static int32_t sat32(int64_t x) {
  if (x > I32MAX) return (int32_t)I32MAX;
  if (x < I32MIN) return (int32_t)I32MIN;
  return (int32_t)x;
}

static int32_t clampq(int64_t x, int qmax) {
  if (x > qmax) return qmax;
  if (x < -qmax) return -qmax;
  return (int32_t)x;
}

int64_t k_rshr(int64_t x, int s) {
  if (s > 0) {
    if (s >= 62) return 0; /* callers keep |x| < 2^61 */
    return (x + ((int64_t)1 << (s - 1))) >> s;
  }
  if (s == 0) return x;
  if (s <= -62) return x > 0 ? I64MAX : (x < 0 ? -I64MAX : 0);
  {
    int64_t lim = I64MAX >> (-s);
    if (x > lim) return I64MAX;
    if (x < -lim) return -I64MAX;
    return x * ((int64_t)1 << (-s));
  }
}

static uint32_t uabs32(int32_t v) { return v < 0 ? (uint32_t)(-(int64_t)v) : (uint32_t)v; }

static int32_t ld(const void *p, int esz, int i) {
  return esz == 1 ? (int32_t)((const int8_t *)p)[i] : (int32_t)((const int16_t *)p)[i];
}

/* ---------------- activation quantizer ---------------- */
typedef struct {
  int mode, qmax, k, e;
  int64_t R;
  int32_t M;
} aq_t;

/* amax > 0 */
static void aq_setup(aq_t *a, uint32_t amax, int mode, int qmax) {
  int L = bl64(amax), lq = bl64((uint64_t)qmax);
  a->mode = mode;
  a->qmax = qmax;
  if (mode == ACT_POW2) {
    int k = L - lq;
    while (k_rshr((int64_t)amax, k) > qmax) k++;
    a->k = k;
    a->M = 1;
    a->e = -k; /* real = q * 2^k * 2^-f */
    a->R = 0;
  } else {
    int e = 16 + lq - L;                         /* -> M in (2^15, 2^17) */
    int64_t num = k_rshr((int64_t)amax, -e);      /* amax * 2^e */
    int64_t M = (num + qmax / 2) / qmax;          /* 17-bit mantissa of amax/qmax */
    a->M = (int32_t)M;
    a->R = (((int64_t)1 << 40) + M / 2) / M;      /* 2^40 / M, 25 bits */
    a->e = e;
    a->k = 0;
  }
}

static int32_t aq_one(const aq_t *a, int32_t v) {
  if (a->mode == ACT_POW2) return clampq(k_rshr(v, a->k), a->qmax);
  return clampq(k_rshr((int64_t)v * a->R, 40 - a->e), a->qmax);
}

static void aq_store(void *q, int i, int qmax, int32_t v) {
  if (qmax <= 127) ((int8_t *)q)[i] = (int8_t)v;
  else ((int16_t *)q)[i] = (int16_t)v;
}

void k_actq(const int32_t *v, int n, int f, int mode, int qmax, void *q, kscl_t *s) {
  uint32_t amax = 0;
  int i;
  aq_t a;
  for (i = 0; i < n; i++) {
    uint32_t u = uabs32(v[i]);
    if (u > amax) amax = u;
  }
  if (amax == 0) {
    for (i = 0; i < n; i++) aq_store(q, i, qmax, 0);
    s->m = 0;
    s->e = 0;
    return;
  }
  aq_setup(&a, amax, mode, qmax);
  for (i = 0; i < n; i++) aq_store(q, i, qmax, aq_one(&a, v[i]));
  s->m = a.M;
  s->e = a.e + f;
}

/* ---------------- gemv ---------------- */
void k_embed(const int8_t *q, const uint16_t *m, int n, int gs, int we, int fo, int32_t *y) {
  int i;
  for (i = 0; i < n; i++) y[i] = sat32(k_rshr((int64_t)q[i] * m[i / gs], we - fo));
}

void k_gemv(const int8_t *W, const uint16_t *wm, int we, int rows, int n, int gs,
            const int8_t *x, kscl_t xs, int fo, int32_t *y) {
  int ng = n / gs, sh = we + xs.e - fo, r, g, k;
  for (r = 0; r < rows; r++) {
    const int8_t *w = W + (long)r * n;
    int64_t S = 0;
    for (g = 0; g < ng; g++) {
      int32_t acc = 0; /* |acc| <= gs*127*127 < 2^31 for gs <= K_NMAX */
      for (k = 0; k < gs; k++) acc += (int32_t)w[g * gs + k] * (int32_t)x[g * gs + k];
      S += (int64_t)acc * wm[(long)r * ng + g]; /* |S| < n*2^14*2^16 <= 2^44 */
    }
    y[r] = sat32(k_rshr(S * xs.m, sh)); /* |S*m| < 2^61 */
  }
}

/* ---------------- scalar nonlinear helpers ---------------- */
uint32_t k_rsqrt(uint64_t u, int *re) {
  int L, t, i;
  uint64_t mn;
  uint32_t y;
  if (u == 0) u = 1;
  L = bl64(u);
  t = L - 32;
  if (t & 1) t += 1;                       /* even shift: mn in [2^30, 2^32) */
  mn = t >= 0 ? (u >> t) : (u << (-t));
  y = k_rsq_lut[(mn >> 26) - 16];          /* ~2^31/sqrt(mn), 6-bit seed */
  for (i = 0; i < 2; i++) {                /* Newton: y = y*(3 - mn*y^2)/2 */
    uint64_t z = (uint64_t)y * y;
    uint64_t p = (mn * (z >> 2)) >> 28;    /* mn*y^2 in Q32 */
    uint64_t three = (uint64_t)3 << 32;
    if (p >= three) p = three - 1;
    y = (uint32_t)(((uint64_t)y * (three - p)) >> 33);
  }
  *re = 31 + t / 2;
  return y;
}

uint32_t k_exp2neg(uint32_t u, int eb, const uint32_t *lut) {
  uint32_t I = u >> 16, f = u & 0xFFFFu;
  int sh = 16 - eb;
  uint32_t idx = f >> sh, fr = f & ((1u << sh) - 1u);
  uint32_t a = lut[idx], b = lut[idx + 1];
  uint32_t e = a - (((a - b) * fr + (1u << (sh - 1))) >> sh);
  if (I >= 32) return 0;
  return (uint32_t)k_rshr((int64_t)e, (int)I);
}

uint32_t k_sigmoid(int32_t a, int sb, const uint32_t *lut) {
  int64_t ua = a < 0 ? -(int64_t)a : (int64_t)a;
  uint32_t sp;
  if (ua >= ((int64_t)1 << 20)) {
    sp = lut[1u << sb];
  } else {
    int sh = 20 - sb;
    uint32_t idx = (uint32_t)(ua >> sh), fr = (uint32_t)(ua & ((1 << sh) - 1));
    uint32_t A = lut[idx], B = lut[idx + 1];
    sp = A + (((B - A) * fr + (1u << (sh - 1))) >> sh);
  }
  return a < 0 ? 65536u - sp : sp;
}

/* ---------------- rmsnorm ---------------- */
void k_rmsnorm(const int32_t *x, int n, int fx, const int16_t *g, int ge, int32_t epsc,
               int fy, int mode, int8_t *q, kscl_t *s) {
  uint32_t amax = 0, ymax = 0;
  uint64_t ss = 0, u;
  int i, k, re, sh;
  uint32_t rm;
  aq_t a;
  (void)fx; /* fx is folded into epsc */
  for (i = 0; i < n; i++) {
    uint32_t v = uabs32(x[i]);
    if (v > amax) amax = v;
  }
  k = bl64(amax) - 15;
  if (k < 0) k = 0;
  for (i = 0; i < n; i++) {
    int64_t xs = clampq(k_rshr(x[i], k), 32767);
    ss += (uint64_t)(xs * xs); /* <= n * 2^30 */
  }
  u = ss + (uint64_t)k_rshr(epsc, 2 * k);
  rm = k_rsqrt(u, &re);
  sh = ge + re - fy;
#define RMS_Y(i) sat32(k_rshr((int64_t)clampq(k_rshr(x[i], k), 32767) * g[i] * (int64_t)rm, sh))
  for (i = 0; i < n; i++) {
    uint32_t v = uabs32(RMS_Y(i));
    if (v > ymax) ymax = v;
  }
  if (ymax == 0) {
    for (i = 0; i < n; i++) q[i] = 0;
    s->m = 0;
    s->e = 0;
    return;
  }
  aq_setup(&a, ymax, mode, 127);
  for (i = 0; i < n; i++) q[i] = (int8_t)aq_one(&a, RMS_Y(i));
#undef RMS_Y
  s->m = a.M;
  s->e = a.e + fy;
}

/* ---------------- rope ---------------- */
void k_rope(const int32_t *v, int n, int hs, const int16_t *cs, int32_t *o) {
  int i;
  for (i = 0; i < n; i += 2) {
    int j = (i % hs) / 2;
    int64_t c = cs[2 * j], sn = cs[2 * j + 1];
    int64_t v0 = v[i], v1 = v[i + 1];
    o[i] = sat32(k_rshr(v0 * c - v1 * sn, 14));
    o[i + 1] = sat32(k_rshr(v0 * sn + v1 * c, 14));
  }
}

/* ---------------- attention: score, softmax, weighted V sum (one head) ---------------- */
#define LOG2E_Q15 47274 /* round(log2(e) * 2^15) */

/* ek, ev: element bytes of (q, K) and V; d0: right shift of the q.K dot product
   (keeps |dot >> d0| < 2^22 so that the product with c < 2^34 stays < 2^56) */
static void attn_core(int T, int hs, int ek, int d0, const void *q, kscl_t qs, const void *K,
                      const kscl_t *ks, int ev, const void *V, const kscl_t *vs, int eb,
                      const uint32_t *elut, int32_t *p, int32_t *o) {
  int t, i, emin = 0, have = 0;
  int32_t mx;
  uint64_t sum = 0, R;
  /* scores, Q(K_FS) */
  for (t = 0; t < T; t++) {
    int64_t dot = 0, c = (int64_t)qs.m * ks[t].m; /* c < 2^34 */
    const int base = t * hs;
    for (i = 0; i < hs; i++) dot += (int64_t)ld(q, ek, i) * ld(K, ek, base + i);
    /* |dot| < 2^21 (int8), 2^29 (12 bit, d0 = 7) or 2^37 (int16, d0 = 15) */
    p[t] = sat32(k_rshr(k_rshr(dot, d0) * c, qs.e + ks[t].e - d0 - K_FS));
  }
  /* softmax numerators: 2^((s - max) * log2 e), Q16 */
  mx = p[0];
  for (t = 1; t < T; t++)
    if (p[t] > mx) mx = p[t];
  for (t = 0; t < T; t++) {
    int64_t d = (int64_t)p[t] - mx; /* <= 0 */
    int64_t w;
    if (d < -((int64_t)1 << 30)) d = -((int64_t)1 << 30);
    w = k_rshr(d * LOG2E_Q15, 15 + K_FS - 16); /* Q16 exponent of 2, <= 0 */
    p[t] = (int32_t)k_exp2neg((uint32_t)(-w), eb, elut);
    sum += (uint32_t)p[t]; /* <= T * 2^16 */
  }
  /* normalize with one reciprocal per head; sum >= 2^16 (the max term is 1.0) */
  R = ((uint64_t)1 << 48) / sum;
  for (t = 0; t < T; t++) p[t] = (int32_t)(((uint64_t)p[t] * R + ((uint64_t)1 << 31)) >> 32);
  /* weighted sum of V; per-t scale aligned to the coarsest exponent, with guard bits
     G so that the aligned weight keeps about 33 bits (G = 16 for pow2 scales) */
  {
    int32_t mmax = 0;
    int G;
    for (t = 0; t < T; t++) {
      if (vs[t].m == 0) continue;
      if (!have || vs[t].e < emin) emin = vs[t].e;
      if (vs[t].m > mmax) mmax = vs[t].m;
      have = 1;
    }
    for (i = 0; i < hs; i++) o[i] = 0;
    if (!have) return;
    G = 17 - bl64((uint64_t)mmax);
    {
      int64_t acc[K_HSMAX];
      for (i = 0; i < hs; i++) acc[i] = 0;
      for (t = 0; t < T; t++) {
        int64_t w;
        if (vs[t].m == 0) continue;
        w = k_rshr((int64_t)p[t] * vs[t].m, vs[t].e - emin - G); /* <= 2^33 */
        for (i = 0; i < hs; i++) acc[i] += w * ld(V, ev, t * hs + i); /* < 2^60, T <= 4096 */
      }
      for (i = 0; i < hs; i++) o[i] = sat32(k_rshr(acc[i], 16 + emin + G - K_FX));
    }
  }
}

void k_attn(int T, int hs, int esz, const void *q, kscl_t qs, const void *K, const kscl_t *ks,
            const void *V, const kscl_t *vs, int eb, const uint32_t *elut, int32_t *p, int32_t *o) {
  attn_core(T, hs, esz, esz == 2 ? 15 : 0, q, qs, K, ks, esz, V, vs, eb, elut, p, o);
}

int k_attn_d0(int kb) { return kb > 8 ? 2 * kb - 17 : 0; }

void k_attn2(int T, int hs, int kb, int vb, const void *q, kscl_t qs, const void *K,
             const kscl_t *ks, const void *V, const kscl_t *vs, int eb, const uint32_t *elut,
             int32_t *p, int32_t *o) {
  attn_core(T, hs, kb > 8 ? 2 : 1, k_attn_d0(kb), q, qs, K, ks, vb > 8 ? 2 : 1, V, vs, eb, elut,
            p, o);
}

/* ---------------- swiglu ---------------- */
static int32_t swiglu_one(int32_t a, int32_t b, int sb, const uint32_t *slut) {
  int64_t silu = k_rshr((int64_t)a * k_sigmoid(a, sb, slut), 16);
  return sat32(k_rshr(silu * b, 16));
}

void k_swiglu(const int32_t *h1, const int32_t *h3, int n, int sb, const uint32_t *slut,
              int mode, int8_t *q, kscl_t *s) {
  uint32_t amax = 0;
  int i;
  aq_t a;
  for (i = 0; i < n; i++) {
    uint32_t v = uabs32(swiglu_one(h1[i], h3[i], sb, slut));
    if (v > amax) amax = v;
  }
  if (amax == 0) {
    for (i = 0; i < n; i++) q[i] = 0;
    s->m = 0;
    s->e = 0;
    return;
  }
  aq_setup(&a, amax, mode, 127);
  for (i = 0; i < n; i++) q[i] = (int8_t)aq_one(&a, swiglu_one(h1[i], h3[i], sb, slut));
  s->m = a.M;
  s->e = a.e + K_FX;
}

/* ---------------- elementwise and selection ---------------- */
void k_add(const int32_t *a, const int32_t *b, int n, int32_t *o) {
  int i;
  for (i = 0; i < n; i++) o[i] = sat32((int64_t)a[i] + b[i]);
}

int k_argmax(const int32_t *v, int n) {
  int i, mi = 0;
  for (i = 1; i < n; i++)
    if (v[i] > v[mi]) mi = i;
  return mi;
}

void k_topk(const int32_t *v, int n, int k, int32_t *idx, int32_t *val) {
  int i, j, c = 0;
  for (i = 0; i < n; i++) {
    if (c == k && v[i] <= val[k - 1]) continue;
    j = c < k ? c++ : k - 1;
    while (j > 0 && v[i] > val[j - 1]) {
      val[j] = val[j - 1];
      idx[j] = idx[j - 1];
      j--;
    }
    val[j] = v[i];
    idx[j] = i;
  }
}

/* ---------------- descriptor dispatch ---------------- */
static const char *knames[K_NKERN] = {"?",     "embed", "gemv", "rmsnorm", "actq", "rope",
                                      "attn",  "swiglu", "add", "argmax",  "topk",
                                      "attn2"};
const char *k_name(int kid) { return (kid > 0 && kid < K_NKERN) ? knames[kid] : "?"; }

#define NEED(cond) \
  do {             \
    if (!(cond)) return -2; \
  } while (0)
#define BUF(i, e, cnt) NEED(c->nb > (i) && c->b[i].esz == (e) && c->b[i].n == (cnt))

int k_exec(const kcall_t *c) {
  const int32_t *P = c->prm;
  switch (c->kid) {
  case K_EMBED:
    NEED(c->np == 4 && c->nb == 3 && P[0] > 0 && P[1] > 0 && P[0] % P[1] == 0);
    BUF(0, 1, P[0]); BUF(1, 2, P[0] / P[1]); BUF(2, 4, P[0]);
    k_embed(c->b[0].p, c->b[1].p, P[0], P[1], P[2], P[3], c->b[2].p);
    return 0;
  case K_GEMV: {
    kscl_t xs;
    NEED(c->np == 7 && c->nb == 4 && P[0] > 0 && P[1] > 0 && P[1] <= K_NMAX && P[2] > 0 &&
         P[1] % P[2] == 0 && P[4] >= 0 && P[4] < (1 << 17));
    BUF(0, 1, P[0] * P[1]); BUF(1, 2, P[0] * (P[1] / P[2])); BUF(2, 1, P[1]); BUF(3, 4, P[0]);
    xs.m = P[4];
    xs.e = P[5];
    k_gemv(c->b[0].p, c->b[1].p, P[3], P[0], P[1], P[2], c->b[2].p, xs, P[6], c->b[3].p);
    return 0;
  }
  case K_RMSNORM:
    NEED(c->np == 6 && c->nb == 4 && P[0] > 0 && P[0] <= K_NMAX && P[3] >= 0);
    BUF(0, 4, P[0]); BUF(1, 2, P[0]); BUF(2, 1, P[0]); BUF(3, 4, 2);
    k_rmsnorm(c->b[0].p, P[0], P[1], c->b[1].p, P[2], P[3], P[4], P[5], c->b[2].p,
              (kscl_t *)c->b[3].p);
    return 0;
  case K_ACTQ:
    NEED(c->np == 4 && c->nb == 3 && P[0] > 0 && (P[3] == 127 || P[3] == 2047 || P[3] == 32767));
    BUF(0, 4, P[0]); BUF(1, P[3] == 127 ? 1 : 2, P[0]); BUF(2, 4, 2);
    k_actq(c->b[0].p, P[0], P[1], P[2], P[3], c->b[1].p, (kscl_t *)c->b[2].p);
    return 0;
  case K_ROPE:
    NEED(c->np == 2 && c->nb == 3 && P[1] > 0 && P[1] % 2 == 0 && P[0] % P[1] == 0);
    BUF(0, 4, P[0]); BUF(1, 2, P[1]); BUF(2, 4, P[0]);
    k_rope(c->b[0].p, P[0], P[1], c->b[1].p, c->b[2].p);
    return 0;
  case K_ATTN: {
    kscl_t qs;
    int T = P[0], hs = P[1], esz = P[2];
    NEED(c->np == 6 && c->nb == 8 && T > 0 && T <= K_TMAX && hs > 0 && hs <= K_HSMAX &&
         (esz == 1 || esz == 2) && P[5] >= 4 && P[5] <= 8);
    BUF(0, esz, hs); BUF(1, esz, T * hs); BUF(2, 4, 2 * T); BUF(3, esz, T * hs);
    BUF(4, 4, 2 * T); BUF(5, 4, (1 << P[5]) + 1); BUF(6, 4, T); BUF(7, 4, hs);
    qs.m = P[3];
    qs.e = P[4];
    k_attn(T, hs, esz, c->b[0].p, qs, c->b[1].p, (const kscl_t *)c->b[2].p, c->b[3].p,
           (const kscl_t *)c->b[4].p, P[5], c->b[5].p, c->b[6].p, c->b[7].p);
    return 0;
  }
  case K_ATTN2: {
    kscl_t qs;
    int T = P[0], hs = P[1], kb = P[2], vb = P[3], ek = kb > 8 ? 2 : 1, ev = vb > 8 ? 2 : 1;
    NEED(c->np == 7 && c->nb == 8 && T > 0 && T <= K_TMAX && hs > 0 && hs <= K_HSMAX &&
         (kb == 8 || kb == 12 || kb == 16) && (vb == 8 || vb == 12 || vb == 16) && P[6] >= 4 &&
         P[6] <= 8);
    BUF(0, ek, hs); BUF(1, ek, T * hs); BUF(2, 4, 2 * T); BUF(3, ev, T * hs);
    BUF(4, 4, 2 * T); BUF(5, 4, (1 << P[6]) + 1); BUF(6, 4, T); BUF(7, 4, hs);
    qs.m = P[4];
    qs.e = P[5];
    k_attn2(T, hs, kb, vb, c->b[0].p, qs, c->b[1].p, (const kscl_t *)c->b[2].p, c->b[3].p,
            (const kscl_t *)c->b[4].p, P[6], c->b[5].p, c->b[6].p, c->b[7].p);
    return 0;
  }
  case K_SWIGLU:
    NEED(c->np == 3 && c->nb == 5 && P[0] > 0 && P[1] >= 4 && P[1] <= 8);
    BUF(0, 4, P[0]); BUF(1, 4, P[0]); BUF(2, 4, (1 << P[1]) + 1); BUF(3, 1, P[0]); BUF(4, 4, 2);
    k_swiglu(c->b[0].p, c->b[1].p, P[0], P[1], c->b[2].p, P[2], c->b[3].p, (kscl_t *)c->b[4].p);
    return 0;
  case K_ADD:
    NEED(c->np == 1 && c->nb == 3 && P[0] > 0);
    BUF(0, 4, P[0]); BUF(1, 4, P[0]); BUF(2, 4, P[0]);
    k_add(c->b[0].p, c->b[1].p, P[0], c->b[2].p);
    return 0;
  case K_ARGMAX:
    NEED(c->np == 1 && c->nb == 2 && P[0] > 0);
    BUF(0, 4, P[0]); BUF(1, 4, 1);
    *(int32_t *)c->b[1].p = k_argmax(c->b[0].p, P[0]);
    return 0;
  case K_TOPK:
    NEED(c->np == 2 && c->nb == 3 && P[0] > 0 && P[1] > 0 && P[1] <= P[0]);
    BUF(0, 4, P[0]); BUF(1, 4, P[1]); BUF(2, 4, P[1]);
    k_topk(c->b[0].p, P[0], P[1], c->b[1].p, c->b[2].p);
    return 0;
  default:
    return -1;
  }
}
