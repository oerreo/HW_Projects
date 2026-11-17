// mod_red, Catapult HLS build: same module name, parameters, ports and
// LATENCY as rtl/l0/mod_red.sv, so tb/l0/tb_mod_red.sv runs unchanged with
// this file in place of the hand RTL (sim/tests/hls_l0_mod_red_*.cfg).
//
// This is an adapter, not a reduction: it instantiates one Catapult-generated
// module, hls/l0/out/mod_red_<algo>_<lib>_<cfg>/concat_rtl.v, selected by
// ALGO, PIPE and hls_l0_cfg_pkg::HLS_LIB, and adds only:
//   * wiring between the hand RTL port names and the Catapult port names,
//     connected with .* (a generated module that has no port of a given name,
//     e.g. no ccs_ccore_start, simply leaves that wire unused);
//   * ccs_ccore_en tied to 1 (the pipeline never stalls, as in the hand RTL);
//   * ccs_ccore_start driven by valid_i (when Catapult keeps this port it
//     gates the data registers of the first stage, like the valid-enabled
//     data registers of the hand RTL);
//   * valid_o: a delay line of LATENCY flops on valid_i, reset by rst_n.
//     The hand RTL has the same LATENCY valid flops; Catapult has no valid.
//   * a simulation-only input range assertion (tag L0_RANGE), same domain and
//     same rule as the hand RTL variants.
// In a QoR comparison, the generated module is the HLS datapath; the
// LATENCY valid flops belong to the adapter (the hand RTL has the same count).
//
//   PIPE  Catapult configuration          generated ports
//   0     c0: combinational CCORE         x, r
//   1     p1: sequential CCORE, latency 1 clk, rst_n, ccs_ccore_en,
//   2     p2: sequential CCORE, latency 2 [ccs_ccore_start_rsc_dat,] x_rsc_dat, r_rsc_z
// The generated latency equals PIPE for every configuration (Catapult rtl.rpt,
// hls/l0/report/), and the TB checks valid_o and r_o alignment against it.
// rst_n is a port of the sequential builds but drives no register there
// (RESET_CLEARS_ALL_REGS no); only the adapter valid flops are reset.
module mod_red
  import mlkem_pkg::*;
  import hls_l0_cfg_pkg::*;
#(
  parameter algo_e ALGO = ALGO_BARRETT, // reduction variant
  parameter int    PIPE = 0             // 0: comb, 1: latency 1, 2: latency 2
) (
  input  logic              clk,
  input  logic              rst_n,      // async assert, sync deassert
  input  logic [PROD_W-1:0] x_i,        // variant domain (see rtl/l0/mod_red.sv)
  input  logic              valid_i,
  output logic [COEF_W-1:0] r_o,        // x_i * S mod Q, [0, Q)
  output logic              valid_o
);

  localparam int LATENCY = PIPE;

  if (PIPE < 0 || PIPE > MOD_RED_PIPE_MAX) begin : g_bad_pipe
    $error("mod_red (HLS): PIPE=%0d not supported (0..%0d)", PIPE, MOD_RED_PIPE_MAX);
  end

  // --------------------------------------------------------------------------
  // Catapult port names
  // --------------------------------------------------------------------------
  logic [PROD_W-1:0] x;                 // c0
  logic [COEF_W-1:0] r;                 // c0
  logic [PROD_W-1:0] x_rsc_dat;         // p1, p2
  logic [COEF_W-1:0] r_rsc_z;           // p1, p2
  logic              ccs_ccore_en;
  logic              ccs_ccore_start_rsc_dat;

  assign x                       = x_i;
  assign x_rsc_dat               = x_i;
  assign ccs_ccore_en            = 1'b1;
  assign ccs_ccore_start_rsc_dat = valid_i;

  // --------------------------------------------------------------------------
  // Generated module (one per ALGO x PIPE x library)
  // --------------------------------------------------------------------------
  localparam string ALGO_NAME = (ALGO == ALGO_BARRETT)  ? "barrett"  :
                                (ALGO == ALGO_MONT12)   ? "mont12"   :
                                (ALGO == ALGO_SHIFTADD) ? "shiftadd" :
                                (ALGO == ALGO_K2RED)    ? "k2red"    : "?";

  if (HLS_LIB == "fpga") begin : g_fpga
    if      (ALGO == ALGO_BARRETT  && PIPE == 0) begin : g_i mod_red_barrett_fpga_c0  u_hls (.*); end
    else if (ALGO == ALGO_BARRETT  && PIPE == 1) begin : g_i mod_red_barrett_fpga_p1  u_hls (.*); end
    else if (ALGO == ALGO_BARRETT  && PIPE == 2) begin : g_i mod_red_barrett_fpga_p2  u_hls (.*); end
    else if (ALGO == ALGO_MONT12   && PIPE == 0) begin : g_i mod_red_mont12_fpga_c0   u_hls (.*); end
    else if (ALGO == ALGO_MONT12   && PIPE == 1) begin : g_i mod_red_mont12_fpga_p1   u_hls (.*); end
    else if (ALGO == ALGO_MONT12   && PIPE == 2) begin : g_i mod_red_mont12_fpga_p2   u_hls (.*); end
    else if (ALGO == ALGO_SHIFTADD && PIPE == 0) begin : g_i mod_red_shiftadd_fpga_c0 u_hls (.*); end
    else if (ALGO == ALGO_SHIFTADD && PIPE == 1) begin : g_i mod_red_shiftadd_fpga_p1 u_hls (.*); end
    else if (ALGO == ALGO_SHIFTADD && PIPE == 2) begin : g_i mod_red_shiftadd_fpga_p2 u_hls (.*); end
    else if (ALGO == ALGO_K2RED    && PIPE == 0) begin : g_i mod_red_k2red_fpga_c0    u_hls (.*); end
    else if (ALGO == ALGO_K2RED    && PIPE == 1) begin : g_i mod_red_k2red_fpga_p1    u_hls (.*); end
    else if (ALGO == ALGO_K2RED    && PIPE == 2) begin : g_i mod_red_k2red_fpga_p2    u_hls (.*); end
    else begin : g_none
      $error("mod_red (HLS): no fpga build for ALGO=%s PIPE=%0d", ALGO_NAME, PIPE);
    end
  end else if (HLS_LIB == "asic") begin : g_asic
    if      (ALGO == ALGO_BARRETT  && PIPE == 0) begin : g_i mod_red_barrett_asic_c0  u_hls (.*); end
    else if (ALGO == ALGO_BARRETT  && PIPE == 1) begin : g_i mod_red_barrett_asic_p1  u_hls (.*); end
    else if (ALGO == ALGO_BARRETT  && PIPE == 2) begin : g_i mod_red_barrett_asic_p2  u_hls (.*); end
    else if (ALGO == ALGO_MONT12   && PIPE == 0) begin : g_i mod_red_mont12_asic_c0   u_hls (.*); end
    else if (ALGO == ALGO_MONT12   && PIPE == 1) begin : g_i mod_red_mont12_asic_p1   u_hls (.*); end
    else if (ALGO == ALGO_MONT12   && PIPE == 2) begin : g_i mod_red_mont12_asic_p2   u_hls (.*); end
    else if (ALGO == ALGO_SHIFTADD && PIPE == 0) begin : g_i mod_red_shiftadd_asic_c0 u_hls (.*); end
    else if (ALGO == ALGO_SHIFTADD && PIPE == 1) begin : g_i mod_red_shiftadd_asic_p1 u_hls (.*); end
    else if (ALGO == ALGO_SHIFTADD && PIPE == 2) begin : g_i mod_red_shiftadd_asic_p2 u_hls (.*); end
    else if (ALGO == ALGO_K2RED    && PIPE == 0) begin : g_i mod_red_k2red_asic_c0    u_hls (.*); end
    else if (ALGO == ALGO_K2RED    && PIPE == 1) begin : g_i mod_red_k2red_asic_p1    u_hls (.*); end
    else if (ALGO == ALGO_K2RED    && PIPE == 2) begin : g_i mod_red_k2red_asic_p2    u_hls (.*); end
    else begin : g_none
      $error("mod_red (HLS): no asic build for ALGO=%s PIPE=%0d", ALGO_NAME, PIPE);
    end
  end else begin : g_bad_lib
    $error("mod_red (HLS): HLS_LIB=%s not supported", HLS_LIB);
  end

  if (PIPE == 0) begin : g_out_comb
    assign r_o = r;
  end else begin : g_out_seq
    assign r_o = r_rsc_z;
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
  // Simulation-only input range check (same domains as the hand RTL)
  // --------------------------------------------------------------------------
`ifndef SYNTHESIS
  localparam longint DOM_HI = (ALGO == ALGO_MONT12) ? (longint'(Q) << 12)
                                                    : (longint'(1) << PROD_W);
  always_comb begin
    if (rst_n === 1'b1 && valid_i === 1'b1) begin
      a_input_range : assert final (!$isunknown(x_i) && longint'(x_i) < DOM_HI)
        else $error("L0_RANGE mod_red (HLS) %s: input out of [0, %0d): x_i=%0h", ALGO_NAME,
                    DOM_HI, x_i);
    end
  end
`endif

endmodule
