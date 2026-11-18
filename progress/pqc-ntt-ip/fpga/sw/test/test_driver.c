/* test_driver.c: host-only negative and corner tests of the driver against
 * the register model (reg_model.c). Each test prints
 *   NEG name=<name> result=PASS|FAIL detail=...
 * and the program ends with "NEGTEST RESULT: PASS|FAIL".
 *
 * What is covered: every ERR bit (start_busy, din_notready, dout_notvalid,
 * bad_op, din_range), W1C, driver argument checks (no hardware access on a
 * rejected call), busy precondition, timeouts (hang, stall, illegal op),
 * recovery of half-finished LOAD / UNLOAD, result bank check, done_sticky
 * clear and its exception for an illegal op, CONFIG decode, LOAD/UNLOAD
 * round trip, and that STATUS polling saw not-ready states (so the poll
 * loops were exercised).
 */
#include <stdio.h>
#include <string.h>

#include "pqc_ntt.h"
#include "pqc_ntt_hal.h"
#include "reg_model.h"

static int n_fail;
static int n_run;

static void report(const char *name, int ok, const char *detail)
{
  n_run++;
  if (!ok) n_fail++;
  printf("NEG name=%s result=%s detail=%s\n", name, ok ? "PASS" : "FAIL", detail);
}

static pqc_ntt_dev_t dev;
static uint16_t a[PQC_NTT_N], b[PQC_NTT_N];
static char msg[256];

static void fresh(int algo, int lat, int fault)
{
  reg_model_config(algo, lat, fault, 7u);
  pqc_ntt_init(&dev, (uintptr_t)PQC_NTT_DEFAULT_BASEADDR);
}

static void pattern(uint16_t *p, unsigned mul, unsigned add)
{
  int i;
  for (i = 0; i < PQC_NTT_N; i++) p[i] = (uint16_t)(((unsigned)i * mul + add) % PQC_NTT_Q);
}

int main(void)
{
  reg_model_stats_t st0, st1;
  pqc_ntt_version_t v;
  uint32_t e, s;
  int rc, i;

  /* VERSION decode */
  fresh(PQC_NTT_ALGO_K2RED, 3, RM_FAULT_NONE);
  pqc_ntt_version(&dev, &v);
  snprintf(msg, sizeof msg, "raw=0x%x", (unsigned)v.raw);
  report("version_decode", v.algo == 3u && v.bfu_latency == 3u && v.id == PQC_NTT_VERSION_ID_VALUE, msg);

  /* CONFIG decode (model default for LATENCY 3: CFG preset l3, 100 MHz) */
  {
    pqc_ntt_config_t c;
    pqc_ntt_config(&dev, &c);
    snprintf(msg, sizeof msg, "raw=0x%x", (unsigned)c.raw);
    report("config_decode", c.impl == 0u && c.share_addsub == 0u && c.rom_out_reg == 1u && c.pre_reg == 0u &&
                                c.mul_reg == 1u && c.red_pipe == 1u && c.out_reg == 1u && c.fclk_mhz == 100u &&
                                c.pre_reg + c.mul_reg + c.red_pipe + c.out_reg == v.bfu_latency, msg);
  }

  /* ERR.din, W1C of a single bit */
  fresh(0, 0, RM_FAULT_NONE);
  reg_write32(dev.base, PQC_NTT_REG_DIN, 5u);
  e = pqc_ntt_err_read(&dev);
  report("err_din_idle", e == PQC_NTT_ERR_DIN, "");
  pqc_ntt_err_clear(&dev, PQC_NTT_ERR_DIN);
  reg_write32(dev.base, PQC_NTT_REG_DIN, 0xFFFu); /* dropped: no din_range */
  e = pqc_ntt_err_read(&dev);
  report("err_din_idle_ge_q_only_din", e == PQC_NTT_ERR_DIN, "");
  reg_read32(dev.base, PQC_NTT_REG_DOUT);
  e = pqc_ntt_err_read(&dev);
  report("err_dout_idle", e == (PQC_NTT_ERR_DIN | PQC_NTT_ERR_DOUT), "");
  pqc_ntt_err_clear(&dev, PQC_NTT_ERR_DIN);
  e = pqc_ntt_err_read(&dev);
  report("err_w1c_single_bit", e == PQC_NTT_ERR_DOUT, "");
  pqc_ntt_err_clear(&dev, PQC_NTT_ERR_ALL);

  /* ERR left set makes the next op report PQC_ERR_HW (driver does not
   * clear ERR by itself) */
  pattern(a, 1u, 0u);
  reg_write32(dev.base, PQC_NTT_REG_DIN, 5u);
  rc = pqc_ntt_load(&dev, 0u, a);
  report("stale_err_reported", rc == PQC_ERR_HW && dev.last_err == PQC_NTT_ERR_DIN, pqc_ntt_rc_name(rc));
  pqc_ntt_err_clear(&dev, PQC_NTT_ERR_ALL);

  /* start while busy: raw CTRL write -> ERR.start_busy; driver start ->
   * PQC_ERR_BUSY without touching CTRL */
  fresh(0, 0, RM_FAULT_NONE);
  rc = pqc_ntt_start(&dev, PQC_NTT_OP_LOAD, 1u);
  reg_write32(dev.base, PQC_NTT_REG_CTRL, PQC_NTT_CTRL_VALUE(1u, PQC_NTT_OP_NTT, 0u));
  e = pqc_ntt_err_read(&dev);
  report("err_start_busy", rc == PQC_OK && e == PQC_NTT_ERR_START_BUSY, "");
  pqc_ntt_err_clear(&dev, PQC_NTT_ERR_ALL);
  rc = pqc_ntt_run(&dev, PQC_NTT_OP_NTT, 0u);
  e = pqc_ntt_err_read(&dev);
  report("driver_refuses_start_when_busy", rc == PQC_ERR_BUSY && e == 0u, pqc_ntt_rc_name(rc));
  rc = pqc_ntt_load(&dev, 0u, a);
  report("driver_refuses_load_when_busy", rc == PQC_ERR_BUSY, pqc_ntt_rc_name(rc));

  /* recover a half-finished LOAD (100 words written) */
  for (i = 0; i < 100; i++) {
    while (!(pqc_ntt_status(&dev) & PQC_NTT_STATUS_IN_READY)) {}
    reg_write32(dev.base, PQC_NTT_REG_DIN, 1u);
  }
  rc = pqc_ntt_recover(&dev);
  s = pqc_ntt_status(&dev);
  report("recover_load", rc == PQC_OK && !(s & PQC_NTT_STATUS_BUSY) && pqc_ntt_err_read(&dev) == 0u,
         pqc_ntt_rc_name(rc));

  /* recover a half-finished UNLOAD (10 words read) */
  rc = pqc_ntt_start(&dev, PQC_NTT_OP_UNLOAD, 0u);
  for (i = 0; i < 10; i++) {
    while (!(pqc_ntt_status(&dev) & PQC_NTT_STATUS_OUT_VALID)) {}
    reg_read32(dev.base, PQC_NTT_REG_DOUT);
  }
  rc = pqc_ntt_recover(&dev);
  s = pqc_ntt_status(&dev);
  report("recover_unload", rc == PQC_OK && !(s & PQC_NTT_STATUS_BUSY) && pqc_ntt_err_read(&dev) == 0u,
         pqc_ntt_rc_name(rc));

  /* argument checks: rejected without any register access */
  fresh(0, 0, RM_FAULT_NONE);
  reg_model_get_stats(&st0);
  pattern(a, 1u, 0u);
  a[200] = (uint16_t)PQC_NTT_Q; /* out of range */
  rc = pqc_ntt_load(&dev, 0u, a);
  report("arg_coef_ge_q", rc == PQC_ERR_ARG, pqc_ntt_rc_name(rc));
  a[200] = 0;
  rc = pqc_ntt_load(&dev, 2u, a);
  report("arg_bank", rc == PQC_ERR_ARG, pqc_ntt_rc_name(rc));
  rc = pqc_ntt_run(&dev, PQC_NTT_OP_LOAD, 0u);
  report("arg_run_load", rc == PQC_ERR_ARG, pqc_ntt_rc_name(rc));
  rc = pqc_ntt_run(&dev, 7u, 0u);
  report("arg_run_illegal_op", rc == PQC_ERR_ARG, pqc_ntt_rc_name(rc));
  rc = pqc_ntt_start(&dev, 5u, 0u);
  report("arg_start_illegal_op", rc == PQC_ERR_ARG, pqc_ntt_rc_name(rc));
  reg_model_get_stats(&st1);
  report("arg_no_access", st1.accesses == st0.accesses, "");

  /* illegal op written raw: no busy, no done (A9) -> timeout, ERR.bad_op */
  dev.poll_limit = 1000u;
  reg_write32(dev.base, PQC_NTT_REG_CTRL, PQC_NTT_CTRL_VALUE(1u, 5u, 0u));
  rc = pqc_ntt_wait_done(&dev);
  report("illegal_op_raw_timeout", rc == PQC_ERR_TIMEOUT && pqc_ntt_err_read(&dev) == PQC_NTT_ERR_BAD_OP,
         pqc_ntt_rc_name(rc));
  pqc_ntt_err_clear(&dev, PQC_NTT_ERR_ALL);
  dev.poll_limit = PQC_NTT_POLL_LIMIT_DEFAULT;

  /* illegal op after an op: done_sticky and busy unchanged, ERR.bad_op */
  pattern(a, 5u, 9u);
  rc = pqc_ntt_load(&dev, 0u, a);
  reg_write32(dev.base, PQC_NTT_REG_CTRL, PQC_NTT_CTRL_VALUE(1u, 7u, 1u));
  s = pqc_ntt_status(&dev);
  e = pqc_ntt_err_read(&dev);
  snprintf(msg, sizeof msg, "status=0x%x err=0x%x", (unsigned)s, (unsigned)e);
  report("bad_op_keeps_done_sticky", rc == PQC_OK && (s & PQC_NTT_STATUS_DONE_STICKY) &&
                                         !(s & PQC_NTT_STATUS_BUSY) && e == PQC_NTT_ERR_BAD_OP, msg);
  pqc_ntt_err_clear(&dev, PQC_NTT_ERR_ALL);

  /* illegal op while busy: start_busy and bad_op */
  rc = pqc_ntt_start(&dev, PQC_NTT_OP_LOAD, 1u);
  reg_write32(dev.base, PQC_NTT_REG_CTRL, PQC_NTT_CTRL_VALUE(1u, 6u, 0u));
  e = pqc_ntt_err_read(&dev);
  report("bad_op_while_busy", rc == PQC_OK && e == (PQC_NTT_ERR_START_BUSY | PQC_NTT_ERR_BAD_OP), "");
  pqc_ntt_err_clear(&dev, PQC_NTT_ERR_ALL);

  /* din_range: words >= q written raw during that LOAD are stored as their
   * low 12 bits and set ERR.din_range */
  pattern(b, 7u, 2u);
  b[5] = (uint16_t)PQC_NTT_Q;
  b[6] = 0xFFFu;
  for (i = 0; i < PQC_NTT_N; i++) {
    while (!(pqc_ntt_status(&dev) & PQC_NTT_STATUS_IN_READY)) {}
    reg_write32(dev.base, PQC_NTT_REG_DIN, (i == 6) ? 0xFFFFFFFFu : b[i]);
  }
  rc = pqc_ntt_wait_done(&dev);
  e = pqc_ntt_err_read(&dev);
  report("err_din_range", rc == PQC_OK && e == PQC_NTT_ERR_DIN_RANGE, pqc_ntt_rc_name(rc));
  pqc_ntt_err_clear(&dev, PQC_NTT_ERR_ALL);
  {
    uint16_t r1[PQC_NTT_N];
    rc = pqc_ntt_unload(&dev, 1u, r1);
    report("din_range_word_stored_unchanged", rc == PQC_OK && !memcmp(b, r1, sizeof b), pqc_ntt_rc_name(rc));
  }

  /* hang: compute op never completes -> timeout, then busy blocks ops */
  fresh(1, 2, RM_FAULT_HANG);
  dev.poll_limit = 2000u;
  pattern(a, 3u, 1u);
  rc = pqc_ntt_load(&dev, 0u, a);
  if (rc == PQC_OK) rc = pqc_ntt_run(&dev, PQC_NTT_OP_NTT, 0u);
  report("timeout_hang", rc == PQC_ERR_TIMEOUT, pqc_ntt_rc_name(rc));
  rc = pqc_ntt_unload(&dev, 1u, b);
  report("busy_after_hang", rc == PQC_ERR_BUSY, pqc_ntt_rc_name(rc));
  rc = pqc_ntt_recover(&dev); /* NTT never ends: recover must give up too */
  report("recover_gives_up_on_hang", rc == PQC_ERR_TIMEOUT, pqc_ntt_rc_name(rc));

  /* stall: in_ready never rises -> load times out at the first word */
  fresh(0, 0, RM_FAULT_STALL);
  dev.poll_limit = 2000u;
  rc = pqc_ntt_load(&dev, 0u, a);
  report("timeout_stall_load", rc == PQC_ERR_TIMEOUT, pqc_ntt_rc_name(rc));

  /* wrong result bank -> PQC_ERR_STATE */
  fresh(0, 1, RM_FAULT_RBANK);
  rc = pqc_ntt_load(&dev, 0u, a);
  if (rc == PQC_OK) rc = pqc_ntt_run(&dev, PQC_NTT_OP_INTT, 0u);
  report("result_bank_checked", rc == PQC_ERR_STATE, pqc_ntt_rc_name(rc));

  /* done_sticky: set after an op, cleared by any CTRL write (A5) */
  fresh(2, 1, RM_FAULT_NONE);
  rc = pqc_ntt_load(&dev, 1u, a);
  s = pqc_ntt_status(&dev);
  reg_write32(dev.base, PQC_NTT_REG_CTRL, 0u);
  report("done_sticky_clear", rc == PQC_OK && (s & PQC_NTT_STATUS_DONE_STICKY) &&
                                  !(pqc_ntt_status(&dev) & PQC_NTT_STATUS_DONE_STICKY), "");

  /* LOAD / UNLOAD round trip on both banks, cycles of an NTT */
  pattern(a, 17u, 5u);
  pattern(b, 1000u, 3u);
  rc = pqc_ntt_load(&dev, 0u, a);
  if (rc == PQC_OK) rc = pqc_ntt_load(&dev, 1u, b);
  {
    uint16_t r0[PQC_NTT_N], r1[PQC_NTT_N];
    if (rc == PQC_OK) rc = pqc_ntt_unload(&dev, 0u, r0);
    if (rc == PQC_OK) rc = pqc_ntt_unload(&dev, 1u, r1);
    report("roundtrip_two_banks",
           rc == PQC_OK && !memcmp(a, r0, sizeof a) && !memcmp(b, r1, sizeof b), pqc_ntt_rc_name(rc));
  }
  rc = pqc_ntt_run(&dev, PQC_NTT_OP_NTT, 0u);
  snprintf(msg, sizeof msg, "cycles=%u exp=%u", (unsigned)dev.last_cycles,
           (unsigned)pqc_ntt_expected_cycles(PQC_NTT_OP_NTT, 2u, 1u));
  report("ntt_cycles", rc == PQC_OK && dev.last_cycles == pqc_ntt_expected_cycles(PQC_NTT_OP_NTT, 2u, 1u), msg);

  /* the STATUS polls saw not-ready states (poll loops exercised) */
  reg_model_get_stats(&st1);
  snprintf(msg, sizeof msg, "status_reads=%llu not_ready=%llu",
           (unsigned long long)st1.status_reads, (unsigned long long)st1.status_not_ready);
  report("polling_exercised", st1.status_not_ready > 0u, msg);

  printf("NEGTEST runs=%d fail=%d\n", n_run, n_fail);
  printf("NEGTEST RESULT: %s\n", n_fail ? "FAIL" : "PASS");
  return n_fail ? 1 : 0;
}
