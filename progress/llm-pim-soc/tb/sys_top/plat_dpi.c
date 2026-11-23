/*
 * RTL system testbench implementation of plat.h (fpga/sw/src/plat.h, S5-3). Replaces
 * plat_host.c (PC) and plat_xil.c (board) for the system program inside the simulator:
 *   time     simulation cycles of the 100 MHz testbench clock (exported sv_cycles): one tick
 *            = one PL cycle, plat_tps = 100,000,000. ARM-side work (k_exec, cache model, log)
 *            takes no simulation time, so only PL and AXI-Lite time is seen.
 *   console  lines go to sys_tb.c (transcript, file sys.log, checks)
 *   DDR images  +DDR_CK=<file> +DDR_TK=<file> (relative to the run directory) at DDR_CK_ADDR /
 *            DDR_TK_ADDR (the 15M checkpoint and tokenizer; the board loads them over JTAG)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "bcfg.h"
#include "hal.h"
#include "out.h"
#include "plat.h"
#include "systb.h"

extern long long sv_cycles(void);

static char lb[1024];
static size_t ln;
static struct {
  uint32_t addr;
  void *p;
  size_t n;
} img[2];
static void *arena;

static void *load(const char *path, size_t *n) {
  FILE *f = fopen(path, "rb");
  long len;
  void *p;
  *n = 0;
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  len = ftell(f);
  fseek(f, 0, SEEK_SET);
  p = len > 0 ? malloc((size_t)len + 64) : NULL;
  if (p && fread(p, 1, (size_t)len, f) != (size_t)len) {
    free(p);
    p = NULL;
  }
  fclose(f);
  if (p) *n = (size_t)len;
  return p;
}

void plat_init(void) {
  const char *k[2] = {"DDR_CK", "DDR_TK"};
  uint32_t a[2] = {DDR_CK_ADDR, DDR_TK_ADDR};
  int i;
  for (i = 0; i < 2; i++) {
    const char *f = hal_env(k[i]);
    img[i].addr = a[i];
    img[i].p = f ? load(f, &img[i].n) : NULL;
  }
}

const char *plat_name(void) { return "rtl_sim"; }
uint64_t plat_now(void) { return (uint64_t)sv_cycles(); }
uint64_t plat_tps(void) { return 100000000u; }
uint32_t plat_cyc(void) { return (uint32_t)plat_now(); }

void plat_putc(int c) {
  if (c == '\r') return;
  if (c == '\n' || ln + 1 >= sizeof(lb)) {
    lb[ln] = 0;
    tb_line(lb);
    ln = 0;
    if (c == '\n') return;
  }
  lb[ln++] = (char)c;
}

void plat_cache_flush(void) {}

int plat_info(void) {
  o_key("PLAT");
  o_s("name", "rtl_sim");
  o_s("timer", "sim_cycle_100mhz");
  o_u("ddr_images", (uint64_t)((img[0].p != NULL) + (img[1].p != NULL)));
  o_end();
  return 0;
}

const void *plat_ddr(uint32_t addr, uint32_t len) {
  int i;
  for (i = 0; i < 2; i++)
    if (img[i].p && img[i].addr == addr) return img[i].n >= len ? img[i].p : NULL;
  return NULL;
}

void *plat_arena(size_t need, size_t *cap) {
  free(arena);
  arena = malloc(need);
  *cap = arena ? need : 0;
  return arena;
}

uint32_t plat_prog_top(void) { return 0; }

/* the program ends by returning from its main; the code is kept for the testbench verdict */
void plat_exit(int rc) {
  if (ln) plat_putc('\n');
  TB.prog_rc = rc;
}
