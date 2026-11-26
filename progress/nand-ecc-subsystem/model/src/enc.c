#include "enc.h"
#include "plat.h"
#include <string.h>

int enc_qc(const code_t *c, const uint8_t *u, uint8_t *cw)
{
  const int mb = c->mb, nb = c->nb, Z = c->Z, ni = nb - mb;
  const short *S = c->S;
  uint8_t lam[64][512];   /* mb <= 64, Z <= 512 (checked) */
  uint8_t *p = cw + ni * Z;
  int r, b, i, s, a, bad = 0;
  if (!c->ddiag || mb > 64 || Z > 512) return -1;
  memcpy(cw, u, (size_t)ni * Z);
  for (r = 0; r < mb; r++) {
    memset(lam[r], 0, (size_t)Z);
    for (b = 0; b < ni; b++) {
      s = S[r * nb + b];
      if (s < 0) continue;
      for (i = 0; i < Z; i++) lam[r][i] ^= u[b * Z + (i + s) % Z];   /* (P^s u_b)[i] */
    }
  }
  /* p0 = sum of all lambda_r (the p0 column sums to I, the dual diagonal cancels) */
  memset(p, 0, (size_t)Z);
  for (r = 0; r < mb; r++)
    for (i = 0; i < Z; i++) p[i] ^= lam[r][i];
  /* row 0: lambda_0 + P^a p0 + p1 = 0 */
  a = S[0 * nb + ni];
  for (i = 0; i < Z; i++) p[Z + i] = lam[0][i] ^ p[(i + a) % Z];
  /* rows 1 .. mb-2: lambda_r + P^{s(r,p0)} p0 + p_r + p_{r+1} = 0 */
  for (r = 1; r < mb - 1; r++) {
    s = S[r * nb + ni];
    for (i = 0; i < Z; i++) {
      uint8_t x = lam[r][i] ^ p[r * Z + i];
      if (s >= 0) x ^= p[(i + s) % Z];
      p[(r + 1) * Z + i] = x;
    }
  }
  /* last row must hold automatically */
  r = mb - 1;
  s = S[r * nb + ni];
  for (i = 0; i < Z; i++) bad |= lam[r][i] ^ p[(i + s) % Z] ^ p[r * Z + i];
  return bad ? -1 : 0;
}

void genc_free(genc_t *g)
{
  plat_free(g->piv_col); plat_free(g->info_col); plat_free(g->A);
  memset(g, 0, sizeof *g);
}

int genc_build(genc_t *g, const code_t *c)
{
  const int n = c->n, m = c->m, W = (n + 63) / 64;
  uint64_t *H = plat_alloc(sizeof(uint64_t) * (size_t)m * W);
  uint8_t *ispiv = plat_alloc((size_t)n);
  int r, e, col, rank = 0, j, i;
  memset(g, 0, sizeof *g);
  if (!H || !ispiv) { plat_free(H); plat_free(ispiv); return -1; }
  for (r = 0; r < m; r++)
    for (e = c->row_ptr[r]; e < c->row_ptr[r + 1]; e++) {
      int v = c->row_var[e];
      H[(size_t)r * W + v / 64] ^= 1ull << (v % 64);
    }
  g->piv_col = plat_alloc(sizeof(int) * (m + 1));
  for (col = n - 1; col >= 0 && rank < m; col--) {
    const int w = col / 64;
    const uint64_t bit = 1ull << (col % 64);
    int pr = -1;
    for (r = rank; r < m; r++) if (H[(size_t)r * W + w] & bit) { pr = r; break; }
    if (pr < 0) continue;
    if (pr != rank)
      for (j = 0; j < W; j++) {
        uint64_t t = H[(size_t)pr * W + j];
        H[(size_t)pr * W + j] = H[(size_t)rank * W + j];
        H[(size_t)rank * W + j] = t;
      }
    for (r = 0; r < m; r++)
      if (r != rank && (H[(size_t)r * W + w] & bit)) {
        uint64_t *dst = H + (size_t)r * W;
        const uint64_t *src = H + (size_t)rank * W;
        for (j = 0; j < W; j++) dst[j] ^= src[j];
      }
    g->piv_col[rank++] = col;
    ispiv[col] = 1;
  }
  g->n = n; g->m = m; g->rank = rank; g->k = n - rank;
  g->info_col = plat_alloc(sizeof(int) * (g->k + 1));
  for (i = 0, j = 0; i < n; i++) if (!ispiv[i]) g->info_col[j++] = i;
  g->words = (g->k + 63) / 64;
  g->A = plat_alloc(sizeof(uint64_t) * (size_t)(rank + 1) * g->words);
  for (r = 0; r < rank; r++)
    for (j = 0; j < g->k; j++) {
      int v = g->info_col[j];
      if (H[(size_t)r * W + v / 64] >> (v % 64) & 1)
        g->A[(size_t)r * g->words + j / 64] |= 1ull << (j % 64);
    }
  plat_free(H); plat_free(ispiv);
  return 0;
}

void genc_encode(const genc_t *g, const uint8_t *u, uint8_t *cw)
{
  uint64_t up[1024];
  int j, r, w;
  if (g->words > 1024) return;
  memset(up, 0, sizeof(uint64_t) * g->words);
  for (j = 0; j < g->k; j++) {
    cw[g->info_col[j]] = u[j] & 1;
    if (u[j] & 1) up[j / 64] |= 1ull << (j % 64);
  }
  for (r = 0; r < g->rank; r++) {
    uint64_t acc = 0;
    const uint64_t *a = g->A + (size_t)r * g->words;
    for (w = 0; w < g->words; w++) acc ^= a[w] & up[w];
    acc ^= acc >> 32; acc ^= acc >> 16; acc ^= acc >> 8; acc ^= acc >> 4; acc ^= acc >> 2; acc ^= acc >> 1;
    cw[g->piv_col[r]] = (uint8_t)(acc & 1);
  }
}
