/*
 * Vector tool for the RTL testbenches (S4-1). Settings come from the config file (env CFG,
 * default ./run.cfg) or environment variables of the same name; nothing is passed on the
 * command line (process-privacy.md).
 *
 *   job split : dump file `in` -> one record file per kernel in directory `odir`
 *               (<kernel>.bin, same record format as the dump, so k_exec replay and the
 *               DPI reader tb/dpi/kdpi.c read it) and odir/manifest.txt (one line per file,
 *               then one line per record: kernel, index in its file, dumped position
 *               ordinal, prm...). Every record is replayed through k_exec before it is
 *               written; a record whose replay differs from the recorded output stops the job.
 *   job range : dump files `in` (space separated) with labels `lab` -> per kernel min/max of
 *               exponents, shifts and internal widths (hierarchy.md 4 A10), table to `out`.
 *               Internal values come from the stage traces of k_exec_st.
 *   job bimg  : PIM bank RAM images of model `ck` (variant `var`, gs = n) for nb banks of
 *               BIMG_LB lanes, depth `depth`: odir/bank<k>.hex (one 144-bit word per line,
 *               36 hex digits, tag in the top 16 bits) and odir/bimg_map.txt.
 *   job rrec  : gemv row records (arch.md 2.2) of every matrix of model `ck`: odir/rrec.bin
 *               (matrices back to back, each 8 B aligned) and odir/rrec_map.txt.
 * Matrix order of bimg and rrec: per layer wq wk wv wo w1 w3 w2, then cls (s4calc.py order).
 */
#include <stdlib.h>
#include <string.h>
#include "io.h"

static FILE *OUT;
#define P(...)                          \
  do {                                  \
    printf(__VA_ARGS__);                \
    if (OUT) fprintf(OUT, __VA_ARGS__); \
  } while (0)

static int replay_ok(kcall_t *c, void *rec[KB_MAX], void *st) {
  int i, bad = 0;
  if (k_exec_st(c, st)) return 0;
  for (i = 0; i < c->nb; i++)
    if (c->b[i].out) bad |= memcmp(c->b[i].p, rec[i], (size_t)c->b[i].n * c->b[i].esz) != 0;
  return !bad;
}

/* writes record c with the recorded outputs (same layout as dump_hook) */
static void rec_write(FILE *f, const kcall_t *c, void *rec[KB_MAX]) {
  uint32_t v;
  int i;
#define W32(x) (v = (uint32_t)(x), fwrite(&v, 4, 1, f))
  W32(0x504D444Bu);
  W32(c->kid);
  W32(c->np);
  W32(c->nb);
  for (i = 0; i < c->np; i++) W32(c->prm[i]);
  for (i = 0; i < c->nb; i++) {
    W32(c->b[i].esz);
    W32(c->b[i].n);
    W32(c->b[i].out);
  }
#undef W32
  for (i = 0; i < c->nb; i++)
    if (!c->b[i].out) fwrite(c->b[i].p, (size_t)c->b[i].esz, (size_t)c->b[i].n, f);
  for (i = 0; i < c->nb; i++)
    if (c->b[i].out) fwrite(rec[i], (size_t)c->b[i].esz, (size_t)c->b[i].n, f);
}

/* ---------------- split ---------------- */
static int job_split(void) {
  const char *in = cfg_s("in", ""), *odir = cfg_s("odir", ".");
  FILE *f = fopen(in, "rb"), *kf[K_NKERN] = {0}, *mf;
  long cnt[K_NKERN] = {0}, n = 0, ord = -1;
  char path[1024];
  int rc, k;
  if (!f) { fprintf(stderr, "split: no input\n"); return 1; }
  snprintf(path, sizeof(path), "%s/manifest.txt", odir);
  mf = fopen(path, "w");
  if (!mf) { fprintf(stderr, "split: cannot write manifest\n"); return 1; }
  fprintf(mf, "# split of one dump file; record format: model/README.md\n");
  fprintf(mf, "# rec <kernel> <index in file> <position ordinal> <prm...>\n");
  for (;;) {
    kcall_t c;
    void *rec[KB_MAX];
    int i;
    rc = dump_read(f, &c, rec);
    if (rc <= 0) break;
    if (c.kid <= 0 || c.kid >= K_NKERN) { rc = -1; dump_free(&c, rec); break; }
    if (c.kid == K_EMBED) ord++; /* every forward position starts with the embedding */
    if (!replay_ok(&c, rec, NULL)) {
      fprintf(stderr, "split: record %ld (%s) does not replay\n", n, k_name(c.kid));
      dump_free(&c, rec);
      return 1;
    }
    if (!kf[c.kid]) {
      snprintf(path, sizeof(path), "%s/%s.bin", odir, k_name(c.kid));
      kf[c.kid] = fopen(path, "wb");
      if (!kf[c.kid]) { fprintf(stderr, "split: cannot write\n"); return 1; }
    }
    rec_write(kf[c.kid], &c, rec);
    fprintf(mf, "rec %s %ld %ld", k_name(c.kid), cnt[c.kid], ord);
    for (i = 0; i < c.np; i++) fprintf(mf, " %d", c.prm[i]);
    fprintf(mf, "\n");
    cnt[c.kid]++;
    n++;
    dump_free(&c, rec);
  }
  fclose(f);
  for (k = 1; k < K_NKERN; k++)
    if (kf[k]) {
      fclose(kf[k]);
      fprintf(mf, "file %s %s.bin records %ld\n", k_name(k), k_name(k), cnt[k]);
      P("split %s records %ld\n", k_name(k), cnt[k]);
    }
  fprintf(mf, "total records %ld positions %ld\n", n, ord + 1);
  fclose(mf);
  P("split total records %ld positions %ld %s\n", n, ord + 1, rc < 0 ? "READ_ERROR" : "ok");
  return rc < 0;
}

/* ---------------- range (A10) ---------------- */
#define NM 96
typedef struct {
  char name[40];
  int cls; /* 0 info, 1 exponent (E_W), 2 shift (SH_W) */
  long long mn, mx, cnt;
} met_t;
static met_t MET[NM];
static int NMET;

static void obs(const char *name, int cls, long long v) {
  int i;
  for (i = 0; i < NMET; i++)
    if (!strcmp(MET[i].name, name)) break;
  if (i == NMET) {
    if (NMET == NM) return;
    strcpy(MET[i].name, name);
    MET[i].cls = cls;
    MET[i].mn = MET[i].mx = v;
    MET[i].cnt = 0;
    NMET++;
  }
  if (v < MET[i].mn) MET[i].mn = v;
  if (v > MET[i].mx) MET[i].mx = v;
  MET[i].cnt++;
}

static int sbits(long long mn, long long mx) { /* signed width holding [mn, mx] */
  int w = 1;
  while (w < 64 && (mn < -(1LL << (w - 1)) || mx > (1LL << (w - 1)) - 1)) w++;
  return w;
}

static void range_rec(kcall_t *c, long *bad) {
  const int32_t *P = c->prm;
  int i, t;
  switch (c->kid) {
  case K_EMBED:
    obs("embed.we", 1, P[2]);
    obs("embed.fo", 1, P[3]);
    obs("embed.sh=we-fo", 2, P[2] - P[3]);
    *bad += k_exec(c) != 0;
    break;
  case K_GEMV: {
    int rows = P[0], n = P[1], gs = P[2];
    int64_t *S = malloc(sizeof(int64_t) * rows);
    const int8_t *W = c->b[0].p, *x = c->b[2].p;
    const uint16_t *wm = c->b[1].p;
    *bad += k_exec_st(c, S) != 0;
    obs("gemv.rows", 0, rows);
    obs("gemv.n", 0, n);
    obs("gemv.gs==n", 0, gs == n);
    obs("gemv.we", 1, P[3]);
    obs("gemv.xm", 0, P[4]);
    obs("gemv.xe", 1, P[5]);
    obs("gemv.fo", 1, P[6]);
    obs("gemv.sh=we+xe-fo", 2, P[3] + P[5] - P[6]);
    for (i = 0; i < rows * (n / gs); i++) obs("gemv.wm", 0, wm[i]);
    for (i = 0; i < rows; i++) {
      obs("gemv.S", 0, S[i]);
      obs("gemv.S*xm", 0, (long long)S[i] * P[4]);
      if (gs == n) obs("gemv.acc", 0, k_dot8(W + (size_t)i * n, x, n));
    }
    free(S);
    break;
  }
  case K_RMSNORM: {
    k_rms_st_t st;
    const kscl_t *s = c->b[3].p;
    memset(&st, 0, sizeof(st));
    *bad += k_exec_st(c, &st) != 0;
    obs("rms.n", 0, P[0]);
    obs("rms.ge", 1, P[2]);
    obs("rms.fy", 1, P[4]);
    obs("rms.k", 2, st.k);
    obs("rms.2k(epsc shift)", 2, 2 * st.k);
    obs("rms.re", 1, st.re);
    obs("rms.sh=ge+re-fy", 2, st.sh);
    obs("rms.ss", 0, (long long)st.ss);
    obs("rms.u", 0, (long long)st.u);
    obs("rms.rm", 0, st.rm);
    if (st.ymax) {
      obs("rms.aq.e", 1, st.aq.e);
      obs("rms.aq.sh=40-e", 2, 40 - st.aq.e);
      obs("rms.aq.R", 0, st.aq.R);
      obs("rms.out.m", 0, s->m);
      obs("rms.out.e", 1, s->e);
    }
    break;
  }
  case K_ACTQ: {
    k_actq_st_t st;
    const kscl_t *s = c->b[2].p;
    char nm[40];
    memset(&st, 0, sizeof(st));
    *bad += k_exec_st(c, &st) != 0;
    obs("actq.n", 0, P[0]);
    obs("actq.f", 1, P[1]);
    snprintf(nm, sizeof(nm), "actq.q%d.calls", P[3]);
    obs(nm, 0, P[0]);
    if (st.amax) {
      obs("actq.aq.e", 1, st.aq.e);
      obs("actq.aq.sh=40-e", 2, 40 - st.aq.e);
      obs("actq.aq.R", 0, st.aq.R);
      obs("actq.out.m", 0, s->m);
      snprintf(nm, sizeof(nm), "actq.q%d.out.e", P[3]);
      obs(nm, 1, s->e);
    }
    break;
  }
  case K_SWIGLU: {
    k_swi_st_t st;
    const kscl_t *s = c->b[4].p;
    memset(&st, 0, sizeof(st));
    *bad += k_exec_st(c, &st) != 0;
    obs("swiglu.n", 0, P[0]);
    if (st.amax) {
      obs("swiglu.aq.e", 1, st.aq.e);
      obs("swiglu.aq.sh=40-e", 2, 40 - st.aq.e);
      obs("swiglu.out.e", 1, s->e);
    }
    break;
  }
  case K_ATTN2: {
    int T = P[0], hs = P[1];
    k_attn_st_t st;
    const kscl_t *ks = c->b[2].p, *vs = c->b[4].p;
    memset(&st, 0, sizeof(st));
    st.dot = malloc(sizeof(int64_t) * T);
    st.s = malloc(sizeof(int32_t) * T);
    st.e = malloc(sizeof(uint32_t) * T);
    st.w = malloc(sizeof(int64_t) * T);
    st.acc = malloc(sizeof(int64_t) * hs);
    *bad += k_exec_st(c, &st) != 0;
    obs("attn.T", 0, T);
    obs("attn.hs", 0, hs);
    obs("attn.kb", 0, P[2]);
    obs("attn.vb", 0, P[3]);
    obs("attn.qm", 0, P[4]);
    obs("attn.qe", 1, P[5]);
    obs("attn.d0", 0, st.d0);
    for (t = 0; t < T; t++) {
      obs("attn.km", 0, ks[t].m);
      obs("attn.ke", 1, ks[t].e);
      obs("attn.vm", 0, vs[t].m);
      obs("attn.ve", 1, vs[t].e);
      obs("attn.dot", 0, st.dot[t]);
      obs("attn.s.sh=qe+ke-d0-16", 2, P[5] + ks[t].e - st.d0 - K_FS);
      obs("attn.s", 0, st.s[t]);
      obs("attn.s-mx", 0, (long long)st.s[t] - st.mx);
      obs("attn.e", 0, st.e[t]);
      if (vs[t].m) {
        obs("attn.v.sh=ve-emin-G", 2, vs[t].e - st.emin - st.G);
        obs("attn.w", 0, st.w[t]);
      }
    }
    obs("attn.sum", 0, (long long)st.sum);
    obs("attn.R", 0, (long long)st.R);
    if (st.have) {
      obs("attn.emin", 1, st.emin);
      obs("attn.G", 0, st.G);
      obs("attn.mmax", 0, st.mmax);
      obs("attn.o.sh=emin+G", 2, 16 + st.emin + st.G - K_FX);
      for (i = 0; i < hs; i++) obs("attn.acc", 0, st.acc[i]);
    }
    free(st.dot);
    free(st.s);
    free(st.e);
    free(st.w);
    free(st.acc);
    break;
  }
  case K_ARGMAX:
    obs("argmax.n", 0, P[0]);
    *bad += k_exec(c) != 0;
    break;
  default:
    *bad += k_exec(c) != 0;
    break;
  }
}

static void range_print(const char *lab) {
  int i, cls;
  long long emn = 0, emx = 0, smn = 0, smx = 0;
  int he = 0, hsft = 0;
  P("## range %s\n# metric class min max count signed_bits\n", lab);
  for (i = 0; i < NMET; i++) {
    met_t *m = &MET[i];
    P("%-24s %s %lld %lld %lld %d\n", m->name, m->cls == 1 ? "E " : m->cls == 2 ? "SH" : "- ",
      m->mn, m->mx, m->cnt, sbits(m->mn, m->mx));
    if (m->cls == 1) {
      if (!he || m->mn < emn) emn = m->mn;
      if (!he || m->mx > emx) emx = m->mx;
      he = 1;
    }
    if (m->cls == 2) {
      if (!hsft || m->mn < smn) smn = m->mn;
      if (!hsft || m->mx > smx) smx = m->mx;
      hsft = 1;
    }
  }
  for (cls = 1; cls <= 2; cls++) {
    long long mn = cls == 1 ? emn : smn, mx = cls == 1 ? emx : smx;
    P("summary %s %s min %lld max %lld signed_bits %d\n", lab, cls == 1 ? "E" : "SH", mn, mx,
      sbits(mn, mx));
  }
}

static int job_range(void) {
  char inb[2048], lb[512], *in, *la, *s1 = NULL, *s2 = NULL;
  long bad_all = 0;
  strncpy(inb, cfg_s("in", ""), sizeof(inb) - 1);
  inb[sizeof(inb) - 1] = 0;
  strncpy(lb, cfg_s("lab", ""), sizeof(lb) - 1);
  lb[sizeof(lb) - 1] = 0;
  P("# A10 range of exponents (class E) and shifts (class SH) over K12V8 dump records\n");
  P("# every record is replayed with stage traces (k_exec_st) and must reproduce its output\n");
  for (in = strtok_r(inb, " ", &s1), la = strtok_r(lb, " ", &s2); in;
       in = strtok_r(NULL, " ", &s1), la = la ? strtok_r(NULL, " ", &s2) : NULL) {
    FILE *f = fopen(in, "rb");
    long n = 0, bad = 0, rbad = 0;
    int rc;
    if (!f) { fprintf(stderr, "range: no input\n"); return 1; }
    NMET = 0;
    for (;;) {
      kcall_t c;
      void *rec[KB_MAX];
      int i;
      rc = dump_read(f, &c, rec);
      if (rc <= 0) break;
      range_rec(&c, &bad);
      for (i = 0; i < c.nb; i++)
        if (c.b[i].out) rbad += memcmp(c.b[i].p, rec[i], (size_t)c.b[i].n * c.b[i].esz) != 0;
      n++;
      dump_free(&c, rec);
    }
    fclose(f);
    range_print(la ? la : in);
    P("records %s %ld replay_mismatch %ld exec_errors %ld read %s\n", la ? la : in, n, rbad, bad,
      rc < 0 ? "ERROR" : "ok");
    bad_all += rbad + bad + (rc < 0);
  }
  return bad_all != 0;
}

/* ---------------- model matrices ---------------- */
typedef struct {
  char name[16];
  const lm_hm_t *m;
} mref_t;

static int mats(const bundle_t *b, mref_t *o) {
  const lm_hw_t *w = &b->v[0].hw;
  int l, j, n = 0;
  for (l = 0; l < b->c.n_layers; l++)
    for (j = 0; j < 7; j++) {
      static const char *nm[7] = {"wq", "wk", "wv", "wo", "w1", "w3", "w2"};
      const lm_hm_t *m = j == 0 ? &w->wq[l] : j == 1 ? &w->wk[l] : j == 2 ? &w->wv[l]
                         : j == 3 ? &w->wo[l] : j == 4 ? &w->w1[l] : j == 5 ? &w->w3[l]
                                                                          : &w->w2[l];
      snprintf(o[n].name, sizeof(o[n].name), "%s%d", nm[j], l);
      o[n++].m = m;
    }
  strcpy(o[n].name, "cls");
  o[n++].m = &w->cls;
  return n;
}

static int job_bimg(void) {
  bundle_t b;
  mref_t mr[128];
  int nb = (int)cfg_i("nb", 4), nm, i, k;
  long depth = cfg_i("depth", 4096), base = 0, w;
  const char *odir = cfg_s("odir", ".");
  bimg_word_t **img;
  char path[1024];
  FILE *mf;
  if (bundle_load(&b, cfg_s("ck", ""), cfg_s("tk", ""), cfg_s("var", "K12V8"))) return 1;
  nm = mats(&b, mr);
  img = malloc(sizeof(*img) * nb);
  for (k = 0; k < nb; k++) img[k] = calloc((size_t)depth, sizeof(bimg_word_t));
  snprintf(path, sizeof(path), "%s/bimg_map.txt", odir);
  mf = fopen(path, "w");
  if (!mf) return 1;
  fprintf(mf, "# PIM bank image map: nb %d lanes %d depth %ld (model/src/llm.h bimg_*)\n", nb,
          BIMG_LB, depth);
  fprintf(mf, "# mat <name> rows n nw base words we\n");
  for (i = 0; i < nm; i++) {
    const lm_hm_t *m = mr[i].m;
    if (m->gs != m->n) { fprintf(stderr, "bimg: %s has weight groups (gs != n)\n", mr[i].name); return 1; }
    w = bimg_pack(img, nb, depth, base, m->q, m->m, m->rows, m->n);
    if (w < 0) { fprintf(stderr, "bimg: %s does not fit (base %ld)\n", mr[i].name, base); return 1; }
    fprintf(mf, "mat %s %d %d %d %ld %ld %d\n", mr[i].name, m->rows, m->n, bimg_nw(m->n), base, w,
            m->we);
    base += w;
  }
  fprintf(mf, "used %ld of %ld words per bank\n", base, depth);
  fclose(mf);
  for (k = 0; k < nb; k++) {
    FILE *f;
    long a;
    snprintf(path, sizeof(path), "%s/bank%d.hex", odir, k);
    f = fopen(path, "w");
    if (!f) return 1;
    for (a = 0; a < depth; a++) {
      const bimg_word_t *x = &img[k][a];
      int l;
      fprintf(f, "%04x", x->tag);
      for (l = BIMG_LB - 1; l >= 0; l--) fprintf(f, "%02x", (uint8_t)x->d[l]);
      fprintf(f, "\n");
    }
    fclose(f);
  }
  P("bimg matrices %d nb %d depth %ld used %ld\n", nm, nb, depth, base);
  return 0;
}

static int job_rrec(void) {
  bundle_t b;
  mref_t mr[128];
  int nm, i;
  long off = 0;
  const char *odir = cfg_s("odir", ".");
  char path[1024];
  FILE *f, *mf;
  if (bundle_load(&b, cfg_s("ck", ""), cfg_s("tk", ""), cfg_s("var", "K12V8"))) return 1;
  nm = mats(&b, mr);
  snprintf(path, sizeof(path), "%s/rrec.bin", odir);
  f = fopen(path, "wb");
  snprintf(path, sizeof(path), "%s/rrec_map.txt", odir);
  mf = fopen(path, "w");
  if (!f || !mf) return 1;
  fprintf(mf, "# gemv row records (arch.md 2.2): header 8 B (wm) + ceil(n/8)*8 B per row\n");
  fprintf(mf, "# mat <name> rows n byte_offset bytes we\n");
  for (i = 0; i < nm; i++) {
    const lm_hm_t *m = mr[i].m;
    long nbt = rrec_bytes(m->rows, m->n);
    uint8_t *buf = malloc((size_t)nbt);
    if (m->gs != m->n) { fprintf(stderr, "rrec: %s has weight groups\n", mr[i].name); return 1; }
    rrec_pack(buf, m->q, m->m, m->rows, m->n);
    fwrite(buf, 1, (size_t)nbt, f);
    fprintf(mf, "mat %s %d %d %ld %ld %d\n", mr[i].name, m->rows, m->n, off, nbt, m->we);
    off += nbt;
    free(buf);
  }
  fprintf(mf, "total %ld bytes\n", off);
  fclose(f);
  fclose(mf);
  P("rrec matrices %d bytes %ld\n", nm, off);
  return 0;
}

int main(void) {
  const char *job, *out;
  int rc;
  if (cfg_load()) fprintf(stderr, "no config file\n");
  job = cfg_s("job", "split");
  out = cfg_s("out", NULL);
  if (out) OUT = fopen(out, "w");
  if (!strcmp(job, "split")) rc = job_split();
  else if (!strcmp(job, "range")) rc = job_range();
  else if (!strcmp(job, "bimg")) rc = job_bimg();
  else if (!strcmp(job, "rrec")) rc = job_rrec();
  else rc = 2;
  if (OUT) fclose(OUT);
  return rc;
}
