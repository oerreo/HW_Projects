#include "lmhash.h"

uint32_t h_fnv(uint32_t h, const void *p, size_t n) {
  const uint8_t *b = (const uint8_t *)p;
  size_t i;
  for (i = 0; i < n; i++) {
    h ^= b[i];
    h *= 16777619u;
  }
  return h;
}

uint32_t h_i32(uint32_t h, int32_t v) {
  uint8_t b[4];
  uint32_t u = (uint32_t)v;
  b[0] = (uint8_t)u;
  b[1] = (uint8_t)(u >> 8);
  b[2] = (uint8_t)(u >> 16);
  b[3] = (uint8_t)(u >> 24);
  return h_fnv(h, b, 4);
}

static uint32_t h_qm(uint32_t h, const lm_qm_t *m) {
  h = h_i32(h, m->rows);
  h = h_i32(h, m->n);
  h = h_i32(h, m->gs);
  h = h_fnv(h, m->q, (size_t)m->rows * m->n);
  return h_fnv(h, m->s, sizeof(float) * (size_t)m->rows * (m->n / m->gs));
}

uint32_t h_qweights(const lm_qw_t *w, const lm_cfg_t *c) {
  uint32_t h = H_INIT;
  int l;
  for (l = 0; l < c->n_layers; l++) {
    h = h_qm(h, &w->wq[l]);
    h = h_qm(h, &w->wk[l]);
    h = h_qm(h, &w->wv[l]);
    h = h_qm(h, &w->wo[l]);
    h = h_qm(h, &w->w1[l]);
    h = h_qm(h, &w->w2[l]);
    h = h_qm(h, &w->w3[l]);
  }
  h = h_qm(h, &w->cls);
  return h_fnv(h, w->emb, sizeof(float) * (size_t)c->vocab_size * c->dim);
}

static uint32_t h_hm(uint32_t h, const lm_hm_t *m) {
  h = h_i32(h, m->rows);
  h = h_i32(h, m->n);
  h = h_i32(h, m->gs);
  h = h_i32(h, m->we);
  h = h_fnv(h, m->q, (size_t)m->rows * m->n);
  return h_fnv(h, m->m, sizeof(uint16_t) * (size_t)m->rows * (m->n / m->gs));
}

static uint32_t h_hg(uint32_t h, const lm_hg_t *g, int n) {
  h = h_i32(h, g->ge);
  return h_fnv(h, g->g, sizeof(int16_t) * (size_t)n);
}

uint32_t h_hweights(const lm_hw_t *w, const lm_cfg_t *c) {
  uint32_t h = H_INIT;
  int l;
  for (l = 0; l < c->n_layers; l++) {
    h = h_hm(h, &w->wq[l]);
    h = h_hm(h, &w->wk[l]);
    h = h_hm(h, &w->wv[l]);
    h = h_hm(h, &w->wo[l]);
    h = h_hm(h, &w->w1[l]);
    h = h_hm(h, &w->w2[l]);
    h = h_hm(h, &w->w3[l]);
    h = h_hg(h, &w->ra[l], c->dim);
    h = h_hg(h, &w->rf[l], c->dim);
  }
  h = h_hm(h, &w->cls);
  h = h_hg(h, &w->rfin, c->dim);
  return h_i32(h, w->epsc);
}
