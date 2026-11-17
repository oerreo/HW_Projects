// ntt_l2_pkg: types and constants shared by the L2 modules (zeta_rom,
// coef_ram, ntt_ctrl) and the L3 ntt_core datapath glue.
//
// Kept separate from rtl/pkg/mlkem_pkg.sv (common package, not modified by
// the L2 work). Encodings that cross into the golden model keep the DPI-C
// values (rom_kind_e = rom_kind argument of mlkem_dpi_rom).
package ntt_l2_pkg;
  import mlkem_pkg::*;

  localparam int N_COEF    = 256;               // coefficients per polynomial / bank depth
  localparam int RAM_AW    = $clog2(N_COEF);    // 8, coef_ram address width
  localparam int N_PAIR    = N_COEF / 2;        // 128 butterflies per layer, 128 basemul pairs
  localparam int ROM_DEPTH = 128;               // zeta / gamma ROM depth
  localparam int ROM_AW    = $clog2(ROM_DEPTH); // 7
  localparam int N_LAYER   = 7;                 // NTT / INTT layers (len 128 .. 2)

  // Largest bfu LATENCY = PRE_REG + MUL_REG + RED_PIPE + OUT_REG with every
  // parameter at its maximum (rtl/l1/bfu.sv parameter checks).
  localparam int BFU_LATENCY_MAX = 1 + 1 + MOD_RED_PIPE_MAX + 1;

  // ROM select, same values as the rom_kind argument of mlkem_dpi_rom().
  typedef enum logic [1:0] {
    ROM_ZETA  = 2'd0,   // zeta ROM, address = zeta index
    ROM_GAMMA = 2'd1,   // gamma ROM, address = pair index
    ROM_K2    = 2'd2    // constant K2 = S^-2, address ignored
  } rom_kind_e;

  // ntt_ctrl / ntt_core operation (start_i, op_i). The target bank is bank_i.
  typedef enum logic [2:0] {
    OP_LOAD    = 3'd0,  // stream in 256 coefficients to bank bank_i
    OP_NTT     = 3'd1,  // forward NTT, input bank bank_i, result bank ~bank_i
    OP_INTT    = 3'd2,  // inverse NTT, input bank bank_i, result bank ~bank_i
    OP_BASEMUL = 3'd3,  // a (bank0) x b (bank1) in the NTT domain, result bank0
    OP_UNLOAD  = 3'd4   // stream out the 256 coefficients of bank bank_i
  } op_e;

  // bfu input selects, decoded by the ntt_core datapath glue.
  //   RAM : read data of the bank given by ntt_ctrl rd_bank_o (a: port A, b: port B)
  //   A0, A1, B0, B1: basemul operand registers, R0, R1: basemul temporaries
  //   ROM : zeta_rom data_o (zeta, gamma or K2 by rom_kind_o)
  typedef enum logic [1:0] {
    ASEL_RAM  = 2'd0,
    ASEL_ZERO = 2'd1,
    ASEL_R0   = 2'd2
  } a_sel_e;

  typedef enum logic [2:0] {
    BSEL_RAM = 3'd0,
    BSEL_A0  = 3'd1,
    BSEL_A1  = 3'd2,
    BSEL_R0  = 3'd3,
    BSEL_R1  = 3'd4
  } b_sel_e;

  typedef enum logic [1:0] {
    ZSEL_ROM = 2'd0,
    ZSEL_B0  = 2'd1,
    ZSEL_B1  = 2'd2
  } z_sel_e;

  // coef_ram port A write data source (port B always writes bfu y_o).
  typedef enum logic {
    WSRC_BFU    = 1'b0,  // bfu x_o
    WSRC_STREAM = 1'b1   // input stream data (LOAD)
  } wsrc_e;

  // basemul micro-op count: 5 when the multiplier scale S = 1, else 7
  // (arch.md "basemul sequence", golden mlkem_dpi_basemul_nops).
  function automatic int basemul_nops(algo_e a);
    return (a == ALGO_BARRETT || a == ALGO_SHIFTADD) ? 5 : 7;
  endfunction

endpackage
