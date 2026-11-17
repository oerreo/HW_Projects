/* pqc_ntt_hal.h: the only hardware access points of the PS software.
 *
 * The driver touches the IP exclusively through these two functions.
 *   board: pqc_ntt_hal_xil.c  (Xil_In32 / Xil_Out32, standalone BSP)
 *   host : test/reg_model.c   (register-level software model)
 * Accesses are 32-bit, aligned, one AXI4-Lite transaction each. A read of
 * PQC_NTT_REG_DOUT has a side effect (pops the output stream), so the
 * implementation must not merge, repeat or speculate reads.
 */
#ifndef PQC_NTT_HAL_H
#define PQC_NTT_HAL_H

#include <stdint.h>

uint32_t reg_read32(uintptr_t base, uint32_t off);
void reg_write32(uintptr_t base, uint32_t off, uint32_t val);

#endif /* PQC_NTT_HAL_H */
