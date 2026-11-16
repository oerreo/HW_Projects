// bfu: unified butterfly of pqc-ntt-ip (L1), CT and GS modes.
//
// Function (docs/spec/arch.md, "bfu interface" and "correction"; golden model
// mlkem::hw::bfu, DPI mlkem_dpi_bfu):
//   CT: t = mul(b, z);              x = add(a, t);   y = sub(a, t)
//   GS: s = add(a, b); d = sub(b, a); x = half(s);    y = half(mul(d, z))
//   mul(u, v) = u * v * S mod Q (mod_mul of the same ALGO; S = 1, 2^-12, 1, 169)
// GS subtracts in the order b - a (FIPS 203 Algorithm 10 line 10, arch.md
// correction of 2026-11-16).
//
// Built only from L0 instances (mod_add, mod_sub, mod_half, mod_mul) plus the
// operand / output muxes, the delay line and the stage registers of this
// level. All L0 instances use PIPE = 0; mod_mul gets MUL_REG and RED_PIPE.
//
// Pipeline (arch.md "bfu pipeline"):
//
//   a_i,b_i,z_i,mode_i
//      |
//   [pre]   GS: s = add(a, b), d = sub(b, a). CT: pass.
//           mul operand  u   = GS ? d : b
//           bypass       p   = GS ? s : a      (value that skips the multiply)
//      |    PRE_REG register (u, z, p, mode, valid)
//   [mul]   m = mod_mul(u, z)                  latency MUL_LAT = MUL_REG + RED_PIPE
//           p, mode follow on a MUL_LAT-deep delay line (13 bit per stage)
//      |
//   [post]  CT: x = add(p, m), y = sub(p, m)   (p = a, m = t)
//           GS: x = half(p),   y = half(m)     (p = s, m = mul(d, z))
//      |    OUT_REG register (x, y, valid)
//   x_o, y_o, valid_o
//
//   LATENCY = PRE_REG + MUL_REG + RED_PIPE + OUT_REG, the same for CT and GS.
//
// mod_add / mod_sub sharing (parameter SHARE_ADDSUB):
//   The arch.md text asks for one mod_add and one mod_sub shared by the GS pre
//   stage and the CT post stage through input muxes. The two uses sit in
//   different pipeline stages: a GS input issued at cycle c needs the pair at
//   cycle c (pre stage), a CT input issued at cycle c - D needs it at the same
//   cycle c (post stage), with D = PRE_REG + MUL_LAT. With a stream in which
//   the mode may change from one cycle to the next, both can occur in the same
//   cycle, so one shared pair cannot serve them. Sharing is therefore only
//   conditionally correct:
//     SHARE_ADDSUB = 0 (default): separate pairs. u_add_pre / u_sub_pre serve
//       GS, u_add_post / u_sub_post serve CT. 2 mod_add, 2 mod_sub, 2
//       mod_half, 1 mod_mul. No input muxes on the adders; any per-cycle mix
//       of CT and GS inputs is supported (no traffic constraint).
//     SHARE_ADDSUB = 1: one shared pair (1 mod_add, 1 mod_sub). Input muxes:
//         add inputs = sel_post ? (p_m, m) : (a_i, b_i)
//         sub inputs = sel_post ? (p_m, m) : (b_i, a_i)
//         sel_post   = valid at the post stage AND mode there is CT
//       Traffic constraint: a GS input must not be issued exactly D cycles
//       after a CT input. A sufficient rule for the controller: after a CT
//       input, issue the next GS input only after the pipeline has drained
//       (LATENCY or more idle cycles). The simulation-only assertion L1_SHARE
//       flags a violation. D = 0 is rejected at elaboration: the shared adder
//       output would feed its own input mux combinationally (add -> p -> add,
//       sub -> d -> mod_mul -> m -> sub), a structural combinational loop.
//
// Registers and reset (design-methodology.md):
//   valid bits of every stage are reset. Data registers (operands, bypass,
//   products, outputs) are not reset and load only when the valid of their
//   stage is 1. The mode bit that follows the data is treated as data, not
//   reset: it is read only through the output mux (whose result is qualified
//   by valid_o) and, with SHARE_ADDSUB = 1, through sel_post, which is
//   AND-ed with the stage valid. No logic depends on a mode bit whose valid
//   is 0, so resetting it would add reset fan-out without changing behavior.
//
// Interface rules:
//   a_i, b_i, z_i must be canonical [0, Q) while valid_i is high (mod_mul
//   MONT12 domain requires it). Simulation-only assertion tag L1_RANGE.
//   Fixed latency, no backpressure (no ready): the issuer guarantees the
//   schedule. Back-to-back valid and gaps are both supported. With
//   SHARE_ADDSUB = 0 the mode may change on every cycle.
module bfu
  import mlkem_pkg::*;
#(
  parameter algo_e ALGO         = ALGO_BARRETT, // reduction variant of mod_mul
  parameter int    PRE_REG      = 0,            // 0..1 register after the pre stage
  parameter int    MUL_REG      = 0,            // 0..1 mod_mul register after the multiplier
  parameter int    RED_PIPE     = 0,            // 0..MOD_RED_PIPE_MAX mod_red PIPE
  parameter int    OUT_REG      = 0,            // 0..1 output register
  parameter int    SHARE_ADDSUB = 0             // 0: separate pre/post add+sub, 1: shared (see above)
) (
  input  logic              clk,
  input  logic              rst_n,      // async assert, sync deassert
  input  mode_e             mode_i,     // MODE_CT / MODE_GS, may change per cycle if SHARE_ADDSUB = 0
  input  logic [COEF_W-1:0] a_i,        // [0, Q)
  input  logic [COEF_W-1:0] b_i,        // [0, Q)
  input  logic [COEF_W-1:0] z_i,        // [0, Q), twiddle / ROM constant / data
  input  logic              valid_i,    // no ready: fixed latency, no backpressure
  output logic [COEF_W-1:0] x_o,        // [0, Q)
  output logic [COEF_W-1:0] y_o,        // [0, Q)
  output logic              valid_o     // valid_i delayed by LATENCY
);

  localparam int MUL_LAT = MUL_REG + RED_PIPE;          // mod_mul LATENCY
  localparam int D_SHARE = PRE_REG + MUL_LAT;           // pre-to-post distance
  localparam int LATENCY = PRE_REG + MUL_LAT + OUT_REG;

  // --------------------------------------------------------------------------
  // Parameter checks
  // --------------------------------------------------------------------------
  if (PRE_REG < 0 || PRE_REG > 1) begin : g_bad_pre_reg
    $error("bfu: PRE_REG=%0d not supported (0..1)", PRE_REG);
  end
  if (MUL_REG < 0 || MUL_REG > 1) begin : g_bad_mul_reg
    $error("bfu: MUL_REG=%0d not supported (0..1)", MUL_REG);
  end
  if (RED_PIPE < 0 || RED_PIPE > MOD_RED_PIPE_MAX) begin : g_bad_red_pipe
    $error("bfu: RED_PIPE=%0d not supported (0..%0d)", RED_PIPE, MOD_RED_PIPE_MAX);
  end
  if (OUT_REG < 0 || OUT_REG > 1) begin : g_bad_out_reg
    $error("bfu: OUT_REG=%0d not supported (0..1)", OUT_REG);
  end
  if (SHARE_ADDSUB < 0 || SHARE_ADDSUB > 1) begin : g_bad_share
    $error("bfu: SHARE_ADDSUB=%0d not supported (0..1)", SHARE_ADDSUB);
  end
  if (SHARE_ADDSUB == 1 && D_SHARE == 0) begin : g_bad_share_comb
    $error("bfu: SHARE_ADDSUB=1 needs PRE_REG + MUL_REG + RED_PIPE >= 1 (combinational loop)");
  end

  // --------------------------------------------------------------------------
  // Signals
  // --------------------------------------------------------------------------
  logic              gs_i;              // input mode is GS
  // adder pair results seen by the pre stage (GS use)
  logic [COEF_W-1:0] s_pre;             // add(a, b)
  logic [COEF_W-1:0] d_pre;             // sub(b, a)
  // pre stage outputs
  logic [COEF_W-1:0] u_pre;             // mul operand
  logic [COEF_W-1:0] p_pre;             // bypass value
  // after PRE_REG (stage 1)
  logic [COEF_W-1:0] u_s1, z_s1, p_s1;
  mode_e             mode_s1;
  logic              valid_s1;
  // post stage inputs (after the mul / delay line)
  logic [COEF_W-1:0] m_m;               // mod_mul result
  logic              valid_m;           // mod_mul valid_o
  logic [COEF_W-1:0] p_m;               // delayed bypass
  mode_e             mode_m;            // delayed mode
  logic              gs_m;
  logic              sel_post;          // CT data present at the post stage
  // adder pair results seen by the post stage (CT use)
  logic [COEF_W-1:0] sum_post;          // add(p, m)
  logic [COEF_W-1:0] diff_post;         // sub(p, m)
  logic [COEF_W-1:0] hx_post;           // half(p)
  logic [COEF_W-1:0] hy_post;           // half(m)
  logic [COEF_W-1:0] x_post, y_post;

  assign gs_i     = (mode_i == MODE_GS);
  assign gs_m     = (mode_m == MODE_GS);
  assign sel_post = valid_m && !gs_m;

  // --------------------------------------------------------------------------
  // mod_add / mod_sub instances
  // --------------------------------------------------------------------------
  if (SHARE_ADDSUB == 0) begin : g_sep
    // Separate pairs, no input muxes. The valid_i of each L0 instance is the
    // stage valid AND-ed with the mode that uses it, so the L0 range checks
    // only look at values whose result is used. L0 valid_o (= valid_i with
    // PIPE = 0) is left open.
    mod_add #(.PIPE(0)) u_add_pre (
      .clk(clk), .rst_n(rst_n), .a_i(a_i), .b_i(b_i),
      .valid_i(valid_i && gs_i), .sum_o(s_pre), .valid_o()
    );
    mod_sub #(.PIPE(0)) u_sub_pre (
      .clk(clk), .rst_n(rst_n), .a_i(b_i), .b_i(a_i),       // GS: b - a
      .valid_i(valid_i && gs_i), .diff_o(d_pre), .valid_o()
    );
    mod_add #(.PIPE(0)) u_add_post (
      .clk(clk), .rst_n(rst_n), .a_i(p_m), .b_i(m_m),
      .valid_i(sel_post), .sum_o(sum_post), .valid_o()
    );
    mod_sub #(.PIPE(0)) u_sub_post (
      .clk(clk), .rst_n(rst_n), .a_i(p_m), .b_i(m_m),       // CT: a - t
      .valid_i(sel_post), .diff_o(diff_post), .valid_o()
    );
  end else begin : g_share
    // One shared pair. Input mux selects the CT post-stage operands when CT
    // data is at the post stage, else the GS pre-stage operands:
    //   add: (p_m, m_m) | (a_i, b_i)       sub: (p_m, m_m) | (b_i, a_i)
    // The same outputs are read by the pre stage (s, d) and the post stage
    // (CT x, y); each reader only uses them in its own mode.
    logic [COEF_W-1:0] add_a, add_b, sub_a, sub_b, add_r, sub_r;
    logic              use_v;

    always_comb begin
      add_a = sel_post ? p_m : a_i;
      add_b = sel_post ? m_m : b_i;
      sub_a = sel_post ? p_m : b_i;
      sub_b = sel_post ? m_m : a_i;
    end
    assign use_v = sel_post || (valid_i && gs_i);

    mod_add #(.PIPE(0)) u_add (
      .clk(clk), .rst_n(rst_n), .a_i(add_a), .b_i(add_b),
      .valid_i(use_v), .sum_o(add_r), .valid_o()
    );
    mod_sub #(.PIPE(0)) u_sub (
      .clk(clk), .rst_n(rst_n), .a_i(sub_a), .b_i(sub_b),
      .valid_i(use_v), .diff_o(sub_r), .valid_o()
    );

    assign s_pre     = add_r;
    assign d_pre     = sub_r;
    assign sum_post  = add_r;
    assign diff_post = sub_r;

`ifndef SYNTHESIS
    // Traffic constraint of the shared pair (see header).
    always_comb begin
      if (rst_n === 1'b1 && sel_post === 1'b1 && valid_i === 1'b1 && mode_i === MODE_GS) begin
        share_conflict : assert final (1'b0)
          else $error("L1_SHARE bfu: GS input issued while CT data uses the shared add/sub");
      end
    end
`endif
  end

  // --------------------------------------------------------------------------
  // Pre stage muxes and PRE_REG
  // --------------------------------------------------------------------------
  always_comb begin
    u_pre = gs_i ? d_pre : b_i;
    p_pre = gs_i ? s_pre : a_i;
  end

  if (PRE_REG == 1) begin : g_pre_reg
    logic [COEF_W-1:0] u_q, z_q, p_q;
    mode_e             mode_q;
    logic              valid_q;

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) valid_q <= 1'b0;
      else        valid_q <= valid_i;
    end

    // Data and mode registers have no reset: qualified by valid_q.
    always_ff @(posedge clk) begin
      if (valid_i) begin
        u_q    <= u_pre;
        z_q    <= z_i;
        p_q    <= p_pre;
        mode_q <= mode_i;
      end
    end

    assign u_s1     = u_q;
    assign z_s1     = z_q;
    assign p_s1     = p_q;
    assign mode_s1  = mode_q;
    assign valid_s1 = valid_q;
  end else begin : g_no_pre_reg
    assign u_s1     = u_pre;
    assign z_s1     = z_i;
    assign p_s1     = p_pre;
    assign mode_s1  = mode_i;
    assign valid_s1 = valid_i;
  end

  // --------------------------------------------------------------------------
  // Multiply stage
  // --------------------------------------------------------------------------
  mod_mul #(
    .ALGO     (ALGO),
    .MUL_REG  (MUL_REG),
    .RED_PIPE (RED_PIPE)
  ) u_mul (
    .clk     (clk),
    .rst_n   (rst_n),
    .a_i     (u_s1),
    .b_i     (z_s1),
    .valid_i (valid_s1),
    .p_o     (m_m),
    .valid_o (valid_m)
  );

  // Delay line for the bypass value and the mode, MUL_LAT stages. Stage k
  // loads from stage k-1 when the valid of stage k-1 is 1. The valid bits
  // here only provide those enables; the post-stage valid is valid_m from
  // mod_mul (checked equal to dl_v[MUL_LAT] in simulation).
  logic [COEF_W-1:0] dl_p [0:MUL_LAT];
  mode_e             dl_m [0:MUL_LAT];
  logic              dl_v [0:MUL_LAT];

  assign dl_p[0] = p_s1;
  assign dl_m[0] = mode_s1;
  assign dl_v[0] = valid_s1;

  for (genvar k = 1; k <= MUL_LAT; k++) begin : g_dl
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) dl_v[k] <= 1'b0;
      else        dl_v[k] <= dl_v[k-1];
    end

    always_ff @(posedge clk) begin
      if (dl_v[k-1]) begin
        dl_p[k] <= dl_p[k-1];
        dl_m[k] <= dl_m[k-1];
      end
    end
  end

  assign p_m    = dl_p[MUL_LAT];
  assign mode_m = dl_m[MUL_LAT];

  // --------------------------------------------------------------------------
  // Post stage: halvers and output mux
  // --------------------------------------------------------------------------
  mod_half #(.PIPE(0)) u_half_x (
    .clk(clk), .rst_n(rst_n), .x_i(p_m), .valid_i(valid_m && gs_m),
    .h_o(hx_post), .valid_o()
  );
  mod_half #(.PIPE(0)) u_half_y (
    .clk(clk), .rst_n(rst_n), .x_i(m_m), .valid_i(valid_m && gs_m),
    .h_o(hy_post), .valid_o()
  );

  always_comb begin
    x_post = gs_m ? hx_post : sum_post;
    y_post = gs_m ? hy_post : diff_post;
  end

  if (OUT_REG == 1) begin : g_out_reg
    logic [COEF_W-1:0] x_q, y_q;
    logic              valid_q;

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) valid_q <= 1'b0;
      else        valid_q <= valid_m;
    end

    // Data registers have no reset: qualified by valid_q.
    always_ff @(posedge clk) begin
      if (valid_m) begin
        x_q <= x_post;
        y_q <= y_post;
      end
    end

    assign x_o     = x_q;
    assign y_o     = y_q;
    assign valid_o = valid_q;
  end else begin : g_no_out_reg
    assign x_o     = x_post;
    assign y_o     = y_post;
    assign valid_o = valid_m;
  end

  // --------------------------------------------------------------------------
  // Simulation-only checks
  // --------------------------------------------------------------------------
`ifndef SYNTHESIS
  // Inputs must be canonical and known while valid_i is high.
  always_comb begin
    if (rst_n === 1'b1 && valid_i === 1'b1) begin
      in_range : assert final (!$isunknown({mode_i, a_i, b_i, z_i}) && a_i < COEF_W'(Q)
                               && b_i < COEF_W'(Q) && z_i < COEF_W'(Q))
        else $error("L1_RANGE bfu: input out of [0, Q): mode_i=%0d a_i=%0d b_i=%0d z_i=%0d",
                    mode_i, a_i, b_i, z_i);
    end
  end

  // The local delay line must stay aligned with mod_mul.
  always_comb begin
    if (rst_n === 1'b1) begin
      dl_align : assert final (dl_v[MUL_LAT] === valid_m)
        else $error("bfu: delay line valid %b != mod_mul valid_o %b", dl_v[MUL_LAT], valid_m);
    end
  end

  initial begin
    if (u_mul.LATENCY != MUL_LAT)
      $error("bfu: mod_mul.LATENCY=%0d != MUL_REG + RED_PIPE=%0d", u_mul.LATENCY, MUL_LAT);
  end
`endif

endmodule
