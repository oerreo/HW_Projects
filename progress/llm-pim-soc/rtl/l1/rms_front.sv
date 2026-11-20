// rms_front: RMSNORM front end (hierarchy.md 3.3, arch.md 5.2). Golden: model/src/kern.c
// k_rmsnorm_st up to the pre-quantization y (stage trace A4: amax, k, ss, u, rm, re, sh, y); the
// quantizer is actq_core (f = fy, qmax = 127), which takes the y stream.
//
// One call (start_i; cfg n_i, ge_i, epsc_i (>= 0), fy_i sampled in the start cycle):
//   P1  x[0..n-1] (int32) from the element stream into the buffer (external RAM port, read latency
//       1), amax = max |x|
//   K   k = max(bitlen(amax) - 15, 0)
//   P2  xs = clamp(rshr(x, k), 32767) from the buffer, ss = sum xs^2 (< N_MAX 2^30: 40 bits)
//   P3  u = ss + rshr(epsc, 2k), rsqrt_nr (CYCLES 15) -> rm, re; sh = ge + re - fy
//   P4  g[0..n-1] (int16 values, sign-extended in the element) from the stream; with x[i] from the
//       buffer: y = sat32(rshr(xs g rm, sh)) -> y stream (valid only)
// Element stream e_valid_i / e_ready_o / e_i: the first n elements are x, the next n are g.
// e_ready_o = 1 in P1 and P4 only (one element per cycle; P4 reads x[i] in the cycle it takes
// g[i]). The y stream has no backpressure: the consumer (actq_core in LOAD) takes every y.
// Datapath: rshr_sat (k: 32 -> 17 bits, then the clamp to +-32767 equals the golden clamp), one
// 16 x 16 signed multiplier shared by P2 (xs xs) and P4 (xs g), one 31 x 17 multiplier (P4: xs g
// rm, 48 bits), rshr_sat 48 -> 32 (sh, PIPE 1), rshr_sat for rshr(epsc, 2k).
// done_o: 1-cycle pulse after the last y; busy_o from the start to done (a start is taken when
// idle or in the done cycle).
// Simulation-only checks: L1_START, L1_CFG (n 0 or > N_MAX, epsc < 0), VR_X.
module rms_front
  import llm_pkg::*;
#(
  parameter int N_MAX = 1024,
  localparam int NW   = $clog2(N_MAX + 1),
  localparam int AW   = (N_MAX > 1) ? $clog2(N_MAX) : 1,
  localparam int SS_W = 30 + $clog2(N_MAX),        // sum of n squares xs^2 < 2^30 (40 for 1024)
  localparam int U_W  = SS_W + 1                   // ss + rshr(epsc, 2k) (< 2^31): 41 for 1024
) (
  input  logic                  clk,
  input  logic                  rst_n,
  input  logic                  start_i,
  input  logic [NW-1:0]         n_i,
  input  logic signed [E_W-1:0] ge_i,
  input  logic [31:0]           epsc_i,
  input  logic signed [E_W-1:0] fy_i,
  // element stream: x then g
  input  logic                  e_valid_i,
  output logic                  e_ready_o,
  input  logic [31:0]           e_i,
  // buffer port (ram_sdp, RD_LAT 1)
  output logic                  b_we_o,
  output logic [AW-1:0]         b_waddr_o,
  output logic [31:0]           b_wdata_o,
  output logic                  b_re_o,
  output logic [AW-1:0]         b_raddr_o,
  input  logic [31:0]           b_rdata_i,
  // y stream (no backpressure)
  output logic                  y_valid_o,
  output logic [31:0]           y_o,
  output logic                  busy_o,
  output logic                  done_o
);
  if (N_MAX < 2 || N_MAX > 65536) $error("rms_front: N_MAX=%0d must be 2..65536", N_MAX);

  typedef enum logic [3:0] {R_IDLE, R_P1, R_K, R_P2, R_P2W, R_U, R_RSQ, R_RSQW, R_SH, R_P4, R_P4W,
                            R_FIN} st_t;
  st_t st_q;

  logic [NW-1:0]         n_q, cnt_q;
  logic signed [E_W-1:0] ge_q, fy_q;
  logic [31:0]           epsc_q, amax_q;
  logic [4:0]            k_q;
  logic [SS_W-1:0]       ss_q;
  logic [U_W-1:0]        u_q;
  logic signed [SH_W-1:0] sh_q;
  logic                  go, take, done_q;
  logic [16:0]           rm;            // rsqrt_nr result (valid from its done cycle)
  logic signed [E_W-1:0] re;
  logic                  r_done, r_busy;

  assign go        = start_i && (st_q == R_IDLE || done_q);
  assign e_ready_o = st_q == R_P1 || st_q == R_P4;
  assign take      = e_valid_i && e_ready_o;

  // ---------------- P1: buffer write, amax ----------------
  logic [31:0] ax;
  assign ax        = e_i[31] ? 32'(-e_i) : e_i;
  assign b_we_o    = take && st_q == R_P1;
  assign b_waddr_o = AW'(cnt_q);
  assign b_wdata_o = e_i;

  // ---------------- K ----------------
  logic [5:0] la;
  always_comb begin
    la = '0;
    for (int i = 0; i < 32; i++) if (amax_q[i]) la = 6'(i + 1);
  end

  // ---------------- P2 / P4 pipeline ----------------
  // c0: buffer read (P2: every cycle; P4: with the g element), c1: xs = clamp(rshr(x, k)),
  // c2: m = xs * (P2 ? xs : g), c3: P2 ss += m; P4 m rm, c4: rshr_sat(sh) -> y (c5 valid)
  logic                 rd, p4;
  logic                 v1_q, v2_q, v3_q;
  logic                 p1_q, p2_q, p3_q;           // P4 flag along the pipeline
  logic signed [15:0]   g1_q;
  logic signed [15:0]   xs2_q, g2_q;
  logic signed [30:0]   m3_q;
  logic signed [47:0]   pr4_q;
  logic                 v4_q;
  logic signed [16:0]   xr;
  logic signed [15:0]   xs;

  assign p4        = st_q == R_P4;
  assign rd        = (st_q == R_P2 && cnt_q != n_q) || (p4 && take);
  assign b_re_o    = rd;
  assign b_raddr_o = AW'(cnt_q);

  rshr_sat #(.IN_W(32), .OUT_W(17), .SAT_MODE(0), .PIPE(0)) u_xs (
    .clk, .rst_n, .valid_i(1'b0), .x_i(b_rdata_i), .sh_i(SH_W'(k_q)), .valid_o(), .y_o(xr));
  assign xs = (xr > 17'sd32767) ? 16'sd32767 : (xr < -17'sd32767) ? -16'sd32767 : 16'(xr);

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      v1_q <= 1'b0; v2_q <= 1'b0; v3_q <= 1'b0; v4_q <= 1'b0;
      p1_q <= 1'b0; p2_q <= 1'b0; p3_q <= 1'b0;
    end else begin
      v1_q <= rd;      p1_q <= p4;
      v2_q <= v1_q;    p2_q <= p1_q;
      v3_q <= v2_q;    p3_q <= p2_q;
      v4_q <= v3_q && p3_q;
    end

  always_ff @(posedge clk) begin
    if (rd) g1_q <= e_i[15:0];
    if (v1_q) begin
      xs2_q <= xs;
      g2_q  <= p1_q ? g1_q : xs;
    end
    if (v2_q) m3_q <= xs2_q * g2_q;                           // |.| < 2^30
    if (v3_q && p3_q) pr4_q <= m3_q * $signed({1'b0, rm});    // |.| < 2^47
  end

  logic signed [31:0] y;
  logic               y_valid;
  rshr_sat #(.IN_W(48), .OUT_W(32), .SAT_MODE(0), .PIPE(1)) u_y (
    .clk, .rst_n, .valid_i(v4_q), .x_i(pr4_q), .sh_i(sh_q), .valid_o(y_valid), .y_o(y));
  assign y_valid_o = y_valid;
  assign y_o       = y;

  // ---------------- P3: u, rsqrt ----------------
  logic signed [32:0] er;
  rshr_sat #(.IN_W(33), .OUT_W(33), .SAT_MODE(0), .PIPE(0)) u_eps (
    .clk, .rst_n, .valid_i(1'b0), .x_i($signed({1'b0, epsc_q})), .sh_i(SH_W'({k_q, 1'b0})),
    .valid_o(), .y_o(er));

  rsqrt_nr #(.U_W(U_W)) u_rsq (
    .clk, .rst_n, .start_i(st_q == R_RSQ), .u_i(u_q), .rm_o(rm), .re_o(re), .done_o(r_done),
    .busy_o(r_busy));

  // ---------------- control ----------------
  logic [NW-1:0] ycnt_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      st_q   <= R_IDLE;
      cnt_q  <= '0;
      ycnt_q <= '0;
      done_q <= 1'b0;
    end else begin
      done_q <= 1'b0;
      if (y_valid) ycnt_q <= ycnt_q + 1'b1;
      if (go) begin
        st_q   <= R_P1;
        cnt_q  <= '0;
        ycnt_q <= '0;
      end else
        unique case (st_q)
          R_P1:   if (take) begin
            cnt_q <= cnt_q + 1'b1;
            if (cnt_q + 1'b1 == n_q) st_q <= R_K;
          end
          R_K:    begin st_q <= R_P2; cnt_q <= '0; end
          R_P2:   if (rd) cnt_q <= cnt_q + 1'b1;
                  else st_q <= R_P2W;
          R_P2W:  if (!v1_q && !v2_q && !v3_q) st_q <= R_U;
          R_U:    st_q <= R_RSQ;
          R_RSQ:  st_q <= R_RSQW;
          R_RSQW: if (r_done) st_q <= R_SH;
          R_SH:   begin st_q <= R_P4; cnt_q <= '0; end
          R_P4:   if (take) begin
            cnt_q <= cnt_q + 1'b1;
            if (cnt_q + 1'b1 == n_q) st_q <= R_P4W;
          end
          R_P4W:  if (y_valid && ycnt_q + 1'b1 == n_q) begin
            st_q   <= R_FIN;
            done_q <= 1'b1;
          end
          R_FIN:  st_q <= R_IDLE;
          default: ;
        endcase
    end

  always_ff @(posedge clk) begin
    if (go) begin
      n_q    <= n_i;
      ge_q   <= ge_i;
      fy_q   <= fy_i;
      epsc_q <= epsc_i;
      amax_q <= '0;
    end else if (b_we_o && ax > amax_q) amax_q <= ax;
    if (st_q == R_K) begin
      k_q  <= (la > 6'd15) ? 5'(la - 6'd15) : 5'd0;
      ss_q <= '0;
    end else if (v3_q && !p3_q) ss_q <= ss_q + SS_W'(unsigned'(m3_q));
    if (st_q == R_U) u_q <= U_W'(ss_q) + U_W'(unsigned'(er));
    if (st_q == R_SH) sh_q <= SH_W'(ge_q) + SH_W'(re) - SH_W'(fy_q);
  end

  assign busy_o = st_q != R_IDLE;
  assign done_o = done_q;

`ifndef SYNTHESIS
  always @(posedge clk)
    if (rst_n === 1'b1) begin
      if ($isunknown(start_i) || $isunknown(e_valid_i)) $error("VR_X rms_front %m: X/Z on start_i or e_valid_i");
      if (start_i === 1'b1 && !go) $error("L1_START rms_front %m: start while busy (ignored)");
      if (go && (n_i == '0 || 32'(n_i) > N_MAX || epsc_i[31]))
        $error("L1_CFG rms_front %m: n %0d epsc %0d", n_i, $signed(epsc_i));
    end
`endif

endmodule
