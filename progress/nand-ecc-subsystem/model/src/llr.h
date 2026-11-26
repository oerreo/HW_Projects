/* LLR LUT per read configuration (channel.md 5). Built in double from a nominal channel, exchanged as
 * an int8 table; llr_map (K_LLR) is a table lookup and is what the PL llr_gen reproduces.
 * Sign: positive = bit 0. Quantization: round half away from zero of LLR * scale, saturate to
 * +-(2^(w-1) - 1). Hard reads may instead use +-A. Also the AWGN/BPSK LLR helpers (verification). */
#ifndef LLR_H
#define LLR_H
#include <stdint.h>
#include "sense.h"

typedef struct {
  int nreg, w;
  double scale;
  double llr[GRID_MAX + 1];   /* exact LLR (double) per read region */
  int8_t lut[GRID_MAX + 1];
  int8_t full[GRID_MAX + 1];  /* grid region -> quantized LLR (lut composed with rc->map) */
} llrlut_t;

int llr_quant(double x, double scale, int w);
/* nominal: channel used for the LUT (may differ from the sampled channel) */
void llr_build(llrlut_t *L, const grid_t *g, const chan_t *nominal, const rdcfg_t *rc, int w, double scale);
/* hard read: +-A by the hard bit of each region */
void llr_build_hard(llrlut_t *L, const rdcfg_t *rc, int w, int A);
/* K_LLR: grid region q -> int8 LLR (sense_read and lut in one table) */
void llr_map(const llrlut_t *L, const uint8_t *q, int n, int8_t *out);
/* double LLR for the float decoders */
void llr_map_f(const llrlut_t *L, const rdcfg_t *rc, const uint8_t *q, int n, double *out);

#endif
