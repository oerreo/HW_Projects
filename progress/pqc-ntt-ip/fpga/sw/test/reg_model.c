/* reg_model.c: register-level software model of pqc_ntt_axi_top (host test
 * only). See reg_model.h for what it does and does not prove.
 *
 * Time model: every register access advances the model clock by 1..10
 * FCLK cycles (seeded jitter), standing in for the AXI4-Lite access time.
 * NTT / INTT / BASEMUL complete after the cycle count of docs/spec/arch.md
 * ("L2 results"); in_ready and out_valid rise after a random delay so that
 * the driver's STATUS polling is exercised.
 *
 * Register behaviour (l4_axi.md "decided behaviour", same as
 * rtl/l4/pqc_ntt_csr.sv):
 *   CTRL write     clears done_sticky (A5), except a start with an illegal
 *                  op, which changes nothing but sets ERR.bad_op (A9).
 *                  start = 1 while busy: ignored, ERR.start_busy (A8); an
 *                  illegal op while busy sets both bits. Else the op starts.
 *   STATUS read    busy, done_sticky, result_bank, in_ready, out_valid.
 *   DIN write      accepted only during LOAD with in_ready, else ERR.din and
 *                  dropped (A1, A3). Bits [11:0] stored unchanged; an
 *                  accepted word >= q sets ERR.din_range (A15).
 *   DOUT read      during UNLOAD with out_valid returns the next word and
 *                  pops it; else ERR.dout and returns 0 (A4).
 *   CYCLES         start to done in model cycles (A12).
 *   VERSION        ALGO | BFU_LATENCY << 8 | ID << 16.  CONFIG constant.
 *   ERR            W1C (A14); a set wins over a clear of the same access.
 * Op completion at model time t_end (the RTL done_o cycle): from t_end on
 * busy = 0 and result_bank is the new value; done_sticky and CYCLES become
 * visible from t_end + 1 (RTL registers). A CTRL write at exactly t_end
 * cancels the done_sticky set (clear wins), CYCLES is still updated.
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
  uint32_t config;
  int config_set;     /* config given explicitly (not derived)         */
  int replay;         /* replay mode: time from reg_model_set_time      */
  uint64_t t_set;     /* replay time of the next access                 */
  int pend;           /* op ended at pend_at, done_sticky not yet set   */
  uint64_t pend_at;
  uint32_t pend_cycles;
  uint64_t err_set_t;  /* model time of the last ERR set                 */
  uint32_t err_set_bits; /* bits set at err_set_t (survive a W1C then)  */
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
  m.pend = 0;
  m.pend_at = 0;
  m.pend_cycles = 0;
  m.err_set_t = NEVER;
  m.err_set_bits = 0;
  m.n_compute = 0;
  memset(&m.st, 0, sizeof(m.st));
  /* RAM contents after configuration are unknown: random */
  for (b = 0; b < 2; b++)
    for (i = 0; i < N; i++) m.bank[b][i] = (uint16_t)rnd(Q);
}

/* CONFIG derived from the bfu LATENCY: FCLK 100 MHz, ROM_OUT_REG 1 and
 * the pipeline split of the Vivado CFG presets (create_project.tcl l0..l5). */
static uint32_t default_config(int lat)
{
  static const unsigned preset[6][4] = { /* PRE MUL RED OUT */
    {0, 0, 0, 0}, {0, 1, 0, 0}, {0, 1, 1, 0}, {0, 1, 1, 1}, {1, 1, 1, 1}, {1, 1, 2, 1}};
  const unsigned *p = preset[(lat >= 0 && lat <= 5) ? lat : 0];
  return (100u << PQC_NTT_CONFIG_FCLK_MHZ_SHIFT) | (p[3] << PQC_NTT_CONFIG_OUT_REG_BIT) |
         (p[2] << PQC_NTT_CONFIG_RED_PIPE_SHIFT) | (p[1] << PQC_NTT_CONFIG_MUL_REG_BIT) |
         (p[0] << PQC_NTT_CONFIG_PRE_REG_BIT) | (1u << PQC_NTT_CONFIG_ROM_OUT_REG_BIT);
}

void reg_model_config(int algo, int bfu_lat, int fault, uint32_t seed)
{
  m.algo = algo;
  m.lat = bfu_lat;
  m.fault = fault;
  m.seed = seed;
  m.configured = 1;
  if (!m.config_set) m.config = default_config(bfu_lat);
  reg_model_reset();
}

void reg_model_set_config_reg(uint32_t config)
{
  m.config = config;
  m.config_set = 1;
}

void reg_model_set_replay(int on)
{
  m.replay = on;
}

void reg_model_set_time(uint64_t t)
{
  m.t_set = t;
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
  f = getenv("PQC_CONFIG");
  if (f && *f) reg_model_set_config_reg((uint32_t)strtoul(f, NULL, 16));
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
  if (m.replay) {
    if (m.t_set < m.now) fatal("replay time goes backwards", (uint32_t)m.t_set);
    m.now = m.t_set;
  } else {
    m.now += 1u + rnd(10);
  }
  m.st.accesses++;
  if (m.op != OP_IDLE && m.t_end != NEVER && m.now >= m.t_end) {
    /* done_o cycle t_end: busy 0 and result_bank from here on */
    m.result_bank = m.op_rbank;
    m.pend = 1;
    m.pend_at = m.t_end;
    m.pend_cycles = (uint32_t)(m.t_end - m.t_start);
    m.op = OP_IDLE;
    m.t_end = NEVER;
    m.t_ready = NEVER;
  }
  if (m.pend && m.now > m.pend_at) {
    /* registers written in the done_o cycle are visible one cycle later */
    m.done_sticky = 1;
    m.cycles = m.pend_cycles;
    m.pend = 0;
  }
}

/* CTRL write while an op end is pending (write in the done_o cycle):
 * CYCLES is latched anyway, done_sticky is not set when clear is true. */
static void resolve_pend(int clear)
{
  if (!m.pend) return;
  m.cycles = m.pend_cycles;
  if (!clear) m.done_sticky = 1;
  m.pend = 0;
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
    if (m.fault != RM_FAULT_STALL) m.t_ready = m.replay ? m.now : m.now + 1u + rnd(20);
    break;
  case PQC_NTT_OP_UNLOAD:
    if (m.fault != RM_FAULT_STALL) m.t_ready = m.replay ? m.now : m.now + 2u + rnd(20);
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

/* ERR set: a W1C in the same model cycle does not clear these bits (RTL:
 * set wins). Only reachable in replay mode, where two accesses can share a
 * cycle. */
static void set_err(uint32_t bits)
{
  if (m.err_set_t != m.now) {
    m.err_set_t = m.now;
    m.err_set_bits = 0;
  }
  m.err_set_bits |= bits;
  m.err |= bits;
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
      else m.t_ready = m.replay ? m.now + 1u : m.now + 1u + rnd(20);
    } else {
      set_err(PQC_NTT_ERR_DOUT);
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
  case PQC_NTT_REG_CONFIG:
    v = m.config;
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
    int start = (val & PQC_NTT_CTRL_START_MASK) != 0u;
    int legal = op < PQC_NTT_OP_COUNT;
    if (!(start && !legal)) { /* A5; an illegal op start changes nothing (A9) */
      resolve_pend(1);
      m.done_sticky = 0;
    }
    if (start) {
      if (m.op != OP_IDLE) set_err(PQC_NTT_ERR_START_BUSY); /* A8 */
      if (!legal) set_err(PQC_NTT_ERR_BAD_OP);              /* A9 */
      if (m.op == OP_IDLE && legal) start_op(op, bank);
    }
    break;
  }
  case PQC_NTT_REG_DIN:
    if (in_ready()) {
      m.bank[m.op_bank][m.count++] = (uint16_t)(val & PQC_NTT_COEF_MASK);
      if ((val & PQC_NTT_COEF_MASK) >= Q) set_err(PQC_NTT_ERR_DIN_RANGE); /* A15 */
      if (m.count == N) m.t_end = m.now + 1u;
    } else {
      set_err(PQC_NTT_ERR_DIN);
    }
    break;
  case PQC_NTT_REG_ERR:
    m.err &= ~(val & ~(m.err_set_t == m.now ? m.err_set_bits : 0u));
    break;
  default: /* read-only and unmapped offsets: ignored */
    break;
  }
}
