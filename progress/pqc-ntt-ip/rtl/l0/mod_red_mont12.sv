// mod_red_mont12: r_o = x_i * 2^-12 mod Q by Montgomery reduction, R = 2^12.
//
// Structure matches the golden model mont12_reduce()
// (model/include/mlkem_modarith.h) step by step, with the same widths:
//   xl  = x mod 2^12                         [11:0]
//   t   = -(xl + (xl << 8) + (xl << 9))       [11:0]  = xl * q' mod 2^12,
//         mod 2^12                                     q' = -Q^-1 = 3327, Q^-1 = 769
//   tq  = t * Q                              [23:0]
//   s   = x + tq                             [24:0]  low 12 bits are 0
//   u   = s >> 12                            [12:0]  value in [0, 2Q)
//   d   = u - Q                              s14
//   out = (d < 0) ? u : d
// The golden model forms xl * 769 in a 32-bit integer and masks after the
// negation; only the low 12 bits reach t, so the 3-input sum is computed
// modulo 2^12 here (no golden width is declared for that sum).
//
// Output scale: the result carries the Montgomery factor R^-1 = 2^-12 mod Q
// (= 2704). It is not removed here: per docs/spec/arch.md the constant operand
// (zeta ROM) is pre-scaled by S^-1 = 2^12 mod Q, and data-by-data products in
// basemul are corrected by the K2 = S^-2 micro-op.
//
// Constant multiplications (both by shift-add, as in the golden model for q'):
//   xl * 769 : 769 = 2^9 + 2^8 + 1, 3-input adder on 12 bits, then negation.
//   t * Q    : Q = 2^11 + 2^10 + 2^8 + 1, 4-input adder on 24 bits. Same form
//              as qhat * Q in mod_red_barrett.
// The full 25-bit sum x + tq is kept as in the golden model (its low 12 bits
// are known to be zero; a carry-only shortcut is a possible later
// optimization, not done here to stay 1:1 with the model).
//
// Domain: x_i in [0, Q * 2^12) = [0, 13635584). This contains every product of
// two values in [0, Q). A simulation-only assertion flags x_i >= Q * 2^12 or
// unknown bits while valid_i is high.
//
// Pipelining (fixed latency LATENCY = PIPE, no backpressure):
//   PIPE = 0 : combinational.
//   PIPE = 1 : output register.
//   PIPE = 2 : mid register after t (the classic Montgomery split between the
//              quotient digit and the (x + t * Q) / R step; registers t[11:0]
//              and x[23:0]) + output register.
// Control (valid) registers are reset; data registers are enabled by the
// valid of their stage and not reset.
module mod_red_mont12
  import mlkem_pkg::*;
#(
  parameter int PIPE = 0                // 0: comb, 1: output reg, 2: mid + output reg
) (
  input  logic              clk,
  input  logic              rst_n,      // async assert, sync deassert
  input  logic [PROD_W-1:0] x_i,        // [0, Q * 2^12)
  input  logic              valid_i,
  output logic [COEF_W-1:0] r_o,        // x_i * 2^-12 mod Q, [0, Q)
  output logic              valid_o
);

  localparam int     LATENCY = PIPE;

  localparam int     R_LOG2  = 12;                        // R = 2^12
  localparam int     T_W     = 12;                        // xl, t
  localparam int     TQ_W    = 24;                        // t * Q
  localparam int     S_W     = 25;                        // x + t * Q
  localparam int     U_W     = 13;                        // s >> 12
  localparam int     D_W     = 14;                        // u - Q
  localparam longint DOM_HI  = longint'(Q) << R_LOG2;    // 13635584

  if (((Q * 769) % (1 << R_LOG2)) != 1 || Q != (1 << 11) + (1 << 10) + (1 << 8) + 1)
  begin : g_bad_const
    $error("mod_red_mont12: constants do not match the golden model");
  end

  // --------------------------------------------------------------------------
  // Stage A: quotient digit t = xl * q' mod 2^12
  // --------------------------------------------------------------------------
  logic [T_W-1:0] xl_a;
  logic [T_W-1:0] xl_qinv_a;            // xl * 769 mod 2^12
  logic [T_W-1:0] t_a;

  always_comb begin
    xl_a      = x_i[T_W-1:0];
    xl_qinv_a = xl_a + {xl_a[T_W-9:0], 8'b0} + {xl_a[T_W-10:0], 9'b0};
    t_a       = T_W'(0) - xl_qinv_a;
  end

  // --------------------------------------------------------------------------
  // Optional mid register (PIPE = 2)
  // --------------------------------------------------------------------------
  logic [T_W-1:0]    t_b;
  logic [PROD_W-1:0] x_b;
  logic              valid_b;

  if (PIPE == 2) begin : g_mid
    logic [T_W-1:0]    t_q;
    logic [PROD_W-1:0] x_q;
    logic              valid_q;

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) valid_q <= 1'b0;
      else        valid_q <= valid_i;
    end

    always_ff @(posedge clk) begin
      if (valid_i) begin
        t_q <= t_a;
        x_q <= x_i;
      end
    end

    assign t_b     = t_q;
    assign x_b     = x_q;
    assign valid_b = valid_q;
  end else begin : g_no_mid
    assign t_b     = t_a;
    assign x_b     = x_i;
    assign valid_b = valid_i;
  end

  // --------------------------------------------------------------------------
  // Stage B: u = (x + t * Q) / R and one conditional subtraction
  // --------------------------------------------------------------------------
  logic [TQ_W-1:0]   tq_b;
  logic [S_W-1:0]    s_b;
  logic [U_W-1:0]    u_b;               // [0, 2Q)
  logic [D_W-1:0]    d_b;               // u - Q, s14
  logic [COEF_W-1:0] res_b;

  always_comb begin
    tq_b  = TQ_W'({t_b, 11'b0}) + TQ_W'({t_b, 10'b0}) + TQ_W'({t_b, 8'b0}) + TQ_W'(t_b);
    s_b   = S_W'(x_b) + S_W'(tq_b);
    u_b   = s_b[R_LOG2 +: U_W];
    d_b   = D_W'(u_b) - D_W'(Q);
    // d < 0 means u < Q; otherwise d is in [0, Q).
    res_b = d_b[D_W-1] ? u_b[COEF_W-1:0] : d_b[COEF_W-1:0];
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
    $error("mod_red_mont12: PIPE=%0d not supported (0..%0d)", PIPE, MOD_RED_PIPE_MAX);
  end

  // --------------------------------------------------------------------------
  // Simulation-only input range check
  // --------------------------------------------------------------------------
`ifndef SYNTHESIS
  always_comb begin
    if (rst_n === 1'b1 && valid_i === 1'b1) begin
      a_input_range : assert final (!$isunknown(x_i) && longint'(x_i) < DOM_HI)
        else $error("L0_RANGE mod_red_mont12: input out of [0, Q*2^12): x_i=%0d", x_i);
    end
  end
`endif

endmodule
