/*
 * Integer kernels of the H variant. No float type and no libm call may appear in
 * this file (checked by `make check-int`, which compiles it with -mgeneral-regs-only).
 */
#include <stddef.h>
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

int32_t k_sat32(int64_t x) { return sat32(x); }

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
/* amax > 0 */
void k_aq_setup(k_aq_t *a, uint32_t amax, int mode, int qmax) {
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

int32_t k_aq_one(const k_aq_t *a, int32_t v) {
  if (a->mode == ACT_POW2) return clampq(k_rshr(v, a->k), a->qmax);
  return clampq(k_rshr((int64_t)v * a->R, 40 - a->e), a->qmax);
}

static void aq_store(void *q, int i, int qmax, int32_t v) {
  if (qmax <= 127) ((int8_t *)q)[i] = (int8_t)v;
  else ((int16_t *)q)[i] = (int16_t)v;
}

void k_actq(const int32_t *v, int n, int f, int mode, int qmax, void *q, kscl_t *s) {
  k_actq_st(v, n, f, mode, qmax, q, s, NULL);
}

void k_actq_st(const int32_t *v, int n, int f, int mode, int qmax, void *q, kscl_t *s,
               k_actq_st_t *st) {
  uint32_t amax = 0;
  int i;
  k_aq_t a;
  for (i = 0; i < n; i++) {
    uint32_t u = uabs32(v[i]);
    if (u > amax) amax = u;
  }
  if (st) st->amax = amax;
  if (amax == 0) {
    for (i = 0; i < n; i++) aq_store(q, i, qmax, 0);
    s->m = 0;
    s->e = 0;
    return;
  }
  k_aq_setup(&a, amax, mode, qmax);
  if (st) st->aq = a;
  for (i = 0; i < n; i++) aq_store(q, i, qmax, k_aq_one(&a, v[i]));
  s->m = a.M;
  s->e = a.e + f;
}

/* ---------------- gemv ---------------- */
void k_embed(const int8_t *q, const uint16_t *m, int n, int gs, int we, int fo, int32_t *y) {
  int i;
  for (i = 0; i < n; i++) y[i] = sat32(k_rshr((int64_t)q[i] * m[i / gs], we - fo));
}

/* |acc| <= n*127*127 < 2^31 for n <= K_NMAX */
int32_t k_dot8(const int8_t *a, const int8_t *b, int n) {
  int32_t acc = 0;
  int k;
  for (k = 0; k < n; k++) acc += (int32_t)a[k] * (int32_t)b[k];
  return acc;
}

/* |S| < n*2^14*2^16 <= 2^44 */
int64_t k_gemv_row(const int8_t *w, const uint16_t *wm, const int8_t *x, int n, int gs) {
  int ng = n / gs, g;
  int64_t S = 0;
  for (g = 0; g < ng; g++) S += (int64_t)k_dot8(w + g * gs, x + g * gs, gs) * wm[g];
  return S;
}

/* |S*m| < 2^61 */
int32_t k_gemv_out(int64_t S, int32_t xm, int sh) { return sat32(k_rshr(S * xm, sh)); }

void k_gemv_st(const int8_t *W, const uint16_t *wm, int we, int rows, int n, int gs,
               const int8_t *x, kscl_t xs, int fo, int32_t *y, int64_t *Sv) {
  int ng = n / gs, sh = we + xs.e - fo, r;
  for (r = 0; r < rows; r++) {
    int64_t S = k_gemv_row(W + (long)r * n, wm + (long)r * ng, x, n, gs);
    if (Sv) Sv[r] = S;
    y[r] = k_gemv_out(S, xs.m, sh);
  }
}

void k_gemv(const int8_t *W, const uint16_t *wm, int we, int rows, int n, int gs,
            const int8_t *x, kscl_t xs, int fo, int32_t *y) {
  k_gemv_st(W, wm, we, rows, n, gs, x, xs, fo, y, NULL);
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
  k_rmsnorm_st(x, n, fx, g, ge, epsc, fy, mode, q, s, NULL);
}

void k_rmsnorm_st(const int32_t *x, int n, int fx, const int16_t *g, int ge, int32_t epsc,
                  int fy, int mode, int8_t *q, kscl_t *s, k_rms_st_t *st) {
  uint32_t amax = 0, ymax = 0;
  uint64_t ss = 0, u;
  int i, k, re, sh;
  uint32_t rm;
  k_aq_t a;
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
    int32_t yv = RMS_Y(i);
    uint32_t v = uabs32(yv);
    if (st && st->y) st->y[i] = yv;
    if (v > ymax) ymax = v;
  }
  if (st) {
    st->amax = amax;
    st->ymax = ymax;
    st->k = k;
    st->re = re;
    st->sh = sh;
    st->ss = ss;
    st->u = u;
    st->rm = rm;
  }
  if (ymax == 0) {
    for (i = 0; i < n; i++) q[i] = 0;
    s->m = 0;
    s->e = 0;
    return;
  }
  k_aq_setup(&a, ymax, mode, 127);
  if (st) st->aq = a;
  for (i = 0; i < n; i++) q[i] = (int8_t)k_aq_one(&a, RMS_Y(i));
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

/* stage functions of attn_core (S4-6, golden of attn_score, exp_unit, attn_vacc) */
/* score of one position: sat32(rshr(rshr(dot, d0) * qm * km, qe + ke - d0 - K_FS)) */
int32_t k_attn_score(int64_t dot, int32_t qm, int32_t km, int qe, int ke, int d0) {
  int64_t c = (int64_t)qm * km; /* c < 2^34 */
  /* |dot| < 2^21 (int8), 2^29 (12 bit, d0 = 7) or 2^37 (int16, d0 = 15) */
  return sat32(k_rshr(k_rshr(dot, d0) * c, qe + ke - d0 - K_FS));
}

/* softmax numerator of one score: 2^((s - mx) * log2 e), Q16 */
uint32_t k_attn_exp(int32_t s, int32_t mx, int eb, const uint32_t *elut) {
  int64_t d = (int64_t)s - mx; /* <= 0 */
  int64_t w;
  if (d < -((int64_t)1 << 30)) d = -((int64_t)1 << 30);
  w = k_rshr(d * LOG2E_Q15, 15 + K_FS - 16); /* Q16 exponent of 2, <= 0 */
  return k_exp2neg((uint32_t)(-w), eb, elut);
}

/* normalized probability: (e * R + 2^31) >> 32 */
int32_t k_attn_pn(uint32_t e, uint64_t R) {
  return (int32_t)(((uint64_t)e * R + ((uint64_t)1 << 31)) >> 32);
}

/* aligned V weight of one position with vs.m != 0 */
int64_t k_attn_w(int32_t p, int32_t vm, int ve, int emin, int G) {
  return k_rshr((int64_t)p * vm, ve - emin - G); /* <= 2^33 */
}

/* output element from its V accumulator */
int32_t k_attn_out(int64_t acc, int emin, int G) { return sat32(k_rshr(acc, 16 + emin + G - K_FX)); }

/* ek, ev: element bytes of (q, K) and V; d0: right shift of the q.K dot product
   (keeps |dot >> d0| < 2^22 so that the product with c < 2^34 stays < 2^56) */
static void attn_core(int T, int hs, int ek, int d0, const void *q, kscl_t qs, const void *K,
                      const kscl_t *ks, int ev, const void *V, const kscl_t *vs, int eb,
                      const uint32_t *elut, int32_t *p, int32_t *o, k_attn_st_t *st) {
  int t, i, emin = 0, have = 0;
  int32_t mx;
  uint64_t sum = 0, R;
  /* scores, Q(K_FS) */
  for (t = 0; t < T; t++) {
    int64_t dot = 0;
    const int base = t * hs;
    for (i = 0; i < hs; i++) dot += (int64_t)ld(q, ek, i) * ld(K, ek, base + i);
    p[t] = k_attn_score(dot, qs.m, ks[t].m, qs.e, ks[t].e, d0);
    if (st && st->dot) st->dot[t] = dot;
    if (st && st->s) st->s[t] = p[t];
  }
  /* softmax numerators: 2^((s - max) * log2 e), Q16 */
  mx = p[0];
  for (t = 1; t < T; t++)
    if (p[t] > mx) mx = p[t];
  for (t = 0; t < T; t++) {
    p[t] = (int32_t)k_attn_exp(p[t], mx, eb, elut);
    sum += (uint32_t)p[t]; /* <= T * 2^16 */
    if (st && st->e) st->e[t] = (uint32_t)p[t];
  }
  /* normalize with one reciprocal per head; sum >= 2^16 (the max term is 1.0) */
  R = ((uint64_t)1 << 48) / sum;
  if (st) {
    st->d0 = d0;
    st->mx = mx;
    st->sum = sum;
    st->R = R;
  }
  for (t = 0; t < T; t++) p[t] = k_attn_pn((uint32_t)p[t], R);
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
    if (st) {
      st->have = have;
      st->mmax = mmax;
      st->emin = emin;
      st->G = 0;
      if (st->w)
        for (t = 0; t < T; t++) st->w[t] = 0;
      if (st->acc)
        for (i = 0; i < hs; i++) st->acc[i] = 0;
    }
    if (!have) return;
    G = 17 - bl64((uint64_t)mmax);
    if (st) st->G = G;
    {
      int64_t acc[K_HSMAX];
      for (i = 0; i < hs; i++) acc[i] = 0;
      for (t = 0; t < T; t++) {
        int64_t w;
        if (vs[t].m == 0) continue;
        w = k_attn_w(p[t], vs[t].m, vs[t].e, emin, G);
        if (st && st->w) st->w[t] = w;
        for (i = 0; i < hs; i++) acc[i] += w * ld(V, ev, t * hs + i); /* < 2^60, T <= 4096 */
      }
      for (i = 0; i < hs; i++) o[i] = k_attn_out(acc[i], emin, G);
      if (st && st->acc)
        for (i = 0; i < hs; i++) st->acc[i] = acc[i];
    }
  }
}

void k_attn(int T, int hs, int esz, const void *q, kscl_t qs, const void *K, const kscl_t *ks,
            const void *V, const kscl_t *vs, int eb, const uint32_t *elut, int32_t *p, int32_t *o) {
  attn_core(T, hs, esz, esz == 2 ? 15 : 0, q, qs, K, ks, esz, V, vs, eb, elut, p, o, NULL);
}

int k_attn_d0(int kb) { return kb > 8 ? 2 * kb - 17 : 0; }

void k_attn2(int T, int hs, int kb, int vb, const void *q, kscl_t qs, const void *K,
             const kscl_t *ks, const void *V, const kscl_t *vs, int eb, const uint32_t *elut,
             int32_t *p, int32_t *o) {
  k_attn2_st(T, hs, kb, vb, q, qs, K, ks, V, vs, eb, elut, p, o, NULL);
}

void k_attn2_st(int T, int hs, int kb, int vb, const void *q, kscl_t qs, const void *K,
                const kscl_t *ks, const void *V, const kscl_t *vs, int eb, const uint32_t *elut,
                int32_t *p, int32_t *o, k_attn_st_t *st) {
  attn_core(T, hs, kb > 8 ? 2 : 1, k_attn_d0(kb), q, qs, K, ks, vb > 8 ? 2 : 1, V, vs, eb, elut,
            p, o, st);
}

/* ---------------- swiglu ---------------- */
static int32_t swiglu_one(int32_t a, int32_t b, int sb, const uint32_t *slut) {
  int64_t silu = k_rshr((int64_t)a * k_sigmoid(a, sb, slut), 16);
  return sat32(k_rshr(silu * b, 16));
}

void k_swiglu(const int32_t *h1, const int32_t *h3, int n, int sb, const uint32_t *slut,
              int mode, int8_t *q, kscl_t *s) {
  k_swiglu_st(h1, h3, n, sb, slut, mode, q, s, NULL);
}

void k_swiglu_st(const int32_t *h1, const int32_t *h3, int n, int sb, const uint32_t *slut,
                 int mode, int8_t *q, kscl_t *s, k_swi_st_t *st) {
  uint32_t amax = 0;
  int i;
  k_aq_t a;
  for (i = 0; i < n; i++) {
    int32_t gv = swiglu_one(h1[i], h3[i], sb, slut);
    uint32_t v = uabs32(gv);
    if (st && st->g) st->g[i] = gv;
    if (v > amax) amax = v;
  }
  if (st) st->amax = amax;
  if (amax == 0) {
    for (i = 0; i < n; i++) q[i] = 0;
    s->m = 0;
    s->e = 0;
    return;
  }
  k_aq_setup(&a, amax, mode, 127);
  if (st) st->aq = a;
  for (i = 0; i < n; i++) q[i] = (int8_t)k_aq_one(&a, swiglu_one(h1[i], h3[i], sb, slut));
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

int k_exec(const kcall_t *c) { return k_exec_st(c, NULL); }

int k_exec_st(const kcall_t *c, void *st) {
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
    k_gemv_st(c->b[0].p, c->b[1].p, P[3], P[0], P[1], P[2], c->b[2].p, xs, P[6], c->b[3].p,
              (int64_t *)st);
    return 0;
  }
  case K_RMSNORM:
    NEED(c->np == 6 && c->nb == 4 && P[0] > 0 && P[0] <= K_NMAX && P[3] >= 0);
    BUF(0, 4, P[0]); BUF(1, 2, P[0]); BUF(2, 1, P[0]); BUF(3, 4, 2);
    k_rmsnorm_st(c->b[0].p, P[0], P[1], c->b[1].p, P[2], P[3], P[4], P[5], c->b[2].p,
                 (kscl_t *)c->b[3].p, (k_rms_st_t *)st);
    return 0;
  case K_ACTQ:
    NEED(c->np == 4 && c->nb == 3 && P[0] > 0 && (P[3] == 127 || P[3] == 2047 || P[3] == 32767));
    BUF(0, 4, P[0]); BUF(1, P[3] == 127 ? 1 : 2, P[0]); BUF(2, 4, 2);
    k_actq_st(c->b[0].p, P[0], P[1], P[2], P[3], c->b[1].p, (kscl_t *)c->b[2].p,
              (k_actq_st_t *)st);
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
    k_attn2_st(T, hs, kb, vb, c->b[0].p, qs, c->b[1].p, (const kscl_t *)c->b[2].p, c->b[3].p,
               (const kscl_t *)c->b[4].p, P[6], c->b[5].p, c->b[6].p, c->b[7].p,
               (k_attn_st_t *)st);
    return 0;
  }
  case K_SWIGLU:
    NEED(c->np == 3 && c->nb == 5 && P[0] > 0 && P[1] >= 4 && P[1] <= 8);
    BUF(0, 4, P[0]); BUF(1, 4, P[0]); BUF(2, 4, (1 << P[1]) + 1); BUF(3, 1, P[0]); BUF(4, 4, 2);
    k_swiglu_st(c->b[0].p, c->b[1].p, P[0], P[1], c->b[2].p, P[2], c->b[3].p, (kscl_t *)c->b[4].p,
                (k_swi_st_t *)st);
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
