/*
 * Build detection and model initialization of the system program (system.md 2.3):
 * IP detection from the ID slots (SYS line), matrix table, row records (rrec_pack of
 * model/src/bank.c), PIM bank bases in the order of the `vt` bimg job (per layer wq wk wv wo
 * w1 w3 w2, then cls), LDW of all matrices, availability per model (AVAIL line), and the
 * executor's buffers in the model arena (q records, run K p buffer and shadow outputs).
 */
#include <string.h>
#include "hal.h"
#include "out.h"
#include "plat.h"
#include "sx.h"

static const uint32_t IDV[SLOT_N] = {GA_ID, PI_ID, AT_ID, VE_ID};

int sys_detect(sys_t *y) {
  int k, nf = 0, other = 0;
  memset(y, 0, sizeof(*y));
  for (k = 0; k < SYS_NSLOT; k++) {
    uint32_t id = hal_rd(k, R_ID);
    if (k < SLOT_N) {
      y->id[k] = id;
      y->has[k] = id == IDV[k];
      if (y->has[k]) {
        nf++;
        y->cfg[k] = hal_rd(k, R_CONFIG);
        if (k == SLOT_PI || k == SLOT_AT) y->cfg2[k] = hal_rd(k, 0x24u);
        if (k == SLOT_AT) y->cfg3[k] = hal_rd(k, 0x28u);
      }
    } else if (id) {
      other++;
    }
  }
  y->ga_p = (int)GA_CFG_P(y->cfg[SLOT_GA]);
  y->ga_nmax = (int)GA_CFG_NMAX(y->cfg[SLOT_GA]);
  y->pi_nb = (int)PI_CFG_NB(y->cfg[SLOT_PI]);
  y->pi_lb = y->has[SLOT_PI] ? (int)PI_CFG_LB(y->cfg[SLOT_PI]) : 0;
  y->pi_nmax = (int)PI_CFG_NMAX(y->cfg[SLOT_PI]);
  y->pi_depth = (int)PI_CFG2_DEPTH(y->cfg2[SLOT_PI]);
  y->pi_cmdd = (int)PI_CFG2_CMDD(y->cfg2[SLOT_PI]);
  y->at_hpar = (int)AT_CFG_HPAR(y->cfg[SLOT_AT]);
  y->at_kvsrc = (int)AT_CFG_KVSRC(y->cfg[SLOT_AT]);
  y->at_kl = y->has[SLOT_AT] ? (int)AT_CFG_KL(y->cfg[SLOT_AT]) : 0;
  y->at_tmax = (int)AT_CFG_TMAX(y->cfg[SLOT_AT]);
  y->at_hsmax = (int)(y->cfg2[SLOT_AT] & 0xFFu);
  y->at_nkv = (int)((y->cfg2[SLOT_AT] >> 8) & 0xFFu);
  y->at_nl = (int)((y->cfg2[SLOT_AT] >> 16) & 0xFFu);
  y->at_kw = (int)(y->cfg3[SLOT_AT] & 0xFFu);
  y->at_vw = (int)((y->cfg3[SLOT_AT] >> 8) & 0xFFu);
  y->ve_nmax = (int)VE_CFG_NMAX(y->cfg[SLOT_VE]);
  y->ve_idxw = (int)VE_CFG_IDXW(y->cfg[SLOT_VE]);
  for (k = 0; k < SLOT_N; k++)
    if (y->has[k]) {
      y->fclk_mhz = (int)(y->cfg[k] & 0xFFu);
      break;
    }
  y->build = '-';
  if (y->has[SLOT_GA] && !y->has[SLOT_PI] && y->has[SLOT_AT] && y->has[SLOT_VE]) y->build = 'A';
  if (!y->has[SLOT_GA] && y->has[SLOT_PI] && y->has[SLOT_AT] && y->has[SLOT_VE]) y->build = 'P';
  {
    char b[2];
    b[0] = y->build;
    b[1] = 0;
    o_key("SYS");
    o_s("build", b);
    o_s("hal", hal_name());
    o_u("ga", (uint64_t)y->has[SLOT_GA]);
    o_u("pi", (uint64_t)y->has[SLOT_PI]);
    o_u("at", (uint64_t)y->has[SLOT_AT]);
    o_u("ve", (uint64_t)y->has[SLOT_VE]);
    o_x("id_ga", y->id[SLOT_GA]);
    o_x("id_pi", y->id[SLOT_PI]);
    o_x("id_at", y->id[SLOT_AT]);
    o_x("id_ve", y->id[SLOT_VE]);
    o_x("cfg_ga", y->cfg[SLOT_GA]);
    o_x("cfg_pi", y->cfg[SLOT_PI]);
    o_x("cfg2_pi", y->cfg2[SLOT_PI]);
    o_x("cfg_at", y->cfg[SLOT_AT]);
    o_x("cfg2_at", y->cfg2[SLOT_AT]);
    o_x("cfg3_at", y->cfg3[SLOT_AT]);
    o_x("cfg_ve", y->cfg[SLOT_VE]);
    o_u("ga_p", (uint64_t)y->ga_p);
    o_u("pi_depth", (uint64_t)y->pi_depth);
    o_u("kv_src", (uint64_t)y->at_kvsrc);
    o_u("h_par", (uint64_t)y->at_hpar);
    o_u("tmax", (uint64_t)y->at_tmax);
    o_u("hs_max", (uint64_t)y->at_hsmax);
    o_u("n_max", (uint64_t)y->ve_nmax);
    o_u("idx_w", (uint64_t)y->ve_idxw);
    o_u("fclk_mhz", (uint64_t)y->fclk_mhz);
    o_u("fclk_hz", (uint64_t)SYS_FCLK_HZ);
    o_u("other_slots", (uint64_t)other);
    o_end();
  }
  return nf;
}

void sx_dims(sx_t *x, sys_t *y, const lm_cfg_t *c, const lm_hfmt_t *f) {
  int l, k, kv;
  int fault = x->fault;
  memset(x, 0, sizeof(*x));
  x->fault = fault;
  x->sys = y;
  x->c = c;
  x->D = c->dim;
  x->H = c->hidden_dim;
  x->nh = c->n_heads;
  x->hs = c->dim / c->n_heads;
  x->nkv = c->n_kv_heads;
  x->kvmul = c->n_heads / c->n_kv_heads;
  x->L = c->n_layers;
  x->seq = c->seq_len;
  x->V = c->vocab_size;
  x->kb = f->kbits ? f->kbits : (f->kv16 ? 16 : 8);
  x->vb = f->kbits ? f->vbits : x->kb;
  x->ek = x->kb > 8 ? 2 : 1;
  x->ev = x->vb > 8 ? 2 : 1;
  x->qb = 8u + 2u * (uint32_t)x->hs;
  kv = x->hs * x->nkv;
  x->nmat = 0;
  for (l = 0; l < x->L && x->nmat + 8 <= SX_MAXMAT; l++) {
    const int r[7] = {x->D, kv, kv, x->D, x->H, x->H, x->D};
    const int n[7] = {x->D, x->D, x->D, x->D, x->D, x->D, x->H};
    const int sk[7] = {SK_GQ, SK_GK, SK_GV, SK_GO, SK_GW1, SK_GW3, SK_GW2};
    for (k = 0; k < 7; k++) {
      smat_t *m = &x->mat[x->nmat++];
      m->rows = r[k];
      m->n = n[k];
      m->sk = sk[k];
      m->base = -1;
    }
  }
  x->mat[x->nmat].rows = x->V;
  x->mat[x->nmat].n = x->D;
  x->mat[x->nmat].sk = SK_GCLS;
  x->mat[x->nmat].base = -1;
  x->nmat++;
  x->shn = 4u * (size_t)(x->V + x->H + x->D + x->seq) + 256u;
  x->kvw_l = -1;
}

void sx_layout(sx_t *x, lm_arena_t *a) {
  int i, gemv_ip = x->sys->has[SLOT_GA] || x->sys->has[SLOT_PI];
  x->rrec_bytes = 0;
  for (i = 0; i < x->nmat; i++) {
    smat_t *m = &x->mat[i];
    m->rbytes = gemv_ip ? (uint32_t)rrec_bytes(m->rows, m->n) : 0u;
    m->rrec = gemv_ip ? lm_take(a, m->rbytes) : NULL;
    x->rrec_bytes += m->rbytes;
  }
  x->qrec = lm_take(a, (size_t)x->nh * x->qb);
  x->pbuf = lm_take(a, (size_t)x->nh * 8u * (((size_t)x->seq + 1u) / 2u));
  x->shadow = lm_take(a, x->shn);
}

void sx_model(sx_t *x, const lm_hw_t *w, lm_hs_t *s) {
  int l, k, i = 0;
  x->w = w;
  x->s = s;
  for (l = 0; l < x->L; l++) {
    const lm_hm_t *m[7];
    m[0] = &w->wq[l]; m[1] = &w->wk[l]; m[2] = &w->wv[l]; m[3] = &w->wo[l];
    m[4] = &w->w1[l]; m[5] = &w->w3[l]; m[6] = &w->w2[l];
    for (k = 0; k < 7; k++, i++) {
      x->mat[i].w = m[k]->q;
      x->mat[i].ok = m[k]->gs == m[k]->n && m[k]->rows == x->mat[i].rows && m[k]->n == x->mat[i].n;
    }
  }
  x->mat[i].w = w->cls.q;
  x->mat[i].ok = w->cls.gs == w->cls.n && w->cls.rows == x->mat[i].rows && w->cls.n == x->mat[i].n;
}

static const lm_hm_t *hm_of(const sx_t *x, int i) {
  int l = i / 7, k = i % 7;
  const lm_hw_t *w = x->w;
  if (i == x->nmat - 1) return &w->cls;
  switch (k) {
  case 0: return &w->wq[l];
  case 1: return &w->wk[l];
  case 2: return &w->wv[l];
  case 3: return &w->wo[l];
  case 4: return &w->w1[l];
  case 5: return &w->w3[l];
  default: return &w->w2[l];
  }
}

static void avail_line(const sx_t *x, const char *why) {
  o_key("AVAIL");
  o_s("m", x->mname);
  o_s("v", x->vname);
  o_x("avail", x->avail);
  o_s("build", x->sys->build == 'A' ? "A" : x->sys->build == 'P' ? "P" : "-");
  o_s("why", why);
  o_u("rrec_bytes", x->rrec_bytes);
  o_i("bank_words", x->bank_words);
  o_end();
}

int sx_init(sx_t *x) {
  sys_t *y = x->sys;
  int i, err = 0;
  const lm_hfmt_t *f = &x->w->f;
  char why[64];
  why[0] = 0;
  /* buffer names for the host coherence report */
  hal_name_range(x->s->x, 4u * (size_t)x->D, "x");
  hal_name_range(x->s->x2, 4u * (size_t)x->D, "x2");
  hal_name_range(x->s->y, 4u * (size_t)x->D, "y");
  hal_name_range(x->s->q, 4u * (size_t)x->D, "q");
  hal_name_range(x->s->qr, 4u * (size_t)x->D, "qr");
  hal_name_range(x->s->k, 4u * (size_t)(x->hs * x->nkv), "k");
  hal_name_range(x->s->kr, 4u * (size_t)(x->hs * x->nkv), "kr");
  hal_name_range(x->s->v, 4u * (size_t)(x->hs * x->nkv), "v");
  hal_name_range(x->s->att, 4u * (size_t)x->D, "att");
  hal_name_range(x->s->h1, 4u * (size_t)x->H, "h1");
  hal_name_range(x->s->h3, 4u * (size_t)x->H, "h3");
  hal_name_range(x->s->logits, 4u * (size_t)x->V, "logits");
  hal_name_range(x->s->argmax, 4u, "argmax");
  hal_name_range(x->s->a8, (size_t)(x->H > x->D ? x->H : x->D), "a8");
  hal_name_range(x->s->as, 8u, "as");
  hal_name_range(x->s->qh, (size_t)x->hs * (size_t)x->ek, "qh");
  hal_name_range(x->s->qhs, 8u, "qhs");
  hal_name_range(x->s->kc, (size_t)x->L * x->nkv * x->seq * x->hs * x->ek, "kc");
  hal_name_range(x->s->vc, (size_t)x->L * x->nkv * x->seq * x->hs * x->ev, "vc");
  hal_name_range(x->s->kcs, 8u * (size_t)x->L * x->nkv * x->seq, "kcs");
  hal_name_range(x->s->vcs, 8u * (size_t)x->L * x->nkv * x->seq, "vcs");
  hal_name_range(x->qrec, (size_t)x->nh * x->qb, "qrec");
  hal_name_range(x->pbuf, (size_t)x->nh * 8u * (((size_t)x->seq + 1u) / 2u), "pbuf");

  /* 3. row records (both GEMV IPs read them) */
  if (x->mat[0].rrec) {
    uint64_t t0 = plat_now();
    for (i = 0; i < x->nmat; i++) {
      smat_t *m = &x->mat[i];
      const lm_hm_t *h = hm_of(x, i);
      if (!m->ok) continue;
      rrec_pack(m->rrec, h->q, h->m, m->rows, m->n);
      hal_name_range(m->rrec, m->rbytes, "rrec");
    }
    o_key("INIT");
    o_s("m", x->mname);
    o_s("kind", "rrec");
    o_u("ticks", plat_now() - t0);
    o_u("bytes", x->rrec_bytes);
    o_u("mats", (uint64_t)x->nmat);
    o_end();
  }
  hal_flush_all();

  /* availability (system.md 1.2, 2.3 step 2) */
  x->avail = 0;
  if (y->has[SLOT_GA] && !y->dead[SLOT_GA]) {
    x->avail |= MB_G | MB_C;
  } else if (y->has[SLOT_PI] && !y->dead[SLOT_PI]) {
    long base = 0;
    for (i = 0; i < x->nmat; i++) {
      x->mat[i].base = base;
      base += bimg_words(x->mat[i].rows, x->mat[i].n, y->pi_nb > 0 ? y->pi_nb : 1);
    }
    x->bank_words = base;
    if (y->pi_lb != BIMG_LB) strcat(why, "pi_lanes,");
    else if (base > y->pi_depth) strcat(why, "pi_depth,");
    else x->avail |= MB_G | MB_C;
    if (!(x->avail & MB_G))
      for (i = 0; i < x->nmat; i++) x->mat[i].base = -1;
  }
  if (y->has[SLOT_AT] && !y->dead[SLOT_AT]) {
    int ok = f->kbits != 0 && f->win == 0 && f->exp_bits == 8;
    if (!ok) strcat(why, "at_format,");
    if (ok && !y->at_kvsrc) {
      ok = x->hs <= y->at_kl && x->hs <= y->at_hsmax && x->nkv <= y->at_nkv && x->L <= y->at_nl &&
           x->kb <= y->at_kw && x->vb <= y->at_vw && x->seq <= y->at_tmax;
      if (!ok) strcat(why, "at_bram_kv,");
    }
    if (ok) x->avail |= MB_A;
  }
  if (y->has[SLOT_VE] && !y->dead[SLOT_VE]) x->avail |= MB_R | MB_S | MB_QH | MB_QA | MB_M;
  if (!why[0]) strcat(why, "-");
  avail_line(x, why);

  /* 4. PIM: LDW of every matrix (bank image), one time */
  if ((x->avail & MB_G) && y->has[SLOT_PI]) {
    uint64_t t0 = plat_now(), cyc = 0;
    uint32_t st[3];
    int rc = pi_ldw_all(x, &cyc, st);
    o_key("INIT");
    o_s("m", x->mname);
    o_s("kind", "ldw");
    o_u("ticks", plat_now() - t0);
    o_u("bytes", x->rrec_bytes);
    o_u("cyc", cyc);
    o_u("st_wrgb", st[0]);
    o_u("st_mac", st[1]);
    o_u("st_rdmac", st[2]);
    o_u("words", (uint64_t)x->bank_words);
    o_i("rc", rc);
    o_end();
    if (rc != DRV_OK) err++;
  }
  hal_flush_all();
  return err;
}

int sx_kv_sync(sx_t *x, int upto) {
  int l, p, err = 0;
  dres_t r;
  if (!x->sys->has[SLOT_AT] || x->sys->at_kvsrc) return 0;
  for (p = 0; p < upto; p++)
    for (l = 0; l < x->L; l++) err += at_kvw(x, l, p, &r) != DRV_OK;
  return err;
}
