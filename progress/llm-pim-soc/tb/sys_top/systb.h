/*
 * RTL system testbench, C side (S5-3): state shared by hal_dpi.c, plat_dpi.c and sys_tb.c.
 */
#ifndef SYSTB_H
#define SYSTB_H
#include <stdint.h>

typedef struct {
  /* bus traffic of the program */
  long n_rd, n_wr, n_start;
  long beats_rd, beats_wr, beats_bad;
  /* CYCLES reads: all, compared with a closed form, different */
  long cyc_reads, cyc_checked, cyc_mis;
  /* IP fault injection: starts that switched the fault on */
  long inj_done;
  long bad_cfg;
  int prog_rc;
} systb_t;
extern systb_t TB;

/* one finished log line of the program (plat_dpi.c -> sys_tb.c) */
void tb_line(const char *l);
/* a testbench message to the simulator transcript and the log file */
void tb_print(const char *l);
long tb_env_l(const char *key, long d);

#endif
