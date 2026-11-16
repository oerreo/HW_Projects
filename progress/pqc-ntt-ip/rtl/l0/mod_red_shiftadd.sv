// mod_red_shiftadd: r_o = x_i mod Q by q-specific shift-add folding.
//
// Q = 3329 gives 2^12 = 2^9 + 2^8 - 1 (mod Q). One fold maps
// y = h * 2^12 + l to (h << 9) + (h << 8) - h + l, which is congruent mod Q.
// Structure matches the golden model shiftadd_reduce()
// (model/include/mlkem_modarith.h), five folds with the same widths:
//   y1 = fold(x)   [21:0]  h = x[23:12]  (12 bit)
//   y2 = fold(y1)  [19:0]  h = y1[21:12] (10 bit)
//   y3 = fold(y2)  [16:0]  h = y2[19:12] (8 bit)
//   y4 = fold(y3)  [14:0]  h = y3[16:12] (5 bit)
//   y5 = fold(y4)  [13:0]  h = y4[14:12] (3 bit), value < 3Q
//   d1 = y5 - Q    s15
//   d2 = y5 - 2Q   s15
//   out = (d2 >= 0) ? d2 : (d1 >= 0) ? d1 : y5
// Each fold is computed modulo 2^(output width). The true fold value fits in
// that width (golden model bounds), so the modular sum is exact.
//
// Constant multiplications: none. Each fold is a 4-operand add/sub
// (h << 9, h << 8, -h, l) written explicitly, as in the golden model. The
// final step is two parallel subtractions (Q, 2Q) and a 3:1 select.
//
// Domain: every x_i in [0, 2^24). A simulation-only assertion flags unknown
// (X/Z) input bits while valid_i is high; no 24-bit value is out of the domain.
//
// Pipelining (fixed latency LATENCY = PIPE, no backpressure):
//   PIPE = 0 : combinational.
//   PIPE = 1 : output register.
//   PIPE = 2 : mid register after fold 3 (registers y3[16:0]; folds 1..3 in
//              the first stage, folds 4..5 and the final select in the second)
//              + output register.
// Control (valid) registers are reset; data registers are enabled by the
// valid of their stage and not reset.
module mod_red_shiftadd
  import mlkem_pkg::*;
#(
  parameter int PIPE = 0                // 0: comb, 1: output reg, 2: mid + output reg
) (
  input  logic              clk,
  input  logic              rst_n,      // async assert, sync deassert
  input  logic [PROD_W-1:0] x_i,        // [0, 2^24)
  input  logic              valid_i,
  output logic [COEF_W-1:0] r_o,        // x_i mod Q, [0, Q)
  output logic              valid_o
);

  localparam int     LATENCY = PIPE;

  localparam int     L_W    = 12;                        // low part of a fold
  localparam int     Y1_W   = 22;
  localparam int     Y2_W   = 20;
  localparam int     Y3_W   = 17;
  localparam int     Y4_W   = 15;
  localparam int     Y5_W   = 14;
  localparam int     D_W    = 15;                        // y5 - Q, y5 - 2Q
  localparam longint DOM_HI = longint'(1) << PROD_W;    // input domain [0, 2^24)

  if (((1 << 9) + (1 << 8) - 1) != ((1 << L_W) % Q)) begin : g_bad_const
    $error("mod_red_shiftadd: 2^12 mod Q != 2^9 + 2^8 - 1");
  end

  // --------------------------------------------------------------------------
  // Stage A: folds 1..3
  // --------------------------------------------------------------------------
  logic [PROD_W-L_W-1:0] h1_a;
  logic [Y1_W-L_W-1:0]   h2_a;
  logic [Y2_W-L_W-1:0]   h3_a;
  logic [Y1_W-1:0]       y1_a;
  logic [Y2_W-1:0]       y2_a;
  logic [Y3_W-1:0]       y3_a;

  always_comb begin
    h1_a = x_i[PROD_W-1:L_W];
    y1_a = Y1_W'({h1_a, 9'b0}) + Y1_W'({h1_a, 8'b0}) - Y1_W'(h1_a) + Y1_W'(x_i[L_W-1:0]);
    h2_a = y1_a[Y1_W-1:L_W];
    y2_a = Y2_W'({h2_a, 9'b0}) + Y2_W'({h2_a, 8'b0}) - Y2_W'(h2_a) + Y2_W'(y1_a[L_W-1:0]);
    h3_a = y2_a[Y2_W-1:L_W];
    y3_a = Y3_W'({h3_a, 9'b0}) + Y3_W'({h3_a, 8'b0}) - Y3_W'(h3_a) + Y3_W'(y2_a[L_W-1:0]);
  end

  // --------------------------------------------------------------------------
  // Optional mid register (PIPE = 2)
  // --------------------------------------------------------------------------
  logic [Y3_W-1:0] y3_b;
  logic            valid_b;

  if (PIPE == 2) begin : g_mid
    logic [Y3_W-1:0] y3_q;
    logic            valid_q;

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) valid_q <= 1'b0;
      else        valid_q <= valid_i;
    end

    always_ff @(posedge clk) begin
      if (valid_i) y3_q <= y3_a;
    end

    assign y3_b    = y3_q;
    assign valid_b = valid_q;
  end else begin : g_no_mid
    assign y3_b    = y3_a;
    assign valid_b = valid_i;
  end

  // --------------------------------------------------------------------------
  // Stage B: folds 4..5 and the final 3-way select
  // --------------------------------------------------------------------------
  logic [Y3_W-L_W-1:0] h4_b;
  logic [Y4_W-L_W-1:0] h5_b;
  logic [Y4_W-1:0]     y4_b;
  logic [Y5_W-1:0]     y5_b;            // < 3Q
  logic [D_W-1:0]      d1_b;            // y5 - Q, s15
  logic [D_W-1:0]      d2_b;            // y5 - 2Q, s15
  logic [COEF_W-1:0]   res_b;

  always_comb begin
    h4_b  = y3_b[Y3_W-1:L_W];
    y4_b  = Y4_W'({h4_b, 9'b0}) + Y4_W'({h4_b, 8'b0}) - Y4_W'(h4_b) + Y4_W'(y3_b[L_W-1:0]);
    h5_b  = y4_b[Y4_W-1:L_W];
    y5_b  = Y5_W'({h5_b, 9'b0}) + Y5_W'({h5_b, 8'b0}) - Y5_W'(h5_b) + Y5_W'(y4_b[L_W-1:0]);
    d1_b  = D_W'(y5_b) - D_W'(Q);
    d2_b  = D_W'(y5_b) - D_W'(2 * Q);
    // y5 < 3Q: exactly one of y5, d1, d2 is in [0, Q).
    if (!d2_b[D_W-1])      res_b = d2_b[COEF_W-1:0];
    else if (!d1_b[D_W-1]) res_b = d1_b[COEF_W-1:0];
    else                   res_b = y5_b[COEF_W-1:0];
  end

  // --------------------------------------------------------------------------
  // Output stage
  // --------------------------------------------------------------------------
  if (PIPE == 0) begin : g_comb
    assign r_o     = res_b;
    assign valid_o = valid_b;
  end else if (PIPE == 1 || PIPE == 2) begin : g_reg
    logic [COEF_W-1:0] r_q;
    logic              valid_q;

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) valid_q <= 1'b0;
      else        valid_q <= valid_b;
    end

    // Data register has no reset: it is qualified by valid_q.
    always_ff @(posedge clk) begin
      if (valid_b) r_q <= res_b;
    end

    assign r_o     = r_q;
    assign valid_o = valid_q;
  end else begin : g_bad_pipe
    $error("mod_red_shiftadd: PIPE=%0d not supported (0..%0d)", PIPE, MOD_RED_PIPE_MAX);
  end

  // --------------------------------------------------------------------------
  // Simulation-only input range check
  // --------------------------------------------------------------------------
`ifndef SYNTHESIS
  always_comb begin
    if (rst_n === 1'b1 && valid_i === 1'b1) begin
      a_input_range : assert final (!$isunknown(x_i) && longint'(x_i) < DOM_HI)
        else $error("L0_RANGE mod_red_shiftadd: input out of [0, 2^24): x_i=%0h", x_i);
    end
  end
`endif

endmodule
