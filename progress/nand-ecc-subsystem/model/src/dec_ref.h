/* Float reference decoders on any H (external codes included). Double precision.
 * Rules: SPA (tanh product), MS with normalization (NMS) or offset (OMS).
 * Schedules: flooding, horizontal layered (one check after another in row order; for a QC code with
 * weight-1 circulants this equals base-row layering because checks of one base row share no variable).
 * Early termination: syndrome of the a-posteriori hard decision after every iteration except the
 * last (same placement as AFF3CT BP_FLOODING / BP_HORIZONTAL_LAYERED with --dec-synd-depth 1).
 * LLR sign convention: positive = bit 0. Hard decision: post < 0 -> 1. */
#ifndef DEC_REF_H
#define DEC_REF_H
#include <stdint.h>
#include "code.h"

enum { DR_SPA = 0, DR_NMS = 1, DR_OMS = 2 };

typedef struct {
  int rule;       /* DR_SPA, DR_NMS (norm = 1 is plain min-sum), DR_OMS */
  int layered;    /* 0 flooding, 1 horizontal layered */
  int iters;      /* maximum iterations */
  double norm;    /* NMS factor */
  double offset;  /* OMS offset */
  int et;         /* 1: syndrome stop */
} dref_cfg_t;

typedef struct {
  const code_t *c;
  dref_cfg_t cfg;
  double *c2v, *v2c, *app, *tv;
  int iters_used;
} dref_t;

int dref_init(dref_t *d, const code_t *c, const dref_cfg_t *cfg);
void dref_free(dref_t *d);
/* llr[n] -> hard[n]; returns 1 if the final hard decision satisfies H */
int dref_decode(dref_t *d, const double *llr, uint8_t *hard);

#endif
