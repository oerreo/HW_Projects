/*
 * Zynq-7000 (Cortex-A9, Xilinx standalone BSP) implementation of plat.h.
 * The only file of the program that includes Xilinx headers. Not compiled on the
 * host (the host test uses plat_host.c).
 *
 * UNVERIFIED (no board, no Xilinx toolchain on the preparation machine): every
 * Xilinx API call and CP15 / register access below. Check items in fpga/README.md.
 */
#include <stdint.h>
#include "bcfg.h"
#include "out.h"
#include "plat.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xtime_l.h"

/* Cortex-A9 MPCore private memory region (Zynq-7000 TRM, Appendix B) */
#define GT_BASE 0xF8F00200u   /* global timer: counter lo +0, hi +4, control +8 */
#define L2C_CTRL 0xF8F02100u  /* PL310 control register, bit 0 = enable */
#define L2C_AUX 0xF8F02104u

static uint32_t fpscr_before;

static inline uint32_t rd_sctlr(void) {
  uint32_t v;
  __asm__ volatile("mrc p15, 0, %0, c1, c0, 0" : "=r"(v));
  return v;
}
static inline uint32_t rd_actlr(void) {
  uint32_t v;
  __asm__ volatile("mrc p15, 0, %0, c1, c0, 1" : "=r"(v));
  return v;
}
static inline uint32_t rd_fpscr(void) {
  uint32_t v;
  __asm__ volatile("vmrs %0, fpscr" : "=r"(v));
  return v;
}
static inline void wr_fpscr(uint32_t v) { __asm__ volatile("vmsr fpscr, %0" : : "r"(v)); }

void plat_init(void) {
  uint64_t a, b;
  int i;
  /* PMU: enable counters (E), reset the cycle counter (C), no divider (D = 0) */
  __asm__ volatile("mcr p15, 0, %0, c9, c12, 0" : : "r"(0x5u));
  __asm__ volatile("mcr p15, 0, %0, c9, c12, 1" : : "r"(0x80000000u)); /* PMCNTENSET: CCNT */
  /* global timer: start it if the boot code did not */
  a = plat_now();
  for (i = 0; i < 1000; i++) __asm__ volatile("nop");
  b = plat_now();
  if (a == b) Xil_Out32(GT_BASE + 8u, Xil_In32(GT_BASE + 8u) | 1u);
  /* IEEE subnormals as on the PC: clear flush-to-zero (bit 24) */
  fpscr_before = rd_fpscr();
  wr_fpscr(fpscr_before & ~(1u << 24));
}

const char *plat_name(void) { return "xil"; }

uint64_t plat_now(void) {
  XTime t;
  XTime_GetTime(&t);
  return (uint64_t)t;
}

uint64_t plat_tps(void) { return (uint64_t)COUNTS_PER_SECOND; }

uint32_t plat_cyc(void) {
  uint32_t v;
  __asm__ volatile("mrc p15, 0, %0, c9, c13, 0" : "=r"(v));
  return v;
}

void plat_putc(int c) { outbyte((char)c); }

void plat_cache_flush(void) { Xil_DCacheFlush(); }

int plat_info(void) {
  uint32_t sp = (uint32_t)(uintptr_t)__builtin_frame_address(0);
  o_key("PLAT");
  o_s("name", "xil");
  o_s("timer", "global_timer");
#ifdef XPAR_CPU_CORTEXA9_0_CPU_CLK_FREQ_HZ
  o_u("cpu_hz", (uint64_t)XPAR_CPU_CORTEXA9_0_CPU_CLK_FREQ_HZ);
#endif
  o_u("tps", plat_tps());
  o_x("sctlr", rd_sctlr());
  o_x("actlr", rd_actlr());
  o_x("l2c_ctrl", Xil_In32(L2C_CTRL));
  o_x("l2c_aux", Xil_In32(L2C_AUX));
  o_x("fpscr_boot", fpscr_before);
  o_x("fpscr", rd_fpscr());
  o_x("sp", sp);
  o_x("ddr_ck", DDR_CK_ADDR);
  o_x("ddr_tk", DDR_TK_ADDR);
  o_x("arena", ARENA_ADDR);
  o_s("layout", sp < plat_prog_top() ? "ok" : "overlap");
  o_end();
  return sp < plat_prog_top() ? 0 : 1;
}

const void *plat_ddr(uint32_t addr, uint32_t len) {
  (void)len;
  return (const void *)(uintptr_t)addr;
}

void *plat_arena(size_t need, size_t *cap) {
  *cap = ARENA_CAP;
  return need <= (size_t)ARENA_CAP ? (void *)(uintptr_t)ARENA_ADDR : (void *)0;
}

/* the image placed by the linker script (text .. stack) must end below the first
 * preloaded DDR image */
uint32_t plat_prog_top(void) { return DDR_CK_ADDR; }

void plat_exit(int rc) {
  (void)rc;
  for (;;) {
  }
}
