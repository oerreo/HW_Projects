// mod_red_k2red: r_o = 169 * x_i mod Q by K2-RED (Longa and Naehrig 2016).
//
// Q = k * 2^m + 1 with k = 13, m = 8, so k * 2^m = -1 (mod Q) and
// K-RED(C) = k * (C mod 2^m) - (C >> m) is congruent to k * C. Applying it
// twice gives k^2 * C = 169 * C. Structure matches the golden model
// k2red_reduce() (model/include/mlkem_modarith.h) with the same widths:
//   c0   = x[7:0]                     [7:0]
//   c1   = x >> 8                     [15:0]
//   r1   = 13 * c0 - c1               s17, [-65535, 3315]
//   r1_0 = r1[7:0]                    [7:0]
//   r1_1 = r1 >>> 8                   s9,  [-256, 12]
//   r2   = 13 * r1_0 - r1_1           s13, [-12, 3571]
//   d    = r2 - Q                     s13
//   out  = (r2 < 0) ? r2 + Q : (d < 0) ? r2 : d
//
// Output scale: the result carries the factor 169 (S = 169). It is not removed
// here: per docs/spec/arch.md the constant operand (zeta ROM) is pre-scaled
// by S^-1 = 169^-1 = 2285 mod Q, and data-by-data products in basemul are
// corrected by the K2 = S^-2 micro-op.
//
// Constant multiplications: 13 * c = (c << 3) + (c << 2) + c, written as
// shift-add as in the golden model, and merged with the subtraction into one
// 4-operand add/sub per K-RED step (17 bit, then 13 bit). The final
// correction computes r2 + Q and r2 - Q in parallel and selects with the
// signs of r2 and d.
//
// Domain: every x_i in [0, 2^24). A simulation-only assertion flags unknown
// (X/Z) input bits while valid_i is high; no 24-bit value is out of the domain.
//
// Pipelining (fixed latency LATENCY = PIPE, no backpressure):
//   PIPE = 0 : combinational.
//   PIPE = 1 : output register.
//   PIPE = 2 : mid register between the two K-RED steps (registers r1[16:0])
//              + output register.
// Control (valid) registers are reset; data registers are enabled by the
// valid of their stage and not reset.
module mod_red_k2red
  import mlkem_pkg::*;
#(
  parameter int PIPE = 0                // 0: comb, 1: output reg, 2: mid + output reg
) (
  input  logic              clk,
  input  logic              rst_n,      // async assert, sync deassert
  input  logic [PROD_W-1:0] x_i,        // [0, 2^24)
  input  logic              valid_i,
  output logic [COEF_W-1:0] r_o,        // 169 * x_i mod Q, [0, Q)
  output logic              valid_o
);

  localparam int     LATENCY = PIPE;

  localparam int     KRED_M = 8;                         // Q = 13 * 2^8 + 1
  localparam int     C1_W   = PROD_W - KRED_M;           // 16
  localparam int     R1_W   = 17;                        // r1, signed
  localparam int     R11_W  = R1_W - KRED_M;             // r1 >>> 8, signed (9)
  localparam int     R2_W   = 13;                        // r2 and d, signed
  localparam longint DOM_HI = longint'(1) << PROD_W;    // input domain [0, 2^24)

  if (13 * (1 << KRED_M) + 1 != Q) begin : g_bad_const
    $error("mod_red_k2red: Q != 13 * 2^8 + 1");
  end

  // --------------------------------------------------------------------------
  // Stage A: first K-RED step
  // --------------------------------------------------------------------------
  logic [KRED_M-1:0] c0_a;
  logic [C1_W-1:0]   c1_a;
  logic [R1_W-1:0]   r1_a;              // s17

  always_comb begin
    c0_a = x_i[KRED_M-1:0];
    c1_a = x_i[PROD_W-1:KRED_M];
    r1_a = R1_W'({c0_a, 3'b0}) + R1_W'({c0_a, 2'b0}) + R1_W'(c0_a) - R1_W'(c1_a);
  end

  // --------------------------------------------------------------------------
  // Optional mid register (PIPE = 2)
  // --------------------------------------------------------------------------
  logic [R1_W-1:0] r1_b;
  logic            valid_b;

  if (PIPE == 2) begin : g_mid
    logic [R1_W-1:0] r1_q;
    logic            valid_q;

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) valid_q <= 1'b0;
      else        valid_q <= valid_i;
    end

    always_ff @(posedge clk) begin
      if (valid_i) r1_q <= r1_a;
    end

    assign r1_b    = r1_q;
    assign valid_b = valid_q;
  end else begin : g_no_mid
    assign r1_b    = r1_a;
    assign valid_b = valid_i;
  end

  // --------------------------------------------------------------------------
  // Stage B: second K-RED step and the final +Q / -Q correction
  // --------------------------------------------------------------------------
  logic [KRED_M-1:0] r1_0_b;
  logic [R11_W-1:0]  r1_1_b;            // s9
  logic [R2_W-1:0]   r2_b;              // s13, [-12, 3571]
  logic [R2_W-1:0]   p_b;               // r2 + Q, used when r2 < 0
  logic [R2_W-1:0]   d_b;               // r2 - Q, s13
  logic [COEF_W-1:0] res_b;

  always_comb begin
    r1_0_b = r1_b[KRED_M-1:0];
    r1_1_b = r1_b[R1_W-1:KRED_M];
    r2_b   = R2_W'({r1_0_b, 3'b0}) + R2_W'({r1_0_b, 2'b0}) + R2_W'(r1_0_b)
           - {{(R2_W - R11_W){r1_1_b[R11_W-1]}}, r1_1_b};   // sign-extended r1_1
    p_b    = r2_b + R2_W'(Q);
    d_b    = r2_b - R2_W'(Q);
    if (r2_b[R2_W-1])     res_b = p_b[COEF_W-1:0];
    else if (d_b[R2_W-1]) res_b = r2_b[COEF_W-1:0];
    else                  res_b = d_b[COEF_W-1:0];
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
    $error("mod_red_k2red: PIPE=%0d not supported (0..%0d)", PIPE, MOD_RED_PIPE_MAX);
  end

  // --------------------------------------------------------------------------
  // Simulation-only input range check
  // --------------------------------------------------------------------------
`ifndef SYNTHESIS
  always_comb begin
    if (rst_n === 1'b1 && valid_i === 1'b1) begin
      a_input_range : assert final (!$isunknown(x_i) && longint'(x_i) < DOM_HI)
        else $error("L0_RANGE mod_red_k2red: input out of [0, 2^24): x_i=%0h", x_i);
    end
  end
`endif

endmodule
