// attn_score: attention pass P1 of one head (hierarchy.md 3.3, arch.md 4.1). Golden:
// model/src/kern.c k_attn_score and the P1 part of attn_core (stage trace k_attn2_st: dot, s,
// mx, emin, mmax, have).
//
// Per position t the K row arrives as nb = ceil(hs / KL) beats of KL lanes (16-bit signed
// containers; lanes >= hs of the last beat are ignored). Beat g is multiplied lane-wise with q
// group g (q is loaded through q_we_i before the head) and summed (dotp); the sums of the nb
// beats form dot. Then
//   s = sat32(rshr(rshr(dot, d0) * (qm * km), qe + ke - d0 - 16))
// mx is the running maximum of s, and over the positions with vm != 0: emin = min ve,
// mmax = max vm, have = 1. The scales km, ke, vm, ve of a position are taken from its last beat.
// Precondition (golden): |rshr(dot, d0)| < 2^22 (values inside their kb-bit range, hs <= 64);
// a larger value is reported (L1_RANGE) and saturated to 24 bits.
//
// Pipeline (valid only, no backpressure): dotp PIPE DOT_PIPE -> dot accumulator (1) ->
// rshr(dot, d0) and qm * km (1) -> product (1) -> rshr_sat PIPE SH_PIPE. A position's s_valid_o
// comes LATENCY = DOT_PIPE + 3 + SH_PIPE cycles after its last beat. s_vm_o / s_ve_o carry the
// position's vm / ve with s. mx_o, emin_o, mmax_o, have_o are final LATENCY cycles after the
// last beat of the head. clr_i (one cycle, no beat in flight) starts a head: beat counter,
// maximum and statistics restart.
module attn_score
  import llm_pkg::*;
#(
  parameter int KL       = 8,
  parameter int HS_MAX   = 64,
  parameter int DOT_PIPE = 2,
  parameter int SH_PIPE  = 1,
  localparam int NG      = (HS_MAX + KL - 1) / KL,
  localparam int GB_W    = (NG > 1) ? $clog2(NG) : 1,
  localparam int HS_W    = $clog2(HS_MAX + 1)
) (
  input  logic                    clk,
  input  logic                    rst_n,
  // head configuration (held while the head runs)
  input  logic [HS_W-1:0]         hs_i,
  input  logic [3:0]              d0_i,
  input  logic [AM_W-1:0]         qm_i,
  input  logic signed [E_W-1:0]   qe_i,
  input  logic                    clr_i,
  // q load (group q_idx_i = lanes q_idx_i * KL ..)
  input  logic                    q_we_i,
  input  logic [GB_W-1:0]         q_idx_i,
  input  logic [KL*16-1:0]        q_data_i,
  // K beats
  input  logic                    k_valid_i,
  input  logic [KL*16-1:0]        k_data_i,
  input  logic [AM_W-1:0]         km_i,
  input  logic signed [E_W-1:0]   ke_i,
  input  logic [AM_W-1:0]         vm_i,
  input  logic signed [E_W-1:0]   ve_i,
  // scores
  output logic                    s_valid_o,
  output logic signed [31:0]      s_o,
  output logic [AM_W-1:0]         s_vm_o,
  output logic signed [E_W-1:0]   s_ve_o,
  output logic signed [31:0]      mx_o,
  output logic signed [E_W-1:0]   emin_o,
  output logic [AM_W-1:0]         mmax_o,
  output logic                    have_o
);
  localparam int SW      = 32 + $clog2(KL);          // dotp sum width (16 x 16, KL lanes)
  localparam int ACC_W   = SW + $clog2(NG + 1);      // dot over nb beats
  localparam int R_W     = 24;                       // rshr(dot, d0)
  localparam int LATENCY = DOT_PIPE + 3 + SH_PIPE;

  if (KL < 2 || (KL & (KL - 1)) != 0) $error("attn_score: KL=%0d must be a power of two >= 2", KL);
  if (HS_MAX < 1 || HS_MAX > 128) $error("attn_score: HS_MAX=%0d must be 1..128", HS_MAX);
  if (ACC_W > 62) $error("attn_score: dot width %0d > 62", ACC_W);
  if (SH_PIPE < 0 || SH_PIPE > 2) $error("attn_score: SH_PIPE=%0d must be 0..2", SH_PIPE);

  // ---------------- q registers and beat counter ----------------
  logic [KL*16-1:0] q_r [NG];
  always_ff @(posedge clk)
    if (q_we_i) q_r[q_idx_i] <= q_data_i;

  logic [GB_W-1:0] g_q, nbm1;
  logic            b_first, b_last;
  assign nbm1    = GB_W'((32'(hs_i) + KL - 1) / KL - 1);
  assign b_first = g_q == '0;
  assign b_last  = g_q == nbm1;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) g_q <= '0;
    else if (clr_i) g_q <= '0;
    else if (k_valid_i) g_q <= b_last ? '0 : g_q + 1'b1;

  // lanes >= hs of the beat are zero
  logic [KL*16-1:0] kmask;
  always_comb
    for (int l = 0; l < KL; l++)
      kmask[l*16 +: 16] = (32'(g_q) * KL + l < 32'(hs_i)) ? k_data_i[l*16 +: 16] : 16'd0;

  // ---------------- dotp and its side band ----------------
  logic                  dv;
  logic signed [SW-1:0]  dsum;
  dotp #(.LANES(KL), .AW(16), .BW(16), .PIPE(DOT_PIPE)) u_dot (
    .clk, .rst_n, .valid_i(k_valid_i), .a_i(q_r[g_q]), .b_i(kmask), .valid_o(dv), .sum_o(dsum));

  typedef struct packed {
    logic                  first, last;
    logic [AM_W-1:0]       km, vm;
    logic signed [E_W-1:0] ke, ve;
  } side_t;
  side_t sd_in, sd;
  assign sd_in = '{first: b_first, last: b_last, km: km_i, vm: vm_i, ke: ke_i, ve: ve_i};
  if (DOT_PIPE == 0) begin : g_sd0
    assign sd = sd_in;
  end else begin : g_sd
    side_t sr [DOT_PIPE];
    always_ff @(posedge clk) begin
      sr[0] <= sd_in;
      for (int i = 1; i < DOT_PIPE; i++) sr[i] <= sr[i-1];
    end
    assign sd = sr[DOT_PIPE-1];
  end

  // ---------------- stage A: dot accumulation, statistics ----------------
  logic                    pa_q;          // dot of a position complete
  logic signed [ACC_W-1:0] acc_q;
  logic [AM_W-1:0]         kmA, vmA, mmax_q;
  logic signed [E_W-1:0]   keA, veA, emin_q;
  logic                    have_q;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      pa_q   <= 1'b0;
      have_q <= 1'b0;
    end else begin
      pa_q <= dv && sd.last;
      if (clr_i) have_q <= 1'b0;
      else if (dv && sd.last && sd.vm != '0) have_q <= 1'b1;
    end

  always_ff @(posedge clk) begin
    if (dv) acc_q <= sd.first ? ACC_W'(dsum) : acc_q + ACC_W'(dsum);
    if (dv && sd.last) begin
      kmA <= sd.km;
      keA <= sd.ke;
      vmA <= sd.vm;
      veA <= sd.ve;
    end
    if (clr_i) mmax_q <= '0;
    else if (dv && sd.last && sd.vm != '0) begin
      if (!have_q || sd.ve < emin_q) emin_q <= sd.ve;
      if (sd.vm > mmax_q) mmax_q <= sd.vm;
    end
  end

  // ---------------- stage B: rshr(dot, d0), c = qm * km, shift ----------------
  logic                       rv;
  logic signed [R_W-1:0]      r;
  logic [2*AM_W-1:0]          cB;
  logic signed [SH_W-1:0]     shB;
  logic [AM_W-1:0]            vmB;
  logic signed [E_W-1:0]      veB;

  rshr_sat #(.IN_W(ACC_W), .OUT_W(R_W), .SAT_MODE(0), .PIPE(1)) u_rd0 (
    .clk, .rst_n, .valid_i(pa_q), .x_i(acc_q), .sh_i(SH_W'(d0_i)), .valid_o(rv), .y_o(r));

  always_ff @(posedge clk)
    if (pa_q) begin
      cB  <= qm_i * kmA;
      shB <= SH_W'(qe_i) + SH_W'(keA) - SH_W'(d0_i) - SH_W'(16);
      vmB <= vmA;
      veB <= veA;
    end

  // ---------------- stage C: product ----------------
  logic                       xv_q;
  logic signed [57:0]         x_q;
  logic signed [SH_W-1:0]     shC;
  logic [AM_W-1:0]            vmC;
  logic signed [E_W-1:0]      veC;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) xv_q <= 1'b0;
    else        xv_q <= rv;
  always_ff @(posedge clk)
    if (rv) begin
      x_q <= 58'(r) * 58'($signed({1'b0, cB}));
      shC <= shB;
      vmC <= vmB;
      veC <= veB;
    end

  // ---------------- stage D: s = sat32(rshr(x, sh)) ----------------
  rshr_sat #(.IN_W(58), .OUT_W(32), .SAT_MODE(0), .PIPE(SH_PIPE)) u_rs (
    .clk, .rst_n, .valid_i(xv_q), .x_i(x_q), .sh_i(shC), .valid_o(s_valid_o), .y_o(s_o));

  if (SH_PIPE == 0) begin : g_vs0
    assign s_vm_o = vmC;
    assign s_ve_o = veC;
  end else begin : g_vs
    logic [AM_W-1:0]       vr [SH_PIPE];
    logic signed [E_W-1:0] er [SH_PIPE];
    always_ff @(posedge clk) begin
      vr[0] <= vmC;
      er[0] <= veC;
      for (int i = 1; i < SH_PIPE; i++) begin
        vr[i] <= vr[i-1];
        er[i] <= er[i-1];
      end
    end
    assign s_vm_o = vr[SH_PIPE-1];
    assign s_ve_o = er[SH_PIPE-1];
  end

  // ---------------- running maximum ----------------
  logic               mxs_q;   // a score has been seen since clr_i
  logic signed [31:0] mx_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) mxs_q <= 1'b0;
    else if (clr_i) mxs_q <= 1'b0;
    else if (s_valid_o) mxs_q <= 1'b1;
  always_ff @(posedge clk)
    if (s_valid_o && (!mxs_q || s_o > mx_q)) mx_q <= s_o;

  assign mx_o   = mx_q;
  assign emin_o = emin_q;
  assign mmax_o = mmax_q;
  assign have_o = have_q;

`ifndef SYNTHESIS
  always @(posedge clk)
    if (rst_n === 1'b1 && pa_q === 1'b1 &&
        (64'(acc_q) >= (64'sd1 <<< (22 + d0_i)) || 64'(acc_q) < -(64'sd1 <<< (22 + d0_i))))
      $error("L1_RANGE attn_score %m: |dot >> d0| >= 2^22 (dot %0d, d0 %0d)", acc_q, d0_i);
`endif

endmodule
