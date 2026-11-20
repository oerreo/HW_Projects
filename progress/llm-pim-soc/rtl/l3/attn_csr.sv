// attn_csr: register file, descriptor check and run control of the attention IP attn_top (L3).
// Register map and rules: docs/spec/attn.md (common frame arch.md 7.2; the decided behaviour of
// gemv_acc_csr / pim_csr: done_sticky priority, W1C with set winning, undefined addresses read 0,
// WSTRB ignored, a read in the cycle of a write returns the state before the write).
//
//   0x00 ID       R     0x4154_0001 ("AT", version 1)
//   0x04 CONFIG   R     [7:0] FCLK_MHZ, [10:8] H_PAR, [11] KV_SRC (0 BRAM, 1 DDR), [15:12] log2(KL),
//                       [31:16] TMAX
//   0x08 CTRL     W     bit0 start, [7:4] op (1 = ATTN, 2 = KVW); reads 0
//   0x0C STATUS   R     bit0 busy (check or op), bit1 done_sticky, bit2 err_any
//   0x10 ERR      R/W1C bit0 START_BUSY, bit1 BAD_OP, bit2 BAD_DESC, bit3 MISALIGN, bit4 RD_RESP,
//                       bit5 WR_RESP
//   0x14 CYCLES   R     cycles of the last accepted call (CTRL write to done, check included)
//   0x18 RD_STALL R     cycles of the last call in which a core waited for KV data
//   0x1C WR_STALL R     cycles of the last call in which the output packer was held by the writer
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
// Call (S4-6b: sequential descriptor check, no runtime multiplier). CTRL write in cycle s while
// idle (= no check and no op running, or the done cycle e of the running op):
//   op 1 ATTN / op 2 KVW (KV_SRC 0): accepted. The descriptor is latched (run_* outputs valid from
//   s + 1, later register writes do not affect the call), done_sticky cleared, CYCLES / RD_STALL /
//   WR_STALL cleared, STATUS.busy = 1 from s + 1. The check runs in s + 1 .. v, v = s + CHK_CYC,
//   on the latched descriptor with umul_seq / udiv_seq units started in s (and in the done cycle of
//   the unit they depend on). In v: a legal descriptor gives start_o (op busy_o from v + 1 to e);
//   otherwise BAD_DESC and / or MISALIGN are set (visible v + 1), no start, STATUS.busy = 0 from
//   v + 1 (no done, OPS unchanged, CYCLES = CHK_CYC).
//   op 2 with KV_SRC = 1 (no on-chip KV) or another op: BAD_OP only, in s (done_sticky unchanged).
//   start = 0: done_sticky cleared. While busy (check or op, not the done cycle): start = 1 ->
//   START_BUSY (+ BAD_OP for an illegal op), ignored.
// CHK_CYC: 18 for KV_SRC 1 (kv head of the last head by udiv_seq (9), then its slot products (9));
// for KV_SRC 0 the longest of hend x ceil(T/2) (10), hend x hs and the KVW chain (slot, then row).
// Checks (docs/spec/attn.md 4.2) are bit-exact with the combinational products they replace:
// operands are narrowed only where the narrowed value is exact whenever every other term of the
// same verdict is true (hs <= KL or HS_MAX, T <= TMAX, HEAD0 + NHEAD <= 256, KVH0 + NKVH <= NKV).
// Derived outputs for attn_top (valid from start_o until the next accepted call):
//   seqhs_o = SEQ x hs, ths_o = T x hs (KV_SRC 1: kv head stride and KV byte counts),
//   kw0_o = KVH0 x SEQ + POS (KV_SRC 0: KVW source slot of the first kv head).
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
  parameter int FCLK_MHZ = 100,
  localparam int HS_W    = $clog2(HS_MAX + 1),              // hs when legal (<= HS_MAX)
  localparam int TW      = $clog2(TMAX + 1),                // T when legal (<= TMAX)
  localparam int KV_W    = (NKV > 1) ? $clog2(NKV) : 1,     // KVW kv head when legal (< NKV)
  localparam int SQH_W   = 16 + HS_W,                       // SEQ x hs
  localparam int TH_W    = TW + HS_W,                       // T x hs
  localparam int KW0_W   = KV_W + 17                        // KVH0 x SEQ + POS
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
  output logic              start_o,       // legal call: cycle v = s + CHK_CYC
  output logic              op_kvw_o,      // latched: 1 = KVW, 0 = ATTN
  output logic              busy_o,        // op running: v + 1 .. e
  input  logic              done_i,
  // latched descriptor (valid from s + 1)
  output logic [31:0]       q_addr_o, o_addr_o, p_addr_o, k_addr_o, v_addr_o, ks_addr_o, vs_addr_o,
  output logic [15:0]       t_o,
  output logic [7:0]        hs_o,
  output logic [4:0]        kb_o, vb_o,
  output logic              p_en_o,
  output logic [7:0]        head0_o, nhead_o, kvmul_o, layer_o, kvh0_o, nkvh_o,
  output logic [15:0]       seq_o, pos_o,
  // derived (valid from start_o until the next accepted call)
  output logic [SQH_W-1:0]  seqhs_o,
  output logic [TH_W-1:0]   ths_o,
  output logic [KW0_W-1:0]  kw0_o,
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
  if (KL < 1 || KL > 255) $error("attn_csr: KL=%0d must be 1..255", KL);
  if (NKV < 1 || NKV > 255) $error("attn_csr: NKV=%0d must be 1..255", NKV);

  localparam logic [31:0] ID_VAL      = 32'h4154_0001;
  localparam logic [31:0] CONFIG_VAL  = {16'(TMAX), 4'($clog2(KL)), 1'(KV_SRC), 3'(H_PAR), 8'(FCLK_MHZ)};
  localparam logic [31:0] CONFIG2_VAL = KV_SRC ? {8'd0, 8'd0, 8'd0, 8'(HS_MAX)}
                                               : {8'd0, 8'(NL), 8'(NKV), 8'(HS_MAX)};
  localparam logic [31:0] CONFIG3_VAL = KV_SRC ? 32'd0 : {16'(TMAX), 8'(VW), 8'(KW)};
  localparam int E_START_BUSY = 0, E_BAD_OP = 1, E_BAD_DESC = 2, E_MISALIGN = 3, E_RD_RESP = 4,
                 E_WR_RESP = 5, ERR_W = 6;

  // check unit widths (narrowed operands, see the header)
  localparam int HK     = (KL < HS_MAX) ? KL : HS_MAX;
  localparam int HSK_W  = $clog2(HK + 1);                   // hs when legal with KV_SRC 0 (<= KL)
  localparam int QB_W   = KV_SRC ? HS_W : HSK_W;            // hs operand of hend x hs
  localparam int CT_W   = $clog2((TMAX + 1) / 2 + 1);       // ceil(T / 2)
  localparam int WS_W   = KV_W + 17;                        // KVW slot + 1 (kvl SEQ + POS + 1)
  localparam int C_HEND = 9 + 1;                            // umul_seq B_W = 9: hend
  localparam int C_KVW  = (KV_W + 1) + (HSK_W + 1);         // slot, then slot x hs
  localparam int C_DDR  = (8 + 1) + (8 + 1);                // udiv_seq Q_W 8, then x kvmax
  localparam int C_K0   = (C_HEND > QB_W + 1) ? C_HEND : QB_W + 1;
  localparam int CHK_CYC = KV_SRC ? ((C_DDR > C_K0) ? C_DDR : C_K0) : ((C_KVW > C_K0) ? C_KVW : C_K0);
  localparam int CC_W   = $clog2(CHK_CYC + 1);

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

  // ---------------- CTRL and call state ----------------
  logic             chk_q, busy_q, done_q, kvw_q;
  logic [CC_W-1:0]  ccnt_q;
  logic             ctrl_wr, start_req, idle, op_attn, op_kvw, op_ok, acc, verdict, v_desc_ok, v_al_ok;
  logic [ERR_W-1:0] err_q, err_set;

  assign ctrl_wr   = wr_hit && (wr_w == R_CTRL);
  assign start_req = ctrl_wr && wr_data_i[0];
  assign idle      = (!chk_q && !busy_q) || done_i;
  assign op_attn   = wr_data_i[7:4] == 4'd1;
  assign op_kvw    = wr_data_i[7:4] == 4'd2 && KV_SRC == 0;
  assign op_ok     = op_attn || op_kvw;
  assign acc       = start_req && idle && op_ok;           // accepted call: cycle s
  assign verdict   = chk_q && ccnt_q == CC_W'(1);          // cycle v = s + CHK_CYC
  assign start_o   = verdict && v_desc_ok && v_al_ok;
  assign busy_o    = busy_q;
  assign op_kvw_o  = kvw_q;

  // latched descriptor (from s + 1)
  always_ff @(posedge clk)
    if (acc) begin
      q_addr_o <= qa_r; o_addr_o <= oa_r; p_addr_o <= pa_r; k_addr_o <= ka_r; v_addr_o <= va_r;
      ks_addr_o <= ksa_r; vs_addr_o <= vsa_r; t_o <= t_r; hs_o <= hs_r; kb_o <= kb_r; vb_o <= vb_r;
      p_en_o <= pen_r; head0_o <= h0_r; nhead_o <= nh_r; kvmul_o <= km_r; layer_o <= ly_r;
      seq_o <= seq_r; pos_o <= pos_r; kvh0_o <= kv0_r; nkvh_o <= nkv_r;
    end

  // ---------------- descriptor check (sequential products) ----------------
  localparam logic [35:0] LIM = 36'h1_0000_0000;   // 2^32
  // operands in cycle s (registers, = the latched descriptor from s + 1)
  logic [8:0]  hend_r;
  assign hend_r = 9'(h0_r) + 9'(nh_r);
  // latched descriptor terms (cycle v)
  logic [8:0]  hend;
  logic        ek2, ev2, fmt_ok, hs_ok, t_ok;
  assign hend   = 9'(head0_o) + 9'(nhead_o);
  assign ek2    = kb_o > 5'd8;
  assign ev2    = vb_o > 5'd8;
  assign fmt_ok = (kb_o == 5'd8 || kb_o == 5'd12 || kb_o == 5'd16) &&
                  (vb_o == 5'd8 || vb_o == 5'd12 || vb_o == 5'd16);
  assign hs_ok  = hs_o != '0 && hs_o[2:0] == 3'd0 && 9'(hs_o) <= 9'(HS_MAX);
  assign t_ok   = t_o != '0 && 17'(t_o) <= 17'(TMAX);

  // hend x hs (q and o ranges), hend x ceil(T/2) (p range): started in s
  logic [9+QB_W-1:0] p_q;
  logic [CT_W+9-1:0] p_p;
  logic              uq_busy, up_busy;
  umul_seq #(.A_W(9), .B_W(QB_W)) u_mq (
    .clk, .rst_n, .start_i(acc), .a_i(hend_r), .b_i(QB_W'(hs_r)), .p_o(p_q), .done_o(),
    .busy_o(uq_busy));
  umul_seq #(.A_W(CT_W), .B_W(9)) u_mp (
    .clk, .rst_n, .start_i(acc), .a_i(CT_W'((17'(t_r) + 17'd1) >> 1)), .b_i(hend_r), .p_o(p_p),
    .done_o(), .busy_o(up_busy));

  logic [35:0] q_end, o_end, p_end;
  assign q_end = 36'(q_addr_o) + 36'({hend, 3'b000}) + 36'({p_q, 1'b0});   // + hend (8 + 2 hs)
  assign o_end = 36'(o_addr_o) + 36'({p_q, 2'b00});                       // + 4 hs hend
  assign p_end = 36'(p_addr_o) + 36'({p_p, 3'b000});                      // + 8 ceil(T/2) hend

  logic a_base_ok, a_kv_ok, w_ok, units_busy;
  assign a_base_ok = fmt_ok && hs_ok && t_ok && nhead_o != '0 && kvmul_o != '0 && hend <= 9'd256 &&
                     q_end <= LIM && o_end <= LIM && (!p_en_o || p_end <= LIM);

  if (KV_SRC == 0) begin : g_chk_bram
    // ATTN: (hend - 1) / KVMUL < NKV  <=>  hend <= NKV x KVMUL (hend >= 1, KVMUL >= 1 when legal)
    localparam int NK_W = 8 + $clog2(NKV + 1);
    logic [NK_W-1:0] nkkm;
    assign nkkm    = NK_W'(kvmul_o) * NK_W'(NKV);       // constant multiple
    assign a_kv_ok = 9'(hs_o) <= 9'(KL) && 32'(kb_o) <= KW && 32'(vb_o) <= VW &&
                     9'(layer_o) <= 9'(NL - 1) && NK_W'(hend) <= nkkm;
    // KVW: slot of the last kv head (KVH0 + NKVH - 1) SEQ + POS + 1, then x hs; first slot
    // KVH0 SEQ + POS for attn_top
    logic [KV_W+16-1:0]   p_w, p_0;
    logic [WS_W+HSK_W-1:0] p_r;
    logic [WS_W-1:0]      wslot;
    logic                 uw_done, uw_busy, u0_busy, ur_busy;
    umul_seq #(.A_W(16), .B_W(KV_W)) u_mw (
      .clk, .rst_n, .start_i(acc), .a_i(seq_r), .b_i(KV_W'(9'(kv0_r) + 9'(nkv_r) - 9'd1)), .p_o(p_w),
      .done_o(uw_done), .busy_o(uw_busy));
    umul_seq #(.A_W(16), .B_W(KV_W)) u_m0 (
      .clk, .rst_n, .start_i(acc), .a_i(seq_r), .b_i(KV_W'(kv0_r)), .p_o(p_0), .done_o(),
      .busy_o(u0_busy));
    assign wslot = WS_W'(p_w) + WS_W'(pos_o) + WS_W'(1);
    umul_seq #(.A_W(WS_W), .B_W(HSK_W)) u_mr (
      .clk, .rst_n, .start_i(uw_done), .a_i(wslot), .b_i(HSK_W'(hs_o)), .p_o(p_r), .done_o(),
      .busy_o(ur_busy));
    logic [35:0] wk_end, wv_end, wks_end, wvs_end;
    assign wk_end  = 36'(k_addr_o) + (36'(p_r) << ek2);
    assign wv_end  = 36'(v_addr_o) + (36'(p_r) << ev2);
    assign wks_end = 36'(ks_addr_o) + 36'({wslot, 3'b000});
    assign wvs_end = 36'(vs_addr_o) + 36'({wslot, 3'b000});
    assign w_ok = fmt_ok && hs_ok && 9'(hs_o) <= 9'(KL) && 32'(kb_o) <= KW && 32'(vb_o) <= VW &&
                  nkvh_o != '0 && 9'(kvh0_o) + 9'(nkvh_o) <= 9'(NKV) && 17'(pos_o) < 17'(TMAX) &&
                  9'(layer_o) <= 9'(NL - 1) && pos_o < seq_o && wk_end <= LIM && wv_end <= LIM &&
                  wks_end <= LIM && wvs_end <= LIM;
    assign units_busy = uq_busy || up_busy || uw_busy || u0_busy || ur_busy;
    assign kw0_o   = KW0_W'(p_0) + KW0_W'(pos_o);
    assign seqhs_o = '0;
    assign ths_o   = '0;
  end else begin : g_chk_ddr
    // kv head of the last head kvmax = (hend - 1) / KVMUL (exact when hend <= 256, KVMUL >= 1);
    // slot = kvmax SEQ + T; slot x hs = kvmax (SEQ hs) + T hs
    logic [7:0]          kvmax;
    logic                ud_done, ud_busy, us_busy, ut_busy, uk_busy, ukh_busy;
    logic [SQH_W-1:0]    p_sh;
    logic [TH_W-1:0]     p_th;
    logic [16+8-1:0]     p_ks;      // kvmax x SEQ
    logic [SQH_W+8-1:0]  p_kh;      // kvmax x SEQ x hs
    udiv_seq #(.NUM_W(8), .DEN_W(8), .Q_W(8)) u_div (
      .clk, .rst_n, .start_i(acc), .num_i(8'(hend_r - 9'd1)), .den_i((km_r == '0) ? 8'd1 : km_r),
      .q_o(kvmax), .done_o(ud_done), .busy_o(ud_busy));
    umul_seq #(.A_W(16), .B_W(HS_W)) u_msh (
      .clk, .rst_n, .start_i(acc), .a_i(seq_r), .b_i(HS_W'(hs_r)), .p_o(p_sh), .done_o(),
      .busy_o(us_busy));
    umul_seq #(.A_W(TW), .B_W(HS_W)) u_mth (
      .clk, .rst_n, .start_i(acc), .a_i(TW'(t_r)), .b_i(HS_W'(hs_r)), .p_o(p_th), .done_o(),
      .busy_o(ut_busy));
    umul_seq #(.A_W(16), .B_W(8)) u_mks (
      .clk, .rst_n, .start_i(ud_done), .a_i(seq_o), .b_i(kvmax), .p_o(p_ks), .done_o(),
      .busy_o(uk_busy));
    umul_seq #(.A_W(SQH_W), .B_W(8)) u_mkh (
      .clk, .rst_n, .start_i(ud_done), .a_i(p_sh), .b_i(kvmax), .p_o(p_kh), .done_o(),
      .busy_o(ukh_busy));
    logic [24:0]       aslot;      // kvmax SEQ + T
    logic [SQH_W+8:0]  ahs;        // aslot x hs
    logic [35:0]       ka_end, va_end, ksa_end, vsa_end;
    assign aslot   = 25'(p_ks) + 25'(t_o);
    assign ahs     = (SQH_W + 9)'(p_kh) + (SQH_W + 9)'(p_th);
    assign ka_end  = 36'(k_addr_o) + (36'(ahs) << ek2);
    assign va_end  = 36'(v_addr_o) + (36'(ahs) << ev2);
    assign ksa_end = 36'(ks_addr_o) + 36'({aslot, 3'b000});
    assign vsa_end = 36'(vs_addr_o) + 36'({aslot, 3'b000});
    assign a_kv_ok = t_o <= seq_o && ka_end <= LIM && va_end <= LIM && ksa_end <= LIM &&
                     vsa_end <= LIM;
    assign w_ok    = 1'b0;     // KVW is BAD_OP without on-chip KV
    assign units_busy = uq_busy || up_busy || ud_busy || us_busy || ut_busy || uk_busy || ukh_busy;
    assign seqhs_o = p_sh;
    assign ths_o   = p_th;
    assign kw0_o   = '0;
  end

  always_comb begin
    v_desc_ok = kvw_q ? w_ok : (a_base_ok && a_kv_ok);
    if (kvw_q)
      v_al_ok = k_addr_o[2:0] == '0 && v_addr_o[2:0] == '0 && ks_addr_o[2:0] == '0 &&
                vs_addr_o[2:0] == '0;
    else
      v_al_ok = q_addr_o[2:0] == '0 && o_addr_o[2:0] == '0 && (!p_en_o || p_addr_o[2:0] == '0) &&
                (KV_SRC == 0 || (k_addr_o[2:0] == '0 && v_addr_o[2:0] == '0 &&
                                 ks_addr_o[2:0] == '0 && vs_addr_o[2:0] == '0));
  end

  always_comb begin
    err_set               = '0;
    err_set[E_START_BUSY] = start_req && !idle;
    err_set[E_BAD_OP]     = start_req && !op_ok;
    err_set[E_BAD_DESC]   = verdict && !v_desc_ok;
    err_set[E_MISALIGN]   = verdict && !v_al_ok;
    err_set[E_RD_RESP]    = rd_err_i;
    err_set[E_WR_RESP]    = wr_err_i;
  end

  logic [31:0] cyc_q, rdst_q, wrst_q, ops_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      chk_q  <= 1'b0;
      ccnt_q <= '0;
      busy_q <= 1'b0;
      done_q <= 1'b0;
      kvw_q  <= 1'b0;
      err_q  <= '0;
      cyc_q  <= '0;
      rdst_q <= '0;
      wrst_q <= '0;
      ops_q  <= '0;
    end else begin
      if (acc) begin
        chk_q  <= 1'b1;
        ccnt_q <= CC_W'(CHK_CYC);
        kvw_q  <= !op_attn;
      end else if (chk_q) begin
        ccnt_q <= ccnt_q - 1'b1;
        if (verdict) chk_q <= 1'b0;
      end
      if (start_o) busy_q <= 1'b1;
      else if (done_i) busy_q <= 1'b0;
      if (ctrl_wr && idle && !(wr_data_i[0] && !op_ok)) done_q <= 1'b0;
      else if (done_i) done_q <= 1'b1;
      err_q <= (err_q & ~((wr_hit && wr_w == R_ERR) ? wr_data_i[ERR_W-1:0] : '0)) | err_set;
      if (acc) begin
        cyc_q  <= '0;
        rdst_q <= '0;
        wrst_q <= '0;
      end else if (chk_q || busy_q) begin
        cyc_q <= cyc_q + 32'd1;
        if (rd_stall_i) rdst_q <= rdst_q + 32'd1;
        if (wr_stall_i) wrst_q <= wrst_q + 32'd1;
      end
      if (done_i) ops_q <= ops_q + 32'd1;
    end

  // ---------------- read mux ----------------
  always_comb begin
    rd_data_o = 32'd0;
    if (rd_hit)
      case (rd_w)
        R_ID:      rd_data_o = ID_VAL;
        R_CONFIG:  rd_data_o = CONFIG_VAL;
        R_STATUS:  rd_data_o = {29'd0, err_q != '0, done_q, chk_q || busy_q};
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
    if (rst_n === 1'b1) begin
      if (done_i === 1'b1 && busy_q !== 1'b1)
        $error("L3_DONE attn_csr %m: done_i while not busy");
      if (verdict && units_busy)
        $error("L3_CHK attn_csr %m: a check unit is still busy in the verdict cycle");
    end
`endif

endmodule
