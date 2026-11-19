/* host syntax-check stub of the Xilinx standalone BSP header (declarations only) */
#ifndef XIL_IO_H
#define XIL_IO_H
#include <stdint.h>
typedef uintptr_t UINTPTR;
uint32_t Xil_In32(UINTPTR addr);
void Xil_Out32(UINTPTR addr, uint32_t v);
#endif
