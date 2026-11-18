/*
 * Thin wrapper around the unmodified llama2.c reference (third_party run.c, MIT),
 * used only by the tests to produce reference tokens and logits. x1.c is a build
 * symlink to data/third_party/llama2c/run.c (see Makefile); nothing is copied.
 */
#define TESTING
#include "x1.c"
#include "ref.h"

struct ref {
  Transformer t;
  Tokenizer tk;
  Sampler s;
};

ref_t *ref_open(const char *ck, const char *tk, int *vocab, int *seq) {
  ref_t *r = calloc(1, sizeof(*r));
  build_transformer(&r->t, (char *)ck);
  build_tokenizer(&r->tk, (char *)tk, r->t.config.vocab_size);
  build_sampler(&r->s, r->t.config.vocab_size, 0.0f, 0.9f, 1234);
  *vocab = r->t.config.vocab_size;
  *seq = r->t.config.seq_len;
  return r;
}

float *ref_forward(ref_t *r, int tok, int pos) { return forward(&r->t, tok, pos); }

void ref_encode(ref_t *r, const char *text, int *toks, int *n) {
  encode(&r->tk, (char *)text, 1, 0, toks, n);
}

const char *ref_decode(ref_t *r, int prev, int tok) { return decode(&r->tk, prev, tok); }

int ref_sample(ref_t *r, float *logits) { return sample(&r->s, logits); }

void ref_close(ref_t *r) {
  free_sampler(&r->s);
  free_tokenizer(&r->tk);
  free_transformer(&r->t);
  free(r);
}
