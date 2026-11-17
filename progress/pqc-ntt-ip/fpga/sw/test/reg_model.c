/* reg_model.c: register-level software model of pqc_ntt_axi_top (host test
 * only). See reg_model.h for what it does and does not prove.
 *
 * Time model: every register access advances the model clock by 1..10
 * FCLK cycles (seeded jitter), standing in for the AXI4-Lite access time.
 * NTT / INTT / BASEMUL complete after the cycle count of docs/spec/arch.md
 * ("L2 results"); in_ready and out_valid rise after a random delay so that
 * the driver's STATUS polling is exercised.
 *
 * Register behaviour (l4_axi.md + ASSUMPTIONS.md):
 *   CTRL write     clears done_sticky (A5). start = 1: ignored with
 *                  ERR.start_busy while busy (A8), ignored silently for an
 *                  illegal op (A9), else the op starts.
 *   STATUS read    busy, done_sticky, result_bank, in_ready, out_valid.
 *   DIN write      accepted only during LOAD with in_ready, else ERR.din and
 *                  dropped (A1, A3). Bits [11:0] stored unchecked (A15).
 *   DOUT read      during UNLOAD with out_valid returns the next word and
 *                  pops it; else ERR.dout and returns 0 (A4).
 *   CYCLES         latched at done: start to done in model cycles (A12).
 *   VERSION        ALGO | BFU_LATENCY << 8 | ID << 16.
 *   ERR            W1C (A14).
 * NTT / INTT write the result to the other bank and leave random values in
 * the input bank (A19). BASEMUL: bank0 = bank0 x bank1, bank1 unchanged.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mlkem_dpi.h"
#include "pqc_ntt_hal.h"
#include "pqc_ntt_regs.h"
#include "reg_model.h"

#define N 256
#define Q 3329
#define NEVER UINT64_MAX
#define OP_IDLE (-1)

static struct {
  int configured;
  int algo;
  int lat;
  int fault;
  uint32_t seed;
  uint64_t rng;
  uint64_t now;
  uint16_t bank[2][N];
  int op;             /* running op or OP_IDLE                          */
  int op_bank;
  int op_rbank;       /* result bank reported at done                   */
  uint64_t t_start;
  uint64_t t_end;     /* completion time, NEVER while unknown           */
  uint64_t t_ready;   /* in_ready / out_valid from this time            */
  int count;          /* LOAD words accepted / UNLOAD words popped      */
  int done_sticky;
  int result_bank;
  uint32_t cycles;
  uint32_t err;
  uint32_t n_compute;
  reg_model_stats_t st;
} m;

/* splitmix64 */
static uint64_t rnd64(void)
{
  uint64_t z = (m.rng += 0x9E3779B97F4A7C15ull);
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
  return z ^ (z >> 31);
}

static unsigned rnd(unsigned n) /* [0, n) */
{
  return (unsigned)(rnd64() % n);
}

static void fatal(const char *msg, uint32_t v)
{
  fprintf(stderr, "reg_model: %s (0x%x)\n", msg, (unsigned)v);
  exit(3);
}

void reg_model_reset(void)
{
  int i, b;
  m.rng = m.seed;
  m.now = 0;
  m.op = OP_IDLE;
  m.op_bank = 0;
  m.op_rbank = 0;
  m.t_start = 0;
  m.t_end = NEVER;
  m.t_ready = NEVER;
  m.count = 0;
  m.done_sticky = 0;
  m.result_bank = 0;
  m.cycles = 0;
  m.err = 0;
  m.n_compute = 0;
  memset(&m.st, 0, sizeof(m.st));
  /* RAM contents after configuration are unknown: random */
  for (b = 0; b < 2; b++)
    for (i = 0; i < N; i++) m.bank[b][i] = (uint16_t)rnd(Q);
}

void reg_model_config(int algo, int bfu_lat, int fault, uint32_t seed)
{
  m.algo = algo;
  m.lat = bfu_lat;
  m.fault = fault;
  m.seed = seed;
  m.configured = 1;
  reg_model_reset();
}

static int env_int(const char *name, int def)
{
  const char *s = getenv(name);
  return (s && *s) ? atoi(s) : def;
}

static void lazy_init(void)
{
  const char *f;
  int fault = RM_FAULT_NONE;
  if (m.configured) return;
  f = getenv("PQC_MODEL_FAULT");
  if (f && *f && strcmp(f, "none") != 0) {
    if (!strcmp(f, "data")) fault = RM_FAULT_DATA;
    else if (!strcmp(f, "cycles")) fault = RM_FAULT_CYCLES;
    else if (!strcmp(f, "version")) fault = RM_FAULT_VERSION;
    else if (!strcmp(f, "hang")) fault = RM_FAULT_HANG;
    else if (!strcmp(f, "stall")) fault = RM_FAULT_STALL;
    else if (!strcmp(f, "rbank")) fault = RM_FAULT_RBANK;
    else fatal("unknown PQC_MODEL_FAULT", 0);
  }
  reg_model_config(env_int("PQC_ALGO", 0), env_int("PQC_BFU_LAT", 0), fault,
                   (uint32_t)env_int("PQC_MODEL_SEED", 1));
  if (m.algo < 0 || m.algo >= PQC_NTT_ALGO_COUNT) fatal("PQC_ALGO out of range", (uint32_t)m.algo);
  if (m.lat < 0 || m.lat > 255) fatal("PQC_BFU_LAT out of range", (uint32_t)m.lat);
}

void reg_model_get_stats(reg_model_stats_t *st)
{
  *st = m.st;
}

uint64_t reg_model_now(void)
{
  return m.now;
}

/* ------------------------------------------------------------------------
 * Cycle counts, written independently of the driver's copy
 * (pqc_ntt_expected_cycles) from docs/spec/arch.md "L2 results".
 * ------------------------------------------------------------------------ */
static uint64_t model_cycles(int op)
{
  uint64_t l = (uint64_t)m.lat;
  int s_is_one = (m.algo == PQC_NTT_ALGO_BARRETT || m.algo == PQC_NTT_ALGO_SHIFTADD);
  if (op == PQC_NTT_OP_BASEMUL) return 128u * (s_is_one ? 5u : 7u) * (l + 1u) + 3u;
  return 897u + 7u * (1u + l); /* NTT, INTT */
}

/* ------------------------------------------------------------------------ */
static void advance(void)
{
  m.now += 1u + rnd(10);
  m.st.accesses++;
  if (m.op != OP_IDLE && m.t_end != NEVER && m.now >= m.t_end) {
    m.done_sticky = 1;
    m.result_bank = m.op_rbank;
    m.cycles = (uint32_t)(m.t_end - m.t_start);
    m.op = OP_IDLE;
    m.t_end = NEVER;
    m.t_ready = NEVER;
  }
}

static void compute(int op, int bank)
{
  int in_a[N], in_b[N], out[N];
  int i, rc, dst;
  for (i = 0; i < N; i++) {
    in_a[i] = m.bank[op == PQC_NTT_OP_BASEMUL ? 0 : bank][i];
    in_b[i] = m.bank[1][i];
  }
  if (op == PQC_NTT_OP_NTT) rc = mlkem_dpi_hw_ntt(m.algo, in_a, out);
  else if (op == PQC_NTT_OP_INTT) rc = mlkem_dpi_hw_intt(m.algo, in_a, out);
  else rc = mlkem_dpi_hw_basemul(m.algo, in_a, in_b, out);
  if (rc != 0) {
    fprintf(stderr, "reg_model: golden model rejected the input of op %d (coefficient >= q)\n", op);
    for (i = 0; i < N; i++) out[i] = 0;
  }
  dst = (op == PQC_NTT_OP_BASEMUL) ? 0 : (bank ^ 1);
  if (op != PQC_NTT_OP_BASEMUL) {
    for (i = 0; i < N; i++) m.bank[bank][i] = (uint16_t)rnd(Q); /* A19 */
  }
  for (i = 0; i < N; i++) m.bank[dst][i] = (uint16_t)out[i];
  if (m.fault == RM_FAULT_DATA && (m.n_compute % 7u) == 3u) {
    m.bank[dst][17] = (uint16_t)((m.bank[dst][17] + 1u) % Q);
  }
  m.n_compute++;
  m.op_rbank = dst;
  if (m.fault == RM_FAULT_RBANK && op == PQC_NTT_OP_INTT) m.op_rbank = bank;
}

static void start_op(int op, int bank)
{
  m.op = op;
  m.op_bank = bank;
  m.op_rbank = bank;
  m.t_start = m.now;
  m.t_end = NEVER;
  m.t_ready = NEVER;
  m.count = 0;
  m.st.ops_started++;
  switch (op) {
  case PQC_NTT_OP_LOAD:
    if (m.fault != RM_FAULT_STALL) m.t_ready = m.now + 1u + rnd(20);
    break;
  case PQC_NTT_OP_UNLOAD:
    if (m.fault != RM_FAULT_STALL) m.t_ready = m.now + 2u + rnd(20);
    break;
  default: /* NTT, INTT, BASEMUL */
    compute(op, bank);
    if (m.fault != RM_FAULT_HANG) {
      m.t_end = m.now + model_cycles(op);
      if (m.fault == RM_FAULT_CYCLES && op == PQC_NTT_OP_BASEMUL) m.t_end += 1u;
    }
    break;
  }
}

static void check_addr(uintptr_t base, uint32_t off)
{
  if (base != (uintptr_t)PQC_NTT_DEFAULT_BASEADDR) fatal("access outside the IP base", (uint32_t)base);
  if ((off & 3u) != 0u || off >= PQC_NTT_ADDR_RANGE) fatal("bad register offset", off);
}

static int in_ready(void)
{
  return m.op == PQC_NTT_OP_LOAD && m.count < N && m.now >= m.t_ready;
}

static int out_valid(void)
{
  return m.op == PQC_NTT_OP_UNLOAD && m.count < N && m.now >= m.t_ready;
}

uint32_t reg_read32(uintptr_t base, uint32_t off)
{
  uint32_t v = 0;
  lazy_init();
  check_addr(base, off);
  advance();
  switch (off) {
  case PQC_NTT_REG_STATUS:
    v = (m.op != OP_IDLE ? PQC_NTT_STATUS_BUSY : 0u) |
        (m.done_sticky ? PQC_NTT_STATUS_DONE_STICKY : 0u) |
        (m.result_bank ? PQC_NTT_STATUS_RESULT_BANK : 0u) |
        (in_ready() ? PQC_NTT_STATUS_IN_READY : 0u) |
        (out_valid() ? PQC_NTT_STATUS_OUT_VALID : 0u);
    m.st.status_reads++;
    if ((m.op == PQC_NTT_OP_LOAD && !in_ready()) || (m.op == PQC_NTT_OP_UNLOAD && !out_valid()))
      m.st.status_not_ready++;
    break;
  case PQC_NTT_REG_DOUT:
    if (out_valid()) {
      v = m.bank[m.op_bank][m.count++];
      if (m.count == N) m.t_end = m.now + 1u;
      else m.t_ready = m.now + 1u + rnd(20);
    } else {
      m.err |= PQC_NTT_ERR_DOUT;
      v = 0;
    }
    break;
  case PQC_NTT_REG_CYCLES:
    v = m.cycles;
    break;
  case PQC_NTT_REG_VERSION:
    v = ((uint32_t)m.algo << PQC_NTT_VERSION_ALGO_SHIFT) |
        ((uint32_t)m.lat << PQC_NTT_VERSION_BFU_LATENCY_SHIFT) |
        ((PQC_NTT_VERSION_ID_VALUE ^ (m.fault == RM_FAULT_VERSION ? 1u : 0u))
         << PQC_NTT_VERSION_ID_SHIFT);
    break;
  case PQC_NTT_REG_ERR:
    v = m.err;
    break;
  default: /* CTRL, DIN (write only) and unmapped offsets read 0 (A17, A20) */
    v = 0;
    break;
  }
  return v;
}

void reg_write32(uintptr_t base, uint32_t off, uint32_t val)
{
  lazy_init();
  check_addr(base, off);
  advance();
  switch (off) {
  case PQC_NTT_REG_CTRL: {
    int op = (int)((val & PQC_NTT_CTRL_OP_MASK) >> PQC_NTT_CTRL_OP_SHIFT);
    int bank = (val & PQC_NTT_CTRL_BANK_MASK) ? 1 : 0;
    m.done_sticky = 0; /* A5 */
    if (val & PQC_NTT_CTRL_START_MASK) {
      if (m.op != OP_IDLE) m.err |= PQC_NTT_ERR_START_BUSY; /* A8 */
      else if (op < PQC_NTT_OP_COUNT) start_op(op, bank);  /* illegal op ignored, A9 */
    }
    break;
  }
  case PQC_NTT_REG_DIN:
    if (in_ready()) {
      m.bank[m.op_bank][m.count++] = (uint16_t)(val & PQC_NTT_COEF_MASK);
      if (m.count == N) m.t_end = m.now + 1u;
    } else {
      m.err |= PQC_NTT_ERR_DIN;
    }
    break;
  case PQC_NTT_REG_ERR:
    m.err &= ~val;
    break;
  default: /* read-only and unmapped offsets: ignored */
    break;
  }
}
