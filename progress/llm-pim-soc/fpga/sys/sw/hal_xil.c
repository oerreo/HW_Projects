/*
 * Zynq-7000 (Cortex-A9, Xilinx standalone BSP) implementation of hal.h.
 *
 * UNVERIFIED (no board, no ARM compiler, no Xilinx BSP on the preparation machine): every
 * Xilinx API call and the inline assembly below. Only a host syntax check against stub BSP
 * headers was done (fpga/sys/test/Makefile, target xilsyntax). See fpga/sys/README.md.
 *  - the L4 register window at SYS_BASE (0x43C0_0000, 64 KiB, system.md 1.4) is set by the
 *    block design address map (S5-5);
 *  - Xil_DCacheFlushRange / Xil_DCacheInvalidateRange clean/invalidate L1 and the PL310 L2 by
 *    32-byte lines; how partial lines at the range ends are treated is not checked (the
 *    executor never leaves dirty lines in an IP output range, system.md 2.2 rule 4);
 *  - the arena (ARENA_ADDR) is ordinary cacheable DDR; HP addresses equal physical addresses.
 */
#include <stdint.h>
#include "bcfg.h"
#include "hal.h"
#include "ipregs.h"
#include "xil_cache.h"
#include "xil_io.h"

int hal_init(void) { return 0; }
const char *hal_name(void) { return "xil"; }

uint32_t hal_rd(int slot, uint32_t off) {
  return Xil_In32((UINTPTR)(SYS_BASE + (uint32_t)slot * SYS_SLOT_SZ + off));
}

void hal_wr(int slot, uint32_t off, uint32_t v) {
  Xil_Out32((UINTPTR)(SYS_BASE + (uint32_t)slot * SYS_SLOT_SZ + off), v);
}

uint32_t hal_pa(const void *p) { return (uint32_t)(uintptr_t)p; }

void hal_flush(const void *p, size_t n) { Xil_DCacheFlushRange((INTPTR)(uintptr_t)p, (u32)n); }

void hal_inval(const void *p, size_t n) {
  Xil_DCacheInvalidateRange((INTPTR)(uintptr_t)p, (u32)n);
}

void hal_flush_all(void) { Xil_DCacheFlush(); }

void hal_dsb(void) { __asm__ volatile("dsb" : : : "memory"); }

void *hal_arena(size_t need, size_t *cap) {
  *cap = ARENA_CAP;
  return need <= (size_t)ARENA_CAP ? (void *)(uintptr_t)ARENA_ADDR : (void *)0;
}

const char *hal_env(const char *key) {
  (void)key;
  return (const char *)0;
}
