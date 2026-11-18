/* Arena, checkpoint layout and small shared helpers. */
#include <string.h>
#include "llm.h"

void *lm_take(lm_arena_t *a, size_t bytes) {
  size_t off = (a->off + 63u) & ~(size_t)63u;
  void *p = NULL;
  if (a->base) {
    if (off + bytes > a->cap) {
      a->fail = 1;
      return NULL;
    }
    p = a->base + off;
    memset(p, 0, bytes);
  }
  a->off = off + bytes;
  return p;
}

int lm_ckpt_parse(const void *img, size_t len, lm_cfg_t *c, lm_fw_t *w) {
  const int32_t *h = (const int32_t *)img;
  const float *p;
  size_t need;
  long hs, kv, L, D, H, V;
  if (len < 7 * sizeof(int32_t)) return -1;
  c->dim = h[0];
  c->hidden_dim = h[1];
  c->n_layers = h[2];
  c->n_heads = h[3];
  c->n_kv_heads = h[4];
  c->vocab_size = h[5] < 0 ? -h[5] : h[5];
  c->seq_len = h[6];
  w->shared = h[5] > 0;
  if (c->dim <= 0 || c->n_heads <= 0 || c->dim % c->n_heads || c->n_kv_heads <= 0 ||
      c->n_heads % c->n_kv_heads)
    return -2;
  D = c->dim;
  H = c->hidden_dim;
  L = c->n_layers;
  V = c->vocab_size;
  hs = D / c->n_heads;
  kv = hs * c->n_kv_heads;
  p = (const float *)(h + 7);
  w->emb = p;            p += V * D;
  w->rms_att = p;        p += L * D;
  w->wq = p;             p += L * D * D;
  w->wk = p;             p += L * D * kv;
  w->wv = p;             p += L * D * kv;
  w->wo = p;             p += L * D * D;
  w->rms_ffn = p;        p += L * D;
  w->w1 = p;             p += L * D * H;
  w->w2 = p;             p += L * H * D;
  w->w3 = p;             p += L * D * H;
  w->rms_final = p;      p += D;
  p += c->seq_len * hs; /* legacy freq_cis_real and freq_cis_imag */
  if (w->shared) {
    w->wcls = w->emb;
  } else {
    w->wcls = p;
    p += V * D;
  }
  need = (size_t)((const char *)p - (const char *)img);
  return need <= len ? 0 : -3;
}

int lm_group(int n, int target) {
  int g;
  if (target <= 0 || target >= n) return n;
  for (g = target; g > 1; g--)
    if (n % g == 0) return g;
  return 1;
}
