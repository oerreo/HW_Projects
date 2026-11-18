/* main.c: PS test program of pqc_ntt_axi_top (Zybo Z7-20, bare metal).
 *
 * Runs the built-in vectors (vectors.h) through the IP and compares with
 * the expected values:
 *   NTT, INTT          LOAD bank b, op, UNLOAD bank b ^ 1 (b alternates)
 *   BASEMUL            LOAD a -> bank0, b -> bank1, BASEMUL, UNLOAD bank0
 *   POLYMUL            pqc_ntt_polymul (NTT, NTT, BASEMUL, INTT, one PS
 *                      round trip for bank placement)
 * plus register-level checks (all five ERR bits, W1C, done_sticky clear and
 * its exception for an illegal op, LOAD/UNLOAD round trip, bank
 * independence, CONFIG consistent with VERSION), and compares CYCLES with
 * the value expected for the ALGO / BFU_LATENCY read from VERSION.
 *
 * Output: one item per line, "KEY k=v k=v ...", parsed by
 * fpga/sw/tools/parse_uart_log.py. Format described in fpga/README.md.
 * The same file is built for the host test (fpga/sw/test, -DPQC_HOST_TEST).
 */
#include <stdint.h>

#include "pqc_platform.h"
#include "pqc_ntt.h"
#include "pqc_ntt_hal.h"
#include "vectors.h"

#define LOG_FORMAT_VERSION       1
#define MISMATCH_PRINT_PER_CASE  4   /* MISMATCH lines per failing case */
#define MISMATCH_PRINT_TOTAL     64  /* MISMATCH lines in the whole run */
#define MAX_DRIVER_ERRORS        8   /* abort after this many driver errors */

typedef struct {
  int cases;
  int fail_cases;
  int mismatches;   /* coefficient mismatches */
  int cycle_bad;    /* cases whose CYCLES differ from the expected value */
  int errors;       /* driver errors (timeout, ERR, result bank, ...) */
} op_stat_t;

static pqc_ntt_dev_t dev;
static uint16_t got[PQC_NTT_N];
static uint16_t pat[PQC_NTT_N];
static int mismatch_printed;
static int driver_errors;
static int checks_failed;
static int checks_run;

/* ------------------------------------------------------------------------ */
static int compare(const char *op, int idx, const uint16_t *exp, const uint16_t *act)
{
  int i;
  int n = 0;
  for (i = 0; i < PQC_NTT_N; i++) {
    if (exp[i] != act[i]) {
      if (n < MISMATCH_PRINT_PER_CASE && mismatch_printed < MISMATCH_PRINT_TOTAL) {
        PQC_PRINTF("MISMATCH op=%s idx=%d coef=%d exp=0x%x got=0x%x\r\n", op, idx, i,
                   (unsigned)exp[i], (unsigned)act[i]);
        mismatch_printed++;
      }
      n++;
    }
  }
  return n;
}

/* After a driver error: finish a half-done stream and clear ERR so that the
 * next case starts clean. A hung compute op stays busy (no abort, A16). */
static void after_error(void)
{
  driver_errors++;
  (void)pqc_ntt_recover(&dev);
  pqc_ntt_err_clear(&dev, PQC_NTT_ERR_ALL);
}

static void print_case(const char *op, int idx, const char *name, int rc, int mism,
                       uint32_t cycles, uint32_t exp_cycles)
{
  PQC_PRINTF("CASE op=%s idx=%d name=%s rc=%s mismatch=%d cycles=%d exp_cycles=%d cycles_ok=%d\r\n",
             op, idx, name, pqc_ntt_rc_name(rc), mism, (int)cycles, (int)exp_cycles,
             (rc == PQC_OK && cycles == exp_cycles) ? 1 : 0);
}

static void account(op_stat_t *st, int rc, int mism, uint32_t cycles, uint32_t exp_cycles)
{
  st->cases++;
  if (rc != PQC_OK) {
    st->errors++;
    st->fail_cases++;
    after_error();
    return;
  }
  st->mismatches += mism;
  if (cycles != exp_cycles) {
    st->cycle_bad++;
  }
  if (mism != 0 || cycles != exp_cycles) {
    st->fail_cases++;
  }
}

static int print_summary(const char *op, const op_stat_t *st)
{
  int pass = (st->fail_cases == 0 && st->cases > 0);
  PQC_PRINTF("SUMMARY op=%s cases=%d fail_cases=%d mismatch=%d cycle_bad=%d errors=%d result=%s\r\n",
             op, st->cases, st->fail_cases, st->mismatches, st->cycle_bad, st->errors,
             pass ? "PASS" : "FAIL");
  return pass;
}

/* ------------------------------------------------------------------------
 * Vector tests
 * ------------------------------------------------------------------------ */
static int test_transform(unsigned op, const pqc_vec_t *vec, int count, uint32_t exp_cycles)
{
  const char *name = pqc_ntt_op_name(op);
  op_stat_t st = {0, 0, 0, 0, 0};
  int k;
  for (k = 0; k < count && driver_errors < MAX_DRIVER_ERRORS; k++) {
    unsigned bank = (unsigned)k & 1u; /* use both banks as input */
    uint32_t cycles = 0;
    int mism = 0;
    int rc = pqc_ntt_load(&dev, bank, vec[k].a);
    if (rc == PQC_OK) {
      rc = pqc_ntt_run(&dev, op, bank);
      cycles = dev.last_cycles;
    }
    if (rc == PQC_OK) {
      rc = pqc_ntt_unload(&dev, pqc_ntt_result_bank(op, bank), got);
    }
    if (rc == PQC_OK) {
      mism = compare(name, k, vec[k].out, got);
    }
    print_case(name, k, vec[k].name, rc, mism, cycles, exp_cycles);
    account(&st, rc, mism, cycles, exp_cycles);
  }
  return print_summary(name, &st);
}

static int test_basemul(const pqc_vec_t *vec, int count, uint32_t exp_cycles)
{
  op_stat_t st = {0, 0, 0, 0, 0};
  int k;
  for (k = 0; k < count && driver_errors < MAX_DRIVER_ERRORS; k++) {
    uint32_t cycles = 0;
    int mism = 0;
    int rc = pqc_ntt_load(&dev, 0u, vec[k].a);
    if (rc == PQC_OK) rc = pqc_ntt_load(&dev, 1u, vec[k].b);
    if (rc == PQC_OK) {
      rc = pqc_ntt_run(&dev, PQC_NTT_OP_BASEMUL, 0u);
      cycles = dev.last_cycles;
    }
    if (rc == PQC_OK) rc = pqc_ntt_unload(&dev, pqc_ntt_result_bank(PQC_NTT_OP_BASEMUL, 0u), got);
    if (rc == PQC_OK) mism = compare("BASEMUL", k, vec[k].out, got);
    print_case("BASEMUL", k, vec[k].name, rc, mism, cycles, exp_cycles);
    account(&st, rc, mism, cycles, exp_cycles);
  }
  return print_summary("BASEMUL", &st);
}

static int test_polymul(const pqc_vec_t *vec, int count, uint32_t exp_cycles)
{
  op_stat_t st = {0, 0, 0, 0, 0};
  int k;
  for (k = 0; k < count && driver_errors < MAX_DRIVER_ERRORS; k++) {
    uint32_t cycles = 0;
    int mism = 0;
    int rc = pqc_ntt_polymul(&dev, vec[k].a, vec[k].b, got, &cycles);
    if (rc == PQC_OK) mism = compare("POLYMUL", k, vec[k].out, got);
    print_case("POLYMUL", k, vec[k].name, rc, mism, cycles, exp_cycles);
    account(&st, rc, mism, cycles, exp_cycles);
  }
  return print_summary("POLYMUL", &st);
}

/* ------------------------------------------------------------------------
 * Register-level checks (l4_axi.md "decided behaviour"; ASSUMPTIONS.md A4,
 * A5, A8, A9, A14, A15)
 * ------------------------------------------------------------------------ */
static void check(const char *name, int ok, uint32_t val)
{
  checks_run++;
  if (!ok) checks_failed++;
  PQC_PRINTF("CHECK name=%s result=%s val=0x%x\r\n", name, ok ? "PASS" : "FAIL", (unsigned)val);
}

static void make_pattern(uint16_t *p, unsigned mul, unsigned add)
{
  int i;
  for (i = 0; i < PQC_NTT_N; i++) {
    p[i] = (uint16_t)(((unsigned)i * mul + add) % PQC_NTT_Q);
  }
}

static void register_checks(void)
{
  uint32_t e, s, v;
  int i, rc, ok;

  /* ERR after reset / previous run: report, then clear. */
  e = pqc_ntt_err_read(&dev);
  PQC_PRINTF("INFO err_at_start=0x%x\r\n", (unsigned)e);
  pqc_ntt_err_clear(&dev, PQC_NTT_ERR_ALL);
  check("err_clear_all", pqc_ntt_err_read(&dev) == 0u, pqc_ntt_err_read(&dev));

  s = pqc_ntt_status(&dev);
  check("idle_at_start", (s & PQC_NTT_STATUS_BUSY) == 0u, s);

  /* DIN write while idle -> ERR.din only. */
  reg_write32(dev.base, PQC_NTT_REG_DIN, 1u);
  e = pqc_ntt_err_read(&dev);
  check("err_din_idle", e == PQC_NTT_ERR_DIN, e);
  /* W1C: writing another bit leaves ERR.din, writing it clears it. */
  pqc_ntt_err_clear(&dev, PQC_NTT_ERR_START_BUSY);
  e = pqc_ntt_err_read(&dev);
  check("err_w1c_other_bit", e == PQC_NTT_ERR_DIN, e);
  pqc_ntt_err_clear(&dev, PQC_NTT_ERR_DIN);
  e = pqc_ntt_err_read(&dev);
  check("err_w1c_clear", e == 0u, e);

  /* DOUT read while idle -> ERR.dout only. */
  v = reg_read32(dev.base, PQC_NTT_REG_DOUT);
  e = pqc_ntt_err_read(&dev);
  check("err_dout_idle", e == PQC_NTT_ERR_DOUT, e);
  PQC_PRINTF("INFO dout_idle_value=0x%x\r\n", (unsigned)v);
  pqc_ntt_err_clear(&dev, PQC_NTT_ERR_ALL);

  /* start while busy (LOAD waiting for data) -> ERR.start_busy, LOAD
   * continues and loads the pattern correctly. */
  make_pattern(pat, 13u, 7u);
  rc = pqc_ntt_start(&dev, PQC_NTT_OP_LOAD, 0u);
  check("start_load_raw", rc == PQC_OK, (uint32_t)rc);
  reg_write32(dev.base, PQC_NTT_REG_CTRL, PQC_NTT_CTRL_VALUE(1u, PQC_NTT_OP_NTT, 0u));
  e = pqc_ntt_err_read(&dev);
  check("err_start_busy", e == PQC_NTT_ERR_START_BUSY, e);
  s = pqc_ntt_status(&dev);
  check("load_still_busy", (s & PQC_NTT_STATUS_BUSY) != 0u && (s & PQC_NTT_STATUS_DONE_STICKY) == 0u, s);
  pqc_ntt_err_clear(&dev, PQC_NTT_ERR_ALL);
  ok = 1;
  for (i = 0; i < PQC_NTT_N && ok; i++) {
    uint32_t n;
    for (n = 0; n < dev.poll_limit; n++) {
      if (pqc_ntt_status(&dev) & PQC_NTT_STATUS_IN_READY) break;
    }
    if (n == dev.poll_limit) ok = 0;
    else reg_write32(dev.base, PQC_NTT_REG_DIN, pat[i]);
  }
  rc = ok ? pqc_ntt_wait_done(&dev) : PQC_ERR_TIMEOUT;
  check("load_after_start_busy_done", rc == PQC_OK, (uint32_t)rc);
  if (rc != PQC_OK) after_error();
  rc = pqc_ntt_unload(&dev, 0u, got);
  check("load_after_start_busy_data", rc == PQC_OK && compare("CHECK", 0, pat, got) == 0, (uint32_t)rc);
  if (rc != PQC_OK) after_error();

  /* done_sticky is cleared by a CTRL write without start (A5). */
  s = pqc_ntt_status(&dev);
  check("done_sticky_set", (s & PQC_NTT_STATUS_DONE_STICKY) != 0u, s);
  /* An illegal op changes neither busy nor done_sticky, sets ERR.bad_op
   * (A9). The driver never writes one; written raw here. */
  reg_write32(dev.base, PQC_NTT_REG_CTRL, PQC_NTT_CTRL_VALUE(1u, 7u, 0u));
  s = pqc_ntt_status(&dev);
  check("bad_op_keeps_status", (s & (PQC_NTT_STATUS_DONE_STICKY | PQC_NTT_STATUS_BUSY)) ==
                                   PQC_NTT_STATUS_DONE_STICKY, s);
  e = pqc_ntt_err_read(&dev);
  check("err_bad_op", e == PQC_NTT_ERR_BAD_OP, e);
  pqc_ntt_err_clear(&dev, PQC_NTT_ERR_ALL);
  reg_write32(dev.base, PQC_NTT_REG_CTRL, PQC_NTT_CTRL_VALUE(0u, PQC_NTT_OP_LOAD, 0u));
  s = pqc_ntt_status(&dev);
  check("done_sticky_clear_by_ctrl", (s & (PQC_NTT_STATUS_DONE_STICKY | PQC_NTT_STATUS_BUSY)) == 0u, s);

  /* The two banks are independent (LOAD / UNLOAD round trip). */
  make_pattern(pat, 29u, 3u);
  rc = pqc_ntt_load(&dev, 0u, pat);
  if (rc == PQC_OK) {
    make_pattern(got, 31u, 1000u);
    rc = pqc_ntt_load(&dev, 1u, got);
  }
  if (rc == PQC_OK) rc = pqc_ntt_unload(&dev, 0u, got);
  check("bank0_roundtrip", rc == PQC_OK && compare("CHECK", 1, pat, got) == 0, (uint32_t)rc);
  if (rc != PQC_OK) after_error();
  make_pattern(pat, 31u, 1000u);
  rc = pqc_ntt_unload(&dev, 1u, got);
  check("bank1_roundtrip", rc == PQC_OK && compare("CHECK", 2, pat, got) == 0, (uint32_t)rc);
  if (rc != PQC_OK) after_error();

  /* din_range: a word >= q written raw during LOAD is stored as its low 12
   * bits and sets ERR.din_range (A15; the driver rejects such input). */
  make_pattern(pat, 37u, 11u);
  pat[9] = (uint16_t)PQC_NTT_Q;
  pat[10] = 0xFFFu;
  rc = pqc_ntt_start(&dev, PQC_NTT_OP_LOAD, 1u);
  ok = (rc == PQC_OK);
  for (i = 0; i < PQC_NTT_N && ok; i++) {
    uint32_t n;
    for (n = 0; n < dev.poll_limit; n++) {
      if (pqc_ntt_status(&dev) & PQC_NTT_STATUS_IN_READY) break;
    }
    if (n == dev.poll_limit) ok = 0;
    else reg_write32(dev.base, PQC_NTT_REG_DIN, pat[i]);
  }
  rc = ok ? pqc_ntt_wait_done(&dev) : PQC_ERR_TIMEOUT;
  e = pqc_ntt_err_read(&dev);
  check("err_din_range", rc == PQC_OK && e == PQC_NTT_ERR_DIN_RANGE, e);
  if (rc != PQC_OK) after_error();
  pqc_ntt_err_clear(&dev, PQC_NTT_ERR_ALL);
  rc = pqc_ntt_unload(&dev, 1u, got);
  check("din_range_stored_unchanged", rc == PQC_OK && compare("CHECK", 3, pat, got) == 0, (uint32_t)rc);
  if (rc != PQC_OK) after_error();

  /* CONFIG: pipeline fields add up to VERSION.BFU_LATENCY */
  {
    pqc_ntt_version_t vv;
    pqc_ntt_config_t cc;
    pqc_ntt_version(&dev, &vv);
    pqc_ntt_config(&dev, &cc);
    check("config_latency", cc.pre_reg + cc.mul_reg + cc.red_pipe + cc.out_reg == vv.bfu_latency &&
                                cc.fclk_mhz != 0u, cc.raw);
  }

  e = pqc_ntt_err_read(&dev);
  check("err_zero_after_checks", e == 0u, e);
  pqc_ntt_err_clear(&dev, PQC_NTT_ERR_ALL);
}

/* ------------------------------------------------------------------------ */
int main(void)
{
  pqc_ntt_version_t ver;
  pqc_ntt_config_t cfg;
  uint32_t c_ntt, c_intt, c_bm, c_pm;
  int pass = 1;
  int version_ok;

  pqc_ntt_init(&dev, (uintptr_t)PQC_NTT_BASEADDR);

  PQC_PRINTF("\r\nPQCNTT BEGIN fmt=%d\r\n", LOG_FORMAT_VERSION);
  PQC_PRINTF("INFO base=0x%x vectors_ntt=%d vectors_intt=%d vectors_basemul=%d vectors_polymul=%d\r\n",
             (unsigned)PQC_NTT_BASEADDR, VEC_NTT_COUNT, VEC_INTT_COUNT, VEC_BASEMUL_COUNT,
             VEC_POLYMUL_COUNT);

  pqc_ntt_version(&dev, &ver);
  version_ok = (ver.id == PQC_NTT_VERSION_ID_VALUE) && (ver.algo < PQC_NTT_ALGO_COUNT);
  PQC_PRINTF("VERSION raw=0x%x id=0x%x id_ok=%d algo=%d algo_name=%s bfu_latency=%d\r\n",
             (unsigned)ver.raw, (unsigned)ver.id, ver.id == PQC_NTT_VERSION_ID_VALUE ? 1 : 0,
             (int)ver.algo, pqc_ntt_algo_name(ver.algo), (int)ver.bfu_latency);
  pqc_ntt_config(&dev, &cfg);
  PQC_PRINTF("CONFIG raw=0x%x impl=%d share_addsub=%d rom_out_reg=%d pre_reg=%d mul_reg=%d red_pipe=%d out_reg=%d fclk_mhz=%d\r\n",
             (unsigned)cfg.raw, (int)cfg.impl, (int)cfg.share_addsub, (int)cfg.rom_out_reg, (int)cfg.pre_reg,
             (int)cfg.mul_reg, (int)cfg.red_pipe, (int)cfg.out_reg, (int)cfg.fclk_mhz);
  if (!version_ok) {
    /* Wrong ID: wrong base address, no bitstream, or header / RTL out of
     * sync. Expected cycles are meaningless; stop here. */
    PQC_PRINTF("ABORT reason=version\r\n");
    PQC_PRINTF("RESULT: FAIL\r\n");
    PQC_PRINTF("PQCNTT END\r\n");
    return 1;
  }

  c_ntt = pqc_ntt_expected_cycles(PQC_NTT_OP_NTT, ver.algo, ver.bfu_latency);
  c_intt = pqc_ntt_expected_cycles(PQC_NTT_OP_INTT, ver.algo, ver.bfu_latency);
  c_bm = pqc_ntt_expected_cycles(PQC_NTT_OP_BASEMUL, ver.algo, ver.bfu_latency);
  c_pm = 2u * c_ntt + c_bm + c_intt;
  PQC_PRINTF("EXPECT op=NTT cycles=%d\r\n", (int)c_ntt);
  PQC_PRINTF("EXPECT op=INTT cycles=%d\r\n", (int)c_intt);
  PQC_PRINTF("EXPECT op=BASEMUL cycles=%d\r\n", (int)c_bm);
  PQC_PRINTF("EXPECT op=POLYMUL cycles=%d\r\n", (int)c_pm);

  register_checks();
  PQC_PRINTF("SUMMARY op=CHECK cases=%d fail_cases=%d mismatch=0 cycle_bad=0 errors=0 result=%s\r\n",
             checks_run, checks_failed, checks_failed ? "FAIL" : "PASS");
  if (checks_failed) pass = 0;

  if (!test_transform(PQC_NTT_OP_NTT, vec_ntt, VEC_NTT_COUNT, c_ntt)) pass = 0;
  if (!test_transform(PQC_NTT_OP_INTT, vec_intt, VEC_INTT_COUNT, c_intt)) pass = 0;
  if (!test_basemul(vec_basemul, VEC_BASEMUL_COUNT, c_bm)) pass = 0;
  if (!test_polymul(vec_polymul, VEC_POLYMUL_COUNT, c_pm)) pass = 0;

  if (driver_errors >= MAX_DRIVER_ERRORS) {
    PQC_PRINTF("ABORT reason=driver_errors count=%d\r\n", driver_errors);
    pass = 0;
  }
  PQC_PRINTF("RESULT: %s\r\n", pass ? "PASS" : "FAIL");
  PQC_PRINTF("PQCNTT END\r\n");
  return pass ? 0 : 1;
}
