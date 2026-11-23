/*
 * System measurement of one model (system.md 2.1 sbench, 2.6, 2.7): build the H variant of the
 * expected header (K12V8), initialize the executor (row records, PIM bank load), then for every
 * (mask, opt) of the run list the runs
 *   E  end-to-end, minimal drivers, tokens checked
 *   T  per token time, tokens + logits hash
 *   P  lap probes (KERN) + per-category split (KSPLIT), tokens + hash
 *   K  every IP call compared with k_exec on shadow outputs (KCMP), tokens + hash
 *   W  warm start: positions 0 .. S-2 with mask 0, then KVW sync and position S-1 with the mask
 * Every run starts with a full D-cache flush. Log lines: fpga/sys/README.md.
 */
#include <stdlib.h>
#include <string.h>
#include "hal.h"
#include "lmhash.h"
#include "out.h"
#include "plat.h"
#include "prof.h"
#include "sbench.h"
#include "sx.h"

static sx_t SX;
static lm_cfg_t C;
static lm_fw_t FW;
static lm_tok_t TOK;
static lm_hfmt_t HF;
static lm_hw_t HW;
static lm_hs_t HS;
static int ptok[SYS_MAX_PTOK];
static int32_t tok_r[SYS_MAX_STEPS];
static uint32_t lh_r[SYS_MAX_STEPS];
static prof_t PF;
static hprof_t HPF;
static const exp_model_t *E_;
static const exp_var_t *EV;

static void line_m(const char *key) {
  o_key(key);
  o_s("m", E_->model);
  if (EV) o_s("v", EV->name);
}
static void line_r(const char *key, int kind) {
  line_m(key);
  o_s("run", RK_NAME[kind]);
  o_x("mask", SX.mask);
  o_x("opt", SX.opt);
}

/* ---------------- run list (compile time; host: SX_LIST, SX_RUNS, SX_STEPS) ---------------- */
static const uint32_t LIST0[] = {SYS_MASK_LIST};

static int run_list(uint32_t *list) {
  const char *s = hal_env("SX_LIST");
  int n = 0;
  if (!s) {
    for (n = 0; n < (int)(sizeof(LIST0) / sizeof(LIST0[0])) && n < SYS_MAX_RUNS; n++) list[n] = LIST0[n];
    return n;
  }
  while (*s && n < SYS_MAX_RUNS) { /* "mask:opt,mask:opt" in hex */
    char *e;
    unsigned long m = strtoul(s, &e, 16), o = OPT_DEFAULT;
    if (e == s) break;
    s = e;
    if (*s == ':') {
      o = strtoul(s + 1, &e, 16);
      s = e;
    }
    list[n++] = (uint32_t)(m & 0xFFu) | (uint32_t)((o & 0xFFu) << 8);
    while (*s == ',' || *s == ' ') s++;
  }
  return n;
}

static uint32_t run_kinds(void) {
  const char *s = hal_env("SX_RUNS");
  uint32_t r = 0;
  if (!s) return SYS_RUN_MASK;
  for (; *s; s++) {
    const char *p = strchr("ETPKW", *s);
    if (p) r |= 1u << (p - "ETPKW");
  }
  return r;
}

static int run_steps(void) {
  const char *s = hal_env("SX_STEPS");
  int n = s ? atoi(s) : SYS_STEPS;
  if (n <= 0 || n > E_->steps) n = E_->steps;
  return n;
}

/* ---------------- forward pass ---------------- */
static void phook(void *u, int phase, const kcall_t *c) {
  (void)u;
  if (phase == 0) { /* a deferred batch that must run first is charged to its own category */
    int k = sx_need_barrier(&SX, c);
    if (k >= 0) {
      prof_lap(&PF, PC_OTHER);
      sx_barrier(&SX);
      prof_lap(&PF, k);
    }
  }
  hprof_hook(&HPF, phase, c);
}

static long pend_err;

static int fwd(int tok, int pos, const k_hook_t *hk) {
  k_exec_t ex;
  const int32_t *l;
  ex.fn = sx_exec;
  ex.user = &SX;
  SX.pos = pos;
  l = lm_h_forward_x(&HS, &C, &HW, tok, pos, hk, &ex);
  if (SX.at_n || SX.pi_n) { /* argmax is the last call and a barrier: nothing may be left */
    pend_err++;
    sx_barrier(&SX);
  }
  if (!l) return -1;
  hal_arm_rd(HS.argmax, 4);
  return HS.argmax[0];
}

static int next_tok(int pos, int am) { return pos + 1 < E_->nptok ? E_->ptok[pos + 1] : am; }

static void put_time(uint64_t ticks, int steps) {
  uint64_t tps = plat_tps();
  o_u("ticks", ticks);
  o_q3("ms", ticks * 1000u, tps);
  o_q3("ms_tok", ticks * 1000u, tps * (uint64_t)steps);
  o_q3("tok_s", (uint64_t)steps * tps, ticks ? ticks : 1u);
}

static void ksplit_lines(void) {
  int k;
  for (k = 0; k < SK_N; k++) {
    const sk_t *s = &SX.sk[k];
    if (!s->ip && !s->arm && !s->fb && !s->ops) continue;
    line_r("KSPLIT", RK_P);
    o_s("k", SK_NAME[k]);
    o_u("calls_ip", (uint64_t)s->ip);
    o_u("calls_arm", (uint64_t)s->arm);
    o_u("calls_fb", (uint64_t)s->fb);
    o_i("arm", s->t_arm);
    o_i("pl", s->t_pl);
    o_i("mv", s->t_mv);
    o_i("call", s->t_call);
    o_u("cyc", s->cyc);
    o_u("rd_stall", s->rd);
    o_u("wr_stall", s->wr);
    o_u("ops", (uint64_t)s->ops);
    o_end();
  }
}

static void kcmp_lines(void) {
  int k;
  for (k = 0; k < SK_N; k++) {
    const kc_t *c = &SX.kc[k];
    if (!c->calls) continue;
    line_r("KCMP", RK_K);
    o_s("k", SK_NAME[k]);
    o_u("calls", (uint64_t)c->calls);
    o_u("mis", (uint64_t)c->mis);
    o_i("first_pos", c->mis ? c->first_pos : -1);
    o_i("first_call", c->mis ? c->first_call : -1);
    o_i("first_idx", c->mis ? c->first_idx : -1);
    o_i("exp", c->exp);
    o_i("got", c->got);
    o_end();
    SX.kmis += c->mis;
  }
}

/* one run; returns the number of failed requirements */
static long run_one(int kind, uint32_t mask, uint32_t opt, int S) {
  int pos, cur = E_->ptok[0], k;
  long tmis = 0, hmis = 0, req;
  uint64_t t0, t1, tot = 0, probes = 0;
  hal_coh_t coh;
  k_hook_t hk;
  memset(&coh, 0, sizeof(coh));
  sx_run_begin(&SX, kind == RK_W ? 0u : mask, opt, kind);
  hal_coh_get(&coh, 1);
  pend_err = 0;
  if (kind == RK_P) {
    prof_clear(&PF);
    if (hprof_setup(&HPF, &PF, &HW, &C)) return 1;
    hk.fn = phook;
    hk.user = NULL;
  }
  hal_flush_all(); /* system.md 2.2 cache rule 1 */
  t0 = plat_now();
  for (pos = 0; pos < S; pos++) {
    int am;
    uint64_t a = 0;
    if (kind == RK_W && pos == S - 1) { /* warm start: switch from ARM to the mask here */
      hal_flush_all();
      SX.mask = mask;
      if (mask & MB_A) sx_kv_sync(&SX, pos);
    }
    if (kind == RK_P) PF.last = plat_now();
    if (kind == RK_T) a = plat_now();
    am = fwd(cur, pos, kind == RK_P ? &hk : NULL);
    if (kind == RK_T) tot += plat_now() - a;
    if (kind == RK_P) prof_lap(&PF, PC_OTHER);
    if (am < 0) break;
    tok_r[pos] = am;
    if (kind != RK_E) {
      hal_arm_rd(HS.logits, 4u * (size_t)C.vocab_size);
      lh_r[pos] = h_fnv(H_INIT, HS.logits, 4u * (size_t)C.vocab_size);
    }
    cur = next_tok(pos, am);
  }
  t1 = plat_now();
  SX.mask = mask;
  if (pos < S) {
    line_r("RUN", kind);
    o_s("status", "kernel_error");
    o_i("pos", pos);
    o_end();
    return 1;
  }
  if (kind == RK_E || kind == RK_K || kind == RK_W) tot = t1 - t0;
  if (kind == RK_P) {
    for (k = 0; k < PC_N; k++) {
      tot += PF.t[k];
      probes += PF.n[k];
    }
    for (k = 0; k < PC_N; k++) {
      if (!PF.n[k] && k != PC_OTHER) continue;
      line_r("KERN", kind);
      o_s("k", PC_NAME[k]);
      o_u("calls", PF.n[k]);
      o_u("ticks", PF.t[k]);
      o_q3("us_tok", PF.t[k] * 1000000u, plat_tps() * (uint64_t)S);
      o_q3("pct", PF.t[k] * 100000u, tot ? tot * 1000u : 1u);
      o_end();
    }
    ksplit_lines();
  }
  if (kind == RK_K) kcmp_lines();
  line_r("RUN", kind);
  o_u("steps", (uint64_t)S);
  put_time(tot, S);
  if (kind == RK_P) o_u("probes", probes);
  o_u("ip_ops", (uint64_t)SX.nops);
  o_end();
  hal_coh_get(&coh, 0);
  if (coh.n || coh.old) {
    line_r("COH", kind);
    o_u("n", (uint64_t)coh.n);
    o_u("old", (uint64_t)coh.old);
    o_s("kind", coh.kind);
    o_s("what", coh.what);
    o_s("k", coh.ctx);
    o_i("pos", coh.pos);
    o_x("addr", coh.addr);
    o_end();
  }
  for (pos = 0; pos < S; pos++) {
    tmis += tok_r[pos] != EV->tok[pos];
    if (kind != RK_E) hmis += lh_r[pos] != EV->lh[pos];
  }
  req = tmis + hmis + SX.kmis + coh.n + SX.fb + SX.iperr + pend_err;
  line_r("CHECK", kind);
  o_u("n", (uint64_t)S);
  o_i("tok_mis", tmis);
  o_i("hash_mis", hmis);
  o_u("hash_req", (uint64_t)(kind != RK_E));
  o_i("kmis", SX.kmis);
  o_i("coh", coh.n);
  o_i("fb", SX.fb);
  o_i("iperr", SX.iperr + pend_err);
  o_s("result", req ? "FAIL" : "PASS");
  o_end();
  return req ? 1 : 0;
}

/* ---------------- model ---------------- */
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

static int sys_fault(void) {
#if SX_FAULT_INJ
  const char *s = hal_env("SX_FAULT");
  return s ? atoi(s) : 0;
#else
  return 0;
#endif
}

void sbench_model(const exp_model_t *e, sys_t *y, const void *ck, size_t ckn, const void *tk,
                  size_t tkn, const char *src, sres_t *r) {
  lm_arena_t a;
  size_t cap = 0;
  uint8_t *base;
  long mis = 0, err = 0;
  int i, n, S, nl, nrun = 0, nskip = 0;
  uint32_t list[SYS_MAX_RUNS], kinds;
  E_ = e;
  EV = NULL;
  line_m("MODEL");
  o_u("dim", (uint64_t)e->dim);
  o_u("hidden", (uint64_t)e->hidden);
  o_u("layers", (uint64_t)e->layers);
  o_u("heads", (uint64_t)e->heads);
  o_u("kv_heads", (uint64_t)e->kv_heads);
  o_u("vocab", (uint64_t)e->vocab);
  o_u("seq_len", (uint64_t)e->seq_len);
  o_u("steps", (uint64_t)e->steps);
  o_end();
  r->ran++;
  {
    int ok = 0;
    uint32_t ckh = 0, tkh = 0;
    if (ck && ckn >= 28) {
      lm_cfg_t c;
      lm_fw_t fw;
      ok = lm_ckpt_parse(ck, ckn, &c, &fw) == 0 && c.dim == e->dim && c.n_layers == e->layers &&
           c.vocab_size == e->vocab && c.seq_len == e->seq_len && c.hidden_dim == e->hidden &&
           c.n_heads == e->heads && c.n_kv_heads == e->kv_heads;
    }
    if (ok) {
      ckh = h_fnv(H_INIT, ck, ckn);
      tkh = tk ? h_fnv(H_INIT, tk, tkn) : 0;
    }
    line_m("DATA");
    o_s("src", src);
    o_u("ck_len", ckn);
    o_x("ck_hash", ckh);
    o_x("ck_exp", e->ck_hash);
    o_x("tk_hash", tkh);
    o_x("tk_exp", e->tk_hash);
    if (!ok) {
      o_s("status", "absent");
      o_end();
      r->ran--;
      return;
    }
    if (ckh != e->ck_hash || tkh != e->tk_hash || ckn != e->ck_len || tkn != e->tk_len) {
      o_s("status", "corrupt");
      o_end();
      r->mismatches++;
      line_m("MSUM");
      o_i("mismatches", 1);
      o_i("errors", 0);
      o_s("result", "FAIL");
      o_end();
      return;
    }
    o_s("status", "ok");
    o_end();
  }
  for (i = 0; i < e->nvar && i < 4; i++)
    if (e->var[i].kind == VK_H) EV = &e->var[i];
  if (!EV || lm_ckpt_parse(ck, ckn, &C, &FW)) { err++; goto done; }
  hf_from(&HF, EV);
  SX.fault = sys_fault();
  sx_dims(&SX, y, &C, &HF);
  /* sizing pass */
  memset(&a, 0, sizeof(a));
  if (lm_tok_init(&TOK, tk, tkn, C.vocab_size, &a)) { err++; goto done; }
  lm_h_build(&HW, &C, &FW, &HF, &a);
  lm_h_alloc(&HS, &C, &HF, &a);
  sx_layout(&SX, &a);
  base = (uint8_t *)hal_arena(a.off + 64u, &cap);
  line_m("ARENA");
  o_u("need", (uint64_t)(a.off + 64u));
  o_u("cap", (uint64_t)cap);
  o_s("status", base ? "ok" : "too_small");
  o_end();
  if (!base) { err++; goto done; }
  /* filling pass */
  memset(&a, 0, sizeof(a));
  a.base = base;
  a.cap = cap;
  if (lm_tok_init(&TOK, tk, tkn, C.vocab_size, &a)) { err++; goto done; }
  {
    uint64_t t0 = plat_now(), t1;
    uint32_t wh;
    size_t off0 = a.off;
    int hs = C.dim / C.n_heads, nr = C.seq_len * hs, diff = 0, j;
    lm_h_build(&HW, &C, &FW, &HF, &a);
    t1 = plat_now();
    lm_h_alloc(&HS, &C, &HF, &a);
    sx_layout(&SX, &a);
    if (a.fail) { err++; goto done; }
    wh = h_hweights(&HW, &C);
    line_m("VAR");
    o_s("kind", "H");
    o_u("init_ticks", t1 - t0);
    o_u("bytes", (uint64_t)(a.off - off0));
    o_x("whash", wh);
    o_x("whash_exp", EV->whash);
    o_i("wmis", wh != EV->whash);
    o_end();
    mis += wh != EV->whash;
    if (nr != e->rope_n) { err++; goto done; }
    for (j = 0; j < nr; j++) diff += HW.rope[j] != e->rope[j];
    if (diff && SYS_ROPE_FROM_PC) memcpy(HW.rope, e->rope, sizeof(int16_t) * (size_t)nr);
    line_m("ROPE");
    o_u("diff", (uint64_t)diff);
    o_u("replaced", (uint64_t)(diff && SYS_ROPE_FROM_PC));
    o_end();
    if (diff && !SYS_ROPE_FROM_PC) mis++;
  }
  SX.mname = e->model;
  SX.vname = EV->name;
  sx_model(&SX, &HW, &HS);
  err += sx_init(&SX);
  if (strlen(e->prompt) + 3 > SYS_MAX_PTOK || e->steps > SYS_MAX_STEPS) { err++; goto done; }
  lm_tok_encode(&TOK, e->prompt, 1, 0, ptok, &n);
  {
    long pm = n != e->nptok;
    for (i = 0; i < n && i < e->nptok; i++) pm += ptok[i] != e->ptok[i];
    line_m("PROMPT");
    o_u("n", (uint64_t)n);
    o_u("n_exp", (uint64_t)e->nptok);
    o_i("mis", pm);
    o_end();
    mis += pm;
  }
  S = run_steps();
  nl = run_list(list);
  kinds = run_kinds();
  for (i = 0; i < nl; i++) {
    uint32_t mask = list[i] & 0xFFu, opt = list[i] >> 8;
    int k;
    if (mask & ~SX.avail) {
      line_m("SKIP");
      o_x("mask", mask);
      o_x("opt", opt);
      o_x("avail", SX.avail);
      o_end();
      nskip++;
      continue;
    }
    for (k = 0; k < RK_N; k++)
      if ((kinds >> k) & 1u) {
        mis += run_one(k, mask, opt, S);
        nrun++;
      }
  }
done:
  line_m("MSUM");
  o_u("runs", (uint64_t)nrun);
  o_u("skipped", (uint64_t)nskip);
  o_i("mismatches", mis);
  o_i("errors", err);
  o_s("result", (mis || err) ? "FAIL" : "PASS");
  o_end();
  r->mismatches += mis;
  r->errors += err;
}
