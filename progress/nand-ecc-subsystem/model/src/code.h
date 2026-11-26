/* Parity-check matrix representation (docs/spec/code.md 2).
 * Sparse H as check -> variable lists (CSR, edge order) and variable -> edge lists.
 * QC codes keep the base shift table; external codes come from alist text. */
#ifndef CODE_H
#define CODE_H
#include <stdint.h>

typedef struct {
  int n, m, nedge;
  int *row_ptr;   /* m + 1 */
  int *row_var;   /* nedge: variable of edge e (edges grouped by check) */
  int *col_ptr;   /* n + 1 */
  int *col_edge;  /* nedge: edges of variable v (col_ptr[v] .. col_ptr[v+1]-1) */
  int dc_max, dv_max;
  /* QC description (qc = 1): base mb x nb, lifting Z, S[r*nb + c] in {-1, 0..Z-1} */
  int qc, mb, nb, Z;
  short *S;
  int k;          /* information length used by the encoder (QC dual diagonal: (nb-mb)*Z) */
  int ddiag;      /* 1: parity part is the dual-diagonal structure of code.md 2.3 (enc_qc usable) */
} code_t;

/* QC table text (code.md 2.2): '#' lines skipped, then "mb nb Z" and mb rows of nb shifts.
 * Expanded check (r, i) = r*Z + i connects variable c*Z + (i + s) mod Z for every block column c
 * with s = S[r][c] >= 0, edges in ascending c. Returns 0 on success. */
int code_parse_qc(code_t *c, const char *text);
int code_from_qc(code_t *c, int mb, int nb, int Z, const short *S);
/* alist text (MacKay format; a first line starting with '#' is skipped). Edges of a check in the
 * order listed in the check (row) section. */
int code_parse_alist(code_t *c, const char *text);
/* from explicit check lists */
int code_from_rows(code_t *c, int n, int m, const int *row_ptr, const int *row_var);
void code_free(code_t *c);

/* number of unsatisfied checks for hard decisions x[n] (0/1) */
int code_syndrome(const code_t *c, const uint8_t *x);

#endif
