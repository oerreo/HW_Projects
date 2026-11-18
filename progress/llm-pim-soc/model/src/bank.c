/*
 * PIM-style banked gemv model (GDDR6-AiM-like, scaled down to BRAM banks).
 * The weight matrix is split into nbank private bank images. The input vector is
 * broadcast once into a global buffer; every bank runs its own MAC over its image;
 * the controller gathers the bank results. Integer only; the result must equal
 * k_gemv bit for bit (tested in tests/t.c).
 *   BANK_ROW: row r lives in bank r % nbank; a bank produces complete outputs.
 *   BANK_COL: bank b holds columns [c0[b], c1[b]) of every row; banks produce int32
 *             partial group sums that the controller adds before scaling.
 */
#include <string.h>
#include "llm.h"

static int32_t sat32(int64_t x) {
  if (x > 2147483647LL) return 2147483647;
  if (x < -2147483647LL - 1) return (int32_t)(-2147483647LL - 1);
  return (int32_t)x;
}

void bank_pack(bank_mat_t *b, const lm_hm_t *m, int nbank, int mode, lm_arena_t *a) {
  int ng = m->n / m->gs, k;
  b->nbank = nbank;
  b->mode = mode;
  b->rows = m->rows;
  b->n = m->n;
  b->gs = m->gs;
  b->we = m->we;
  b->m = m->m;
  b->bw = lm_take(a, sizeof(int8_t *) * nbank);
  b->bm = lm_take(a, sizeof(uint16_t *) * nbank);
  b->brows = lm_take(a, sizeof(int) * nbank);
  b->c0 = lm_take(a, sizeof(int) * nbank);
  b->c1 = lm_take(a, sizeof(int) * nbank);
  for (k = 0; k < nbank; k++) {
    int rb = (m->rows - k + nbank - 1) / nbank;
    int c0 = (int)((long)k * m->n / nbank), c1 = (int)((long)(k + 1) * m->n / nbank);
    void *pw, *pm = NULL;
    if (mode == BANK_ROW) {
      pw = lm_take(a, (size_t)rb * m->n);
      pm = lm_take(a, sizeof(uint16_t) * (size_t)rb * ng);
    } else {
      pw = lm_take(a, (size_t)m->rows * (c1 - c0));
    }
    if (!a->base || a->fail) continue;
    b->bw[k] = pw;
    b->bm[k] = pm;
    b->brows[k] = rb;
    b->c0[k] = c0;
    b->c1[k] = c1;
    if (mode == BANK_ROW) {
      int i;
      for (i = 0; i < rb; i++) {
        int r = i * nbank + k;
        memcpy(b->bw[k] + (size_t)i * m->n, m->q + (size_t)r * m->n, (size_t)m->n);
        memcpy(b->bm[k] + (size_t)i * ng, m->m + (size_t)r * ng, sizeof(uint16_t) * ng);
      }
    } else {
      int r;
      for (r = 0; r < m->rows; r++)
        memcpy(b->bw[k] + (size_t)r * (c1 - c0), m->q + (size_t)r * m->n + c0, (size_t)(c1 - c0));
    }
  }
}

static long cdiv(long a, long b) { return (a + b - 1) / b; }

void bank_gemv(const bank_mat_t *b, const int8_t *x, kscl_t xs, int fo, int32_t *y,
               int8_t *gbuf, int32_t *part, bank_stat_t *st) {
  int N = b->nbank, n = b->n, gs = b->gs, ng = n / gs, sh = b->we + xs.e - fo, k, r, g, i;
  memcpy(gbuf, x, (size_t)n); /* broadcast into the global buffer */
  st->wrgb += cdiv(n, 32);
  if (b->mode == BANK_ROW) {
    long maxr = 0;
    for (k = 0; k < N; k++) {
      const int8_t *bw = b->bw[k];
      const uint16_t *bm = b->bm[k];
      if (b->brows[k] > maxr) maxr = b->brows[k];
      for (i = 0; i < b->brows[k]; i++) {
        int64_t S = 0; /* bank MAC register */
        for (g = 0; g < ng; g++) {
          int32_t acc = 0;
          int c;
          for (c = 0; c < gs; c++)
            acc += (int32_t)bw[(size_t)i * n + g * gs + c] * (int32_t)gbuf[g * gs + c];
          S += (int64_t)acc * bm[(size_t)i * ng + g];
        }
        y[i * N + k] = sat32(k_rshr(S * xs.m, sh));
      }
    }
    st->mac += maxr * cdiv(n, BANK_LANES);
    st->rdmac += b->rows;
  } else {
    long maxc = 0;
    for (k = 0; k < N; k++) {
      int c0 = b->c0[k], c1 = b->c1[k], w = c1 - c0;
      const int8_t *bw = b->bw[k];
      if (w > maxc) maxc = w;
      for (r = 0; r < b->rows; r++) {
        int32_t *pp = part + ((size_t)k * b->rows + r) * ng;
        for (g = 0; g < ng; g++) pp[g] = 0;
        for (i = 0; i < w; i++) {
          int col = c0 + i;
          pp[col / gs] += (int32_t)bw[(size_t)r * w + i] * (int32_t)gbuf[col];
        }
      }
    }
    for (r = 0; r < b->rows; r++) { /* controller gather */
      int64_t S = 0;
      for (g = 0; g < ng; g++) {
        int32_t acc = 0; /* sum of partials of one group == the group sum, < 2^31 */
        for (k = 0; k < N; k++) acc += part[((size_t)k * b->rows + r) * ng + g];
        S += (int64_t)acc * b->m[(size_t)r * ng + g];
      }
      y[r] = sat32(k_rshr(S * xs.m, sh));
    }
    st->mac += b->rows * cdiv(maxc, BANK_LANES);
    st->rdmac += (long)N * b->rows * ng;
  }
}
