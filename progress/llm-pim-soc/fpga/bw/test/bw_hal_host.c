/*
 * bw_hal_host.c: host (PC) implementation of bw_hal.h with a SOFTWARE MODEL of the IP's
 * register interface, written from docs/spec/bwtest.md. It is not the RTL: passing the host
 * test only shows that the PS program, its checks and its log format agree with the spec text
 * (the RTL is checked against the spec by tb/bw_top). An op completes inside the CTRL write.
 *
 * Environment (read once): BW_P (1|2, default 2), BW_OUTS (4), BW_MAXB (16),
 * BW_FAULT: 0 none, 1 checksum bit flip, 2 wrong pattern byte, 3 guard byte overwritten,
 * 4 wrong RD_BEATS, 5 ERR bit set after an op, 6 op never finishes (busy forever).
 */
#define _POSIX_C_SOURCE 199309L /* clock_gettime under -std=c99 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "bw_hal.h"
#include "bw_regs.h"

#define MEM_LO 0x10000000u
#define MEM_HI 0x18000000u

static uint8_t *mem;
static uint32_t regs[64];      /* word-indexed register file (0x00 .. 0xFC) */
static uint32_t P_ = 2, OUTS_ = 4, MAXB_ = 16;
static int fault;

static uint32_t env_u(const char *k, uint32_t d) {
  const char *s = getenv(k);
  return s ? (uint32_t)strtoul(s, 0, 0) : d;
}

int bw_hal_init(void) {
  P_ = env_u("BW_P", 2);
  OUTS_ = env_u("BW_OUTS", 4);
  MAXB_ = env_u("BW_MAXB", 16);
  fault = (int)env_u("BW_FAULT", 0);
  mem = calloc(MEM_HI - MEM_LO, 1);
  if (!mem) return 1;
  memset(regs, 0, sizeof regs);
  regs[BW_BURST / 4] = MAXB_;
  regs[BW_OUTS / 4] = OUTS_;
  regs[BW_PORTS / 4] = 1;
  return 0;
}

volatile uint8_t *bw_mem(uint32_t addr) {
  if (addr < MEM_LO || addr >= MEM_HI) {
    fprintf(stderr, "host model: address 0x%08x outside the modelled DDR\n", addr);
    exit(3);
  }
  return mem + (addr - MEM_LO);
}

static void op_run(uint32_t op) {
  uint32_t len = regs[BW_LEN / 4], ports = regs[BW_PORTS / 4], p, k, nb = (len + 7u) / 8u;
  uint32_t cyc = 0;
  for (p = 0; p < P_; p++) {
    uint32_t base = 0x20u + 8u * p;
    memset(&regs[base], 0, 8 * sizeof(uint32_t));
    regs[0x30u + 2u * p] = 0;
    regs[0x31u + 2u * p] = 0;
    if (!((ports >> p) & 1u)) continue;
    if (op & BW_OP_RD) {
      uint32_t a = regs[BW_RD_ADDR(p) / 4];
      uint64_t x = 0, s = 0;
      for (k = 0; k < nb; k++) {
        uint64_t w = 0;
        int b;
        for (b = 7; b >= 0; b--) w = (w << 8) | (8u * k + (uint32_t)b < len ? bw_mem(a + 8u * k + (uint32_t)b)[0] : 0u);
        x ^= w;
        s += w;
      }
      if (fault == 1) x ^= 0x100u;
      regs[base + 0] = (uint32_t)x;
      regs[base + 1] = (uint32_t)(x >> 32);
      regs[base + 2] = (uint32_t)s;
      regs[base + 3] = (uint32_t)(s >> 32);
      regs[base + 4] = nb + 20u;      /* RD_CYC: modelled, not a hardware number */
      regs[base + 6] = 19u;           /* RD_STALL = RD_CYC - 1 - beats */
      regs[0x30u + 2u * p] = fault == 4 ? nb + 1u : nb;
      if (regs[base + 4] > cyc) cyc = regs[base + 4];
    }
    if (op & BW_OP_WR) {
      uint32_t a = regs[BW_WR_ADDR(p) / 4];
      uint64_t d = ((uint64_t)(regs[BW_SEED_HI / 4] ^ p) << 32) | regs[BW_SEED_LO / 4];
      for (k = 0; k < len; k++) {
        if (k && (k % 8u) == 0) d += BW_PAT_INC;
        bw_mem(a + k)[0] = (uint8_t)(d >> (8u * (k % 8u)));
      }
      if (fault == 2 && len > 3) bw_mem(a + len / 2)[0] ^= 1u;
      if (fault == 3) bw_mem(a + len)[0] ^= 0xFFu;
      regs[base + 5] = nb + 30u;
      regs[base + 7] = 0;
      regs[0x31u + 2u * p] = nb;
      if (regs[base + 5] > cyc) cyc = regs[base + 5];
    }
  }
  regs[BW_CYCLES / 4] = cyc;
  regs[BW_OPS / 4]++;
  if (fault == 5) regs[BW_ERR / 4] |= BW_E_RD_RESP;
}

static int busy;

void bw_wr(uint32_t off, uint32_t v) {
  uint32_t w = (off & 0xFFu) / 4u;
  switch (off) {
    case BW_CTRL: {
      uint32_t op = (v >> 4) & 3u, len = regs[BW_LEN / 4], ports = regs[BW_PORTS / 4];
      uint32_t burst = regs[BW_BURST / 4], outs = regs[BW_OUTS / 4], p;
      int ok = 1;
      if (busy) {
        if (v & 1u) regs[BW_ERR / 4] |= BW_E_START_BUSY;
        return;
      }
      regs[BW_STATUS / 4] &= ~BW_ST_DONE;
      if (!(v & 1u)) return;
      if (op == 0) { regs[BW_ERR / 4] |= BW_E_BAD_OP; return; }
      if (len == 0 || burst == 0 || burst > MAXB_ || outs == 0 || outs > OUTS_ || ports == 0 ||
          (P_ == 1 && (ports & 2u)))
        ok = 0;
      for (p = 0; p < 2; p++)
        if ((ports >> p) & 1u) {
          uint32_t ra = regs[BW_RD_ADDR(p) / 4], wa = regs[BW_WR_ADDR(p) / 4];
          if ((op & 1u) && ((ra & 7u) || (uint64_t)ra + len > 0x100000000ull)) ok = 0;
          if ((op & 2u) && ((wa & 7u) || (uint64_t)wa + len > 0x100000000ull)) ok = 0;
        }
      if (!ok) { regs[BW_ERR / 4] |= BW_E_BAD_DESC; return; }
      if (fault == 6) { busy = 1; return; }
      op_run(op);
      regs[BW_STATUS / 4] |= BW_ST_DONE;
      return;
    }
    case BW_ERR: regs[w] &= ~v; return;
    case BW_LEN: case BW_SEED_LO: case BW_SEED_HI:
    case 0x60: case 0x64: case 0x68: case 0x6C: regs[w] = v; return;
    case BW_BURST: regs[w] = v & 0x1FFu; return;
    case BW_OUTS: regs[w] = v & 0x7Fu; return;
    case BW_PORTS: regs[w] = v & 3u; return;
    default: return;
  }
}

uint32_t bw_rd(uint32_t off) {
  uint32_t w = (off & 0xFFu) / 4u;
  if (off >= 0x100u) return 0;
  switch (off) {
    case BW_ID: return BW_ID_VALUE;
    case BW_CONFIG: return (MAXB_ << 20) | (OUTS_ << 12) | (P_ << 8) | 100u;
    case BW_CTRL: return 0;
    case BW_STATUS: return (regs[w] & BW_ST_DONE) | (busy ? BW_ST_BUSY : 0u) | (regs[BW_ERR / 4] ? BW_ST_ERR : 0u);
    case BW_RD_STALL: return regs[0x26];
    case BW_WR_STALL: return regs[0x27];
    default: return regs[w];
  }
}

void bw_flush(uint32_t addr, uint32_t len) { (void)addr; (void)len; }
void bw_inval(uint32_t addr, uint32_t len) { (void)addr; (void)len; }

uint64_t bw_now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}
uint64_t bw_tps(void) { return 1000000000u; }
void bw_putc(int c) { putchar(c); }
const char *bw_plat(void) { return "host_model"; }
