/*
 * Q variant: int8 symmetric weights and activations with one float scale per
 * (row, group), int32 group accumulation, float combination of group sums.
 * Nonlinear functions stay float32 as in F. Groups never cross a row: the group
 * size is a divisor of the row length (lm_group).
 *
 * Accumulator bound: one group sum is at most gs * 127 * 127; with gs <= K_NMAX
 * (16384) that is 264,257,536 < 2^31 - 1, checked in lm_q_build.
 */
#include <math.h>
#include <string.h>
#include "llm.h"

static int qm_take(lm_qm_t *m, int rows, int n, int gst, lm_arena_t *a) {
  m->rows = rows;
  m->n = n;
  m->gs = lm_group(n, gst);
  m->q = lm_take(a, (size_t)rows * n);
  m->s = lm_take(a, sizeof(float) * (size_t)rows * (n / m->gs));
  return m->gs <= K_NMAX && (long)m->gs * 127 * 127 <= 2147483647L;
}

static void qm_fill(lm_qm_t *m, const float *w) {
  int r, g, k, ng = m->n / m->gs;
  for (r = 0; r < m->rows; r++)
    for (g = 0; g < ng; g++) {
      const float *src = w + (size_t)r * m->n + (size_t)g * m->gs;
      int8_t *dst = m->q + (size_t)r * m->n + (size_t)g * m->gs;
      float mx = 0.0f, s;
      for (k = 0; k < m->gs; k++)
        if (fabsf(src[k]) > mx) mx = fabsf(src[k]);
      s = mx / 127.0f;
      m->s[(size_t)r * ng + g] = s;
      for (k = 0; k < m->gs; k++) dst[k] = s > 0.0f ? (int8_t)roundf(src[k] / s) : 0;
    }
}

void lm_q_build(lm_qw_t *w, const lm_cfg_t *c, const lm_fw_t *fw, int gs_target, lm_arena_t *a) {
  int L = c->n_layers, D = c->dim, H = c->hidden_dim, kv = D * c->n_kv_heads / c->n_heads, l;
  int ok = 1;
  lm_qm_t embq;
  w->fw = fw;
  w->gs_target = gs_target;
  w->wq = lm_take(a, sizeof(lm_qm_t) * L);
  w->wk = lm_take(a, sizeof(lm_qm_t) * L);
  w->wv = lm_take(a, sizeof(lm_qm_t) * L);
  w->wo = lm_take(a, sizeof(lm_qm_t) * L);
  w->w1 = lm_take(a, sizeof(lm_qm_t) * L);
  w->w2 = lm_take(a, sizeof(lm_qm_t) * L);
  w->w3 = lm_take(a, sizeof(lm_qm_t) * L);
  w->emb = lm_take(a, sizeof(float) * (size_t)c->vocab_size * D);
  if (!a->base) { /* sizing pass: descriptors live on the stack */
    lm_qm_t d;
    for (l = 0; l < L; l++) {
      qm_take(&d, D, D, gs_target, a);
      qm_take(&d, kv, D, gs_target, a);
      qm_take(&d, kv, D, gs_target, a);
      qm_take(&d, D, D, gs_target, a);
      qm_take(&d, H, D, gs_target, a);
      qm_take(&d, D, H, gs_target, a);
      qm_take(&d, H, D, gs_target, a);
    }
    qm_take(&d, c->vocab_size, D, gs_target, a);
    if (!fw->shared) qm_take(&d, c->vocab_size, D, gs_target, a);
    return;
  }
  for (l = 0; l < L; l++) {
    ok &= qm_take(&w->wq[l], D, D, gs_target, a);
    ok &= qm_take(&w->wk[l], kv, D, gs_target, a);
    ok &= qm_take(&w->wv[l], kv, D, gs_target, a);
    ok &= qm_take(&w->wo[l], D, D, gs_target, a);
    ok &= qm_take(&w->w1[l], H, D, gs_target, a);
    ok &= qm_take(&w->w2[l], D, H, gs_target, a);
    ok &= qm_take(&w->w3[l], H, D, gs_target, a);
  }
  ok &= qm_take(&w->cls, c->vocab_size, D, gs_target, a);
  if (!ok || a->fail) {
    a->fail = 1;
    return;
  }
  for (l = 0; l < L; l++) {
    qm_fill(&w->wq[l], fw->wq + (size_t)l * D * D);
    qm_fill(&w->wk[l], fw->wk + (size_t)l * D * kv);
    qm_fill(&w->wv[l], fw->wv + (size_t)l * D * kv);
    qm_fill(&w->wo[l], fw->wo + (size_t)l * D * D);
    qm_fill(&w->w1[l], fw->w1 + (size_t)l * D * H);
    qm_fill(&w->w2[l], fw->w2 + (size_t)l * D * H);
    qm_fill(&w->w3[l], fw->w3 + (size_t)l * D * H);
  }
  qm_fill(&w->cls, fw->wcls);
  /* embedding: dequantized int8 table (the classifier storage when shared) */
  embq = w->cls;
  if (!fw->shared) {
    qm_take(&embq, c->vocab_size, D, gs_target, a);
    if (a->fail) return;
    qm_fill(&embq, fw->emb);
  }
  {
    size_t i, N = (size_t)c->vocab_size * D;
    for (i = 0; i < N; i++) w->emb[i] = embq.q[i] * embq.s[i / embq.gs];
  }
}

void lm_q_alloc(lm_qs_t *s, const lm_cfg_t *c, lm_arena_t *a) {
  int n = c->hidden_dim > c->dim ? c->hidden_dim : c->dim;
  lm_f_alloc(&s->f, c, a);
  s->xq = lm_take(a, (size_t)n);
  s->xs = lm_take(a, sizeof(float) * n);
}

/* quantize x with the matrix's group size, then grouped int8 matmul */
static void q_matmul(float *o, const float *x, const lm_qm_t *m, int8_t *xq, float *xs) {
  int gs = m->gs, ng = m->n / gs, g, k, r;
  for (g = 0; g < ng; g++) {
    float mx = 0.0f, s;
    for (k = 0; k < gs; k++)
      if (fabsf(x[g * gs + k]) > mx) mx = fabsf(x[g * gs + k]);
    s = mx / 127.0f;
    xs[g] = s;
    for (k = 0; k < gs; k++) xq[g * gs + k] = s > 0.0f ? (int8_t)roundf(x[g * gs + k] / s) : 0;
  }
  for (r = 0; r < m->rows; r++) {
    const int8_t *w = m->q + (size_t)r * m->n;
    const float *ws = m->s + (size_t)r * ng;
    float v = 0.0f;
    for (g = 0; g < ng; g++) {
      int32_t acc = 0;
      for (k = 0; k < gs; k++) acc += (int32_t)w[g * gs + k] * (int32_t)xq[g * gs + k];
      v += (float)acc * ws[g] * xs[g];
    }
    o[r] = v;
  }
}

static void f_rmsnorm(float *o, const float *x, const float *w, int n) {
  float ss = 0.0f;
  int j;
  for (j = 0; j < n; j++) ss += x[j] * x[j];
  ss /= n;
  ss += 1e-5f;
  ss = 1.0f / sqrtf(ss);
  for (j = 0; j < n; j++) o[j] = w[j] * (ss * x[j]);
}

static void f_softmax(float *x, int n) {
  float mx = x[0], sum = 0.0f;
  int i;
  for (i = 1; i < n; i++)
    if (x[i] > mx) mx = x[i];
  for (i = 0; i < n; i++) {
    x[i] = expf(x[i] - mx);
    sum += x[i];
  }
  for (i = 0; i < n; i++) x[i] /= sum;
}

float *lm_q_forward(lm_qs_t *qs, const lm_cfg_t *c, const lm_qw_t *w, int tok, int pos) {
  lm_fs_t *s = &qs->f;
  const lm_fw_t *fw = w->fw;
  int dim = c->dim, hid = c->hidden_dim, hs = dim / c->n_heads;
  int kv = dim * c->n_kv_heads / c->n_heads, kvmul = c->n_heads / c->n_kv_heads;
  float *x = s->x;
  int l, i, h, t;
  memcpy(x, w->emb + (size_t)tok * dim, sizeof(float) * dim);
  for (l = 0; l < c->n_layers; l++) {
    size_t loff = (size_t)l * c->seq_len * kv;
    f_rmsnorm(s->xb, x, fw->rms_att + (size_t)l * dim, dim);
    s->k = s->kc + loff + (size_t)pos * kv;
    s->v = s->vc + loff + (size_t)pos * kv;
    q_matmul(s->q, s->xb, &w->wq[l], qs->xq, qs->xs);
    q_matmul(s->k, s->xb, &w->wk[l], qs->xq, qs->xs);
    q_matmul(s->v, s->xb, &w->wv[l], qs->xq, qs->xs);
    for (i = 0; i < dim; i += 2) {
      int hd = i % hs, rotn = i < kv ? 2 : 1, r;
      float freq = 1.0f / powf(10000.0f, hd / (float)hs);
      float val = pos * freq, fcr = cosf(val), fci = sinf(val);
      for (r = 0; r < rotn; r++) {
        float *vec = r == 0 ? s->q : s->k;
        float v0 = vec[i], v1 = vec[i + 1];
        vec[i] = v0 * fcr - v1 * fci;
        vec[i + 1] = v0 * fci + v1 * fcr;
      }
    }
    for (h = 0; h < c->n_heads; h++) {
      float *q = s->q + h * hs, *att = s->att + (size_t)h * c->seq_len, *xb = s->xb + h * hs;
      for (t = 0; t <= pos; t++) {
        const float *k = s->kc + loff + (size_t)t * kv + (h / kvmul) * hs;
        float score = 0.0f;
        for (i = 0; i < hs; i++) score += q[i] * k[i];
        score /= sqrtf(hs);
        att[t] = score;
      }
      f_softmax(att, pos + 1);
      memset(xb, 0, sizeof(float) * hs);
      for (t = 0; t <= pos; t++) {
        const float *v = s->vc + loff + (size_t)t * kv + (h / kvmul) * hs;
        float a = att[t];
        for (i = 0; i < hs; i++) xb[i] += a * v[i];
      }
    }
    q_matmul(s->xb2, s->xb, &w->wo[l], qs->xq, qs->xs);
    for (i = 0; i < dim; i++) x[i] += s->xb2[i];
    f_rmsnorm(s->xb, x, fw->rms_ffn + (size_t)l * dim, dim);
    q_matmul(s->hb, s->xb, &w->w1[l], qs->xq, qs->xs);
    q_matmul(s->hb2, s->xb, &w->w3[l], qs->xq, qs->xs);
    for (i = 0; i < hid; i++) {
      float val = s->hb[i];
      val *= (1.0f / (1.0f + expf(-val)));
      val *= s->hb2[i];
      s->hb[i] = val;
    }
    q_matmul(s->xb, s->hb, &w->w2[l], qs->xq, qs->xs);
    for (i = 0; i < dim; i++) x[i] += s->xb[i];
  }
  f_rmsnorm(x, x, fw->rms_final, dim);
  q_matmul(s->logits, x, &w->cls, qs->xq, qs->xs);
  return s->logits;
}
