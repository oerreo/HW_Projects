/*
 * bw_hal.h: the platform layer of the bandwidth program. Board: bw_hal_xil.c (Xilinx
 * standalone BSP). Host test: test/bw_hal_host.c (software model of the IP, not the RTL).
 */
#ifndef BW_HAL_H
#define BW_HAL_H
#include <stdint.h>

int bw_hal_init(void);                            /* 0 = ok */
uint32_t bw_rd(uint32_t off);                     /* CSR read at BW_BASEADDR + off */
void bw_wr(uint32_t off, uint32_t v);             /* CSR write */
volatile uint8_t *bw_mem(uint32_t addr);          /* CPU pointer of a DDR (HP) address */
void bw_flush(uint32_t addr, uint32_t len);       /* clean D-cache lines of a range */
void bw_inval(uint32_t addr, uint32_t len);       /* invalidate D-cache lines of a range */
uint64_t bw_now(void);                            /* free-running timer */
uint64_t bw_tps(void);                            /* timer ticks per second */
void bw_putc(int c);                              /* one UART character */
const char *bw_plat(void);                        /* platform name for the log */

#endif
