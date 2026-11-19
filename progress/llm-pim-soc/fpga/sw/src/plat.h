/*
 * Platform layer of the ARM baseline program. Everything that differs between the
 * host test build (plat_host.c, gcc on the PC) and the Zynq-7000 bare-metal build
 * (plat_xil.c, Xilinx standalone BSP) is behind these functions. No other file of
 * the program includes a Xilinx header.
 */
#ifndef PLAT_H
#define PLAT_H
#include <stddef.h>
#include <stdint.h>

void plat_init(void);
const char *plat_name(void);      /* "xil" or "host" */

/* free-running 64-bit time base: ticks and ticks per second.
 * xil: Cortex-A9 global timer (CPU clock / 2). host: CLOCK_MONOTONIC in ns. */
uint64_t plat_now(void);
uint64_t plat_tps(void);
/* 32-bit CPU cycle counter (xil: PMU PMCCNTR, host: low bits of the ns clock) */
uint32_t plat_cyc(void);

void plat_putc(int c);            /* console byte (xil: UART through outbyte) */
void plat_cache_flush(void);      /* write back and invalidate all data caches */
int plat_info(void);              /* prints PLAT lines (clocks, cache, FPU); 0 = layout ok */

/* image preloaded at a fixed DDR address (xil: the address itself; host: a file
 * mapped by the DDRMAP environment variable, NULL if not mapped) */
const void *plat_ddr(uint32_t addr, uint32_t len);
/* model memory block of at least need bytes, NULL if it does not fit */
void *plat_arena(size_t need, size_t *cap);
/* lowest address the program image (code, data, stack) may not reach, 0 = no check */
uint32_t plat_prog_top(void);

void plat_exit(int rc);

#endif
