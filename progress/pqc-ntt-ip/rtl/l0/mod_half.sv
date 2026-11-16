// mod_half: h_o = x_i * 2^-1 mod Q with one addition.
//
//   h = (x >> 1) + (x[0] ? (Q + 1) / 2 : 0)
// x even: 2h = x. x odd: 2h = (x - 1) + (Q + 1) = x + Q. So 2h mod Q == x.
// For x in [0, Q) the maximum is x = Q - 2 = 3327: 1663 + 1665 = 3328 < Q,
// so h is canonical and fits in COEF_W bits without a carry.
//
// Inputs must be canonical, x_i in [0, Q). Behavior for other inputs is
// undefined; a simulation-only assertion flags them while valid_i is high.
//
// Timing: fixed latency LATENCY = PIPE cycles, no backpressure. valid_o is
// valid_i delayed by LATENCY. PIPE = 0 is purely combinational (clk, rst_n
// unused except by the simulation assertion).
module mod_half
  import mlkem_pkg::*;
#(
  parameter int PIPE = 0                // 0: combinational, 1: output register
) (
  input  logic              clk,
  input  logic              rst_n,      // async assert, sync deassert
  input  logic [COEF_W-1:0] x_i,        // [0, Q)
  input  logic              valid_i,
  output logic [COEF_W-1:0] h_o,        // [0, Q), 2 * h_o mod Q == x_i
  output logic              valid_o
);

  localparam int LATENCY = PIPE;

  // --------------------------------------------------------------------------
  // Datapath
  // --------------------------------------------------------------------------
  logic [COEF_W-1:0] r;

  always_comb begin
    r = {1'b0, x_i[COEF_W-1:1]} + (x_i[0] ? COEF_W'(Q_INV2) : '0);
  end

  // --------------------------------------------------------------------------
  // Output stage
  // --------------------------------------------------------------------------
  if (PIPE == 0) begin : g_comb
    assign h_o     = r;
    assign valid_o = valid_i;
  end else if (PIPE == 1) begin : g_reg
    logic [COEF_W-1:0] h_q;
    logic              valid_q;

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) valid_q <= 1'b0;
      else        valid_q <= valid_i;
    end

    // Data register has no reset: it is qualified by valid_q.
    always_ff @(posedge clk) begin
      if (valid_i) h_q <= r;
    end

    assign h_o     = h_q;
    assign valid_o = valid_q;
  end else begin : g_bad_pipe
    $error("mod_half: PIPE=%0d not supported (0..%0d)", PIPE, L0_PIPE_MAX);
  end

  // --------------------------------------------------------------------------
  // Simulation-only input range check
  // --------------------------------------------------------------------------
`ifndef SYNTHESIS
  always_comb begin
    if (rst_n === 1'b1 && valid_i === 1'b1) begin
      a_input_range : assert final (x_i < COEF_W'(Q))
        else $error("L0_RANGE mod_half: input out of [0, Q): x_i=%0d", x_i);
    end
  end
`endif

endmodule
