/* pqc_ntt.h: bare-metal driver of pqc_ntt_axi_top (AXI4-Lite CSR, v1).
 *
 * Register map: pqc_ntt_regs.h. Hardware access: pqc_ntt_hal.h only.
 * Behaviour assumed where docs/spec/l4_axi.md (draft) is silent:
 * fpga/sw/ASSUMPTIONS.md (numbers An in the comments below).
 *
 * v1 stream access: the IP does not stall AXI on DIN / DOUT; an access while
 * in_ready / out_valid = 0 is dropped and sets an ERR bit (l4_axi.md v1
 * default). The driver therefore polls STATUS before every DIN write and
 * every DOUT read.
 *
 * All functions return PQC_OK (0) or a negative pqc_ntt_rc code. None of
 * them clears ERR by itself; ERR bits found after an operation are reported
 * as PQC_ERR_HW and left set for the caller to inspect and clear.
 */
#ifndef PQC_NTT_H
#define PQC_NTT_H

#include <stdint.h>

#include "pqc_ntt_regs.h"

#define PQC_NTT_N 256    /* coefficients per polynomial */
#define PQC_NTT_Q 3329u  /* modulus; coefficients are canonical [0, q) */

/* Default poll limit (STATUS reads) of every wait. One AXI4-Lite read costs
 * tens of FCLK cycles, the longest op (BASEMUL, 7 ops, BFU_LATENCY 5) is
 * about 5.4k cycles, so 1e6 polls is a generous bound (A24). */
#define PQC_NTT_POLL_LIMIT_DEFAULT 1000000u

enum pqc_ntt_rc {
  PQC_OK          = 0,
  PQC_ERR_ARG     = -1, /* bad argument (bank, op, coefficient >= q)     */
  PQC_ERR_BUSY    = -2, /* STATUS.busy = 1 before a new op               */
  PQC_ERR_TIMEOUT = -3, /* poll limit reached                            */
  PQC_ERR_HW      = -4, /* ERR register non-zero after the op            */
  PQC_ERR_STATE   = -5  /* STATUS.result_bank differs from the contract  */
};

typedef struct {
  uintptr_t base;        /* AXI base address of the IP                   */
  uint32_t poll_limit;   /* STATUS polls per wait before PQC_ERR_TIMEOUT */
  uint32_t last_status;  /* last STATUS value read (diagnostics)         */
  uint32_t last_err;     /* ERR value read at the end of the last op     */
  uint32_t last_cycles;  /* CYCLES read after the last completed op      */
} pqc_ntt_dev_t;

typedef struct {
  uint32_t raw;
  uint32_t id;
  uint32_t algo;
  uint32_t bfu_latency;
} pqc_ntt_version_t;

/* Setup. Does not touch the hardware. */
void pqc_ntt_init(pqc_ntt_dev_t *dev, uintptr_t base);

/* Register-level helpers. */
uint32_t pqc_ntt_status(pqc_ntt_dev_t *dev);
uint32_t pqc_ntt_cycles(pqc_ntt_dev_t *dev);
uint32_t pqc_ntt_version_raw(pqc_ntt_dev_t *dev);
void pqc_ntt_version(pqc_ntt_dev_t *dev, pqc_ntt_version_t *v);
uint32_t pqc_ntt_err_read(pqc_ntt_dev_t *dev);
void pqc_ntt_err_clear(pqc_ntt_dev_t *dev, uint32_t mask); /* W1C */

/* Write CTRL with start = 1. Checks op / bank encodings and busy = 0, does
 * not wait. Used by the operations below and by tests. */
int pqc_ntt_start(pqc_ntt_dev_t *dev, unsigned op, unsigned bank);
/* Poll STATUS until done_sticky = 1 (A5, A6). */
int pqc_ntt_wait_done(pqc_ntt_dev_t *dev);

/* Operations. Each waits for done_sticky, reads CYCLES into last_cycles,
 * checks STATUS.result_bank against the contract (A11) and ERR == 0. */
int pqc_ntt_load(pqc_ntt_dev_t *dev, unsigned bank, const uint16_t coeffs[PQC_NTT_N]);
int pqc_ntt_unload(pqc_ntt_dev_t *dev, unsigned bank, uint16_t coeffs[PQC_NTT_N]);
/* op: PQC_NTT_OP_NTT, _INTT (result in bank ^ 1) or _BASEMUL (bank ignored,
 * a in bank0, b in bank1, result bank0). */
int pqc_ntt_run(pqc_ntt_dev_t *dev, unsigned op, unsigned bank);

/* Expected result bank of an op (contract of ntt_l2_pkg::op_e). */
unsigned pqc_ntt_result_bank(unsigned op, unsigned bank);

/* Expected CYCLES of NTT, INTT and BASEMUL for the given ALGO and bfu
 * LATENCY (docs/spec/arch.md, "L2 results"):
 *   NTT, INTT : 897 + 7 (1 + L)
 *   BASEMUL   : 128 n (L + 1) + 3, n = 5 (BARRETT, SHIFTADD) or 7
 * Returns 0 for LOAD / UNLOAD (they include PS wait time, not compared) and
 * for invalid arguments. */
uint32_t pqc_ntt_expected_cycles(unsigned op, unsigned algo, unsigned bfu_latency);

/* Bring a half-finished LOAD or UNLOAD to its end (no abort exists, A16):
 * writes zeros while in_ready = 1, reads DOUT while out_valid = 1, until
 * done or idle. Clears no ERR bit. */
int pqc_ntt_recover(pqc_ntt_dev_t *dev);

/* ------------------------------------------------------------------------
 * Polynomial product h = f * g mod (X^256 + 1) on the current op set:
 * NTT f, NTT g, BASEMUL, INTT.
 *
 * Bank placement is the only reason for a PS round trip: NTT writes its
 * result to the opposite bank and overwrites its input bank, while BASEMUL
 * needs a in bank0 and b in bank1. pqc_ntt_place_operands() hides this; when
 * the hardware gains a bank select (or a copy op) only that function
 * changes.
 *
 * cycles_out (optional): sum of the CYCLES of the NTT, NTT, BASEMUL and
 * INTT ops (LOAD / UNLOAD and the round trip excluded).
 * ------------------------------------------------------------------------ */
int pqc_ntt_place_operands(pqc_ntt_dev_t *dev, const uint16_t f[PQC_NTT_N],
                           const uint16_t g[PQC_NTT_N], uint32_t *cycles_out);
int pqc_ntt_polymul(pqc_ntt_dev_t *dev, const uint16_t f[PQC_NTT_N],
                    const uint16_t g[PQC_NTT_N], uint16_t h[PQC_NTT_N],
                    uint32_t *cycles_out);

const char *pqc_ntt_op_name(unsigned op);
const char *pqc_ntt_algo_name(unsigned algo);
const char *pqc_ntt_rc_name(int rc);

#endif /* PQC_NTT_H */
