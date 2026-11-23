/*
 * H variant forward pass. Every arithmetic step is a kernel call through a
 * descriptor (k_exec), so a hook sees and can dump the exact inputs and outputs of
 * each hardware kernel. No float type and no libm call in this file.
 */
#include <string.h>
#include "llm.h"

void lm_h_alloc(lm_hs_t *s, const lm_cfg_t *c, const lm_hfmt_t *f, lm_arena_t *a) {
  int D = c->dim, H = c->hidden_dim, hs = D / c->n_heads, kv = D * c->n_kv_heads / c->n_heads;
  int kbit = f->kbits ? f->kbits : (f->kv16 ? 16 : 8), vbit = f->kbits ? f->vbits : kbit;
  int ek = kbit > 8 ? 2 : 1, ev = vbit > 8 ? 2 : 1, mx = H > D ? H : D;
  size_t cache = (size_t)c->n_layers * c->n_kv_heads * c->seq_len;
  s->x = lm_take(a, 4 * (size_t)D);
  s->x2 = lm_take(a, 4 * (size_t)D);
  s->y = lm_take(a, 4 * (size_t)D);
  s->q = lm_take(a, 4 * (size_t)D);
  s->qr = lm_take(a, 4 * (size_t)D);
  s->k = lm_take(a, 4 * (size_t)kv);
  s->kr = lm_take(a, 4 * (size_t)kv);
  s->v = lm_take(a, 4 * (size_t)kv);
  s->att = lm_take(a, 4 * (size_t)D);
  s->h1 = lm_take(a, 4 * (size_t)H);
  s->h3 = lm_take(a, 4 * (size_t)H);
  s->logits = lm_take(a, 4 * (size_t)c->vocab_size);
  s->p = lm_take(a, 4 * (size_t)c->seq_len);
  s->argmax = lm_take(a, 4);
  s->a8 = lm_take(a, (size_t)mx);
  s->as = lm_take(a, sizeof(kscl_t));
  s->qh = lm_take(a, (size_t)ek * hs);
  s->qhs = lm_take(a, sizeof(kscl_t));
  s->kc = lm_take(a, (size_t)ek * cache * hs);
  s->vc = lm_take(a, (size_t)ev * cache * hs);
  s->kcs = lm_take(a, sizeof(kscl_t) * cache);
  s->vcs = lm_take(a, sizeof(kscl_t) * cache);
}

static void kc0(kcall_t *c, int kid) {
  memset(c, 0, sizeof(*c));
  c->kid = kid;
}
static void kp(kcall_t *c, int32_t v) { c->prm[c->np++] = v; }
static void kb(kcall_t *c, const void *p, int esz, int n, int out) {
  kbuf_t *b = &c->b[c->nb++];
  b->p = (void *)p;
  b->esz = esz;
  b->n = n;
  b->out = out;
}
/* hook and executor of one forward pass */
typedef struct {
  const k_hook_t *hk;
  const k_exec_t *ex;
} fx_t;

static int run(const fx_t *h, kcall_t *c) {
  int rc;
  if (h->hk && h->hk->fn) h->hk->fn(h->hk->user, 0, c);
  rc = (h->ex && h->ex->fn) ? h->ex->fn(h->ex->user, c) : k_exec(c);
  if (h->hk && h->hk->fn) h->hk->fn(h->hk->user, 1, c);
  return rc;
}

static int gemv(const fx_t *h, const lm_hm_t *m, const int8_t *x, const kscl_t *xs, int32_t *y) {
  kcall_t c;
  kc0(&c, K_GEMV);
  kp(&c, m->rows); kp(&c, m->n); kp(&c, m->gs); kp(&c, m->we);
  kp(&c, xs->m); kp(&c, xs->e); kp(&c, K_FX);
  kb(&c, m->q, 1, m->rows * m->n, 0);
  kb(&c, m->m, 2, m->rows * (m->n / m->gs), 0);
  kb(&c, x, 1, m->n, 0);
  kb(&c, y, 4, m->rows, 1);
  return run(h, &c);
}

static int rmsnorm(const fx_t *h, const int32_t *x, int n, const lm_hg_t *g, int32_t epsc,
                   int mode, int8_t *q, kscl_t *s) {
  kcall_t c;
  kc0(&c, K_RMSNORM);
  kp(&c, n); kp(&c, K_FX); kp(&c, g->ge); kp(&c, epsc); kp(&c, K_FX); kp(&c, mode);
  kb(&c, x, 4, n, 0);
  kb(&c, g->g, 2, n, 0);
  kb(&c, q, 1, n, 1);
  kb(&c, s, 4, 2, 1);
  return run(h, &c);
}

static int actq(const fx_t *h, const int32_t *v, int n, int mode, int qmax, void *q, kscl_t *s) {
  kcall_t c;
  kc0(&c, K_ACTQ);
  kp(&c, n); kp(&c, K_FX); kp(&c, mode); kp(&c, qmax);
  kb(&c, v, 4, n, 0);
  kb(&c, q, qmax == 127 ? 1 : 2, n, 1);
  kb(&c, s, 4, 2, 1);
  return run(h, &c);
}

static int rope(const fx_t *h, const int32_t *v, int n, int hs, const int16_t *cs, int32_t *o) {
  kcall_t c;
  kc0(&c, K_ROPE);
  kp(&c, n); kp(&c, hs);
  kb(&c, v, 4, n, 0);
  kb(&c, cs, 2, hs, 0);
  kb(&c, o, 4, n, 1);
  return run(h, &c);
}

static int add(const fx_t *h, const int32_t *a, const int32_t *b, int n, int32_t *o) {
  kcall_t c;
  kc0(&c, K_ADD);
  kp(&c, n);
  kb(&c, a, 4, n, 0);
  kb(&c, b, 4, n, 0);
  kb(&c, o, 4, n, 1);
  return run(h, &c);
}

const int32_t *lm_h_forward(lm_hs_t *s, const lm_cfg_t *cf, const lm_hw_t *w, int tok, int pos,
                            const k_hook_t *h) {
  return lm_h_forward_x(s, cf, w, tok, pos, h, NULL);
}

const int32_t *lm_h_forward_x(lm_hs_t *s, const lm_cfg_t *cf, const lm_hw_t *w, int tok, int pos,
                              const k_hook_t *hook, const k_exec_t *ex) {
  fx_t hx, *h = &hx;
  const lm_hfmt_t *f = &w->f;
  int D = cf->dim, H = cf->hidden_dim, hs = D / cf->n_heads, nkv = cf->n_kv_heads;
  int kv = hs * nkv, kvmul = cf->n_heads / nkv;
  int kbit = f->kbits ? f->kbits : (f->kv16 ? 16 : 8), vbit = f->kbits ? f->vbits : kbit;
  int ek = kbit > 8 ? 2 : 1, ev = vbit > 8 ? 2 : 1;
  int qk = (1 << (kbit - 1)) - 1, qv = (1 << (vbit - 1)) - 1, mode = f->act_mode, T = pos + 1;
  int T0 = (f->win > 0 && T > f->win) ? T - f->win : 0; /* first attended position */
  const int16_t *cs = w->rope + (size_t)pos * hs;
  int rc = 0, l, j;
  kcall_t c;
  hx.hk = hook;
  hx.ex = ex;
  if (tok < 0 || tok >= cf->vocab_size || pos < 0 || pos >= cf->seq_len) return NULL;
  kc0(&c, K_EMBED);
  kp(&c, D); kp(&c, w->cls.gs); kp(&c, w->cls.we); kp(&c, K_FX);
  kb(&c, w->cls.q + (size_t)tok * D, 1, D, 0);
  kb(&c, w->cls.m + (size_t)tok * (D / w->cls.gs), 2, D / w->cls.gs, 0);
  kb(&c, s->x, 4, D, 1);
  rc |= run(h, &c);
  for (l = 0; l < cf->n_layers; l++) {
    int32_t *t32;
    rc |= rmsnorm(h, s->x, D, &w->ra[l], w->epsc, mode, s->a8, s->as);
    rc |= gemv(h, &w->wq[l], s->a8, s->as, s->q);
    rc |= gemv(h, &w->wk[l], s->a8, s->as, s->k);
    rc |= gemv(h, &w->wv[l], s->a8, s->as, s->v);
    rc |= rope(h, s->q, D, hs, cs, s->qr);
    rc |= rope(h, s->k, kv, hs, cs, s->kr);
    for (j = 0; j < nkv; j++) {
      size_t slot = ((size_t)l * nkv + j) * cf->seq_len + pos;
      rc |= actq(h, s->kr + j * hs, hs, mode, qk, (int8_t *)s->kc + slot * hs * ek, s->kcs + slot);
      rc |= actq(h, s->v + j * hs, hs, mode, qv, (int8_t *)s->vc + slot * hs * ev, s->vcs + slot);
    }
    for (j = 0; j < cf->n_heads; j++) {
      /* the window is a contiguous slice; a ring buffer gives the same result because the
         kernel is invariant to the order of positions (integer sums, max, min) */
      size_t base = ((size_t)l * nkv + j / kvmul) * cf->seq_len + T0;
      int Tw = T - T0;
      rc |= actq(h, s->qr + j * hs, hs, mode, qk, s->qh, s->qhs);
      if (f->kbits) {
        kc0(&c, K_ATTN2);
        kp(&c, Tw); kp(&c, hs); kp(&c, kbit); kp(&c, vbit);
      } else {
        kc0(&c, K_ATTN);
        kp(&c, Tw); kp(&c, hs); kp(&c, ek);
      }
      kp(&c, s->qhs->m); kp(&c, s->qhs->e); kp(&c, f->exp_bits);
      kb(&c, s->qh, ek, hs, 0);
      kb(&c, (int8_t *)s->kc + base * hs * ek, ek, Tw * hs, 0);
      kb(&c, s->kcs + base, 4, 2 * Tw, 0);
      kb(&c, (int8_t *)s->vc + base * hs * ev, ev, Tw * hs, 0);
      kb(&c, s->vcs + base, 4, 2 * Tw, 0);
      kb(&c, w->elut, 4, (1 << f->exp_bits) + 1, 0);
      kb(&c, s->p, 4, Tw, 1);
      kb(&c, s->att + j * hs, 4, hs, 1);
      rc |= run(h, &c);
    }
    rc |= actq(h, s->att, D, mode, 127, s->a8, s->as);
    rc |= gemv(h, &w->wo[l], s->a8, s->as, s->y);
    rc |= add(h, s->x, s->y, D, s->x2);
    t32 = s->x; s->x = s->x2; s->x2 = t32;
    rc |= rmsnorm(h, s->x, D, &w->rf[l], w->epsc, mode, s->a8, s->as);
    rc |= gemv(h, &w->w1[l], s->a8, s->as, s->h1);
    rc |= gemv(h, &w->w3[l], s->a8, s->as, s->h3);
    kc0(&c, K_SWIGLU);
    kp(&c, H); kp(&c, f->sig_bits); kp(&c, mode);
    kb(&c, s->h1, 4, H, 0);
    kb(&c, s->h3, 4, H, 0);
    kb(&c, w->slut, 4, (1 << f->sig_bits) + 1, 0);
    kb(&c, s->a8, 1, H, 1);
    kb(&c, s->as, 4, 2, 1);
    rc |= run(h, &c);
    rc |= gemv(h, &w->w2[l], s->a8, s->as, s->y);
    rc |= add(h, s->x, s->y, D, s->x2);
    t32 = s->x; s->x = s->x2; s->x2 = t32;
  }
  rc |= rmsnorm(h, s->x, D, &w->rfin, w->epsc, mode, s->a8, s->as);
  rc |= gemv(h, &w->cls, s->a8, s->as, s->logits);
  kc0(&c, K_ARGMAX);
  kp(&c, cf->vocab_size);
  kb(&c, s->logits, 4, cf->vocab_size, 0);
  kb(&c, s->argmax, 4, 1, 1);
  rc |= run(h, &c);
  return rc ? NULL : s->logits;
}
