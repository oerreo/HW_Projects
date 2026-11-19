/* host syntax-check stub of the Xilinx standalone BSP header (declarations only) */
#ifndef XTIME_L_H
#define XTIME_L_H
#include <stdint.h>
#include "xparameters.h"
typedef uint64_t XTime;
#define COUNTS_PER_SECOND (XPAR_CPU_CORTEXA9_CORE_CLOCK_FREQ_HZ / 2)
void XTime_GetTime(XTime *t);
#endif
