/* Sensing grid, integer inverse-CDF cell sampler, read configurations (channel.md 4, 7; decision H2, H3).
 *
 * Grid: for every hard boundary b of a page, G points e = R_b + k*step, k = -(G-1)/2 .. (G-1)/2,
 * all points ascending (npt = B*G <= 63). Grid region q of a cell = number of grid points below its
 * Vth (0..npt). Table T[s][j] = min(round(2^32 * P(Vth <= e_j | s)), 2^32 - 1) (built in double,
 * exchanged as integers). Sample (bit-exact, numeric.md 2): per cell r1 = next(), u = next();
 * state = state_of[bit][r1 >> (32 - other_bits)], q = #{ j : u >= T[state][j] }. */
#ifndef SENSE_H
#define SENSE_H
#include <stdint.h>
#include "chan.h"
#include "rng.h"

#define GRID_MAX 63

typedef struct {
  int page, B, G, npt, nstate, other_bits;
  double step;
  int bstate[4];          /* lower state of each boundary */
  double ref[4];          /* grid centre of each boundary */
  double e[GRID_MAX];     /* grid voltages, ascending */
  uint32_t T[8][GRID_MAX];
  uint8_t pbit[8];
  uint8_t state_of[2][4]; /* [page bit][other-page index] -> state (states ascending) */
} grid_t;

/* ref == NULL: centres at the optimal thresholds of ch (chan_ref_opt) */
int grid_build(grid_t *g, const chan_t *ch, int page, int G, double step, const double *ref);
/* replace the tables with another channel condition on the same voltages (mismatch experiments) */
void grid_tables(grid_t *g, const chan_t *ch);

/* K_CHAN: bits[n] -> q[n] (grid region) */
void chan_sample(const grid_t *g, const uint8_t *bits, int n, rng_t *r, uint8_t *q);
/* reference sampler (verification only): continuous Vth by Box-Muller for TLC, then grid region */
void chan_sample_ref(const grid_t *g, const chan_t *ch, const uint8_t *bits, int n, rng_t *r, uint8_t *q);

typedef struct {
  int levels;             /* sense levels per boundary: 1 (hard), 3, 5, 7 */
  int nthr, nreg;         /* thresholds, read regions = nthr + 1 */
  uint8_t gidx[GRID_MAX]; /* grid index of each threshold, ascending */
  uint8_t map[GRID_MAX + 1]; /* grid region -> read region */
  uint8_t hbit[GRID_MAX + 1]; /* read region -> hard decision bit (by the nearest boundary side) */
} rdcfg_t;
/* levels L, soft spacing dstep (grid steps), retry offsets off[b] (grid steps, NULL = 0) */
int rdcfg_make(rdcfg_t *rc, const grid_t *g, int levels, int dstep, const int *off);
/* K_SENSE: q[n] -> region[n] */
void sense_read(const rdcfg_t *rc, const uint8_t *q, int n, uint8_t *reg);

/* raw BER of the hard read of a read configuration: from the continuous CDF of ch at the threshold
 * voltages (analytic) and from the integer table (exactly the sampler's distribution) */
double rber_analytic(const grid_t *g, const chan_t *ch, const rdcfg_t *rc);
double rber_table(const grid_t *g, const rdcfg_t *rc);

#endif
