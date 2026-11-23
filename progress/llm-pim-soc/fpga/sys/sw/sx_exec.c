/*
 * Executor (system.md 2.2, 2.4, 2.6, 2.7). Entry sx_exec() is the k_exec_fn of
 * lm_h_forward_x: one call per kernel call of the golden forward pass, in golden order.
 *
 *  - mask bit of the call (G, C, A, R, S, Qh, Qa, M); bit off -> ARM k_exec
 *  - guard (IP limits); outside -> ARM k_exec and fallback count (must stay 0)
 *  - deferred execution: ATTN heads of one layer -> one op (DEFER_AT), MACABs with the same x
 *    -> one RUN (PIM_BATCH). A call that cannot join the pending batch is a barrier: the batch
 *    runs first and completes ("a call that reads a deferred output always passes a barrier")
 *  - cache rules: producer flush of every ARM output (mask != 0), consumer invalidate of IP
 *    outputs that the ARM reads later in this run, q records flushed by the driver
 *  - x generation: every call writing a8/as increments it; WRGB is skipped only when the x
 *    address and the generation equal the last WRGB
 *  - run P: time split per category (arm, pl, mv, call); run K: k_exec of every IP call on
 *    shadow outputs, compared element by element with the IP output
 */
#include <string.h>
#include "hal.h"
#include "out.h"
#include "plat.h"
#include "prof.h"
#include "sx.h"

const char *const SK_NAME[SK_N] = {
    "embed",   "rmsnorm", "gemv_q", "gemv_k", "gemv_v", "gemv_o", "gemv_w1", "gemv_w2", "gemv_w3",
    "gemv_cls", "rope",   "actq_h", "actq_a", "attn",   "swiglu", "add",     "argmax",  "other"};
const char *const RK_NAME[RK_N] = {"E", "T", "P", "K", "W"};
static const int8_t SK_PC[SK_N] = {PC_EMBED, PC_RMSNORM, PC_GQ,   PC_GK,     PC_GV,  PC_GO,
                                   PC_GW1,   PC_GW2,     PC_GW3,  PC_GCLS,   PC_ROPE, PC_ACTQ,
                                   PC_ACTQ,  PC_ATTN,    PC_SWIGLU, PC_ADD,  PC_ARGMAX, PC_OTHER};

static size_t bsz(const kbuf_t *b) { return (size_t)b->esz * (size_t)b->n; }
static int s8(int32_t v) { return v >= -128 && v <= 127; }

void sx_run_begin(sx_t *x, uint32_t mask, uint32_t opt, int kind) {
  x->mask = mask;
  x->opt = opt;
  x->kind = kind;
  x->meas = kind == RK_P;
  x->kmode = kind == RK_K;
  x->need_hash = kind != RK_E;
  memset(x->ncall, 0, sizeof(x->ncall));
  memset(x->sk, 0, sizeof(x->sk));
  memset(x->kc, 0, sizeof(x->kc));
  x->fb = x->iperr = x->iperr_lines = x->kmis = x->nops = 0;
  x->at_n = x->pi_n = 0;
  x->kvw_l = -1;
  x->kvw_pos = -1;
  x->fused = 0;
  x->fault_n = 0;
}

/* ---------------- classification ---------------- */
static const smat_t *find_mat(const sx_t *x, const void *w) {
  int i;
  for (i = 0; i < x->nmat; i++)
    if (x->mat[i].w == w) return &x->mat[i];
  return NULL;
}

static int cat_of(const sx_t *x, const kcall_t *c, uint32_t *bit, const smat_t **mp) {
  *bit = 0;
  *mp = NULL;
  switch (c->kid) {
  case K_EMBED: return SK_EMBED;
  case K_ROPE: return SK_ROPE;
  case K_ADD: return SK_ADD;
  case K_RMSNORM: *bit = MB_R; return SK_RMSNORM;
  case K_SWIGLU: *bit = MB_S; return SK_SWIGLU;
  case K_ACTQ:
    if (c->nb > 1 && c->b[1].p == (void *)x->s->a8) { *bit = MB_QA; return SK_ACTQA; }
    *bit = MB_QH;
    return SK_ACTQH;
  case K_ATTN:
  case K_ATTN2: *bit = MB_A; return SK_ATTN;
  case K_ARGMAX: *bit = MB_M; return SK_ARGMAX;
  case K_GEMV:
    *mp = find_mat(x, c->b[0].p);
    if (!*mp) return SK_OTHER;
    *bit = (*mp)->sk == SK_GCLS ? MB_C : MB_G;
    return (*mp)->sk;
  default: return SK_OTHER;
  }
}

static int slot_of(const sx_t *x, uint32_t bit) {
  if (bit & (MB_G | MB_C)) return x->sys->has[SLOT_GA] ? SLOT_GA : SLOT_PI;
  if (bit & MB_A) return SLOT_AT;
  return SLOT_VE;
}

/* the call of this bit goes to its IP in this run (mask, availability, IP alive) */
static int ip_on(const sx_t *x, uint32_t bit) {
  return (x->mask & bit) && (x->avail & bit) && !x->sys->dead[slot_of(x, bit)];
}

/* attention call geometry: head j, layer l, kv head, first position (window) */
typedef struct { int j, l, kvh, t0; } ageo_t;
static int attn_geo(const sx_t *x, const kcall_t *c, ageo_t *g) {
  long oj = (long)((const int32_t *)c->b[7].p - x->s->att);
  long ok = (long)((const int8_t *)c->b[1].p - (const int8_t *)x->s->kc);
  long el = (long)x->hs * x->ek, slot;
  if (oj < 0 || oj % x->hs || ok < 0 || ok % el) return 0;
  slot = ok / el;
  g->j = (int)(oj / x->hs);
  g->t0 = (int)(slot % x->seq);
  g->kvh = (int)((slot / x->seq) % x->nkv);
  g->l = (int)(slot / ((long)x->seq * x->nkv));
  return 1;
}

/* system.md 2.2 guard table (equal to or narrower than the IP's BAD_DESC rules) */
static int guard(const sx_t *x, const kcall_t *c, uint32_t bit, const smat_t *m) {
  const sys_t *y = x->sys;
  const int32_t *P = c->prm;
  if (FAULT(x, FX_GUARD)) return 1;
  if (bit & (MB_G | MB_C)) {
    int nmax = y->has[SLOT_GA] ? y->ga_nmax : y->pi_nmax;
    if (!m || !m->ok || P[2] != P[1] || P[1] > nmax || P[0] > 65535 || P[4] < 0 ||
        P[4] >= (1 << 17) || !s8(P[3]) || !s8(P[5]) || !s8(P[6]))
      return 0;
    if (!y->has[SLOT_GA] && m->base < 0) return 0;
    return 1;
  }
  if (bit & MB_A) {
    ageo_t g;
    int T = P[0];
    if (c->kid != K_ATTN2 || !attn_geo(x, c, &g)) return 0;
    if ((P[2] != 8 && P[2] != 12 && P[2] != 16) || (P[3] != 8 && P[3] != 12 && P[3] != 16)) return 0;
    if (P[2] != x->kb || P[3] != x->vb || P[1] != x->hs) return 0;
    if (P[1] % 8 || P[1] > y->at_hsmax || T > y->at_tmax || T > x->seq || P[6] != 8) return 0;
    if (g.t0 != 0 || g.kvh != g.j / x->kvmul || g.j >= SX_MAXH || g.j >= 256) return 0;
    if (!y->at_kvsrc &&
        (P[1] > y->at_kl || P[2] > y->at_kw || P[3] > y->at_vw || g.l >= y->at_nl || g.kvh >= y->at_nkv))
      return 0;
    return 1;
  }
  switch (c->kid) {
  case K_RMSNORM: return P[5] == ACT_MANT && P[0] <= y->ve_nmax && s8(P[4]) && s8(P[2]) && P[3] >= 0;
  case K_SWIGLU: return P[2] == ACT_MANT && P[1] == 8 && P[0] <= y->ve_nmax;
  case K_ACTQ:
    return P[2] == ACT_MANT && (P[3] == 127 || P[3] == 2047 || P[3] == 32767) && P[0] <= y->ve_nmax &&
           s8(P[1]);
  case K_ARGMAX: return y->ve_idxw >= 31 || (long)P[0] <= (1L << y->ve_idxw);
  default: return 0;
  }
}

/* ---------------- ARM execution and cache helpers ---------------- */
static void flush_out(sx_t *x, const kcall_t *c) {
  int i;
  for (i = 0; i < c->nb; i++) {
    if (!c->b[i].out) continue;
    if (FAULT(x, FX_NOFLUSH) && !x->fault_n++) continue; /* (1) one producer flush missing */
    hal_flush(c->b[i].p, bsz(&c->b[i]));
  }
}

static void inv(sx_t *x, const void *p, size_t n) {
  if (FAULT(x, FX_NOINVAL) && !x->fault_n++) return; /* (2) one consumer invalidate missing */
  hal_inval(p, n);
}

static int arm_exec(sx_t *x, const kcall_t *c, int sk) {
  uint64_t t0 = 0, t1 = 0;
  int i, rc;
  for (i = 0; i < c->nb; i++)
    if (!c->b[i].out) hal_arm_rd(c->b[i].p, bsz(&c->b[i]));
  if (x->meas) t0 = plat_now();
  rc = k_exec(c);
  if (x->meas) {
    t1 = plat_now();
    x->sk[sk].t_arm += (int64_t)(t1 - t0);
  }
  for (i = 0; i < c->nb; i++)
    if (c->b[i].out) hal_arm_wr(c->b[i].p, bsz(&c->b[i]));
  if (x->mask) { /* producer rule (system.md 2.2 cache rule 2) */
    flush_out(x, c);
    if (x->meas) x->sk[sk].t_mv += (int64_t)(plat_now() - t1);
  }
  x->sk[sk].arm++;
  return rc;
}

/* accounting of one IP op (system.md 2.6) */
static void ip_done(sx_t *x, int sk, const dres_t *r) {
  sk_t *k = &x->sk[sk];
  k->ops++;
  if (!x->meas) return;
  k->cyc += r->cyc;
  k->rd += r->rd;
  k->wr += r->wr;
  k->t_pl += sx_cyc_ticks(x, (uint64_t)r->cyc - r->rd - r->wr);
  k->t_mv += (int64_t)(r->t1 - r->t0) + (int64_t)r->tinv + sx_cyc_ticks(x, (uint64_t)r->rd + r->wr);
  k->t_call += (int64_t)(r->t3 - r->t1) - sx_cyc_ticks(x, r->cyc) + (int64_t)(r->t4 - r->t3 - r->tinv);
}

/* run K: k_exec of c on shadow outputs, compared with the IP outputs.
   qsub: q of a deferred head (replaces b[0]); preal: where the IP wrote p (attention) */
static void kcmp(sx_t *x, int sk, const kcall_t *c, const void *qsub, const int32_t *preal) {
  kcall_t d = *c;
  kc_t *k = &x->kc[sk];
  size_t off = 0;
  int i;
  long e, call = k->calls++;
  if (qsub) d.b[0].p = (void *)qsub;
  for (i = 0; i < d.nb; i++) {
    if (!d.b[i].out) {
      hal_arm_rd(d.b[i].p, bsz(&d.b[i]));
      continue;
    }
    if (off + bsz(&d.b[i]) > x->shn) return;
    d.b[i].p = x->shadow + off;
    off += (bsz(&d.b[i]) + 7u) & ~(size_t)7u;
  }
  if (k_exec(&d)) {
    k->mis++;
    return;
  }
  hal_arm_wr(x->shadow, off);
  for (i = 0; i < d.nb; i++) {
    const void *real = (c->kid == K_ATTN2 && i == 6 && preal) ? (const void *)preal : c->b[i].p;
    if (!d.b[i].out) continue;
    hal_arm_rd(real, bsz(&d.b[i]));
    for (e = 0; e < d.b[i].n; e++) {
      int32_t a, b;
      if (d.b[i].esz == 1) {
        a = ((const int8_t *)d.b[i].p)[e];
        b = ((const int8_t *)real)[e];
      } else if (d.b[i].esz == 2) {
        a = ((const int16_t *)d.b[i].p)[e];
        b = ((const int16_t *)real)[e];
      } else {
        a = ((const int32_t *)d.b[i].p)[e];
        b = ((const int32_t *)real)[e];
      }
      if (a != b) {
        if (!k->mis) {
          k->first_pos = x->pos;
          k->first_call = call;
          k->first_idx = e;
          k->exp = a;
          k->got = b;
        }
        k->mis++;
      }
    }
  }
}

/* an IP op failed so that its outputs are not valid: compute them on the ARM */
static int redo(sx_t *x, const kcall_t *c, int sk, const void *qsub) {
  kcall_t d = *c;
  if (qsub) d.b[0].p = (void *)qsub;
  return arm_exec(x, &d, sk);
}

static int need_inv_a8(const sx_t *x, const kcall_t *c) {
  /* consumer of a8: the next K_GEMV (cls after the final rmsnorm) */
  uint32_t b = (c->kid == K_RMSNORM && c->b[1].p == (void *)x->w->rfin.g) ? MB_C : MB_G;
  return x->kmode || !ip_on(x, b);
}

static int need_inv_y(const sx_t *x, int sk) {
  switch (sk) {
  case SK_GV: return x->kmode || !ip_on(x, MB_QH);
  case SK_GW1:
  case SK_GW3: return x->kmode || !ip_on(x, MB_S);
  case SK_GCLS: return x->kmode || x->need_hash || (!ip_on(x, MB_M) && !x->fused);
  default: return 1; /* q, k (rope), o, w2 (add) */
  }
}

/* ---------------- PIM batch ---------------- */
static void pim_flush(sx_t *x) {
  dres_t r;
  uint64_t est = 64u, t;
  int i, rc, sk = x->pi_m[0]->sk;
  for (i = 0; i < x->pi_n; i++)
    est += (uint64_t)x->pi_c[i].prm[0] * (1u + (uint32_t)x->pi_c[i].prm[1] / 16u) / 4u + 64u;
  memset(&r, 0, sizeof(r));
  if (x->meas) r.t0 = r.t1 = plat_now();
  rc = pi_run(x, est, &r);
  if (rc == DRV_ERR || rc == DRV_TIMEOUT) {
    x->pi_xok = 0;
    for (i = 0; i < x->pi_n; i++) redo(x, &x->pi_c[i], x->pi_m[i]->sk, NULL);
    x->pi_n = 0;
    return;
  }
  t = x->meas ? plat_now() : 0;
  for (i = 0; i < x->pi_n; i++) {
    const kcall_t *c = &x->pi_c[i];
    if (need_inv_y(x, x->pi_m[i]->sk)) inv(x, c->b[3].p, bsz(&c->b[3]));
  }
  if (x->meas) {
    r.t4 = plat_now();
    r.tinv = r.t4 - t;
    if (!r.t3) r.t3 = t;
  }
  ip_done(x, sk, &r);
  if (x->kmode)
    for (i = 0; i < x->pi_n; i++) kcmp(x, x->pi_m[i]->sk, &x->pi_c[i], NULL, NULL);
  x->pi_n = 0;
}

static int pim_gemv(sx_t *x, const kcall_t *c, int sk, const smat_t *m) {
  const int32_t *P = c->prm;
  uint32_t xpa = hal_pa(c->b[2].p);
  uint64_t t0 = x->meas ? plat_now() : 0;
  int same = x->pi_xok && x->pi_xpa == xpa && x->pi_xgen == x->xgen, rc, k;
  if (FAULT(x, FX_WRGB) && x->pi_xok) same = 1; /* (6) WRGB skipped although x changed */
  for (k = 0; k < 2; k++) {
    rc = DRV_OK;
    if (!same || !(x->opt & OPT_WRGB_SKIP)) rc = pi_push(x, PI_C_WRGB, P[1], 0, 0, 0, xpa, 0, 0, 0);
    if (rc == DRV_OK)
      rc = pi_push(x, PI_C_MACAB, P[1], P[0], P[4], m->base, hal_pa(c->b[3].p), P[3], P[5], P[6]);
    if (rc != DRV_FULL || !x->pi_n) break;
    pim_flush(x); /* FIFO full: run what is queued, then push again */
    same = 0;
  }
  if (rc != DRV_OK) { /* push not possible: compute on the ARM */
    x->pi_xok = 0;
    return redo(x, c, sk, NULL);
  }
  x->pi_xok = 1;
  x->pi_xpa = xpa;
  x->pi_xgen = x->xgen;
  x->pi_c[x->pi_n] = *c;
  x->pi_m[x->pi_n] = m;
  x->pi_n++;
  x->sk[sk].ip++;
  if (x->meas) x->sk[sk].t_mv += (int64_t)(plat_now() - t0); /* push = input side (2.6 t1) */
  if (!(x->opt & OPT_PIM_BATCH) || x->pi_n >= SX_MAXB) pim_flush(x);
  return 0;
}

/* ---------------- gemv_acc ---------------- */
static int ga_call(sx_t *x, const kcall_t *c, int sk, const smat_t *m) {
  dres_t r;
  uint64_t t;
  int am = sk == SK_GCLS && (x->opt & OPT_FUSE_AM) && ip_on(x, MB_M), rc;
  memset(&r, 0, sizeof(r));
  rc = ga_gemv(x, c, m, am, &r);
  x->sk[sk].ip++;
  if (rc == DRV_ERR || rc == DRV_TIMEOUT) return redo(x, c, sk, NULL);
  if (am) x->fused = 1;
  t = x->meas ? plat_now() : 0;
  if (need_inv_y(x, sk)) inv(x, c->b[3].p, bsz(&c->b[3]));
  if (x->meas) {
    r.t4 = plat_now();
    r.tinv = r.t4 - t;
  }
  ip_done(x, sk, &r);
  if (x->kmode) kcmp(x, sk, c, NULL, NULL);
  return 0;
}

/* ---------------- attention ---------------- */
static void attn_flush(sx_t *x) {
  dres_t r;
  uint64_t t;
  int j, rc, h0 = x->at_h0, n = x->at_n;
  uint32_t ps = 8u * (((uint32_t)x->at_T + 1u) / 2u);
  memset(&r, 0, sizeof(r));
  if (x->meas) r.t0 = plat_now();
  rc = at_attn(x, x->at_l, x->at_T, h0, n, &r);
  x->at_n = 0;
  if (rc == DRV_ERR || rc == DRV_TIMEOUT) {
    for (j = h0; j < h0 + n; j++) redo(x, &x->at_c[j], SK_ATTN, x->qsave[j]);
    return;
  }
  t = x->meas ? plat_now() : 0;
  if (x->kmode || !ip_on(x, MB_QA))
    inv(x, x->s->att + (size_t)h0 * (size_t)x->hs, 4u * (size_t)x->hs * (size_t)n);
  if (x->kmode) inv(x, (uint8_t *)x->pbuf + (size_t)h0 * ps, (size_t)n * ps);
  if (x->meas) {
    r.t4 = plat_now();
    r.tinv = r.t4 - t;
  }
  ip_done(x, SK_ATTN, &r);
  if (x->kmode)
    for (j = h0; j < h0 + n; j++)
      kcmp(x, SK_ATTN, &x->at_c[j], x->qsave[j], (const int32_t *)((uint8_t *)x->pbuf + (size_t)j * ps));
}

static int attn_call(sx_t *x, const kcall_t *c) {
  const int32_t *P = c->prm;
  ageo_t g;
  int T = P[0], i;
  uint64_t t0 = x->meas ? plat_now() : 0;
  uint8_t *rec;
  int32_t qm = P[4], qe = P[5];
  attn_geo(x, c, &g); /* checked by the guard */
  if (x->at_n && (g.l != x->at_l || T != x->at_T || g.j != x->at_next)) attn_flush(x);
  if (!x->sys->at_kvsrc && (x->kvw_l != g.l || x->kvw_pos != T - 1)) {
    dres_t r;
    int rc;
    memset(&r, 0, sizeof(r));
    if (x->meas) r.t0 = plat_now();
    rc = at_kvw(x, g.l, T - 1, &r); /* BRAM KV: the new position of this layer */
    if (x->meas) r.t4 = plat_now();
    ip_done(x, SK_ATTN, &r);
    x->kvw_l = g.l;
    x->kvw_pos = T - 1;
    if (rc != DRV_OK) x->kvw_l = -1;
    if (x->meas) t0 = plat_now();
  }
  /* q record j: {int32 qm, int32 qe, int16 q[hs]} (attn.md 2) */
  hal_arm_rd(c->b[0].p, bsz(&c->b[0]));
  memcpy(x->qsave[g.j], c->b[0].p, bsz(&c->b[0]));
  rec = x->qrec + (size_t)g.j * x->qb;
  if (FAULT(x, FX_QREC)) { /* (3) qm and qe swapped */
    memcpy(rec, &qe, 4);
    memcpy(rec + 4, &qm, 4);
  } else {
    memcpy(rec, &qm, 4);
    memcpy(rec + 4, &qe, 4);
  }
  for (i = 0; i < x->hs; i++) {
    int16_t v = x->ek == 2 ? ((const int16_t *)c->b[0].p)[i] : (int16_t)((const int8_t *)c->b[0].p)[i];
    memcpy(rec + 8 + 2 * i, &v, 2);
  }
  hal_arm_wr(rec, x->qb);
  x->at_c[g.j] = *c;
  if (!x->at_n) {
    x->at_h0 = g.j;
    x->at_l = g.l;
    x->at_T = T;
  }
  x->at_n++;
  x->at_next = g.j + 1;
  x->sk[SK_ATTN].ip++;
  if (x->meas) x->sk[SK_ATTN].t_mv += (int64_t)(plat_now() - t0); /* q record = input side */
  if (!(x->opt & OPT_DEFER_AT) || (g.j == x->nh - 1 && !FAULT(x, FX_BARRIER))) attn_flush(x);
  return 0;
}

/* ---------------- vec ---------------- */
static int vec_call(sx_t *x, const kcall_t *c, int sk) {
  dres_t r;
  uint64_t t;
  int rc;
  if (c->kid == K_ARGMAX && x->fused) { /* done by gemv_acc argmax_en (FUSE_AM) */
    x->sk[sk].ip++;
    if (x->kmode) kcmp(x, sk, c, NULL, NULL);
    return 0;
  }
  memset(&r, 0, sizeof(r));
  rc = ve_call(x, c, &r);
  x->sk[sk].ip++;
  if (rc == DRV_ERR || rc == DRV_TIMEOUT) return redo(x, c, sk, NULL);
  t = x->meas ? plat_now() : 0;
  switch (c->kid) {
  case K_RMSNORM:
    if (need_inv_a8(x, c)) inv(x, c->b[2].p, bsz(&c->b[2]));
    inv(x, c->b[3].p, bsz(&c->b[3])); /* `as` is read by fwd_h.c for the next K_GEMV */
    break;
  case K_SWIGLU:
    if (need_inv_a8(x, c)) inv(x, c->b[3].p, bsz(&c->b[3]));
    inv(x, c->b[4].p, bsz(&c->b[4]));
    break;
  case K_ACTQ:
    if (sk == SK_ACTQA) {
      if (need_inv_a8(x, c)) inv(x, c->b[1].p, bsz(&c->b[1]));
      inv(x, c->b[2].p, bsz(&c->b[2]));
    } else if (c->b[1].p == x->s->qh || x->kmode || !ip_on(x, MB_A)) {
      /* q head: read by the q record copy or the ARM attention; K, V slots: ARM attention */
      inv(x, c->b[1].p, bsz(&c->b[1]));
      inv(x, c->b[2].p, bsz(&c->b[2]));
    }
    break;
  default: /* K_ARGMAX: index from the register */
    break;
  }
  if (x->meas) {
    r.t4 = plat_now();
    r.tinv = r.t4 - t;
  }
  ip_done(x, sk, &r);
  if (x->kmode) kcmp(x, sk, c, NULL, NULL);
  return 0;
}

/* ---------------- barrier and entry ---------------- */
static int pim_route(const sx_t *x, const kcall_t *c) {
  uint32_t bit;
  const smat_t *m;
  int sk = cat_of(x, c, &bit, &m);
  (void)sk;
  return c->kid == K_GEMV && bit && ip_on(x, bit) && !x->sys->has[SLOT_GA] && guard(x, c, bit, m);
}

static int joins(const sx_t *x, const kcall_t *c) {
  if (x->at_n) {
    if (c->kid == K_ATTN2) return 1; /* attn_call itself checks layer, T and head order */
    if (c->kid == K_ACTQ && c->b[1].p == x->s->qh) return 1;
    if (FAULT(x, FX_BARRIER) && c->kid == K_ACTQ && c->b[1].p == (void *)x->s->a8) return 1;
    return 0;
  }
  if (x->pi_n)
    return pim_route(x, c) && hal_pa(c->b[2].p) == x->pi_xpa && x->xgen == x->pi_xgen;
  return 1;
}

void sx_barrier(sx_t *x) {
  if (x->at_n) attn_flush(x);
  if (x->pi_n) pim_flush(x);
}

int sx_need_barrier(sx_t *x, const kcall_t *c) {
  if (!x->at_n && !x->pi_n) return -1;
  if (joins(x, c)) return -1;
  return x->at_n ? PC_ATTN : SK_PC[x->pi_m[0]->sk];
}

static int writes_a8(const sx_t *x, const kcall_t *c) {
  return c->kid == K_RMSNORM || c->kid == K_SWIGLU ||
         (c->kid == K_ACTQ && c->b[1].p == (void *)x->s->a8);
}

int sx_exec(void *user, const kcall_t *c) {
  sx_t *x = (sx_t *)user;
  uint32_t bit;
  const smat_t *m;
  int sk = cat_of(x, c, &bit, &m);
  x->ncall[sk]++;
  if (c->kid == K_EMBED) x->fused = 0; /* first call of a forward pass */
  if ((x->at_n || x->pi_n) && !joins(x, c)) sx_barrier(x);
  hal_ctx(SK_NAME[sk], x->pos);
  /* fwd_h.c read `as` (K_GEMV xm, xe) and `qhs` (attention qm, qe) to build this call */
  if (c->kid == K_GEMV) hal_arm_rd(x->s->as, sizeof(kscl_t));
  if (c->kid == K_ATTN2 || c->kid == K_ATTN) hal_arm_rd(x->s->qhs, sizeof(kscl_t));
  if (writes_a8(x, c)) x->xgen++;
  if (bit && (x->mask & bit)) {
    if (!ip_on(x, bit) || !guard(x, c, bit, m)) {
      x->sk[sk].fb++;
      x->fb++;
      return arm_exec(x, c, sk);
    }
    if (bit & (MB_G | MB_C)) return x->sys->has[SLOT_GA] ? ga_call(x, c, sk, m) : pim_gemv(x, c, sk, m);
    if (bit & MB_A) return attn_call(x, c);
    return vec_call(x, c, sk);
  }
  return arm_exec(x, c, sk);
}
