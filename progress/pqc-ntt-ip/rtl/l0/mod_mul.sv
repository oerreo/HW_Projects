// mod_mul: p_o = a_i * b_i * S mod Q, one 12b x 12b multiplier + mod_red.
//
// Structure (hierarchy.md): the plain product a * b (24 bit, written with '*'
// so synthesis maps it to a DSP block or an adder tree) followed by one
// instance of the mod_red wrapper with the same ALGO. No reduction logic is
// duplicated here; this module is the multiplier, an optional register and
// the wiring.
//
//   ALGO           S                  p_o
//   ALGO_BARRETT   1                  a * b mod Q
//   ALGO_MONT12    2^-12 (= 2704)     a * b * 2^-12 mod Q
//   ALGO_SHIFTADD  1                  a * b mod Q
//   ALGO_K2RED     169                a * b * 169 mod Q
// Golden counterpart: mlkem_dpi_<algo>_reduce(a * b), which is mul(b, z) of
// the golden bfu (model/include/mlkem_hw.h, docs/spec/arch.md). The scale S
// is not removed here (see mod_red.sv for where it is compensated).
//
// Domain: a_i, b_i in [0, Q). Then a * b <= (Q - 1)^2 = 11,075,584, which is
// below 2^24 (domain of BARRETT, SHIFTADD, K2RED) and below
// Q * 2^12 = 13,635,584 (domain of MONT12), so the product is always inside
// the mod_red domain of every variant. g_bad_dom checks this at elaboration.
// A simulation-only assertion (tag L0_RANGE) flags a_i or b_i outside [0, Q)
// or with unknown bits while valid_i is high.
//
// Pipelining (fixed latency, no backpressure; valid_o is valid_i delayed by
// LATENCY):
//   MUL_REG  = 0 : product goes to mod_red combinationally.
//   MUL_REG  = 1 : register after the multiplier (24-bit product + valid).
//   RED_PIPE      : PIPE of mod_red, 0..MOD_RED_PIPE_MAX (0: comb, 1: output
//                   reg, 2: variant mid reg + output reg).
//   LATENCY = MUL_REG + RED_PIPE (0..3).
// The two cut points are separate parameters (not one PIPE) so that every
// combination can be placed by the parent: e.g. LATENCY 1 is either a
// registered product (MUL_REG=1, RED_PIPE=0) or a registered output
// (MUL_REG=0, RED_PIPE=1).
// Control (valid) registers are reset; the product register is enabled by
// valid_i and not reset.
module mod_mul
  import mlkem_pkg::*;
#(
  parameter algo_e ALGO     = ALGO_BARRETT, // reduction variant
  parameter int    MUL_REG  = 0,            // 0: none, 1: register after the multiplier
  parameter int    RED_PIPE = 0             // PIPE of mod_red (0..MOD_RED_PIPE_MAX)
) (
  input  logic              clk,
  input  logic              rst_n,          // async assert, sync deassert
  input  logic [COEF_W-1:0] a_i,            // [0, Q)
  input  logic [COEF_W-1:0] b_i,            // [0, Q)
  input  logic              valid_i,
  output logic [COEF_W-1:0] p_o,            // a_i * b_i * S mod Q, [0, Q)
  output logic              valid_o
);

  localparam int LATENCY = MUL_REG + RED_PIPE;

  // --------------------------------------------------------------------------
  // Parameter and constant checks
  // --------------------------------------------------------------------------
  if (MUL_REG < 0 || MUL_REG > 1) begin : g_bad_mul_reg
    $error("mod_mul: MUL_REG=%0d not supported (0..1)", MUL_REG);
  end

  if (RED_PIPE < 0 || RED_PIPE > MOD_RED_PIPE_MAX) begin : g_bad_red_pipe
    $error("mod_mul: RED_PIPE=%0d not supported (0..%0d)", RED_PIPE, MOD_RED_PIPE_MAX);
  end

  if (longint'(Q - 1) * longint'(Q - 1) >= (longint'(Q) << 12)) begin : g_bad_dom
    $error("mod_mul: (Q-1)^2 exceeds the MONT12 domain Q*2^12");
  end

  // --------------------------------------------------------------------------
  // Multiplier
  // --------------------------------------------------------------------------
  logic [PROD_W-1:0] prod_a;            // a * b, <= (Q-1)^2

  always_comb begin
    prod_a = PROD_W'(a_i) * PROD_W'(b_i);
  end

  // --------------------------------------------------------------------------
  // Optional product register (MUL_REG = 1)
  // --------------------------------------------------------------------------
  logic [PROD_W-1:0] prod_b;
  logic              valid_b;

  if (MUL_REG == 1) begin : g_mul_reg
    logic [PROD_W-1:0] prod_q;
    logic              valid_q;

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) valid_q <= 1'b0;
      else        valid_q <= valid_i;
    end

    // Data register has no reset: it is qualified by valid_q.
    always_ff @(posedge clk) begin
      if (valid_i) prod_q <= prod_a;
    end

    assign prod_b  = prod_q;
    assign valid_b = valid_q;
  end else begin : g_no_mul_reg
    assign prod_b  = prod_a;
    assign valid_b = valid_i;
  end

  // --------------------------------------------------------------------------
  // Reduction (mod_red wrapper, same ALGO)
  // --------------------------------------------------------------------------
  mod_red #(
    .ALGO (ALGO),
    .PIPE (RED_PIPE)
  ) u_red (
    .clk     (clk),
    .rst_n   (rst_n),
    .x_i     (prod_b),
    .valid_i (valid_b),
    .r_o     (p_o),
    .valid_o (valid_o)
  );

  // --------------------------------------------------------------------------
  // Simulation-only input range check
  // --------------------------------------------------------------------------
`ifndef SYNTHESIS
  always_comb begin
    if (rst_n === 1'b1 && valid_i === 1'b1) begin
      a_input_range : assert final (!$isunknown({a_i, b_i}) && a_i < COEF_W'(Q)
                                    && b_i < COEF_W'(Q))
        else $error("L0_RANGE mod_mul: input out of [0, Q): a_i=%0d b_i=%0d", a_i, b_i);
    end
  end
`endif

endmodule
