/*
 * Host model of pim_top from docs/spec/pim.md (commands 2, registers 3, push check 4.1, CTRL
 * 4.2). Not the RTL. Bank RAM: NB banks x DEPTH words of model/src bimg_word_t.
 *   LDW   rrec_unpack of the row records, bimg_pack into the banks at base (zero-filled slots)
 *   WRGB  x into the global buffer (beyond n reads 0)
 *   MACAB bimg_unpack of the bank words at base, bank_gemv (BANK_ROW) on the global buffer
 * ST_MAC / ST_RDMAC add the bank_stat_t of bank_gemv, ST_WRGB counts ceil(n/32) per WRGB.
 * CYCLES [estimate, no closed form for a multi-command run in pim.md]: 1 + sum of controller
 * occupancies (LDW: LDW_CYC 9 + rows (1 + ceil(n/8)) + 6, WRGB: ceil(n/8) + 8, MACAB:
 * (R - 1) max(nw, 4) + nw + 1, pim.md 6.1) + the tail of the last MACAB (L_BANK 5 + last round
 * rows + L_S 3 + y write 5 + last burst).
 */
#include <string.h>
#include "ipm.h"
#include "ipregs.h"
#include "llm.h"

#define E_START_BUSY 0x001u
#define E_BAD_OP 0x002u
#define E_BAD_CMD 0x004u
#define E_BAD_DESC 0x008u
#define E_MISALIGN 0x010u
#define E_RD_RESP 0x020u
#define E_WR_RESP 0x040u
#define E_FIFO_OVF 0x080u
#define FMAX 256

static struct {
  uint32_t cmd[4], fifo[FMAX][4];
  int nf, busy, done;
  uint32_t err, cyc, ops, st[3], nk[3];
  bimg_word_t *bank[16];
  int8_t gb[4096];
} S;

static uint32_t cdiv(uint32_t a, uint32_t b) { return (a + b - 1u) / b; }
static int sx8(uint32_t v) { return (int)(int8_t)(uint8_t)(v & 0xFFu); }

static int init(void) {
  int k;
  static bimg_word_t *mem;
  memset(&S, 0, sizeof(S));
  if (IPC.pi_nb > 16 || IPC.pi_cmdd > FMAX || IPC.pi_nmax > 4096) return 1;
  mem = ipm_scr(7, sizeof(bimg_word_t) * (size_t)IPC.pi_nb * (size_t)IPC.pi_depth);
  if (!mem) return 1;
  memset(mem, 0, sizeof(bimg_word_t) * (size_t)IPC.pi_nb * (size_t)IPC.pi_depth);
  for (k = 0; k < IPC.pi_nb; k++) S.bank[k] = mem + (size_t)k * (size_t)IPC.pi_depth;
  return 0;
}

static void push(void) {
  uint32_t op = S.cmd[0] & 0xFu, n = (S.cmd[0] >> 4) & 0xFFFu, rows = S.cmd[0] >> 16;
  uint32_t base = S.cmd[1] >> 17, addr = S.cmd[2];
  int bad = 0;
  if (op < PI_C_LDW || op > PI_C_MACAB) {
    S.err |= E_BAD_CMD;
    return;
  }
  if (n == 0 || n > (uint32_t)IPC.pi_nmax) bad = 1;
  if (op != PI_C_WRGB &&
      (rows == 0 || (uint64_t)base + (uint64_t)cdiv(rows, (uint32_t)IPC.pi_nb) * cdiv(n, 16u) >
                        (uint64_t)IPC.pi_depth))
    bad = 1;
  if (op == PI_C_LDW && (uint64_t)addr + (uint64_t)rows * 8u * (1u + cdiv(n, 8u)) > 0x100000000ull) bad = 1;
  if (op == PI_C_WRGB && (uint64_t)addr + n > 0x100000000ull) bad = 1;
  if (op == PI_C_MACAB && (uint64_t)addr + 4u * (uint64_t)rows > 0x100000000ull) bad = 1;
  if (bad) S.err |= E_BAD_DESC;
  if (addr & 7u) S.err |= E_MISALIGN;
  if (bad || (addr & 7u)) return;
  if (S.nf >= IPC.pi_cmdd) {
    S.err |= E_FIFO_OVF;
    return;
  }
  memcpy(S.fifo[S.nf++], S.cmd, sizeof(S.cmd));
}

static uint32_t exec(const uint32_t *c, int fault, uint32_t *tail) {
  uint32_t op = c[0] & 0xFu, n = (c[0] >> 4) & 0xFFFu, rows = c[0] >> 16;
  uint32_t xm = c[1] & 0x1FFFFu, base = c[1] >> 17, addr = c[2];
  uint32_t nw = cdiv(n, 16u), R = cdiv(rows, (uint32_t)IPC.pi_nb), last = 0;
  if (op == PI_C_LDW) {
    uint32_t rb = 8u * (1u + cdiv(n, 8u));
    const uint8_t *rec = mem_rd(addr, rows * rb);
    int8_t *W = ipm_scr(0, (size_t)rows * n);
    uint16_t *wm = ipm_scr(2, 2u * (size_t)rows);
    if (!rec || fault == 1) S.err |= E_RD_RESP;
    if (rec) rrec_unpack(rec, (int)rows, (int)n, W, wm);
    else {
      memset(W, 0, (size_t)rows * n);
      memset(wm, 0, 2u * (size_t)rows);
    }
    bimg_pack(S.bank, IPC.pi_nb, IPC.pi_depth, (long)base, W, wm, (int)rows, (int)n);
    S.nk[0]++;
    *tail = 0;
    return 9u + rows * (1u + cdiv(n, 8u)) + 6u;
  }
  if (op == PI_C_WRGB) {
    const uint8_t *x = mem_rd(addr, n);
    if (!x || fault == 1) S.err |= E_RD_RESP;
    memset(S.gb, 0, sizeof(S.gb));
    if (x) memcpy(S.gb, x, n);
    S.st[0] += cdiv(n, 32u);
    S.nk[1]++;
    *tail = 0;
    return cdiv(n, 8u) + 8u;
  }
  { /* MACAB */
    bank_mat_t b;
    bank_stat_t st;
    lm_arena_t a;
    size_t need = (size_t)rows * n + 4u * (size_t)rows + 64u * 16u + 4096u;
    int32_t *y = ipm_scr(3, 4u * (size_t)rows);
    int8_t *gbuf = ipm_scr(4, n);
    kscl_t xs;
    uint8_t *d;
    memset(&a, 0, sizeof(a));
    a.base = ipm_scr(5, need);
    a.cap = need;
    memset(&st, 0, sizeof(st));
    bimg_unpack(&b, (const bimg_word_t *const *)S.bank, IPC.pi_nb, (long)base, (int)rows, (int)n,
                sx8(c[3]), &a);
    xs.m = (int32_t)xm;
    xs.e = sx8(c[3] >> 8);
    bank_gemv(&b, S.gb, xs, sx8(c[3] >> 16), y, gbuf, NULL, &st);
    S.st[1] += (uint32_t)st.mac;
    S.st[2] += (uint32_t)st.rdmac;
    d = mem_wr(addr, 4u * rows);
    if (d) memcpy(d, y, 4u * (size_t)rows);
    else S.err |= E_WR_RESP;
    if (fault == 1) S.err |= E_RD_RESP;
    S.nk[2]++;
    ipm_nburst(addr, cdiv(rows, 2u), &last);
    *tail = 5u + (rows - (uint32_t)IPC.pi_nb * (R - 1u)) + 3u + 5u + last;
    return (R - 1u) * (nw > 4u ? nw : 4u) + nw + 1u;
  }
}

static void ctrl(uint32_t v) {
  uint32_t op = (v >> 4) & 0xFu, tail = 0;
  int f, i;
  if (S.busy) {
    if (v & 1u) S.err |= E_START_BUSY | ((op != PI_OP_RUN && op != PI_OP_FLUSH) ? E_BAD_OP : 0u);
    return;
  }
  if (!(v & 1u)) {
    S.done = 0;
    return;
  }
  if (op != PI_OP_RUN && op != PI_OP_FLUSH) {
    S.err |= E_BAD_OP;
    return;
  }
  S.done = 0;
  S.cyc = 0;
  if (op == PI_OP_FLUSH) {
    S.cyc = (uint32_t)S.nf + 1u;
    S.nf = 0;
    S.done = 1;
    return;
  }
  f = ipm_fault(SLOT_PI);
  if (f == 2) {
    S.busy = 1;
    return;
  }
  S.cyc = 1;
  for (i = 0; i < S.nf; i++) {
    S.cyc += exec(S.fifo[i], f, &tail);
    S.ops++;
  }
  S.cyc += tail;
  S.nf = 0;
  S.done = 1;
}

static void wr(uint32_t off, uint32_t v) {
  switch (off) {
  case R_CTRL: ctrl(v); return;
  case R_ERR: S.err &= ~v; return;
  case PI_CMD0: S.cmd[0] = v; return;
  case PI_CMD1: S.cmd[1] = v; return;
  case PI_CMD2: S.cmd[2] = v; return;
  case PI_CMD3: S.cmd[3] = v; return;
  case PI_CMD_PUSH: push(); return;
  default: return;
  }
}

static uint32_t rd(uint32_t off) {
  switch (off) {
  case R_ID: return PI_ID;
  case R_CONFIG:
    return (uint32_t)IPC.fclk | ((uint32_t)IPC.pi_nb << 8) | (4u << 12) | ((uint32_t)IPC.pi_nmax << 16);
  case R_STATUS:
    return (S.busy ? ST_BUSY : 0u) | (S.done ? ST_DONE : 0u) | (S.err ? ST_ERR : 0u) |
           ((uint32_t)S.nf << 8);
  case R_ERR: return S.err;
  case R_CYCLES: return S.cyc;
  case R_RD_STALL: return 0;
  case R_WR_STALL: return 0;
  case R_OPS: return S.ops;
  case PI_CONFIG2: return (uint32_t)IPC.pi_depth | ((uint32_t)IPC.pi_cmdd << 16);
  case PI_CMD0: return S.cmd[0];
  case PI_CMD1: return S.cmd[1];
  case PI_CMD2: return S.cmd[2];
  case PI_CMD3: return S.cmd[3];
  case PI_ST_WRGB: return S.st[0];
  case PI_ST_MAC: return S.st[1];
  case PI_ST_RDMAC: return S.st[2];
  case PI_N_LDW: return S.nk[0];
  case PI_N_WRGB: return S.nk[1];
  case PI_N_MACAB: return S.nk[2];
  default: return 0;
  }
}

const ipm_t IPM_PI = {rd, wr, init};
