// rshr_sat: round-half-up arithmetic right shift (negative shift: saturating left shift)
// followed by output saturation. Golden: model/src/kern.c k_rshr, k_sat32
// (docs/spec/arch.md 6, hierarchy.md 3.2).
//
//   sh > 0  : floor((x + 2^(sh-1)) / 2^sh); 0 if sh >= IN_W (golden: s >= 62 -> 0; for
//             |x| < 2^(IN_W-1) <= 2^61 both give 0 for every sh >= IN_W)
//   sh == 0 : x
//   sh < 0  : x * 2^-sh, saturated
// Output saturation:
//   SAT_MODE 0: to the OUT_W two's complement range [-2^(OUT_W-1), 2^(OUT_W-1)-1]
//               (OUT_W 32 = sat32(k_rshr(x, sh)); golden's +-I64MAX of a left-shift
//               overflow saturates to the same OUT_W bounds for OUT_W <= 63)
//   SAT_MODE 1: the 64-bit k_rshr rule, OUT_W must be 64: symmetric +-I64MAX
//               (= +-(2^63-1)), and every nonzero x with sh <= -62 saturates (golden
//               branch "s <= -62"), even where x * 2^-sh would fit (x = +-1, sh = -62)
// IN_W <= 62 keeps every input inside the golden precondition |x| < 2^61 of the
// right shift.
//
// Pipeline: PIPE 0 combinational, 1 output register, 2 register after the shift stage
// and at the output. LATENCY = PIPE. No backpressure (valid only).
module rshr_sat
  import llm_pkg::*;
#(
  parameter int IN_W     = 58,
  parameter int OUT_W    = 32,
  parameter int SAT_MODE = 0,
  parameter int PIPE     = 1
) (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    valid_i,
  input  logic signed [IN_W-1:0]  x_i,
  input  logic signed [SH_W-1:0]  sh_i,
  output logic                    valid_o,
  output logic signed [OUT_W-1:0] y_o
);
  localparam int LATENCY = PIPE;

  // ---- parameter checks (elaboration) ----
  if (IN_W < 2 || IN_W > 62)
    $error("rshr_sat: IN_W=%0d must be 2..62 (golden precondition |x| < 2^61)", IN_W);
  if (PIPE < 0 || PIPE > 2) $error("rshr_sat: PIPE=%0d must be 0..2", PIPE);
  if (SAT_MODE == 0 && (OUT_W < 2 || OUT_W > 63))
    $error("rshr_sat: OUT_W=%0d must be 2..63 for SAT_MODE 0", OUT_W);
  if (SAT_MODE == 1 && OUT_W != 64)
    $error("rshr_sat: OUT_W=%0d must be 64 for SAT_MODE 1", OUT_W);
  if (SAT_MODE != 0 && SAT_MODE != 1) $error("rshr_sat: SAT_MODE=%0d must be 0 or 1", SAT_MODE);

  // left shifts of LS_LIM or more saturate every nonzero x
  localparam int LS_LIM = (SAT_MODE == 1) ? 62 : OUT_W;
  localparam int WIDE_W = IN_W + LS_LIM;
  localparam int LS_W   = $clog2(LS_LIM);
  localparam int RS_W   = $clog2(IN_W);
  localparam int HB     = (SAT_MODE == 1) ? 63 : OUT_W - 1;
  localparam logic signed [WIDE_W-1:0] HI = {{(WIDE_W - HB){1'b0}}, {HB{1'b1}}};
  localparam logic signed [WIDE_W-1:0] LO = (SAT_MODE == 1) ? -HI : ~HI;

  // ---- stage 1: shift ----
  logic                    is_r, is_l, r_zero, l_big;
  logic [SH_W-1:0]         ls;          // -sh as unsigned (512 for sh = -512)
  logic [RS_W-1:0]         rs_m1;       // sh - 1 for 0 < sh < IN_W
  logic signed [IN_W-1:0]  rs_t;
  logic signed [IN_W:0]    rs_r;
  logic signed [WIDE_W-1:0] v1;
  logic                    big1, neg1;

  always_comb begin
    is_r   = sh_i > 0;
    is_l   = sh_i < 0;
    ls     = -sh_i;
    r_zero = is_r && (sh_i >= IN_W);
    l_big  = is_l && (ls >= LS_LIM);
    rs_m1  = RS_W'(sh_i - 1);
    // floor((x + 2^(s-1)) / 2^s) = floor((floor(x / 2^(s-1)) + 1) / 2)
    rs_t   = x_i >>> rs_m1;
    rs_r   = ($signed({rs_t[IN_W-1], rs_t}) + (IN_W + 1)'(1)) >>> 1;
    if (is_r)      v1 = r_zero ? '0 : WIDE_W'(rs_r);
    else if (is_l) v1 = l_big ? '0 : (WIDE_W'(x_i) <<< ls[LS_W-1:0]);
    else           v1 = WIDE_W'(x_i);
    big1 = l_big && (x_i != '0);
    neg1 = x_i[IN_W-1];
  end

  // optional register between the stages (PIPE 2)
  logic                     v2_valid, big2, neg2;
  logic signed [WIDE_W-1:0] v2;
  if (PIPE >= 2) begin : g_mid
    logic                     vq;
    logic                     bq, nq;
    logic signed [WIDE_W-1:0] dq;
    always_ff @(posedge clk or negedge rst_n)
      if (!rst_n) vq <= 1'b0;
      else        vq <= valid_i;
    always_ff @(posedge clk)
      if (valid_i) begin
        dq <= v1;
        bq <= big1;
        nq <= neg1;
      end
    assign v2_valid = vq;
    assign v2       = dq;
    assign big2     = bq;
    assign neg2     = nq;
  end else begin : g_nomid
    assign v2_valid = valid_i;
    assign v2       = v1;
    assign big2     = big1;
    assign neg2     = neg1;
  end

  // ---- stage 2: saturate ----
  logic signed [OUT_W-1:0] y2;
  always_comb begin
    if (big2 ? !neg2 : (v2 > HI))     y2 = HI[OUT_W-1:0];
    else if (big2 ? neg2 : (v2 < LO)) y2 = LO[OUT_W-1:0];
    else                              y2 = v2[OUT_W-1:0];
  end

  if (PIPE >= 1) begin : g_out
    logic                    vq;
    logic signed [OUT_W-1:0] yq;
    always_ff @(posedge clk or negedge rst_n)
      if (!rst_n) vq <= 1'b0;
      else        vq <= v2_valid;
    always_ff @(posedge clk)
      if (v2_valid) yq <= y2;
    assign valid_o = vq;
    assign y_o     = yq;
  end else begin : g_noout
    assign valid_o = v2_valid;
    assign y_o     = y2;
  end

endmodule
