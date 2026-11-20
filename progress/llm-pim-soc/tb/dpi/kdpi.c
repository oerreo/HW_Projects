/*
 * kdpi: thin DPI-C wrapper over the golden model (model/src) for the Questa testbenches.
 *
 * No arithmetic is implemented here: every value comes from a model/src function
 * (kernel, stage function, row record or bank image packer). The only code of its own is
 * the reader of the kernel record file format (model/README.md "덤프 레코드 형식"), which
 * keeps the DPI library free of the PC tools (tools/io.c pulls in the whole model).
 *
 * Compiled by vlog together with model/src/{kern,tabs,bank,core}.c (sim/run.sh, DPI=1).
 * SV side: tb/dpi/kdpi_pkg.sv. One record file is open at a time; kd_rec_next() makes the
 * next record current. Element access: kd_rec_get() sign-extends, kd_rec_getu()
 * zero-extends (u16 mantissas, u32 LUT entries). Outputs read through kd_rec_get are the
 * recorded (golden) outputs of the dump.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "svdpi.h"
#include "llm.h"

#define KD_MAGIC 0x504D444Bu

static FILE *RF;
static kcall_t RC;      /* current record: inputs in b[i].p, outputs in RO[i] */
static void *RO[KB_MAX]; /* recorded outputs */
static long RN;          /* records read */

static void rec_free(void) {
  int i;
  for (i = 0; i < KB_MAX; i++) {
    free(RC.b[i].p);
    free(RO[i]);
    RC.b[i].p = NULL;
    RO[i] = NULL;
  }
  memset(&RC, 0, sizeof(RC));
}

static int r32(uint32_t *v) { return fread(v, 4, 1, RF) == 1; }

int kd_rec_open(const char *path) {
  if (RF) fclose(RF);
  rec_free();
  RN = 0;
  RF = fopen(path, "rb");
  return RF ? 0 : -1;
}

int kd_rec_close(void) {
  if (RF) fclose(RF);
  RF = NULL;
  rec_free();
  return 0;
}

/* next record: returns its kernel id, 0 at end of file, -1 on a format error */
int kd_rec_next(void) {
  uint32_t v, kid, np, nb;
  int i;
  if (!RF) return -1;
  rec_free();
  if (!r32(&v)) return 0;
  if (v != KD_MAGIC || !r32(&kid) || !r32(&np) || !r32(&nb) || np > KP_MAX || nb > KB_MAX)
    return -1;
  RC.kid = (int32_t)kid;
  RC.np = (int32_t)np;
  RC.nb = (int32_t)nb;
  for (i = 0; i < RC.np; i++) {
    if (!r32(&v)) return -1;
    RC.prm[i] = (int32_t)v;
  }
  for (i = 0; i < RC.nb; i++) {
    uint32_t e, n, o;
    if (!r32(&e) || !r32(&n) || !r32(&o) || (e != 1 && e != 2 && e != 4)) return -1;
    RC.b[i].esz = (int32_t)e;
    RC.b[i].n = (int32_t)n;
    RC.b[i].out = (int32_t)o;
    RC.b[i].p = calloc(n ? n : 1, e);
  }
  for (i = 0; i < RC.nb; i++)
    if (!RC.b[i].out && fread(RC.b[i].p, (size_t)RC.b[i].esz, (size_t)RC.b[i].n, RF) != (size_t)RC.b[i].n)
      return -1;
  for (i = 0; i < RC.nb; i++)
    if (RC.b[i].out) {
      RO[i] = calloc(RC.b[i].n ? RC.b[i].n : 1, RC.b[i].esz);
      if (fread(RO[i], (size_t)RC.b[i].esz, (size_t)RC.b[i].n, RF) != (size_t)RC.b[i].n) return -1;
    }
  RN++;
  return RC.kid;
}

int kd_rec_index(void) { return (int)RN - 1; }
int kd_rec_kid(void) { return RC.kid; }
int kd_rec_np(void) { return RC.np; }
int kd_rec_prm(int i) { return (i >= 0 && i < RC.np) ? RC.prm[i] : 0; }
int kd_rec_nb(void) { return RC.nb; }
int kd_rec_esz(int b) { return (b >= 0 && b < RC.nb) ? RC.b[b].esz : 0; }
int kd_rec_n(int b) { return (b >= 0 && b < RC.nb) ? RC.b[b].n : 0; }
int kd_rec_out(int b) { return (b >= 0 && b < RC.nb) ? RC.b[b].out : 0; }

static const void *bufp(int b) { return RC.b[b].out ? RO[b] : RC.b[b].p; }

/* element i of buffer b, sign-extended (out-of-range index: 0) */
int kd_rec_get(int b, int i) {
  const void *p;
  if (b < 0 || b >= RC.nb || i < 0 || i >= RC.b[b].n) return 0;
  p = bufp(b);
  switch (RC.b[b].esz) {
  case 1: return ((const int8_t *)p)[i];
  case 2: return ((const int16_t *)p)[i];
  default: return ((const int32_t *)p)[i];
  }
}

/* element i of buffer b, zero-extended */
int kd_rec_getu(int b, int i) {
  const void *p;
  if (b < 0 || b >= RC.nb || i < 0 || i >= RC.b[b].n) return 0;
  p = bufp(b);
  switch (RC.b[b].esz) {
  case 1: return ((const uint8_t *)p)[i];
  case 2: return ((const uint16_t *)p)[i];
  default: return (int)((const uint32_t *)p)[i];
  }
}

/* runs the current record through k_exec on copies of its inputs; returns the number of
   output elements that differ from the recorded ones, or -1 if k_exec rejects it */
int kd_rec_replay(void) {
  kcall_t c = RC;
  void *tmp[KB_MAX] = {0};
  int i, j, bad = 0;
  for (i = 0; i < c.nb; i++)
    if (c.b[i].out) {
      tmp[i] = malloc((size_t)c.b[i].n * c.b[i].esz + 1);
      memset(tmp[i], 0xA5, (size_t)c.b[i].n * c.b[i].esz);
      c.b[i].p = tmp[i];
    }
  if (k_exec(&c)) bad = -1;
  for (i = 0; i < c.nb && bad >= 0; i++)
    if (c.b[i].out)
      for (j = 0; j < c.b[i].n; j++)
        bad += memcmp((char *)tmp[i] + (size_t)j * c.b[i].esz, (char *)RO[i] + (size_t)j * c.b[i].esz,
                      (size_t)c.b[i].esz) != 0;
  for (i = 0; i < c.nb; i++) free(tmp[i]);
  return bad;
}

/* ---- K_GEMV record helpers (prm rows n gs we xm xe fo; b W m x | y) ---- */
static int is_gemv(void) { return RC.kid == K_GEMV && RC.nb == 4; }

/* S of row r (k_gemv_row) */
long long kd_rec_gemv_s(int r) {
  int n = RC.prm[1], gs = RC.prm[2];
  if (!is_gemv() || r < 0 || r >= RC.prm[0]) return 0;
  return k_gemv_row((const int8_t *)RC.b[0].p + (size_t)r * n,
                    (const uint16_t *)RC.b[1].p + (size_t)r * (n / gs), RC.b[2].p, n, gs);
}

/* int32 dot product of row r with x (one group: requires gs == n), k_dot8 */
int kd_rec_gemv_acc(int r) {
  int n = RC.prm[1];
  if (!is_gemv() || r < 0 || r >= RC.prm[0]) return 0;
  return k_dot8((const int8_t *)RC.b[0].p + (size_t)r * n, RC.b[2].p, n);
}

/* number of 64-bit beats of one row record: header + ceil(n / 8) */
int kd_rec_rrec_nbeat(void) { return is_gemv() ? 1 + (RC.prm[1] + 7) / 8 : 0; }

/* beat j of the row record of row r (rrec_pack, little-endian bytes -> 64-bit word) */
long long kd_rec_rrec_beat(int r, int j) {
  int n = RC.prm[1], gs = RC.prm[2], k;
  uint8_t *buf;
  uint64_t w = 0;
  long nb;
  if (!is_gemv() || gs != n || r < 0 || r >= RC.prm[0] || j < 0 || j >= kd_rec_rrec_nbeat())
    return 0;
  nb = rrec_bytes(1, n);
  buf = malloc((size_t)nb);
  rrec_pack(buf, (const int8_t *)RC.b[0].p + (size_t)r * n, (const uint16_t *)RC.b[1].p + r, 1, n);
  for (k = 7; k >= 0; k--) w = (w << 8) | buf[(size_t)j * 8 + k];
  free(buf);
  return (long long)w;
}

/* ---- PIM bank image of the current K_GEMV record (BIMG_LB lanes, nb banks, base 0) ----
   word a of bank k: lanes 0..15 (lo: lanes 0..7, hi: lanes 8..15 as little-endian 64-bit
   words) and the 16-bit tag. Returns -1 if the record does not fit (gs != n). */
static bimg_word_t *BI[64];
static int BNB;
static long BDEP;

int kd_rec_bimg(int nb) {
  int k;
  long w;
  for (k = 0; k < BNB; k++) free(BI[k]);
  BNB = 0;
  if (!is_gemv() || RC.prm[2] != RC.prm[1] || nb < 1 || nb > 64) return -1;
  BDEP = bimg_words(RC.prm[0], RC.prm[1], nb);
  for (k = 0; k < nb; k++) BI[k] = calloc((size_t)BDEP, sizeof(bimg_word_t));
  BNB = nb;
  w = bimg_pack(BI, nb, BDEP, 0, RC.b[0].p, RC.b[1].p, RC.prm[0], RC.prm[1]);
  return w < 0 ? -1 : (int)w;
}

long long kd_bimg_lo(int k, int a) {
  uint64_t w = 0;
  int l;
  if (k < 0 || k >= BNB || a < 0 || a >= BDEP) return 0;
  for (l = 7; l >= 0; l--) w = (w << 8) | (uint8_t)BI[k][a].d[l];
  return (long long)w;
}

long long kd_bimg_hi(int k, int a) {
  uint64_t w = 0;
  int l;
  if (k < 0 || k >= BNB || a < 0 || a >= BDEP) return 0;
  for (l = 15; l >= 8; l--) w = (w << 8) | (uint8_t)BI[k][a].d[l];
  return (long long)w;
}

int kd_bimg_tag(int k, int a) { return (k >= 0 && k < BNB && a >= 0 && a < BDEP) ? BI[k][a].tag : 0; }

/* ---- scalar stage functions ---- */
long long kd_rshr(long long x, int s) { return k_rshr(x, s); }
int kd_sat32(long long x) { return k_sat32(x); }
int kd_gemv_out(long long S, int xm, int sh) { return k_gemv_out(S, xm, sh); }
int kd_exp2neg(int u, int eb) { return (int)k_exp2neg((uint32_t)u, eb, k_exp_lut(eb)); }
int kd_sigmoid(int a, int sb) { return (int)k_sigmoid(a, sb, k_sig_lut(sb)); }
int kd_rsqrt(long long u, int *re) { return (int)k_rsqrt((uint64_t)u, re); }

/* k_dot8 over the first n elements of two byte open arrays */
int kd_dot8(const svOpenArrayHandle a, const svOpenArrayHandle b, int n) {
  int8_t *pa = malloc((size_t)n + 1), *pb = malloc((size_t)n + 1);
  int i, r;
  for (i = 0; i < n; i++) {
    pa[i] = *(int8_t *)svGetArrElemPtr1(a, svLow(a, 1) + i);
    pb[i] = *(int8_t *)svGetArrElemPtr1(b, svLow(b, 1) + i);
  }
  r = k_dot8(pa, pb, n);
  free(pa);
  free(pb);
  return r;
}

/* ---- S4-2 bulk accessors (copies only; values come from the record or model/src) ---- */

/* copies n int8 elements of buffer b starting at element off into the byte open array v
   (element v[low + i]); returns the number copied, -1 if b is not an int8 buffer or the
   range is outside the buffer */
int kd_rec_bytes(int b, int off, const svOpenArrayHandle v, int n) {
  const int8_t *p;
  int i;
  if (b < 0 || b >= RC.nb || RC.b[b].esz != 1 || off < 0 || n < 0 || off + n > RC.b[b].n) return -1;
  p = (const int8_t *)bufp(b);
  for (i = 0; i < n; i++) *(int8_t *)svGetArrElemPtr1(v, svLow(v, 1) + i) = p[off + i];
  return n;
}

/* all beats of the row record of row r of the current K_GEMV record (rrec_pack, one row:
   beat 0 = header, beats 1..ceil(n/8) = weights) into the longint open array beats;
   returns the number of beats, -1 if not a row-wise K_GEMV record */
int kd_rec_rrec_row(int r, const svOpenArrayHandle beats) {
  int n = RC.prm[1], gs = RC.prm[2], nb, j, k;
  uint8_t *buf;
  if (!is_gemv() || gs != n || r < 0 || r >= RC.prm[0]) return -1;
  nb = kd_rec_rrec_nbeat();
  buf = malloc((size_t)rrec_bytes(1, n));
  rrec_pack(buf, (const int8_t *)RC.b[0].p + (size_t)r * n, (const uint16_t *)RC.b[1].p + r, 1, n);
  for (j = 0; j < nb; j++) {
    uint64_t w = 0;
    for (k = 7; k >= 0; k--) w = (w << 8) | buf[(size_t)j * 8 + k];
    *(uint64_t *)svGetArrElemPtr1(beats, svLow(beats, 1) + j) = w;
  }
  free(buf);
  return nb;
}

/* y of one synthetic gemv row (gs = n): k_gemv_out(k_gemv_row(w, wm, x, n, n), xm, sh) */
int kd_gemv1(const svOpenArrayHandle w, const svOpenArrayHandle x, int n, int wm, int xm, int sh) {
  int8_t *pw = malloc((size_t)n + 1), *px = malloc((size_t)n + 1);
  uint16_t m = (uint16_t)wm;
  int i, r;
  for (i = 0; i < n; i++) {
    pw[i] = *(int8_t *)svGetArrElemPtr1(w, svLow(w, 1) + i);
    px[i] = *(int8_t *)svGetArrElemPtr1(x, svLow(x, 1) + i);
  }
  r = k_gemv_out(k_gemv_row(pw, &m, px, n, n), xm, sh);
  free(pw);
  free(px);
  return r;
}

/* ---- S4-5: PIM bank model (bank_pack BANK_ROW + bank_gemv, model/src/bank.c) ---- */

/* bank_gemv of one rows x n matrix (gs = n) over nb banks: y[rows] and the command counts of
   this one call in st[0..2] = wrgb, mac, rdmac (bank_stat_t). Returns 0, or -1 on bad
   arguments / no memory. All arithmetic is model/src (bank_pack, bank_gemv). */
static int bank_run(const int8_t *W, const uint16_t *wm, const int8_t *x, int rows, int n,
                    int we, int xm, int xe, int fo, int nb, int32_t *y, long *st) {
  lm_hm_t m;
  bank_mat_t b;
  lm_arena_t a = {0};
  bank_stat_t s = {0, 0, 0};
  int8_t *gbuf;
  int32_t *part;
  kscl_t xs;
  if (rows < 1 || n < 1 || nb < 1 || nb > 64) return -1;
  m.q = (int8_t *)W;
  m.m = (uint16_t *)wm;
  m.we = we;
  m.rows = rows;
  m.n = n;
  m.gs = n;
  bank_pack(&b, &m, nb, BANK_ROW, &a); /* sizing pass */
  a.cap = a.off + 64;
  a.base = malloc(a.cap);
  a.off = 0;
  if (!a.base) return -1;
  bank_pack(&b, &m, nb, BANK_ROW, &a);
  gbuf = malloc((size_t)n + 1);
  part = malloc(sizeof(int32_t) * ((size_t)nb * rows + 1));
  xs.m = xm;
  xs.e = xe;
  if (a.fail || !gbuf || !part) {
    free(a.base);
    free(gbuf);
    free(part);
    return -1;
  }
  bank_gemv(&b, x, xs, fo, y, gbuf, part, &s);
  st[0] = s.wrgb;
  st[1] = s.mac;
  st[2] = s.rdmac;
  free(a.base);
  free(gbuf);
  free(part);
  return 0;
}

/* current K_GEMV record through bank_gemv: st[0..2] = wrgb, mac, rdmac; returns the number of
   y elements differing from the recorded y, -1 if not a row-wise K_GEMV record */
int kd_rec_bank(int nb, const svOpenArrayHandle st) {
  int rows = RC.prm[0], n = RC.prm[1], i, bad = 0;
  int32_t *y;
  long s[3];
  if (!is_gemv() || RC.prm[2] != n) return -1;
  y = malloc(sizeof(int32_t) * (size_t)rows);
  if (!y || bank_run(RC.b[0].p, RC.b[1].p, RC.b[2].p, rows, n, RC.prm[3], RC.prm[4], RC.prm[5],
                     RC.prm[6], nb, y, s)) {
    free(y);
    return -1;
  }
  for (i = 0; i < rows; i++) bad += y[i] != ((const int32_t *)RO[3])[i];
  for (i = 0; i < 3; i++) *(int64_t *)svGetArrElemPtr1(st, svLow(st, 1) + i) = s[i];
  free(y);
  return bad;
}

/* synthetic matrix: w[rows * n] (row-major), wm[rows], x[n] -> y[rows] and st[0..2] */
int kd_bank_syn(const svOpenArrayHandle w, const svOpenArrayHandle wm, const svOpenArrayHandle x,
                int rows, int n, int we, int xm, int xe, int fo, int nb,
                const svOpenArrayHandle y, const svOpenArrayHandle st) {
  int8_t *pw = malloc((size_t)rows * n + 1), *px = malloc((size_t)n + 1);
  uint16_t *pm = malloc(sizeof(uint16_t) * ((size_t)rows + 1));
  int32_t *py = malloc(sizeof(int32_t) * ((size_t)rows + 1));
  long s[3];
  int i, r = -1;
  if (pw && px && pm && py) {
    for (i = 0; i < rows * n; i++) pw[i] = *(int8_t *)svGetArrElemPtr1(w, svLow(w, 1) + i);
    for (i = 0; i < n; i++) px[i] = *(int8_t *)svGetArrElemPtr1(x, svLow(x, 1) + i);
    for (i = 0; i < rows; i++) pm[i] = (uint16_t)*(int16_t *)svGetArrElemPtr1(wm, svLow(wm, 1) + i);
    r = bank_run(pw, pm, px, rows, n, we, xm, xe, fo, nb, py, s);
    if (r == 0) {
      for (i = 0; i < rows; i++) *(int32_t *)svGetArrElemPtr1(y, svLow(y, 1) + i) = py[i];
      for (i = 0; i < 3; i++) *(int64_t *)svGetArrElemPtr1(st, svLow(st, 1) + i) = s[i];
    }
  }
  free(pw);
  free(px);
  free(pm);
  free(py);
  return r;
}

/* ---- S4-4 ---- */

/* k_argmax over the first n elements of an int open array (index of the first maximum) */
int kd_argmax(const svOpenArrayHandle v, int n) {
  int32_t *pv = malloc((size_t)(n > 0 ? n : 1) * sizeof(int32_t));
  int i, r;
  for (i = 0; i < n; i++) pv[i] = *(int32_t *)svGetArrElemPtr1(v, svLow(v, 1) + i);
  r = k_argmax(pv, n);
  free(pv);
  return r;
}

/* ---- S4-6: attention (k_attn2_st and the A3 stage functions of src/kern.c) ---- */

/* stage functions */
int kd_attn_score(long long dot, int qm, int km, int qe, int ke, int d0) {
  return k_attn_score(dot, qm, km, qe, ke, d0);
}
int kd_attn_exp(int s, int mx) { return (int)k_attn_exp(s, mx, 8, k_exp_lut(8)); }
int kd_attn_pn(int e, long long R) { return k_attn_pn((uint32_t)e, (uint64_t)R); }
long long kd_attn_w(int p, int vm, int ve, int emin, int G) { return k_attn_w(p, vm, ve, emin, G); }
int kd_attn_out(long long acc, int emin, int G) { return k_attn_out(acc, emin, G); }
/* exp LUT entry of the golden model (k_exp_lut(8)[i]) */
int kd_exp_lut8(int i) { return (i >= 0 && i <= 256) ? (int)k_exp_lut(8)[i] : -1; }

/* one attention call held in a scratch area: inputs come from the TB (kd_att_set) or from
   the current K_ATTN2 / K_ATTN record (kd_att_from_rec), kd_att_run runs k_attn2_st (LUT
   k_exp_lut(8)) with every trace array; kd_att_get reads inputs, outputs and the trace. */
static int AT_T, AT_HS, AT_KB, AT_VB, AT_QM, AT_QE, AT_OK;
static int16_t AQ[K_HSMAX], *AK, *AV;
static kscl_t *AKS, *AVS;
static int32_t *AP, *AS, AO[K_HSMAX];
static uint32_t *AE;
static int64_t *ADOT, *AWT, AACC[K_HSMAX];
static k_attn_st_t AST;

static void att_free(void) {
  free(AK); free(AV); free(AKS); free(AVS); free(AP); free(AS); free(AE); free(ADOT); free(AWT);
  AK = AV = NULL; AKS = AVS = NULL; AP = AS = NULL; AE = NULL; ADOT = AWT = NULL;
  AT_OK = 0;
}

int kd_att_begin(int T, int hs, int kb, int vb, int qm, int qe) {
  att_free();
  if (T < 1 || T > K_TMAX || hs < 1 || hs > K_HSMAX) return -1;
  AT_T = T; AT_HS = hs; AT_KB = kb; AT_VB = vb; AT_QM = qm; AT_QE = qe;
  AK = calloc((size_t)T * hs, 2); AV = calloc((size_t)T * hs, 2);
  AKS = calloc((size_t)T, sizeof(kscl_t)); AVS = calloc((size_t)T, sizeof(kscl_t));
  AP = calloc((size_t)T, 4); AS = calloc((size_t)T, 4); AE = calloc((size_t)T, 4);
  ADOT = calloc((size_t)T, 8); AWT = calloc((size_t)T, 8);
  memset(AQ, 0, sizeof(AQ));
  AT_OK = AK && AV && AKS && AVS && AP && AS && AE && ADOT && AWT;
  return AT_OK ? 0 : -1;
}

/* what: 0 q[i], 1 K[i] (i = t hs + lane), 2 V[i], 3 ks[i].m, 4 ks[i].e, 5 vs[i].m, 6 vs[i].e */
int kd_att_set(int what, int i, int v) {
  int n = AT_T * AT_HS;
  if (!AT_OK || i < 0) return -1;
  switch (what) {
  case 0: if (i >= AT_HS) return -1; AQ[i] = (int16_t)v; return 0;
  case 1: if (i >= n) return -1; AK[i] = (int16_t)v; return 0;
  case 2: if (i >= n) return -1; AV[i] = (int16_t)v; return 0;
  case 3: if (i >= AT_T) return -1; AKS[i].m = v; return 0;
  case 4: if (i >= AT_T) return -1; AKS[i].e = v; return 0;
  case 5: if (i >= AT_T) return -1; AVS[i].m = v; return 0;
  case 6: if (i >= AT_T) return -1; AVS[i].e = v; return 0;
  default: return -1;
  }
}

/* current record (K_ATTN2, or K_ATTN with kb = vb = 8 esz) into the scratch area; returns 0,
   -1 if it is not an attention record, -2 if its LUT is not k_exp_lut(8) */
int kd_att_from_rec(void) {
  int T, hs, kb, vb, qm, qe, eb, ek, ev, i, t;
  if (RC.kid == K_ATTN2 && RC.np == 7 && RC.nb == 8) {
    T = RC.prm[0]; hs = RC.prm[1]; kb = RC.prm[2]; vb = RC.prm[3]; qm = RC.prm[4]; qe = RC.prm[5];
    eb = RC.prm[6];
  } else if (RC.kid == K_ATTN && RC.np == 6 && RC.nb == 8) {
    T = RC.prm[0]; hs = RC.prm[1]; kb = vb = 8 * RC.prm[2]; qm = RC.prm[3]; qe = RC.prm[4];
    eb = RC.prm[5];
  } else
    return -1;
  if (eb != 8 || RC.b[5].n != 257) return -2;
  for (i = 0; i < 257; i++)
    if (((const uint32_t *)RC.b[5].p)[i] != k_exp_lut(8)[i]) return -2;
  if (kd_att_begin(T, hs, kb, vb, qm, qe)) return -1;
  ek = kb > 8 ? 2 : 1;
  ev = vb > 8 ? 2 : 1;
  for (i = 0; i < hs; i++) AQ[i] = (int16_t)(ek == 2 ? ((const int16_t *)RC.b[0].p)[i] : ((const int8_t *)RC.b[0].p)[i]);
  for (i = 0; i < T * hs; i++) {
    AK[i] = (int16_t)(ek == 2 ? ((const int16_t *)RC.b[1].p)[i] : ((const int8_t *)RC.b[1].p)[i]);
    AV[i] = (int16_t)(ev == 2 ? ((const int16_t *)RC.b[3].p)[i] : ((const int8_t *)RC.b[3].p)[i]);
  }
  for (t = 0; t < T; t++) {
    AKS[t] = ((const kscl_t *)RC.b[2].p)[t];
    AVS[t] = ((const kscl_t *)RC.b[4].p)[t];
  }
  return 0;
}

/* k_attn2_st on the scratch inputs (q, K, V narrowed to int8 for widths 8) */
int kd_att_run(void) {
  int n = AT_T * AT_HS, i, ek = AT_KB > 8 ? 2 : 1, ev = AT_VB > 8 ? 2 : 1;
  int8_t q8[K_HSMAX], *K8 = NULL, *V8 = NULL;
  kscl_t qs;
  if (!AT_OK) return -1;
  if (ek == 1 || ev == 1) {
    K8 = malloc((size_t)n + 1);
    V8 = malloc((size_t)n + 1);
    for (i = 0; i < n; i++) { K8[i] = (int8_t)AK[i]; V8[i] = (int8_t)AV[i]; }
  }
  for (i = 0; i < AT_HS; i++) q8[i] = (int8_t)AQ[i];
  qs.m = AT_QM;
  qs.e = AT_QE;
  memset(&AST, 0, sizeof(AST));
  AST.dot = ADOT; AST.s = AS; AST.e = AE; AST.w = AWT; AST.acc = AACC;
  k_attn2_st(AT_T, AT_HS, AT_KB, AT_VB, ek == 2 ? (const void *)AQ : (const void *)q8, qs,
             ek == 2 ? (const void *)AK : (const void *)K8, AKS,
             ev == 2 ? (const void *)AV : (const void *)V8, AVS, 8, k_exp_lut(8), AP, AO, &AST);
  free(K8);
  free(V8);
  return 0;
}

/* number of p and o elements of the last kd_att_run differing from the current record's
   recorded outputs (after kd_att_from_rec), -1 if the record is not an attention record */
int kd_att_rec_cmp(void) {
  int i, bad = 0;
  if ((RC.kid != K_ATTN2 && RC.kid != K_ATTN) || RC.nb != 8) return -1;
  for (i = 0; i < AT_T; i++) bad += AP[i] != ((const int32_t *)RO[6])[i];
  for (i = 0; i < AT_HS; i++) bad += AO[i] != ((const int32_t *)RO[7])[i];
  return bad;
}

/* what: 0 p[i], 1 o[i], 2 dot[i], 3 s[i], 4 e[i], 5 w[i], 6 acc[i], 7 q[i], 8 K[i], 9 V[i],
   10 ks.m, 11 ks.e, 12 vs.m, 13 vs.e (index t); scalars 20 T, 21 hs, 22 kb, 23 vb, 24 qm, 25 qe,
   30 d0, 31 mx, 32 sum, 33 R, 34 emin, 35 mmax, 36 G, 37 have */
long long kd_att_get(int what, int i) {
  int n = AT_T * AT_HS;
  if (!AT_OK) return 0;
  if (what < 20 && i < 0) return 0;
  switch (what) {
  case 0: return i < AT_T ? AP[i] : 0;
  case 1: return i < AT_HS ? AO[i] : 0;
  case 2: return i < AT_T ? ADOT[i] : 0;
  case 3: return i < AT_T ? AS[i] : 0;
  case 4: return i < AT_T ? (long long)AE[i] : 0;
  case 5: return i < AT_T ? AWT[i] : 0;
  case 6: return i < AT_HS ? AACC[i] : 0;
  case 7: return i < AT_HS ? AQ[i] : 0;
  case 8: return i < n ? AK[i] : 0;
  case 9: return i < n ? AV[i] : 0;
  case 10: return i < AT_T ? AKS[i].m : 0;
  case 11: return i < AT_T ? AKS[i].e : 0;
  case 12: return i < AT_T ? AVS[i].m : 0;
  case 13: return i < AT_T ? AVS[i].e : 0;
  case 20: return AT_T;
  case 21: return AT_HS;
  case 22: return AT_KB;
  case 23: return AT_VB;
  case 24: return AT_QM;
  case 25: return AT_QE;
  case 30: return AST.d0;
  case 31: return AST.mx;
  case 32: return (long long)AST.sum;
  case 33: return (long long)AST.R;
  case 34: return AST.emin;
  case 35: return AST.mmax;
  case 36: return AST.G;
  case 37: return AST.have;
  default: return 0;
  }
}
