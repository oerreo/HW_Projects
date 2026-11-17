// zeta_rom: per-ALGO constant ROM of pqc-ntt-ip (L2).
//
// Contents (docs/spec/arch.md "decisions", golden mlkem::hw::rom_read, DPI
// mlkem_dpi_rom(algo, kind, index)):
//   kind_i = ROM_ZETA : zeta_i * S^-1 mod q          addr_i = zeta index 0..127
//   kind_i = ROM_GAMMA: gamma_i          (S = 1)     addr_i = pair index 0..127
//                       gamma_i * S^-2   (S != 1)
//   kind_i = ROM_K2   : K2 = S^-2 mod q              addr_i ignored
// S is the multiplier scale of ALGO (1, 2^-12, 1, 169).
//
// The tables are the packed constants of zeta_rom_pkg, generated from the
// golden-model dumps by rtl/l2/rom/gen_rom_pkg.py (no $readmemh, so the ROM
// is a plain constant mux for DC and for FPGA LUT ROM inference). Only the
// tables of the selected ALGO are referenced; the others are not built.
//
// Timing (parameter OUT_REG, LATENCY = OUT_REG):
//   OUT_REG = 1 (default): synchronous read. kind_i / addr_i sampled at the
//     rising edge when en_i = 1, data_o valid from the next cycle and held
//     while en_i = 0. The output register is a datapath register (no reset).
//   OUT_REG = 0: combinational read, data_o follows kind_i / addr_i in the
//     same cycle (en_i unused).
// Choice for ntt_core (ntt_ctrl ROM_LAT = LATENCY): 1 by default. With the
// 1-cycle coef_ram read, the ROM address is then issued in the same cycle as
// the RAM read addresses, and the ROM + kind mux path ends in a register
// instead of feeding the bfu multiplier operand directly. ntt_ctrl supports
// both values (ROM address issued RAM_LAT - ROM_LAT cycles after the RAM read).
module zeta_rom
  import mlkem_pkg::*;
  import ntt_l2_pkg::*;
#(
  parameter algo_e ALGO    = ALGO_BARRETT,  // reduction variant (selects the table set)
  parameter int    OUT_REG = 1              // 0: combinational read, 1: registered read
) (
  input  logic              clk,
  input  logic              rst_n,    // only used by simulation checks
  input  logic              en_i,     // read enable (OUT_REG = 1)
  input  rom_kind_e         kind_i,   // ROM_ZETA / ROM_GAMMA / ROM_K2
  input  logic [ROM_AW-1:0] addr_i,   // table address
  output logic [COEF_W-1:0] data_o    // [0, Q)
);

  localparam int LATENCY = OUT_REG;

  if (OUT_REG < 0 || OUT_REG > 1) begin : g_bad_out_reg
    $error("zeta_rom: OUT_REG=%0d not supported (0..1)", OUT_REG);
  end
  if (zeta_rom_pkg::ZR_DEPTH != ROM_DEPTH || zeta_rom_pkg::ZR_W != COEF_W) begin : g_bad_tbl
    $error("zeta_rom: generated table shape does not match ROM_DEPTH / COEF_W");
  end

  // Tables of this ALGO (constants).
  localparam logic [0:ROM_DEPTH-1][COEF_W-1:0] ZETA_T  = zeta_rom_pkg::ZETA_ROM_TBL[int'(ALGO)];
  localparam logic [0:ROM_DEPTH-1][COEF_W-1:0] GAMMA_T = zeta_rom_pkg::GAMMA_ROM_TBL[int'(ALGO)];
  localparam logic [COEF_W-1:0]                K2_C    = zeta_rom_pkg::K2_TBL[int'(ALGO)];

  logic [COEF_W-1:0] rd;

  always_comb begin
    unique case (kind_i)
      ROM_ZETA:  rd = ZETA_T[addr_i];
      ROM_GAMMA: rd = GAMMA_T[addr_i];
      default:   rd = K2_C;            // ROM_K2 (kind 3 is illegal, see check)
    endcase
  end

  if (OUT_REG == 1) begin : g_reg
    logic [COEF_W-1:0] data_q;
    // Datapath register, no reset: meaningful only after a read with en_i = 1.
    always_ff @(posedge clk) begin
      if (en_i) data_q <= rd;
    end
    assign data_o = data_q;
  end else begin : g_comb
    assign data_o = rd;
  end

`ifndef SYNTHESIS
  // kind 2'd3 is not a table. Checked on reads (en_i = 1; with OUT_REG = 0
  // the issuer still marks the cycles whose data it uses with en_i).
  always_comb begin
    if (rst_n === 1'b1 && en_i === 1'b1) begin
      kind_ok : assert final (!$isunknown({kind_i, addr_i}) && kind_i != 2'd3)
        else $error("L2_ROM_KIND zeta_rom: illegal read kind_i=%0d addr_i=%0d", kind_i, addr_i);
    end
  end
`endif

endmodule
