/*
 * System program (S5-1): the H forward pass of the ARM baseline with kernels offloaded to the
 * PL IPs by a runtime mask. Prints a machine-readable log between "LMSYS BEGIN" and
 * "LMSYS END" (format: fpga/sys/README.md, parser: fpga/sw/tools/parse_log.py).
 */
#include <stdint.h>
#include "bcfg.h"
#include "hal.h"
#include "out.h"
#include "plat.h"
#include "sbench.h"
#include "scfg.h"

#if SYS_RUN_M1
extern const unsigned char m1_ck[], m1_tk[];
extern const uint32_t m1_ck_len, m1_tk_len;
#endif

static sys_t SYS;

/* host test: SX_MODELS ("1", "2", "12") selects the models; board: both compiled ones */
static int model_on(int k) {
  const char *s = hal_env("SX_MODELS");
  if (!s) return 1;
  for (; *s; s++)
    if (*s - '0' == k) return 1;
  return 0;
}

static void build_line(void) {
  o_key("BUILD");
  o_s("prog", "sys");
  o_s("plat", plat_name());
  o_s("hal", hal_name());
  o_i("opt", BUILD_OPT);
#ifdef __OPTIMIZE__
  o_u("optimize", 1);
#else
  o_u("optimize", 0);
#endif
  o_u("ptr_bits", (uint64_t)(8u * sizeof(void *)));
  o_u("run_mask", SYS_RUN_MASK);
  o_u("steps", SYS_STEPS);
  o_u("fault_inj", SX_FAULT_INJ);
  o_s("cc", __VERSION__);
  o_end();
  o_key("CLK");
  o_u("tps", plat_tps());
  o_end();
}

int main(void) {
  sres_t r = {0, 0, 0};
  int skipped = 0;
  plat_init();
  o_raw("LMSYS BEGIN fmt=1\r\n");
  build_line();
  r.errors += plat_info();
  if (hal_init()) {
    o_key("HAL");
    o_s("status", "init_failed");
    o_end();
    r.errors++;
  }
  sys_detect(&SYS);
#if SYS_RUN_M1
  if (model_on(1)) sbench_model(&EXP_M1, &SYS, m1_ck, m1_ck_len, m1_tk, m1_tk_len, "embedded", &r);
#endif
#if SYS_RUN_M2
  if (model_on(2)) {
    int before = r.ran;
    const void *ck = plat_ddr(DDR_CK_ADDR, EXP_M2.ck_len);
    const void *tk = plat_ddr(DDR_TK_ADDR, EXP_M2.tk_len);
    sbench_model(&EXP_M2, &SYS, ck, ck ? EXP_M2.ck_len : 0, tk, tk ? EXP_M2.tk_len : 0, "ddr", &r);
    if (r.ran == before) skipped++;
  }
#endif
  o_key("RESULT");
  o_u("models_run", (uint64_t)r.ran);
  o_u("models_skipped", (uint64_t)skipped);
  o_i("mismatches", r.mismatches);
  o_i("errors", r.errors);
  o_s("result", (r.mismatches || r.errors || r.ran == 0) ? "FAIL" : "PASS");
  o_end();
  o_raw("LMSYS END\r\n");
  plat_exit((r.mismatches || r.errors || r.ran == 0) ? 1 : 0);
  return 0;
}
