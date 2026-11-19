/*
 * Expected values computed on the PC by tools/gen_expect.c (model/tools/io.c
 * golden driver + model/src). The generated headers ../expect/exp_m1.h and
 * exp_m2.h define one exp_model_t each (EXP_M1, EXP_M2).
 *
 * Generation loop (both here and in gen_expect): tokens = encode(prompt, BOS);
 * cur = tokens[0]; for pos in 0..steps-1: a = argmax(forward(cur, pos));
 * cur = pos + 1 < nptok ? tokens[pos + 1] : a. No stop at BOS, so every run has
 * exactly `steps` forward passes.
 */
#ifndef EXPECT_H
#define EXPECT_H
#include <stdint.h>

enum { VK_F = 0, VK_Q = 1, VK_H = 2 };

/* H number format, the integer fields of lm_hfmt_t (gen_expect checks that these
 * fields reproduce the whole lm_hfmt_t of model/tools/io.c) */
typedef struct {
  int act_mode, wgs, exp_bits, sig_bits, kv16, kbits, vbits, win;
} exp_hfmt_t;

typedef struct {
  const char *name;     /* "F", "Qg", "HD", ... */
  int kind;             /* VK_F, VK_Q, VK_H */
  int qgs;              /* Q: group size target (0 = whole row) */
  exp_hfmt_t hf;        /* H: format */
  const int32_t *tok;   /* argmax at each position [steps] */
  const uint32_t *lh;   /* hash of the logits at each position [steps] */
  uint32_t whash;       /* hash of the quantized weights (Q, H), 0 for F */
} exp_var_t;

typedef struct {
  const char *model;    /* "260K", "15M" */
  int dim, hidden, layers, heads, kv_heads, vocab, seq_len;
  uint32_t ck_len, ck_hash, tk_len, tk_hash; /* checkpoint and tokenizer images */
  const char *prompt;
  int pidx;             /* line index in data/prompts/prompts.txt */
  int nptok;
  const int32_t *ptok;  /* encoded prompt with BOS */
  int steps;
  const int16_t *rope;  /* H RoPE table of the PC build [seq_len * head_size] */
  int rope_n;
  uint32_t rope_hash;
  int corrupt;          /* 1: deliberately wrong values (negative test only) */
  int nvar;
  exp_var_t var[4];
} exp_model_t;

#endif
