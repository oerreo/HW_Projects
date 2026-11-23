/*
 * Small llama2-architecture inference golden model: F (float), Q (int8 matmul, float
 * nonlinear) and H (all integer, bit-exact hardware kernels) variants.
 *
 * Portability rules: no file I/O and no dynamic allocation in this library. All
 * memory comes from one caller-provided block through lm_arena_t (init only). The
 * PC tools in tools/ do file I/O and allocate that block once.
 */
#ifndef LLM_H
#define LLM_H
#include <stddef.h>
#include <stdint.h>
#include "kern.h"

typedef struct {
  int dim, hidden_dim, n_layers, n_heads, n_kv_heads, vocab_size, seq_len;
} lm_cfg_t;

/* bump allocator; base == NULL is a sizing pass that only advances off */
typedef struct {
  uint8_t *base;
  size_t off, cap;
  int fail;
} lm_arena_t;
void *lm_take(lm_arena_t *a, size_t bytes);

/* ---------------- checkpoint (llama2.c version 0 layout) ---------------- */
typedef struct {
  const float *emb, *rms_att, *wq, *wk, *wv, *wo, *rms_ffn, *w1, *w2, *w3, *rms_final, *wcls;
  int shared;
} lm_fw_t;
int lm_ckpt_parse(const void *img, size_t len, lm_cfg_t *c, lm_fw_t *w);

/* ---------------- tokenizer ---------------- */
typedef struct {
  int n, maxlen;
  char **vocab;
  float *score;
  int *sorted;
  char *buf;
  unsigned char bytes[512];
} lm_tok_t;
int lm_tok_init(lm_tok_t *t, const void *img, size_t len, int vocab, lm_arena_t *a);
/* tokens must hold strlen(text) + 3 entries */
void lm_tok_encode(lm_tok_t *t, const char *text, int bos, int eos, int *tokens, int *n);
const char *lm_tok_decode(const lm_tok_t *t, int prev, int tok);
int lm_tok_printable(const char *piece); /* 0 for a lone unprintable byte */

/* ---------------- F variant ---------------- */
typedef struct {
  float *x, *xb, *xb2, *hb, *hb2, *q, *k, *v, *kc, *vc, *att, *logits;
} lm_fs_t;
void lm_f_alloc(lm_fs_t *s, const lm_cfg_t *c, lm_arena_t *a);
float *lm_f_forward(lm_fs_t *s, const lm_cfg_t *c, const lm_fw_t *w, int tok, int pos);

/* ---------------- Q variant ---------------- */
typedef struct {
  int8_t *q;
  float *s; /* one scale per (row, group) */
  int rows, n, gs;
} lm_qm_t;
typedef struct {
  lm_qm_t *wq, *wk, *wv, *wo, *w1, *w2, *w3, cls;
  float *emb; /* dequantized embedding (same int8 storage as cls) */
  const lm_fw_t *fw;
  int gs_target;
} lm_qw_t;
typedef struct {
  lm_fs_t f;
  int8_t *xq;
  float *xs;
} lm_qs_t;
int lm_group(int n, int target); /* largest divisor of n <= target (target <= 0: n) */
void lm_q_build(lm_qw_t *w, const lm_cfg_t *c, const lm_fw_t *fw, int gs_target, lm_arena_t *a);
void lm_q_alloc(lm_qs_t *s, const lm_cfg_t *c, lm_arena_t *a);
float *lm_q_forward(lm_qs_t *s, const lm_cfg_t *c, const lm_qw_t *w, int tok, int pos);

/* ---------------- H variant ---------------- */
typedef struct {
  const char *name;
  int act_mode;  /* ACT_POW2 or ACT_MANT */
  int wgs;       /* weight group size target, 0 = whole row */
  int exp_bits;  /* exp2 LUT index bits (4..8) */
  int sig_bits;  /* sigmoid LUT index bits (4..8) */
  int kv16;      /* 1: q, k, v quantized to int16 for attention */
  /* S2b additions (0 keeps the behaviour above bit for bit) */
  int kbits;     /* q and K bits 8, 12 or 16 (attention through K_ATTN2); 0: from kv16, K_ATTN */
  int vbits;     /* V bits 8, 12 or 16, used when kbits != 0 */
  int win;       /* attention window: only the last win positions are attended; 0: all */
} lm_hfmt_t;
typedef struct {
  int8_t *q;
  uint16_t *m; /* mantissa per (row, group); scale = m * 2^-we */
  int we, rows, n, gs;
} lm_hm_t;
typedef struct {
  int16_t *g; /* rmsnorm gain * sqrt(n), real = g * 2^-ge */
  int ge;
} lm_hg_t;
typedef struct {
  lm_hfmt_t f;
  lm_hm_t *wq, *wk, *wv, *wo, *w1, *w2, *w3, cls; /* cls also serves the embedding */
  lm_hg_t *ra, *rf, rfin;
  int16_t *rope; /* [seq_len][head_size]: (cos, sin) pairs, Q14 */
  const uint32_t *elut, *slut;
  int32_t epsc;  /* round(dim * 1e-5 * 2^(2 K_FX)) */
} lm_hw_t;
typedef struct {
  int32_t *x, *x2, *y, *q, *qr, *k, *kr, *v, *att, *h1, *h3, *logits, *p, *argmax;
  int8_t *a8;  /* int8 gemv input */
  kscl_t *as;  /* its scale */
  void *qh;    /* quantized q head */
  kscl_t *qhs;
  void *kc, *vc;   /* [layer][kv_head][seq_len][head_size], int8 or int16 */
  kscl_t *kcs, *vcs; /* [layer][kv_head][seq_len] */
} lm_hs_t;
void lm_h_build(lm_hw_t *w, const lm_cfg_t *c, const lm_fw_t *fw, const lm_hfmt_t *f, lm_arena_t *a);
void lm_h_alloc(lm_hs_t *s, const lm_cfg_t *c, const lm_hfmt_t *f, lm_arena_t *a);
const int32_t *lm_h_forward(lm_hs_t *s, const lm_cfg_t *c, const lm_hw_t *w, int tok, int pos,
                            const k_hook_t *hook);
/* Executor insertion point (S5-1, system.md 2.1 / O3). Every kernel call of the forward pass
 * goes through fn(user, c) instead of k_exec(c) when ex and ex->fn are not NULL; the call
 * order and the descriptors are the same. fn returns 0 or a negative error like k_exec. The
 * hook (if any) still sees phase 0 before and phase 1 after each call. lm_h_forward(...) is
 * lm_h_forward_x(..., NULL) and its results are unchanged bit for bit. */
typedef int (*k_exec_fn)(void *user, const kcall_t *c);
typedef struct { k_exec_fn fn; void *user; } k_exec_t;
const int32_t *lm_h_forward_x(lm_hs_t *s, const lm_cfg_t *c, const lm_hw_t *w, int tok, int pos,
                              const k_hook_t *hook, const k_exec_t *ex);

/* ---------------- PIM-style banked gemv model ---------------- */
#define BANK_ROW 0 /* rows interleaved over banks, each bank produces whole outputs */
#define BANK_COL 1 /* columns split over banks, partial int32 sums gathered */
typedef struct {
  int nbank, mode, rows, n, gs, we;
  int8_t **bw;     /* per-bank weight image */
  uint16_t **bm;   /* per-bank mantissa image (ROW mode) */
  const uint16_t *m; /* full mantissa table (COL mode gather) */
  int *brows;      /* rows per bank (ROW) */
  int *c0, *c1;    /* column range per bank (COL) */
} bank_mat_t;
typedef struct {
  long wrgb, mac, rdmac; /* commands: vector broadcasts, all-bank MAC steps, result reads */
} bank_stat_t;
void bank_pack(bank_mat_t *b, const lm_hm_t *m, int nbank, int mode, lm_arena_t *a);
#define BANK_LANES 16 /* int8 MACs per bank per all-bank MAC command (stat model only) */
/* scratch: gbuf int8[n] (global buffer), part int32[nbank * rows * (n / gs)] (COL partials) */
void bank_gemv(const bank_mat_t *b, const int8_t *x, kscl_t xs, int fo, int32_t *y,
               int8_t *gbuf, int32_t *part, bank_stat_t *st);

/* ---- PIM bank RAM image (arch.md 3.1, 3.3; S4-1 A6) ----
 * BANK_ROW over nb banks of BIMG_LB lanes. One bank word = BIMG_LB int8 weights (lane i =
 * column w * BIMG_LB + i of the row, columns >= n are 0) and a 16-bit tag. The tag of the
 * first word of a row holds the row mantissa wm, the tags of the other words are 0
 * (RTL word: bits [8i+7:8i] = lane i, bits [143:128] = tag). Row r of a matrix with
 * gs == n lives in bank r % nb at word base + (r / nb) * nw, nw = ceil(n / BIMG_LB). */
#define BIMG_LB 16
typedef struct {
  int8_t d[BIMG_LB];
  uint16_t tag;
} bimg_word_t;
int bimg_nw(int n);
/* words per bank for a rows x n matrix: ceil(rows / nb) * nw */
long bimg_words(int rows, int n, int nb);
/* writes W (rows x n, int8) and wm (one mantissa per row) at base; returns the words used
   per bank, or -1 if base + words > depth */
long bimg_pack(bimg_word_t *const *img, int nb, long depth, long base, const int8_t *W,
               const uint16_t *wm, int rows, int n);
/* rebuilds a BANK_ROW bank_mat_t (gs = n, weights and mantissas taken from the image only)
   with arena memory; returns the number of format violations (non-zero padding lane or
   non-zero tag outside the first word of a row) */
long bimg_unpack(bank_mat_t *b, const bimg_word_t *const *img, int nb, long base, int rows,
                 int n, int we, lm_arena_t *a);

/* ---- gemv row records of the accelerator IP (arch.md 2.2; S4-1) ----
 * Per row: 8 B header (wm little-endian in bytes 0..1, bytes 2..7 zero) and the n int8
 * weights padded with zeros to a multiple of 8 B. Rows follow each other. */
#define RREC_HDR 8
long rrec_bytes(int rows, int n);
long rrec_pack(uint8_t *out, const int8_t *W, const uint16_t *wm, int rows, int n);
/* inverse of rrec_pack; returns the number of non-zero header or padding bytes */
long rrec_unpack(const uint8_t *in, int rows, int n, int8_t *W, uint16_t *wm);

#endif
