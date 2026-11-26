/* Fixed-point layered min-sum decoder: the RTL golden (docs/spec/numeric.md 4, bit exact).
 * QC codes with weight-1 circulants only: layer r = base row r (Z checks, no variable twice).
 * Messages: Q = APP - R (w_m bits), R stored compressed per check (min1, min2, idx, sign product,
 * per-edge sign of Q); APP w_a bits. All arithmetic in int, symmetric saturation. */
#ifndef DEC_FIX_H
#define DEC_FIX_H
#include <stdint.h>
#include "code.h"

enum { DF_NMS = 0, DF_OMS = 1 };
enum { DF_ET_NONE = 0, DF_ET_A = 1, DF_ET_B = 2 };

typedef struct {
  int wc;       /* channel LLR width (input must lie in +-(2^(wc-1)-1)) */
  int wm;       /* Q and R width */
  int wa;       /* APP width */
  int corr;     /* DF_NMS or DF_OMS */
  int nms_num;  /* NMS factor = nms_num / 16 (12 = 0.75, 13 = 0.8125, 14 = 0.875, 16 = 1) */
  int oms_beta; /* OMS offset in LSB */
  int iters;    /* iteration limit 1..63 */
  int et;       /* DF_ET_NONE, DF_ET_A, DF_ET_B */
} dfix_cfg_t;

/* dump hook events (kernel boundaries, numeric.md 5) */
enum {
  DF_EV_START = 0,     /* after APP init (iter = -1) */
  DF_EV_LAYER_IN,      /* phase 1 done for (iter, layer): q[] and cn[] of this layer valid,
                          lane_in[] = APP values after the read shifter (layer edge order) */
  DF_EV_LAYER_OUT,     /* phase 2 done: rnew[] and lane_out[] (APP to be written, before the
                          inverse shift) valid, app[] updated */
  DF_EV_ITER_END,      /* end of iteration: app[], hard[] valid, et flags */
  DF_EV_DONE
};

struct dfix;
typedef void (*dfix_hook_fn)(void *user, int ev, const struct dfix *d, int iter, int layer);

typedef struct dfix {
  const code_t *c;
  dfix_cfg_t cfg;
  int mmax, amax;        /* 2^(wm-1)-1, 2^(wa-1)-1 */
  int16_t *app;          /* n */
  uint8_t *hard;         /* n */
  /* compressed check state, per check */
  int16_t *min1, *min2;  /* corrected magnitudes f(min1), f(min2) */
  uint8_t *idx;          /* position of min1 in the check (edge order) */
  uint8_t *sgn;          /* XOR of the Q signs */
  uint8_t *sq;           /* per edge: sign of Q (1 = negative) */
  /* per layer scratch, layer edge order (check i of the layer, then its edges) */
  int16_t *q, *rold, *rnew, *lane_in, *lane_out;
  int layer_edges;
  int iters_used, ok;
  int etb_sat, etb_chg;  /* ET-B flags of the current iteration */
  long hard_changes;     /* statistics */
  dfix_hook_fn hook;
  void *user;
} dfix_t;

int dfix_init(dfix_t *d, const code_t *c, const dfix_cfg_t *cfg);
void dfix_free(dfix_t *d);
/* llr[n] (int8, |llr| <= 2^(wc-1)-1) -> d->hard[n], returns ok flag (1 = ET condition met) */
int dfix_decode(dfix_t *d, const int8_t *llr);

/* stage functions shared with the RTL test-vector dump (numeric.md 4.2) */
static inline int df_sat(int x, int mx) { return x > mx ? mx : (x < -mx ? -mx : x); }
int df_corr(const dfix_cfg_t *cfg, int m);   /* f(m), m >= 0 */

#endif
