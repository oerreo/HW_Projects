// attn_core: attention of one head (hierarchy.md 3.4, arch.md 4.1, 4.4). Golden: model/src/kern.c
// k_attn2 (record K_ATTN2; K_ATTN with kb = vb = 8 or 16), stage trace k_attn2_st.
//
// A call (start_i with T, hs, kb, qm, qe, p_en) runs
//   Q   q[hs] from the q stream: ceil(hs/KL) beats of KL 16-bit lanes (lanes >= hs ignored)
//   P1  K pass: T x ceil(hs/KL) beats -> attn_score: s[t] -> p buffer, (vm, ve)[t] -> vs buffer,
//       mx, emin, mmax, have
//   P2  p buffer -> exp_unit (e = k_attn_exp(s, mx)) -> p buffer, sum of e
//   DIV R = 2^48 / sum (udiv_seq, Q_W 33), G = 17 - bitlen(mmax) (emin = G = 0 if !have)
//   P3  V pass: T x ceil(hs/VL) beats -> attn_vacc with e[t], (vm, ve)[t] from the buffers:
//       p[t] to the output stream (if p_en), acc += w V
//   O   o[i] = sat32(rshr(acc[i], emin + G)), i < hs, to the output stream
// The output stream carries p[0..T-1] (if p_en, out_last_o on p[T-1], out_is_o_o = 0) and then
// o[0..hs-1] (out_last_o on o[hs-1], out_is_o_o = 1). done_o is a 1-cycle pulse in the cycle
// after the last output element was taken; start_i is taken while idle (busy_o = 0, including the
// done cycle). The configuration inputs are sampled with start_i.
//
// KV source interface (independent of where K and V live, arch.md 4.2): the core requests a pass
// (kvreq_valid_o / kvreq_ready_i, kvreq_pass_o 0 = K, 1 = V); the source then delivers exactly
// T x ceil(hs/KL) beats in position order on kv_* (valid / ready). K pass beats carry K lanes and,
// on the last beat of each position, ks = (km, ke) and vs = (vm, ve) (sampled there only); V pass
// beats carry V lanes only (scales ignored). Lanes >= hs are ignored. The K request is made at
// start, the V request when P2 starts, so a source can fetch ahead.
//
// Backpressure: P1 and P2 never stall internally. P3 takes the first beat of a position only if
// the output FIFO (OUT_DEPTH) has room for its p (credit = level + p in flight); O issues a read
// only with a free entry. The output FIFO is a sync_fifo (first-word fall-through).
module attn_core
  import llm_pkg::*;
#(
  parameter int KL        = 8,
  parameter int VL        = 8,
  parameter int HS_MAX    = 64,
  parameter int TMAX      = llm_pkg::T_MAX,
  parameter int DOT_PIPE  = 2,
  parameter int SH_PIPE   = 1,
  parameter int RS_PIPE   = 1,
  parameter int LUT_PIPE  = 2,
  parameter int OUT_DEPTH = 16,
  parameter int ACC_W     = 60,
  localparam int HS_W     = $clog2(HS_MAX + 1),
  localparam int TW       = $clog2(TMAX + 1)
) (
  input  logic                   clk,
  input  logic                   rst_n,
  // call
  input  logic                   start_i,
  input  logic [TW-1:0]          t_i,
  input  logic [HS_W-1:0]        hs_i,
  input  logic [4:0]             kb_i,
  input  logic [AM_W-1:0]        qm_i,
  input  logic signed [E_W-1:0]  qe_i,
  input  logic                   p_en_i,
  output logic                   busy_o,
  output logic                   done_o,
  // q stream
  input  logic                   q_valid_i,
  output logic                   q_ready_o,
  input  logic [KL*16-1:0]       q_data_i,
  // KV pass request and stream
  output logic                   kvreq_valid_o,
  input  logic                   kvreq_ready_i,
  output logic                   kvreq_pass_o,
  input  logic                   kv_valid_i,
  output logic                   kv_ready_o,
  input  logic [KL*16-1:0]       kv_data_i,
  input  logic [AM_W-1:0]        kv_km_i,
  input  logic signed [E_W-1:0]  kv_ke_i,
  input  logic [AM_W-1:0]        kv_vm_i,
  input  logic signed [E_W-1:0]  kv_ve_i,
  // output stream (p then o)
  output logic                   out_valid_o,
  input  logic                   out_ready_i,
  output logic [31:0]            out_data_o,
  output logic                   out_last_o,
  output logic                   out_is_o_o,
  // status
  output logic                   kv_stall_o
);
  localparam int NG    = (HS_MAX + KL - 1) / KL;
  localparam int GB_W  = (NG > 1) ? $clog2(NG) : 1;
  localparam int PA_W  = (TMAX > 1) ? $clog2(TMAX) : 1;
  localparam int LAT_E = 1 + RS_PIPE + LUT_PIPE;
  localparam int LAT_P = 2, LAT_MAC = 6, LAT_O = 2;
  localparam int SUM_W = 17 + $clog2(TMAX);   // sum of T values <= 2^16
  localparam int OL_W  = $clog2(OUT_DEPTH + 1);
  localparam int CR_W  = $clog2(OUT_DEPTH + 8);

  if (KL != VL) $error("attn_core: KL=%0d and VL=%0d must be equal (one KV beat width)", KL, VL);
  if (TMAX < 1 || TMAX > 4096) $error("attn_core: TMAX=%0d must be 1..4096", TMAX);
  if (OUT_DEPTH < 4) $error("attn_core: OUT_DEPTH=%0d must be >= 4", OUT_DEPTH);
  if (SUM_W > 26 + 3) $error("attn_core: TMAX too large for the divider");

  typedef enum logic [3:0] {S_IDLE, S_Q, S_P1, S_P1W, S_P2, S_P2W, S_DIV, S_DIVW, S_P3, S_P3W,
                            S_OD, S_FIN} st_t;
  st_t st_q;

  // ---------------- configuration ----------------
  logic [TW-1:0]         T_q;
  logic [HS_W-1:0]       hs_q;
  logic [3:0]            d0_q;
  logic [AM_W-1:0]       qm_q;
  logic signed [E_W-1:0] qe_q;
  logic                  pen_q;
  logic [GB_W-1:0]       nbm1;
  logic                  go;

  assign go   = start_i && st_q == S_IDLE;
  assign nbm1 = GB_W'((32'(hs_q) + KL - 1) / KL - 1);

  always_ff @(posedge clk)
    if (go) begin
      T_q   <= t_i;
      hs_q  <= hs_i;
      d0_q  <= (kb_i > 5'd8) ? 4'(2 * 32'(kb_i) - 17) : 4'd0;   // k_attn_d0
      qm_q  <= qm_i;
      qe_q  <= qe_i;
      pen_q <= p_en_i;
    end

  // ---------------- counters ----------------
  logic [GB_W-1:0] b_q;          // beat within a position (Q, P1, P3)
  logic [TW-1:0]   t_q;          // position (P1, P3) / read index (P2)
  logic [TW-1:0]   sc_q;         // scores written (P1), e written (P2)
  logic [HS_W-1:0] oi_q;         // o index (O)
  logic [3:0]      wc_q;         // wait counter (P3W)
  logic            req_k_q, req_v_q;

  logic q_hs, kv_hs, b_end, t_end;
  assign q_hs  = q_valid_i && q_ready_o;
  assign kv_hs = kv_valid_i && kv_ready_o;
  assign b_end = b_q == nbm1;
  assign t_end = t_q == T_q - 1'b1;

  // ---------------- buffers ----------------
  logic              pb_we, pb_re, vb_re;
  logic [PA_W-1:0]   pb_wa, pb_ra;
  logic [31:0]       pb_wd, pb_rd;
  logic [AM_W+E_W-1:0] vb_rd;

  // ---------------- attn_score ----------------
  logic                  s_valid, have;
  logic signed [31:0]    s_val, mx;
  logic [AM_W-1:0]       s_vm, mmax;
  logic signed [E_W-1:0] s_ve, emin;

  attn_score #(.KL(KL), .HS_MAX(HS_MAX), .DOT_PIPE(DOT_PIPE), .SH_PIPE(SH_PIPE)) u_score (
    .clk, .rst_n, .hs_i(hs_q), .d0_i(d0_q), .qm_i(qm_q), .qe_i(qe_q), .clr_i(go),
    .q_we_i(q_hs), .q_idx_i(b_q), .q_data_i(q_data_i),
    .k_valid_i(kv_hs && st_q == S_P1), .k_data_i(kv_data_i), .km_i(kv_km_i), .ke_i(kv_ke_i),
    .vm_i(kv_vm_i), .ve_i(kv_ve_i),
    .s_valid_o(s_valid), .s_o(s_val), .s_vm_o(s_vm), .s_ve_o(s_ve), .mx_o(mx), .emin_o(emin),
    .mmax_o(mmax), .have_o(have));

  // ---------------- exp_unit (P2) ----------------
  logic             e_in_q, e_valid;
  logic [16:0]      e_val;
  logic [SUM_W-1:0] sum_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) e_in_q <= 1'b0;
    else        e_in_q <= pb_re && st_q == S_P2;

  exp_unit #(.RS_PIPE(RS_PIPE), .LUT_PIPE(LUT_PIPE)) u_exp (
    .clk, .rst_n, .valid_i(e_in_q), .s_i(pb_rd), .mx_i(mx), .valid_o(e_valid), .e_o(e_val));

  // ---------------- divider ----------------
  logic        div_start, div_done;
  logic [32:0] div_q, r_q;
  logic [4:0]  g_q;
  logic signed [E_W-1:0] emin_q;
  udiv_seq #(.NUM_W(49), .DEN_W(SUM_W), .Q_W(33)) u_div (
    .clk, .rst_n, .start_i(div_start), .num_i(49'(64'd1 << 48)), .den_i(sum_q), .q_o(div_q),
    .done_o(div_done), .busy_o());
  assign div_start = st_q == S_DIV;

  function automatic logic [4:0] bitlen17(logic [AM_W-1:0] v);
    bitlen17 = '0;
    for (int i = 0; i < AM_W; i++) if (v[i]) bitlen17 = 5'(i + 1);
  endfunction

  // ---------------- attn_vacc (P3, O) ----------------
  logic             vb_q, vfirst_q;    // V beat registered (aligned with the buffer read data)
  logic [GB_W-1:0]  vg_q;
  logic [KL*16-1:0] vv_q;
  logic             p_valid, o_valid, o_rd;
  logic [31:0]      p_val;
  logic signed [31:0] o_val;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) vb_q <= 1'b0;
    else        vb_q <= kv_hs && st_q == S_P3;
  always_ff @(posedge clk)
    if (kv_hs) begin
      vfirst_q <= b_q == '0;
      vg_q     <= b_q;
      vv_q     <= kv_data_i;
    end

  attn_vacc #(.VL(VL), .HS_MAX(HS_MAX), .T_MAX(TMAX), .ACC_W(ACC_W)) u_vacc (
    .clk, .rst_n, .r_i(r_q), .emin_i(emin_q), .g_i(g_q), .clr_i(go),
    .b_valid_i(vb_q), .b_first_i(vfirst_q), .b_g_i(vg_q), .b_v_i(vv_q), .b_e_i(pb_rd[16:0]),
    .b_vm_i(vb_rd[AM_W-1:0]), .b_ve_i(vb_rd[AM_W +: E_W]),
    .p_valid_o(p_valid), .p_o(p_val), .o_rd_i(o_rd), .o_idx_i(oi_q), .o_valid_o(o_valid), .o_o(o_val));

  // ---------------- output FIFO and credit ----------------
  logic            of_push, of_in_ready;
  logic [33:0]     of_din, of_dout;
  logic [OL_W-1:0] of_level;
  logic [CR_W-1:0] infl_q;     // p / o elements issued but not yet pushed
  logic [TW-1:0]   pc_q;       // p pushed
  logic [HS_W-1:0] op_q;       // o pushed (o are read in index order)
  logic            credit_ok, issue_p;

  assign credit_ok = 32'(of_level) + 32'(infl_q) < 32'(OUT_DEPTH);
  assign of_push   = (p_valid && pen_q) || o_valid;
  assign of_din    = p_valid ? {1'b0, pc_q == T_q - 1'b1, p_val}
                             : {1'b1, op_q == hs_q - 1'b1, o_val};

  sync_fifo #(.W(34), .DEPTH(OUT_DEPTH)) u_ofifo (
    .clk, .rst_n, .in_valid_i(of_push), .in_ready_o(of_in_ready), .in_data_i(of_din),
    .out_valid_o(out_valid_o), .out_ready_i(out_ready_i), .out_data_o(of_dout), .level_o(of_level));
  assign out_data_o = of_dout[31:0];
  assign out_last_o = of_dout[32];
  assign out_is_o_o = of_dout[33];

  // ---------------- handshakes of the phases ----------------
  assign q_ready_o  = st_q == S_Q;
  assign issue_p    = kv_hs && st_q == S_P3 && b_q == '0 && pen_q;
  assign kv_ready_o = st_q == S_P1 || (st_q == S_P3 && (b_q != '0 || !pen_q || credit_ok));
  assign kv_stall_o = kv_ready_o && !kv_valid_i;
  assign o_rd       = st_q == S_OD && credit_ok;

  assign kvreq_valid_o = req_k_q || req_v_q;
  assign kvreq_pass_o  = !req_k_q;

  // buffer ports
  always_comb begin
    pb_we = 1'b0;
    pb_wa = PA_W'(sc_q);
    pb_wd = s_val;
    if (st_q == S_P1 || st_q == S_P1W) pb_we = s_valid;
    else if (st_q == S_P2 || st_q == S_P2W) begin
      pb_we = e_valid;
      pb_wd = 32'(e_val);
    end
    pb_re = (st_q == S_P2) || (st_q == S_P3 && kv_hs && b_q == '0);
    pb_ra = PA_W'(t_q);
    vb_re = st_q == S_P3 && kv_hs && b_q == '0;
  end

  ram_sdp #(.W(32), .DEPTH(TMAX), .RD_LAT(1)) u_pbuf (
    .clk, .rst_n, .we_i(pb_we), .waddr_i(pb_wa), .wdata_i(pb_wd), .re_i(pb_re), .raddr_i(pb_ra),
    .rdata_o(pb_rd));
  ram_sdp #(.W(AM_W + E_W), .DEPTH(TMAX), .RD_LAT(1)) u_vbuf (
    .clk, .rst_n, .we_i(s_valid && (st_q == S_P1 || st_q == S_P1W)), .waddr_i(PA_W'(sc_q)),
    .wdata_i({s_ve, s_vm}), .re_i(vb_re), .raddr_i(pb_ra), .rdata_o(vb_rd));

  // ---------------- state machine ----------------
  logic done_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      st_q    <= S_IDLE;
      b_q     <= '0;
      t_q     <= '0;
      sc_q    <= '0;
      oi_q    <= '0;
      op_q    <= '0;
      pc_q    <= '0;
      wc_q    <= '0;
      infl_q  <= '0;
      req_k_q <= 1'b0;
      req_v_q <= 1'b0;
      done_q  <= 1'b0;
    end else begin
      done_q <= 1'b0;
      // pass requests
      if (go) req_k_q <= 1'b1;
      else if (kvreq_ready_i && req_k_q) req_k_q <= 1'b0;
      if (st_q == S_P1W && 32'(sc_q) == 32'(T_q)) req_v_q <= 1'b1;
      else if (kvreq_ready_i && !req_k_q && req_v_q) req_v_q <= 1'b0;
      // output credit
      infl_q <= infl_q + CR_W'(issue_p || o_rd) - CR_W'(of_push);
      if (p_valid && pen_q) pc_q <= pc_q + 1'b1;
      if (o_valid) op_q <= op_q + 1'b1;
      unique case (st_q)
        S_IDLE: if (go) begin
          st_q <= S_Q;
          b_q  <= '0;
          t_q  <= '0;
          sc_q <= '0;
          oi_q <= '0;
          op_q <= '0;
          pc_q <= '0;
        end
        S_Q: if (q_hs) begin
          b_q <= b_end ? '0 : b_q + 1'b1;
          if (b_end) st_q <= S_P1;
        end
        S_P1, S_P1W: begin
          if (s_valid) sc_q <= sc_q + 1'b1;
          if (st_q == S_P1 && kv_hs) begin
            b_q <= b_end ? '0 : b_q + 1'b1;
            if (b_end) begin
              t_q <= t_q + 1'b1;
              if (t_end) st_q <= S_P1W;
            end
          end
          if (st_q == S_P1W && 32'(sc_q) == 32'(T_q)) begin
            st_q <= S_P2;
            t_q  <= '0;
            sc_q <= '0;
          end
        end
        S_P2: begin
          t_q <= t_q + 1'b1;
          if (e_valid) sc_q <= sc_q + 1'b1;
          if (t_end) st_q <= S_P2W;
        end
        S_P2W: begin
          if (e_valid) sc_q <= sc_q + 1'b1;
          if (32'(sc_q) == 32'(T_q)) st_q <= S_DIV;
        end
        S_DIV: st_q <= S_DIVW;
        S_DIVW: if (div_done) begin
          st_q <= S_P3;
          t_q  <= '0;
          b_q  <= '0;
        end
        S_P3: if (kv_hs) begin
          b_q <= b_end ? '0 : b_q + 1'b1;
          if (b_end) begin
            t_q <= t_q + 1'b1;
            if (t_end) begin
              st_q <= S_P3W;
              wc_q <= '0;
            end
          end
        end
        S_P3W: begin
          wc_q <= wc_q + 1'b1;
          if (32'(wc_q) == LAT_MAC) st_q <= S_OD;   // last beat registered + LAT_MAC
        end
        S_OD: if (o_rd) begin
          oi_q <= oi_q + 1'b1;
          if (oi_q == hs_q - 1'b1) st_q <= S_FIN;
        end
        S_FIN: if (infl_q == '0 && !of_push && of_level == '0) begin
          st_q   <= S_IDLE;
          done_q <= 1'b1;
        end
        default: st_q <= S_IDLE;
      endcase
    end

  // sum of e (P2), divider result, head constants
  always_ff @(posedge clk) begin
    if (go) sum_q <= '0;
    else if (e_valid && (st_q == S_P2 || st_q == S_P2W)) sum_q <= sum_q + SUM_W'(e_val);
    if (st_q == S_DIV) begin
      g_q    <= have ? 5'd17 - bitlen17(mmax) : 5'd0;
      emin_q <= have ? emin : '0;
    end
    if (div_done) r_q <= div_q;
  end

  assign busy_o = st_q != S_IDLE;
  assign done_o = done_q;

`ifndef SYNTHESIS
  always @(posedge clk)
    if (rst_n === 1'b1) begin
      if (start_i === 1'b1 && st_q != S_IDLE) $error("L2_START attn_core %m: start while busy");
      if (go && (t_i == '0 || 32'(t_i) > TMAX || hs_i == '0 || 32'(hs_i) > HS_MAX ||
                 !(kb_i == 5'd8 || kb_i == 5'd12 || kb_i == 5'd16)))
        $error("L2_RANGE attn_core %m: T %0d hs %0d kb %0d outside 1..%0d, 1..%0d, {8, 12, 16}",
               t_i, hs_i, kb_i, TMAX, HS_MAX);
      if (of_push && !of_in_ready) $error("L2_OVF attn_core %m: output FIFO overflow");
    end
`endif

endmodule
