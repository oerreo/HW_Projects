/*
 * Hardware layer of the system program (system.md 2.1). Board: hal_xil.c (Xilinx standalone
 * BSP). Host test: ../test/hal_host.c (C register models of the IPs written from the spec
 * documents + a cache model that keeps the CPU view and the DDR image apart). Later: the RTL
 * system TB (hal_dpi.c, S5-3). Time, UART and preloaded DDR images stay in fpga/sw/src/plat.h.
 */
#ifndef HAL_H
#define HAL_H
#include <stddef.h>
#include <stdint.h>

int hal_init(void);                           /* 0 = ok */
const char *hal_name(void);                   /* "xil", "host_model" */
uint32_t hal_rd(int slot, uint32_t off);      /* AXI-Lite read, SYS_BASE + slot 4 KiB + off */
void hal_wr(int slot, uint32_t off, uint32_t v);
uint32_t hal_pa(const void *p);               /* HP bus address of a CPU pointer (arena only) */
void hal_flush(const void *p, size_t n);      /* clean + invalidate the D-cache lines of a range */
void hal_inval(const void *p, size_t n);      /* invalidate the D-cache lines of a range */
void hal_flush_all(void);                     /* clean + invalidate the whole D-cache */
void hal_dsb(void);                           /* barrier before the CTRL write */
/* model memory block (the only memory the IPs may access), 64 B aligned or better */
void *hal_arena(size_t need, size_t *cap);
/* host only: run settings from the environment (board: always NULL) */
const char *hal_env(const char *key);

/*
 * Coherence checks (host model only; the board build compiles them to nothing).
 * hal_arm_rd: the program is about to read a range that the IPs may have written (kernel
 * input on the ARM, driver read). hal_arm_wr: the program wrote a range (marks the bytes as
 * written by the ARM even when the value did not change). hal_ctx: kernel and position.
 */
typedef struct {
  long n;            /* errors in this run */
  long old;          /* full-flush write-backs over IP data of an earlier run (not errors) */
  char kind[16];     /* first error: ip_rd_dirty, ip_wr_dirty, arm_rd_stale, flush_clobber, ... */
  char what[24];     /* buffer name of the first error */
  char ctx[24];      /* kernel of the first error */
  int pos;
  uint32_t addr;
} hal_coh_t;
#ifdef HAL_HOST
void hal_arm_rd(const void *p, size_t n);
void hal_arm_wr(const void *p, size_t n); /* the ARM wrote this range (kernel output, driver) */
void hal_ctx(const char *k, int pos);
void hal_name_range(const void *p, size_t n, const char *name);
void hal_coh_get(hal_coh_t *c, int reset);
#else
#define hal_arm_rd(p, n) ((void)0)
#define hal_arm_wr(p, n) ((void)0)
#define hal_ctx(k, pos) ((void)0)
#define hal_name_range(p, n, name) ((void)0)
#define hal_coh_get(c, reset) ((void)0)
#endif

#endif
