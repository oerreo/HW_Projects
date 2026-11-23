/*
 * Host (PC) implementation of hal.h (S5-1, system.md 3.1): the IP register models of
 * ipm_*.c behind the 16 slots of the L4 crossbar. The cache model and the DDR image that the
 * models read and write (hal_arena, hal_pa, hal_flush/inval/flush_all, hal_arm_rd/wr,
 * mem_rd/mem_wr) are in hal_cache.c (shared with the RTL system testbench, S5-3).
 *
 * Environment: SX_BUILD (A | P | 0), SX_VE_NMAX, SX_AT_HSMAX, SX_IPFAULT (rdresp | hang),
 * SX_IPFAULT_SLOT (0..3, default any), SX_IPFAULT_OP (n-th accepted op, default 1), SX_GA_P
 * (gemv_acc slices of build A, default 1),
 * SX_CYCTRACE (file: one line "slot ctrl cycles" per CYCLES read, for the RTL comparison).
 */
#define _POSIX_C_SOURCE 200112L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "bcfg.h"
#include "hal.h"
#include "ipm.h"
#include "ipregs.h"

static const ipm_t *slot_m[SYS_NSLOT];
static int fault_kind, fault_slot = -1;
static long fault_op = 1, fault_cnt[SYS_NSLOT];

ipcfg_t IPC;

static long env_l(const char *k, long d) {
  const char *s = getenv(k);
  return s ? strtol(s, NULL, 0) : d;
}

int hal_init(void) {
  const char *b = getenv("SX_BUILD"), *f = getenv("SX_IPFAULT");
  int k;
  memset(&IPC, 0, sizeof(IPC));
  IPC.fclk = 100;
  if (!b) b = "A";
  memset(slot_m, 0, sizeof(slot_m));
  if (b[0] == 'A') { /* system.md 1.2 build A */
    IPC.ga_p = (int)env_l("SX_GA_P", 1); /* 2: build A2 (CYCLES estimate comparison) */
    IPC.ga_nmax = 1024;
    IPC.at_hpar = 1;
    IPC.at_kvsrc = 1;
    IPC.at_hsmax = 64;
    IPC.at_tmax = 512;
    slot_m[SLOT_GA] = &IPM_GA;
  } else if (b[0] == 'P') { /* build P */
    IPC.pi_nb = 4;
    IPC.pi_depth = 4096;
    IPC.pi_cmdd = 32;
    IPC.pi_nmax = 1024;
    IPC.at_hpar = 2;
    IPC.at_kvsrc = 0;
    IPC.at_hsmax = 8;
    IPC.at_tmax = 512;
    IPC.at_nkv = 4;
    IPC.at_nl = 5;
    IPC.at_kw = 12;
    IPC.at_vw = 8;
    slot_m[SLOT_PI] = &IPM_PI;
  }
  if (b[0] == 'A' || b[0] == 'P') {
    IPC.ve_nmax = (int)env_l("SX_VE_NMAX", 1024);
    IPC.ve_idxw = 16;
    IPC.at_hsmax = (int)env_l("SX_AT_HSMAX", IPC.at_hsmax);
    slot_m[SLOT_AT] = &IPM_AT;
    slot_m[SLOT_VE] = &IPM_VE;
  }
  for (k = 0; k < SYS_NSLOT; k++)
    if (slot_m[k] && slot_m[k]->init()) return 1;
  fault_kind = f ? (!strcmp(f, "rdresp") ? 1 : !strcmp(f, "hang") ? 2 : 0) : 0;
  fault_slot = (int)env_l("SX_IPFAULT_SLOT", -1);
  fault_op = env_l("SX_IPFAULT_OP", 1);
  return 0;
}

const char *hal_name(void) { return "host_model"; }
const char *hal_env(const char *key) { return getenv(key); }

int ipm_fault(int slot) {
  static long any;
  long c;
  if (!fault_kind || (fault_slot >= 0 && slot != fault_slot)) return 0;
  c = fault_slot >= 0 ? ++fault_cnt[slot] : ++any;
  return c == fault_op ? fault_kind : 0;
}

/* optional CYCLES trace (SX_CYCTRACE): "slot ctrl cycles" per read of CYCLES, ctrl = the last
   start written to the slot; compared with the same trace of the RTL system testbench */
static FILE *ctr;
static int ctr_on = -1;
static uint32_t last_ctrl[SYS_NSLOT];

uint32_t hal_rd(int slot, uint32_t off) {
  uint32_t v;
  if (slot < 0 || slot >= SYS_NSLOT || !slot_m[slot] || off >= SYS_SLOT_SZ) return 0;
  v = slot_m[slot]->rd(off & ~3u);
  if ((off & ~3u) == R_CYCLES) {
    if (ctr_on < 0) {
      const char *f = getenv("SX_CYCTRACE");
      ctr = f ? fopen(f, "w") : NULL;
      ctr_on = ctr != NULL;
    }
    if (ctr_on) fprintf(ctr, "%d %x %u\n", slot, (unsigned)last_ctrl[slot], (unsigned)v);
  }
  return v;
}

void hal_wr(int slot, uint32_t off, uint32_t v) {
  if (slot < 0 || slot >= SYS_NSLOT || !slot_m[slot] || off >= SYS_SLOT_SZ) return;
  if ((off & ~3u) == R_CTRL && (v & 1u)) last_ctrl[slot] = v;
  slot_m[slot]->wr(off & ~3u, v);
}

void hal_dsb(void) {}

/* ---------------- model helpers ---------------- */
void *ipm_scr(int i, size_t n) {
  static void *b[8];
  static size_t sz[8];
  if (i < 0 || i >= 8) return NULL;
  if (n > sz[i]) {
    free(b[i]);
    b[i] = malloc(n + 64u);
    sz[i] = b[i] ? n : 0;
  }
  return b[i];
}

int ipm_nburst(uint32_t addr, uint32_t beats, uint32_t *last) {
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
