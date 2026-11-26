/* Binary BCH over GF(2^m), shortened (scope.md 2.1, decision D9: C only).
 * Default: m = 14, primitive polynomial x^14 + x^10 + x^6 + x + 1, t = 73, n = 9207, k = 8192,
 * parity r = deg g = 1015. Codeword c(x) = sum c_i x^i, c[i] = c_i: parity c_0..c_{r-1},
 * information c_{r+j} = u_j. Decoder: syndromes S_1..S_2t, inversionless Berlekamp-Massey,
 * Chien search over positions 0..n-1; failure rule = AFF3CT STD: if the number of roots found
 * differs from deg(Lambda) (or deg > t), the received word is returned unchanged. */
#ifndef BCH_H
#define BCH_H
#include <stdint.h>

#define BCH_TMAX 128
typedef struct {
  int m, q1, poly, t, n, k, r;
  uint16_t *exp_t;   /* 2*q1 entries */
  int16_t *log_t;    /* 2^m entries, log 0 = -1 */
  uint8_t *g;        /* generator coefficients g_0..g_r */
  uint64_t *gw;      /* generator low r coefficients packed (LFSR feedback) */
  int words;
} bch_t;

typedef struct {
  uint16_t S[2 * BCH_TMAX + 1];
  uint16_t lam[BCH_TMAX + 2];
  int deg, nroots, fail, nerr_fixed;
} bch_dbg_t;

int bch_init(bch_t *b, int m, int poly, int t, int k);
void bch_free(bch_t *b);
/* returns 0 if alpha has order 2^m - 1 and exp/log tables are consistent (self check) */
int bch_gf_check(const bch_t *b);
static inline uint16_t gf_mul(const bch_t *b, uint16_t x, uint16_t y)
{
  if (!x || !y) return 0;
  return b->exp_t[b->log_t[x] + b->log_t[y]];
}
uint16_t gf_inv(const bch_t *b, uint16_t x);

void bch_encode(const bch_t *b, const uint8_t *u, uint8_t *cw);   /* K_BCH_ENC */
int bch_syndromes(const bch_t *b, const uint8_t *rx, uint16_t *S);  /* K_BCH_SYND; returns 1 if all zero */
int bch_bm(const bch_t *b, const uint16_t *S, uint16_t *lam);       /* K_BCH_BM; returns degree */
int bch_chien(const bch_t *b, const uint16_t *lam, int deg, int *pos); /* K_BCH_CHIEN; returns #roots */
/* full decode in place; returns 0 ok (possibly a miscorrection), 1 detected failure. dbg may be NULL */
int bch_decode(const bch_t *b, uint8_t *rx, bch_dbg_t *dbg);

#endif
