/* pqc_platform.h: printing and base address for board and host builds.
 *
 * Board (default): xil_printf on the BSP stdout (UART1 on the Zybo Z7-20).
 * Host (-DPQC_HOST_TEST): printf, used by fpga/sw/test.
 *
 * Only %d, %x, %s and %c are used with PQC_PRINTF so that the output is the
 * same with xil_printf, which supports a reduced format set. No field width,
 * no long modifiers.
 */
#ifndef PQC_PLATFORM_H
#define PQC_PLATFORM_H

#include "pqc_ntt_regs.h"

#ifdef PQC_HOST_TEST
#include <stdio.h>
#define PQC_PRINTF printf
#else
#include "xil_printf.h"
#include "xparameters.h"
#define PQC_PRINTF xil_printf
#endif

/* Base address: an explicit -DPQC_NTT_BASEADDR wins, otherwise the address
 * map default of pqc_ntt_regs.h (also used by create_project.tcl). The
 * xparameters.h name of a module reference cell is not known before the
 * first Vitis build (unverified), so it is not used here. */
#ifndef PQC_NTT_BASEADDR
#define PQC_NTT_BASEADDR PQC_NTT_DEFAULT_BASEADDR
#endif

#endif /* PQC_PLATFORM_H */
