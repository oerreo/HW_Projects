/*
 * Host (PC) implementation of hal.h (S5-1, system.md 3.1): the IP register models of
 * ipm_*.c behind the 16 slots of the L4 crossbar, and a cache model.
 *
 * Cache model. Three images of the model arena, byte for byte, and a flag array:
 *   cpu  what the program reads and writes through pointers (the arena itself)
 *   ddr  what the IPs read and write (mem_rd / mem_wr)
 *   syn  the value of the byte at its last flush / invalidate (both views agreed)
 *   aw   1: the ARM wrote the byte since then (hal_arm_wr: kernel outputs, driver writes)
 * A byte was written by the ARM since the last sync if aw is set or cpu != syn (writes the
 * program did not declare, e.g. the model build), by an IP if ddr != syn. Every line
 * (32 B) is treated as present in the cache all the time (worst case: speculative fills,
 * evictions at any time), so:
 *   flush(range)  each line: if the ARM wrote any byte, the whole line goes to ddr (IP bytes
 *                 the ARM did not overwrite are lost: "flush_clobber"); then cpu = syn = ddr
 *   inval(range)  each line inside the range: unflushed ARM bytes are discarded
 *                 ("inval_discard"); cpu = syn = ddr. A line only partly inside is flushed
 *                 (assumed BSP behaviour for partial lines, [unverified])
 *   flush_all     flush of every line; losses here are counted as "old" (data of an earlier
 *                 run that no later run reads), not as errors
 * Checks (COH errors): the ARM reads a byte an IP wrote that was not invalidated
 * ("arm_rd_stale"); an IP reads a byte the ARM wrote that was not flushed ("ip_rd_dirty"); an
 * IP writes into a line with unflushed ARM bytes ("ip_wr_dirty", rule 4 of system.md 2.2).
 *
 * Environment: SX_BUILD (A | P | 0), SX_VE_NMAX, SX_AT_HSMAX, SX_IPFAULT (rdresp | hang),
 * SX_IPFAULT_SLOT (0..3, default any), SX_IPFAULT_OP (n-th accepted op, default 1).
 */
#define _POSIX_C_SOURCE 200112L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "bcfg.h"
#include "hal.h"
#include "ipm.h"
#include "ipregs.h"

#define LN 32u
#define PA0 ARENA_ADDR

static uint8_t *cpu, *ddr, *syn, *aw;
static size_t cap;
static hal_coh_t coh;
static char ctxk[24];
static int ctxpos;
static struct {
  size_t off, n;
  char name[16];
} nm[256];
static int nnm;
static const ipm_t *slot_m[SYS_NSLOT];
static int fault_kind, fault_slot = -1;
static long fault_op = 1, fault_cnt[SYS_NSLOT];

ipcfg_t IPC;

static void scpy(char *d, const char *s, size_t n) {
  size_t i;
  for (i = 0; i + 1 < n && s[i]; i++) d[i] = s[i];
  d[i] = 0;
}

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
    IPC.ga_p = 1;
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

uint32_t hal_rd(int slot, uint32_t off) {
  if (slot < 0 || slot >= SYS_NSLOT || !slot_m[slot] || off >= SYS_SLOT_SZ) return 0;
  return slot_m[slot]->rd(off & ~3u);
}

void hal_wr(int slot, uint32_t off, uint32_t v) {
  if (slot < 0 || slot >= SYS_NSLOT || !slot_m[slot] || off >= SYS_SLOT_SZ) return;
  slot_m[slot]->wr(off & ~3u, v);
}

void hal_dsb(void) {}

/* ---------------- arena and the three images ---------------- */
void *hal_arena(size_t need, size_t *capo) {
  void *p = NULL;
  free(cpu);
  free(ddr);
  free(syn);
  free(aw);
  cpu = ddr = syn = aw = NULL;
  cap = (need + 4095u) & ~(size_t)4095u;
  if (posix_memalign(&p, 4096, cap)) p = NULL;
  cpu = p;
  ddr = calloc(cap, 1);
  syn = calloc(cap, 1);
  aw = calloc(cap, 1);
  nnm = 0;
  if (!cpu || !ddr || !syn || !aw) {
    *capo = 0;
    return NULL;
  }
  memset(cpu, 0, cap);
  *capo = cap;
  return cpu;
}

static int in_arena(const void *p, size_t n, size_t *off) {
  const uint8_t *b = (const uint8_t *)p;
  if (!cpu || b < cpu || b >= cpu + cap || n > cap || (size_t)(b - cpu) + n > cap) return 0;
  *off = (size_t)(b - cpu);
  return 1;
}

uint32_t hal_pa(const void *p) {
  size_t off;
  if (!in_arena(p, 1, &off)) return 0xFFFFFFF8u; /* not reachable by the IPs: bus error */
  return (uint32_t)(PA0 + off);
}

void hal_name_range(const void *p, size_t n, const char *name) {
  size_t off;
  if (nnm >= 256 || !in_arena(p, n, &off)) return;
  nm[nnm].off = off;
  nm[nnm].n = n;
  scpy(nm[nnm].name, name, sizeof(nm[nnm].name));
  nnm++;
}

static const char *name_of(size_t off) {
  int i;
  for (i = 0; i < nnm; i++)
    if (off >= nm[i].off && off < nm[i].off + nm[i].n) return nm[i].name;
  return "-";
}

void hal_ctx(const char *k, int pos) {
  scpy(ctxk, k, sizeof(ctxk));
  ctxpos = pos;
}

void hal_coh_get(hal_coh_t *c, int reset) {
  *c = coh;
  if (reset) memset(&coh, 0, sizeof(coh));
}

static void coh_err(const char *kind, size_t off) {
  if (!coh.n) {
    scpy(coh.kind, kind, sizeof(coh.kind));
    scpy(coh.what, name_of(off), sizeof(coh.what));
    scpy(coh.ctx, ctxk, sizeof(coh.ctx));
    coh.pos = ctxpos;
    coh.addr = (uint32_t)(PA0 + off);
  }
  coh.n++;
}

/* ---------------- cache operations ---------------- */
static int armw(size_t i) { return aw[i] || cpu[i] != syn[i]; }
static int line_dirty(size_t lo) {
  size_t i;
  if (memcmp(cpu + lo, syn + lo, LN)) return 1;
  for (i = lo; i < lo + LN; i++)
    if (aw[i]) return 1;
  return 0;
}

static void line_flush(size_t lo, int full) {
  size_t i;
  if (line_dirty(lo)) { /* the ARM wrote: the line is dirty and is written back whole */
    for (i = lo; i < lo + LN; i++)
      if (ddr[i] != syn[i] && !armw(i) && cpu[i] != ddr[i]) {
        if (full) coh.old++;
        else coh_err("flush_clobber", i);
        break;
      }
    memcpy(ddr + lo, cpu + lo, LN);
  }
  memcpy(cpu + lo, ddr + lo, LN);
  memcpy(syn + lo, ddr + lo, LN);
  memset(aw + lo, 0, LN);
}

void hal_flush(const void *p, size_t n) {
  size_t off, lo, hi;
  if (!n || !in_arena(p, n, &off)) return;
  lo = off & ~(size_t)(LN - 1u);
  hi = (off + n + LN - 1u) & ~(size_t)(LN - 1u);
  for (; lo < hi && lo < cap; lo += LN) line_flush(lo, 0);
}

void hal_inval(const void *p, size_t n) {
  size_t off, lo, hi, i;
  if (!n || !in_arena(p, n, &off)) return;
  lo = off & ~(size_t)(LN - 1u);
  hi = (off + n + LN - 1u) & ~(size_t)(LN - 1u);
  for (; lo < hi && lo < cap; lo += LN) {
    if (lo < off || lo + LN > off + n) { /* partial line at a range end */
      line_flush(lo, 0);
      continue;
    }
    for (i = lo; i < lo + LN; i++)
      if (armw(i) && cpu[i] != ddr[i]) {
        coh_err("inval_discard", i);
        break;
      }
    memcpy(cpu + lo, ddr + lo, LN);
    memcpy(syn + lo, ddr + lo, LN);
    memset(aw + lo, 0, LN);
  }
}

void hal_flush_all(void) {
  size_t blk, lo;
  if (!cpu) return;
  for (blk = 0; blk < cap; blk += 4096u) {
    size_t n = cap - blk < 4096u ? cap - blk : 4096u;
    static const uint8_t z[4096];
    if (!memcmp(cpu + blk, syn + blk, n) && !memcmp(ddr + blk, syn + blk, n) && !memcmp(aw + blk, z, n))
      continue;
    for (lo = blk; lo < blk + n; lo += LN) line_flush(lo, 1);
  }
}

/* ---------------- coherence checks ---------------- */
void hal_arm_rd(const void *p, size_t n) {
  size_t off, i;
  if (!n || !in_arena(p, n, &off)) return;
  if (!memcmp(cpu + off, ddr + off, n)) return;
  for (i = off; i < off + n; i++)
    if (cpu[i] != ddr[i] && ddr[i] != syn[i] && !aw[i]) {
      coh_err("arm_rd_stale", i);
      return;
    }
}

void hal_arm_wr(const void *p, size_t n) {
  size_t off;
  if (!n || !in_arena(p, n, &off)) return;
  memset(aw + off, 1, n);
}

static int pa_ok(uint32_t pa, uint32_t n, size_t *off) {
  if (pa < PA0 || (uint64_t)pa + n > (uint64_t)PA0 + cap || !cpu) return 0;
  *off = pa - PA0;
  return 1;
}

const uint8_t *mem_rd(uint32_t pa, uint32_t n) {
  size_t off, i;
  if (!pa_ok(pa, n, &off)) return NULL;
  if (n && memcmp(cpu + off, ddr + off, n))
    for (i = off; i < off + n; i++)
      if (cpu[i] != ddr[i] && armw(i)) {
        coh_err("ip_rd_dirty", i);
        break;
      }
  return ddr + off;
}

uint8_t *mem_wr(uint32_t pa, uint32_t n) {
  size_t off, lo, hi, i;
  if (!pa_ok(pa, n, &off)) return NULL;
  lo = off & ~(size_t)(LN - 1u);
  hi = (off + n + LN - 1u) & ~(size_t)(LN - 1u);
  if (hi > cap) hi = cap;
  if (hi > lo && memcmp(cpu + lo, ddr + lo, hi - lo))
    for (i = lo; i < hi; i++)
      if (cpu[i] != ddr[i] && armw(i)) {
        coh_err("ip_wr_dirty", i);
        break;
      }
  return ddr + off;
}

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
