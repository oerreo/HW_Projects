#include "bch.h"
#include "plat.h"
#include <string.h>

void bch_free(bch_t *b)
{
  plat_free(b->exp_t); plat_free(b->log_t); plat_free(b->g); plat_free(b->gw);
  memset(b, 0, sizeof *b);
}

uint16_t gf_inv(const bch_t *b, uint16_t x)
{
  if (!x) return 0;
  return b->exp_t[(b->q1 - b->log_t[x]) % b->q1];
}

int bch_gf_check(const bch_t *b)
{
  int i, x = 1;
  /* alpha^i distinct for i < q1 and alpha^q1 = 1 */
  for (i = 0; i < b->q1; i++) {
    if (b->log_t[b->exp_t[i]] != i) return -1;
    if (i > 0 && b->exp_t[i] == 1) return -1;
  }
  if (b->exp_t[b->q1] != 1) return -1;
  /* every nonzero element times its inverse is 1 */
  for (x = 1; x <= b->q1; x++) if (gf_mul(b, (uint16_t)x, gf_inv(b, (uint16_t)x)) != 1) return -1;
  return 0;
}

int bch_init(bch_t *b, int m, int poly, int t, int k)
{
  int i, j, x, q1 = (1 << m) - 1, deg = 0;
  uint8_t *used, *gtmp;
  memset(b, 0, sizeof *b);
  if (m < 3 || m > 15 || t < 1 || t > BCH_TMAX) return -1;
  b->m = m; b->q1 = q1; b->poly = poly; b->t = t;
  b->exp_t = plat_alloc(sizeof(uint16_t) * 2 * (q1 + 1));
  b->log_t = plat_alloc(sizeof(int16_t) * (q1 + 1));
  used = plat_alloc((size_t)q1 + 1);
  gtmp = plat_alloc((size_t)m * t + 2);
  b->g = plat_alloc((size_t)m * t + 2);
  if (!b->exp_t || !b->log_t || !used || !gtmp || !b->g) { plat_free(used); plat_free(gtmp); bch_free(b); return -1; }
  for (i = 0; i <= q1; i++) b->log_t[i] = -1;
  x = 1;
  for (i = 0; i < 2 * (q1 + 1); i++) {
    b->exp_t[i] = (uint16_t)x;
    if (i < q1 && b->log_t[x] < 0) b->log_t[x] = (int16_t)i;
    x <<= 1;
    if (x >> m) x ^= poly;
  }
  /* g(x) = lcm of minimal polynomials of alpha^1, alpha^3, ..., alpha^(2t-1) */
  b->g[0] = 1;
  for (i = 1; i <= 2 * t - 1; i += 2) {
    uint16_t mp[32];
    int c = i, cl = 0, e;
    if (used[i]) continue;
    memset(mp, 0, sizeof mp);
    mp[0] = 1;
    do {
      /* mp *= (x + alpha^c) */
      uint16_t a = b->exp_t[c];
      used[c] = 1;
      for (e = cl + 1; e >= 1; e--) mp[e] = mp[e - 1] ^ gf_mul(b, mp[e], a);
      mp[0] = gf_mul(b, mp[0], a);
      cl++;
      c = (2 * c) % q1;
    } while (c != i && cl < 31);
    for (e = 0; e <= cl; e++) if (mp[e] > 1) { plat_free(used); plat_free(gtmp); bch_free(b); return -1; }
    /* g *= mp (binary) */
    memset(gtmp, 0, (size_t)m * t + 2);
    for (j = 0; j <= deg; j++)
      if (b->g[j]) for (e = 0; e <= cl; e++) gtmp[j + e] ^= (uint8_t)mp[e];
    deg += cl;
    memcpy(b->g, gtmp, (size_t)deg + 1);
  }
  plat_free(used); plat_free(gtmp);
  b->r = deg;
  b->k = k;
  b->n = k + deg;
  if (b->n > q1) { bch_free(b); return -1; }
  b->words = (deg + 63) / 64;
  b->gw = plat_alloc(sizeof(uint64_t) * b->words);
  for (j = 0; j < deg; j++) if (b->g[j]) b->gw[j / 64] |= 1ull << (j % 64);
  return 0;
}

void bch_encode(const bch_t *b, const uint8_t *u, uint8_t *cw)
{
  uint64_t rem[64];
  const int r = b->r, W = b->words, top = (r - 1) % 64;
  const uint64_t mask = (r % 64) ? ((1ull << (r % 64)) - 1) : ~0ull;
  int j, w;
  memset(rem, 0, sizeof rem);
  for (j = b->k - 1; j >= 0; j--) {
    int fb = (u[j] & 1) ^ (int)((rem[W - 1] >> top) & 1);
    for (w = W - 1; w > 0; w--) rem[w] = (rem[w] << 1) | (rem[w - 1] >> 63);
    rem[0] <<= 1;
    rem[W - 1] &= mask;
    if (fb) for (w = 0; w < W; w++) rem[w] ^= b->gw[w];
  }
  for (j = 0; j < r; j++) cw[j] = (uint8_t)((rem[j / 64] >> (j % 64)) & 1);
  for (j = 0; j < b->k; j++) cw[r + j] = u[j] & 1;
}

int bch_syndromes(const bch_t *b, const uint8_t *rx, uint16_t *S)
{
  int i, j, nz = 0, any = 0;
  static int pos[32768];
  for (i = 0; i < b->n; i++) if (rx[i] & 1) pos[nz++] = i;
  S[0] = 0;
  for (j = 1; j <= 2 * b->t; j += 2) {
    uint16_t acc = 0;
    for (i = 0; i < nz; i++) acc ^= b->exp_t[(int)(((long)pos[i] * j) % b->q1)];
    S[j] = acc;
  }
  for (j = 2; j <= 2 * b->t; j += 2) S[j] = gf_mul(b, S[j / 2], S[j / 2]);
  for (j = 1; j <= 2 * b->t; j++) any |= S[j];
  return any == 0;
}

int bch_bm(const bch_t *b, const uint16_t *S, uint16_t *lam)
{
  /* inversionless Berlekamp-Massey (Sarwate and Shanbhag 2001, iBM), 2t steps */
  const int t = b->t, L = 2 * t + 2;
  uint16_t B[2 * BCH_TMAX + 2], nl[2 * BCH_TMAX + 2], gam = 1;
  int k = 0, r, i, deg = 0;
  memset(lam, 0, sizeof(uint16_t) * (t + 2));
  memset(B, 0, sizeof B);
  {
    uint16_t lm[2 * BCH_TMAX + 2];
    memset(lm, 0, sizeof lm);
    lm[0] = 1; B[0] = 1;
    for (r = 0; r < 2 * t; r++) {
      uint16_t d = 0;
      for (i = 0; i <= r && i < L; i++) if (lm[i]) d ^= gf_mul(b, lm[i], S[r + 1 - i]);
      for (i = 0; i < L; i++) nl[i] = gf_mul(b, gam, lm[i]) ^ (i ? gf_mul(b, d, B[i - 1]) : 0);
      if (d && k >= 0) {
        memcpy(B, lm, sizeof(uint16_t) * L);
        k = -k - 1;
        gam = d;
      } else {
        for (i = L - 1; i > 0; i--) B[i] = B[i - 1];
        B[0] = 0;
        k = k + 1;
      }
      memcpy(lm, nl, sizeof(uint16_t) * L);
    }
    for (i = 0; i < L; i++) if (lm[i]) deg = i;
    for (i = 0; i <= t + 1 && i < L; i++) lam[i] = lm[i];
    if (deg > t) return deg;
  }
  return deg;
}

int bch_chien(const bch_t *b, const uint16_t *lam, int deg, int *pos)
{
  int cur[BCH_TMAX + 2], nr = 0, i, j;
  for (j = 0; j <= deg; j++) cur[j] = lam[j] ? b->log_t[lam[j]] : -1;
  for (i = 0; i < b->n; i++) {
    uint16_t s = 0;
    for (j = 0; j <= deg; j++)
      if (cur[j] >= 0) {
        s ^= b->exp_t[cur[j]];
        cur[j] -= j;            /* next position: times alpha^-j */
        if (cur[j] < 0) cur[j] += b->q1;
      }
    if (!s) { if (nr < BCH_TMAX + 1) pos[nr] = i; nr++; }
  }
  return nr;
}

int bch_decode(const bch_t *b, uint8_t *rx, bch_dbg_t *dbg)
{
  uint16_t S[2 * BCH_TMAX + 1], lam[BCH_TMAX + 2];
  int pos[BCH_TMAX + 2], deg, nr, i;
  if (dbg) memset(dbg, 0, sizeof *dbg);
  if (bch_syndromes(b, rx, S)) return 0;
  deg = bch_bm(b, S, lam);
  if (dbg) { memcpy(dbg->S, S, sizeof S); memcpy(dbg->lam, lam, sizeof lam); dbg->deg = deg; }
  if (deg > b->t) { if (dbg) dbg->fail = 1; return 1; }
  nr = bch_chien(b, lam, deg, pos);
  if (dbg) dbg->nroots = nr;
  if (nr != deg) { if (dbg) dbg->fail = 1; return 1; }
  for (i = 0; i < nr; i++) rx[pos[i]] ^= 1;
  if (dbg) dbg->nerr_fixed = nr;
  return 0;
}
