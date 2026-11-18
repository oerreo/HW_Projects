#ifndef REF_H
#define REF_H
typedef struct ref ref_t;
ref_t *ref_open(const char *ck, const char *tk, int *vocab, int *seq);
float *ref_forward(ref_t *r, int tok, int pos);
void ref_encode(ref_t *r, const char *text, int *toks, int *n);
const char *ref_decode(ref_t *r, int prev, int tok);
int ref_sample(ref_t *r, float *logits); /* temperature 0: argmax */
void ref_close(ref_t *r);
#endif
