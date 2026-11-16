// mod_red_barrett: r_o = x_i mod Q by Barrett reduction with k = 24.
//
// Structure matches the golden model barrett_reduce()
// (model/include/mlkem_modarith.h) step by step, with the same widths:
//   xm   = x * M                 [36:0]  M = floor(2^24 / Q) = 5039 (13 bit)
//   qhat = xm >> 24              [12:0]  max 5038
//   qq   = (qhat * Q) mod 2^14   [13:0]  low 14 bits only
//   r    = (x - qq) mod 2^14     [13:0]  value in [0, 2Q)
//   d    = r - Q                 s14
//   out  = (d < 0) ? r : d
// qhat is floor(x/Q) or floor(x/Q) - 1, so r < 2Q < 2^14 and computing the
// subtraction on the low 14 bits is exact.
//
// Constant multiplications:
//   x * M    : written with '*'. M = 5039 has 9 set bits (CSD weight 5) and the
//              product is 24b x 13b; how it is mapped (LUT adder tree, CSD, or
//              a DSP block on FPGA) is left to synthesis, so the FPGA/ASIC
//              comparison sees the tool's choice for the one wide multiply.
//   qhat * Q : written as shift-add, Q = 2^11 + 2^10 + 2^8 + 1 (4 terms),
//              truncated to 14 bits. Q is treated the same way in every variant
//              that multiplies by Q (MONT12 uses the same form).
//
// Domain: every x_i in [0, 2^24) (covers any product of two 12-bit values).
// A simulation-only assertion flags unknown (X/Z) input bits while valid_i is
// high; no 24-bit value is out of the domain.
//
// Pipelining (fixed latency LATENCY = PIPE, no backpressure):
//   PIPE = 0 : combinational.
//   PIPE = 1 : output register.
//   PIPE = 2 : mid register after qhat (cut between the wide multiply and the
//              correction part; registers qhat[12:0] and x[13:0]) + output
//              register.
// Control (valid) registers are reset; data registers are enabled by the
// valid of their stage and not reset.
module mod_red_barrett
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

  localparam int LATENCY = PIPE;

  localparam int     BARRETT_K = 24;
  localparam int     BARRETT_M = (1 << BARRETT_K) / Q;   // 5039
  localparam int     XM_W      = 37;                     // x * M
  localparam int     QHAT_W    = 13;                     // qhat
  localparam int     R_W       = 14;                     // qq, r, d
  localparam longint DOM_HI    = longint'(1) << PROD_W;  // input domain [0, 2^24)

  if (BARRETT_M != 5039 || Q != (1 << 11) + (1 << 10) + (1 << 8) + 1) begin : g_bad_const
    $error("mod_red_barrett: constants do not match the golden model (M=%0d)", BARRETT_M);
  end

  // --------------------------------------------------------------------------
  // Stage A: quotient estimate (wide constant multiply)
  // --------------------------------------------------------------------------
  logic [XM_W-1:0]   xm_a;
  logic [QHAT_W-1:0] qhat_a;

  always_comb begin
    xm_a   = XM_W'(x_i) * XM_W'(BARRETT_M);
    qhat_a = xm_a[BARRETT_K +: QHAT_W];
  end

  // --------------------------------------------------------------------------
  // Optional mid register (PIPE = 2)
  // --------------------------------------------------------------------------
  logic [QHAT_W-1:0] qhat_b;
  logic [R_W-1:0]    xlo_b;             // x mod 2^14
  logic              valid_b;

  if (PIPE == 2) begin : g_mid
    logic [QHAT_W-1:0] qhat_q;
    logic [R_W-1:0]    xlo_q;
    logic              valid_q;

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) valid_q <= 1'b0;
      else        valid_q <= valid_i;
    end

    always_ff @(posedge clk) begin
      if (valid_i) begin
        qhat_q <= qhat_a;
        xlo_q  <= x_i[R_W-1:0];
      end
    end

    assign qhat_b  = qhat_q;
    assign xlo_b   = xlo_q;
    assign valid_b = valid_q;
  end else begin : g_no_mid
    assign qhat_b  = qhat_a;
    assign xlo_b   = x_i[R_W-1:0];
    assign valid_b = valid_i;
  end

  // --------------------------------------------------------------------------
  // Stage B: remainder and one conditional subtraction
  // --------------------------------------------------------------------------
  logic [R_W-1:0]    qq_b;              // (qhat * Q) mod 2^14
  logic [R_W-1:0]    r_b;               // [0, 2Q)
  logic [R_W-1:0]    d_b;               // r - Q, s14
  logic [COEF_W-1:0] res_b;

  always_comb begin
    qq_b  = R_W'({qhat_b, 11'b0}) + R_W'({qhat_b, 10'b0}) + R_W'({qhat_b, 8'b0})
          + R_W'(qhat_b);
    r_b   = xlo_b - qq_b;
    d_b   = r_b - R_W'(Q);
    // d < 0 means r < Q; otherwise d is in [0, Q).
    res_b = d_b[R_W-1] ? r_b[COEF_W-1:0] : d_b[COEF_W-1:0];
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
    $error("mod_red_barrett: PIPE=%0d not supported (0..%0d)", PIPE, MOD_RED_PIPE_MAX);
  end

  // --------------------------------------------------------------------------
  // Simulation-only input range check
  // --------------------------------------------------------------------------
`ifndef SYNTHESIS
  always_comb begin
    if (rst_n === 1'b1 && valid_i === 1'b1) begin
      a_input_range : assert final (!$isunknown(x_i) && longint'(x_i) < DOM_HI)
        else $error("L0_RANGE mod_red_barrett: input out of [0, 2^24): x_i=%0h", x_i);
    end
  end
`endif

endmodule
