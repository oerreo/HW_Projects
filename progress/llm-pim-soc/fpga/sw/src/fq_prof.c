/*
 * F and Q forward passes with probes between the steps. The arithmetic is a
 * statement-by-statement copy of model/src/fwd_f.c and fwd_q.c (same operation
 * order, same float expressions), so the logits are bit-identical to the model/src
 * functions under the same compiler flags. The board program verifies this on every
 * run (CHECK ... self_mis) and the host test verifies it against model/src too.
 * If model/src/fwd_f.c or fwd_q.c change, this file must change with them; the
 * self check fails otherwise.
 */
#include <math.h>
#include <string.h>
#include "prof.h"

static void p_rmsnorm(float *o, const float *x, const float *w, int n) {
  float ss = 0.0f;
  int j;
  for (j = 0; j < n; j++) ss += x[j] * x[j];
  ss /= n;
  ss += 1e-5f;
  ss = 1.0f / sqrtf(ss);
  for (j = 0; j < n; j++) o[j] = w[j] * (ss * x[j]);
}

static void p_softmax(float *x, int n) {
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

static void p_matmul(float *o, const float *x, const float *w, int n, int d) {
  int i, j;
  for (i = 0; i < d; i++) {
    float v = 0.0f;
    const float *r = w + (size_t)i * n;
    for (j = 0; j < n; j++) v += r[j] * x[j];
    o[i] = v;
  }
}

static void p_rope(float *q, float *k, int dim, int kv, int hs, int pos) {
  int i;
  for (i = 0; i < dim; i += 2) {
    int hd = i % hs, rotn = i < kv ? 2 : 1, r;
    float freq = 1.0f / powf(10000.0f, hd / (float)hs);
    float val = pos * freq, fcr = cosf(val), fci = sinf(val);
    for (r = 0; r < rotn; r++) {
      float *vec = r == 0 ? q : k;
      float v0 = vec[i], v1 = vec[i + 1];
      vec[i] = v0 * fcr - v1 * fci;
      vec[i + 1] = v0 * fci + v1 * fcr;
    }
  }
}

/* one head of attention (scores, softmax, weighted sum) */
static void p_head(lm_fs_t *s, const lm_cfg_t *c, size_t loff, int kv, int kvmul, int hs, int h,
                   int pos) {
  float *q = s->q + h * hs, *att = s->att + (size_t)h * c->seq_len, *xb = s->xb + h * hs;
  int t, i;
  for (t = 0; t <= pos; t++) {
    const float *k = s->kc + loff + (size_t)t * kv + (h / kvmul) * hs;
    float score = 0.0f;
    for (i = 0; i < hs; i++) score += q[i] * k[i];
    score /= sqrtf(hs);
    att[t] = score;
  }
  p_softmax(att, pos + 1);
  memset(xb, 0, sizeof(float) * hs);
  for (t = 0; t <= pos; t++) {
    const float *v = s->vc + loff + (size_t)t * kv + (h / kvmul) * hs;
    float a = att[t];
    for (i = 0; i < hs; i++) xb[i] += a * v[i];
  }
}

static void p_swiglu(float *hb, const float *hb2, int hid) {
  int i;
  for (i = 0; i < hid; i++) {
    float val = hb[i];
    val *= (1.0f / (1.0f + expf(-val)));
    val *= hb2[i];
    hb[i] = val;
  }
}

static void p_add(float *x, const float *y, int n) {
  int i;
  for (i = 0; i < n; i++) x[i] += y[i];
}

const float *fq_f_forward(lm_fs_t *s, const lm_cfg_t *c, const lm_fw_t *w, int tok, int pos,
                          prof_t *p, int *am) {
  int dim = c->dim, hid = c->hidden_dim, hs = dim / c->n_heads;
  int kv = dim * c->n_kv_heads / c->n_heads, kvmul = c->n_heads / c->n_kv_heads;
  float *x = s->x;
  int l, h;
  memcpy(x, w->emb + (size_t)tok * dim, sizeof(float) * dim);
  prof_lap(p, PC_EMBED);
  for (l = 0; l < c->n_layers; l++) {
    size_t loff = (size_t)l * c->seq_len * kv;
    p_rmsnorm(s->xb, x, w->rms_att + (size_t)l * dim, dim);
    prof_lap(p, PC_RMSNORM);
    s->k = s->kc + loff + (size_t)pos * kv;
    s->v = s->vc + loff + (size_t)pos * kv;
    p_matmul(s->q, s->xb, w->wq + (size_t)l * dim * dim, dim, dim);
    prof_lap(p, PC_GQ);
    p_matmul(s->k, s->xb, w->wk + (size_t)l * dim * kv, dim, kv);
    prof_lap(p, PC_GK);
    p_matmul(s->v, s->xb, w->wv + (size_t)l * dim * kv, dim, kv);
    prof_lap(p, PC_GV);
    p_rope(s->q, s->k, dim, kv, hs, pos);
    prof_lap(p, PC_ROPE);
    for (h = 0; h < c->n_heads; h++) {
      p_head(s, c, loff, kv, kvmul, hs, h, pos);
      prof_lap(p, PC_ATTN);
    }
    p_matmul(s->xb2, s->xb, w->wo + (size_t)l * dim * dim, dim, dim);
    prof_lap(p, PC_GO);
    p_add(x, s->xb2, dim);
    prof_lap(p, PC_ADD);
    p_rmsnorm(s->xb, x, w->rms_ffn + (size_t)l * dim, dim);
    prof_lap(p, PC_RMSNORM);
    p_matmul(s->hb, s->xb, w->w1 + (size_t)l * dim * hid, dim, hid);
    prof_lap(p, PC_GW1);
    p_matmul(s->hb2, s->xb, w->w3 + (size_t)l * dim * hid, dim, hid);
    prof_lap(p, PC_GW3);
    p_swiglu(s->hb, s->hb2, hid);
    prof_lap(p, PC_SWIGLU);
    p_matmul(s->xb, s->hb, w->w2 + (size_t)l * dim * hid, hid, dim);
    prof_lap(p, PC_GW2);
    p_add(x, s->xb, dim);
    prof_lap(p, PC_ADD);
  }
  p_rmsnorm(x, x, w->rms_final, dim);
  prof_lap(p, PC_RMSNORM);
  p_matmul(s->logits, x, w->wcls, dim, c->vocab_size);
  prof_lap(p, PC_GCLS);
  *am = argmax_f(s->logits, c->vocab_size);
  prof_lap(p, PC_ARGMAX);
  return s->logits;
}

/* ---- Q ---- */
/* activation quantization part of model/src/fwd_q.c q_matmul */
static void q_quant(const float *x, const lm_qm_t *m, int8_t *xq, float *xs) {
  int gs = m->gs, ng = m->n / gs, g, k;
  for (g = 0; g < ng; g++) {
    float mx = 0.0f, s;
    for (k = 0; k < gs; k++)
      if (fabsf(x[g * gs + k]) > mx) mx = fabsf(x[g * gs + k]);
    s = mx / 127.0f;
    xs[g] = s;
    for (k = 0; k < gs; k++) xq[g * gs + k] = s > 0.0f ? (int8_t)roundf(x[g * gs + k] / s) : 0;
  }
}

/* integer matmul part of q_matmul */
static void q_mm(float *o, const lm_qm_t *m, const int8_t *xq, const float *xs) {
  int gs = m->gs, ng = m->n / gs, g, k, r;
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

static void q_matmul(float *o, const float *x, const lm_qm_t *m, int8_t *xq, float *xs, prof_t *p,
                     int cat) {
  q_quant(x, m, xq, xs);
  prof_lap(p, PC_ACTQ);
  q_mm(o, m, xq, xs);
  prof_lap(p, cat);
}

const float *fq_q_forward(lm_qs_t *qs, const lm_cfg_t *c, const lm_qw_t *w, int tok, int pos,
                          prof_t *p, int *am) {
  lm_fs_t *s = &qs->f;
  const lm_fw_t *fw = w->fw;
  int dim = c->dim, hid = c->hidden_dim, hs = dim / c->n_heads;
  int kv = dim * c->n_kv_heads / c->n_heads, kvmul = c->n_heads / c->n_kv_heads;
  float *x = s->x;
  int l, h;
  memcpy(x, w->emb + (size_t)tok * dim, sizeof(float) * dim);
  prof_lap(p, PC_EMBED);
  for (l = 0; l < c->n_layers; l++) {
    size_t loff = (size_t)l * c->seq_len * kv;
    p_rmsnorm(s->xb, x, fw->rms_att + (size_t)l * dim, dim);
    prof_lap(p, PC_RMSNORM);
    s->k = s->kc + loff + (size_t)pos * kv;
    s->v = s->vc + loff + (size_t)pos * kv;
    q_matmul(s->q, s->xb, &w->wq[l], qs->xq, qs->xs, p, PC_GQ);
    q_matmul(s->k, s->xb, &w->wk[l], qs->xq, qs->xs, p, PC_GK);
    q_matmul(s->v, s->xb, &w->wv[l], qs->xq, qs->xs, p, PC_GV);
    p_rope(s->q, s->k, dim, kv, hs, pos);
    prof_lap(p, PC_ROPE);
    for (h = 0; h < c->n_heads; h++) {
      p_head(s, c, loff, kv, kvmul, hs, h, pos);
      prof_lap(p, PC_ATTN);
    }
    q_matmul(s->xb2, s->xb, &w->wo[l], qs->xq, qs->xs, p, PC_GO);
    p_add(x, s->xb2, dim);
    prof_lap(p, PC_ADD);
    p_rmsnorm(s->xb, x, fw->rms_ffn + (size_t)l * dim, dim);
    prof_lap(p, PC_RMSNORM);
    q_matmul(s->hb, s->xb, &w->w1[l], qs->xq, qs->xs, p, PC_GW1);
    q_matmul(s->hb2, s->xb, &w->w3[l], qs->xq, qs->xs, p, PC_GW3);
    p_swiglu(s->hb, s->hb2, hid);
    prof_lap(p, PC_SWIGLU);
    q_matmul(s->xb, s->hb, &w->w2[l], qs->xq, qs->xs, p, PC_GW2);
    p_add(x, s->xb, dim);
    prof_lap(p, PC_ADD);
  }
  p_rmsnorm(x, x, fw->rms_final, dim);
  prof_lap(p, PC_RMSNORM);
  q_matmul(s->logits, x, &w->cls, qs->xq, qs->xs, p, PC_GCLS);
  *am = argmax_f(s->logits, c->vocab_size);
  prof_lap(p, PC_ARGMAX);
  return s->logits;
}
