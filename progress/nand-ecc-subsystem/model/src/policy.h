/* Read retry policy (scope.md 2.2): HARD(ref0) -> DEC_H -> RETRY k = 1..K (hard read with offsets) ->
 * SOFT stages (levels L1 < L2 < ...) -> FAIL. Every stage re-reads the same cells (same grid region q),
 * so reads are mutually consistent. The decoder is the fixed-point golden (dec_fix) for every stage;
 * hard stages feed +-A. A stage succeeds when the decoder's ok flag is set (what a controller sees);
 * an ok frame whose output differs from the written codeword is counted as undetected.
 * Latency model: [R7] eq. (1) extended over the stages; sense/transfer constants are inputs. */
#ifndef POLICY_H
#define POLICY_H
#include <stdint.h>
#include "sense.h"
#include "llr.h"
#include "dec_fix.h"

#define POL_MAXRETRY 8
#define POL_MAXSOFT 4

typedef struct {
  int nretry;
  int roff[POL_MAXRETRY][4];   /* retry offsets per boundary, grid steps */
  int nsoft;
  int soft_levels[POL_MAXSOFT];
  int dstep;                   /* soft spacing, grid steps */
  int hardA;                   /* hard LLR magnitude */
  double scale;                /* soft LLR scale */
  /* latency model constants (us) */
  double t_sense_hard, t_sense_level, t_xfer_byte, t_dec_iter;
} pol_cfg_t;

typedef struct {
  pol_cfg_t cfg;
  int nst;                     /* stages: 1 + nretry + nsoft */
  rdcfg_t rc[1 + POL_MAXRETRY + POL_MAXSOFT];
  llrlut_t lut[1 + POL_MAXRETRY + POL_MAXSOFT];
  double t_stage[1 + POL_MAXRETRY + POL_MAXSOFT];   /* sense + transfer time of each stage */
} pol_t;

typedef struct {
  int stage;          /* index of the successful stage, -1 = FAIL */
  int undetected;     /* ok flag set but output != codeword */
  int iters;          /* total decoder iterations over all stages */
  double latency_us;
} pol_res_t;

/* nominal: channel the LUTs are built from; w: LLR width */
int policy_init(pol_t *p, const pol_cfg_t *cfg, const grid_t *g, const chan_t *nominal, int w);
/* K_POLICY: run the stages for one codeword (q = grid regions of its cells). llr scratch n int8. */
void policy_run(const pol_t *p, dfix_t *dec, const uint8_t *q, const uint8_t *cw, int8_t *llr, pol_res_t *res);

#endif
