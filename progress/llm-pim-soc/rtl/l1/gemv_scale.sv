// gemv_scale: one gemv output y = sat32(rshr(acc * wm * xm, sh)).
// Golden: model/src/kern.c k_gemv_out(S, xm, sh) with S = acc * wm (gs = n, stage A2,
// hierarchy.md 3.3). sh = we + xe - fo is formed by the caller.
//
//   S = acc * wm   : ACC_W x 16 (wm unsigned)  -> ACC_W + 16 bits
//   P = S * xm     : (ACC_W + 16) x 17 (xm unsigned) -> ACC_W + 33 bits (58 for ACC_W 25)
//   y = rshr_sat(P, sh), OUT_W 32, SAT_MODE 0 (= sat32(k_rshr(P, sh)))
// Pipeline (LATENCY = PIPE, 0..4):
//   PIPE >= 1: rshr_sat output register      PIPE >= 2: register after acc * wm
//   PIPE >= 3: register after S * xm         PIPE == 4: rshr_sat middle register too
// No backpressure (valid only).
module gemv_scale
  import llm_pkg::*;
#(
  parameter int ACC_W = 25,
  parameter int PIPE  = 3
) (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    valid_i,
  input  logic signed [ACC_W-1:0] acc_i,
  input  logic        [WM_W-1:0]  wm_i,
  input  logic        [AM_W-1:0]  xm_i,
  input  logic signed [SH_W-1:0]  sh_i,
  output logic                    valid_o,
  output logic signed [31:0]      y_o
);
  localparam int S_W     = ACC_W + WM_W;
  localparam int P_W     = S_W + AM_W;
  localparam int RS_PIPE = (PIPE >= 4) ? 2 : (PIPE >= 1 ? 1 : 0);
  localparam int LATENCY = PIPE;

  if (PIPE < 0 || PIPE > 4) $error("gemv_scale: PIPE=%0d must be 0..4", PIPE);
  if (ACC_W < 2 || P_W > 62) $error("gemv_scale: ACC_W=%0d must be 2..%0d", ACC_W, 62 - WM_W - AM_W);

  // ---- stage 1: S = acc * wm ----
  logic signed [S_W-1:0] s1;
  assign s1 = S_W'(acc_i) * S_W'($signed({1'b0, wm_i}));

  logic                  v2;
  logic signed [S_W-1:0] s2;
  logic        [AM_W-1:0] xm2;
  logic signed [SH_W-1:0] sh2;
  if (PIPE >= 2) begin : g_r1
    always_ff @(posedge clk or negedge rst_n)
      if (!rst_n) v2 <= 1'b0;
      else        v2 <= valid_i;
    always_ff @(posedge clk)
      if (valid_i) begin
        s2  <= s1;
        xm2 <= xm_i;
        sh2 <= sh_i;
      end
  end else begin : g_c1
    assign v2  = valid_i;
    assign s2  = s1;
    assign xm2 = xm_i;
    assign sh2 = sh_i;
  end

  // ---- stage 2: P = S * xm ----
  logic signed [P_W-1:0] p2;
  assign p2 = P_W'(s2) * P_W'($signed({1'b0, xm2}));

  logic                   v3;
  logic signed [P_W-1:0]  p3;
  logic signed [SH_W-1:0] sh3;
  if (PIPE >= 3) begin : g_r2
    always_ff @(posedge clk or negedge rst_n)
      if (!rst_n) v3 <= 1'b0;
      else        v3 <= v2;
    always_ff @(posedge clk)
      if (v2) begin
        p3  <= p2;
        sh3 <= sh2;
      end
  end else begin : g_c2
    assign v3  = v2;
    assign p3  = p2;
    assign sh3 = sh2;
  end

  // ---- stage 3: shift and saturate ----
  rshr_sat #(.IN_W(P_W), .OUT_W(32), .SAT_MODE(0), .PIPE(RS_PIPE)) u_rshr (
    .clk(clk), .rst_n(rst_n), .valid_i(v3), .x_i(p3), .sh_i(sh3),
    .valid_o(valid_o), .y_o(y_o));

endmodule
