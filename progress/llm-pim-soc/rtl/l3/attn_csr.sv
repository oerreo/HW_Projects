// attn_csr: register file, descriptor check and run control of the attention IP attn_top (L3).
// Register map and rules: docs/spec/attn.md (common frame arch.md 7.2; the decided behaviour of
// gemv_acc_csr / pim_csr: done_sticky priority, W1C with set winning, undefined addresses read 0,
// WSTRB ignored, a read in the cycle of a write returns the state before the write).
//
//   0x00 ID       R     0x4154_0001 ("AT", version 1)
//   0x04 CONFIG   R     [7:0] FCLK_MHZ, [10:8] H_PAR, [11] KV_SRC (0 BRAM, 1 DDR), [15:12] log2(KL),
//                       [31:16] TMAX
//   0x08 CTRL     W     bit0 start, [7:4] op (1 = ATTN, 2 = KVW); reads 0
//   0x0C STATUS   R     bit0 busy, bit1 done_sticky, bit2 err_any
//   0x10 ERR      R/W1C bit0 START_BUSY, bit1 BAD_OP, bit2 BAD_DESC, bit3 MISALIGN, bit4 RD_RESP,
//                       bit5 WR_RESP
//   0x14 CYCLES   R     cycles of the last op (start to done)
//   0x18 RD_STALL R     cycles of the last op in which a core waited for KV data
//   0x1C WR_STALL R     cycles of the last op in which the output packer was held by the writer
//   0x20 OPS      R     ops completed since reset (ATTN + KVW)
//   0x24 CONFIG2  R     [7:0] HS_MAX, [15:8] NKV, [23:16] NL (BRAM KV; 0 for DDR)
//   0x28 CONFIG3  R     [7:0] KW, [15:8] VW (BRAM word element bits), [31:16] SEQ_B (BRAM positions)
//   0x40 Q_ADDR, 0x44 O_ADDR, 0x48 P_ADDR, 0x4C K_ADDR, 0x50 V_ADDR, 0x54 KS_ADDR, 0x58 VS_ADDR  RW
//   0x5C T [15:0]   0x60 HS [7:0]   0x64 FMT [4:0] kb, [12:8] vb, [16] p_en
//   0x68 HEAD [7:0] HEAD0, [15:8] NHEAD, [23:16] KVMUL      0x6C LAYER [7:0]
//   0x70 SEQ [15:0] (position stride of kv heads in the DDR KV / KVW source buffers)
//   0x74 POS [15:0] (KVW position)   0x78 KVH [7:0] KVH0, [15:8] NKVH (KVW kv heads)   RW
// Descriptor registers keep the written bits of their fields (other bits read 0).
//
// Start (CTRL write in cycle s while idle = !busy or the done cycle):
//   op 1 ATTN / op 2 KVW with a legal descriptor: start_o, the descriptor is latched (run_* valid
//   from s + 1), done_sticky cleared, CYCLES / RD_STALL / WR_STALL cleared.
//   op 1 / 2 with descriptor errors: BAD_DESC and / or MISALIGN, no start, done_sticky cleared.
//   op 2 with KV_SRC = 1 (no on-chip KV) or another op: BAD_OP only.
//   start = 0: done_sticky cleared. While busy (not the done cycle): start = 1 -> START_BUSY
//   (+ BAD_OP for an illegal op), ignored.
// Checks (docs/spec/attn.md 4): see the c_* signals below.
module attn_csr
  import llm_pkg::*;
#(
  parameter int ADDR_W   = 12,
  parameter int H_PAR    = 2,
  parameter int KV_SRC   = 0,
  parameter int KL       = 8,
  parameter int HS_MAX   = 8,
  parameter int TMAX     = 512,
  parameter int NKV      = 4,
  parameter int NL       = 5,
  parameter int KW       = 12,
  parameter int VW       = 8,
  parameter int FCLK_MHZ = 100
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              wr_en_i,
  input  logic [ADDR_W-1:0] wr_addr_i,
  input  logic [31:0]       wr_data_i,
  input  logic              rd_en_i,
  input  logic [ADDR_W-1:0] rd_addr_i,
  output logic [31:0]       rd_data_o,
  // run control
  output logic              start_o,
  output logic              op_kvw_o,      // latched: 1 = KVW, 0 = ATTN
  output logic              busy_o,
  input  logic              done_i,
  // latched descriptor (valid from s + 1)
  output logic [31:0]       q_addr_o, o_addr_o, p_addr_o, k_addr_o, v_addr_o, ks_addr_o, vs_addr_o,
  output logic [15:0]       t_o,
  output logic [7:0]        hs_o,
  output logic [4:0]        kb_o, vb_o,
  output logic              p_en_o,
  output logic [7:0]        head0_o, nhead_o, kvmul_o, layer_o, kvh0_o, nkvh_o,
  output logic [15:0]       seq_o, pos_o,
  // events
  input  logic              rd_err_i,
  input  logic              wr_err_i,
  input  logic              rd_stall_i,
  input  logic              wr_stall_i
);
  if (ADDR_W < 8 || ADDR_W > 32) $error("attn_csr: ADDR_W=%0d must be 8..32", ADDR_W);
  if (H_PAR < 1 || H_PAR > 7) $error("attn_csr: H_PAR=%0d does not fit CONFIG[10:8]", H_PAR);
  if (TMAX < 1 || TMAX > 65535) $error("attn_csr: TMAX=%0d must be 1..65535", TMAX);
  if (HS_MAX < 8 || HS_MAX > 255) $error("attn_csr: HS_MAX=%0d must be 8..255", HS_MAX);

  localparam logic [31:0] ID_VAL      = 32'h4154_0001;
  localparam logic [31:0] CONFIG_VAL  = {16'(TMAX), 4'($clog2(KL)), 1'(KV_SRC), 3'(H_PAR), 8'(FCLK_MHZ)};
  localparam logic [31:0] CONFIG2_VAL = KV_SRC ? {8'd0, 8'd0, 8'd0, 8'(HS_MAX)}
                                               : {8'd0, 8'(NL), 8'(NKV), 8'(HS_MAX)};
  localparam logic [31:0] CONFIG3_VAL = KV_SRC ? 32'd0 : {16'(TMAX), 8'(VW), 8'(KW)};
  localparam int E_START_BUSY = 0, E_BAD_OP = 1, E_BAD_DESC = 2, E_MISALIGN = 3, E_RD_RESP = 4,
                 E_WR_RESP = 5, ERR_W = 6;

  localparam logic [5:0] R_ID = 6'h00, R_CONFIG = 6'h01, R_CTRL = 6'h02, R_STATUS = 6'h03,
                         R_ERR = 6'h04, R_CYCLES = 6'h05, R_RDSTALL = 6'h06, R_WRSTALL = 6'h07,
                         R_OPS = 6'h08, R_CONFIG2 = 6'h09, R_CONFIG3 = 6'h0A,
                         R_QA = 6'h10, R_OA = 6'h11, R_PA = 6'h12, R_KA = 6'h13, R_VA = 6'h14,
                         R_KSA = 6'h15, R_VSA = 6'h16, R_T = 6'h17, R_HS = 6'h18, R_FMT = 6'h19,
                         R_HEAD = 6'h1A, R_LAYER = 6'h1B, R_SEQ = 6'h1C, R_POS = 6'h1D, R_KVH = 6'h1E;

  // ---------------- decode ----------------
  logic        wr_hit, rd_hit;
  logic [5:0]  wr_w, rd_w;
  logic [31:0] wr_a32, rd_a32;
  assign wr_a32 = 32'(wr_addr_i);
  assign rd_a32 = 32'(rd_addr_i);
  assign wr_hit = wr_en_i && (wr_a32[31:8] == 24'd0);
  assign rd_hit = rd_a32[31:8] == 24'd0;
  assign wr_w   = wr_a32[7:2];
  assign rd_w   = rd_a32[7:2];

  // ---------------- descriptor registers ----------------
  logic [31:0] qa_r, oa_r, pa_r, ka_r, va_r, ksa_r, vsa_r;
  logic [15:0] t_r, seq_r, pos_r;
  logic [7:0]  hs_r, h0_r, nh_r, km_r, ly_r, kv0_r, nkv_r;
  logic [4:0]  kb_r, vb_r;
  logic        pen_r;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      qa_r <= '0; oa_r <= '0; pa_r <= '0; ka_r <= '0; va_r <= '0; ksa_r <= '0; vsa_r <= '0;
      t_r <= '0; seq_r <= '0; pos_r <= '0; hs_r <= '0; h0_r <= '0; nh_r <= '0; km_r <= '0;
      ly_r <= '0; kv0_r <= '0; nkv_r <= '0; kb_r <= '0; vb_r <= '0; pen_r <= 1'b0;
    end else if (wr_hit)
      unique case (wr_w)
        R_QA:    qa_r  <= wr_data_i;
        R_OA:    oa_r  <= wr_data_i;
        R_PA:    pa_r  <= wr_data_i;
        R_KA:    ka_r  <= wr_data_i;
        R_VA:    va_r  <= wr_data_i;
        R_KSA:   ksa_r <= wr_data_i;
        R_VSA:   vsa_r <= wr_data_i;
        R_T:     t_r   <= wr_data_i[15:0];
        R_HS:    hs_r  <= wr_data_i[7:0];
        R_FMT:   begin kb_r <= wr_data_i[4:0]; vb_r <= wr_data_i[12:8]; pen_r <= wr_data_i[16]; end
        R_HEAD:  begin h0_r <= wr_data_i[7:0]; nh_r <= wr_data_i[15:8]; km_r <= wr_data_i[23:16]; end
        R_LAYER: ly_r  <= wr_data_i[7:0];
        R_SEQ:   seq_r <= wr_data_i[15:0];
        R_POS:   pos_r <= wr_data_i[15:0];
        R_KVH:   begin kv0_r <= wr_data_i[7:0]; nkv_r <= wr_data_i[15:8]; end
        default: ;
      endcase

  // ---------------- descriptor checks ----------------
  localparam logic [33:0] LIM = 34'h1_0000_0000;   // 2^32
  logic        fmt_ok, hs_ok, t_ok;
  logic [8:0]  hend;          // HEAD0 + NHEAD
  logic [7:0]  kvmax;         // (HEAD0 + NHEAD - 1) / KVMUL
  logic [31:0] rowk, rowv, qb;
  logic        a_desc_ok, a_align_ok, w_desc_ok, w_align_ok;

  assign fmt_ok = (kb_r == 5'd8 || kb_r == 5'd12 || kb_r == 5'd16) &&
                  (vb_r == 5'd8 || vb_r == 5'd12 || vb_r == 5'd16);
  assign hs_ok  = hs_r != '0 && hs_r[2:0] == 3'd0 && 32'(hs_r) <= HS_MAX;
  assign t_ok   = t_r != '0 && 32'(t_r) <= TMAX;
  assign hend   = 9'(h0_r) + 9'(nh_r);
  assign kvmax  = 8'((32'(hend) - 1) / ((km_r == '0) ? 32'd1 : 32'(km_r)));   // KVMUL 0 is BAD_DESC
  assign rowk   = 32'(hs_r) << (kb_r > 5'd8);
  assign rowv   = 32'(hs_r) << (vb_r > 5'd8);
  assign qb     = 32'd8 + 32'(hs_r) * 2;

  // byte ranges (34-bit sums of products; operands are at most 32 x 24 bits)
  logic [33:0] q_end, o_end, p_end, ka_end, va_end, ksa_end, vsa_end;
  logic [33:0] wk_end, wv_end, wks_end, wvs_end;
  logic [31:0] a_slot, w_slot;    // last position slot + 1 of the DDR KV / KVW source
  assign a_slot  = 32'(kvmax) * 32'(seq_r) + 32'(t_r);
  assign w_slot  = (32'(kv0_r) + 32'(nkv_r) - 1) * 32'(seq_r) + 32'(pos_r) + 1;
  assign q_end   = 34'(qa_r) + 34'(64'(hend) * 64'(qb));
  assign o_end   = 34'(oa_r) + 34'(64'(hend) * 64'(hs_r) * 4);
  assign p_end   = 34'(pa_r) + 34'(64'(hend) * ((64'(t_r) + 1) >> 1) * 8);   // p stride 8 ceil(T/2)
  assign ka_end  = 34'(ka_r) + 34'(64'(a_slot) * 64'(rowk));
  assign va_end  = 34'(va_r) + 34'(64'(a_slot) * 64'(rowv));
  assign ksa_end = 34'(ksa_r) + 34'(64'(a_slot) * 8);
  assign vsa_end = 34'(vsa_r) + 34'(64'(a_slot) * 8);
  assign wk_end  = 34'(ka_r) + 34'(64'(w_slot) * 64'(rowk));
  assign wv_end  = 34'(va_r) + 34'(64'(w_slot) * 64'(rowv));
  assign wks_end = 34'(ksa_r) + 34'(64'(w_slot) * 8);
  assign wvs_end = 34'(vsa_r) + 34'(64'(w_slot) * 8);

  always_comb begin
    a_desc_ok = fmt_ok && hs_ok && t_ok && nh_r != '0 && km_r != '0 && hend <= 9'd256 &&
                q_end <= LIM && o_end <= LIM && (!pen_r || p_end <= LIM);
    if (KV_SRC == 0)
      a_desc_ok = a_desc_ok && 32'(hs_r) <= KL && 32'(kb_r) <= KW && 32'(vb_r) <= VW &&
                  32'(ly_r) < NL && 32'(kvmax) < NKV;
    else
      a_desc_ok = a_desc_ok && 32'(t_r) <= 32'(seq_r) && ka_end <= LIM && va_end <= LIM &&
                  ksa_end <= LIM && vsa_end <= LIM;
    a_align_ok = qa_r[2:0] == '0 && oa_r[2:0] == '0 && (!pen_r || pa_r[2:0] == '0) &&
                 (KV_SRC == 0 || (ka_r[2:0] == '0 && va_r[2:0] == '0 && ksa_r[2:0] == '0 &&
                                  vsa_r[2:0] == '0));
    w_desc_ok  = fmt_ok && hs_ok && 32'(hs_r) <= KL && 32'(kb_r) <= KW && 32'(vb_r) <= VW &&
                 nkv_r != '0 && 32'(kv0_r) + 32'(nkv_r) <= NKV && 32'(pos_r) < TMAX &&
                 32'(ly_r) < NL && 32'(pos_r) < 32'(seq_r) && wk_end <= LIM && wv_end <= LIM &&
                 wks_end <= LIM && wvs_end <= LIM;
    w_align_ok = ka_r[2:0] == '0 && va_r[2:0] == '0 && ksa_r[2:0] == '0 && vsa_r[2:0] == '0;
  end

  // ---------------- CTRL ----------------
  logic       busy_q, done_q, kvw_q;
  logic       ctrl_wr, start_req, idle, op_attn, op_kvw, op_ok, d_ok, al_ok;
  logic [ERR_W-1:0] err_q, err_set;

  assign ctrl_wr   = wr_hit && (wr_w == R_CTRL);
  assign start_req = ctrl_wr && wr_data_i[0];
  assign idle      = !busy_q || done_i;
  assign op_attn   = wr_data_i[7:4] == 4'd1;
  assign op_kvw    = wr_data_i[7:4] == 4'd2 && KV_SRC == 0;
  assign op_ok     = op_attn || op_kvw;
  assign d_ok      = op_attn ? a_desc_ok : w_desc_ok;
  assign al_ok     = op_attn ? a_align_ok : w_align_ok;
  assign start_o   = start_req && idle && op_ok && d_ok && al_ok;
  assign busy_o    = busy_q;
  assign op_kvw_o  = kvw_q;

  always_comb begin
    err_set               = '0;
    err_set[E_START_BUSY] = start_req && !idle;
    err_set[E_BAD_OP]     = start_req && !op_ok;
    err_set[E_BAD_DESC]   = start_req && idle && op_ok && !d_ok;
    err_set[E_MISALIGN]   = start_req && idle && op_ok && !al_ok;
    err_set[E_RD_RESP]    = rd_err_i;
    err_set[E_WR_RESP]    = wr_err_i;
  end

  logic [31:0] cyc_q, rdst_q, wrst_q, ops_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      busy_q <= 1'b0;
      done_q <= 1'b0;
      kvw_q  <= 1'b0;
      err_q  <= '0;
      cyc_q  <= '0;
      rdst_q <= '0;
      wrst_q <= '0;
      ops_q  <= '0;
    end else begin
      if (start_o) begin
        busy_q <= 1'b1;
        kvw_q  <= !op_attn;
      end else if (done_i) busy_q <= 1'b0;
      if (ctrl_wr && idle && !(wr_data_i[0] && !op_ok)) done_q <= 1'b0;
      else if (done_i) done_q <= 1'b1;
      err_q <= (err_q & ~((wr_hit && wr_w == R_ERR) ? wr_data_i[ERR_W-1:0] : '0)) | err_set;
      if (start_o) begin
        cyc_q  <= '0;
        rdst_q <= '0;
        wrst_q <= '0;
      end else if (busy_q) begin
        cyc_q <= cyc_q + 32'd1;
        if (rd_stall_i) rdst_q <= rdst_q + 32'd1;
        if (wr_stall_i) wrst_q <= wrst_q + 32'd1;
      end
      if (done_i) ops_q <= ops_q + 32'd1;
    end

  // latched descriptor
  always_ff @(posedge clk)
    if (start_o) begin
      q_addr_o <= qa_r; o_addr_o <= oa_r; p_addr_o <= pa_r; k_addr_o <= ka_r; v_addr_o <= va_r;
      ks_addr_o <= ksa_r; vs_addr_o <= vsa_r; t_o <= t_r; hs_o <= hs_r; kb_o <= kb_r; vb_o <= vb_r;
      p_en_o <= pen_r; head0_o <= h0_r; nhead_o <= nh_r; kvmul_o <= km_r; layer_o <= ly_r;
      seq_o <= seq_r; pos_o <= pos_r; kvh0_o <= kv0_r; nkvh_o <= nkv_r;
    end

  // ---------------- read mux ----------------
  always_comb begin
    rd_data_o = 32'd0;
    if (rd_hit)
      case (rd_w)
        R_ID:      rd_data_o = ID_VAL;
        R_CONFIG:  rd_data_o = CONFIG_VAL;
        R_STATUS:  rd_data_o = {29'd0, err_q != '0, done_q, busy_q};
        R_ERR:     rd_data_o = 32'(err_q);
        R_CYCLES:  rd_data_o = cyc_q;
        R_RDSTALL: rd_data_o = rdst_q;
        R_WRSTALL: rd_data_o = wrst_q;
        R_OPS:     rd_data_o = ops_q;
        R_CONFIG2: rd_data_o = CONFIG2_VAL;
        R_CONFIG3: rd_data_o = CONFIG3_VAL;
        R_QA:      rd_data_o = qa_r;
        R_OA:      rd_data_o = oa_r;
        R_PA:      rd_data_o = pa_r;
        R_KA:      rd_data_o = ka_r;
        R_VA:      rd_data_o = va_r;
        R_KSA:     rd_data_o = ksa_r;
        R_VSA:     rd_data_o = vsa_r;
        R_T:       rd_data_o = 32'(t_r);
        R_HS:      rd_data_o = 32'(hs_r);
        R_FMT:     rd_data_o = {15'd0, pen_r, 3'd0, vb_r, 3'd0, kb_r};
        R_HEAD:    rd_data_o = {8'd0, km_r, nh_r, h0_r};
        R_LAYER:   rd_data_o = 32'(ly_r);
        R_SEQ:     rd_data_o = 32'(seq_r);
        R_POS:     rd_data_o = 32'(pos_r);
        R_KVH:     rd_data_o = {16'd0, nkv_r, kv0_r};
        default:   rd_data_o = 32'd0;
      endcase
  end

  logic unused_rd_en;
  assign unused_rd_en = rd_en_i;

`ifndef SYNTHESIS
  always @(posedge clk)
    if (rst_n === 1'b1 && done_i === 1'b1 && busy_q !== 1'b1)
      $error("L3_DONE attn_csr %m: done_i while not busy");
`endif

endmodule
