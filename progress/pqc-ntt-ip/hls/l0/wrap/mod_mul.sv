// mod_mul, Catapult HLS build: same module name, parameters, ports and
// LATENCY as rtl/l0/mod_mul.sv, so tb/l0/tb_mod_mul.sv runs unchanged with
// this file in place of the hand RTL (sim/tests/hls_l0_mod_mul_*.cfg).
//
// This is an adapter, not a multiplier: it instantiates one Catapult-generated
// module, hls/l0/out/mod_mul_<algo>_<lib>_<cfg>/concat_rtl.v (the 12b x 12b
// product and the reduction in one HLS function), selected by ALGO, LATENCY
// and hls_l0_cfg_pkg::HLS_LIB, and adds only:
//   * wiring between the hand RTL port names and the Catapult port names,
//     connected with .* (absent Catapult ports leave their wire unused);
//   * ccs_ccore_en tied to 1 (the pipeline never stalls);
//   * ccs_ccore_start driven by valid_i (gates first-stage data registers
//     when Catapult keeps the port);
//   * valid_o: a delay line of LATENCY flops on valid_i, reset by rst_n
//     (the hand RTL has the same LATENCY valid flops);
//   * a simulation-only input range assertion (tag L0_RANGE), same rule as
//     the hand RTL.
//
// Parameters: MUL_REG and RED_PIPE keep the hand RTL ranges and error
// messages, and LATENCY = MUL_REG + RED_PIPE as there. The HLS build has no
// separate cut points: Catapult places the registers itself, so every
// (MUL_REG, RED_PIPE) pair with the same LATENCY selects the same build:
//   LATENCY 0: c0 (combinational CCORE)        ports a, b, p
//   LATENCY 1: p1 (sequential CCORE, latency 1) ports clk, rst_n, ccs_ccore_en,
//   LATENCY 2: p2 (sequential CCORE, latency 2) [ccs_ccore_start_rsc_dat,]
//                                               a_rsc_dat, b_rsc_dat, p_rsc_z
// LATENCY 3 (hand RTL MUL_REG = 1, RED_PIPE = 2) has no HLS build and fails
// elaboration. rst_n drives no register of the generated module
// (RESET_CLEARS_ALL_REGS no); only the adapter valid flops are reset.
module mod_mul
  import mlkem_pkg::*;
  import hls_l0_cfg_pkg::*;
#(
  parameter algo_e ALGO     = ALGO_BARRETT, // reduction variant
  parameter int    MUL_REG  = 0,            // 0..1 (same range as the hand RTL)
  parameter int    RED_PIPE = 0             // 0..MOD_RED_PIPE_MAX
) (
  input  logic              clk,
  input  logic              rst_n,          // async assert, sync deassert
  input  logic [COEF_W-1:0] a_i,            // [0, Q)
  input  logic [COEF_W-1:0] b_i,            // [0, Q)
  input  logic              valid_i,
  output logic [COEF_W-1:0] p_o,            // a_i * b_i * S mod Q, [0, Q)
  output logic              valid_o
);

  localparam int LATENCY     = MUL_REG + RED_PIPE;
  localparam int HLS_LAT_MAX = 2;

  if (MUL_REG < 0 || MUL_REG > 1) begin : g_bad_mul_reg
    $error("mod_mul: MUL_REG=%0d not supported (0..1)", MUL_REG);
  end

  if (RED_PIPE < 0 || RED_PIPE > MOD_RED_PIPE_MAX) begin : g_bad_red_pipe
    $error("mod_mul: RED_PIPE=%0d not supported (0..%0d)", RED_PIPE, MOD_RED_PIPE_MAX);
  end

  // --------------------------------------------------------------------------
  // Catapult port names
  // --------------------------------------------------------------------------
  logic [COEF_W-1:0] a, b;              // c0
  logic [COEF_W-1:0] p;                 // c0
  logic [COEF_W-1:0] a_rsc_dat;         // p1, p2
  logic [COEF_W-1:0] b_rsc_dat;         // p1, p2
  logic [COEF_W-1:0] p_rsc_z;           // p1, p2
  logic              ccs_ccore_en;
  logic              ccs_ccore_start_rsc_dat;

  assign a                       = a_i;
  assign b                       = b_i;
  assign a_rsc_dat               = a_i;
  assign b_rsc_dat               = b_i;
  assign ccs_ccore_en            = 1'b1;
  assign ccs_ccore_start_rsc_dat = valid_i;

  // --------------------------------------------------------------------------
  // Generated module (one per ALGO x LATENCY x library)
  // --------------------------------------------------------------------------
  localparam string ALGO_NAME = (ALGO == ALGO_BARRETT)  ? "barrett"  :
                                (ALGO == ALGO_MONT12)   ? "mont12"   :
                                (ALGO == ALGO_SHIFTADD) ? "shiftadd" :
                                (ALGO == ALGO_K2RED)    ? "k2red"    : "?";

  if (HLS_LIB == "fpga") begin : g_fpga
    if      (ALGO == ALGO_BARRETT  && LATENCY == 0) begin : g_i mod_mul_barrett_fpga_c0  u_hls (.*); end
    else if (ALGO == ALGO_BARRETT  && LATENCY == 1) begin : g_i mod_mul_barrett_fpga_p1  u_hls (.*); end
    else if (ALGO == ALGO_BARRETT  && LATENCY == 2) begin : g_i mod_mul_barrett_fpga_p2  u_hls (.*); end
    else if (ALGO == ALGO_MONT12   && LATENCY == 0) begin : g_i mod_mul_mont12_fpga_c0   u_hls (.*); end
    else if (ALGO == ALGO_MONT12   && LATENCY == 1) begin : g_i mod_mul_mont12_fpga_p1   u_hls (.*); end
    else if (ALGO == ALGO_MONT12   && LATENCY == 2) begin : g_i mod_mul_mont12_fpga_p2   u_hls (.*); end
    else if (ALGO == ALGO_SHIFTADD && LATENCY == 0) begin : g_i mod_mul_shiftadd_fpga_c0 u_hls (.*); end
    else if (ALGO == ALGO_SHIFTADD && LATENCY == 1) begin : g_i mod_mul_shiftadd_fpga_p1 u_hls (.*); end
    else if (ALGO == ALGO_SHIFTADD && LATENCY == 2) begin : g_i mod_mul_shiftadd_fpga_p2 u_hls (.*); end
    else if (ALGO == ALGO_K2RED    && LATENCY == 0) begin : g_i mod_mul_k2red_fpga_c0    u_hls (.*); end
    else if (ALGO == ALGO_K2RED    && LATENCY == 1) begin : g_i mod_mul_k2red_fpga_p1    u_hls (.*); end
    else if (ALGO == ALGO_K2RED    && LATENCY == 2) begin : g_i mod_mul_k2red_fpga_p2    u_hls (.*); end
    else begin : g_none
      $error("mod_mul (HLS): no fpga build for ALGO=%s LATENCY=%0d (0..%0d)", ALGO_NAME,
             LATENCY, HLS_LAT_MAX);
    end
  end else if (HLS_LIB == "asic") begin : g_asic
    if      (ALGO == ALGO_BARRETT  && LATENCY == 0) begin : g_i mod_mul_barrett_asic_c0  u_hls (.*); end
    else if (ALGO == ALGO_BARRETT  && LATENCY == 1) begin : g_i mod_mul_barrett_asic_p1  u_hls (.*); end
    else if (ALGO == ALGO_BARRETT  && LATENCY == 2) begin : g_i mod_mul_barrett_asic_p2  u_hls (.*); end
    else if (ALGO == ALGO_MONT12   && LATENCY == 0) begin : g_i mod_mul_mont12_asic_c0   u_hls (.*); end
    else if (ALGO == ALGO_MONT12   && LATENCY == 1) begin : g_i mod_mul_mont12_asic_p1   u_hls (.*); end
    else if (ALGO == ALGO_MONT12   && LATENCY == 2) begin : g_i mod_mul_mont12_asic_p2   u_hls (.*); end
    else if (ALGO == ALGO_SHIFTADD && LATENCY == 0) begin : g_i mod_mul_shiftadd_asic_c0 u_hls (.*); end
    else if (ALGO == ALGO_SHIFTADD && LATENCY == 1) begin : g_i mod_mul_shiftadd_asic_p1 u_hls (.*); end
    else if (ALGO == ALGO_SHIFTADD && LATENCY == 2) begin : g_i mod_mul_shiftadd_asic_p2 u_hls (.*); end
    else if (ALGO == ALGO_K2RED    && LATENCY == 0) begin : g_i mod_mul_k2red_asic_c0    u_hls (.*); end
    else if (ALGO == ALGO_K2RED    && LATENCY == 1) begin : g_i mod_mul_k2red_asic_p1    u_hls (.*); end
    else if (ALGO == ALGO_K2RED    && LATENCY == 2) begin : g_i mod_mul_k2red_asic_p2    u_hls (.*); end
    else begin : g_none
      $error("mod_mul (HLS): no asic build for ALGO=%s LATENCY=%0d (0..%0d)", ALGO_NAME,
             LATENCY, HLS_LAT_MAX);
    end
  end else begin : g_bad_lib
    $error("mod_mul (HLS): HLS_LIB=%s not supported", HLS_LIB);
  end

  if (LATENCY == 0) begin : g_out_comb
    assign p_o = p;
  end else begin : g_out_seq
    assign p_o = p_rsc_z;
  end

  // --------------------------------------------------------------------------
  // Adapter: valid delay line (control, reset)
  // --------------------------------------------------------------------------
  logic [LATENCY:0] valid_d;
  assign valid_d[0] = valid_i;

  for (genvar i = 1; i <= LATENCY; i++) begin : g_valid
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) valid_d[i] <= 1'b0;
      else        valid_d[i] <= valid_d[i - 1];
    end
  end

  assign valid_o = valid_d[LATENCY];

  // --------------------------------------------------------------------------
  // Simulation-only input range check (same rule as the hand RTL)
  // --------------------------------------------------------------------------
`ifndef SYNTHESIS
  always_comb begin
    if (rst_n === 1'b1 && valid_i === 1'b1) begin
      a_input_range : assert final (!$isunknown({a_i, b_i}) && a_i < COEF_W'(Q)
                                    && b_i < COEF_W'(Q))
        else $error("L0_RANGE mod_mul (HLS) %s: input out of [0, Q): a_i=%0d b_i=%0d",
                    ALGO_NAME, a_i, b_i);
    end
  end
`endif

endmodule
