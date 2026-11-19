/*
 * PC driver. All settings come from the config file (env CFG, default ./run.cfg)
 * or environment variables of the same name; nothing is passed on the command line.
 *   job eval : F vs other variants on the prompt set and the evaluation text
 *   job prof : per-kernel call count, MAC count and PC time of one H variant
 *   job dump : kernel input/output records of one H variant (RTL test vectors)
 *   job gen  : print greedy generations of one variant
 *   job ceval: per-story cross-entropy and top-1 agreement with F on the evaluation text
 *              (stories skip .. skip + nstory - 1), one line per story for paired statistics
 *   (dump keys added in S4-1: pos = position filter "a-b,c,...", only the kernel calls of the
 *    selected positions are written, every position is still computed; noeos 1 = keep
 *    generating after the BOS/EOS token so that long attention lengths are reached)
 * keys: ck tk pf ev steps nstory skip vars var out dump cap pi pos noeos
 */
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "io.h"

static FILE *OUT;
#define P(...)                                    \
  do {                                            \
    printf(__VA_ARGS__);                          \
    if (OUT) fprintf(OUT, __VA_ARGS__);           \
  } while (0)

static int load(bundle_t *b, const char *vars) {
  int rc = bundle_load(b, cfg_s("ck", ""), cfg_s("tk", ""), vars);
  if (rc) fprintf(stderr, "load failed %d\n", rc);
  return rc;
}

/* ---------------- eval ---------------- */
typedef struct {
  double maxabs, sumsq, n, top1, ntop, ce, nce, time;
  int ndiv, ncens;
  double divsum, censsum;
} acc_t;

static int split_stories(char *txt, char **st, int max) {
  int n = 0;
  char *p = txt;
  while (p && *p && n < max) {
    char *e = strstr(p, "<|endoftext|>");
    if (e) *e = 0;
    while (*p == '\n' || *p == ' ' || *p == '\r') p++;
    {
      size_t l = strlen(p);
      while (l > 0 && (p[l - 1] == '\n' || p[l - 1] == ' ' || p[l - 1] == '\r')) p[--l] = 0;
    }
    if (*p && e) st[n++] = p; /* drop the last, possibly truncated, story */
    p = e ? e + strlen("<|endoftext|>") : NULL;
  }
  return n;
}

static double ce_of(const float *l, int V, int target) {
  double mx = l[0], s = 0.0;
  int i;
  for (i = 1; i < V; i++)
    if (l[i] > mx) mx = l[i];
  for (i = 0; i < V; i++) s += exp((double)l[i] - mx);
  return log(s) + mx - (double)l[target];
}

static int job_eval(void) {
  bundle_t b;
  char **pr, *txt, *stories[4096];
  int np, ns, i, v, V, steps = (int)cfg_i("steps", 256), nst = (int)cfg_i("nstory", 32);
  float *lf, *lv;
  int *tok, *seq;
  acc_t A[MAXV];
  if (load(&b, cfg_s("vars", "F,Qr,Qg,HA,HB,HC,HD"))) return 1;
  if (strcmp(b.v[0].name, "F")) { fprintf(stderr, "first variant must be F\n"); return 1; }
  V = b.c.vocab_size;
  if (steps > b.c.seq_len) steps = b.c.seq_len;
  np = io_prompts(cfg_s("pf", ""), &pr);
  txt = io_read(cfg_s("ev", ""), NULL);
  if (np <= 0 || !txt) { fprintf(stderr, "inputs missing\n"); return 1; }
  ns = split_stories(txt, stories, 4096);
  if (ns > nst) ns = nst;
  lf = malloc(sizeof(float) * V);
  lv = malloc(sizeof(float) * V);
  tok = malloc(sizeof(int) * 65536);
  seq = malloc(sizeof(int) * (b.c.seq_len + 1));
  memset(A, 0, sizeof(A));
  P("# eval dim=%d layers=%d vocab=%d seq_len=%d steps=%d prompts=%d stories=%d\n", b.c.dim,
    b.c.n_layers, V, b.c.seq_len, steps, np, ns);
  P("# per-prompt divergence: prompt variant gen_len first_divergence(-1 none)\n");
  for (i = 0; i < np; i++) {
    int nt, pos, div[MAXV], glen = 0;
    lm_tok_encode(&b.tok, pr[i], 1, 0, tok, &nt);
    for (v = 0; v < MAXV; v++) div[v] = -1;
    seq[0] = tok[0];
    for (pos = 0; pos < steps; pos++) {
      double t0 = io_now();
      int af = bundle_step(&b, 0, seq[pos], pos, lf, NULL), next;
      A[0].time += io_now() - t0;
      next = pos < nt - 1 ? tok[pos + 1] : af;
      for (v = 1; v < b.nv; v++) {
        int av, k;
        t0 = io_now();
        av = bundle_step(&b, v, seq[pos], pos, lv, NULL);
        A[v].time += io_now() - t0;
        if (av < 0) { fprintf(stderr, "kernel error %s\n", b.v[v].name); return 1; }
        for (k = 0; k < V; k++) {
          double d = fabs((double)lv[k] - lf[k]);
          if (d > A[v].maxabs) A[v].maxabs = d;
          A[v].sumsq += d * d;
        }
        A[v].n += V;
        A[v].top1 += av == af;
        A[v].ntop += 1;
        if (pos >= nt - 1 && div[v] < 0 && av != next) div[v] = pos - (nt - 1);
      }
      if (pos >= nt - 1) glen++;
      if (next == 1) break;
      seq[pos + 1] = next;
    }
    for (v = 1; v < b.nv; v++) {
      P("div %d %s %d %d\n", i, b.v[v].name, glen, div[v]);
      if (div[v] >= 0) { A[v].ndiv++; A[v].divsum += div[v]; }
      else { A[v].ncens++; A[v].censsum += glen; }
    }
    fflush(stdout);
  }
  for (i = 0; i < ns; i++) {
    int nt, pos;
    lm_tok_encode(&b.tok, stories[i], 1, 0, tok, &nt);
    if (nt > b.c.seq_len) nt = b.c.seq_len;
    if (nt > steps) nt = steps;
    for (pos = 0; pos < nt - 1; pos++)
      for (v = 0; v < b.nv; v++) {
        bundle_step(&b, v, tok[pos], pos, lv, NULL);
        A[v].ce += ce_of(lv, V, tok[pos + 1]);
        A[v].nce += 1;
      }
  }
  P("# variant logits_maxabs logits_rms top1_pct ce dce_vs_F diverged/total mean_div_pos "
    "mean_div_pos_censored never_diverged pc_sec\n");
  for (v = 0; v < b.nv; v++) {
    acc_t *a = &A[v];
    double ce = a->nce ? a->ce / a->nce : 0, cef = A[0].nce ? A[0].ce / A[0].nce : 0;
    int tot = a->ndiv + a->ncens;
    if (v == 0) {
      P("res F - - - %.5f 0 - - - - %.1f\n", ce, a->time);
      continue;
    }
    P("res %s %.5f %.5f %.3f %.5f %+.5f %d/%d %.1f %.1f %d %.1f\n", b.v[v].name, a->maxabs,
      sqrt(a->sumsq / a->n), 100.0 * a->top1 / a->ntop, ce, ce - cef, a->ndiv, tot,
      a->ndiv ? a->divsum / a->ndiv : -1.0, tot ? (a->divsum + a->censsum) / tot : -1.0, a->ncens,
      a->time);
  }
  P("# loss tokens per variant: %.0f\n", A[0].nce);
  return 0;
}

/* ---------------- ceval ---------------- */
static int job_ceval(void) {
  bundle_t b;
  char *txt;
  static char *stories[16384];
  int ns, i, v, V, steps = (int)cfg_i("steps", 256), nst = (int)cfg_i("nstory", 32);
  int skip = (int)cfg_i("skip", 0);
  float *lf, *lv;
  int *tok;
  double t0 = io_now();
  if (load(&b, cfg_s("vars", "F,HB"))) return 1;
  if (strcmp(b.v[0].name, "F")) { fprintf(stderr, "first variant must be F\n"); return 1; }
  V = b.c.vocab_size;
  if (steps > b.c.seq_len) steps = b.c.seq_len;
  txt = io_read(cfg_s("ev", ""), NULL);
  if (!txt) { fprintf(stderr, "inputs missing\n"); return 1; }
  ns = split_stories(txt, stories, 16384);
  if (skip > ns) skip = ns;
  if (ns > skip + nst) ns = skip + nst;
  lf = malloc(sizeof(float) * V);
  lv = malloc(sizeof(float) * V);
  tok = malloc(sizeof(int) * 65536);
  P("# ceval dim=%d layers=%d vocab=%d seq_len=%d steps=%d stories=%d..%d\n", b.c.dim,
    b.c.n_layers, V, b.c.seq_len, steps, skip, ns - 1);
  P("# st index predicted_tokens sum_ce(variant...) | top1_agree_with_F(variant 1..)\n");
  P("vars");
  for (v = 0; v < b.nv; v++) P(" %s", b.v[v].name);
  P("\n");
  for (i = skip; i < ns; i++) {
    int nt, pos;
    double ce[MAXV];
    long t1[MAXV];
    if (strlen(stories[i]) > 60000) continue;
    lm_tok_encode(&b.tok, stories[i], 1, 0, tok, &nt);
    if (nt > b.c.seq_len) nt = b.c.seq_len;
    if (nt > steps) nt = steps;
    for (v = 0; v < MAXV; v++) { ce[v] = 0; t1[v] = 0; }
    for (pos = 0; pos < nt - 1; pos++) {
      int af = bundle_step(&b, 0, tok[pos], pos, lf, NULL);
      ce[0] += ce_of(lf, V, tok[pos + 1]);
      for (v = 1; v < b.nv; v++) {
        int av = bundle_step(&b, v, tok[pos], pos, lv, NULL);
        if (av < 0) { fprintf(stderr, "kernel error %s\n", b.v[v].name); return 1; }
        ce[v] += ce_of(lv, V, tok[pos + 1]);
        t1[v] += av == af;
      }
    }
    P("st %d %d", i, nt - 1);
    for (v = 0; v < b.nv; v++) P(" %.10f", ce[v]);
    P(" |");
    for (v = 1; v < b.nv; v++) P(" %ld", t1[v]);
    P("\n");
    if (OUT) fflush(OUT);
    fflush(stdout);
  }
  P("# pc_sec %.1f\n", io_now() - t0);
  return 0;
}

/* ---------------- prof ---------------- */
static int job_prof(void) {
  bundle_t b;
  char **pr;
  const char *var = cfg_s("var", "HB");
  char vars[32];
  int np, i, k, steps = (int)cfg_i("steps", 256), ntok = 0;
  float *l;
  int *tok;
  prof_t pf;
  k_hook_t hk;
  double tF = 0, tH = 0, tsum = 0;
  sprintf(vars, "F,%s", var);
  if (load(&b, vars)) return 1;
  if (steps > b.c.seq_len) steps = b.c.seq_len;
  np = io_prompts(cfg_s("pf", ""), &pr);
  np = np > (int)cfg_i("nprof", 8) ? (int)cfg_i("nprof", 8) : np;
  l = malloc(sizeof(float) * b.c.vocab_size);
  tok = malloc(sizeof(int) * 65536);
  memset(&pf, 0, sizeof(pf));
  hk.fn = prof_hook;
  hk.user = &pf;
  for (i = 0; i < np; i++) {
    int nt, pos, cur;
    lm_tok_encode(&b.tok, pr[i], 1, 0, tok, &nt);
    cur = tok[0];
    for (pos = 0; pos < steps; pos++) {
      double t0 = io_now();
      int a = bundle_step(&b, 1, cur, pos, l, &hk), next;
      tH += io_now() - t0;
      t0 = io_now();
      bundle_step(&b, 0, cur, pos, l, NULL);
      tF += io_now() - t0;
      ntok++;
      next = pos < nt - 1 ? tok[pos + 1] : a;
      if (next == 1) break;
      cur = next;
    }
  }
  for (k = 1; k < K_NKERN; k++) tsum += pf.t[k];
  P("# prof var=%s prompts=%d tokens=%d (PC x86, not ARM)\n", var, np, ntok);
  P("# kernel calls_per_token macs_per_token elems_per_token time_pct\n");
  for (k = 1; k < K_NKERN; k++)
    if (pf.calls[k])
      P("prof %s %.2f %.0f %.0f %.2f\n", k_name(k), (double)pf.calls[k] / ntok, pf.macs[k] / ntok,
        pf.elems[k] / ntok, 100.0 * pf.t[k] / tsum);
  P("# per token: H kernels %.4f ms (sum of hooks), H forward %.4f ms, F forward %.4f ms\n",
    1e3 * tsum / ntok, 1e3 * tH / ntok, 1e3 * tF / ntok);
  return 0;
}

/* ---------------- dump ---------------- */
static int job_dump(void) {
  bundle_t b;
  char **pr;
  const char *var = cfg_s("var", "HB");
  char vars[32];
  int np, pi = (int)cfg_i("pi", 0), steps = (int)cfg_i("steps", 16), nt, pos;
  int noeos = (int)cfg_i("noeos", 0);
  const char *psel = cfg_s("pos", NULL);
  long npos = 0;
  int *tok;
  dump_t d;
  sprintf(vars, "%s", var);
  if (load(&b, vars)) return 1;
  np = io_prompts(cfg_s("pf", ""), &pr);
  if (pi >= np) return 1;
  memset(&d, 0, sizeof(d));
  d.cap = (int)cfg_i("cap", 1000000);
  d.f = fopen(cfg_s("dump", "k.bin"), "wb");
  if (!d.f) return 1;
  tok = malloc(sizeof(int) * 65536);
  lm_tok_encode(&b.tok, pr[pi], 1, 0, tok, &nt);
  pos = dump_steps(&b, 0, tok, nt, steps, psel, noeos, &d, NULL, &npos);
  if (pos < 0) { fprintf(stderr, "kernel error\n"); return 1; }
  fclose(d.f);
  if (psel || noeos) P("# positions computed %d dumped %ld (pos %s)\n", pos, npos, psel ? psel : "all");
  P("dump records %ld\n", d.recs);
  return 0;
}

/* ---------------- gen ---------------- */
static int job_gen(void) {
  bundle_t b;
  char **pr;
  int np, i, steps = (int)cfg_i("steps", 256);
  float *l;
  int *tok;
  if (load(&b, cfg_s("var", "F"))) return 1;
  if (steps > b.c.seq_len) steps = b.c.seq_len;
  np = io_prompts(cfg_s("pf", ""), &pr);
  l = malloc(sizeof(float) * b.c.vocab_size);
  tok = malloc(sizeof(int) * 65536);
  for (i = 0; i < np; i++) {
    int nt, pos, cur;
    lm_tok_encode(&b.tok, pr[i], 1, 0, tok, &nt);
    cur = tok[0];
    P("[%d] ", i);
    for (pos = 0; pos < steps; pos++) {
      int a = bundle_step(&b, 0, cur, pos, l, NULL), next = pos < nt - 1 ? tok[pos + 1] : a;
      const char *pc;
      if (next == 1) break;
      pc = lm_tok_decode(&b.tok, cur, next);
      if (lm_tok_printable(pc)) P("%s", pc);
      cur = next;
    }
    P("\n");
  }
  return 0;
}

int main(void) {
  const char *job, *out;
  int rc;
  if (cfg_load()) fprintf(stderr, "no config file\n");
  job = cfg_s("job", "eval");
  out = cfg_s("out", NULL);
  if (out) OUT = fopen(out, "w");
  if (!strcmp(job, "eval")) rc = job_eval();
  else if (!strcmp(job, "prof")) rc = job_prof();
  else if (!strcmp(job, "dump")) rc = job_dump();
  else if (!strcmp(job, "gen")) rc = job_gen();
  else if (!strcmp(job, "ceval")) rc = job_ceval();
  else rc = 2;
  if (OUT) fclose(OUT);
  return rc;
}
