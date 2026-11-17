/* pqc_ntt_hal_xil.c: board implementation of pqc_ntt_hal.h (Xilinx
 * standalone BSP). Not built by the host test (fpga/sw/test/Makefile).
 *
 * The M_AXI_GP0 window (0x40000000..0x7FFFFFFF) is mapped as device /
 * strongly-ordered memory by the standalone BSP translation table, so each
 * Xil_In32 / Xil_Out32 is exactly one AXI transaction (ASSUMPTION A18;
 * not checked on a board yet).
 */
#ifndef PQC_HOST_TEST

#include "xil_io.h"

#include "pqc_ntt_hal.h"

uint32_t reg_read32(uintptr_t base, uint32_t off)
{
  return Xil_In32((UINTPTR)(base + off));
}

void reg_write32(uintptr_t base, uint32_t off, uint32_t val)
{
  Xil_Out32((UINTPTR)(base + off), val);
}

#endif /* PQC_HOST_TEST */
