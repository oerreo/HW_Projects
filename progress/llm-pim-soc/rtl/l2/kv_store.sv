// kv_store: on-chip KV cache of the 260K PIM system (arch.md 4.2, D7; hierarchy.md 3.4).
//
// One SDP RAM (ram_sdp) per kv head, word = one position of that head:
//   [KL*KW-1:0]          K lanes (KW-bit signed each, lane i = element i)
//   [+KL*VW]             V lanes (VW-bit signed)
//   [+AM_W], [+E_W]      ks = (km, ke)
//   [+AM_W], [+E_W]      vs = (vm, ve)
// Default KL 8, KW 12, VW 8: 96 + 64 + 25 + 25 = 210 bits (K12V8 packed, arch.md 4.2; BRAM36 x 3
// wide = 216). Address = layer * SEQ + position, depth NL x SEQ (5 x 512 = 2560: 5 BRAM36 deep,
// 15 per head, 60 for 4 heads [calculation]). Heads of size <= KL only (one word per position).
//
// Write: w_valid_i writes one word (K, V given as 16-bit containers; the low KW / VW bits are
// stored, values outside the KW / VW range are reported, L2_RANGE).
// Read: H_PAR ports. Port p serves pass requests (rq_*: pass 0 = K, 1 = V, kv head, layer, T) for
// kv heads with kvh mod H_PAR = p (static, so two ports never read one RAM; L2_RANGE otherwise)
// and delivers T beats, one per position t = 0..T-1, on kv_* (valid / ready): K or V lanes
// sign-extended to 16 bits and both scale pairs. A port accepts a request while idle (busy_o = 0);
// reads are issued while the output FIFO (FIFO_D) has room, RAM read latency 1, so the port
// streams 1 beat per cycle with an always-ready consumer.
module kv_store
  import llm_pkg::*;
#(
  parameter int NKV    = 4,
  parameter int NL     = 5,
  parameter int SEQ    = 512,
  parameter int KL     = 8,
  parameter int KW     = 12,
  parameter int VW     = 8,
  parameter int H_PAR  = 2,
  parameter int FIFO_D = 4,
  localparam int KVH_W = (NKV > 1) ? $clog2(NKV) : 1,
  localparam int L_W   = (NL > 1) ? $clog2(NL) : 1,
  localparam int TW    = $clog2(SEQ + 1),
  localparam int PW    = (SEQ > 1) ? $clog2(SEQ) : 1
) (
  input  logic                              clk,
  input  logic                              rst_n,
  // write
  input  logic                              w_valid_i,
  input  logic [KVH_W-1:0]                  w_kvh_i,
  input  logic [L_W-1:0]                    w_layer_i,
  input  logic [PW-1:0]                     w_pos_i,
  input  logic [KL*16-1:0]                  w_k_i,
  input  logic [KL*16-1:0]                  w_v_i,
  input  logic [AM_W-1:0]                   w_km_i,
  input  logic signed [E_W-1:0]             w_ke_i,
  input  logic [AM_W-1:0]                   w_vm_i,
  input  logic signed [E_W-1:0]             w_ve_i,
  // read ports
  input  logic [H_PAR-1:0]                  rq_valid_i,
  output logic [H_PAR-1:0]                  rq_ready_o,
  input  logic [H_PAR-1:0]                  rq_pass_i,
  input  wire  [H_PAR-1:0][KVH_W-1:0]       rq_kvh_i,
  input  wire  [H_PAR-1:0][L_W-1:0]         rq_layer_i,
  input  wire  [H_PAR-1:0][TW-1:0]          rq_t_i,
  output logic [H_PAR-1:0]                  kv_valid_o,
  input  logic [H_PAR-1:0]                  kv_ready_i,
  output logic [H_PAR-1:0][KL*16-1:0]       kv_data_o,
  output logic [H_PAR-1:0][AM_W-1:0]        kv_km_o,
  output logic [H_PAR-1:0][E_W-1:0]         kv_ke_o,
  output logic [H_PAR-1:0][AM_W-1:0]        kv_vm_o,
  output logic [H_PAR-1:0][E_W-1:0]         kv_ve_o,
  output logic [H_PAR-1:0]                  busy_o
);
  localparam int WW    = KL * KW + KL * VW + 2 * (AM_W + E_W);
  localparam int DEPTH = NL * SEQ;
  localparam int AW_   = $clog2(DEPTH);
  localparam int BW    = KL * 16 + 2 * (AM_W + E_W);   // FIFO beat
  localparam int FL_W  = $clog2(FIFO_D + 1);

  if (H_PAR < 1 || H_PAR > NKV) $error("kv_store: H_PAR=%0d must be 1..NKV (%0d)", H_PAR, NKV);
  if (KW < 2 || KW > 16 || VW < 2 || VW > 16) $error("kv_store: KW=%0d VW=%0d must be 2..16", KW, VW);
  if (FIFO_D < 2) $error("kv_store: FIFO_D=%0d must be >= 2", FIFO_D);

  // ---------------- word packing ----------------
  function automatic logic [WW-1:0] pack(logic [KL*16-1:0] k, logic [KL*16-1:0] v,
                                         logic [AM_W-1:0] km, logic [E_W-1:0] ke,
                                         logic [AM_W-1:0] vm, logic [E_W-1:0] ve);
    logic [WW-1:0] w;
    for (int l = 0; l < KL; l++) begin
      w[l*KW +: KW]           = k[l*16 +: KW];
      w[KL*KW + l*VW +: VW]   = v[l*16 +: VW];
    end
    w[KL*(KW+VW) +: 2*(AM_W+E_W)] = {ve, vm, ke, km};
    return w;
  endfunction

  // ---------------- RAMs ----------------
  logic [NKV-1:0]   r_re;
  logic [AW_-1:0]   r_ra [NKV];
  logic [WW-1:0]    r_rd [NKV];
  logic [AW_-1:0]   w_addr;
  logic [WW-1:0]    w_word;
  assign w_addr = AW_'(32'(w_layer_i) * SEQ + 32'(w_pos_i));
  assign w_word = pack(w_k_i, w_v_i, w_km_i, w_ke_i, w_vm_i, w_ve_i);

  for (genvar j = 0; j < NKV; j++) begin : g_ram
    ram_sdp #(.W(WW), .DEPTH(DEPTH), .RD_LAT(1)) u_ram (
      .clk, .rst_n, .we_i(w_valid_i && w_kvh_i == KVH_W'(j)), .waddr_i(w_addr), .wdata_i(w_word),
      .re_i(r_re[j]), .raddr_i(r_ra[j]), .rdata_o(r_rd[j]));
  end

  // ---------------- read ports ----------------
  logic [H_PAR-1:0]            iss;      // port issues a read this cycle
  logic [H_PAR-1:0][AW_-1:0]   iss_a;
  logic [H_PAR-1:0][KVH_W-1:0] kvh_q;

  for (genvar p = 0; p < H_PAR; p++) begin : g_port
    logic            run_q, pass_q, rv_q, pass_d;
    logic [L_W-1:0]  layer_q;
    logic [TW-1:0]   t_q, ti_q;          // T, positions issued
    logic [KVH_W-1:0] rk_q;              // head of the read in flight
    logic [FL_W-1:0] level;
    logic            f_in_ready;
    logic [BW-1:0]   f_din, f_dout;

    assign rq_ready_o[p] = !run_q;
    assign busy_o[p]     = run_q;
    assign iss[p]        = run_q && ti_q != t_q && 32'(level) + 32'(rv_q) < FIFO_D;
    assign iss_a[p]      = AW_'(32'(layer_q) * SEQ + 32'(ti_q));

    always_ff @(posedge clk or negedge rst_n)
      if (!rst_n) begin
        run_q <= 1'b0;
        rv_q  <= 1'b0;
      end else begin
        rv_q <= iss[p];
        if (rq_valid_i[p] && !run_q) run_q <= 1'b1;
        else if (run_q && ti_q == t_q) run_q <= 1'b0;
      end

    always_ff @(posedge clk) begin
      if (rq_valid_i[p] && !run_q) begin
        pass_q     <= rq_pass_i[p];
        kvh_q[p]   <= rq_kvh_i[p];
        layer_q    <= rq_layer_i[p];
        t_q        <= rq_t_i[p];
        ti_q       <= '0;
      end else if (iss[p]) ti_q <= ti_q + 1'b1;
      if (iss[p]) begin
        rk_q   <= kvh_q[p];
        pass_d <= pass_q;
      end
    end

    // decode the word read in the previous cycle
    always_comb begin
      logic [WW-1:0]     w;
      logic [KL*16-1:0]  lanes;
      w = r_rd[rk_q];
      for (int l = 0; l < KL; l++)
        lanes[l*16 +: 16] = pass_d ? 16'($signed(w[KL*KW + l*VW +: VW])) : 16'($signed(w[l*KW +: KW]));
      f_din = {lanes, w[KL*(KW+VW) +: 2*(AM_W+E_W)]};
    end

    sync_fifo #(.W(BW), .DEPTH(FIFO_D)) u_f (
      .clk, .rst_n, .in_valid_i(rv_q), .in_ready_o(f_in_ready), .in_data_i(f_din),
      .out_valid_o(kv_valid_o[p]), .out_ready_i(kv_ready_i[p]), .out_data_o(f_dout), .level_o(level));

    assign kv_data_o[p] = f_dout[BW-1 -: KL*16];
    assign {kv_ve_o[p], kv_vm_o[p], kv_ke_o[p], kv_km_o[p]} = f_dout[2*(AM_W+E_W)-1:0];

`ifndef SYNTHESIS
    always @(posedge clk)
      if (rst_n === 1'b1) begin
        if (rq_valid_i[p] === 1'b1 && !run_q && (32'(rq_kvh_i[p]) % H_PAR != p || 32'(rq_kvh_i[p]) >= NKV ||
            32'(rq_layer_i[p]) >= NL || rq_t_i[p] == '0 || 32'(rq_t_i[p]) > SEQ))
          $error("L2_RANGE kv_store %m: port %0d request kvh %0d layer %0d T %0d", p, rq_kvh_i[p],
                 rq_layer_i[p], rq_t_i[p]);
        if (rv_q && !f_in_ready) $error("L2_OVF kv_store %m: port %0d FIFO overflow", p);
      end
`endif
  end

  // RAM read address: RAM j is read by port j mod H_PAR
  always_comb
    for (int j = 0; j < NKV; j++) begin
      r_re[j] = iss[j % H_PAR] && kvh_q[j % H_PAR] == KVH_W'(j);
      r_ra[j] = iss_a[j % H_PAR];
    end

`ifndef SYNTHESIS
  always @(posedge clk)
    if (rst_n === 1'b1 && w_valid_i === 1'b1) begin
      if (32'(w_kvh_i) >= NKV || 32'(w_layer_i) >= NL || 32'(w_pos_i) >= SEQ)
        $error("L2_RANGE kv_store %m: write kvh %0d layer %0d pos %0d", w_kvh_i, w_layer_i, w_pos_i);
      for (int l = 0; l < KL; l++) begin
        if ($signed(w_k_i[l*16 +: 16]) != $signed(w_k_i[l*16 +: KW]))
          $error("L2_RANGE kv_store %m: K lane %0d = %0d outside %0d bits", l, $signed(w_k_i[l*16 +: 16]), KW);
        if ($signed(w_v_i[l*16 +: 16]) != $signed(w_v_i[l*16 +: VW]))
          $error("L2_RANGE kv_store %m: V lane %0d = %0d outside %0d bits", l, $signed(w_v_i[l*16 +: 16]), VW);
      end
    end
`endif

endmodule
