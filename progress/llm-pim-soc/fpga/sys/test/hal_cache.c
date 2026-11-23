/*
 * Cache model and shared DDR image of the system program (S5-1, system.md 3.1), used by the
 * host HAL (hal_host.c: C register models of the IPs) and by the RTL system testbench HAL
 * (tb/sys_top/hal_dpi.c: the AXI memory models of the HP ports read and write the same DDR
 * image beat by beat). Split out of hal_host.c in S5-3 without a change of behaviour.
 *
 * Three images of the model arena, byte for byte, and a flag array:
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
 */
#define _POSIX_C_SOURCE 200112L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "bcfg.h"
#include "hal.h"
#include "ipm.h"

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

static void scpy(char *d, const char *s, size_t n) {
  size_t i;
  for (i = 0; i + 1 < n && s[i]; i++) d[i] = s[i];
  d[i] = 0;
}

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

/* testbench access to the DDR image without coherence checks (RTL system TB: AXI memory model
   beats are checked through mem_rd / mem_wr; this is for the TB's own reads) */
const uint8_t *mem_peek(uint32_t pa, uint32_t n) {
  size_t off;
  return pa_ok(pa, n, &off) ? ddr + off : NULL;
}
