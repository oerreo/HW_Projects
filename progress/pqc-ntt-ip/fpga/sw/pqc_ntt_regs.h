/* pqc_ntt_regs.h: register map of pqc_ntt_axi_top (AXI4-Lite CSR).
 *
 * Single source of truth for the PS software: register offsets, bit
 * positions and the op / ALGO encodings live ONLY in this file. Everything
 * else (driver, test program, register model) uses these macros.
 *
 * Sources (register behaviour fixed 2026-11-17, l4_axi.md "decided behaviour";
 * RTL: rtl/l4/pqc_ntt_csr.sv):
 *   docs/spec/l4_axi.md   "register map" table      offsets, fields
 *   rtl/l2/ntt_l2_pkg.sv  op_e                      op encoding
 *   rtl/pkg/mlkem_pkg.sv  algo_e                    ALGO encoding
 * fpga/sw/tools/check_regs.py parses the three files above and this header
 * and fails on any difference. Run it after every spec or RTL change.
 *
 * "An" numbers refer to fpga/sw/ASSUMPTIONS.md (each item marked there as
 * confirmed by l4_axi.md or still open).
 */
#ifndef PQC_NTT_REGS_H
#define PQC_NTT_REGS_H

/* ------------------------------------------------------------------------
 * Address map (A17, open: chosen here, not part of l4_axi.md). The Vivado block design script
 * (fpga/vivado/create_project.tcl, PQC_BASEADDR / PQC_RANGE) uses the same
 * values; check_regs.py compares them.
 * ------------------------------------------------------------------------ */
#define PQC_NTT_DEFAULT_BASEADDR 0x43C00000u
#define PQC_NTT_ADDR_RANGE       0x00001000u

/* ------------------------------------------------------------------------
 * Register offsets (bytes)
 * ------------------------------------------------------------------------ */
#define PQC_NTT_REG_CTRL    0x00u /* W    */
#define PQC_NTT_REG_STATUS  0x04u /* R    */
#define PQC_NTT_REG_DIN     0x08u /* W    */
#define PQC_NTT_REG_DOUT    0x0Cu /* R, read pops the output stream */
#define PQC_NTT_REG_CYCLES  0x10u /* R    */
#define PQC_NTT_REG_VERSION 0x14u /* R    */
#define PQC_NTT_REG_ERR     0x18u /* R/W1C */
#define PQC_NTT_REG_CONFIG  0x1Cu /* R, build parameters */

/* ------------------------------------------------------------------------
 * CTRL
 * ------------------------------------------------------------------------ */
#define PQC_NTT_CTRL_START_BIT  0
#define PQC_NTT_CTRL_OP_SHIFT   1
#define PQC_NTT_CTRL_OP_WIDTH   3
#define PQC_NTT_CTRL_BANK_BIT   4

#define PQC_NTT_CTRL_START_MASK (1u << PQC_NTT_CTRL_START_BIT)
#define PQC_NTT_CTRL_OP_MASK    (((1u << PQC_NTT_CTRL_OP_WIDTH) - 1u) << PQC_NTT_CTRL_OP_SHIFT)
#define PQC_NTT_CTRL_BANK_MASK  (1u << PQC_NTT_CTRL_BANK_BIT)

/* ------------------------------------------------------------------------
 * STATUS
 * ------------------------------------------------------------------------ */
#define PQC_NTT_STATUS_BUSY_BIT        0
#define PQC_NTT_STATUS_DONE_STICKY_BIT 1
#define PQC_NTT_STATUS_RESULT_BANK_BIT 2
#define PQC_NTT_STATUS_IN_READY_BIT    3
#define PQC_NTT_STATUS_OUT_VALID_BIT   4

#define PQC_NTT_STATUS_BUSY        (1u << PQC_NTT_STATUS_BUSY_BIT)
#define PQC_NTT_STATUS_DONE_STICKY (1u << PQC_NTT_STATUS_DONE_STICKY_BIT)
#define PQC_NTT_STATUS_RESULT_BANK (1u << PQC_NTT_STATUS_RESULT_BANK_BIT)
#define PQC_NTT_STATUS_IN_READY    (1u << PQC_NTT_STATUS_IN_READY_BIT)
#define PQC_NTT_STATUS_OUT_VALID   (1u << PQC_NTT_STATUS_OUT_VALID_BIT)

/* ------------------------------------------------------------------------
 * DIN / DOUT: coefficient in bits [11:0]
 * ------------------------------------------------------------------------ */
#define PQC_NTT_DIN_COEF_SHIFT  0
#define PQC_NTT_DIN_COEF_WIDTH  12
#define PQC_NTT_DOUT_COEF_SHIFT 0
#define PQC_NTT_DOUT_COEF_WIDTH 12
#define PQC_NTT_COEF_MASK       ((1u << PQC_NTT_DIN_COEF_WIDTH) - 1u)

/* ------------------------------------------------------------------------
 * VERSION
 * ------------------------------------------------------------------------ */
#define PQC_NTT_VERSION_ALGO_SHIFT        0
#define PQC_NTT_VERSION_ALGO_WIDTH        8
#define PQC_NTT_VERSION_BFU_LATENCY_SHIFT 8
#define PQC_NTT_VERSION_BFU_LATENCY_WIDTH 8
#define PQC_NTT_VERSION_ID_SHIFT          16
#define PQC_NTT_VERSION_ID_WIDTH          16
/* Fixed ID value (A13, confirmed: rtl/l4/pqc_ntt_csr.sv VERSION_ID). */
#define PQC_NTT_VERSION_ID_VALUE          0x4E54u

/* ------------------------------------------------------------------------
 * ERR (sticky, write 1 to clear)
 * ------------------------------------------------------------------------ */
#define PQC_NTT_ERR_START_BUSY_BIT 0 /* start written while busy (ignored)        */
#define PQC_NTT_ERR_DIN_BIT        1 /* DIN written while in_ready = 0 (dropped)  */
#define PQC_NTT_ERR_DOUT_BIT       2 /* DOUT read while out_valid = 0 (reads 0)   */
#define PQC_NTT_ERR_BAD_OP_BIT     3 /* start with an op outside enum pqc_ntt_op  */
#define PQC_NTT_ERR_DIN_RANGE_BIT  4 /* accepted DIN word with bits [11:0] >= q   */

#define PQC_NTT_ERR_START_BUSY (1u << PQC_NTT_ERR_START_BUSY_BIT)
#define PQC_NTT_ERR_DIN        (1u << PQC_NTT_ERR_DIN_BIT)
#define PQC_NTT_ERR_DOUT       (1u << PQC_NTT_ERR_DOUT_BIT)
#define PQC_NTT_ERR_BAD_OP     (1u << PQC_NTT_ERR_BAD_OP_BIT)
#define PQC_NTT_ERR_DIN_RANGE  (1u << PQC_NTT_ERR_DIN_RANGE_BIT)
#define PQC_NTT_ERR_ALL        (PQC_NTT_ERR_START_BUSY | PQC_NTT_ERR_DIN | PQC_NTT_ERR_DOUT | \
                                PQC_NTT_ERR_BAD_OP | PQC_NTT_ERR_DIN_RANGE)

/* ------------------------------------------------------------------------
 * CONFIG (build parameters of the bitstream, constant)
 * ------------------------------------------------------------------------ */
#define PQC_NTT_CONFIG_IMPL_BIT          0 /* 0 hand RTL, 1 HLS L0 datapath   */
#define PQC_NTT_CONFIG_SHARE_ADDSUB_BIT  1
#define PQC_NTT_CONFIG_ROM_OUT_REG_BIT   2
#define PQC_NTT_CONFIG_PRE_REG_BIT       3
#define PQC_NTT_CONFIG_MUL_REG_BIT       4
#define PQC_NTT_CONFIG_RED_PIPE_SHIFT    5
#define PQC_NTT_CONFIG_RED_PIPE_WIDTH    2
#define PQC_NTT_CONFIG_OUT_REG_BIT       7
#define PQC_NTT_CONFIG_FCLK_MHZ_SHIFT    16
#define PQC_NTT_CONFIG_FCLK_MHZ_WIDTH    8

/* ------------------------------------------------------------------------
 * op encoding (CTRL.op) = ntt_l2_pkg::op_e
 * ------------------------------------------------------------------------ */
enum pqc_ntt_op {
  PQC_NTT_OP_LOAD    = 0,
  PQC_NTT_OP_NTT     = 1,
  PQC_NTT_OP_INTT    = 2,
  PQC_NTT_OP_BASEMUL = 3,
  PQC_NTT_OP_UNLOAD  = 4
};
#define PQC_NTT_OP_COUNT 5

/* ------------------------------------------------------------------------
 * ALGO encoding (VERSION.ALGO) = mlkem_pkg::algo_e
 * ------------------------------------------------------------------------ */
enum pqc_ntt_algo {
  PQC_NTT_ALGO_BARRETT  = 0,
  PQC_NTT_ALGO_MONT12   = 1,
  PQC_NTT_ALGO_SHIFTADD = 2,
  PQC_NTT_ALGO_K2RED    = 3
};
#define PQC_NTT_ALGO_COUNT 4

/* ------------------------------------------------------------------------
 * Field helpers
 * ------------------------------------------------------------------------ */
#define PQC_NTT_FIELD_GET(val, shift, width) \
  (((val) >> (shift)) & ((1u << (width)) - 1u))

#define PQC_NTT_CTRL_VALUE(start, op, bank)                                   \
  ((((unsigned)(start) & 1u) << PQC_NTT_CTRL_START_BIT) |                     \
   (((unsigned)(op) << PQC_NTT_CTRL_OP_SHIFT) & PQC_NTT_CTRL_OP_MASK) |       \
   (((unsigned)(bank) & 1u) << PQC_NTT_CTRL_BANK_BIT))

#endif /* PQC_NTT_REGS_H */
