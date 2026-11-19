#ifndef BENCH_H
#define BENCH_H
#include <stddef.h>
#include <stdint.h>
#include "expect.h"

typedef struct {
  long mismatches; /* required comparisons that failed */
  long errors;     /* kernel errors, setup failures */
  int ran;
} bres_t;

/* runs every selected variant of one model; ck/tk are the checkpoint and tokenizer
 * images (ckn/tkn bytes). Prints its log lines and adds to r. */
void bench_model(const exp_model_t *e, const void *ck, size_t ckn, const void *tk, size_t tkn,
                 const char *src, bres_t *r);

/* probe overhead and clock lines (OVH, CLK) */
void bench_overhead(void);

extern const exp_model_t EXP_M1, EXP_M2;

#endif
