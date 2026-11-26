/* NAND channel models (docs/spec/channel.md 2, 3). Double precision; used to build the integer
 * sampling tables (sense.c) and the LLR LUT (llr.c), never in the bit-exact sample path.
 *   CH_TLC: 3D TLC Gaussian fit table [R5] Tables A1-A3, sigma scaled by alpha (project knob).
 *   CH_MLC: MLC analytic model [R3] Example 2.1, numeric density on a grid:
 *           f = [sum_xp p_prog(xp) N(xp - mu_d(xp), sd_d(xp)^2)] (*) p_RTN (*) p_CCI
 *           (retention depends on the programmed Vth xp; RTN and CCI are independent additive). */
#ifndef CHAN_H
#define CHAN_H

enum { CH_TLC = 0, CH_MLC = 1 };

typedef struct {
  /* [R3] Example 2.1 */
  double mu_e, sig_e, dvpp, vp[3], k_lambda, gam_y, gam_xy, wc_rel, sc_rel;
  double ks, x0, kd, km, t0;
  int cci;          /* 1: CCI on (1 vertical + 2 diagonal next-word-line neighbours) */
} mlc_param_t;
void mlc_param_default(mlc_param_t *p);   /* [R3] values */

typedef struct {
  int model, nstate, bits;
  double mu[8], sig[8], alpha;       /* TLC */
  /* MLC numeric density: x grid, per state CDF */
  double x_lo, h;
  int ng;
  double *cdf[4];
  double N, t_h;
} chan_t;

/* page bit of state s: TLC page 0 LSB, 1 CSB, 2 MSB ([R5] Table 1);
 * MLC page 0 lower (bit pattern 1,1,0,0: one boundary P1|P2), 1 upper (1,0,0,1) ([R4] Gray 11/10/00/01) */
int chan_page_bit(const chan_t *c, int page, int s);
int chan_npages(const chan_t *c);
/* boundaries of a page: lower state index s of each boundary s|s+1, ascending; returns count */
int chan_bounds(const chan_t *c, int page, int *bstate);

int chan_tlc(chan_t *c, const double mu[8], const double sig[8], double alpha);
int chan_mlc(chan_t *c, const mlc_param_t *p, double N, double t_hours);
void chan_free(chan_t *c);

double chan_cdf(const chan_t *c, int s, double x);   /* P(Vth <= x | s) */
double chan_mean(const chan_t *c, int s);
/* threshold between s and s+1 that minimises (1 - F_s(x)) + F_{s+1}(x) (equal priors) */
double chan_ref_opt(const chan_t *c, int s);

/* TLC table text (data/params/tlc_cui2021.txt): lines "days pe mu0..mu7 sig0..sig7" */
int chan_tlc_lookup(const char *text, int days, int pe, double mu[8], double sig[8]);

#endif
