#include "policy.h"
#include <string.h>

int policy_init(pol_t *p, const pol_cfg_t *cfg, const grid_t *g, const chan_t *nominal, int w)
{
  int k, st = 0, n = 0;
  memset(p, 0, sizeof *p);
  p->cfg = *cfg;
  if (cfg->nretry < 0 || cfg->nretry > POL_MAXRETRY || cfg->nsoft < 0 || cfg->nsoft > POL_MAXSOFT) return -1;
  /* stage 0: hard read at the grid centres */
  if (rdcfg_make(&p->rc[st], g, 1, 1, NULL)) return -1;
  llr_build_hard(&p->lut[st], &p->rc[st], w, cfg->hardA);
  st++;
  for (k = 0; k < cfg->nretry; k++, st++) {
    if (rdcfg_make(&p->rc[st], g, 1, 1, cfg->roff[k])) return -1;
    llr_build_hard(&p->lut[st], &p->rc[st], w, cfg->hardA);
  }
  for (k = 0; k < cfg->nsoft; k++, st++) {
    if (rdcfg_make(&p->rc[st], g, cfg->soft_levels[k], cfg->dstep, NULL)) return -1;
    llr_build(&p->lut[st], g, nominal, &p->rc[st], w, cfg->scale);
  }
  p->nst = st;
  (void)n;
  for (k = 0; k < st; k++) {
    /* sense: hard read + extra levels; transfer: ceil(log2(regions)) bits per cell */
    int L = p->rc[k].levels, bits = 0;
    while ((1 << bits) < p->rc[k].nreg) bits++;
    if (bits < 1) bits = 1;
    p->t_stage[k] = cfg->t_sense_hard + (L - 1) * g->B * cfg->t_sense_level;
    p->t_stage[k] += cfg->t_xfer_byte * (double)bits * 9216.0 / 8.0;
  }
  return 0;
}

void policy_run(const pol_t *p, dfix_t *dec, const uint8_t *q, const uint8_t *cw, int8_t *llr, pol_res_t *res)
{
  const int n = dec->c->n;
  int st;
  memset(res, 0, sizeof *res);
  res->stage = -1;
  for (st = 0; st < p->nst; st++) {
    int ok;
    llr_map(&p->lut[st], q, n, llr);
    ok = dfix_decode(dec, llr);
    res->iters += dec->iters_used;
    res->latency_us += p->t_stage[st] + dec->iters_used * p->cfg.t_dec_iter;
    if (ok) {
      res->stage = st;
      res->undetected = memcmp(dec->hard, cw, (size_t)n) != 0;
      return;
    }
  }
}
