// swi_front: SWIGLU front end (hierarchy.md 3.3, arch.md 5.3). Golden: model/src/kern.c
// swiglu_one of k_swiglu_st (stage trace A5: g before quantization); the quantizer is actq_core
// (f = K_FX = 16, qmax = 127), which takes the g stream.
//
//   s    = k_sigmoid(h1, 8, k_sig_lut(8))         (lut_lerp FUNC SIGM, LATENCY LUT_PIPE)
//   silu = rshr(h1 s, 16)                          (h1 s: 32 x 17 bits; silu fits int32:
//                                                   rshr((2^31 - 1) 2^16, 16) = 2^31 - 1,
//                                                   rshr(-2^31 2^16, 16) = -2^31)
//   g    = sat32(rshr(silu h3, 16))                (silu h3 in [-2^31 (2^31 - 1), 2^62]: the
//                                                   64-bit product is clamped to the 62-bit input
//                                                   range of rshr_sat first; a clamped value
//                                                   gives |rshr| >= 2^45 and saturates to the same
//                                                   sat32 bound, so the result is exact)
// One call (start_i, n_i sampled in the start cycle). Element stream e_valid_i / e_ready_o / e_i:
// the first n elements are h1, the next n are h3.
//   A   take h1[i] (one per cycle), silu[i] -> buffer[i] (external RAM port, read latency 1)
//   AW  wait until all n silu are written (the pipeline is LUT_PIPE + 2 deep)
//   B   take h3[i], read silu[i] in the same cycle; g[i] -> g stream (valid only, LATENCY 3)
// e_ready_o = 1 in A and B. The g stream has no backpressure (actq_core in LOAD takes every g).
// done_o: 1-cycle pulse after the last g; busy_o from the start to done.
// Simulation-only checks: L1_START, L1_CFG (n 0 or > N_MAX), VR_X.
module swi_front
  import llm_pkg::*;
#(
  parameter int N_MAX    = 1024,
  parameter int LUT_PIPE = 2,
  localparam int NW      = $clog2(N_MAX + 1),
  localparam int AW      = (N_MAX > 1) ? $clog2(N_MAX) : 1
) (
  input  logic          clk,
  input  logic          rst_n,
  input  logic          start_i,
  input  logic [NW-1:0] n_i,
  // element stream: h1 then h3
  input  logic          e_valid_i,
  output logic          e_ready_o,
  input  logic [31:0]   e_i,
  // buffer port (ram_sdp, RD_LAT 1)
  output logic          b_we_o,
  output logic [AW-1:0] b_waddr_o,
  output logic [31:0]   b_wdata_o,
  output logic          b_re_o,
  output logic [AW-1:0] b_raddr_o,
  input  logic [31:0]   b_rdata_i,
  // g stream (no backpressure)
  output logic          g_valid_o,
  output logic [31:0]   g_o,
  output logic          busy_o,
  output logic          done_o
);
  if (N_MAX < 2 || N_MAX > 65536) $error("swi_front: N_MAX=%0d must be 2..65536", N_MAX);

  typedef enum logic [2:0] {W_IDLE, W_A, W_AW, W_B, W_BW, W_FIN} st_t;
  st_t st_q;

  logic [NW-1:0] n_q, icnt_q, wcnt_q, gcnt_q;
  logic          go, take, done_q;

  assign go        = start_i && (st_q == W_IDLE || done_q);
  assign e_ready_o = st_q == W_A || st_q == W_B;
  assign take      = e_valid_i && e_ready_o;

  // ---------------- A: silu ----------------
  logic        ta;
  assign ta = take && st_q == W_A;

  logic        s_valid;
  logic [16:0] s;
  lut_lerp #(.FUNC(1), .PIPE(LUT_PIPE)) u_sig (
    .clk, .rst_n, .valid_i(ta), .u_i(e_i), .valid_o(s_valid), .y_o(s));

  // h1 delayed by LUT_PIPE (valid with s)
  logic signed [31:0] h1_d [LUT_PIPE];
  always_ff @(posedge clk) begin
    h1_d[0] <= e_i;
    for (int i = 1; i < LUT_PIPE; i++) h1_d[i] <= h1_d[i-1];
  end

  logic               pa_v_q;
  logic signed [49:0] pa_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) pa_v_q <= 1'b0;
    else        pa_v_q <= s_valid;
  always_ff @(posedge clk)
    if (s_valid) pa_q <= h1_d[LUT_PIPE-1] * $signed({1'b0, s});

  logic               silu_v;
  logic signed [31:0] silu;
  rshr_sat #(.IN_W(50), .OUT_W(32), .SAT_MODE(0), .PIPE(1)) u_silu (
    .clk, .rst_n, .valid_i(pa_v_q), .x_i(pa_q), .sh_i(SH_W'(16)), .valid_o(silu_v), .y_o(silu));

  assign b_we_o    = silu_v;
  assign b_waddr_o = AW'(wcnt_q);
  assign b_wdata_o = silu;

  // ---------------- B: g ----------------
  logic tb;
  assign tb        = take && st_q == W_B;
  assign b_re_o    = tb;
  assign b_raddr_o = AW'(icnt_q);

  logic               v1_q, v2_q;
  logic signed [31:0] h3_q;
  logic signed [63:0] pb_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      v1_q <= 1'b0;
      v2_q <= 1'b0;
    end else begin
      v1_q <= tb;
      v2_q <= v1_q;
    end
  always_ff @(posedge clk) begin
    if (tb) h3_q <= e_i;
    if (v1_q) pb_q <= $signed(b_rdata_i) * h3_q;
  end

  localparam logic signed [63:0] PMAX = 64'sh1FFF_FFFF_FFFF_FFFF;    // 2^61 - 1
  logic signed [61:0] pc;
  assign pc = (pb_q > PMAX) ? 62'(PMAX) : (pb_q < -PMAX - 64'sd1) ? 62'(-PMAX - 64'sd1) : 62'(pb_q);

  logic g_valid;
  rshr_sat #(.IN_W(62), .OUT_W(32), .SAT_MODE(0), .PIPE(1)) u_g (
    .clk, .rst_n, .valid_i(v2_q), .x_i(pc), .sh_i(SH_W'(16)), .valid_o(g_valid), .y_o(g_o));
  assign g_valid_o = g_valid;

  // ---------------- control ----------------
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      st_q   <= W_IDLE;
      icnt_q <= '0;
      wcnt_q <= '0;
      gcnt_q <= '0;
      done_q <= 1'b0;
    end else begin
      done_q <= 1'b0;
      if (silu_v) wcnt_q <= wcnt_q + 1'b1;
      if (g_valid) gcnt_q <= gcnt_q + 1'b1;
      if (go) begin
        st_q   <= W_A;
        icnt_q <= '0;
        wcnt_q <= '0;
        gcnt_q <= '0;
      end else
        unique case (st_q)
          W_A:   if (ta) begin
            icnt_q <= icnt_q + 1'b1;
            if (icnt_q + 1'b1 == n_q) st_q <= W_AW;
          end
          W_AW:  if (wcnt_q == n_q) begin st_q <= W_B; icnt_q <= '0; end
          W_B:   if (tb) begin
            icnt_q <= icnt_q + 1'b1;
            if (icnt_q + 1'b1 == n_q) st_q <= W_BW;
          end
          W_BW:  if (g_valid && gcnt_q + 1'b1 == n_q) begin
            st_q   <= W_FIN;
            done_q <= 1'b1;
          end
          W_FIN: st_q <= W_IDLE;
          default: ;
        endcase
    end

  always_ff @(posedge clk)
    if (go) n_q <= n_i;

  assign busy_o = st_q != W_IDLE;
  assign done_o = done_q;

`ifndef SYNTHESIS
  always @(posedge clk)
    if (rst_n === 1'b1) begin
      if ($isunknown(start_i) || $isunknown(e_valid_i)) $error("VR_X swi_front %m: X/Z on start_i or e_valid_i");
      if (start_i === 1'b1 && !go) $error("L1_START swi_front %m: start while busy (ignored)");
      if (go && (n_i == '0 || 32'(n_i) > N_MAX)) $error("L1_CFG swi_front %m: n %0d", n_i);
    end
`endif

endmodule
