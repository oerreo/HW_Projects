/*
 * Baseline measurement of one model: build each variant (F, Q, H) in the model
 * memory block, then three generation runs per variant:
 *   E  end-to-end, no probes: one time stamp before and after all `steps` tokens
 *   T  per token: one time stamp pair around each forward pass (+ argmax)
 *   P  per kernel: lap probes inside the forward pass (prof.h)
 * Every run is checked against the PC expected values (expect.h).
 */
#include <string.h>
#include "bcfg.h"
#include "bench.h"
#include "llm.h"
#include "lmhash.h"
#include "out.h"
#include "plat.h"
#include "prof.h"

typedef struct {
  const exp_var_t *ev;
  lm_fs_t fs;
  lm_qw_t qw;
  lm_qs_t qs;
  lm_hfmt_t hf;
  lm_hw_t hw;
  lm_hs_t hs;
} var_t;

typedef struct {
  const exp_model_t *e;
  lm_cfg_t c;
  lm_fw_t fw;
  lm_tok_t tok;
  const void *ck, *tk;
  size_t ckn, tkn;
  var_t v[4];
} mctx_t;

static mctx_t M;
static int ptok[MAX_PTOK];
static int32_t tok_e[MAX_STEPS], tok_t[MAX_STEPS], tok_p[MAX_STEPS];
static uint32_t lh_t[MAX_STEPS], lh_p[MAX_STEPS];
static uint64_t tpos[MAX_STEPS];
static prof_t PF;
static hprof_t HPF;
static char txt[200];

static const char *const KIND_NAME[3] = {"F", "Q", "H"};

static void line_mv(const char *key, const mctx_t *m, const var_t *v) {
  o_key(key);
  o_s("m", m->e->model);
  if (v) o_s("v", v->ev->name);
}

static int sel(int i) { return (VAR_MASK >> i) & 1u; }

/* ---------------- build ---------------- */
static void var_layout(mctx_t *m, var_t *v, lm_arena_t *a) {
  const exp_var_t *ev = v->ev;
  if (ev->kind == VK_F) {
    lm_f_alloc(&v->fs, &m->c, a);
  } else if (ev->kind == VK_Q) {
    lm_q_build(&v->qw, &m->c, &m->fw, ev->qgs, a);
    lm_q_alloc(&v->qs, &m->c, a);
  } else {
    lm_h_build(&v->hw, &m->c, &m->fw, &v->hf, a);
    lm_h_alloc(&v->hs, &m->c, &v->hf, a);
  }
}

static void hf_from(lm_hfmt_t *f, const exp_var_t *ev) {
  memset(f, 0, sizeof(*f));
  f->name = ev->name;
  f->act_mode = ev->hf.act_mode;
  f->wgs = ev->hf.wgs;
  f->exp_bits = ev->hf.exp_bits;
  f->sig_bits = ev->hf.sig_bits;
  f->kv16 = ev->hf.kv16;
  f->kbits = ev->hf.kbits;
  f->vbits = ev->hf.vbits;
  f->win = ev->hf.win;
}

/* ---------------- one forward pass ---------------- */
static int fwd_plain(mctx_t *m, var_t *v, int tok, int pos, const void **lg, size_t *lgb) {
  int V = m->c.vocab_size;
  if (v->ev->kind == VK_H) {
    const int32_t *l = lm_h_forward(&v->hs, &m->c, &v->hw, tok, pos, NULL);
    if (!l) return -1;
    *lg = l;
    *lgb = 4u * (size_t)V;
    return v->hs.argmax[0];
  } else {
    const float *l = v->ev->kind == VK_F ? lm_f_forward(&v->fs, &m->c, &m->fw, tok, pos)
                                         : lm_q_forward(&v->qs, &m->c, &v->qw, tok, pos);
    *lg = l;
    *lgb = 4u * (size_t)V;
    return argmax_f(l, V);
  }
}

static int fwd_prof(mctx_t *m, var_t *v, int tok, int pos, const void **lg, size_t *lgb) {
  int V = m->c.vocab_size, am = -1;
  *lgb = 4u * (size_t)V;
  if (v->ev->kind == VK_H) {
    k_hook_t hk;
    const int32_t *l;
    hk.fn = hprof_hook;
    hk.user = &HPF;
    l = lm_h_forward(&v->hs, &m->c, &v->hw, tok, pos, &hk);
    prof_lap(&PF, PC_OTHER);
    if (!l) return -1;
    *lg = l;
    return v->hs.argmax[0];
  }
  if (v->ev->kind == VK_F)
    *lg = fq_f_forward(&v->fs, &m->c, &m->fw, tok, pos, &PF, &am);
  else
    *lg = fq_q_forward(&v->qs, &m->c, &v->qw, tok, pos, &PF, &am);
  prof_lap(&PF, PC_OTHER);
  return am;
}

static int next_tok(const exp_model_t *e, int pos, int am) {
  return pos + 1 < e->nptok ? e->ptok[pos + 1] : am;
}

/* ---------------- report helpers ---------------- */
static void put_time(uint64_t ticks, int steps) {
  uint64_t tps = plat_tps();
  o_u("ticks", ticks);
  o_q3("ms", ticks * 1000u, tps);
  o_q3("ms_tok", ticks * 1000u, tps * (uint64_t)steps);
  o_q3("tok_s", (uint64_t)steps * tps, ticks);
}

static uint64_t wavg(int a, int b) {
  uint64_t s = 0;
  int i;
  if (a < 0) a = 0;
  if (b <= a) return 0;
  for (i = a; i < b; i++) s += tpos[i];
  return s / (uint64_t)(b - a);
}

static void check_line(const mctx_t *m, const var_t *v, const char *run, int n, long tmis,
                       long hmis, int hreq, long smis, long *mis) {
  long req = tmis + (hreq ? hmis : 0) + (smis > 0 ? smis : 0);
  line_mv("CHECK", m, v);
  o_s("run", run);
  o_u("n", (uint64_t)n);
  o_i("tok_mis", tmis);
  o_i("hash_mis", hmis);
  o_u("hash_req", (uint64_t)hreq);
  if (smis >= 0) o_i("self_mis", smis);
  else o_s("self_mis", "-");
  o_s("result", req ? "FAIL" : "PASS");
  o_end();
  *mis += req;
}

static void text_line(mctx_t *m, var_t *v) {
  const exp_model_t *e = m->e;
  int pos, n = 0, cur = e->ptok[0];
  txt[0] = 0;
  for (pos = 0; pos < e->steps; pos++) {
    int nx = next_tok(e, pos, tok_e[pos]);
    if (nx >= 0 && nx < m->c.vocab_size) {
      const char *pc = lm_tok_decode(&m->tok, cur, nx);
      if (lm_tok_printable(pc))
        for (; *pc && n < (int)sizeof(txt) - 1; pc++)
          if ((unsigned char)*pc >= 0x20 && (unsigned char)*pc < 0x7F) txt[n++] = *pc;
    }
    if (n >= (int)sizeof(txt) - 1) break;
    cur = nx;
  }
  txt[n] = 0;
  line_mv("TXT", m, v);
  o_s("s", txt);
  o_end();
}

/* ---------------- runs ---------------- */
static void run_e(mctx_t *m, var_t *v, long *mis, long *err) {
  const exp_model_t *e = m->e;
  int pos, cur = e->ptok[0], bad = 0;
  long tmis = 0;
  uint64_t t0, t1;
  const void *lg;
  size_t lgb;
  plat_cache_flush();
  t0 = plat_now();
  for (pos = 0; pos < e->steps; pos++) {
    int am = fwd_plain(m, v, cur, pos, &lg, &lgb);
    if (am < 0) { bad = 1; break; }
    tok_e[pos] = am;
    cur = next_tok(e, pos, am);
  }
  t1 = plat_now();
  if (bad) { (*err)++; return; }
  line_mv("RUN", m, v);
  o_s("run", "E");
  o_u("steps", (uint64_t)e->steps);
  put_time(t1 - t0, e->steps);
  o_end();
  for (pos = 0; pos < e->steps; pos++) tmis += tok_e[pos] != v->ev->tok[pos];
  check_line(m, v, "E", e->steps, tmis, 0, 0, -1, mis);
  text_line(m, v);
}

static void run_t(mctx_t *m, var_t *v, long *mis, long *err) {
  const exp_model_t *e = m->e;
  int pos, cur = e->ptok[0], S = e->steps, mid = e->steps / 2;
  long tmis = 0, hmis = 0;
  uint64_t sum = 0;
  plat_cache_flush();
  for (pos = 0; pos < S; pos++) {
    const void *lg;
    size_t lgb;
    uint64_t t0 = plat_now(), t1;
    int am = fwd_plain(m, v, cur, pos, &lg, &lgb);
    t1 = plat_now();
    if (am < 0) { (*err)++; return; }
    tpos[pos] = t1 - t0;
    tok_t[pos] = am;
    lh_t[pos] = h_fnv(H_INIT, lg, lgb); /* outside the timed interval */
    cur = next_tok(e, pos, am);
  }
  for (pos = 0; pos < S; pos++) sum += tpos[pos];
  line_mv("RUN", m, v);
  o_s("run", "T");
  o_u("steps", (uint64_t)S);
  put_time(sum, S);
  o_end();
  if (POS_STRIDE > 0)
    for (pos = 0; pos < S; pos++)
      if (pos % POS_STRIDE == 0 || pos == S - 1) {
        line_mv("POS", m, v);
        o_u("pos", (uint64_t)pos);
        o_u("ticks", tpos[pos]);
        o_end();
      }
  line_mv("TOKPOS", m, v);
  o_u("first", tpos[0]);
  o_u("first8", wavg(0, 8));
  o_u("mid", tpos[mid]);
  o_u("mid8", wavg(mid - 4, mid + 4));
  o_u("last", tpos[S - 1]);
  o_u("last8", wavg(S - 8, S));
  o_u("mid_pos", (uint64_t)mid);
  o_q3("first_us", tpos[0] * 1000000u, plat_tps());
  o_q3("mid_us", tpos[mid] * 1000000u, plat_tps());
  o_q3("last_us", tpos[S - 1] * 1000000u, plat_tps());
  o_end();
  for (pos = 0; pos < S; pos++) {
    tmis += tok_t[pos] != v->ev->tok[pos];
    hmis += lh_t[pos] != v->ev->lh[pos];
  }
  check_line(m, v, "T", S, tmis, hmis, v->ev->kind != VK_F, -1, mis);
}

static void run_p(mctx_t *m, var_t *v, long *mis, long *err) {
  const exp_model_t *e = m->e;
  int pos, cur = e->ptok[0], k, S = e->steps;
  long tmis = 0, hmis = 0, smis = 0;
  uint64_t tot = 0, probes = 0;
  prof_clear(&PF);
  if (v->ev->kind == VK_H && hprof_setup(&HPF, &PF, &v->hw, &m->c)) { (*err)++; return; }
  plat_cache_flush();
  for (pos = 0; pos < S; pos++) {
    const void *lg;
    size_t lgb;
    int am;
    PF.last = plat_now();
    am = fwd_prof(m, v, cur, pos, &lg, &lgb);
    if (am < 0) { (*err)++; return; }
    tok_p[pos] = am;
    lh_p[pos] = h_fnv(H_INIT, lg, lgb);
    cur = next_tok(e, pos, am);
  }
  for (k = 0; k < PC_N; k++) {
    tot += PF.t[k];
    probes += PF.n[k];
  }
  for (k = 0; k < PC_N; k++) {
    if (!PF.n[k] && k != PC_OTHER) continue;
    line_mv("KERN", m, v);
    o_s("k", PC_NAME[k]);
    o_u("calls", PF.n[k]);
    o_u("ticks", PF.t[k]);
    o_q3("us_tok", PF.t[k] * 1000000u, plat_tps() * (uint64_t)S);
    o_q3("pct", PF.t[k] * 100000u, tot ? tot * 1000u : 1u);
    o_end();
  }
  line_mv("RUN", m, v);
  o_s("run", "P");
  o_u("steps", (uint64_t)S);
  put_time(tot, S);
  o_u("probes", probes);
  o_end();
  for (pos = 0; pos < S; pos++) {
    tmis += tok_p[pos] != v->ev->tok[pos];
    hmis += lh_p[pos] != v->ev->lh[pos];
    smis += (RUN_MASK & 2u) ? lh_p[pos] != lh_t[pos] : 0;
  }
  check_line(m, v, "P", S, tmis, hmis, v->ev->kind != VK_F, (RUN_MASK & 2u) ? smis : -1, mis);
}

/* ---------------- model ---------------- */
void bench_model(const exp_model_t *e, const void *ck, size_t ckn, const void *tk, size_t tkn,
                 const char *src, bres_t *r) {
  mctx_t *m = &M;
  lm_arena_t a;
  size_t cap = 0;
  uint8_t *base;
  long mis = 0, err = 0;
  int i, n, nv = 0;
  uint32_t ckh, tkh;
  memset(m, 0, sizeof(*m));
  m->e = e;
  line_mv("MODEL", m, NULL);
  o_u("dim", (uint64_t)e->dim);
  o_u("hidden", (uint64_t)e->hidden);
  o_u("layers", (uint64_t)e->layers);
  o_u("heads", (uint64_t)e->heads);
  o_u("kv_heads", (uint64_t)e->kv_heads);
  o_u("vocab", (uint64_t)e->vocab);
  o_u("seq_len", (uint64_t)e->seq_len);
  o_u("steps", (uint64_t)e->steps);
  o_u("pidx", (uint64_t)e->pidx);
  o_u("nptok", (uint64_t)e->nptok);
  o_u("corrupt", (uint64_t)e->corrupt);
  o_end();
  r->ran++;

  /* data images: header must match the model, then the hash */
  {
    uint64_t t0 = plat_now();
    int hdr_ok = 0;
    if (ck && ckn >= 28) {
      lm_cfg_t c;
      lm_fw_t fw;
      int rc = lm_ckpt_parse(ck, ckn, &c, &fw);
      hdr_ok = rc == 0 && c.dim == e->dim && c.n_layers == e->layers && c.vocab_size == e->vocab &&
               c.seq_len == e->seq_len && c.hidden_dim == e->hidden && c.n_heads == e->heads &&
               c.n_kv_heads == e->kv_heads;
    }
    ckh = hdr_ok ? h_fnv(H_INIT, ck, ckn) : 0;
    tkh = (hdr_ok && tk) ? h_fnv(H_INIT, tk, tkn) : 0;
    line_mv("DATA", m, NULL);
    o_s("src", src);
    o_u("ck_len", ckn);
    o_x("ck_hash", ckh);
    o_x("ck_exp", e->ck_hash);
    o_u("tk_len", tkn);
    o_x("tk_hash", tkh);
    o_x("tk_exp", e->tk_hash);
    o_u("hash_ticks", plat_now() - t0);
    if (!hdr_ok) {
      o_s("status", "absent");
      o_end();
      r->ran--;
      return; /* skipped: no image or a different model */
    }
    if (ckh != e->ck_hash || tkh != e->tk_hash || ckn != e->ck_len || tkn != e->tk_len) {
      o_s("status", "corrupt");
      o_end();
      r->mismatches++;
      line_mv("MSUM", m, NULL);
      o_i("mismatches", 1);
      o_i("errors", 0);
      o_s("result", "FAIL");
      o_end();
      return;
    }
    o_s("status", "ok");
    o_end();
  }
  m->ck = ck;
  m->tk = tk;
  m->ckn = ckn;
  m->tkn = tkn;
  if (lm_ckpt_parse(ck, ckn, &m->c, &m->fw)) { err++; goto done; }

  for (i = 0; i < e->nvar && i < 4; i++) {
    m->v[i].ev = &e->var[i];
    if (e->var[i].kind == VK_H) hf_from(&m->v[i].hf, &e->var[i]);
  }
  /* sizing pass, then the block, then the filling pass (timed per variant) */
  memset(&a, 0, sizeof(a));
  if (lm_tok_init(&m->tok, tk, tkn, m->c.vocab_size, &a)) { err++; goto done; }
  for (i = 0; i < e->nvar && i < 4; i++)
    if (sel(i)) var_layout(m, &m->v[i], &a);
  base = (uint8_t *)plat_arena(a.off + 64u, &cap);
  line_mv("ARENA", m, NULL);
  o_u("need", (uint64_t)(a.off + 64u));
  o_u("cap", (uint64_t)cap);
  o_s("status", base ? "ok" : "too_small");
  o_end();
  if (!base) { err++; goto done; }
  memset(&a, 0, sizeof(a));
  a.base = base;
  a.cap = cap;
  if (lm_tok_init(&m->tok, tk, tkn, m->c.vocab_size, &a)) { err++; goto done; }
  line_mv("TOKMEM", m, NULL);
  o_u("bytes", (uint64_t)a.off);
  o_end();
  for (i = 0; i < e->nvar && i < 4; i++) {
    var_t *v = &m->v[i];
    uint64_t t0, t1;
    uint32_t wh = 0;
    long wmis = 0;
    size_t off0 = a.off;
    if (!sel(i)) continue;
    t0 = plat_now();
    var_layout(m, v, &a);
    t1 = plat_now();
    if (a.fail) { err++; goto done; }
    if (v->ev->kind == VK_Q) wh = h_qweights(&v->qw, &m->c);
    if (v->ev->kind == VK_H) wh = h_hweights(&v->hw, &m->c);
    wmis = wh != v->ev->whash;
    line_mv("VAR", m, v);
    o_s("kind", KIND_NAME[v->ev->kind]);
    o_u("init_ticks", t1 - t0);
    o_q3("init_ms", (t1 - t0) * 1000u, plat_tps());
    o_u("bytes", (uint64_t)(a.off - off0));
    o_x("whash", wh);
    o_x("whash_exp", v->ev->whash);
    o_i("wmis", wmis);
    o_end();
    mis += wmis;
    if (v->ev->kind == VK_H) {
      int hs = m->c.dim / m->c.n_heads, j, nr = m->c.seq_len * hs, diff = 0;
      uint32_t rh = h_fnv(H_INIT, v->hw.rope, sizeof(int16_t) * (size_t)nr);
      if (nr != e->rope_n) { err++; goto done; }
      for (j = 0; j < nr; j++) diff += v->hw.rope[j] != e->rope[j];
      if (diff && ROPE_FROM_PC) memcpy(v->hw.rope, e->rope, sizeof(int16_t) * (size_t)nr);
      line_mv("ROPE", m, v);
      o_x("hash", rh);
      o_x("hash_exp", e->rope_hash);
      o_u("diff", (uint64_t)diff);
      o_u("replaced", (uint64_t)(diff && ROPE_FROM_PC));
      o_end();
      if (diff && !ROPE_FROM_PC) mis++;
    }
    nv++;
  }

  /* prompt encoding */
  if (strlen(e->prompt) + 3 > MAX_PTOK || e->steps > MAX_STEPS || e->steps < 8) { err++; goto done; }
  lm_tok_encode(&m->tok, e->prompt, 1, 0, ptok, &n);
  {
    long pm = n != e->nptok;
    for (i = 0; i < n && i < e->nptok; i++) pm += ptok[i] != e->ptok[i];
    line_mv("PROMPT", m, NULL);
    o_u("n", (uint64_t)n);
    o_u("n_exp", (uint64_t)e->nptok);
    o_i("mis", pm);
    o_end();
    mis += pm;
  }

  for (i = 0; i < e->nvar && i < 4; i++) {
    var_t *v = &m->v[i];
    if (!sel(i)) continue;
    if (RUN_MASK & 1u) run_e(m, v, &mis, &err);
    if (RUN_MASK & 2u) run_t(m, v, &mis, &err);
    if (RUN_MASK & 4u) run_p(m, v, &mis, &err);
  }
done:
  line_mv("MSUM", m, NULL);
  o_u("variants", (uint64_t)nv);
  o_i("mismatches", mis);
  o_i("errors", err);
  o_s("result", (mis || err) ? "FAIL" : "PASS");
  o_end();
  r->mismatches += mis;
  r->errors += err;
}

/* ---------------- overhead ---------------- */
void bench_overhead(void) {
  int i;
  uint64_t mn = ~(uint64_t)0, sum = 0, t0, t1;
  uint32_t c0, c1;
  prof_t p;
  hprof_t h;
  kcall_t kc;
  uint64_t tps = plat_tps();

  /* CPU clock from the cycle counter over 0.1 s of the time base */
  c0 = plat_cyc();
  t0 = plat_now();
  while ((t1 = plat_now()) - t0 < tps / 10u) {
  }
  c1 = plat_cyc();
  o_key("CLK");
  o_u("tps", tps);
  o_u("cyc_per_100ms", (uint64_t)(uint32_t)(c1 - c0));
  o_u("ticks", t1 - t0);
  o_end();

  for (i = 0; i < OVH_N; i++) {
    uint64_t a = plat_now(), b = plat_now();
    if (b - a < mn) mn = b - a;
    sum += b - a;
  }
  o_key("OVH");
  o_s("kind", "timer_pair");
  o_u("n", OVH_N);
  o_u("min_ticks", mn);
  o_q3("avg_ticks", sum, OVH_N);
  o_end();

  prof_clear(&p);
  p.last = plat_now();
  t0 = plat_now();
  c0 = plat_cyc();
  for (i = 0; i < OVH_N; i++) prof_lap(&p, PC_OTHER);
  c1 = plat_cyc();
  t1 = plat_now();
  o_key("OVH");
  o_s("kind", "lap");
  o_u("n", OVH_N);
  o_q3("avg_ticks", t1 - t0, OVH_N);
  o_q3("avg_cyc", (uint32_t)(c1 - c0), OVH_N);
  o_end();

  prof_clear(&p);
  memset(&h, 0, sizeof(h));
  h.p = &p;
  memset(&kc, 0, sizeof(kc));
  kc.kid = K_ADD;
  for (i = 0; i < 32; i++) h.kmap[i] = PC_ADD;
  p.last = plat_now();
  t0 = plat_now();
  c0 = plat_cyc();
  for (i = 0; i < OVH_N; i++) {
    hprof_hook(&h, 0, &kc);
    hprof_hook(&h, 1, &kc);
  }
  c1 = plat_cyc();
  t1 = plat_now();
  o_key("OVH");
  o_s("kind", "hook_pair");
  o_u("n", OVH_N);
  o_q3("avg_ticks", t1 - t0, OVH_N);
  o_q3("avg_cyc", (uint32_t)(c1 - c0), OVH_N);
  o_end();
}
