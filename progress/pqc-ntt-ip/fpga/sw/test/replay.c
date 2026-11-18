/* replay.c: replay an access trace of the L4 RTL testbench on the register
 * model (reg_model.c) and compare every read value.
 *
 * The trace (tb/l4/tb_pqc_ntt_axi_top.sv, +TRACE=<file>) lists each AXI4-Lite
 * access the RTL performed, in performance order, with its FCLK cycle:
 *   H <algo> <bfu_latency> <version hex> <config hex>   header
 *   R <cycle> <offset hex> <data hex>                   read, data = RTL value
 *   W <cycle> <offset hex> <data hex>                   write
 *   X <cycle>                                           reset
 * In the same cycle the read is listed before the write (the RTL read sees
 * the state before the write of that cycle).
 *
 * The model runs in replay mode: its time is the trace cycle, in_ready and
 * out_valid have no delay. Compared: every bit of every read value, except
 * STATUS.in_ready / STATUS.out_valid, whose exact cycle depends on the RTL
 * read-ahead and is not part of the spec; for those two bits only "RTL 1 ->
 * model 1" is required (the model must not report not-ready when the RTL
 * was ready). Everything else (data, ERR, CYCLES, busy, done_sticky,
 * result_bank, VERSION, CONFIG, undefined addresses) must be equal.
 *
 * Input: environment variable PQC_TRACE (path), no arguments (process
 * privacy rule of the workspace). Output: one line per mismatch (first 20)
 * and "REPLAY RESULT: PASS|FAIL". Exit 0 only on PASS with at least one read.
 */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pqc_ntt_hal.h"
#include "pqc_ntt_regs.h"
#include "reg_model.h"

#define LOOSE_BITS (PQC_NTT_STATUS_IN_READY | PQC_NTT_STATUS_OUT_VALID)

int main(void)
{
  const char *path = getenv("PQC_TRACE");
  FILE *f;
  char line[256];
  unsigned long n_line = 0, n_rd = 0, n_wr = 0, n_reset = 0, n_bad = 0;
  int have_hdr = 0;
  uintptr_t base = (uintptr_t)PQC_NTT_DEFAULT_BASEADDR;

  if (path == NULL || *path == '\0') {
    fprintf(stderr, "replay: PQC_TRACE not set\n");
    return 2;
  }
  f = fopen(path, "r");
  if (f == NULL) {
    fprintf(stderr, "replay: cannot open the trace\n");
    return 2;
  }
  while (fgets(line, sizeof line, f) != NULL) {
    char kind = 0;
    unsigned long long cyc = 0;
    unsigned off = 0, data = 0;
    n_line++;
    if (line[0] == 'H') {
      int algo, lat;
      unsigned ver, cfg;
      if (sscanf(line, "H %d %d %x %x", &algo, &lat, &ver, &cfg) != 4) {
        fprintf(stderr, "replay: bad header line %lu\n", n_line);
        return 2;
      }
      reg_model_set_config_reg(cfg);
      reg_model_set_replay(1);
      reg_model_config(algo, lat, 0, 1u);
      have_hdr = 1;
      printf("REPLAY header algo=%d lat=%d version=0x%08x config=0x%08x\n", algo, lat, ver, cfg);
      continue;
    }
    if (!have_hdr) {
      fprintf(stderr, "replay: access before the header (line %lu)\n", n_line);
      return 2;
    }
    if (line[0] == 'X') {
      if (sscanf(line, "X %llu", &cyc) != 1) {
        fprintf(stderr, "replay: bad reset line %lu\n", n_line);
        return 2;
      }
      reg_model_reset();
      n_reset++;
      continue;
    }
    if (sscanf(line, "%c %llu %x %x", &kind, &cyc, &off, &data) != 4 || (kind != 'R' && kind != 'W')) {
      fprintf(stderr, "replay: bad line %lu\n", n_line);
      return 2;
    }
    reg_model_set_time((uint64_t)cyc);
    if (kind == 'W') {
      reg_write32(base, off, data);
      n_wr++;
    } else {
      uint32_t mv = reg_read32(base, off);
      uint32_t mask = (off == PQC_NTT_REG_STATUS) ? ~(uint32_t)LOOSE_BITS : 0xFFFFFFFFu;
      int bad = (mv & mask) != (data & mask);
      if (off == PQC_NTT_REG_STATUS && (data & LOOSE_BITS & ~mv) != 0u) bad = 1;
      n_rd++;
      if (bad) {
        if (n_bad < 20)
          printf("REPLAY MISMATCH line=%lu cycle=%llu offset=0x%03x rtl=0x%08x model=0x%08x\n", n_line, cyc, off,
                 data, (unsigned)mv);
        n_bad++;
      }
    }
  }
  fclose(f);
  printf("REPLAY lines=%lu reads=%lu writes=%lu resets=%lu mismatches=%lu\n", n_line, n_rd, n_wr, n_reset, n_bad);
  printf("REPLAY RESULT: %s\n", (n_bad == 0 && n_rd > 0) ? "PASS" : "FAIL");
  return (n_bad == 0 && n_rd > 0) ? 0 : 1;
}
