/*
 * ARM (Zynq-7000 Cortex-A9, bare-metal) baseline of the small LLM golden model.
 * Prints a machine-readable log between "LMBASE BEGIN" and "LMBASE END"
 * (format: fpga/README.md, parser: tools/parse_log.py).
 */
#include <stdint.h>
#include "bcfg.h"
#include "bench.h"
#include "out.h"
#include "plat.h"

#if RUN_M1
extern const unsigned char m1_ck[], m1_tk[];
extern const uint32_t m1_ck_len, m1_tk_len;
#endif

static void build_line(void) {
  o_key("BUILD");
  o_s("plat", plat_name());
  o_i("opt", BUILD_OPT);
#ifdef __OPTIMIZE__
  o_u("optimize", 1);
#else
  o_u("optimize", 0);
#endif
#ifdef __ARM_NEON
  o_u("neon", 1);
#else
  o_u("neon", 0);
#endif
#ifdef __ARM_FP
  o_x("arm_fp", __ARM_FP);
#endif
#ifdef __ARM_PCS_VFP
  o_u("hardfloat", 1);
#endif
  o_u("ptr_bits", (uint64_t)(8u * sizeof(void *)));
  o_u("var_mask", VAR_MASK);
  o_u("run_mask", RUN_MASK);
  o_s("cc", __VERSION__);
  o_end();
}

int main(void) {
  bres_t r = {0, 0, 0};
  int skipped = 0;
  plat_init();
  o_raw("LMBASE BEGIN fmt=1\r\n");
  build_line();
  r.errors += plat_info();
  bench_overhead();
#if RUN_M1
  bench_model(&EXP_M1, m1_ck, m1_ck_len, m1_tk, m1_tk_len, "embedded", &r);
#endif
#if RUN_M2
  if (DDR_CK_ADDR + EXP_M2.ck_len > DDR_TK_ADDR || DDR_TK_ADDR + EXP_M2.tk_len > ARENA_ADDR) {
    o_key("LAYOUT");
    o_s("status", "ddr_images_overlap");
    o_end();
    r.errors++;
  } else {
    int before = r.ran;
    const void *ck = plat_ddr(DDR_CK_ADDR, EXP_M2.ck_len);
    const void *tk = plat_ddr(DDR_TK_ADDR, EXP_M2.tk_len);
    bench_model(&EXP_M2, ck, ck ? EXP_M2.ck_len : 0, tk, tk ? EXP_M2.tk_len : 0, "ddr", &r);
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
  o_raw("LMBASE END\r\n");
  plat_exit((r.mismatches || r.errors || r.ran == 0) ? 1 : 0);
  return 0;
}
