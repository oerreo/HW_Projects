/*
 * H variant preparation (init only, runs once on the host): integer weights with
 * 16-bit scale mantissas, rmsnorm gains, RoPE table. Float is allowed here; it is
 * not part of the inference path. Only IEEE-exact operations (+ - * / sqrt) feed
 * the integer results, except the RoPE table (cos/sin), whose ROM image for the
 * hardware is taken from the PC build.
 */
#include <math.h>
#include "llm.h"

static long rnd(double v) { return (long)(v >= 0 ? v + 0.5 : v - 0.5); }

static void hm_take(lm_hm_t *m, int rows, int n, int gst, lm_arena_t *a) {
  m->rows = rows;
  m->n = n;
  m->gs = lm_group(n, gst);
  m->q = lm_take(a, (size_t)rows * n);
  m->m = lm_take(a, sizeof(uint16_t) * (size_t)rows * (n / m->gs));
}

/* w is rows x n; values are multiplied by mult before quantization */
static void hm_fill(lm_hm_t *m, const float *w, double mult) {
  int ng = m->n / m->gs, r, g, k, we = 0;
  double smax = 0.0, p2 = 1.0;
  size_t ngr = (size_t)m->rows * ng, i;
  for (i = 0; i < ngr; i++) {
    const float *src = w + (i / ng) * m->n + (i % ng) * m->gs;
    double mx = 0.0;
    for (k = 0; k < m->gs; k++) {
      double v = fabs((double)src[k] * mult);
      if (v > mx) mx = v;
    }
    if (mx / 127.0 > smax) smax = mx / 127.0;
  }
  if (smax > 0.0) {
    while (smax * p2 < 32768.0) { p2 *= 2.0; we++; }
    while (smax * p2 >= 65536.0) { p2 *= 0.5; we--; }
  }
  m->we = we;
  for (r = 0; r < m->rows; r++)
    for (g = 0; g < ng; g++) {
      const float *src = w + (size_t)r * m->n + (size_t)g * m->gs;
      int8_t *dst = m->q + (size_t)r * m->n + (size_t)g * m->gs;
      double mx = 0.0, t, sc;
      long mi;
      for (k = 0; k < m->gs; k++) {
        double v = fabs((double)src[k] * mult);
        if (v > mx) mx = v;
      }
      t = mx / 127.0 * p2;
      mi = (long)t;
      if ((double)mi < t) mi++; /* ceil: no element exceeds 127 */
      if (mi < 1) mi = 1;
      if (mi > 65535) mi = 65535;
      m->m[(size_t)r * ng + g] = (uint16_t)mi;
      sc = (double)mi / p2;
      for (k = 0; k < m->gs; k++) {
        long q = rnd((double)src[k] * mult / sc);
        if (q > 127) q = 127;
        if (q < -127) q = -127;
        dst[k] = (int8_t)q;
      }
    }
}

static void hg_fill(lm_hg_t *h, const float *g, int n) {
  double sn = sqrt((double)n), mx = 0.0, p2 = 1.0;
  int i, ge = 0;
  for (i = 0; i < n; i++)
    if (fabs(g[i] * sn) > mx) mx = fabs(g[i] * sn);
  if (mx > 0.0) {
    while (rnd(mx * p2 * 2.0) <= 32767) { p2 *= 2.0; ge++; }
    while (rnd(mx * p2) > 32767) { p2 *= 0.5; ge--; }
  }
  h->ge = ge;
  for (i = 0; i < n; i++) h->g[i] = (int16_t)rnd((double)g[i] * sn * p2);
}

void lm_h_build(lm_hw_t *w, const lm_cfg_t *c, const lm_fw_t *fw, const lm_hfmt_t *f, lm_arena_t *a) {
  int L = c->n_layers, D = c->dim, H = c->hidden_dim, hs = D / c->n_heads;
  int kv = D * c->n_kv_heads / c->n_heads, l, g = f->wgs;
  w->f = *f;
  w->wq = lm_take(a, sizeof(lm_hm_t) * L);
  w->wk = lm_take(a, sizeof(lm_hm_t) * L);
  w->wv = lm_take(a, sizeof(lm_hm_t) * L);
  w->wo = lm_take(a, sizeof(lm_hm_t) * L);
  w->w1 = lm_take(a, sizeof(lm_hm_t) * L);
  w->w2 = lm_take(a, sizeof(lm_hm_t) * L);
  w->w3 = lm_take(a, sizeof(lm_hm_t) * L);
  w->ra = lm_take(a, sizeof(lm_hg_t) * L);
  w->rf = lm_take(a, sizeof(lm_hg_t) * L);
  w->rope = lm_take(a, sizeof(int16_t) * (size_t)c->seq_len * hs);
  {
    lm_hm_t d, *pq, *pk, *pv, *po, *p1, *p2, *p3;
    lm_hg_t dg, *pa, *pf;
    for (l = 0; l < L; l++) {
      pq = a->base ? &w->wq[l] : &d; pk = a->base ? &w->wk[l] : &d;
      pv = a->base ? &w->wv[l] : &d; po = a->base ? &w->wo[l] : &d;
      p1 = a->base ? &w->w1[l] : &d; p2 = a->base ? &w->w2[l] : &d;
      p3 = a->base ? &w->w3[l] : &d;
      pa = a->base ? &w->ra[l] : &dg; pf = a->base ? &w->rf[l] : &dg;
      hm_take(pq, D, D, g, a);
      hm_take(pk, kv, D, g, a);
      hm_take(pv, kv, D, g, a);
      hm_take(po, D, D, g, a);
      hm_take(p1, H, D, g, a);
      hm_take(p2, D, H, g, a);
      hm_take(p3, H, D, g, a);
      pa->g = lm_take(a, sizeof(int16_t) * D);
      pf->g = lm_take(a, sizeof(int16_t) * D);
    }
  }
  hm_take(&w->cls, c->vocab_size, D, g, a);
  w->rfin.g = lm_take(a, sizeof(int16_t) * D);
  w->elut = k_exp_lut(f->exp_bits);
  w->slut = k_sig_lut(f->sig_bits);
  w->epsc = (int32_t)rnd((double)D * (double)1e-5f * 4294967296.0);
  if (!a->base || a->fail) return;
  if (!fw->shared) { /* the H embedding reuses the classifier storage */
    a->fail = 1;
    return;
  }
  for (l = 0; l < L; l++) {
    hm_fill(&w->wq[l], fw->wq + (size_t)l * D * D, 1.0 / sqrt((double)hs)); /* folds 1/sqrt(hs) */
    hm_fill(&w->wk[l], fw->wk + (size_t)l * D * kv, 1.0);
    hm_fill(&w->wv[l], fw->wv + (size_t)l * D * kv, 1.0);
    hm_fill(&w->wo[l], fw->wo + (size_t)l * D * D, 1.0);
    hm_fill(&w->w1[l], fw->w1 + (size_t)l * D * H, 1.0);
    hm_fill(&w->w2[l], fw->w2 + (size_t)l * D * H, 1.0);
    hm_fill(&w->w3[l], fw->w3 + (size_t)l * D * H, 1.0);
    hg_fill(&w->ra[l], fw->rms_att + (size_t)l * D, D);
    hg_fill(&w->rf[l], fw->rms_ffn + (size_t)l * D, D);
  }
  hm_fill(&w->cls, fw->wcls, 1.0);
  hg_fill(&w->rfin, fw->rms_final, D);
  {
    int pos, j;
    for (pos = 0; pos < c->seq_len; pos++)
      for (j = 0; j < hs / 2; j++) {
        float freq = 1.0f / powf(10000.0f, (2 * j) / (float)hs);
        float val = pos * freq;
        w->rope[(size_t)pos * hs + 2 * j] = (int16_t)rnd(cos((double)val) * 16384.0);
        w->rope[(size_t)pos * hs + 2 * j + 1] = (int16_t)rnd(sin((double)val) * 16384.0);
      }
  }
}
