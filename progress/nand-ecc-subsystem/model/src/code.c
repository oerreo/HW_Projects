#include "code.h"
#include "plat.h"
#include <stdlib.h>
#include <string.h>

void code_free(code_t *c)
{
  plat_free(c->row_ptr); plat_free(c->row_var);
  plat_free(c->col_ptr); plat_free(c->col_edge);
  plat_free(c->S);
  memset(c, 0, sizeof *c);
}

int code_from_rows(code_t *c, int n, int m, const int *row_ptr, const int *row_var)
{
  int e, v, r;
  int *fill;
  memset(c, 0, sizeof *c);
  c->n = n; c->m = m; c->nedge = row_ptr[m];
  c->row_ptr = plat_alloc(sizeof(int) * (m + 1));
  c->row_var = plat_alloc(sizeof(int) * (c->nedge + 1));
  c->col_ptr = plat_alloc(sizeof(int) * (n + 1));
  c->col_edge = plat_alloc(sizeof(int) * (c->nedge + 1));
  fill = plat_alloc(sizeof(int) * (n + 1));
  if (!c->row_ptr || !c->row_var || !c->col_ptr || !c->col_edge || !fill) { plat_free(fill); code_free(c); return -1; }
  memcpy(c->row_ptr, row_ptr, sizeof(int) * (m + 1));
  memcpy(c->row_var, row_var, sizeof(int) * c->nedge);
  for (e = 0; e < c->nedge; e++) {
    if (row_var[e] < 0 || row_var[e] >= n) { plat_free(fill); code_free(c); return -1; }
    c->col_ptr[row_var[e] + 1]++;
  }
  for (v = 0; v < n; v++) c->col_ptr[v + 1] += c->col_ptr[v];
  for (r = 0; r < m; r++) {
    int d = row_ptr[r + 1] - row_ptr[r];
    if (d > c->dc_max) c->dc_max = d;
    for (e = row_ptr[r]; e < row_ptr[r + 1]; e++) {
      v = row_var[e];
      c->col_edge[c->col_ptr[v] + fill[v]++] = e;
    }
  }
  for (v = 0; v < n; v++) {
    int d = c->col_ptr[v + 1] - c->col_ptr[v];
    if (d > c->dv_max) c->dv_max = d;
  }
  plat_free(fill);
  c->k = n - m; /* design value; the true dimension needs the rank (genc.c) */
  return 0;
}

static int ddiag_check(const code_t *c)
{
  int mb = c->mb, nb = c->nb, r, k, p0 = nb - mb, a, nj = 0;
  const short *S = c->S;
  if (mb < 3) return 0;
  a = S[0 * nb + p0];
  if (a < 0 || S[(mb - 1) * nb + p0] != a) return 0;
  for (r = 1; r < mb - 1; r++) {
    int s = S[r * nb + p0];
    if (s == 0) nj++;
    else if (s != -1) return 0;
  }
  if (nj != 1) return 0;
  for (k = 1; k < mb; k++)
    for (r = 0; r < mb; r++) {
      int s = S[r * nb + p0 + k];
      int want = (r == k - 1 || r == k) ? 0 : -1;
      if (s != want) return 0;
    }
  return 1;
}

int code_from_qc(code_t *c, int mb, int nb, int Z, const short *S)
{
  int r, i, b, e = 0, rc;
  int m = mb * Z, n = nb * Z, ne = 0;
  int *rp, *rv;
  short *Sc;
  for (r = 0; r < mb * nb; r++) {
    if (S[r] < -1 || S[r] >= Z) return -1;
    if (S[r] >= 0) ne++;
  }
  ne *= Z;
  rp = plat_alloc(sizeof(int) * (m + 1));
  rv = plat_alloc(sizeof(int) * (ne + 1));
  Sc = plat_alloc(sizeof(short) * mb * nb);
  if (!rp || !rv || !Sc) { plat_free(rp); plat_free(rv); plat_free(Sc); return -1; }
  for (r = 0; r < mb; r++)
    for (i = 0; i < Z; i++) {
      rp[r * Z + i] = e;
      for (b = 0; b < nb; b++) {
        int s = S[r * nb + b];
        if (s >= 0) rv[e++] = b * Z + (i + s) % Z;
      }
    }
  rp[m] = e;
  rc = code_from_rows(c, n, m, rp, rv);
  plat_free(rp); plat_free(rv);
  if (rc) { plat_free(Sc); return rc; }
  memcpy(Sc, S, sizeof(short) * mb * nb);
  c->qc = 1; c->mb = mb; c->nb = nb; c->Z = Z; c->S = Sc;
  c->ddiag = ddiag_check(c);
  c->k = (nb - mb) * Z;
  return 0;
}

/* next integer in text, skipping whitespace and '#' comment lines; returns 0 at end */
static int next_int(const char **p, long *out)
{
  const char *s = *p;
  char *end;
  for (;;) {
    while (*s == ' ' || *s == '\t' || *s == '\r' || *s == '\n') s++;
    if (*s == '#') { while (*s && *s != '\n') s++; continue; }
    break;
  }
  if (!*s) return 0;
  *out = strtol(s, &end, 10);
  if (end == s) return 0;
  *p = end;
  return 1;
}

int code_parse_qc(code_t *c, const char *text)
{
  const char *p = text;
  long mb, nb, Z, v;
  short *S;
  int i, rc;
  if (!next_int(&p, &mb) || !next_int(&p, &nb) || !next_int(&p, &Z)) return -1;
  if (mb <= 0 || nb <= mb || Z <= 0 || mb * nb > 100000) return -1;
  S = plat_alloc(sizeof(short) * mb * nb);
  if (!S) return -1;
  for (i = 0; i < mb * nb; i++) {
    if (!next_int(&p, &v)) { plat_free(S); return -1; }
    S[i] = (short)v;
  }
  rc = code_from_qc(c, (int)mb, (int)nb, (int)Z, S);
  plat_free(S);
  return rc;
}

int code_parse_alist(code_t *c, const char *text)
{
  const char *p = text;
  long n, m, dvm, dcm, v;
  int i, j, e = 0, rc;
  int *rp, *rv, *dc;
  if (!next_int(&p, &n) || !next_int(&p, &m) || !next_int(&p, &dvm) || !next_int(&p, &dcm)) return -1;
  if (n <= 0 || m <= 0) return -1;
  dc = plat_alloc(sizeof(int) * m);
  rp = plat_alloc(sizeof(int) * (m + 1));
  rv = plat_alloc(sizeof(int) * (m * dcm + 1));
  if (!dc || !rp || !rv) { rc = -1; goto out; }
  for (i = 0; i < n; i++) if (!next_int(&p, &v)) { rc = -1; goto out; }   /* column weights */
  for (i = 0; i < m; i++) { if (!next_int(&p, &v) || v > dcm) { rc = -1; goto out; } dc[i] = (int)v; }
  /* column lists: dvm entries per column (0 = padding), skipped */
  for (i = 0; i < n * dvm; i++) if (!next_int(&p, &v)) { rc = -1; goto out; }
  for (i = 0; i < m; i++) {
    rp[i] = e;
    for (j = 0; j < dcm; j++) {
      if (!next_int(&p, &v)) { rc = -1; goto out; }
      if (j < dc[i]) {
        if (v < 1 || v > n) { rc = -1; goto out; }
        rv[e++] = (int)v - 1;
      }
    }
  }
  rp[m] = e;
  rc = code_from_rows(c, (int)n, (int)m, rp, rv);
out:
  plat_free(dc); plat_free(rp); plat_free(rv);
  return rc;
}

int code_syndrome(const code_t *c, const uint8_t *x)
{
  int r, e, bad = 0;
  for (r = 0; r < c->m; r++) {
    int s = 0;
    for (e = c->row_ptr[r]; e < c->row_ptr[r + 1]; e++) s ^= x[c->row_var[e]];
    bad += s;
  }
  return bad;
}
