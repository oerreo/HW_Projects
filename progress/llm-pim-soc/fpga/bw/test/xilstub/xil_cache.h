/* host syntax-check stub of the Xilinx standalone BSP header (declarations only) */
#ifndef XIL_CACHE_H
#define XIL_CACHE_H
#include "xil_types.h"
void Xil_DCacheFlushRange(INTPTR adr, u32 len);
void Xil_DCacheInvalidateRange(INTPTR adr, u32 len);
#endif
