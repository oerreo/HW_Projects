#ifndef SBENCH_H
#define SBENCH_H
#include <stddef.h>
#include "expect.h"
#include "sx.h"

typedef struct {
  long mismatches; /* failed runs and failed data checks */
  long errors;     /* setup failures */
  int ran;
} sres_t;

/* all runs of the run list for the H variant of one model */
void sbench_model(const exp_model_t *e, sys_t *y, const void *ck, size_t ckn, const void *tk,
                  size_t tkn, const char *src, sres_t *r);

extern const exp_model_t EXP_M1, EXP_M2; /* fpga/sw/src/exp.c */

#endif
