/* reg_model.h: register-level software model of pqc_ntt_axi_top for the
 * host test. Implements pqc_ntt_hal.h (reg_read32 / reg_write32).
 *
 * This is NOT the RTL. It implements docs/spec/l4_axi.md plus the driver
 * assumptions of fpga/sw/ASSUMPTIONS.md, and computes results with the
 * golden model (model/, C linkage mlkem_dpi_hw_*). Agreement with it shows
 * that the driver, the test program, the vectors and the log format match
 * the spec text, nothing about the hardware.
 *
 * Configuration: reg_model_config() or, at the first register access, the
 * environment variables
 *   PQC_ALGO        0..3 (default 0)
 *   PQC_BFU_LAT     bfu LATENCY reported in VERSION (default 0)
 *   PQC_MODEL_SEED  timing jitter seed (default 1)
 *   PQC_MODEL_FAULT none | data | cycles | version | hang | stall | rbank
 */
#ifndef REG_MODEL_H
#define REG_MODEL_H

#include <stdint.h>

enum reg_model_fault {
  RM_FAULT_NONE = 0,
  RM_FAULT_DATA,    /* one coefficient of some op results is off by one     */
  RM_FAULT_CYCLES,  /* CYCLES of BASEMUL is one too high                    */
  RM_FAULT_VERSION, /* wrong VERSION ID                                     */
  RM_FAULT_HANG,    /* NTT / INTT / BASEMUL never complete                  */
  RM_FAULT_STALL,   /* in_ready / out_valid never rise                      */
  RM_FAULT_RBANK    /* STATUS.result_bank wrong after INTT                  */
};

typedef struct {
  uint64_t accesses;        /* register accesses                           */
  uint64_t status_reads;    /* STATUS reads                                */
  uint64_t status_not_ready;/* STATUS reads during LOAD / UNLOAD with      */
                            /* in_ready / out_valid = 0                    */
  uint64_t ops_started;     /* accepted starts                             */
} reg_model_stats_t;

void reg_model_config(int algo, int bfu_lat, int fault, uint32_t seed);
void reg_model_reset(void);           /* PL reset: state cleared, config kept */
void reg_model_get_stats(reg_model_stats_t *st);
uint64_t reg_model_now(void);         /* model time in FCLK cycles           */

#endif /* REG_MODEL_H */
