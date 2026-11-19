/*
 * bw_main.c: HP-port bandwidth measurement on the Zybo Z7-20 (S4-3, docs/spec/bwtest.md).
 *
 * For every configuration of the sweeps below the PS programs the IP (rtl/l3/bw_top.sv),
 * starts one op, polls STATUS and reads the counters, then checks the result on the ARM:
 *   RD  XOR and SUM (mod 2^64) of the source buffer words, last word masked to LEN, computed
 *       here from memory, must equal the IP's checksum registers
 *   WR  the destination buffer must equal the pattern {SEED_HI ^ p, SEED_LO} + k * INC and
 *       the 8 guard bytes before and after must be unchanged
 *   RD_BEATS / WR_BEATS = ceil(LEN / 8), ERR = 0, op finished before the timeout
 * One line per run on the UART ("BW ..."), then "BWTEST RESULT: PASS|FAIL" and "BWTEST END".
 * Bandwidth: MB/s = bytes moved * FCLK / CYCLES (MB = 10^6 bytes), printed x10 as an integer.
 * FCLK_HZ is the PL clock (the actual FCLK_CLK0 printed by create_project.tcl); the CONFIG
 * register only has the requested MHz. A wall time from the ARM global timer (start write to
 * the end of polling, includes the AXI-Lite polling) is printed as t_us.
 *
 * Output uses only bw_putc (no printf: 64-bit formatting is not portable in xil_printf).
 */
#include <stdint.h>
#include "bw_hal.h"
#include "bw_regs.h"

#ifndef FCLK_HZ
#define FCLK_HZ 100000000u
#endif
#ifndef BW_QUICK
#define BW_QUICK 0 /* 1: reduced sweep (host test) */
#endif
#ifndef POLL_MAX
#define POLL_MAX 200000000u /* about 20 s of AXI-Lite polling */
#endif

/* ---------------- output ---------------- */
static void puts_(const char *s) {
  while (*s) bw_putc(*s++);
}
static void putu(uint64_t v) {
  char b[24];
  int n = 0;
  do {
    b[n++] = (char)('0' + (int)(v % 10u));
    v /= 10u;
  } while (v);
  while (n) bw_putc(b[--n]);
}
static void putx(uint64_t v, int digits) {
  int i;
  for (i = digits - 1; i >= 0; i--) bw_putc("0123456789abcdef"[(v >> (4 * i)) & 0xFu]);
}
static void kv(const char *k, uint64_t v) {
  bw_putc(' ');
  puts_(k);
  bw_putc('=');
  putu(v);
}
static void kvx(const char *k, uint64_t v, int digits) {
  bw_putc(' ');
  puts_(k);
  puts_("=0x");
  putx(v, digits);
}
static void kvs(const char *k, const char *s) {
  bw_putc(' ');
  puts_(k);
  bw_putc('=');
  puts_(s);
}

/* ---------------- memory helpers ---------------- */
static uint64_t rd64(uint32_t a) {
  volatile uint8_t *p = bw_mem(a);
  uint64_t v = 0;
  int i;
  for (i = 7; i >= 0; i--) v = (v << 8) | p[i];
  return v;
}

static uint64_t xs_state;
static uint64_t xs64(void) {
  xs_state ^= xs_state << 13;
  xs_state ^= xs_state >> 7;
  xs_state ^= xs_state << 17;
  return xs_state;
}

static void fill_src(uint32_t a, uint32_t len, uint64_t seed) {
  volatile uint8_t *p = bw_mem(a);
  uint32_t i;
  xs_state = seed | 1u;
  for (i = 0; i < len; i += 8) {
    uint64_t v = xs64();
    int b;
    for (b = 0; b < 8; b++) p[i + (uint32_t)b] = (uint8_t)(v >> (8 * b));
  }
  bw_flush(a, len);
}

/* checksum as defined by the IP: 64-bit little-endian words, bytes beyond len are 0 */
static void csum(uint32_t a, uint32_t len, uint64_t *x, uint64_t *s) {
  uint32_t k, nb = (len + 7u) / 8u;
  *x = 0;
  *s = 0;
  for (k = 0; k < nb; k++) {
    uint64_t w = rd64(a + 8u * k);
    uint32_t left = len - 8u * k;
    if (left < 8u) w &= (((uint64_t)1) << (8u * left)) - 1u;
    *x ^= w;
    *s += w;
  }
}

/* ---------------- one run ---------------- */
static uint32_t n_run, n_fail, P, OUTS, MAXB;

static const char *op_name(uint32_t op) { return op == BW_OP_RD ? "RD" : op == BW_OP_WR ? "WR" : "RW"; }

static int run(uint32_t op, uint32_t len, uint32_t burst, uint32_t outs, uint32_t ports) {
  uint32_t p, st, err, cyc, polls = 0, off = 8u * (n_run % 4u);
  uint32_t seed_lo = 0x1234567u + 0x9E37u * n_run, seed_hi = 0xCAFE0000u ^ n_run;
  uint32_t nb = (len + 7u) / 8u, nport = 0;
  uint64_t t0, t1, bytes, mbps10;
  int ok = 1;
  const char *why = "ok";
  uint32_t rcyc[2] = {0, 0}, wcyc[2] = {0, 0}, rst[2] = {0, 0}, wst[2] = {0, 0};

  n_run++;
  for (p = 0; p < P; p++) {
    if (!((ports >> p) & 1u)) continue;
    nport++;
    if (op & BW_OP_WR) { /* guards around the destination, then clean the whole range */
      volatile uint8_t *g = bw_mem(BW_BUF_WR(p) + off);
      int b;
      for (b = 1; b <= 8; b++) g[-b] = (uint8_t)(0xA0u + (unsigned)b);
      for (b = 0; b < 8; b++) g[len + (uint32_t)b] = (uint8_t)(0xB0u + (unsigned)b);
      bw_flush(BW_BUF_WR(p) + off - 8u, len + 16u);
    }
  }
  bw_wr(BW_LEN, len);
  bw_wr(BW_BURST, burst);
  bw_wr(BW_OUTS, outs);
  bw_wr(BW_PORTS, ports);
  bw_wr(BW_SEED_LO, seed_lo);
  bw_wr(BW_SEED_HI, seed_hi);
  for (p = 0; p < 2; p++) {
    bw_wr(BW_RD_ADDR(p), BW_BUF_RD(p) + off);
    bw_wr(BW_WR_ADDR(p), BW_BUF_WR(p) + off);
  }
  t0 = bw_now();
  bw_wr(BW_CTRL, BW_CTRL_START(op));
  do {
    st = bw_rd(BW_STATUS);
  } while ((st & BW_ST_BUSY) && ++polls < POLL_MAX);
  t1 = bw_now();
  err = bw_rd(BW_ERR);
  cyc = bw_rd(BW_CYCLES);
  if (polls >= POLL_MAX) { ok = 0; why = "timeout"; }
  else if (!(st & BW_ST_DONE)) { ok = 0; why = "not_done"; }
  else if (err != 0) { ok = 0; why = "err"; }

  for (p = 0; p < P && p < 2; p++) {
    if (!((ports >> p) & 1u)) continue;
    rcyc[p] = bw_rd(BW_RES(p, BW_R_RD_CYC));
    wcyc[p] = bw_rd(BW_RES(p, BW_R_WR_CYC));
    rst[p] = bw_rd(BW_RES(p, BW_R_RD_STALL));
    wst[p] = bw_rd(BW_RES(p, BW_R_WR_STALL));
    if (!ok) continue;
    if (op & BW_OP_RD) {
      uint64_t x, s, hx, hs;
      csum(BW_BUF_RD(p) + off, len, &x, &s);
      hx = ((uint64_t)bw_rd(BW_RES(p, BW_R_XOR_HI)) << 32) | bw_rd(BW_RES(p, BW_R_XOR_LO));
      hs = ((uint64_t)bw_rd(BW_RES(p, BW_R_SUM_HI)) << 32) | bw_rd(BW_RES(p, BW_R_SUM_LO));
      if (hx != x || hs != s) { ok = 0; why = "csum"; }
      if (bw_rd(BW_RD_BEATS(p)) != nb) { ok = 0; why = "rd_beats"; }
    }
    if (op & BW_OP_WR) {
      uint32_t a = BW_BUF_WR(p) + off, k;
      volatile uint8_t *m;
      uint64_t d = (((uint64_t)(seed_hi ^ p)) << 32) | seed_lo;
      int b;
      bw_inval(a - 8u, len + 16u);
      m = bw_mem(a);
      for (k = 0; k < len && ok; k++) {
        if (k && (k % 8u) == 0) d += BW_PAT_INC;
        if (m[k] != (uint8_t)(d >> (8u * (k % 8u)))) { ok = 0; why = "wr_data"; }
      }
      for (b = 1; b <= 8; b++)
        if (m[-b] != (uint8_t)(0xA0u + (unsigned)b)) { ok = 0; why = "wr_guard"; }
      for (b = 0; b < 8; b++)
        if (m[len + (uint32_t)b] != (uint8_t)(0xB0u + (unsigned)b)) { ok = 0; why = "wr_guard"; }
      if (bw_rd(BW_WR_BEATS(p)) != nb) { ok = 0; why = "wr_beats"; }
    }
  }

  bytes = (uint64_t)len * nport * (op == BW_OP_RW ? 2u : 1u);
  mbps10 = cyc ? bytes * (uint64_t)FCLK_HZ * 10u / ((uint64_t)cyc * 1000000u) : 0;
  puts_("BW");
  kv("run", n_run);
  kvs("op", op_name(op));
  kv("ports", ports);
  kv("len", len);
  kv("burst", burst);
  kv("outs", outs);
  kv("cyc", cyc);
  kv("rcyc0", rcyc[0]);
  kv("rcyc1", rcyc[1]);
  kv("wcyc0", wcyc[0]);
  kv("wcyc1", wcyc[1]);
  kv("rst0", rst[0]);
  kv("rst1", rst[1]);
  kv("wst0", wst[0]);
  kv("wst1", wst[1]);
  kv("mbps10", mbps10);
  kv("t_us", bw_tps() ? (t1 - t0) * 1000000u / bw_tps() : 0);
  kvx("err", err, 2);
  kvs("chk", ok ? "OK" : why);
  puts_("\r\n");
  if (!ok) n_fail++;
  return ok;
}

/* expect a rejected start with exactly the ERR bits e, then clear them */
static void neg(const char *what, uint32_t ctrl, uint32_t e) {
  uint32_t got;
  bw_wr(BW_CTRL, ctrl);
  got = bw_rd(BW_ERR);
  puts_("BWNEG");
  kvs("case", what);
  kvx("err", got, 2);
  kvx("exp", e, 2);
  bw_wr(BW_ERR, got);
  if (got != e || (bw_rd(BW_STATUS) & (BW_ST_BUSY | BW_ST_DONE)) || bw_rd(BW_ERR) != 0) {
    n_fail++;
    puts_(" chk=FAIL\r\n");
  } else {
    puts_(" chk=OK\r\n");
  }
}

int main(void) {
  uint32_t id, cfg, p, i, j, op, pm;
  static const uint32_t bursts[] = {1, 2, 4, 8, 16, 32, 64, 128, 256};
  static const uint32_t outss[] = {1, 2, 4, 8, 16, 32, 64};
  static const uint32_t lens[] = {8, 64, 4096, 4097, 65536, 1000003, 1048576, 8388608};
  uint32_t nlens = BW_QUICK ? 6u : (uint32_t)(sizeof lens / sizeof lens[0]);

  if (bw_hal_init() != 0) return 1;
  puts_("\r\nBWTEST START");
  kvs("plat", bw_plat());
  kv("fclk_hz", FCLK_HZ);
  kv("quick", BW_QUICK);
  puts_("\r\n");
  id = bw_rd(BW_ID);
  cfg = bw_rd(BW_CONFIG);
  P = BW_CFG_P(cfg);
  OUTS = BW_CFG_OUTS(cfg);
  MAXB = BW_CFG_MAXB(cfg);
  puts_("BWCFG");
  kvx("id", id, 8);
  kvx("config", cfg, 8);
  kv("p", P);
  kv("outs", OUTS);
  kv("max_burst", MAXB);
  kv("fclk_mhz_cfg", BW_CFG_FCLK(cfg));
  puts_("\r\n");
  if (id != BW_ID_VALUE || P < 1 || P > 2 || OUTS < 1 || MAXB < 1 || MAXB > 256) {
    puts_("BWTEST RESULT: FAIL (ID / CONFIG)\r\nBWTEST END\r\n");
    return 1;
  }
  bw_wr(BW_ERR, 0x3Fu);

  /* source buffers: random data, cleaned to DDR */
  for (p = 0; p < P; p++) fill_src(BW_BUF_RD(p), BW_MAXLEN, 0x5EED0000ull + p);

  /* error paths (no traffic) */
  bw_wr(BW_LEN, 0);
  bw_wr(BW_PORTS, 1);
  bw_wr(BW_BURST, MAXB);
  bw_wr(BW_OUTS, OUTS);
  bw_wr(BW_RD_ADDR(0), BW_BUF_RD(0));
  bw_wr(BW_WR_ADDR(0), BW_BUF_WR(0));
  neg("len0", BW_CTRL_START(BW_OP_RD), BW_E_BAD_DESC);
  bw_wr(BW_LEN, 64);
  neg("op0", 1u, BW_E_BAD_OP);
  bw_wr(BW_BURST, MAXB + 1u);
  neg("burst", BW_CTRL_START(BW_OP_RD), BW_E_BAD_DESC);
  bw_wr(BW_BURST, MAXB);
  bw_wr(BW_RD_ADDR(0), BW_BUF_RD(0) + 4u);
  neg("align", BW_CTRL_START(BW_OP_RD), BW_E_BAD_DESC);
  bw_wr(BW_RD_ADDR(0), BW_BUF_RD(0));

  /* sweep A: 1 MiB, burst x outstanding x ports x op */
  for (pm = 1; pm <= (P == 2 ? 3u : 1u); pm += 2u)
    for (op = BW_OP_RD; op <= BW_OP_RW; op++)
      for (i = 0; i < sizeof bursts / sizeof bursts[0] && bursts[i] <= MAXB; i++)
        for (j = 0; j < sizeof outss / sizeof outss[0] && outss[j] <= OUTS; j++)
          (void)run(op, BW_QUICK ? 65536u : 1048576u, bursts[i], outss[j], pm);
  /* sweep B: sizes at the largest burst and outstanding limits, every port mask */
  for (pm = 1; pm <= (P == 2 ? 3u : 1u); pm++)
    for (op = BW_OP_RD; op <= BW_OP_RW; op++)
      for (i = 0; i < nlens; i++) (void)run(op, lens[i], MAXB, OUTS, pm);

  puts_("BWTEST summary");
  kv("runs", n_run);
  kv("fails", n_fail);
  kv("ops", bw_rd(BW_OPS));
  puts_("\r\nBWTEST RESULT: ");
  puts_(n_fail == 0 ? "PASS" : "FAIL");
  puts_("\r\nBWTEST END\r\n");
  return n_fail == 0 ? 0 : 1;
}
