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
