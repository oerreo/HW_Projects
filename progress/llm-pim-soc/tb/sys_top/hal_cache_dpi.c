/*
 * The cache model of the system program (fpga/sys/test/hal_cache.c, unchanged) for the RTL
 * system testbench, with one testbench addition: hal_ctx (kernel name and position of every
 * kernel call of the executor, sx_exec.c) is also written to the viewer trace (hal_dpi.c
 * tb_vt_ctx, +VTRACE) before it goes to the cache model. Only the function name changes, as in
 * sys_main_dpi.c.
 */
#define hal_ctx hal_ctx_model
#include "hal_cache.c"
#undef hal_ctx

#include "systb.h"

void hal_ctx(const char *k, int pos);
void hal_ctx(const char *k, int pos) {
  tb_vt_ctx(k, pos);
  hal_ctx_model(k, pos);
}
