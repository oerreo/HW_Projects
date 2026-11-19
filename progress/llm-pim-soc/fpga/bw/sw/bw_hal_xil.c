/*
 * bw_hal_xil.c: Zynq-7000 (Cortex-A9, Xilinx standalone BSP) implementation of bw_hal.h.
 *
 * UNVERIFIED (no board, no Xilinx toolchain on the preparation machine): every Xilinx API call
 * below. Only a host syntax check against stub headers was done (fpga/bw/test/Makefile,
 * target xilsyntax). Global timer through XTime_GetTime as in fpga/sw/src/plat_xil.c.
 */
#include <stdint.h>
#include "bw_hal.h"
#include "bw_regs.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xtime_l.h"

int bw_hal_init(void) { return 0; }

uint32_t bw_rd(uint32_t off) { return Xil_In32((UINTPTR)(BW_BASEADDR + off)); }

void bw_wr(uint32_t off, uint32_t v) { Xil_Out32((UINTPTR)(BW_BASEADDR + off), v); }

volatile uint8_t *bw_mem(uint32_t addr) { return (volatile uint8_t *)(uintptr_t)addr; }

/* UNVERIFIED: Xil_DCacheFlushRange / Xil_DCacheInvalidateRange also handle the L2 (PL310) on
 * the Zynq-7000 standalone BSP. The range is widened to 32-byte lines by the BSP. */
void bw_flush(uint32_t addr, uint32_t len) { Xil_DCacheFlushRange((INTPTR)addr, len); }

void bw_inval(uint32_t addr, uint32_t len) { Xil_DCacheInvalidateRange((INTPTR)addr, len); }

uint64_t bw_now(void) {
  XTime t;
  XTime_GetTime(&t);
  return (uint64_t)t;
}

uint64_t bw_tps(void) { return (uint64_t)COUNTS_PER_SECOND; }

void bw_putc(int c) { outbyte((char8)c); }

const char *bw_plat(void) { return "xil"; }
