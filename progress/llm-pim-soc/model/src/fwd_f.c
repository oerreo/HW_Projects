/*
 * F variant: float32 forward pass. The operation order matches the llama2.c
 * reference (run.c) so that results are bit-identical under the same compiler
 * flags (-O2 -ffp-contract=off, no -ffast-math).
 */
#include <math.h>
#include <string.h>
#include "llm.h"

void lm_f_alloc(lm_fs_t *s, const lm_cfg_t *c, lm_arena_t *a) {
  int kv = c->dim * c->n_kv_heads / c->n_heads;
  size_t cache = (size_t)c->n_layers * c->seq_len * kv;
  s->x = lm_take(a, sizeof(float) * c->dim);
  s->xb = lm_take(a, sizeof(float) * c->dim);
  s->xb2 = lm_take(a, sizeof(float) * c->dim);
  s->hb = lm_take(a, sizeof(float) * c->hidden_dim);
  s->hb2 = lm_take(a, sizeof(float) * c->hidden_dim);
  s->q = lm_take(a, sizeof(float) * c->dim);
  s->kc = lm_take(a, sizeof(float) * cache);
  s->vc = lm_take(a, sizeof(float) * cache);
  s->att = lm_take(a, sizeof(float) * c->n_heads * c->seq_len);
  s->logits = lm_take(a, sizeof(float) * c->vocab_size);
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

static void f_matmul(float *o, const float *x, const float *w, int n, int d) {
  int i, j;
  for (i = 0; i < d; i++) {
    float v = 0.0f;
    const float *r = w + (size_t)i * n;
    for (j = 0; j < n; j++) v += r[j] * x[j];
    o[i] = v;
  }
}

float *lm_f_forward(lm_fs_t *s, const lm_cfg_t *c, const lm_fw_t *w, int tok, int pos) {
  int dim = c->dim, hid = c->hidden_dim, hs = dim / c->n_heads;
  int kv = dim * c->n_kv_heads / c->n_heads, kvmul = c->n_heads / c->n_kv_heads;
  float *x = s->x;
  int l, i, h, t;
  memcpy(x, w->emb + (size_t)tok * dim, sizeof(float) * dim);
  for (l = 0; l < c->n_layers; l++) {
    size_t loff = (size_t)l * c->seq_len * kv;
    f_rmsnorm(s->xb, x, w->rms_att + (size_t)l * dim, dim);
    s->k = s->kc + loff + (size_t)pos * kv;
    s->v = s->vc + loff + (size_t)pos * kv;
    f_matmul(s->q, s->xb, w->wq + (size_t)l * dim * dim, dim, dim);
    f_matmul(s->k, s->xb, w->wk + (size_t)l * dim * kv, dim, kv);
    f_matmul(s->v, s->xb, w->wv + (size_t)l * dim * kv, dim, kv);
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
    f_matmul(s->xb2, s->xb, w->wo + (size_t)l * dim * dim, dim, dim);
    for (i = 0; i < dim; i++) x[i] += s->xb2[i];
    f_rmsnorm(s->xb, x, w->rms_ffn + (size_t)l * dim, dim);
    f_matmul(s->hb, s->xb, w->w1 + (size_t)l * dim * hid, dim, hid);
    f_matmul(s->hb2, s->xb, w->w3 + (size_t)l * dim * hid, dim, hid);
    for (i = 0; i < hid; i++) {
      float val = s->hb[i];
      val *= (1.0f / (1.0f + expf(-val)));
      val *= s->hb2[i];
      s->hb[i] = val;
    }
    f_matmul(s->xb, s->hb, w->w2 + (size_t)l * dim * hid, hid, dim);
    for (i = 0; i < dim; i++) x[i] += s->xb[i];
  }
  f_rmsnorm(x, x, w->rms_final, dim);
  f_matmul(s->logits, x, w->wcls, dim, c->vocab_size);
  return s->logits;
}
