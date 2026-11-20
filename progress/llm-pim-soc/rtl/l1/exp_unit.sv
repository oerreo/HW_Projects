// exp_unit: softmax numerator of one score (hierarchy.md 3.3). Golden: model/src/kern.c
// k_attn_exp(s, mx, 8, k_exp_lut(8)) (attn_core pass P2, arch.md 4.1):
//   d = s - mx, clamped below at -2^30
//   w = rshr(d * 47274, 15)          (47274 = round(log2(e) 2^15), Q16 exponent of 2)
//   e = k_exp2neg((uint32) -w)        (lut_lerp EXP2N)
// s <= mx is the use case (d <= 0); s > mx is computed like the golden (the 32-bit truncation
// of -w), so that the unit equals k_attn_exp for every 32-bit input pair.
// Widths: d in [-2^30, 2^32), d * 47274 fits 49 bits signed, w fits 35 bits.
//
// Pipeline (valid only): register after the product (always), rshr_sat PIPE RS_PIPE (0..2),
// lut_lerp PIPE LUT_PIPE (1..3). LATENCY = 1 + RS_PIPE + LUT_PIPE.
module exp_unit
  import llm_pkg::*;
#(
  parameter int RS_PIPE  = 1,
  parameter int LUT_PIPE = 2
) (
  input  logic               clk,
  input  logic               rst_n,
  input  logic               valid_i,
  input  logic signed [31:0] s_i,
  input  logic signed [31:0] mx_i,
  output logic               valid_o,
  output logic [16:0]        e_o
);
  localparam int LATENCY = 1 + RS_PIPE + LUT_PIPE;
  localparam logic signed [32:0] DMIN = -(33'sd1 <<< 30);

  // ---- d, clamp, product ----
  logic signed [32:0] d;
  logic signed [48:0] prod_q;
  logic               vm_q;
  assign d = (33'(s_i) - 33'(mx_i) < DMIN) ? DMIN : 33'(s_i) - 33'(mx_i);

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) vm_q <= 1'b0;
    else        vm_q <= valid_i;
  always_ff @(posedge clk)
    if (valid_i) prod_q <= 49'(d) * 49'sd47274;

  // ---- w = rshr(prod, 15) ----
  logic               vw;
  logic signed [39:0] w;
  rshr_sat #(.IN_W(49), .OUT_W(40), .SAT_MODE(0), .PIPE(RS_PIPE)) u_rs (
    .clk, .rst_n, .valid_i(vm_q), .x_i(prod_q), .sh_i(SH_W'(15)), .valid_o(vw), .y_o(w));

  // ---- e = 2^(-u / 2^16), u = (uint32) -w ----
  logic [31:0] u;
  assign u = 32'(-w);

  lut_lerp #(.FUNC(0), .PIPE(LUT_PIPE)) u_lut (
    .clk, .rst_n, .valid_i(vw), .u_i(u), .valid_o(valid_o), .y_o(e_o));

endmodule
