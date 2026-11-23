/*
 * The system program's main (fpga/sys/sw/sys_main.c, unchanged) as a function the testbench
 * calls (sys_tb.c): only its name changes.
 */
#define main sys_prog_main
int sys_prog_main(void);
#include "sys_main.c"
