/*
 * RTL system testbench implementation of hal.h (S5-3, docs/spec/system.md 3.2). The system
 * program of fpga/sys/sw (executor, drivers, init) runs unchanged inside the imported DPI-C
 * context task sys_tb_main (sys_tb.c) and drives the L4 top (sys_a_top / sys_p_top) of
 * tb/sys_top/tb_sys_fwd.sv:
 *   hal_rd / hal_wr  exported SV tasks sv_axil_rd / sv_axil_wr: one AXI4-Lite transaction of
 *                    tb/common/axil_bfm.sv at 0x0000 + slot 4 KiB + off (the 16-bit window of
 *                    the crossbar; GP0 base 0x43C0_0000 on the board). Simulation time passes.
 *   memory           the cache model of fpga/sys/test/hal_cache.c (hal_arena, hal_pa,
 *                    flush/invalidate, the S5-1 coherence checks); its DDR image is the store of
 *                    the AXI memory models of all HP ports (axi_mem_slave EXT_STORE = 1):
 *                    axm_rd64 / axm_wr64 below are called beat by beat and go through mem_rd /
 *                    mem_wr, so the IP-side coherence checks (ip_rd_dirty, ip_wr_dirty) see
 *                    every RTL beat.
 *   hal_env          plusargs (+KEY=value in the vsim argument file), the same keys as the host
 *                    test environment (SX_LIST, SX_RUNS, SX_STEPS, SX_MODELS, SX_FAULT); SX_FAULT
 *                    may also come from the environment (mutation runs).
 * Testbench additions (not part of hal.h):
 *   CYCLES check     every read of CYCLES by a driver (runs P, PIM LDW) is compared with the
 *                    closed form of the IP document where one exists (gemv_acc.md 5 for P = 1,
 *                    vec.md 6.2), computed from the registers the driver wrote; other ops
 *                    (pim runs, attention ATTN / KVW: documents give estimates only) are only
 *                    traced. Trace file +CYCTRACE=<file> (default cyc.txt): "slot ctrl cycles" per
 *                    read, the format of the host model trace (fpga/sys/test/hal_host.c
 *                    SX_CYCTRACE); tb/sys_top/cyc_cmp.py compares the two.
 *                    Memory stall runs (+PROF != 0, the stall profile of tb_sys_fwd.sv): the
 *                    closed forms assume latency 1 and no stall, so there they are lower bounds
 *                    (CYC_LOW if CYCLES < form); every RD_STALL / WR_STALL read after a CYCLES
 *                    read of the same slot must be <= that CYCLES (ST_BAD). Per slot the sums of
 *                    CYCLES, RD_STALL, WR_STALL and CYCLES - form are reported (sys_tb.c).
 *   IP fault         +TB_IPFAULT=rdresp|wrresp|hang +TB_IPFAULT_SLOT=<slot> +TB_IPFAULT_OP=<n>:
 *                    at the n-th start of that IP the memory models of its HP ports answer
 *                    with SLVERR (until the driver sees busy = 0) or stop answering (hang).
 *   viewer trace     +VTRACE=<file> (optional, S4-8 viewer docs/viewer/tools): one event per
 *                    line, tick = sv_cycles (100 MHz testbench clock), ax = cumulative AXI-Lite
 *                    reads and writes of that slot (this access included), b = cumulative
 *                    R and W beats of the memory models HP0..HP3 (8 numbers, rd wr per port):
 *                      K tick pos name                    hal_ctx: every kernel call (ARM or IP)
 *                      S tick slot ctrl axr axw b.. r40..r7C   CTRL write with GO (b before the
 *                                                         write, r = 16 descriptor registers)
 *                      E tick slot status axr axw b..     first STATUS read with busy = 0
 *                      R tick slot off val axr axw        read of ERR, CYCLES, RD_STALL, WR_STALL
 *                      P tick cmd0 cmd1 cmd2 cmd3         pim CMD_PUSH
 *                      L <program log line>               SYS, MODEL, KSPLIT, RUN, CHECK lines
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "bcfg.h"
#include "hal.h"
#include "ipm.h"
#include "ipregs.h"
#include "systb.h"

/* exported SV tasks and functions (tb_sys_fwd.sv) */
extern int sv_axil_wr(unsigned int a, unsigned int d);
extern int sv_axil_rd(unsigned int a, unsigned int *d);
extern int sv_plusarg(const char *k, const char **v);
extern void sv_inj(int slot, int kind, int on);
extern long long sv_mem_beats(int k, int w);
extern long long sv_cycles(void);

systb_t TB;

static uint32_t rg[SYS_NSLOT][32];  /* last value written to offsets 0x00..0x7C */
static uint32_t op_rg[SYS_NSLOT][32]; /* registers at the last start */
static uint32_t cfgv[SYS_NSLOT];    /* CONFIG read by sys_detect */
static uint32_t last_cyc[SYS_NSLOT]; /* last CYCLES read per slot */
static int have_cyc[SYS_NSLOT];
static int busy_op[SYS_NSLOT];      /* a start was written, busy = 0 not yet seen */
static FILE *ctr;
static int inj_kind, inj_slot = -1, inj_on, inj_err_rd;
static long inj_op = 1, inj_cnt;

/* ---------------- viewer trace (+VTRACE) ---------------- */
static FILE *vtr;
static long ax_rd[SYS_NSLOT], ax_wr[SYS_NSLOT];

static void vt_beats(void) {
  int k;
  for (k = 0; k < 4; k++) fprintf(vtr, " %lld %lld", sv_mem_beats(k, 0), sv_mem_beats(k, 1));
}

void tb_vt_ctx(const char *k, int pos) {
  if (vtr) fprintf(vtr, "K %lld %d %s\n", sv_cycles(), pos, k);
}

void tb_vt_line(const char *l) {
  static const char *const keep[] = {"SYS ", "MODEL ", "KSPLIT ", "RUN ", "CHECK "};
  size_t i;
  if (!vtr) return;
  for (i = 0; i < sizeof(keep) / sizeof(keep[0]); i++)
    if (!strncmp(l, keep[i], strlen(keep[i]))) {
      fprintf(vtr, "L %s\n", l);
      return;
    }
}

void tb_vt_close(void) {
  if (vtr) fclose(vtr);
  vtr = NULL;
}

/* ---------------- plusargs ---------------- */
static struct {
  char k[32];
  char *v;
} envc[48];
static int nenv;

const char *hal_env(const char *key) {
  int i;
  const char *v = NULL;
  for (i = 0; i < nenv; i++)
    if (!strcmp(envc[i].k, key)) return envc[i].v;
  if (nenv >= 48 || strlen(key) >= sizeof(envc[0].k)) return NULL;
  strcpy(envc[nenv].k, key);
  envc[nenv].v = NULL;
  if (!sv_plusarg(key, &v)) v = NULL;
  if (!v && !strcmp(key, "SX_FAULT"))
    v = getenv("SX_FAULT"); /* mutation runs: fault hook of the program from the environment */
  if (v) {
    envc[nenv].v = malloc(strlen(v) + 1);
    if (envc[nenv].v) strcpy(envc[nenv].v, v);
  }
  return envc[nenv++].v;
}

long tb_env_l(const char *key, long d) {
  const char *s = hal_env(key);
  return s ? strtol(s, NULL, 0) : d;
}

int hal_init(void) {
  const char *f = hal_env("TB_IPFAULT");
  memset(rg, 0, sizeof(rg));
  inj_kind = !f ? 0 : !strcmp(f, "rdresp") ? 1 : !strcmp(f, "wrresp") ? 2 : !strcmp(f, "hang") ? 3 : -1;
  if (inj_kind < 0) {
    TB.bad_cfg++;
    inj_kind = 0;
  }
  inj_slot = (int)tb_env_l("TB_IPFAULT_SLOT", -1);
  inj_op = tb_env_l("TB_IPFAULT_OP", 1);
  TB.prof = (int)tb_env_l("PROF", 0);
  {
    const char *cf = hal_env("CYCTRACE");
    ctr = fopen(cf ? cf : "cyc.txt", "w");
  }
  {
    const char *vf = hal_env("VTRACE");
    vtr = vf ? fopen(vf, "w") : NULL;
  }
  return 0;
}

const char *hal_name(void) { return "rtl_dpi"; }
void hal_dsb(void) {}

/* ---------------- CYCLES closed forms ---------------- */
static uint32_t cdiv(uint32_t a, uint32_t b) { return (a + b - 1u) / b; }
/* AXI burst split (16 beats, no 4 KiB crossing): number of bursts and beats of the last */
static int nburst(uint32_t addr, uint32_t beats, uint32_t *last) {
  int nb = 0;
  uint32_t l = 0;
  while (beats) {
    uint32_t to4k = (0x1000u - (addr & 0xFFFu)) / 8u;
    l = beats < 16u ? beats : 16u;
    if (to4k && l > to4k) l = to4k;
    addr += 8u * l;
    beats -= l;
    nb++;
  }
  if (last) *last = l;
  return nb;
}
#define R(s, off) (op_rg[s][(off) / 4u])

/* expected CYCLES of the last op of slot s, or -1 if the documents give no closed form */
static long cyc_exp(int s, uint32_t ctrl, const char **cls) {
  uint32_t op = (ctrl >> 4) & 0xFu;
  *cls = "est";
  if (s == SLOT_GA && op == GA_OP_GEMV && GA_CFG_P(cfgv[SLOT_GA]) == 1u) {
    /* gemv_acc.md 5 (P = 1, latency 1, no stall, last y burst not blocked) */
    uint32_t n = R(s, GA_N), rows = R(s, GA_ROWS), nb = cdiv(n, 8u), last = 0, xd;
    int mx = nburst(R(s, GA_X_ADDR), nb, NULL);
    xd = (uint32_t)mx + 1u > nb ? (uint32_t)mx + 1u - nb : 0u;
    *cls = "ga";
    if (R(s, GA_FLAGS) & GA_F_YEN) {
      nburst(R(s, GA_Y_ADDR), cdiv(rows, 2u), &last);
      return (long)(nb + rows * (1u + nb) + 19u + xd + last + 9u);
    }
    return (long)(nb + rows * (1u + nb) + 15u + xd + 9u);
  }
  if (s == SLOT_VE && op >= VE_OP_RMS && op <= VE_OP_AMAX) {
    /* vec.md 6.1 core forms, 6.2 top form 1 + C + 11 + max(L_last, 2); ARGMAX n + 15 */
    uint32_t n = R(s, VE_N), qmax = R(s, VE_FMT) & 0xFFFFu, qb, C, last = 0;
    const uint8_t *sc;
    int32_t m = 1;
    *cls = "ve";
    if (op == VE_OP_AMAX) return (long)n + 15;
    qb = (op == VE_OP_ACTQ && qmax != 127u) ? 2u : 1u;
    C = op == VE_OP_RMS ? 4u * n + 87u : op == VE_OP_SWI ? 3u * n + 67u : 2u * n + 59u;
    sc = mem_peek(R(s, VE_SCL), 8u); /* zero output (scale m 0): the second column of 6.1 */
    if (sc) memcpy(&m, sc, 4);
    if (m == 0) C -= 53u;
    nburst(R(s, VE_OUT), cdiv(n * qb, 8u), &last);
    return (long)(1u + C + 11u + (last > 2u ? last : 2u));
  }
  if (s == SLOT_PI) *cls = "pi";
  if (s == SLOT_AT) *cls = op == AT_OP_KVW ? "kvw" : "at";
  return -1;
}

static void cyc_read(int s, uint32_t v) {
  const char *cls;
  uint32_t ctrl = op_rg[s][R_CTRL / 4u];
  long e = cyc_exp(s, ctrl, &cls);
  if (ctr) fprintf(ctr, "%d %x %u\n", s, (unsigned)ctrl, (unsigned)v);
  TB.cyc_reads++;
  last_cyc[s] = v;
  have_cyc[s] = 1;
  if (s < 4) {
    TB.cyc_ops[s]++;
    TB.cyc_sum[s] += v;
  }
  if (e < 0) return;
  TB.cyc_checked++;
  if (TB.prof) { /* stall run: the latency-1 closed form is a lower bound */
    if (s < 4) TB.cyc_excess[s] += (long)v - e;
    if ((long)v < e) {
      TB.cyc_low++;
      if (TB.cyc_low <= 10) {
        char b[200];
        snprintf(b, sizeof(b), "SYSTB CYC_LOW cls=%s slot=%d ctrl=0x%x cycles=%u formula=%ld", cls, s,
                 (unsigned)ctrl, (unsigned)v, e);
        tb_print(b);
      }
    }
    return;
  }
  if ((long)v != e) {
    TB.cyc_mis++;
    if (TB.cyc_mis <= 10) {
      char b[200];
      snprintf(b, sizeof(b), "SYSTB CYC_MIS cls=%s slot=%d ctrl=0x%x cycles=%u formula=%ld", cls, s,
               (unsigned)ctrl, (unsigned)v, e);
      tb_print(b);
    }
  }
}

/* ---------------- register access ---------------- */
uint32_t hal_rd(int slot, uint32_t off) {
  unsigned int d = 0;
  if (slot < 0 || slot >= SYS_NSLOT || off >= SYS_SLOT_SZ) return 0;
  off &= ~3u;
  sv_axil_rd(((unsigned)slot << 12) | off, &d);
  TB.n_rd++;
  ax_rd[slot]++;
  if (vtr && (off == R_ERR || off == R_CYCLES || off == R_RD_STALL || off == R_WR_STALL))
    fprintf(vtr, "R %lld %d %x %u %ld %ld\n", sv_cycles(), slot, (unsigned)off, d, ax_rd[slot], ax_wr[slot]);
  if (off == R_CONFIG) cfgv[slot] = d;
  if (off == R_STATUS && busy_op[slot] && !(d & ST_BUSY)) {
    if (vtr) {
      fprintf(vtr, "E %lld %d %x %ld %ld", sv_cycles(), slot, d, ax_rd[slot], ax_wr[slot]);
      vt_beats();
      fputc('\n', vtr);
    }
    busy_op[slot] = 0;
    if (inj_on && slot == inj_slot && inj_kind != 3) { /* error window ends with the op */
      char b[120];
      snprintf(b, sizeof(b), "SYSTB INJ_END slot=%d status=0x%x", slot, d);
      tb_print(b);
      sv_inj(slot, inj_kind, 0);
      inj_on = 0;
      inj_err_rd = 1;
    }
  }
  if (off == R_ERR && inj_err_rd && slot == inj_slot) { /* the driver reads ERR after the op */
    char b[120];
    snprintf(b, sizeof(b), "SYSTB INJ_ERR slot=%d err=0x%x", slot, d);
    tb_print(b);
    inj_err_rd = 0;
  }
  if (off == R_CYCLES) cyc_read(slot, d);
  if ((off == R_RD_STALL || off == R_WR_STALL) && have_cyc[slot]) {
    TB.st_reads++;
    if (slot < 4) {
      if (off == R_RD_STALL) TB.rd_st[slot] += d;
      else TB.wr_st[slot] += d;
    }
    if (d > last_cyc[slot]) {
      TB.st_bad++;
      if (TB.st_bad <= 10) {
        char b[160];
        snprintf(b, sizeof(b), "SYSTB ST_BAD slot=%d %s=%u > cycles=%u", slot,
                 off == R_RD_STALL ? "rd_stall" : "wr_stall", d, last_cyc[slot]);
        tb_print(b);
      }
    }
  }
  return d;
}

void hal_wr(int slot, uint32_t off, uint32_t v) {
  if (slot < 0 || slot >= SYS_NSLOT || off >= SYS_SLOT_SZ) return;
  off &= ~3u;
  if (off == R_CTRL && (v & 1u) && slot < SLOT_N) {
    if (inj_kind && slot == inj_slot && ++inj_cnt == inj_op) {
      sv_inj(slot, inj_kind, 1);
      inj_on = 1;
      TB.inj_done++;
    }
  }
  if (vtr && off == R_CTRL && (v & 1u)) { /* beats before the start (the IP is idle) */
    int i;
    fprintf(vtr, "S %lld %d %x %ld %ld", sv_cycles(), slot, (unsigned)v, ax_rd[slot], ax_wr[slot] + 1);
    vt_beats();
    for (i = 0x40 / 4; i < 0x80 / 4; i++) fprintf(vtr, " %x", (unsigned)rg[slot][i]);
    fputc('\n', vtr);
  }
  sv_axil_wr(((unsigned)slot << 12) | off, v);
  TB.n_wr++;
  ax_wr[slot]++;
  if (off < 0x80u) rg[slot][off / 4u] = v;
  if (vtr && slot == SLOT_PI && off == PI_CMD_PUSH)
    fprintf(vtr, "P %lld %x %x %x %x\n", sv_cycles(), (unsigned)rg[slot][PI_CMD0 / 4u],
            (unsigned)rg[slot][PI_CMD1 / 4u], (unsigned)rg[slot][PI_CMD2 / 4u], (unsigned)rg[slot][PI_CMD3 / 4u]);
  if (off == R_CTRL && (v & 1u)) {
    memcpy(op_rg[slot], rg[slot], sizeof(op_rg[slot]));
    busy_op[slot] = 1;
    TB.n_start++;
  }
}

/* ---------------- AXI memory model store (axi_mem_slave EXT_STORE) ---------------- */
int axm_rd64(unsigned long long a, unsigned long long *d) {
  const uint8_t *p = a < 0x100000000ull && !(a & 7u) ? mem_rd((uint32_t)a, 8u) : NULL;
  TB.beats_rd++;
  if (!p) {
    *d = 0xDEADBEEFDEADBEEFull;
    TB.beats_bad++;
    return 1;
  }
  memcpy(d, p, 8);
  return 0;
}

int axm_wr64(unsigned long long a, unsigned long long d, unsigned int strb) {
  uint8_t *p = a < 0x100000000ull && !(a & 7u) ? mem_wr((uint32_t)a, 8u) : NULL;
  int i;
  TB.beats_wr++;
  if (!p) {
    TB.beats_bad++;
    return 1;
  }
  for (i = 0; i < 8; i++)
    if ((strb >> i) & 1u) p[i] = (uint8_t)(d >> (8 * i));
  return 0;
}
