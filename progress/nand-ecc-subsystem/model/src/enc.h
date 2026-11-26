/* Encoders. Bits are uint8_t 0/1, one per byte.
 * enc_qc: dual-diagonal back substitution (docs/spec/code.md 2.3), linear time, K_ENC.
 * genc_*: generic systematic encoder from any H by GF(2) elimination (external codes, rank). */
#ifndef ENC_H
#define ENC_H
#include <stdint.h>
#include "code.h"

/* u[k] information bits (k = (nb-mb)*Z), cw[n] = [u | p0 | p1 .. p_{mb-1}]. Requires c->ddiag.
 * Returns 0, or -1 if the last base row is not satisfied (structure error). */
int enc_qc(const code_t *c, const uint8_t *u, uint8_t *cw);

typedef struct {
  int n, m, rank, k;
  int *piv_col;     /* rank: pivot (parity) column of reduced row i */
  int *info_col;    /* k: information columns, ascending */
  int words;        /* 64-bit words per reduced row (over the k information columns) */
  uint64_t *A;      /* rank x words: parity bit i = <A_i, u> over GF(2) */
} genc_t;

/* Gaussian elimination of H (pivots searched from the last column down, so information bits are
 * the low-index columns whenever possible). Returns 0 on success. */
int genc_build(genc_t *g, const code_t *c);
void genc_free(genc_t *g);
/* u[k] -> cw[n] with cw[info_col[j]] = u[j] */
void genc_encode(const genc_t *g, const uint8_t *u, uint8_t *cw);

#endif
