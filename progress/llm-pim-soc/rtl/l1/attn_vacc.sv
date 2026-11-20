// attn_vacc: attention pass P3 of one head (hierarchy.md 3.3, arch.md 4.1). Golden:
// model/src/kern.c k_attn_pn, k_attn_w, k_attn_out and the P3 part of attn_core (stage trace
// k_attn2_st: w, acc; outputs p and o).
//
// Per position t the V row arrives as nb = ceil(hs / VL) beats (16-bit signed containers); the
// first beat of the position also carries the softmax numerator e[t] and the position's V scale
// (vm, ve). Per position:
//   p = (e R + 2^31) >> 32                        (p_o, one per position)
//   w = rshr(p vm, ve - emin - G)                 (vm = 0 gives w = 0: the position adds nothing,
//                                                  as the golden's skip)
//   acc[i] += w V[t][i]                           (beat g updates lanes g VL .. g VL + VL - 1)
// and at the end, read one element per o_rd_i: o[i] = sat32(rshr(acc[i], emin + G)).
// Ranges (golden): p <= 2^16, 0 <= w <= 2^33, |acc| < 2^(49 + log2 T_MAX); ACC_W >= 50 +
// log2(T_MAX) is checked at elaboration. Lanes >= hs of the last beat are accumulated like the
// others but never read (o_idx_i < hs).
//
// Pipeline (valid only, no backpressure; the caller aligns e / vm / ve with the first beat):
//   1 e * R            2 p (p_valid_o, LAT_P = 2 after a first beat)   3 p * vm
//   4 w = rshr_sat     5 w * V per lane (w of the position held for its later beats)
//   6 accumulate       -> a beat is in acc LAT_MAC = 6 cycles after b_valid_i.
// o read: o_rd_i / o_idx_i -> o_valid_o / o_o after LAT_O = 2 (register after the 1-of-HS_MAX
// mux, rshr_sat PIPE 1). clr_i (no beat in flight) zeroes every accumulator.
module attn_vacc
  import llm_pkg::*;
#(
  parameter int VL     = 8,
  parameter int HS_MAX = 64,
  parameter int T_MAX  = llm_pkg::T_MAX,
  parameter int ACC_W  = 60,
  localparam int NG    = (HS_MAX + VL - 1) / VL,
  localparam int GB_W  = (NG > 1) ? $clog2(NG) : 1,
  localparam int HS_W  = $clog2(HS_MAX + 1)
) (
  input  logic                   clk,
  input  logic                   rst_n,
  // head constants (held from the first beat to the last o read)
  input  logic [32:0]            r_i,
  input  logic signed [E_W-1:0]  emin_i,
  input  logic [4:0]             g_i,
  input  logic                   clr_i,
  // V beats
  input  logic                   b_valid_i,
  input  logic                   b_first_i,
  input  logic [GB_W-1:0]        b_g_i,
  input  logic [VL*16-1:0]       b_v_i,
  input  logic [16:0]            b_e_i,
  input  logic [AM_W-1:0]        b_vm_i,
  input  logic signed [E_W-1:0]  b_ve_i,
  // normalized probabilities
  output logic                   p_valid_o,
  output logic [31:0]            p_o,
  // o read
  input  logic                   o_rd_i,
  input  logic [HS_W-1:0]        o_idx_i,
  output logic                   o_valid_o,
  output logic signed [31:0]     o_o
);
  localparam int LAT_P   = 2;
  localparam int LAT_MAC = 6;
  localparam int LAT_O   = 2;
  localparam int W_W     = 36;  // w <= 2^33 (signed container with headroom)

  if (VL < 1) $error("attn_vacc: VL=%0d must be >= 1", VL);
  if (HS_MAX < 1 || HS_MAX > 128) $error("attn_vacc: HS_MAX=%0d must be 1..128", HS_MAX);
  if (ACC_W < 50 + $clog2(T_MAX) || ACC_W > 62)
    $error("attn_vacc: ACC_W=%0d must be %0d..62", ACC_W, 50 + $clog2(T_MAX));

  typedef struct packed {
    logic                  first;
    logic [GB_W-1:0]       g;
    logic [VL*16-1:0]      v;
  } beat_t;

  // ---- stage 1: e * R ----
  logic                  v1;
  beat_t                 b1;
  logic [49:0]           er1;
  logic [AM_W-1:0]       vm1;
  logic signed [E_W-1:0] ve1;
  // ---- stage 2: p ----
  logic                  v2;
  beat_t                 b2;
  logic [16:0]           p2;
  logic [AM_W-1:0]       vm2;
  logic signed [E_W-1:0] ve2;
  // ---- stage 3: p * vm ----
  logic                  v3;
  beat_t                 b3;
  logic [33:0]           pm3;
  logic signed [SH_W-1:0] sh3;
  // ---- stage 4: w ----
  logic                  v4;
  beat_t                 b4;
  logic signed [W_W-1:0] w4;
  // ---- stage 5: w * V ----
  logic                  v5;
  logic [GB_W-1:0]       g5;
  logic signed [W_W+15:0] m5 [VL];
  logic signed [W_W-1:0] wh_q;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0; v5 <= 1'b0;
    end else begin
      v1 <= b_valid_i; v2 <= v1; v3 <= v2; v5 <= v4;
    end

  always_ff @(posedge clk) begin
    if (b_valid_i) begin
      b1  <= '{first: b_first_i, g: b_g_i, v: b_v_i};
      er1 <= 50'(b_e_i) * 50'(r_i);
      vm1 <= b_vm_i;
      ve1 <= b_ve_i;
    end
    if (v1) begin
      b2  <= b1;
      p2  <= 17'((er1 + 50'(64'd1 << 31)) >> 32);
      vm2 <= vm1;
      ve2 <= ve1;
    end
    if (v2) begin
      b3  <= b2;
      pm3 <= 34'(p2) * 34'(vm2);
      sh3 <= SH_W'(ve2) - SH_W'(emin_i) - SH_W'(g_i);
    end
  end

  rshr_sat #(.IN_W(35), .OUT_W(W_W), .SAT_MODE(0), .PIPE(1)) u_w (
    .clk, .rst_n, .valid_i(v3), .x_i($signed({1'b0, pm3})), .sh_i(sh3), .valid_o(v4), .y_o(w4));
  always_ff @(posedge clk)
    if (v3) b4 <= b3;

  logic signed [W_W-1:0] wuse;
  assign wuse = b4.first ? w4 : wh_q;
  always_ff @(posedge clk)
    if (v4) begin
      wh_q <= wuse;
      g5   <= b4.g;
      for (int l = 0; l < VL; l++) m5[l] <= (W_W + 16)'(wuse) * (W_W + 16)'($signed(b4.v[l*16 +: 16]));
    end

  // ---- stage 6: accumulators ----
  logic signed [ACC_W-1:0] acc_q [NG][VL];
  always_ff @(posedge clk)
    if (clr_i) begin
      for (int g = 0; g < NG; g++)
        for (int l = 0; l < VL; l++) acc_q[g][l] <= '0;
    end else if (v5) begin
      for (int l = 0; l < VL; l++) acc_q[g5][l] <= acc_q[g5][l] + ACC_W'(m5[l]);
    end

  assign p_valid_o = v2 && b2.first;
  assign p_o       = 32'(p2);

  // ---- o read ----
  logic                    ov_q;
  logic signed [ACC_W-1:0] oa_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) ov_q <= 1'b0;
    else        ov_q <= o_rd_i;
  always_ff @(posedge clk)
    if (o_rd_i) oa_q <= acc_q[GB_W'(32'(o_idx_i) / VL)][32'(o_idx_i) % VL];

  rshr_sat #(.IN_W(ACC_W), .OUT_W(32), .SAT_MODE(0), .PIPE(1)) u_o (
    .clk, .rst_n, .valid_i(ov_q), .x_i(oa_q), .sh_i(SH_W'(emin_i) + SH_W'(g_i)),
    .valid_o(o_valid_o), .y_o(o_o));

`ifndef SYNTHESIS
  always @(posedge clk)
    if (rst_n === 1'b1 && v4 === 1'b1 && b4.first && (w4 < 0 || w4 > (W_W'(1) <<< 33)))
      $error("L1_RANGE attn_vacc %m: w = %0d outside [0, 2^33]", w4);
`endif

endmodule
