/* pqc_ntt.c: bare-metal driver of pqc_ntt_axi_top. See pqc_ntt.h. */
#include "pqc_ntt.h"

#include <stddef.h>

#include "pqc_ntt_hal.h"

/* ------------------------------------------------------------------------
 * Register helpers
 * ------------------------------------------------------------------------ */
void pqc_ntt_init(pqc_ntt_dev_t *dev, uintptr_t base)
{
  dev->base = base;
  dev->poll_limit = PQC_NTT_POLL_LIMIT_DEFAULT;
  dev->last_status = 0;
  dev->last_err = 0;
  dev->last_cycles = 0;
}

uint32_t pqc_ntt_status(pqc_ntt_dev_t *dev)
{
  dev->last_status = reg_read32(dev->base, PQC_NTT_REG_STATUS);
  return dev->last_status;
}

uint32_t pqc_ntt_cycles(pqc_ntt_dev_t *dev)
{
  return reg_read32(dev->base, PQC_NTT_REG_CYCLES);
}

uint32_t pqc_ntt_version_raw(pqc_ntt_dev_t *dev)
{
  return reg_read32(dev->base, PQC_NTT_REG_VERSION);
}

void pqc_ntt_version(pqc_ntt_dev_t *dev, pqc_ntt_version_t *v)
{
  uint32_t raw = pqc_ntt_version_raw(dev);
  v->raw = raw;
  v->algo = PQC_NTT_FIELD_GET(raw, PQC_NTT_VERSION_ALGO_SHIFT, PQC_NTT_VERSION_ALGO_WIDTH);
  v->bfu_latency = PQC_NTT_FIELD_GET(raw, PQC_NTT_VERSION_BFU_LATENCY_SHIFT,
                                     PQC_NTT_VERSION_BFU_LATENCY_WIDTH);
  v->id = PQC_NTT_FIELD_GET(raw, PQC_NTT_VERSION_ID_SHIFT, PQC_NTT_VERSION_ID_WIDTH);
}

void pqc_ntt_config(pqc_ntt_dev_t *dev, pqc_ntt_config_t *c)
{
  uint32_t raw = reg_read32(dev->base, PQC_NTT_REG_CONFIG);
  c->raw = raw;
  c->impl = PQC_NTT_FIELD_GET(raw, PQC_NTT_CONFIG_IMPL_BIT, 1u);
  c->share_addsub = PQC_NTT_FIELD_GET(raw, PQC_NTT_CONFIG_SHARE_ADDSUB_BIT, 1u);
  c->rom_out_reg = PQC_NTT_FIELD_GET(raw, PQC_NTT_CONFIG_ROM_OUT_REG_BIT, 1u);
  c->pre_reg = PQC_NTT_FIELD_GET(raw, PQC_NTT_CONFIG_PRE_REG_BIT, 1u);
  c->mul_reg = PQC_NTT_FIELD_GET(raw, PQC_NTT_CONFIG_MUL_REG_BIT, 1u);
  c->red_pipe = PQC_NTT_FIELD_GET(raw, PQC_NTT_CONFIG_RED_PIPE_SHIFT, PQC_NTT_CONFIG_RED_PIPE_WIDTH);
  c->out_reg = PQC_NTT_FIELD_GET(raw, PQC_NTT_CONFIG_OUT_REG_BIT, 1u);
  c->fclk_mhz = PQC_NTT_FIELD_GET(raw, PQC_NTT_CONFIG_FCLK_MHZ_SHIFT, PQC_NTT_CONFIG_FCLK_MHZ_WIDTH);
}

uint32_t pqc_ntt_err_read(pqc_ntt_dev_t *dev)
{
  return reg_read32(dev->base, PQC_NTT_REG_ERR);
}

void pqc_ntt_err_clear(pqc_ntt_dev_t *dev, uint32_t mask)
{
  reg_write32(dev->base, PQC_NTT_REG_ERR, mask);
}

/* ------------------------------------------------------------------------
 * Waits
 * ------------------------------------------------------------------------ */
/* Poll STATUS until any bit of mask is 1. */
static int wait_status(pqc_ntt_dev_t *dev, uint32_t mask)
{
  uint32_t n;
  for (n = 0; n < dev->poll_limit; n++) {
    if (pqc_ntt_status(dev) & mask) {
      return PQC_OK;
    }
  }
  return PQC_ERR_TIMEOUT;
}

int pqc_ntt_wait_done(pqc_ntt_dev_t *dev)
{
  /* done_sticky, not busy: busy rises one cycle after the start pulse and
   * done_sticky is cleared by the CTRL write of this op (A5, A6). */
  return wait_status(dev, PQC_NTT_STATUS_DONE_STICKY);
}

static int op_valid(unsigned op)
{
  return op < PQC_NTT_OP_COUNT;
}

unsigned pqc_ntt_result_bank(unsigned op, unsigned bank)
{
  switch (op) {
  case PQC_NTT_OP_NTT:
  case PQC_NTT_OP_INTT:
    return (bank & 1u) ^ 1u;
  case PQC_NTT_OP_BASEMUL:
    return 0u;
  default: /* LOAD, UNLOAD */
    return bank & 1u;
  }
}

int pqc_ntt_start(pqc_ntt_dev_t *dev, unsigned op, unsigned bank)
{
  if (!op_valid(op) || bank > 1u) {
    return PQC_ERR_ARG; /* A9: an illegal op is never written (the IP would only set ERR.bad_op) */
  }
  if (pqc_ntt_status(dev) & PQC_NTT_STATUS_BUSY) {
    return PQC_ERR_BUSY; /* A8: would only set ERR.start_busy */
  }
  reg_write32(dev->base, PQC_NTT_REG_CTRL, PQC_NTT_CTRL_VALUE(1u, op, bank));
  return PQC_OK;
}

/* Common end of every op: done, CYCLES, ERR, result bank. */
static int finish_op(pqc_ntt_dev_t *dev, unsigned op, unsigned bank)
{
  int rc = pqc_ntt_wait_done(dev);
  uint32_t rbank;
  if (rc != PQC_OK) {
    return rc;
  }
  rbank = (dev->last_status & PQC_NTT_STATUS_RESULT_BANK) ? 1u : 0u;
  dev->last_cycles = pqc_ntt_cycles(dev);
  dev->last_err = pqc_ntt_err_read(dev);
  if (dev->last_err != 0u) {
    return PQC_ERR_HW;
  }
  if (rbank != pqc_ntt_result_bank(op, bank)) {
    return PQC_ERR_STATE;
  }
  return PQC_OK;
}

/* ------------------------------------------------------------------------
 * Operations
 * ------------------------------------------------------------------------ */
int pqc_ntt_load(pqc_ntt_dev_t *dev, unsigned bank, const uint16_t coeffs[PQC_NTT_N])
{
  int i;
  int rc;
  if (coeffs == NULL || bank > 1u) {
    return PQC_ERR_ARG;
  }
  /* The IP stores a word >= q unchanged and only sets ERR.din_range (A15):
   * reject before starting so that no LOAD is left half-finished. */
  for (i = 0; i < PQC_NTT_N; i++) {
    if (coeffs[i] >= PQC_NTT_Q) {
      return PQC_ERR_ARG;
    }
  }
  rc = pqc_ntt_start(dev, PQC_NTT_OP_LOAD, bank);
  if (rc != PQC_OK) {
    return rc;
  }
  for (i = 0; i < PQC_NTT_N; i++) {
    rc = wait_status(dev, PQC_NTT_STATUS_IN_READY); /* A2, A3 */
    if (rc != PQC_OK) {
      return rc;
    }
    reg_write32(dev->base, PQC_NTT_REG_DIN, (uint32_t)coeffs[i] & PQC_NTT_COEF_MASK);
  }
  return finish_op(dev, PQC_NTT_OP_LOAD, bank);
}

int pqc_ntt_unload(pqc_ntt_dev_t *dev, unsigned bank, uint16_t coeffs[PQC_NTT_N])
{
  int i;
  int rc;
  if (coeffs == NULL || bank > 1u) {
    return PQC_ERR_ARG;
  }
  rc = pqc_ntt_start(dev, PQC_NTT_OP_UNLOAD, bank);
  if (rc != PQC_OK) {
    return rc;
  }
  for (i = 0; i < PQC_NTT_N; i++) {
    rc = wait_status(dev, PQC_NTT_STATUS_OUT_VALID); /* A4 */
    if (rc != PQC_OK) {
      return rc;
    }
    coeffs[i] = (uint16_t)(reg_read32(dev->base, PQC_NTT_REG_DOUT) & PQC_NTT_COEF_MASK);
  }
  return finish_op(dev, PQC_NTT_OP_UNLOAD, bank);
}

int pqc_ntt_run(pqc_ntt_dev_t *dev, unsigned op, unsigned bank)
{
  int rc;
  if (op != PQC_NTT_OP_NTT && op != PQC_NTT_OP_INTT && op != PQC_NTT_OP_BASEMUL) {
    return PQC_ERR_ARG;
  }
  if (bank > 1u) {
    return PQC_ERR_ARG;
  }
  if (op == PQC_NTT_OP_BASEMUL) {
    bank = 0u; /* ignored by the IP (A10); written as 0 */
  }
  rc = pqc_ntt_start(dev, op, bank);
  if (rc != PQC_OK) {
    return rc;
  }
  return finish_op(dev, op, bank);
}

int pqc_ntt_recover(pqc_ntt_dev_t *dev)
{
  uint32_t n;
  /* Bound: 256 stream words plus poll_limit idle polls. */
  for (n = 0; n < dev->poll_limit + 2u * PQC_NTT_N; n++) {
    uint32_t s = pqc_ntt_status(dev);
    if ((s & PQC_NTT_STATUS_DONE_STICKY) || !(s & PQC_NTT_STATUS_BUSY)) {
      return PQC_OK;
    }
    if (s & PQC_NTT_STATUS_IN_READY) {
      reg_write32(dev->base, PQC_NTT_REG_DIN, 0u);
    } else if (s & PQC_NTT_STATUS_OUT_VALID) {
      (void)reg_read32(dev->base, PQC_NTT_REG_DOUT);
    }
  }
  return PQC_ERR_TIMEOUT;
}

/* ------------------------------------------------------------------------
 * Expected cycles (docs/spec/arch.md, "L2 results", measured on the
 * behavioural ntt_core datapath, start accepted to done)
 * ------------------------------------------------------------------------ */
uint32_t pqc_ntt_expected_cycles(unsigned op, unsigned algo, unsigned bfu_latency)
{
  uint32_t l = bfu_latency;
  uint32_t nops;
  if (algo >= PQC_NTT_ALGO_COUNT) {
    return 0u;
  }
  switch (op) {
  case PQC_NTT_OP_NTT:
  case PQC_NTT_OP_INTT:
    return 897u + 7u * (1u + l);
  case PQC_NTT_OP_BASEMUL:
    nops = (algo == PQC_NTT_ALGO_BARRETT || algo == PQC_NTT_ALGO_SHIFTADD) ? 5u : 7u;
    return 128u * nops * (l + 1u) + 3u;
  default:
    return 0u;
  }
}

/* ------------------------------------------------------------------------
 * Polynomial product
 * ------------------------------------------------------------------------ */
static uint16_t pqc_ntt_spill[PQC_NTT_N]; /* PS copy of NTT(f) during NTT(g) */

int pqc_ntt_place_operands(pqc_ntt_dev_t *dev, const uint16_t f[PQC_NTT_N],
                           const uint16_t g[PQC_NTT_N], uint32_t *cycles_out)
{
  /* Goal: NTT(f) in bank0 and NTT(g) in bank1 (BASEMUL contract).
   * With the v1 op set an NTT leaves its result in the other bank and
   * overwrites its input bank (A19), so NTT(f) cannot stay in the IP while
   * NTT(g) runs. Sequence (one PS round trip of NTT(f)):
   *   LOAD f -> bank1, NTT bank1 -> NTT(f) in bank0, UNLOAD bank0 to the PS
   *   LOAD g -> bank0, NTT bank0 -> NTT(g) in bank1
   *   LOAD NTT(f) -> bank0
   * Replace this function when the IP can select the NTT result bank. */
  uint32_t cyc = 0;
  int rc;
  rc = pqc_ntt_load(dev, 1u, f);
  if (rc != PQC_OK) return rc;
  rc = pqc_ntt_run(dev, PQC_NTT_OP_NTT, 1u);
  if (rc != PQC_OK) return rc;
  cyc += dev->last_cycles;
  rc = pqc_ntt_unload(dev, 0u, pqc_ntt_spill);
  if (rc != PQC_OK) return rc;
  rc = pqc_ntt_load(dev, 0u, g);
  if (rc != PQC_OK) return rc;
  rc = pqc_ntt_run(dev, PQC_NTT_OP_NTT, 0u);
  if (rc != PQC_OK) return rc;
  cyc += dev->last_cycles;
  rc = pqc_ntt_load(dev, 0u, pqc_ntt_spill);
  if (rc != PQC_OK) return rc;
  if (cycles_out != NULL) {
    *cycles_out = cyc;
  }
  return PQC_OK;
}

int pqc_ntt_polymul(pqc_ntt_dev_t *dev, const uint16_t f[PQC_NTT_N],
                    const uint16_t g[PQC_NTT_N], uint16_t h[PQC_NTT_N],
                    uint32_t *cycles_out)
{
  uint32_t cyc = 0;
  int rc;
  rc = pqc_ntt_place_operands(dev, f, g, &cyc);
  if (rc != PQC_OK) return rc;
  rc = pqc_ntt_run(dev, PQC_NTT_OP_BASEMUL, 0u);          /* result bank0 */
  if (rc != PQC_OK) return rc;
  cyc += dev->last_cycles;
  rc = pqc_ntt_run(dev, PQC_NTT_OP_INTT, 0u);             /* result bank1 */
  if (rc != PQC_OK) return rc;
  cyc += dev->last_cycles;
  rc = pqc_ntt_unload(dev, pqc_ntt_result_bank(PQC_NTT_OP_INTT, 0u), h);
  if (rc != PQC_OK) return rc;
  if (cycles_out != NULL) {
    *cycles_out = cyc;
  }
  return PQC_OK;
}

/* ------------------------------------------------------------------------
 * Names (log output)
 * ------------------------------------------------------------------------ */
const char *pqc_ntt_op_name(unsigned op)
{
  switch (op) {
  case PQC_NTT_OP_LOAD: return "LOAD";
  case PQC_NTT_OP_NTT: return "NTT";
  case PQC_NTT_OP_INTT: return "INTT";
  case PQC_NTT_OP_BASEMUL: return "BASEMUL";
  case PQC_NTT_OP_UNLOAD: return "UNLOAD";
  default: return "ILLEGAL";
  }
}

const char *pqc_ntt_algo_name(unsigned algo)
{
  switch (algo) {
  case PQC_NTT_ALGO_BARRETT: return "BARRETT";
  case PQC_NTT_ALGO_MONT12: return "MONT12";
  case PQC_NTT_ALGO_SHIFTADD: return "SHIFTADD";
  case PQC_NTT_ALGO_K2RED: return "K2RED";
  default: return "UNKNOWN";
  }
}

const char *pqc_ntt_rc_name(int rc)
{
  switch (rc) {
  case PQC_OK: return "OK";
  case PQC_ERR_ARG: return "ERR_ARG";
  case PQC_ERR_BUSY: return "ERR_BUSY";
  case PQC_ERR_TIMEOUT: return "ERR_TIMEOUT";
  case PQC_ERR_HW: return "ERR_HW";
  case PQC_ERR_STATE: return "ERR_STATE";
  default: return "ERR_UNKNOWN";
  }
}
