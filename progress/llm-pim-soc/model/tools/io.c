/* PC-side helpers (file I/O and the single allocation of the model memory). */
#define _POSIX_C_SOURCE 200809L
#include "io.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>

void *io_read(const char *path, size_t *len) {
  FILE *f = fopen(path, "rb");
  char *p;
  long n;
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  n = ftell(f);
  fseek(f, 0, SEEK_SET);
  p = malloc((size_t)n + 1);
  if (!p || fread(p, 1, (size_t)n, f) != (size_t)n) {
    fclose(f);
    free(p);
    return NULL;
  }
  p[n] = 0;
  fclose(f);
  if (len) *len = (size_t)n;
  return p;
}

double io_now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec * 1e-9;
}

/* ---------------- config ---------------- */
#define CFG_MAX 64
static char cfg_k[CFG_MAX][32], cfg_v[CFG_MAX][256];
static int cfg_n;

int cfg_load(void) {
  const char *path = getenv("CFG");
  char *txt, *line, *save = NULL;
  if (!path) path = "run.cfg";
  txt = io_read(path, NULL);
  if (!txt) return -1;
  for (line = strtok_r(txt, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
    char k[32], v[256];
    if (line[0] == '#') continue;
    v[0] = 0;
    if (sscanf(line, "%31s %255[^\n]", k, v) >= 1 && cfg_n < CFG_MAX) {
      strcpy(cfg_k[cfg_n], k);
      strcpy(cfg_v[cfg_n], v);
      cfg_n++;
    }
  }
  free(txt);
  return 0;
}

const char *cfg_s(const char *key, const char *def) {
  int i;
  const char *e = getenv(key); /* environment overrides the file */
  if (e) return e;
  for (i = cfg_n - 1; i >= 0; i--)
    if (!strcmp(cfg_k[i], key)) return cfg_v[i];
  return def;
}

long cfg_i(const char *key, long def) {
  const char *s = cfg_s(key, NULL);
  return s ? atol(s) : def;
}

int io_prompts(const char *path, char ***out) {
  char *txt = io_read(path, NULL), *p, **v;
  int n = 0, cap = 0;
  if (!txt) return -1;
  v = NULL;
  p = txt;
  while (*p) {
    char *e = strchr(p, '\n');
    if (e) *e = 0;
    if (*p && *p != '#') {
      if (n == cap) {
        cap = cap ? cap * 2 : 64;
        v = realloc(v, sizeof(char *) * cap);
      }
      v[n++] = strdup(strcmp(p, "<EMPTY>") ? p : "");
    }
    if (!e) break;
    p = e + 1;
  }
  free(txt);
  *out = v;
  return n;
}

/* ---------------- formats ---------------- */
/*                    name  act       wgs exp sig kv16 kbits vbits win */
static const lm_hfmt_t FMTS[] = {
    {"HA", ACT_POW2, 0, 4, 5, 0, 0, 0, 0},  /* cheapest: shift-only activation scales, small LUTs */
    {"HB", ACT_MANT, 0, 8, 8, 0, 0, 0, 0},  /* mantissa activation scales, row-wise weight scale */
    {"HC", ACT_MANT, 64, 8, 8, 0, 0, 0, 0}, /* HB with weight groups (divisor of row <= 64) */
    {"HD", ACT_MANT, 0, 8, 8, 1, 0, 0, 0},  /* HB with int16 q, k, v in attention */
    {"HE", ACT_POW2, 0, 8, 8, 0, 0, 0, 0},  /* HB with shift-only activation scales */
    {"HF", ACT_MANT, 0, 4, 5, 0, 0, 0, 0},  /* HB with small LUTs */
    {"HG", ACT_MANT, 0, 4, 5, 1, 0, 0, 0},  /* HD with small LUTs */
    {"HH", ACT_MANT, 64, 4, 5, 1, 0, 0, 0}, /* HG with weight groups */
    /* S2b: fields after kv16 are kbits, vbits (0: from kv16) and win (attention window, 0 = all) */
    {"HI", ACT_MANT, 64, 8, 8, 1, 0, 0, 0},  /* HD with weight groups (HH with 8-bit LUTs) */
    /* HB/HD base (MANT, row-wise weight scale, 8-bit LUTs), q and K kbits, V vbits */
    {"K8V8", ACT_MANT, 0, 8, 8, 0, 8, 8, 0},    /* == HB through K_ATTN2 */
    {"K8V12", ACT_MANT, 0, 8, 8, 0, 8, 12, 0},
    {"K8V16", ACT_MANT, 0, 8, 8, 0, 8, 16, 0},
    {"K12V8", ACT_MANT, 0, 8, 8, 0, 12, 8, 0},
    {"K12V12", ACT_MANT, 0, 8, 8, 0, 12, 12, 0},
    {"K12V16", ACT_MANT, 0, 8, 8, 0, 12, 16, 0},
    {"K16V8", ACT_MANT, 0, 8, 8, 0, 16, 8, 0},
    {"K16V12", ACT_MANT, 0, 8, 8, 0, 16, 12, 0},
    {"K16V16", ACT_MANT, 0, 8, 8, 0, 16, 16, 0}, /* == HD through K_ATTN2 */
    {"K12V8s", ACT_MANT, 0, 4, 5, 0, 12, 8, 0},  /* K12V8 with small LUTs (4/5-bit, as HF) */
    /* attention window (sliding, the KV cache keeps only the last win positions) */
    {"HBw256", ACT_MANT, 0, 8, 8, 0, 8, 8, 256},
    {"HBw128", ACT_MANT, 0, 8, 8, 0, 8, 8, 128},
    {"HBw64", ACT_MANT, 0, 8, 8, 0, 8, 8, 64},
    {"HDw256", ACT_MANT, 0, 8, 8, 0, 16, 16, 256},
    {"HDw128", ACT_MANT, 0, 8, 8, 0, 16, 16, 128},
    {"HDw64", ACT_MANT, 0, 8, 8, 0, 16, 16, 64},
    {"K12V12w256", ACT_MANT, 0, 8, 8, 0, 12, 12, 256},
    {"K12V12w128", ACT_MANT, 0, 8, 8, 0, 12, 12, 128},
    {"K8V12w256", ACT_MANT, 0, 8, 8, 0, 8, 12, 256},
    {"K8V12w128", ACT_MANT, 0, 8, 8, 0, 8, 12, 128},
};
const char *FMT_NAMES[] = {"HA", "HB", "HC", "HD", "HE", "HF", "HG", "HH", NULL};

int fmt_lookup(const char *name, lm_hfmt_t *f) {
  size_t i;
  for (i = 0; i < sizeof(FMTS) / sizeof(FMTS[0]); i++)
    if (!strcmp(FMTS[i].name, name)) {
      *f = FMTS[i];
      return 0;
    }
  return -1;
}

/* ---------------- bundle ---------------- */
static int bundle_layout(bundle_t *b, lm_arena_t *a) {
  int i;
  if (lm_tok_init(&b->tok, b->tk, b->tkn, b->c.vocab_size, a)) return -1;
  for (i = 0; i < b->nv; i++) {
    variant_t *v = &b->v[i];
    if (v->kind == VK_F) {
      lm_f_alloc(&v->fs, &b->c, a);
    } else if (v->kind == VK_Q) {
      lm_q_build(&v->qw, &b->c, &b->fw, !strcmp(v->name, "Qr") ? 0 : 64, a);
      lm_q_alloc(&v->qs, &b->c, a);
    } else {
      lm_h_build(&v->hw, &b->c, &b->fw, &v->hf, a);
      lm_h_alloc(&v->hs, &b->c, &v->hf, a);
    }
  }
  return a->fail ? -1 : 0;
}

int bundle_load(bundle_t *b, const char *ck, const char *tk, const char *vars) {
  char buf[256], *tok, *save = NULL;
  lm_arena_t a;
  memset(b, 0, sizeof(*b));
  b->ck = io_read(ck, &b->ckn);
  b->tk = io_read(tk, &b->tkn);
  if (!b->ck || !b->tk) return -1;
  if (lm_ckpt_parse(b->ck, b->ckn, &b->c, &b->fw)) return -2;
  strncpy(buf, vars, sizeof(buf) - 1);
  buf[sizeof(buf) - 1] = 0;
  for (tok = strtok_r(buf, ",", &save); tok && b->nv < MAXV; tok = strtok_r(NULL, ",", &save)) {
    variant_t *v = &b->v[b->nv];
    strncpy(v->name, tok, sizeof(v->name) - 1);
    if (!strcmp(tok, "F")) v->kind = VK_F;
    else if (!strcmp(tok, "Qr") || !strcmp(tok, "Qg")) v->kind = VK_Q;
    else if (!fmt_lookup(tok, &v->hf)) v->kind = VK_H;
    else return -3;
    b->nv++;
  }
  memset(&a, 0, sizeof(a));
  if (bundle_layout(b, &a)) return -4;
  b->memn = a.off + 64;
  b->mem = malloc(b->memn); /* the only allocation of model memory */
  if (!b->mem) return -5;
  memset(&a, 0, sizeof(a));
  a.base = b->mem;
  a.cap = b->memn;
  if (bundle_layout(b, &a)) return -6;
  return 0;
}

int bundle_step(bundle_t *b, int vi, int tok, int pos, float *logits, const k_hook_t *hk) {
  variant_t *v = &b->v[vi];
  int V = b->c.vocab_size, i, am = 0;
  if (v->kind == VK_H) {
    const int32_t *l = lm_h_forward(&v->hs, &b->c, &v->hw, tok, pos, hk);
    if (!l) return -1;
    for (i = 0; i < V; i++) logits[i] = (float)l[i] / 65536.0f;
    return v->hs.argmax[0];
  } else {
    const float *l = v->kind == VK_F ? lm_f_forward(&v->fs, &b->c, &b->fw, tok, pos)
                                     : lm_q_forward(&v->qs, &b->c, &v->qw, tok, pos);
    memcpy(logits, l, sizeof(float) * V);
    for (i = 1; i < V; i++)
      if (l[i] > l[am]) am = i;
    return am;
  }
}

/* ---------------- hooks ---------------- */
#define DUMP_MAGIC 0x504D444Bu
static void w32(FILE *f, uint32_t v) { fwrite(&v, 4, 1, f); }

void dump_hook(void *user, int phase, const kcall_t *c) {
  dump_t *d = user;
  int i;
  if (phase == 0) {
    d->active = d->count[c->kid] < d->cap;
    if (!d->active) return;
    w32(d->f, DUMP_MAGIC);
    w32(d->f, (uint32_t)c->kid);
    w32(d->f, (uint32_t)c->np);
    w32(d->f, (uint32_t)c->nb);
    for (i = 0; i < c->np; i++) w32(d->f, (uint32_t)c->prm[i]);
    for (i = 0; i < c->nb; i++) {
      w32(d->f, (uint32_t)c->b[i].esz);
      w32(d->f, (uint32_t)c->b[i].n);
      w32(d->f, (uint32_t)c->b[i].out);
    }
    for (i = 0; i < c->nb; i++)
      if (!c->b[i].out) fwrite(c->b[i].p, (size_t)c->b[i].esz, (size_t)c->b[i].n, d->f);
  } else if (d->active) {
    for (i = 0; i < c->nb; i++)
      if (c->b[i].out) fwrite(c->b[i].p, (size_t)c->b[i].esz, (size_t)c->b[i].n, d->f);
    d->count[c->kid]++;
    d->recs++;
    d->active = 0;
  }
}

static uint32_t r32(FILE *f, int *ok) {
  uint32_t v = 0;
  if (fread(&v, 4, 1, f) != 1) *ok = 0;
  return v;
}

int dump_read(FILE *f, kcall_t *c, void *rec[KB_MAX]) {
  int ok = 1, i;
  uint32_t mg = r32(f, &ok);
  if (!ok) return 0; /* end of file */
  if (mg != DUMP_MAGIC) return -1;
  memset(c, 0, sizeof(*c));
  c->kid = (int32_t)r32(f, &ok);
  c->np = (int32_t)r32(f, &ok);
  c->nb = (int32_t)r32(f, &ok);
  if (!ok || c->np > KP_MAX || c->nb > KB_MAX) return -1;
  for (i = 0; i < c->np; i++) c->prm[i] = (int32_t)r32(f, &ok);
  for (i = 0; i < c->nb; i++) {
    c->b[i].esz = (int32_t)r32(f, &ok);
    c->b[i].n = (int32_t)r32(f, &ok);
    c->b[i].out = (int32_t)r32(f, &ok);
    c->b[i].p = calloc((size_t)c->b[i].n, (size_t)c->b[i].esz);
    rec[i] = NULL;
  }
  for (i = 0; i < c->nb; i++)
    if (!c->b[i].out && fread(c->b[i].p, (size_t)c->b[i].esz, (size_t)c->b[i].n, f) != (size_t)c->b[i].n)
      ok = 0;
  for (i = 0; i < c->nb; i++)
    if (c->b[i].out) {
      rec[i] = malloc((size_t)c->b[i].n * c->b[i].esz);
      if (fread(rec[i], (size_t)c->b[i].esz, (size_t)c->b[i].n, f) != (size_t)c->b[i].n) ok = 0;
      memset(c->b[i].p, 0xA5, (size_t)c->b[i].n * c->b[i].esz); /* poison before replay */
    }
  return ok ? 1 : -1;
}

void dump_free(kcall_t *c, void *rec[KB_MAX]) {
  int i;
  for (i = 0; i < c->nb; i++) {
    free(c->b[i].p);
    free(rec[i]);
  }
}

void prof_hook(void *user, int phase, const kcall_t *c) {
  prof_t *p = user;
  if (phase == 0) {
    p->t0 = io_now();
    return;
  }
  p->t[c->kid] += io_now() - p->t0;
  p->calls[c->kid]++;
  switch (c->kid) {
  case K_GEMV: p->macs[c->kid] += (double)c->prm[0] * c->prm[1]; p->elems[c->kid] += c->prm[0]; break;
  case K_ATTN:
  case K_ATTN2: p->macs[c->kid] += 2.0 * c->prm[0] * c->prm[1]; p->elems[c->kid] += c->prm[0]; break;
  case K_RMSNORM: p->macs[c->kid] += 2.0 * c->prm[0]; p->elems[c->kid] += c->prm[0]; break;
  case K_SWIGLU: p->macs[c->kid] += 2.0 * c->prm[0]; p->elems[c->kid] += c->prm[0]; break;
  case K_ROPE: p->macs[c->kid] += 2.0 * c->prm[0]; p->elems[c->kid] += c->prm[0]; break;
  default: p->elems[c->kid] += c->prm[0]; break;
  }
}

void both_hook(void *user, int phase, const kcall_t *c) {
  both_t *b = user;
  if (b->d) dump_hook(b->d, phase, c);
  if (b->p) prof_hook(b->p, phase, c);
}
