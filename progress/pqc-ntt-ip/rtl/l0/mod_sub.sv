// mod_sub: diff_o = (a_i - b_i) mod Q with one conditional addition.
//
// Structure matches the golden model mod_sub_hw() (model/include/mlkem_modarith.h):
//   d = a - b        (13 bit two's complement, [-3328, 3328])
//   c = d + Q        (13 bit, used only when d < 0, then c in [1, Q))
//   r = (d < 0) ? c : d
//
// Inputs must be canonical, a_i, b_i in [0, Q). Behavior for other inputs is
// undefined; a simulation-only assertion flags them while valid_i is high.
//
// Timing: fixed latency LATENCY = PIPE cycles, no backpressure. valid_o is
// valid_i delayed by LATENCY. PIPE = 0 is purely combinational (clk, rst_n
// unused except by the simulation assertion).
module mod_sub
  import mlkem_pkg::*;
#(
  parameter int PIPE = 0                // 0: combinational, 1: output register
) (
  input  logic              clk,
  input  logic              rst_n,      // async assert, sync deassert
  input  logic [COEF_W-1:0] a_i,        // [0, Q)
  input  logic [COEF_W-1:0] b_i,        // [0, Q)
  input  logic              valid_i,
  output logic [COEF_W-1:0] diff_o,     // [0, Q)
  output logic              valid_o
);

  localparam int LATENCY = PIPE;

  // --------------------------------------------------------------------------
  // Datapath
  // --------------------------------------------------------------------------
  logic [COEF_W:0]   d;                 // a - b, 13 bit signed
  logic [COEF_W:0]   c;                 // d + Q, 13 bit (mod 2^13)
  logic [COEF_W-1:0] r;

  always_comb begin
    d = {1'b0, a_i} - {1'b0, b_i};
    c = d + (COEF_W + 1)'(Q);
    // d >= 0: d in [0, Q). d < 0: c = d + Q in [1, Q).
    r = d[COEF_W] ? c[COEF_W-1:0] : d[COEF_W-1:0];
  end

  // --------------------------------------------------------------------------
  // Output stage
  // --------------------------------------------------------------------------
  if (PIPE == 0) begin : g_comb
    assign diff_o  = r;
    assign valid_o = valid_i;
  end else if (PIPE == 1) begin : g_reg
    logic [COEF_W-1:0] diff_q;
    logic              valid_q;

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) valid_q <= 1'b0;
      else        valid_q <= valid_i;
    end

    // Data register has no reset: it is qualified by valid_q.
    always_ff @(posedge clk) begin
      if (valid_i) diff_q <= r;
    end

    assign diff_o  = diff_q;
    assign valid_o = valid_q;
  end else begin : g_bad_pipe
    $error("mod_sub: PIPE=%0d not supported (0..%0d)", PIPE, L0_PIPE_MAX);
  end

  // --------------------------------------------------------------------------
  // Simulation-only input range check
  // --------------------------------------------------------------------------
`ifndef SYNTHESIS
  always_comb begin
    if (rst_n === 1'b1 && valid_i === 1'b1) begin
      a_input_range : assert final (a_i < COEF_W'(Q) && b_i < COEF_W'(Q))
        else $error("L0_RANGE mod_sub: input out of [0, Q): a_i=%0d b_i=%0d", a_i, b_i);
    end
  end
`endif

endmodule
