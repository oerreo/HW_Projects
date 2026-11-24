/*
 * RTL system testbench, C entry (S5-3, docs/spec/system.md 3.2, 3.3). The imported DPI-C
 * context task sys_tb_main runs the unchanged system program (fpga/sys/sw/sys_main.c, its main
 * renamed by sys_main_dpi.c) against the RTL through hal_dpi.c / plat_dpi.c, collects its log
 * lines and judges them:
 *   SYS     the build found by the program's own slot detection (all 16 slots) equals
 *           +EXP_BUILD (A | P, or the variants A2 = GA_P 2, PD = AT_KV_SRC 1) with the ID /
 *           CONFIG values of system.md 1.7 (written here from the spec, not from the RTL), no
 *           other slot answers
 *   CHECK   exactly +EXP_CHECKS run checks; each: tok_mis, hash_mis, kmis, coh = 0 (token and
 *           logits hash of every simulated position equal the PC expected values, run K
 *           kernel compare); without fault injection also fb = 0, iperr = 0, result PASS
 *   faults  +EXP_IPERR=<n> (+EXP_IPERR_IP, +EXP_IPERR_KIND): the IPERR count of all runs is n,
 *           every IPERR line names that IP and kind, the program RESULT is FAIL;
 *           +EXP_FB=<n>: fallback calls allowed (hang: later calls of the disabled IP)
 *   other   no COH, SKIP, kernel_error, MSUM errors, INIT rc != 0; CYCLES closed form
 *           mismatches (hal_dpi.c) = 0; no memory beat outside the arena; program RESULT PASS
 *   stall   +PROF != 0 (memory stall and random latency): CYCLES >= closed form (CYC_LOW = 0)
 *           instead of equality, every RD_STALL / WR_STALL <= its CYCLES (ST_BAD = 0); a
 *           "SYSTB STALL" line per slot with the sums; R stalls of the HP3 memory model (vec
 *           port, tb_sys_fwd.sv sv_mem_rstall) imply a vec RD_STALL sum > 0 (VE_RDST)
 * Output: every program line in the transcript and in sys.log, then "SYSTB ..." summary lines.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "systb.h"

extern void sv_puts(const char *s);
extern int sys_prog_main(void);
extern const char *hal_env(const char *key);
extern long long sv_mem_rstall(int k);

static FILE *lf;
static struct {
  int sys_lines, sys_ok;
  char build[4];
  long checks, check_pass, tok, hash, kmis, coh, fb, iperr;
  long iperr_lines, iperr_match;
  long coh_lines, skip_lines, kerr, msum_err, init_bad, result_pass, result_lines;
  char sys_why[160];
} S;

void tb_print(const char *l) {
  sv_puts(l);
  if (lf) {
    fputs(l, lf);
    fputc('\n', lf);
  }
}

/* value of " name=" in line l (copied into v), 0 if absent */
static int fld(const char *l, const char *name, char *v, size_t n) {
  char key[40];
  const char *p;
  size_t i = 0;
  snprintf(key, sizeof(key), " %s=", name);
  p = strstr(l, key);
  if (!p) return 0;
  p += strlen(key);
  while (*p && *p != ' ' && i + 1 < n) v[i++] = *p++;
  v[i] = 0;
  return 1;
}
static long fnum(const char *l, const char *name) {
  char v[40];
  return fld(l, name, v, sizeof(v)) ? strtol(v, NULL, 0) : -1;
}
static int starts(const char *l, const char *k) {
  size_t n = strlen(k);
  return !strncmp(l, k, n) && (l[n] == ' ' || l[n] == 0);
}

/* system.md 1.7 slot table (default parameters of the two builds) */
static void sys_check(const char *l) {
  const char *eb = hal_env("EXP_BUILD");
  struct {
    const char *k;
    unsigned long a, p;
  } t[] = {{"id_ga", 0x47410001ul, 0},          {"id_pi", 0, 0x50490001ul},
           {"id_at", 0x41540001ul, 0x41540001ul}, {"id_ve", 0x56450001ul, 0x56450001ul},
           {"cfg_ga", 0x04003164ul, 0},           {"cfg_pi", 0, 0x04004464ul},
           {"cfg2_pi", 0, 0x00201000ul},          {"cfg_at", 0x02003964ul, 0x02003264ul},
           {"cfg2_at", 0x00000040ul, 0x00050408ul}, {"cfg3_at", 0, 0x0200080Cul},
           {"cfg_ve", 0x04001064ul, 0x04001064ul}, {"other_slots", 0, 0}};
  size_t i;
  int p = eb && eb[0] == 'P';
  S.sys_lines++;
  fld(l, "build", S.build, sizeof(S.build));
  S.sys_ok = eb && S.build[0] == eb[0] && !S.build[1];
  if (eb && !strcmp(eb, "A2")) t[4].a = 0x04003264ul; /* build A2: GA_P 2 */
  if (eb && !strcmp(eb, "PD")) {                      /* build PD: AT_KV_SRC 1 */
    t[7].p = 0x02003A64ul;
    t[8].p = 0x00000008ul;
    t[9].p = 0;
  }
  if (!S.sys_ok) snprintf(S.sys_why, sizeof(S.sys_why), "build %s expected %s", S.build, eb ? eb : "?");
  for (i = 0; i < sizeof(t) / sizeof(t[0]); i++) {
    unsigned long want = p ? t[i].p : t[i].a, got = (unsigned long)fnum(l, t[i].k);
    if (got != want) {
      if (S.sys_ok)
        snprintf(S.sys_why, sizeof(S.sys_why), "%s 0x%08lx expected 0x%08lx", t[i].k, got, want);
      S.sys_ok = 0;
    }
  }
}

void tb_line(const char *l) {
  const char *ei = hal_env("EXP_IPERR_IP"), *ek = hal_env("EXP_IPERR_KIND");
  char v[40];
  tb_print(l);
  tb_vt_line(l);
  if (starts(l, "SYS")) sys_check(l);
  else if (starts(l, "CHECK")) {
    S.checks++;
    S.tok += fnum(l, "tok_mis");
    S.hash += fnum(l, "hash_mis");
    S.kmis += fnum(l, "kmis");
    S.coh += fnum(l, "coh");
    S.fb += fnum(l, "fb");
    S.iperr += fnum(l, "iperr");
    if (fld(l, "result", v, sizeof(v)) && !strcmp(v, "PASS")) S.check_pass++;
  } else if (starts(l, "IPERR")) {
    char ip[16], kind[16];
    S.iperr_lines++;
    if (fld(l, "ip", ip, sizeof(ip)) && fld(l, "kind", kind, sizeof(kind)) && ei && ek && !strcmp(ip, ei) &&
        !strcmp(kind, ek))
      S.iperr_match++;
  } else if (starts(l, "COH")) S.coh_lines++;
  else if (starts(l, "SKIP")) S.skip_lines++;
  else if (starts(l, "RUN") && fld(l, "status", v, sizeof(v))) S.kerr++;
  else if (starts(l, "MSUM") && fnum(l, "errors") != 0) S.msum_err++;
  else if (starts(l, "INIT") && fld(l, "rc", v, sizeof(v)) && strcmp(v, "0")) S.init_bad++;
  else if (starts(l, "HAL")) S.msum_err++;
  else if (starts(l, "RESULT")) {
    S.result_lines++;
    if (fld(l, "result", v, sizeof(v)) && !strcmp(v, "PASS")) S.result_pass++;
  }
}

static int nfail;
static void req(int ok, const char *what) {
  char b[220];
  if (ok) return;
  nfail++;
  snprintf(b, sizeof(b), "SYSTB FAIL %s", what);
  tb_print(b);
}

int sys_tb_main(int *rc) {
  long exp_checks, exp_iperr, exp_fb;
  long long hp3_rst = -1;
  char b[400];
  memset(&S, 0, sizeof(S));
  memset(&TB, 0, sizeof(TB));
  TB.prog_rc = -1;
  nfail = 0;
  lf = fopen("sys.log", "w");
  exp_checks = tb_env_l("EXP_CHECKS", -1);
  exp_iperr = tb_env_l("EXP_IPERR", 0);
  exp_fb = tb_env_l("EXP_FB", 0);
  sys_prog_main();
  tb_vt_close();
  req(TB.bad_cfg == 0, "testbench plusargs (TB_IPFAULT)");
  req(S.sys_lines == 1 && S.sys_ok, S.sys_lines == 1 ? S.sys_why : "SYS line missing");
  req(exp_checks > 0 && S.checks == exp_checks, "number of CHECK lines");
  req(S.tok == 0 && S.hash == 0, "token / logits hash mismatch (CHECK tok_mis, hash_mis)");
  req(S.kmis == 0, "run K kernel compare mismatch (CHECK kmis)");
  req(S.coh == 0 && S.coh_lines == 0, "cache coherence error (COH)");
  req(S.skip_lines == 0, "SKIP (mask not available in this build)");
  req(S.kerr == 0 && S.msum_err == 0, "kernel_error / setup error");
  req(TB.cyc_mis == 0, "CYCLES differ from the closed form (CYC_MIS)");
  req(TB.cyc_low == 0, "CYCLES below the stall-free closed form (CYC_LOW)");
  req(TB.st_bad == 0, "RD_STALL / WR_STALL larger than CYCLES (ST_BAD)");
  if (TB.prof) {
    hp3_rst = sv_mem_rstall(3);
    req(hp3_rst == 0 || TB.rd_st[3] > 0, "HP3 R stalled but vec RD_STALL sum 0 (VE_RDST)");
  }
  req(TB.beats_bad == 0, "AXI beat outside the arena");
  req(S.fb <= exp_fb, "fallback calls (CHECK fb)");
  if (exp_iperr == 0) {
    req(S.iperr == 0 && S.iperr_lines == 0, "IPERR");
    req(S.init_bad == 0, "INIT rc");
    req(S.check_pass == S.checks, "CHECK result FAIL");
    req(S.result_lines == 1 && S.result_pass == 1 && TB.prog_rc == 0, "program RESULT");
  } else {
    req(TB.inj_done == 1, "fault injection did not happen");
    req(S.iperr == exp_iperr, "IPERR count differs from the injected faults");
    req(S.iperr_lines == S.iperr_match && S.iperr_lines == (exp_iperr < 16 ? exp_iperr : 16),
        "IPERR lines differ from the injected IP / kind");
    req(S.result_lines == 1 && S.result_pass == 0 && TB.prog_rc == 1, "program RESULT must be FAIL");
  }
  snprintf(b, sizeof(b),
           "SYSTB build=%s checks=%ld pass=%ld tok_mis=%ld hash_mis=%ld kmis=%ld coh=%ld fb=%ld iperr=%ld "
           "iperr_lines=%ld axil_rd=%ld axil_wr=%ld starts=%ld beats_rd=%ld beats_wr=%ld cyc_reads=%ld "
           "cyc_checked=%ld cyc_mis=%ld inj=%ld prog_rc=%d",
           S.build, S.checks, S.check_pass, S.tok, S.hash, S.kmis, S.coh, S.fb, S.iperr, S.iperr_lines,
           TB.n_rd, TB.n_wr, TB.n_start, TB.beats_rd, TB.beats_wr, TB.cyc_reads, TB.cyc_checked, TB.cyc_mis,
           TB.inj_done, TB.prog_rc);
  tb_print(b);
  {
    int s;
    for (s = 0; s < 4; s++) {
      snprintf(b, sizeof(b),
               "SYSTB STALL prof=%d slot=%d ops=%ld cycles=%lld rd_stall=%lld wr_stall=%lld "
               "over_form=%lld cyc_low=%ld st_bad=%ld st_reads=%ld hp3_rstall=%lld",
               TB.prof, s, TB.cyc_ops[s], TB.cyc_sum[s], TB.rd_st[s], TB.wr_st[s], TB.cyc_excess[s],
               TB.cyc_low, TB.st_bad, TB.st_reads, hp3_rst);
      tb_print(b);
    }
  }
  snprintf(b, sizeof(b), "SYSTB RESULT %s fails=%d", nfail ? "FAIL" : "PASS", nfail);
  tb_print(b);
  if (lf) fclose(lf);
  lf = NULL;
  *rc = nfail;
  return 0;
}
