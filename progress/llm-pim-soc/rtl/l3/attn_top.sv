// attn_top: attention IP (L3, arch.md 4 and 7, hierarchy.md 1; register map, descriptor and run
// rules docs/spec/attn.md).
//
// op ATTN (layer command, D9): heads h = HEAD0 .. HEAD0 + NHEAD - 1 of one layer, T positions.
//   q record of head h at Q_ADDR + h QB (QB = 8 + 2 hs: {int32 qm, int32 qe}, then q int16 [hs])
//   o of head h  -> O_ADDR + 4 hs h (int32 [hs], the golden att + h hs layout)
//   p of head h  -> P_ADDR + PS h (int32 [T]) if FMT.p_en, PS = 8 ceil(T/2) (8-byte aligned)
//   kv head of h = h / KVMUL. KV_SRC 0: kv_store (layer LAYER, positions 0..T-1). KV_SRC 1: DDR in
//   the golden layout, kv head j position t at K_ADDR + (j SEQ + t) hs ek (V, KS, VS alike, scales
//   8 B), read by kv_rd.
// op KVW (KV_SRC 0 only): kv heads j = KVH0 .. KVH0 + NKVH - 1 of position POS: the rows at
//   K_ADDR + (j SEQ + POS) hs ek, V_ADDR + (j SEQ + POS) hs ev, KS_ADDR + 8 (j SEQ + POS),
//   VS_ADDR + 8 (j SEQ + POS) are written into kv_store[j] at LAYER x TMAX + POS.
//
// Structure (instances, wiring and the control of this level):
//   axil_slave + attn_csr            registers, descriptor check, run control
//   engine e < H_PAR: head sequencer (heads with (h / KVMUL) mod H_PAR = e, increasing h),
//     axi_rd_eng on read port e (q records; KV_SRC 1: KV through kv_rd e; engine 0: KVW rows),
//     q assembler (two 64-bit beats -> one 8-lane q beat), attn_core
//   kv_store (KV_SRC 0, read port e = engine e) or kv_rd x H_PAR (KV_SRC 1)
//   write arbiter: grants one engine's output stream (p then o of one head) at a time, issues
//     its write commands; packer (two 32-bit values per beat) + axi_wr_eng (write port)
// Call: the CTRL write s is checked by attn_csr in s + 1 .. v (v = s + CHK_CYC, sequential
// products); start in v, the op runs from v + 1 (go_q).
// Run end e: ATTN: every sequencer finished, no grant, packer empty, write engine idle (last B).
// KVW: the last kv head word written. CYCLES = e - s (check included).
// Addresses: every head / kv head / KVW slot address is a base plus a stride added when its
// counter advances (strides are shifts of the descriptor or the attn_csr products SEQ x hs,
// T x hs, KVH0 x SEQ + POS); no runtime multiplier at this level.
// RD_STALL: busy cycles in which some core waits for KV data; WR_STALL: packer beat not taken.
module attn_top
  import llm_pkg::*;
#(
  parameter int H_PAR     = 2,
  parameter int KV_SRC    = 0,
  parameter int KL        = 8,
  parameter int HS_MAX    = 8,
  parameter int TMAX      = 512,
  parameter int NKV       = 4,
  parameter int NL        = 5,
  parameter int KW        = 12,
  parameter int VW        = 8,
  parameter int CH        = 16,
  parameter int DOT_PIPE  = 2,
  parameter int SH_PIPE   = 1,
  parameter int RS_PIPE   = 1,
  parameter int LUT_PIPE  = 2,
  parameter int OUT_DEPTH = 16,
  parameter int MAX_BURST = 16,
  parameter int OUTS      = 4,
  parameter int RD_FIFO   = MAX_BURST * OUTS,
  parameter int WR_FIFO   = 2 * MAX_BURST,
  parameter int IDW       = 1,
  parameter int FCLK_MHZ  = 100,
  parameter int ADDR_W    = 12
) (
  input  logic                         clk,
  input  logic                         rst_n,
  // AXI4-Lite slave
  input  logic [ADDR_W-1:0]            s_axi_awaddr_i,
  input  logic [2:0]                   s_axi_awprot_i,
  input  logic                         s_axi_awvalid_i,
  output logic                         s_axi_awready_o,
  input  logic [31:0]                  s_axi_wdata_i,
  input  logic [3:0]                   s_axi_wstrb_i,
  input  logic                         s_axi_wvalid_i,
  output logic                         s_axi_wready_o,
  output logic [1:0]                   s_axi_bresp_o,
  output logic                         s_axi_bvalid_o,
  input  logic                         s_axi_bready_i,
  input  logic [ADDR_W-1:0]            s_axi_araddr_i,
  input  logic [2:0]                   s_axi_arprot_i,
  input  logic                         s_axi_arvalid_i,
  output logic                         s_axi_arready_o,
  output logic [31:0]                  s_axi_rdata_o,
  output logic [1:0]                   s_axi_rresp_o,
  output logic                         s_axi_rvalid_o,
  input  logic                         s_axi_rready_i,
  // AXI4 master write (p, o)
  output logic [IDW-1:0]               m_axi_awid_o,
  output logic [31:0]                  m_axi_awaddr_o,
  output logic [7:0]                   m_axi_awlen_o,
  output logic [2:0]                   m_axi_awsize_o,
  output logic [1:0]                   m_axi_awburst_o,
  output logic                         m_axi_awlock_o,
  output logic [3:0]                   m_axi_awcache_o,
  output logic [2:0]                   m_axi_awprot_o,
  output logic [3:0]                   m_axi_awqos_o,
  output logic                         m_axi_awvalid_o,
  input  logic                         m_axi_awready_i,
  output logic [63:0]                  m_axi_wdata_o,
  output logic [7:0]                   m_axi_wstrb_o,
  output logic                         m_axi_wlast_o,
  output logic                         m_axi_wvalid_o,
  input  logic                         m_axi_wready_i,
  input  logic [IDW-1:0]               m_axi_bid_i,
  input  logic [1:0]                   m_axi_bresp_i,
  input  logic                         m_axi_bvalid_i,
  output logic                         m_axi_bready_o,
  // AXI4 master read, one port per engine (q records, DDR KV, KVW rows on port 0)
  output logic [H_PAR-1:0][IDW-1:0]    m_axi_arid_o,
  output logic [H_PAR-1:0][31:0]       m_axi_araddr_o,
  output logic [H_PAR-1:0][7:0]        m_axi_arlen_o,
  output logic [H_PAR-1:0][2:0]        m_axi_arsize_o,
  output logic [H_PAR-1:0][1:0]        m_axi_arburst_o,
  output logic [H_PAR-1:0]             m_axi_arlock_o,
  output logic [H_PAR-1:0][3:0]        m_axi_arcache_o,
  output logic [H_PAR-1:0][2:0]        m_axi_arprot_o,
  output logic [H_PAR-1:0][3:0]        m_axi_arqos_o,
  output logic [H_PAR-1:0]             m_axi_arvalid_o,
  input  wire  [H_PAR-1:0] m_axi_arready_i,
  input  wire  [H_PAR-1:0][IDW-1:0] m_axi_rid_i,
  input  wire  [H_PAR-1:0][63:0] m_axi_rdata_i,
  input  wire  [H_PAR-1:0][1:0] m_axi_rresp_i,
  input  wire  [H_PAR-1:0] m_axi_rlast_i,
  input  wire  [H_PAR-1:0] m_axi_rvalid_i,
  output logic [H_PAR-1:0]             m_axi_rready_o
);
  localparam int HS_W  = $clog2(HS_MAX + 1);
  localparam int TW    = $clog2(TMAX + 1);
  localparam int KVH_W = (NKV > 1) ? $clog2(NKV) : 1;
  localparam int L_W   = (NL > 1) ? $clog2(NL) : 1;
  localparam int PW    = (TMAX > 1) ? $clog2(TMAX) : 1;
  localparam int HP_W  = (H_PAR > 1) ? $clog2(H_PAR) : 1;
  localparam int SQH_W = 16 + HS_W;    // attn_csr: SEQ x hs
  localparam int TH_W  = TW + HS_W;    // attn_csr: T x hs
  localparam int KW0_W = KVH_W + 17;   // attn_csr: KVH0 x SEQ + POS

  if (H_PAR != 1 && H_PAR != 2 && H_PAR != 4) $error("attn_top: H_PAR=%0d must be 1, 2 or 4", H_PAR);
  if (KV_SRC != 0 && KV_SRC != 1) $error("attn_top: KV_SRC=%0d must be 0 (BRAM) or 1 (DDR)", KV_SRC);
  if (KL != 8) $error("attn_top: KL=%0d must be 8", KL);
  if (HS_MAX % 8 != 0) $error("attn_top: HS_MAX=%0d must be a multiple of 8", HS_MAX);
  if (KV_SRC == 0 && HS_MAX < KL) $error("attn_top: HS_MAX=%0d must be >= KL for KV_SRC 0", HS_MAX);

  // ---------------- AXI4-Lite and CSR ----------------
  logic              wr_en, rd_en;
  logic [ADDR_W-1:0] wr_addr, rd_addr;
  logic [31:0]       wr_data, rd_data;

  axil_slave #(.ADDR_W(ADDR_W), .DATA_W(32)) u_axil (
    .clk, .rst_n,
    .s_axi_awaddr_i, .s_axi_awprot_i, .s_axi_awvalid_i, .s_axi_awready_o,
    .s_axi_wdata_i, .s_axi_wstrb_i, .s_axi_wvalid_i, .s_axi_wready_o,
    .s_axi_bresp_o, .s_axi_bvalid_o, .s_axi_bready_i,
    .s_axi_araddr_i, .s_axi_arprot_i, .s_axi_arvalid_i, .s_axi_arready_o,
    .s_axi_rdata_o, .s_axi_rresp_o, .s_axi_rvalid_o, .s_axi_rready_i,
    .wr_en_o(wr_en), .wr_addr_o(wr_addr), .wr_data_o(wr_data),
    .rd_en_o(rd_en), .rd_addr_o(rd_addr), .rd_data_i(rd_data));

  logic        start, op_kvw, busy, run_done, rd_err_ev, wr_err_ev, rd_stall_ev, wr_stall_ev;
  logic [31:0] d_qa, d_oa, d_pa, d_ka, d_va, d_ksa, d_vsa;
  logic [15:0] d_t, d_seq, d_pos;
  logic [7:0]  d_hs, d_h0, d_nh, d_kvmul, d_layer, d_kvh0, d_nkvh;
  logic [4:0]  d_kb, d_vb;
  logic        d_pen;
  logic [SQH_W-1:0] d_sqh;
  logic [TH_W-1:0]  d_ths;
  logic [KW0_W-1:0] d_kw0;

  attn_csr #(.ADDR_W(ADDR_W), .H_PAR(H_PAR), .KV_SRC(KV_SRC), .KL(KL), .HS_MAX(HS_MAX), .TMAX(TMAX),
             .NKV(NKV), .NL(NL), .KW(KW), .VW(VW), .FCLK_MHZ(FCLK_MHZ)) u_csr (
    .clk, .rst_n, .wr_en_i(wr_en), .wr_addr_i(wr_addr), .wr_data_i(wr_data), .rd_en_i(rd_en),
    .rd_addr_i(rd_addr), .rd_data_o(rd_data),
    .start_o(start), .op_kvw_o(op_kvw), .busy_o(busy), .done_i(run_done),
    .q_addr_o(d_qa), .o_addr_o(d_oa), .p_addr_o(d_pa), .k_addr_o(d_ka), .v_addr_o(d_va),
    .ks_addr_o(d_ksa), .vs_addr_o(d_vsa), .t_o(d_t), .hs_o(d_hs), .kb_o(d_kb), .vb_o(d_vb),
    .p_en_o(d_pen), .head0_o(d_h0), .nhead_o(d_nh), .kvmul_o(d_kvmul), .layer_o(d_layer),
    .kvh0_o(d_kvh0), .nkvh_o(d_nkvh), .seq_o(d_seq), .pos_o(d_pos),
    .seqhs_o(d_sqh), .ths_o(d_ths), .kw0_o(d_kw0),
    .rd_err_i(rd_err_ev), .wr_err_i(wr_err_ev), .rd_stall_i(rd_stall_ev), .wr_stall_i(wr_stall_ev));

  // run phase: start is the verdict cycle v of the CSR check; the descriptor is valid from the
  // accepted CTRL write on and the derived products from v (go_q = v + 1)
  logic go_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) go_q <= 1'b0;
    else        go_q <= start;

  // per-head strides (shifts of the descriptor; the head and kv head addresses are kept by
  // adding these strides when the head / kv head counters advance, no runtime multiplier)
  logic [31:0] rowk, rowv, qbytes, pstride, ostride, kstride, vstride, sstride;
  logic        ek2, ev2;
  assign ek2     = d_kb > 5'd8;
  assign ev2     = d_vb > 5'd8;
  assign rowk    = 32'(d_hs) << ek2;
  assign rowv    = 32'(d_hs) << ev2;
  assign qbytes  = 32'd8 + {23'd0, d_hs, 1'b0};                    // QB = 8 + 2 hs
  assign pstride = {12'd0, (17'(d_t) + 17'd1) >> 1, 3'b000};        // PS = 8 ceil(T/2)
  assign ostride = {22'd0, d_hs, 2'b00};                            // 4 hs
  assign kstride = 32'(d_sqh) << ek2;                               // SEQ hs ek
  assign vstride = 32'(d_sqh) << ev2;                               // SEQ hs ev
  assign sstride = {13'd0, d_seq, 3'b000};                          // 8 SEQ

  // ---------------- engines ----------------
  typedef enum logic [2:0] {ES_IDLE, ES_SCAN, ES_QCMD, ES_QHDR, ES_START, ES_RUN, ES_DONE} es_t;

  logic [H_PAR-1:0]            e_done, e_kvstall, e_rerr;
  logic [H_PAR-1:0]            o_valid, o_ready, o_last, o_is_o;
  logic [H_PAR-1:0][31:0]      o_data;
  logic [H_PAR-1:0][31:0]      e_pa, e_oa;     // p / o address of the engine's head h_q
  // kv_store ports (KV_SRC 0)
  logic [H_PAR-1:0]            ks_rq_valid, ks_rq_ready, ks_rq_pass, ks_valid, ks_ready, ks_busy;
  logic [H_PAR-1:0][KVH_W-1:0] ks_rq_kvh;
  logic [H_PAR-1:0][L_W-1:0]   ks_rq_layer;
  logic [H_PAR-1:0][TW-1:0]    ks_rq_t;
  logic [H_PAR-1:0][KL*16-1:0] ks_data;
  logic [H_PAR-1:0][AM_W-1:0]  ks_km, ks_vm;
  logic [H_PAR-1:0][E_W-1:0]   ks_ke, ks_ve;
  // KVW path on read port 0
  logic                        kw_cmd_valid, kw_d_ready;
  logic [31:0]                 kw_cmd_addr, kw_cmd_bytes;
  logic                        e0_cmd_ready, e0_d_valid;
  logic [63:0]                 e0_d_data;

  for (genvar e = 0; e < H_PAR; e++) begin : g_eng
    es_t             es_q;
    logic [7:0]      h_q, kvh_q, sub_q;
    logic [HS_W-1:0] qn_q;          // q record beats left after the header (hs / 4)
    logic            qhalf_q, qph_q;
    logic [63:0]     qlo_q;
    logic [AM_W-1:0] qm_q;
    logic [E_W-1:0]  qe_q;
    logic [31:0]     kb_q, vb_q, ksb_q, vsb_q;   // DDR KV bases of the kv head
    logic [31:0]     qa_q, pa_q, oa_q;           // Q_ADDR + h QB, P_ADDR + h PS, O_ADDR + 4 hs h
    logic [31:0]     kof_q, vof_q, sof_q;        // kv head kvh_q: kvh SEQ hs ek / ev, 8 kvh SEQ
    logic            mine, at_end, h_adv, kvh_adv, seq_go;

    // read engine
    logic        rc_valid, rc_ready, d_valid, d_ready, d_last;
    logic [31:0] rc_addr, rc_bytes;
    logic [63:0] d_data;
    logic        rd_ecmd;

    // core
    logic        c_start, c_busy, c_done, c_qv, c_qr, c_kvreq_v, c_kvreq_r, c_kvreq_pass;
    logic        c_kv_v, c_kv_r, c_kvstall;
    logic [KL*16-1:0] c_kv_d;
    logic [AM_W-1:0]  c_km, c_vm;
    logic [E_W-1:0]   c_ke, c_ve;

    assign mine   = 32'(kvh_q) % H_PAR == e && h_q >= d_h0;
    assign at_end = 9'(h_q) == 9'(d_h0) + 9'(d_nh);
    // the head counter advances (and the kv head counter with it after KVMUL heads)
    assign seq_go  = es_q == ES_IDLE && go_q && !op_kvw;
    assign h_adv   = (es_q == ES_SCAN && !at_end && !mine) || (es_q == ES_RUN && c_done);
    assign kvh_adv = h_adv && sub_q == d_kvmul - 1'b1;

    // ---- head sequencer ----
    always_ff @(posedge clk or negedge rst_n)
      if (!rst_n) begin
        es_q    <= ES_IDLE;
        h_q     <= '0;
        kvh_q   <= '0;
        sub_q   <= '0;
        qph_q   <= 1'b0;
        qhalf_q <= 1'b0;
        qn_q    <= '0;
      end else begin
        unique case (es_q)
          ES_IDLE: if (go_q && !op_kvw) begin
            es_q  <= ES_SCAN;
            h_q   <= '0;
            kvh_q <= '0;
            sub_q <= '0;
          end
          ES_SCAN:
            if (at_end) es_q <= ES_DONE;
            else if (mine) es_q <= ES_QCMD;
            else begin
              h_q <= h_q + 1'b1;
              if (sub_q == d_kvmul - 1'b1) begin
                sub_q <= '0;
                kvh_q <= kvh_q + 1'b1;
              end else sub_q <= sub_q + 1'b1;
            end
          ES_QCMD: if (rc_ready) begin
            es_q    <= ES_QHDR;
            qph_q   <= 1'b1;
            qhalf_q <= 1'b0;
            qn_q    <= HS_W'(d_hs >> 2);
          end
          ES_QHDR: if (d_valid) es_q <= ES_START;
          ES_START: es_q <= ES_RUN;
          ES_RUN: begin
            if (qph_q && d_valid && d_ready) begin
              qhalf_q <= !qhalf_q;
              qn_q    <= qn_q - 1'b1;
              if (qn_q == HS_W'(1)) qph_q <= 1'b0;
            end
            if (c_done) begin
              es_q <= ES_SCAN;
              h_q  <= h_q + 1'b1;
              if (sub_q == d_kvmul - 1'b1) begin
                sub_q <= '0;
                kvh_q <= kvh_q + 1'b1;
              end else sub_q <= sub_q + 1'b1;
            end
          end
          ES_DONE: if (run_done) es_q <= ES_IDLE;
          default: es_q <= ES_IDLE;
        endcase
      end

    always_ff @(posedge clk) begin
      if (es_q == ES_QHDR && d_valid) begin
        qm_q <= AM_W'(d_data[31:0]);
        qe_q <= E_W'(d_data[63:32]);
      end
      if (es_q == ES_RUN && qph_q && d_valid && d_ready && !qhalf_q) qlo_q <= d_data;
      if (es_q == ES_START) begin
        kb_q  <= d_ka + kof_q;
        vb_q  <= d_va + vof_q;
        ksb_q <= d_ksa + sof_q;
        vsb_q <= d_vsa + sof_q;
      end
      // head / kv head addresses (mod 2^32, equal to base + index x stride)
      if (seq_go) begin
        qa_q  <= d_qa;
        pa_q  <= d_pa;
        oa_q  <= d_oa;
        kof_q <= '0;
        vof_q <= '0;
        sof_q <= '0;
      end else begin
        if (h_adv) begin
          qa_q <= qa_q + qbytes;
          pa_q <= pa_q + pstride;
          oa_q <= oa_q + ostride;
        end
        if (kvh_adv) begin
          kof_q <= kof_q + kstride;
          vof_q <= vof_q + vstride;
          sof_q <= sof_q + sstride;
        end
      end
    end

    assign e_done[e] = es_q == ES_DONE;
    assign e_pa[e]   = pa_q;
    assign e_oa[e]   = oa_q;
    assign c_start   = es_q == ES_START;
    assign c_qv      = es_q == ES_RUN && qph_q && qhalf_q && d_valid;

    // ---- read port: q record, DDR KV, KVW (port 0) ----
    logic        kvr_rc_valid, kvr_d_ready;
    logic [31:0] kvr_rc_addr, kvr_rc_bytes;

    always_comb begin
      rc_valid = 1'b0;
      rc_addr  = qa_q;
      rc_bytes = qbytes;
      d_ready  = 1'b0;
      if (es_q == ES_QCMD) rc_valid = 1'b1;
      else if (e == 0 && busy && op_kvw) begin
        rc_valid = kw_cmd_valid;
        rc_addr  = kw_cmd_addr;
        rc_bytes = kw_cmd_bytes;
      end else if (KV_SRC == 1) begin
        rc_valid = kvr_rc_valid;
        rc_addr  = kvr_rc_addr;
        rc_bytes = kvr_rc_bytes;
      end
      if (es_q == ES_QHDR) d_ready = 1'b1;
      else if (es_q == ES_RUN && qph_q) d_ready = qhalf_q ? c_qr : 1'b1;
      else if (e == 0 && busy && op_kvw) d_ready = kw_d_ready;
      else if (KV_SRC == 1) d_ready = kvr_d_ready;
    end

    axi_rd_eng #(.AW(32), .IDW(IDW), .LEN_W(32), .MAX_BURST(MAX_BURST), .OUTS(OUTS),
                 .FIFO_DEPTH(RD_FIFO)) u_rd (
      .clk, .rst_n, .cfg_burst_i(9'd0), .cfg_outs_i(7'd0),
      .cmd_valid_i(rc_valid), .cmd_ready_o(rc_ready), .cmd_addr_i(rc_addr), .cmd_bytes_i(rc_bytes),
      .d_valid_o(d_valid), .d_ready_i(d_ready), .d_data_o(d_data), .d_last_o(d_last),
      .busy_o(), .done_o(), .stall_o(), .err_resp_o(), .err_cmd_o(rd_ecmd), .err_clr_i(start),
      .m_axi_arid_o(m_axi_arid_o[e]), .m_axi_araddr_o(m_axi_araddr_o[e]),
      .m_axi_arlen_o(m_axi_arlen_o[e]), .m_axi_arsize_o(m_axi_arsize_o[e]),
      .m_axi_arburst_o(m_axi_arburst_o[e]), .m_axi_arlock_o(m_axi_arlock_o[e]),
      .m_axi_arcache_o(m_axi_arcache_o[e]), .m_axi_arprot_o(m_axi_arprot_o[e]),
      .m_axi_arqos_o(m_axi_arqos_o[e]), .m_axi_arvalid_o(m_axi_arvalid_o[e]),
      .m_axi_arready_i(m_axi_arready_i[e]), .m_axi_rid_i(m_axi_rid_i[e]),
      .m_axi_rdata_i(m_axi_rdata_i[e]), .m_axi_rresp_i(m_axi_rresp_i[e]),
      .m_axi_rlast_i(m_axi_rlast_i[e]), .m_axi_rvalid_i(m_axi_rvalid_i[e]),
      .m_axi_rready_o(m_axi_rready_o[e]));

    if (e == 0) begin : g_kw
      assign e0_cmd_ready = rc_ready;
      assign e0_d_valid   = d_valid;
      assign e0_d_data    = d_data;
    end

    assign e_rerr[e] = m_axi_rvalid_i[e] && m_axi_rready_o[e] && m_axi_rresp_i[e][1];

    // ---- core ----
    attn_core #(.KL(KL), .VL(KL), .HS_MAX(HS_MAX), .TMAX(TMAX), .DOT_PIPE(DOT_PIPE),
                .SH_PIPE(SH_PIPE), .RS_PIPE(RS_PIPE), .LUT_PIPE(LUT_PIPE),
                .OUT_DEPTH(OUT_DEPTH)) u_core (
      .clk, .rst_n,
      .start_i(c_start), .t_i(TW'(d_t)), .hs_i(HS_W'(d_hs)), .kb_i(d_kb), .qm_i(qm_q), .qe_i(qe_q),
      .p_en_i(d_pen), .busy_o(c_busy), .done_o(c_done),
      .q_valid_i(c_qv), .q_ready_o(c_qr), .q_data_i({d_data, qlo_q}),
      .kvreq_valid_o(c_kvreq_v), .kvreq_ready_i(c_kvreq_r), .kvreq_pass_o(c_kvreq_pass),
      .kv_valid_i(c_kv_v), .kv_ready_o(c_kv_r), .kv_data_i(c_kv_d), .kv_km_i(c_km), .kv_ke_i(c_ke),
      .kv_vm_i(c_vm), .kv_ve_i(c_ve),
      .out_valid_o(o_valid[e]), .out_ready_i(o_ready[e]), .out_data_o(o_data[e]),
      .out_last_o(o_last[e]), .out_is_o_o(o_is_o[e]), .kv_stall_o(c_kvstall));
    assign e_kvstall[e] = c_kvstall;

    // ---- KV source ----
    if (KV_SRC == 0) begin : g_bram
      assign ks_rq_valid[e] = c_kvreq_v;
      assign c_kvreq_r      = ks_rq_ready[e];
      assign ks_rq_pass[e]  = c_kvreq_pass;
      assign ks_rq_kvh[e]   = KVH_W'(kvh_q);
      assign ks_rq_layer[e] = L_W'(d_layer);
      assign ks_rq_t[e]     = TW'(d_t);
      assign c_kv_v         = ks_valid[e];
      assign ks_ready[e]    = c_kv_r;
      assign c_kv_d         = ks_data[e];
      assign c_km = ks_km[e]; assign c_ke = ks_ke[e]; assign c_vm = ks_vm[e]; assign c_ve = ks_ve[e];
      assign kvr_rc_valid = 1'b0; assign kvr_rc_addr = '0; assign kvr_rc_bytes = '0;
      assign kvr_d_ready  = 1'b0;
    end else begin : g_ddr
      kv_rd #(.KL(KL), .HS_MAX(HS_MAX), .TMAX(TMAX), .CH(CH)) u_kvr (
        .clk, .rst_n,
        .rq_valid_i(c_kvreq_v), .rq_ready_o(c_kvreq_r), .rq_pass_i(c_kvreq_pass), .rq_t_i(TW'(d_t)),
        .rq_hs_i(HS_W'(d_hs)), .rq_ths_i(d_ths), .rq_ek2_i(ek2), .rq_ev2_i(ev2), .rq_kaddr_i(kb_q),
        .rq_vaddr_i(vb_q),
        .rq_ksaddr_i(ksb_q), .rq_vsaddr_i(vsb_q),
        .rc_valid_o(kvr_rc_valid), .rc_ready_i(rc_ready && es_q != ES_QCMD), .rc_addr_o(kvr_rc_addr),
        .rc_bytes_o(kvr_rc_bytes),
        .d_valid_i(d_valid && !qph_q && es_q == ES_RUN), .d_ready_o(kvr_d_ready), .d_data_i(d_data),
        .kv_valid_o(c_kv_v), .kv_ready_i(c_kv_r), .kv_data_o(c_kv_d), .kv_km_o(c_km), .kv_ke_o(c_ke),
        .kv_vm_o(c_vm), .kv_ve_o(c_ve), .busy_o());
      assign ks_rq_valid[e] = 1'b0; assign ks_rq_pass[e] = 1'b0; assign ks_rq_kvh[e] = '0;
      assign ks_rq_layer[e] = '0; assign ks_rq_t[e] = '0; assign ks_ready[e] = 1'b0;
    end

    logic unused_e;
    assign unused_e = d_last ^ c_busy;

`ifndef SYNTHESIS
    logic c_ecmd_q;
    always @(posedge clk) begin
      if (rst_n === 1'b1 && rd_ecmd && !c_ecmd_q)
        $error("L3_ENGCMD attn_top %m: read engine %0d rejected a command", e);
      c_ecmd_q <= (rst_n === 1'b1) && rd_ecmd;
      if (rst_n === 1'b1 && d_valid === 1'b1 && (es_q == ES_SCAN || es_q == ES_DONE ||
          (es_q == ES_IDLE && !(e == 0 && busy && op_kvw))))
        $error("L3_RDATA attn_top %m: read data on port %0d outside a phase that takes it", e);
    end
`endif
  end

  // ---------------- kv_store (KV_SRC 0) ----------------
  logic             kw_w_valid;
  logic [KVH_W-1:0] kw_w_kvh;
  logic [KL*16-1:0] kw_k, kw_v;
  logic [AM_W-1:0]  kw_km, kw_vm;
  logic [E_W-1:0]   kw_ke, kw_ve;

  if (KV_SRC == 0) begin : g_store
    kv_store #(.NKV(NKV), .NL(NL), .SEQ(TMAX), .KL(KL), .KW(KW), .VW(VW), .H_PAR(H_PAR)) u_kvs (
      .clk, .rst_n,
      .w_valid_i(kw_w_valid), .w_kvh_i(kw_w_kvh), .w_layer_i(L_W'(d_layer)), .w_pos_i(PW'(d_pos)),
      .w_k_i(kw_k), .w_v_i(kw_v), .w_km_i(kw_km), .w_ke_i(kw_ke), .w_vm_i(kw_vm), .w_ve_i(kw_ve),
      .rq_valid_i(ks_rq_valid), .rq_ready_o(ks_rq_ready), .rq_pass_i(ks_rq_pass),
      .rq_kvh_i(ks_rq_kvh), .rq_layer_i(ks_rq_layer), .rq_t_i(ks_rq_t),
      .kv_valid_o(ks_valid), .kv_ready_i(ks_ready), .kv_data_o(ks_data), .kv_km_o(ks_km),
      .kv_ke_o(ks_ke), .kv_vm_o(ks_vm), .kv_ve_o(ks_ve), .busy_o(ks_busy));
  end else begin : g_nostore
    assign ks_rq_ready = '0; assign ks_valid = '0; assign ks_data = '0; assign ks_km = '0;
    assign ks_ke = '0; assign ks_vm = '0; assign ks_ve = '0; assign ks_busy = '0;
  end

  // ---------------- KVW (read port 0 -> kv_store) ----------------
  // command side: per kv head 4 commands (K row, V row, ks, vs); data side: K beats, V beats,
  // ks beat, vs beat -> one kv_store word
  logic [7:0]  kwc_j, kwd_j;          // command / data kv head
  logic [1:0]  kwc_k, kwd_k;          // 0 K, 1 V, 2 ks, 3 vs
  logic        kwc_act, kwd_act, kwd_h, kw_done_q;
  logic [KW0_W-1:0] kw_slot_q;        // source slot kwc_j SEQ + POS (from KVH0 SEQ + POS, + SEQ)
  logic [63:0] kw_lo_q;
  logic [31:0] kw_s32;
  assign kw_s32 = 32'(kw_slot_q);

  // KVW has hs = KL = 8 (attn_csr: hs <= KL, hs % 8 == 0), so a row is 8 << ek bytes
  always_comb begin
    kw_cmd_valid = kwc_act;
    unique case (kwc_k)
      2'd0:    begin kw_cmd_addr = d_ka + (kw_s32 << (3 + 32'(ek2)));  kw_cmd_bytes = rowk; end
      2'd1:    begin kw_cmd_addr = d_va + (kw_s32 << (3 + 32'(ev2)));  kw_cmd_bytes = rowv; end
      2'd2:    begin kw_cmd_addr = d_ksa + {kw_s32[28:0], 3'b000};      kw_cmd_bytes = 32'd8; end
      default: begin kw_cmd_addr = d_vsa + {kw_s32[28:0], 3'b000};      kw_cmd_bytes = 32'd8; end
    endcase
  end
  assign kw_d_ready = kwd_act;

  logic kw_hs, kw_sub_last;
  assign kw_hs       = kwd_act && e0_d_valid;
  assign kw_sub_last = kwd_k >= 2'd2 || !(kwd_k == 2'd0 ? ek2 : ev2) || kwd_h;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      kwc_act <= 1'b0; kwd_act <= 1'b0; kwc_j <= '0; kwd_j <= '0; kwc_k <= '0; kwd_k <= '0;
      kwd_h <= 1'b0; kw_done_q <= 1'b0; kw_w_valid <= 1'b0;
    end else begin
      kw_w_valid <= 1'b0;
      kw_done_q  <= 1'b0;
      if (go_q && op_kvw) begin
        kwc_act <= 1'b1; kwd_act <= 1'b1; kwc_j <= d_kvh0; kwd_j <= d_kvh0; kwc_k <= '0; kwd_k <= '0;
        kwd_h <= 1'b0;
      end
      if (kwc_act && e0_cmd_ready) begin
        kwc_k <= kwc_k + 1'b1;
        if (kwc_k == 2'd3) begin
          kwc_j <= kwc_j + 1'b1;
          if (kwc_j == d_kvh0 + d_nkvh - 1'b1) kwc_act <= 1'b0;
        end
      end

      if (kw_hs) begin
        kwd_h <= !kw_sub_last;
        if (kw_sub_last) begin
          kwd_k <= kwd_k + 1'b1;
          if (kwd_k == 2'd3) begin
            kw_w_valid <= 1'b1;
            kwd_j      <= kwd_j + 1'b1;
            if (kwd_j == d_kvh0 + d_nkvh - 1'b1) begin
              kwd_act   <= 1'b0;
              kw_done_q <= 1'b1;
            end
          end
        end
      end
    end

  always_ff @(posedge clk) begin
    if (go_q && op_kvw) kw_slot_q <= d_kw0;
    else if (kwc_act && e0_cmd_ready && kwc_k == 2'd3) kw_slot_q <= kw_slot_q + KW0_W'(d_seq);
    if (kw_hs && !kw_sub_last) kw_lo_q <= e0_d_data;
    if (kw_hs && kw_sub_last)
      unique case (kwd_k)
        2'd0, 2'd1: begin
          logic [KL*16-1:0] l;
          for (int i = 0; i < KL; i++)
            l[i*16 +: 16] = (kwd_k == 2'd0 ? ek2 : ev2)
                              ? ((i < 4) ? kw_lo_q[i*16 +: 16] : e0_d_data[(i-4)*16 +: 16])
                              : 16'($signed(e0_d_data[i*8 +: 8]));
          if (kwd_k == 2'd0) kw_k <= l;
          else               kw_v <= l;
        end
        2'd2: begin kw_km <= AM_W'(e0_d_data[31:0]); kw_ke <= E_W'(e0_d_data[63:32]); end
        default: begin
          kw_vm    <= AM_W'(e0_d_data[31:0]);
          kw_ve    <= E_W'(e0_d_data[63:32]);
          kw_w_kvh <= KVH_W'(kwd_j);
        end
      endcase
  end

  // ---------------- write arbiter, packer, write engine ----------------
  logic            g_act_q;
  logic [HP_W-1:0] g_sel_q;
  logic [1:0]      wc_n_q;          // write commands left for the grant (p, o)
  logic            wc_p_q;          // next command is p
  logic [31:0]     g_pa_q, g_oa_q;  // p / o address of the granted head
  logic            wcmd_valid, wcmd_ready, pk_ready, in_hs, in_last, in_is_o, wr_in_ready, emit;
  logic [31:0]     wcmd_addr, wcmd_bytes, in_data;
  logic            pk_valid_q, half_q;
  logic [63:0]     pk_data_q;
  logic [31:0]     lo_q;
  logic            sel_valid;
  logic [HP_W-1:0] sel;

  always_comb begin
    sel_valid = 1'b0;
    sel       = '0;
    for (int e = H_PAR - 1; e >= 0; e--)
      if (o_valid[e]) begin
        sel_valid = 1'b1;
        sel       = HP_W'(e);
      end
  end

  assign in_data = o_data[g_sel_q];
  assign in_last = o_last[g_sel_q];
  assign in_is_o = o_is_o[g_sel_q];
  always_comb
    for (int e = 0; e < H_PAR; e++) o_ready[e] = g_act_q && g_sel_q == HP_W'(e) && pk_ready;
  assign in_hs = g_act_q && o_valid[g_sel_q] && pk_ready;

  assign wcmd_valid = wc_n_q != '0;
  assign wcmd_addr  = wc_p_q ? g_pa_q : g_oa_q;
  assign wcmd_bytes = wc_p_q ? {14'd0, d_t, 2'b00} : ostride;     // 4 T, 4 hs

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      g_act_q <= 1'b0;
      g_sel_q <= '0;
      wc_n_q  <= '0;
      wc_p_q  <= 1'b0;
    end else begin
      if (!g_act_q && sel_valid && wc_n_q == '0) begin
        g_act_q  <= 1'b1;
        g_sel_q  <= sel;
        g_pa_q   <= e_pa[sel];
        g_oa_q   <= e_oa[sel];
        wc_n_q   <= d_pen ? 2'd2 : 2'd1;
        wc_p_q   <= d_pen;
      end else begin
        if (in_hs && in_last && in_is_o) g_act_q <= 1'b0;
        if (wcmd_valid && wcmd_ready) begin
          wc_n_q <= wc_n_q - 1'b1;
          wc_p_q <= 1'b0;
        end
      end
    end

  assign pk_ready = !pk_valid_q || wr_in_ready;
  assign emit     = in_hs && (half_q || in_last);
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      pk_valid_q <= 1'b0;
      half_q     <= 1'b0;
    end else begin
      if (emit) pk_valid_q <= 1'b1;
      else if (wr_in_ready) pk_valid_q <= 1'b0;
      if (in_hs) half_q <= !half_q && !in_last;
    end
  always_ff @(posedge clk) begin
    if (in_hs && !half_q) lo_q <= in_data;
    if (emit) pk_data_q <= half_q ? {in_data, lo_q} : {32'd0, in_data};
  end

  logic wr_busy, wr_ecmd;
  axi_wr_eng #(.AW(32), .IDW(IDW), .LEN_W(32), .MAX_BURST(MAX_BURST), .OUTS(OUTS),
               .FIFO_DEPTH(WR_FIFO)) u_wr (
    .clk, .rst_n, .cfg_burst_i(9'd0), .cfg_outs_i(7'd0),
    .cmd_valid_i(wcmd_valid), .cmd_ready_o(wcmd_ready), .cmd_addr_i(wcmd_addr), .cmd_bytes_i(wcmd_bytes),
    .in_valid_i(pk_valid_q), .in_ready_o(wr_in_ready), .in_data_i(pk_data_q),
    .busy_o(wr_busy), .done_o(), .stall_o(wr_stall_ev), .err_resp_o(), .err_cmd_o(wr_ecmd),
    .err_clr_i(start),
    .m_axi_awid_o, .m_axi_awaddr_o, .m_axi_awlen_o, .m_axi_awsize_o, .m_axi_awburst_o,
    .m_axi_awlock_o, .m_axi_awcache_o, .m_axi_awprot_o, .m_axi_awqos_o, .m_axi_awvalid_o,
    .m_axi_awready_i, .m_axi_wdata_o, .m_axi_wstrb_o, .m_axi_wlast_o, .m_axi_wvalid_o,
    .m_axi_wready_i, .m_axi_bid_i, .m_axi_bresp_i, .m_axi_bvalid_i, .m_axi_bready_o);

  // ---------------- run end, events ----------------
  logic attn_done;
  assign attn_done = &e_done && !g_act_q && wc_n_q == '0 && !pk_valid_q && !wr_busy;
  assign run_done  = busy && !go_q && (op_kvw ? kw_done_q : attn_done);

  assign rd_stall_ev = |e_kvstall;
  assign rd_err_ev   = |e_rerr;
  assign wr_err_ev   = m_axi_bvalid_i && m_axi_bready_o && m_axi_bresp_i[1];

`ifndef SYNTHESIS
  logic c_wecmd_q;
  always @(posedge clk) begin
    if (rst_n === 1'b1 && wr_ecmd && !c_wecmd_q)
      $error("L3_ENGCMD attn_top %m: the write engine rejected a command");
    c_wecmd_q <= (rst_n === 1'b1) && wr_ecmd;
    if (rst_n === 1'b1 && go_q && op_kvw && 32'(d_hs) != KL)
      $error("L3_KVWHS attn_top %m: KVW with hs %0d != KL (rows of 8 << ek bytes assumed)", d_hs);
  end
`endif

endmodule
