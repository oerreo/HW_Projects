// tb_attn_csr: attn_csr (rtl/l3/attn_csr.sv) alone against a register-file model written from
// docs/spec/attn.md (3 register map, 4.1 CTRL and call timing, 4.2 descriptor check).
//
// Model: descriptor registers; a CTRL write in cycle s while idle with op 1 (or op 2 with
// KV_SRC 0) is accepted: the descriptor is latched, STATUS.busy = 1 from s + 1, and in
// v = s + CHK (CHK from attn.md 4.1, not from the RTL) the verdict of the latched descriptor
// either starts the op (start_o in v, busy_o from v + 1 until the done_i cycle) or sets BAD_DESC /
// MISALIGN. The verdict is computed from the spec rules with 64-bit TB arithmetic (exact
// products, every reason separately); it is independent of the RTL's narrowed sequential units.
// Every cycle (negedge) the TB compares: rd_data_o of the presented read address, start_o,
// busy_o, op_kvw_o and the latched descriptor outputs (from s + 1), and from a passing verdict
// until the next accepted call the derived outputs (KV_SRC 1: seqhs_o = SEQ hs, ths_o = T hs;
// KV_SRC 0 KVW: kw0_o = KVH0 SEQ + POS).
// Stimulus:
//   directed: a legal descriptor (pass), then every BAD_DESC reason alone (each field at its
//     first illegal value, and its last legal value passing), every byte range ending exactly at
//     2^32 (pass) and 8 bytes beyond (fail), large products near the 2^32 wrap, BAD_DESC with
//     MISALIGN, BAD_OP (and KVW with KV_SRC 1), START_BUSY in every cycle of the check (also the
//     verdict cycle) and during the op (also with a bad op), CTRL in the done cycle (start 0 / 1),
//     descriptor writes during the check (the verdict of the new values differs).
//   random (+N_CYC cycles): write strobe with random address / data (descriptor fields from a
//     legal template, edge values computed from the current registers, or random), CTRL with
//     start 0/1 and op 0..15, ERR W1C, reads of every address, events (done_i only while the op
//     runs, +PDONE percent; rd_err, wr_err, rd_stall, wr_stall, +PEV percent).
// Coverage counted and required: passes (ATTN, KVW), each reason alone, each 2^32 edge accepted
// and rejected, the collision cases above, W1C against a set of the same bit, every ERR bit.
// Plusargs: +SEED +N_CYC +PDONE +PEV
`timescale 1ns / 1ps
module tb_attn_csr #(
  parameter int KV_SRC = 0,
  parameter int H_PAR  = 2,
  parameter int KL     = 8,
  parameter int HS_MAX = 8,
  parameter int TMAX   = 512,
  parameter int NKV    = 4,
  parameter int NL     = 5,
  parameter int KW     = 12,
  parameter int VW     = 8
);
  import tb_util_pkg::*;

  localparam int ADDR_W = 12;
  localparam int HS_W  = $clog2(HS_MAX + 1), TW = $clog2(TMAX + 1);
  localparam int KV_W  = (NKV > 1) ? $clog2(NKV) : 1;
  localparam int SQH_W = 16 + HS_W, TH_W = TW + HS_W, KW0_W = KV_W + 17;
  // check cycles (attn.md 4.1)
  localparam int HKM   = (KL < HS_MAX) ? KL : HS_MAX;
  localparam int W_HK  = $clog2(HKM + 1);
  localparam int W_HQ  = KV_SRC ? HS_W : W_HK;
  localparam int CHK0  = (W_HQ + 1 > 10) ? W_HQ + 1 : 10;
  localparam int CHK   = KV_SRC ? ((CHK0 > 18) ? CHK0 : 18) : ((KV_W + W_HK + 2 > CHK0) ? KV_W + W_HK + 2 : CHK0);

  localparam int A_ID = 'h00, A_CONFIG = 'h04, A_CTRL = 'h08, A_STATUS = 'h0C, A_ERR = 'h10,
                 A_CYCLES = 'h14, A_RDST = 'h18, A_WRST = 'h1C, A_OPS = 'h20, A_CFG2 = 'h24,
                 A_CFG3 = 'h28, A_QA = 'h40, A_OA = 'h44, A_PA = 'h48, A_KA = 'h4C, A_VA = 'h50,
                 A_KSA = 'h54, A_VSA = 'h58, A_T = 'h5C, A_HS = 'h60, A_FMT = 'h64, A_HEAD = 'h68,
                 A_LAYER = 'h6C, A_SEQ = 'h70, A_POS = 'h74, A_KVH = 'h78;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic              wr_en = 0, rd_en = 0, done_i = 0, rd_err = 0, wr_err = 0, rd_stall = 0, wr_stall = 0;
  logic [ADDR_W-1:0] wr_addr = 0, rd_addr = 0;
  logic [31:0]       wr_data = 0, rd_data;
  logic              start_o, op_kvw_o, busy_o, p_en_o;
  logic [31:0]       q_addr_o, o_addr_o, p_addr_o, k_addr_o, v_addr_o, ks_addr_o, vs_addr_o;
  logic [15:0]       t_o, seq_o, pos_o;
  logic [7:0]        hs_o, head0_o, nhead_o, kvmul_o, layer_o, kvh0_o, nkvh_o;
  logic [4:0]        kb_o, vb_o;
  logic [SQH_W-1:0]  seqhs_o;
  logic [TH_W-1:0]   ths_o;
  logic [KW0_W-1:0]  kw0_o;

  attn_csr #(.ADDR_W(ADDR_W), .H_PAR(H_PAR), .KV_SRC(KV_SRC), .KL(KL), .HS_MAX(HS_MAX), .TMAX(TMAX),
             .NKV(NKV), .NL(NL), .KW(KW), .VW(VW), .FCLK_MHZ(100)) dut (
    .clk, .rst_n, .wr_en_i(wr_en), .wr_addr_i(wr_addr), .wr_data_i(wr_data), .rd_en_i(rd_en),
    .rd_addr_i(rd_addr), .rd_data_o(rd_data),
    .start_o, .op_kvw_o, .busy_o, .done_i,
    .q_addr_o, .o_addr_o, .p_addr_o, .k_addr_o, .v_addr_o, .ks_addr_o, .vs_addr_o, .t_o, .hs_o,
    .kb_o, .vb_o, .p_en_o, .head0_o, .nhead_o, .kvmul_o, .layer_o, .kvh0_o, .nkvh_o, .seq_o, .pos_o,
    .seqhs_o, .ths_o, .kw0_o,
    .rd_err_i(rd_err), .wr_err_i(wr_err), .rd_stall_i(rd_stall), .wr_stall_i(wr_stall));

  tb_checker c_rd = new("read_data"), c_ctl = new("start_busy"), c_lat = new("latched"),
             c_der = new("derived"), c_cov = new("coverage");

  // ---------------- model ----------------
  typedef struct {
    longint unsigned qa, oa, pa, ka, va, ksa, vsa;
    int t, hs, kb, vb, pen, h0, nh, km, ly, seq, pos, kv0, nkv;
  } desc_t;
  desc_t md, mdl;
  int    m_chk = 0, m_err = 0;
  bit    m_busy = 0, m_done = 0, m_kvw = 0, lt_valid = 0, dv_valid = 0, dv_kvw = 0;
  longint unsigned m_cyc = 0, m_rdst = 0, m_wrst = 0, m_ops = 0;
  localparam longint unsigned LIM = 64'h1_0000_0000;

  // reasons (bit index), docs/spec/attn.md 4.2
  localparam int R_FMT = 0, R_HS = 1, R_T = 2, R_NH0 = 3, R_KM0 = 4, R_HEND = 5, R_QR = 6, R_OR = 7,
                 R_PR = 8, R_HSKL = 9, R_KBW = 10, R_VBW = 11, R_LY = 12, R_KVH = 13, R_TSEQ = 14,
                 R_KR = 15, R_VR = 16, R_KSR = 17, R_VSR = 18, R_NKV0 = 19, R_KVHR = 20, R_POST = 21,
                 R_POSS = 22, R_WKR = 23, R_WVR = 24, R_WKSR = 25, R_WVSR = 26, NR = 27;
  string rname[NR] = '{"FMT", "HS", "T", "NHEAD0", "KVMUL0", "HEND>256", "Q range", "O range",
                       "P range", "hs>KL", "kb>KW", "vb>VW", "LAYER>=NL", "kv head>=NKV", "T>SEQ",
                       "K range", "V range", "KS range", "VS range", "NKVH0", "KVH0+NKVH>NKV",
                       "POS>=TMAX", "POS>=SEQ", "KVW K range", "KVW V range", "KVW KS range",
                       "KVW VS range"};

  function automatic int ekf(int b); return b > 8 ? 2 : 1; endfunction
  function automatic int hendf(desc_t d); return d.h0 + d.nh; endfunction
  function automatic int kvmaxf(desc_t d);   // kv head of the last head (defined: KVMUL >= 1, hend >= 1)
    return (d.km == 0 || hendf(d) == 0) ? 0 : (hendf(d) - 1) / d.km;
  endfunction
  // byte length of each range (exact)
  function automatic longint unsigned rlen(desc_t d, int r);
    longint unsigned hend = hendf(d), aslot = longint'(kvmaxf(d)) * d.seq + d.t;
    longint unsigned wslot = longint'(d.kv0 + d.nkv - 1) * d.seq + d.pos + 1;
    case (r)
      R_QR:   return hend * (8 + 2 * d.hs);
      R_OR:   return hend * 4 * d.hs;
      R_PR:   return hend * 8 * ((d.t + 1) / 2);
      R_KR:   return aslot * d.hs * ekf(d.kb);
      R_VR:   return aslot * d.hs * ekf(d.vb);
      R_KSR, R_VSR: return aslot * 8;
      R_WKR:  return wslot * d.hs * ekf(d.kb);
      R_WVR:  return wslot * d.hs * ekf(d.vb);
      default: return wslot * 8;   // R_WKSR, R_WVSR
    endcase
  endfunction
  function automatic longint unsigned rbase(desc_t d, int r);
    case (r)
      R_QR: return d.qa; R_OR: return d.oa; R_PR: return d.pa;
      R_KR, R_WKR: return d.ka; R_VR, R_WVR: return d.va; R_KSR, R_WKSR: return d.ksa;
      default: return d.vsa;
    endcase
  endfunction
  function automatic int raddr(int r);
    case (r)
      R_QR: return A_QA; R_OR: return A_OA; R_PR: return A_PA;
      R_KR, R_WKR: return A_KA; R_VR, R_WVR: return A_VA; R_KSR, R_WKSR: return A_KSA;
      default: return A_VSA;
    endcase
  endfunction
  function automatic bit rfail(desc_t d, int r);
    return rbase(d, r) + rlen(d, r) > LIM;
  endfunction

  function automatic longint unsigned reasons(desc_t d, bit kvw);
    longint unsigned m = 0;
    bit fmt = (d.kb == 8 || d.kb == 12 || d.kb == 16) && (d.vb == 8 || d.vb == 12 || d.vb == 16);
    bit hs  = d.hs != 0 && d.hs % 8 == 0 && d.hs <= HS_MAX;
    if (!fmt) m[R_FMT] = 1;
    if (!hs) m[R_HS] = 1;
    if (!kvw) begin
      if (d.t == 0 || d.t > TMAX) m[R_T] = 1;
      if (d.nh == 0) m[R_NH0] = 1;
      if (d.km == 0) m[R_KM0] = 1;
      if (hendf(d) > 256) m[R_HEND] = 1;
      if (rfail(d, R_QR)) m[R_QR] = 1;
      if (rfail(d, R_OR)) m[R_OR] = 1;
      if (d.pen && rfail(d, R_PR)) m[R_PR] = 1;
      if (KV_SRC == 0) begin
        if (d.hs > KL) m[R_HSKL] = 1;
        if (d.kb > KW) m[R_KBW] = 1;
        if (d.vb > VW) m[R_VBW] = 1;
        if (d.ly >= NL) m[R_LY] = 1;
        if (d.km != 0 && hendf(d) >= 1 && kvmaxf(d) >= NKV) m[R_KVH] = 1;
      end else begin
        if (d.t > d.seq) m[R_TSEQ] = 1;
        for (int r = R_KR; r <= R_VSR; r++) if (rfail(d, r)) m[r] = 1;
      end
    end else begin
      if (d.hs > KL) m[R_HSKL] = 1;
      if (d.kb > KW) m[R_KBW] = 1;
      if (d.vb > VW) m[R_VBW] = 1;
      if (d.nkv == 0) m[R_NKV0] = 1;
      if (d.kv0 + d.nkv > NKV) m[R_KVHR] = 1;
      if (d.pos >= TMAX) m[R_POST] = 1;
      if (d.ly >= NL) m[R_LY] = 1;
      if (d.pos >= d.seq) m[R_POSS] = 1;
      // the slot of the last kv head is defined with NKVH >= 1
      if (d.nkv != 0) for (int r = R_WKR; r <= R_WVSR; r++) if (rfail(d, r)) m[r] = 1;
    end
    return m;
  endfunction
  function automatic bit al_ok(desc_t d, bit kvw);
    bit kv = d.ka % 8 == 0 && d.va % 8 == 0 && d.ksa % 8 == 0 && d.vsa % 8 == 0;
    if (kvw) return kv;
    return d.qa % 8 == 0 && d.oa % 8 == 0 && (!d.pen || d.pa % 8 == 0) && (KV_SRC == 0 || kv);
  endfunction

  function automatic logic [31:0] model_read(int a);
    if (a >= 256) return 0;
    case (a & 'hFC)
      A_ID:     return 32'h4154_0001;
      A_CONFIG: return {16'(TMAX), 4'($clog2(KL)), 1'(KV_SRC), 3'(H_PAR), 8'd100};
      A_STATUS: return {29'd0, m_err != 0, m_done, m_busy || m_chk != 0};
      A_ERR:    return 32'(m_err);
      A_CYCLES: return 32'(m_cyc);
      A_RDST:   return 32'(m_rdst);
      A_WRST:   return 32'(m_wrst);
      A_OPS:    return 32'(m_ops);
      A_CFG2:   return KV_SRC ? 32'(HS_MAX) : {8'd0, 8'(NL), 8'(NKV), 8'(HS_MAX)};
      A_CFG3:   return KV_SRC ? 32'd0 : {16'(TMAX), 8'(VW), 8'(KW)};
      A_QA: return 32'(md.qa); A_OA: return 32'(md.oa); A_PA: return 32'(md.pa);
      A_KA: return 32'(md.ka); A_VA: return 32'(md.va); A_KSA: return 32'(md.ksa); A_VSA: return 32'(md.vsa);
      A_T: return 32'(md.t); A_HS: return 32'(md.hs);
      A_FMT: return {15'd0, 1'(md.pen), 3'd0, 5'(md.vb), 3'd0, 5'(md.kb)};
      A_HEAD: return {8'd0, 8'(md.km), 8'(md.nh), 8'(md.h0)};
      A_LAYER: return 32'(md.ly); A_SEQ: return 32'(md.seq); A_POS: return 32'(md.pos);
      A_KVH: return {16'd0, 8'(md.nkv), 8'(md.kv0)};
      default: return 32'd0;
    endcase
  endfunction

  // ---------------- coverage ----------------
  longint n_acc = 0, n_pass_a = 0, n_pass_w = 0, n_fail = 0, n_both = 0, n_badop = 0, n_kvw_ddr = 0;
  longint n_sb_chk[int];         // START_BUSY by cycle of the check (1 .. CHK = verdict cycle)
  longint n_sb_op = 0, n_sb_badop = 0, n_ctrl_done0 = 0, n_ctrl_done1 = 0, n_w1c_set = 0;
  longint n_wr_chk_diff = 0, n_err[6] = '{0, 0, 0, 0, 0, 0};
  longint n_single[NR], n_edge_ok[NR], n_edge_bad[NR];
  initial foreach (n_single[i]) begin n_single[i] = 0; n_edge_ok[i] = 0; n_edge_bad[i] = 0; end

  // ---------------- negedge: compare, then advance the model by this cycle ----------------
  always @(negedge clk) if (rst_n) begin
    automatic bit ctrl, sreq, idle, op_ok, acc, verdict, st = 0, w1c, was_busy;
    automatic int op = int'(wr_data[7:4]), w = int'(wr_addr) & 'hFC, set = 0, clr = 0;
    automatic bit wr_hit = wr_en && int'(wr_addr) < 256;
    automatic longint unsigned rs = 0;
    automatic bit al = 1;
    automatic logic [31:0] e;
    // read data of the presented address (state before this cycle's write)
    e = model_read(int'(rd_addr));
    if (rd_data !== e) c_rd.fail($sformatf("rd_addr 0x%03h: %h, model %h", rd_addr, rd_data, e));
    else c_rd.pass();
    ctrl     = wr_hit && w == A_CTRL;
    sreq     = ctrl && wr_data[0];
    idle     = (!m_busy && m_chk == 0) || done_i;
    op_ok    = op == 1 || (op == 2 && KV_SRC == 0);
    acc      = sreq && idle && op_ok;
    verdict  = m_chk == 1;
    was_busy = m_busy || m_chk != 0;
    if (verdict) begin
      rs = reasons(mdl, m_kvw);
      al = al_ok(mdl, m_kvw);
      st = rs == 0 && al;
    end
    if (start_o !== st || busy_o !== m_busy)
      c_ctl.fail($sformatf("start_o %b busy_o %b, model %b %b (kvw %b reasons %h align %b)", start_o, busy_o,
                           st, m_busy, m_kvw, rs, al));
    else c_ctl.pass();
    if (lt_valid) begin
      automatic bit ok = q_addr_o === 32'(mdl.qa) && o_addr_o === 32'(mdl.oa) && p_addr_o === 32'(mdl.pa) &&
          k_addr_o === 32'(mdl.ka) && v_addr_o === 32'(mdl.va) && ks_addr_o === 32'(mdl.ksa) &&
          vs_addr_o === 32'(mdl.vsa) && t_o === 16'(mdl.t) && hs_o === 8'(mdl.hs) && kb_o === 5'(mdl.kb) &&
          vb_o === 5'(mdl.vb) && p_en_o === 1'(mdl.pen) && head0_o === 8'(mdl.h0) && nhead_o === 8'(mdl.nh) &&
          kvmul_o === 8'(mdl.km) && layer_o === 8'(mdl.ly) && seq_o === 16'(mdl.seq) && pos_o === 16'(mdl.pos) &&
          kvh0_o === 8'(mdl.kv0) && nkvh_o === 8'(mdl.nkv) && op_kvw_o === m_kvw;
      if (!ok) c_lat.fail($sformatf("latched descriptor differs (qa %h/%h t %0d/%0d hs %0d/%0d kvw %b/%b)", q_addr_o,
                                    32'(mdl.qa), t_o, mdl.t, hs_o, mdl.hs, op_kvw_o, m_kvw));
      else c_lat.pass();
    end
    // derived outputs from a passing verdict until the next accepted call
    if (st || dv_valid) begin
      automatic bit kvw = st ? m_kvw : dv_kvw;
      if (KV_SRC == 1) begin
        if (seqhs_o !== SQH_W'(longint'(mdl.seq) * mdl.hs) || ths_o !== TH_W'(longint'(mdl.t) * mdl.hs))
          c_der.fail($sformatf("seqhs %0d ths %0d, model %0d %0d", seqhs_o, ths_o, mdl.seq * mdl.hs, mdl.t * mdl.hs));
        else c_der.pass();
      end else if (kvw) begin
        if (kw0_o !== KW0_W'(longint'(mdl.kv0) * mdl.seq + mdl.pos))
          c_der.fail($sformatf("kw0 %0d, model %0d", kw0_o, mdl.kv0 * mdl.seq + mdl.pos));
        else c_der.pass();
      end
    end
    // ERR
    if (sreq && !idle) set |= 1;
    if (sreq && !op_ok) set |= 2;
    if (verdict && rs != 0) set |= 4;
    if (verdict && !al) set |= 8;
    if (rd_err) set |= 16;
    if (wr_err) set |= 32;
    w1c = wr_hit && w == A_ERR;
    clr = w1c ? int'(wr_data[5:0]) : 0;
    // coverage
    if (acc) n_acc++;
    if (verdict) begin
      if (st) begin if (m_kvw) n_pass_w++; else n_pass_a++; end
      else n_fail++;
      if (rs != 0 && !al) n_both++;
      if (rs != 0 && $countones(rs) == 1 && al) for (int r = 0; r < NR; r++) if (rs[r]) n_single[r]++;
      // descriptor written during the check: the verdict of the current registers differs
      if ((reasons(md, m_kvw) != 0 || !al_ok(md, m_kvw)) != !st) n_wr_chk_diff++;
      // range edges (all other terms legal)
      for (int r = R_QR; r < NR; r++) begin
        automatic longint unsigned mm = rs & ~(64'd1 << r);
        if (!(r == R_QR || r == R_OR || r == R_PR || (r >= R_KR && r <= R_VSR) || r >= R_WKR)) continue;
        if (mm == 0 && al && (r != R_PR || mdl.pen) &&
            ((m_kvw && r >= R_WKR) || (!m_kvw && r < R_WKR && (KV_SRC == 1 || r < R_KR)))) begin
          if (rbase(mdl, r) + rlen(mdl, r) == LIM) n_edge_ok[r]++;
          if (rbase(mdl, r) + rlen(mdl, r) == LIM + 8) n_edge_bad[r]++;
        end
      end
    end
    if (sreq && !op_ok) n_badop++;
    if (sreq && op == 2 && KV_SRC == 1) n_kvw_ddr++;
    if (sreq && !idle && m_chk != 0) begin
      automatic int k = CHK + 1 - m_chk;
      if (n_sb_chk.exists(k)) n_sb_chk[k]++; else n_sb_chk[k] = 1;
    end
    if (sreq && !idle && m_busy) n_sb_op++;
    if (sreq && !idle && !op_ok) n_sb_badop++;
    if (ctrl && done_i) begin if (wr_data[0]) n_ctrl_done1++; else n_ctrl_done0++; end
    if ((set & clr) != 0) n_w1c_set++;
    for (int b = 0; b < 6; b++) if (set[b]) n_err[b]++;
    if (done_i && !m_busy) c_ctl.fail("TB drove done_i while the op is not running");
    // next state
    if (acc) begin
      m_chk = CHK;
      mdl = md;
      m_kvw = op == 2;
      lt_valid = 1;
      dv_valid = 0;
    end else if (m_chk != 0) m_chk--;
    if (st) begin
      m_busy = 1;
      dv_valid = 1;
      dv_kvw = m_kvw;
    end else if (done_i) m_busy = 0;
    if (ctrl && idle && !(wr_data[0] && !op_ok)) m_done = 0;
    else if (done_i) m_done = 1;
    m_err = (m_err & ~clr) | set;
    if (acc) begin m_cyc = 0; m_rdst = 0; m_wrst = 0; end
    else if (was_busy) begin
      m_cyc++;
      if (rd_stall) m_rdst++;
      if (wr_stall) m_wrst++;
    end
    if (done_i) m_ops++;
    if (wr_hit)
      case (w)
        A_QA: md.qa = wr_data; A_OA: md.oa = wr_data; A_PA: md.pa = wr_data; A_KA: md.ka = wr_data;
        A_VA: md.va = wr_data; A_KSA: md.ksa = wr_data; A_VSA: md.vsa = wr_data;
        A_T: md.t = wr_data[15:0]; A_HS: md.hs = wr_data[7:0];
        A_FMT: begin md.kb = wr_data[4:0]; md.vb = wr_data[12:8]; md.pen = wr_data[16]; end
        A_HEAD: begin md.h0 = wr_data[7:0]; md.nh = wr_data[15:8]; md.km = wr_data[23:16]; end
        A_LAYER: md.ly = wr_data[7:0]; A_SEQ: md.seq = wr_data[15:0]; A_POS: md.pos = wr_data[15:0];
        A_KVH: begin md.kv0 = wr_data[7:0]; md.nkv = wr_data[15:8]; end
        default: ;
      endcase
  end

  // ---------------- legal template ----------------
  desc_t tp;
  function automatic longint unsigned r64(); return {$urandom(), $urandom()}; endfunction
  // aligned base with the range of length len inside 2^32 (len <= 2^32)
  function automatic longint unsigned fit_base(longint unsigned len);
    longint unsigned room = (LIM - len) / 8;
    return 8 * (r64() % (room + 1));
  endfunction
  function automatic void make_template();
    int hk = (KV_SRC == 0) ? ((KL < HS_MAX) ? KL : HS_MAX) : HS_MAX;
    forever begin
      tp.hs  = 8 * $urandom_range(hk / 8, 1);
      tp.kb  = KV_SRC == 0 ? ($urandom_range(1) ? 8 : (KW >= 12 ? 12 : 8)) : (8 + 4 * $urandom_range(2));
      tp.vb  = KV_SRC == 0 ? ($urandom_range(1) ? 8 : (VW >= 12 ? 12 : 8)) : (8 + 4 * $urandom_range(2));
      tp.pen = $urandom_range(1);
      tp.t   = $urandom_range(3) == 0 ? ($urandom_range(1) ? 1 : TMAX) : $urandom_range(TMAX, 1);
      tp.km  = $urandom_range(3) == 0 ? 1 : $urandom_range(8, 1);
      if (KV_SRC == 0) begin
        // heads with kv head < NKV
        int hmax = NKV * tp.km < 256 ? NKV * tp.km : 256;
        tp.h0 = $urandom_range(hmax - 1);
        tp.nh = $urandom_range(hmax - tp.h0, 1);
      end else begin
        tp.h0 = $urandom_range(3) == 0 ? 0 : $urandom_range(255);
        tp.nh = $urandom_range(256 - tp.h0, 1);
      end
      tp.ly  = $urandom_range(NL - 1);
      tp.kv0 = $urandom_range(NKV - 1);
      tp.nkv = $urandom_range(NKV - tp.kv0, 1);
      tp.pos = $urandom_range((TMAX < 65535 ? TMAX : 65535) - 1);
      // SEQ: >= T (DDR KV) and > POS (KVW); small or large
      tp.seq = (tp.t > tp.pos + 1 ? tp.t : tp.pos + 1);
      if ($urandom_range(1)) tp.seq = tp.seq + $urandom_range(65535 - tp.seq);
      else if ($urandom_range(1)) tp.seq = tp.seq + $urandom_range(16);
      // ranges must fit 2^32
      begin
        automatic bit ok = 1;
        for (int r = R_QR; r < NR; r++) if (rlen(tp, r) > LIM) ok = 0;
        if (!ok) continue;
      end
      tp.qa  = fit_base(rlen(tp, R_QR));
      tp.oa  = fit_base(rlen(tp, R_OR));
      tp.pa  = fit_base(rlen(tp, R_PR));
      tp.ka  = fit_base(rlen(tp, R_KR) > rlen(tp, R_WKR) ? rlen(tp, R_KR) : rlen(tp, R_WKR));
      tp.va  = fit_base(rlen(tp, R_VR) > rlen(tp, R_WVR) ? rlen(tp, R_VR) : rlen(tp, R_WVR));
      tp.ksa = fit_base(rlen(tp, R_KSR) > rlen(tp, R_WKSR) ? rlen(tp, R_KSR) : rlen(tp, R_WKSR));
      tp.vsa = fit_base(rlen(tp, R_VSR) > rlen(tp, R_WVSR) ? rlen(tp, R_VSR) : rlen(tp, R_WVSR));
      if (reasons(tp, 0) != 0 || (KV_SRC == 0 && reasons(tp, 1) != 0))
        $fatal(1, "tb_attn_csr: template not legal (%h %h)", reasons(tp, 0), reasons(tp, 1));
      return;
    end
  endfunction

  function automatic logic [31:0] desc_word(desc_t d, int a);
    case (a)
      A_QA: return 32'(d.qa); A_OA: return 32'(d.oa); A_PA: return 32'(d.pa); A_KA: return 32'(d.ka);
      A_VA: return 32'(d.va); A_KSA: return 32'(d.ksa); A_VSA: return 32'(d.vsa);
      A_T: return 32'(d.t); A_HS: return 32'(d.hs);
      A_FMT: return {15'd0, 1'(d.pen), 3'd0, 5'(d.vb), 3'd0, 5'(d.kb)};
      A_HEAD: return {8'd0, 8'(d.km), 8'(d.nh), 8'(d.h0)};
      A_LAYER: return 32'(d.ly); A_SEQ: return 32'(d.seq); A_POS: return 32'(d.pos);
      A_KVH: return {16'd0, 8'(d.nkv), 8'(d.kv0)};
      default: return 0;
    endcase
  endfunction

  // ---------------- directed helpers ----------------
  int dsc_addrs[] = '{A_QA, A_OA, A_PA, A_KA, A_VA, A_KSA, A_VSA, A_T, A_HS, A_FMT, A_HEAD, A_LAYER,
                      A_SEQ, A_POS, A_KVH};
  int pdone = 5, pev = 30;
  bit rnd_mode = 0;

  task automatic wr(int a, logic [31:0] d, bit done = 0);
    @(posedge clk);
    wr_en <= 1; wr_addr <= ADDR_W'(a); wr_data <= d; done_i <= done;
    rd_en <= 1; rd_addr <= ADDR_W'(dsc_addrs[$urandom_range(dsc_addrs.size() - 1)]);
    @(posedge clk);
    wr_en <= 0; done_i <= 0;
  endtask
  task automatic write_desc(desc_t d);
    foreach (dsc_addrs[i]) wr(dsc_addrs[i], desc_word(d, dsc_addrs[i]));
  endtask
  // finish a running op (done_i) after a few cycles
  task automatic finish_op();
    while (m_chk != 0) @(posedge clk);
    if (m_busy) begin
      repeat ($urandom_range(3)) @(posedge clk);
      @(posedge clk);
      done_i <= 1;
      @(posedge clk);
      done_i <= 0;
    end
    @(posedge clk);
  endtask
  // one call: CTRL write, wait for the verdict, end the op if it started
  task automatic call(int op);
    wr(A_CTRL, 32'((op << 4) | 1));
    finish_op();
  endtask
  // bases moved so that the ranges of a perturbed descriptor stay inside 2^32 when they can
  // (a non-range reason is then alone)
  function automatic desc_t refit(desc_t d);
    longint unsigned l;
    for (int a = A_QA; a <= A_VSA; a += 4) begin
      case (a)
        A_QA: l = rlen(d, R_QR); A_OA: l = rlen(d, R_OR); A_PA: l = rlen(d, R_PR);
        A_KA: l = rlen(d, R_KR) > rlen(d, R_WKR) ? rlen(d, R_KR) : rlen(d, R_WKR);
        A_VA: l = rlen(d, R_VR) > rlen(d, R_WVR) ? rlen(d, R_VR) : rlen(d, R_WVR);
        A_KSA: l = rlen(d, R_KSR) > rlen(d, R_WKSR) ? rlen(d, R_KSR) : rlen(d, R_WKSR);
        default: l = rlen(d, R_VSR) > rlen(d, R_WVSR) ? rlen(d, R_VSR) : rlen(d, R_WVSR);
      endcase
      if (l > LIM) continue;
      case (a)
        A_QA: if (d.qa + l > LIM) d.qa = fit_base(l);
        A_OA: if (d.oa + l > LIM) d.oa = fit_base(l);
        A_PA: if (d.pa + l > LIM) d.pa = fit_base(l);
        A_KA: if (d.ka + l > LIM) d.ka = fit_base(l);
        A_VA: if (d.va + l > LIM) d.va = fit_base(l);
        A_KSA: if (d.ksa + l > LIM) d.ksa = fit_base(l);
        default: if (d.vsa + l > LIM) d.vsa = fit_base(l);
      endcase
    end
    return d;
  endfunction
  // one descriptor (all registers) and one call
  task automatic try_desc(desc_t d, int op, bit fit = 1);
    write_desc(fit ? refit(d) : d);
    call(op);
  endtask

  int unsigned seed;
  longint n_cyc = 200000;

  task automatic directed();
    desc_t d;
    int ops[$];
    ops.push_back(1);
    if (KV_SRC == 0) ops.push_back(2);
    // template passes; one reason at a time; last legal value passes
    repeat (4) begin
      make_template();
      foreach (ops[k]) try_desc(tp, ops[k]);
    end
    for (int rep = 0; rep < 3; rep++) begin
      make_template();
      foreach (ops[k]) begin
        automatic int op = ops[k];
        d = tp; d.kb = 10; try_desc(d, op);
        d = tp; d.vb = 9; try_desc(d, op);
        d = tp; d.vb = 0; try_desc(d, op);
        d = tp; d.hs = 0; try_desc(d, op);
        d = tp; d.hs = 4; try_desc(d, op);
        d = tp; d.hs = HS_MAX + 8 - HS_MAX % 8; if (d.hs <= 255) try_desc(d, op);
        d = tp; d.hs = (HS_MAX / 8) * 8; try_desc(d, op);
        if (KV_SRC == 0 || op == 2) begin
          d = tp; d.hs = KL + 8 - KL % 8; if (d.hs <= HS_MAX) try_desc(d, op);
          d = tp; d.kb = 16; if (KW < 16) try_desc(d, op);
          d = tp; d.vb = 12; if (VW < 12) try_desc(d, op);
          d = tp; d.vb = 16; if (VW < 16) try_desc(d, op);
          d = tp; d.ly = NL; try_desc(d, op);
          d = tp; d.ly = NL - 1; try_desc(d, op);
          d = tp; d.ly = 255; try_desc(d, op);
        end
        if (op == 1) begin
          d = tp; d.t = 0; try_desc(d, op);
          d = tp; d.t = TMAX + 1; if (TMAX < 65535) try_desc(d, op);
          d = tp; d.t = 65535; try_desc(d, op);
          d = tp; d.nh = 0; try_desc(d, op);
          d = tp; d.km = 0; try_desc(d, op);
          d = tp; d.h0 = 0; d.nh = 0; try_desc(d, op);
          d = tp; d.h0 = 255; d.nh = 1; d.km = 255; try_desc(d, op);    // hend 256
          d = tp; d.h0 = 255; d.nh = 2; d.km = 255; try_desc(d, op);    // hend 257
          d = tp; d.h0 = 255; d.nh = 255; d.km = 255; try_desc(d, op);  // hend 510
          d = tp; d.h0 = 0; d.nh = 255; d.km = 1; try_desc(d, op);
          if (KV_SRC == 0) begin
            // last head's kv head = NKV - 1 (legal) and NKV
            d = tp; d.km = $urandom_range(8, 1); d.h0 = 0; d.nh = NKV * d.km; if (d.nh <= 255) try_desc(d, op);
            d.nh = NKV * d.km + 1; if (d.h0 + d.nh <= 256) try_desc(d, op);
            d = tp; d.km = 1; d.h0 = NKV - 1; d.nh = 1; try_desc(d, op);
            d.h0 = NKV; try_desc(d, op);
          end else begin
            d = tp; d.seq = d.t - 1; try_desc(d, op);
            d = tp; d.seq = d.t; try_desc(d, op);
          end
        end else begin
          d = tp; d.nkv = 0; try_desc(d, op);
          d = tp; d.kv0 = NKV - d.nkv; try_desc(d, op);
          d.kv0 = NKV - d.nkv + 1; try_desc(d, op);
          d = tp; d.kv0 = 255; d.nkv = 255; try_desc(d, op);
          d = tp; d.pos = TMAX - 1; d.seq = TMAX; try_desc(d, op);
          d = tp; d.pos = TMAX; d.seq = 65535; try_desc(d, op);
          d = tp; d.seq = d.pos; try_desc(d, op);
          d = tp; d.seq = d.pos + 1; try_desc(d, op);
          d = tp; d.seq = 0; try_desc(d, op);
        end
      end
    end
    // range edges: end exactly at 2^32 (pass) and 8 bytes beyond (fail), every range of the build
    for (int rep = 0; rep < 2; rep++)
      for (int r = R_QR; r < NR; r++) begin
        automatic int op;
        if (r == R_HSKL) r = R_KR;           // skip the non-range reasons
        if (r > R_VSR && r < R_WKR) r = R_WKR;
        if (r >= NR) break;
        op = r >= R_WKR ? 2 : 1;
        if (op == 2 && KV_SRC == 1) continue;
        if (op == 1 && r >= R_KR && KV_SRC == 0) continue;
        make_template();
        d = tp;
        if (r == R_PR) d.pen = 1;
        if (rep == 1) begin
          // large products: the biggest legal sizes of the build
          if (r == R_QR || r == R_OR || r == R_PR) begin d.h0 = KV_SRC ? 0 : d.h0; d.nh = KV_SRC ? 255 : d.nh; d.t = TMAX; end
          if (r >= R_KR && r <= R_VSR) begin d.h0 = 0; d.nh = 255; d.km = 1; d.t = 1; d.seq = 65535; d.hs = 8 * (HS_MAX / 8); end
          if (r >= R_WKR) begin d.kv0 = 0; d.nkv = NKV; d.seq = 65535; d.pos = TMAX - 1; end
        end
        if (rlen(d, r) > LIM) continue;
        case (raddr(r))
          A_QA: d.qa = LIM - rlen(d, r); A_OA: d.oa = LIM - rlen(d, r); A_PA: d.pa = LIM - rlen(d, r);
          A_KA: d.ka = LIM - rlen(d, r); A_VA: d.va = LIM - rlen(d, r); A_KSA: d.ksa = LIM - rlen(d, r);
          default: d.vsa = LIM - rlen(d, r);
        endcase
        if (reasons(d, op == 2) != 0) continue;    // another range of the same base broke
        try_desc(d, op, 0);
        case (raddr(r))
          A_QA: d.qa += 8; A_OA: d.oa += 8; A_PA: d.pa += 8; A_KA: d.ka += 8; A_VA: d.va += 8;
          A_KSA: d.ksa += 8; default: d.vsa += 8;
        endcase
        if (rlen(d, r) == 0 || rbase(d, r) >= LIM) continue;
        try_desc(d, op, 0);
      end
    // misalignment alone and with a bad descriptor; bad ops
    make_template();
    foreach (ops[k]) begin
      d = tp; d.ka += 4; try_desc(d, ops[k]);
      d = tp; d.qa += 2; d.oa += 1; try_desc(d, ops[k]);
      d = tp; d.ksa += 4; d.hs = 0; try_desc(d, ops[k]);
      d = tp; d.qa += 4; d.hs = 0; try_desc(d, ops[k]);
    end
    d = tp; d.pen = 1; d.pa += 4; try_desc(d, 1);
    d = tp; d.pen = 0; d.pa += 4; try_desc(d, 1);
    write_desc(tp);
    wr(A_CTRL, 32'h01); wr(A_CTRL, 32'h31); wr(A_CTRL, 32'hF1); wr(A_CTRL, 32'h21);
    // START_BUSY in every cycle of the check (k = 1 .. CHK, k = CHK is the verdict cycle) and
    // during the op (also with a bad op); descriptor writes during the check
    for (int k = 1; k <= CHK; k++) begin
      @(posedge clk);
      wr_en <= 1; wr_addr <= A_CTRL; wr_data <= 32'h11;                     // cycle s
      for (int j = 1; j <= k; j++) begin
        @(posedge clk);
        wr_en <= j == k; wr_addr <= A_CTRL; wr_data <= (k % 2) ? 32'h11 : 32'hF1;   // s + j
      end
      @(posedge clk);
      wr_en <= 0;
      finish_op();
    end
    // descriptor writes during the check: the verdict is still the one of the latched values
    for (int k = 0; k < 6; k++) begin
      automatic int cw = (k % 2 || KV_SRC == 1) ? 32'h11 : 32'h21;
      write_desc(tp);
      wr(A_CTRL, cw);
      wr(A_HS, 32'(k < 2 ? 0 : 4));        // legal latched, illegal registers
      finish_op();
      d = tp; d.hs = 0;
      write_desc(d);
      wr(A_CTRL, cw);
      wr(A_HS, 32'(tp.hs));                 // illegal latched, legal registers
      finish_op();
    end
    write_desc(tp);
    for (int k = 0; k < 4; k++) begin
      wr(A_CTRL, 32'h11);
      while (!m_busy) @(posedge clk);
      repeat (2) @(posedge clk);
      wr(A_CTRL, k[0] ? 32'h11 : 32'h51);        // START_BUSY during the op (with BAD_OP)
      // CTRL in the done cycle: start = 1 (accepted) or start = 0
      @(posedge clk);
      wr_en <= 1; wr_addr <= A_CTRL; wr_data <= k[1] ? 32'h11 : 32'h10; done_i <= 1;
      @(posedge clk);
      wr_en <= 0; done_i <= 0;
      finish_op();
    end
    // W1C against a set of the same bit (START_BUSY set while ERR bit 0 is cleared)
    wr(A_CTRL, 32'h11);
    @(posedge clk);
    wr_en <= 1; wr_addr <= A_CTRL; wr_data <= 32'h11;
    @(posedge clk);
    wr_en <= 1; wr_addr <= A_ERR; wr_data <= 32'h3F; rd_err <= 1;
    @(posedge clk);
    wr_en <= 0; rd_err <= 0;
    finish_op();
    wr(A_ERR, 32'h3F);
  endtask

  // ---------------- random ----------------
  int addrs[] = '{A_ID, A_CONFIG, A_CTRL, A_STATUS, A_ERR, A_CYCLES, A_RDST, A_WRST, A_OPS, A_CFG2,
                  A_CFG3, A_QA, A_OA, A_PA, A_KA, A_VA, A_KSA, A_VSA, A_T, A_HS, A_FMT, A_HEAD,
                  A_LAYER, A_SEQ, A_POS, A_KVH, 'h2C, 'h3C, 'h7C, 'h80, 'hFC, 'h100, 'hFFC};

  function automatic logic [31:0] rnd_val(int a);
    int k = $urandom_range(9);
    if (k < 4 && a >= A_QA && a <= A_KVH) return desc_word(tp, a);
    case (a)
      A_QA, A_OA, A_PA, A_KA, A_VA, A_KSA, A_VSA: begin
        // a range of the current registers ending exactly at 2^32 (+- 8), misaligned, random
        automatic int rr[$];
        case (a)
          A_QA: rr = '{R_QR}; A_OA: rr = '{R_OR}; A_PA: rr = '{R_PR};
          A_KA: rr = '{R_KR, R_WKR}; A_VA: rr = '{R_VR, R_WVR}; A_KSA: rr = '{R_KSR, R_WKSR};
          default: rr = '{R_VSR, R_WVSR};
        endcase
        if (k < 7) begin
          automatic longint unsigned len = rlen(md, rr[$urandom_range(rr.size() - 1)]);
          return 32'(LIM - len + 8 * (longint'($urandom_range(2)) - 1));
        end
        if (k == 7) return desc_word(tp, a) + $urandom_range(7, 1);
        if (k == 8) return 32'hFFFF_FFF8 - 8 * $urandom_range(64);
        return $urandom;
      end
      A_T: case (k) 4: return 0; 5: return TMAX; 6: return TMAX + 1; 7: return md.seq + $urandom_range(1);
                    8: return $urandom_range(1) ? 1 : 65535; default: return $urandom; endcase
      A_HS: case (k) 4: return 0; 5: return KL; 6: return KL + 8; 7: return HS_MAX + $urandom_range(8);
                     8: return 8 * $urandom_range(31); default: return $urandom; endcase
      A_FMT: return {15'($urandom), 1'($urandom), 3'($urandom), 5'(k < 7 ? 4 * $urandom_range(4, 2) : $urandom),
                     3'($urandom), 5'(k < 6 ? 4 * $urandom_range(4, 2) : $urandom)};
      A_HEAD: begin
        automatic int km = k < 6 ? $urandom_range(8, 1) : $urandom_range(255);
        automatic int nh = k == 6 ? 0 : (k == 7 ? NKV * km - tp.h0 + $urandom_range(1) : $urandom_range(255));
        automatic int h0 = k == 8 ? 256 - nh + $urandom_range(1) : (k == 7 ? tp.h0 : $urandom_range(255));
        return {8'($urandom), 8'(km), 8'(nh), 8'(h0)};
      end
      A_LAYER: return k < 7 ? NL - 1 + $urandom_range(1) : $urandom;
      A_SEQ: case (k) 4: return md.t - $urandom_range(1); 5: return md.pos + $urandom_range(1); 6: return 0;
                      7: return 65535; default: return $urandom; endcase
      A_POS: case (k) 4: return TMAX - $urandom_range(1); 5: return md.seq - $urandom_range(1); default: return $urandom; endcase
      A_KVH: begin
        automatic int nk = k < 7 ? $urandom_range(NKV + 1) : $urandom_range(255);
        automatic int k0 = k < 6 ? NKV - nk + $urandom_range(1) : $urandom_range(255);
        return {16'($urandom), 8'(nk), 8'(k0)};
      end
      A_CTRL: return k < 4 ? {24'($urandom), 4'd1, 3'($urandom), 1'b1} :
                     (k < 7 ? {24'($urandom), 4'd2, 3'($urandom), 1'b1} :
                      (k < 9 ? {24'($urandom), 4'($urandom), 3'($urandom), 1'($urandom)} : 32'h10));
      A_ERR: return k < 6 ? 32'h3F : $urandom;
      default: return $urandom;
    endcase
  endfunction

  initial begin
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("N_CYC=%d", n_cyc));
    void'($value$plusargs("PDONE=%d", pdone));
    void'($value$plusargs("PEV=%d", pev));
    $display("tb_attn_csr: KV_SRC %0d KL %0d HS_MAX %0d TMAX %0d NKV %0d NL %0d CHK %0d SEED %0d N_CYC %0d",
             KV_SRC, KL, HS_MAX, TMAX, NKV, NL, CHK, seed, n_cyc);
    md = '{default: 0};
    mdl = md;
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    @(posedge clk);
    directed();
    $display("tb_attn_csr: directed done (accepted %0d, pass ATTN %0d KVW %0d, fail %0d)", n_acc, n_pass_a,
             n_pass_w, n_fail);
    for (longint i = 0; i < n_cyc; i++) begin
      @(posedge clk);
      begin
        automatic int a = addrs[$urandom_range(addrs.size() - 1)];
        automatic int k = $urandom_range(19);
        if ($urandom_range(999) == 0) make_template();
        if (k < 3) a = A_CTRL;
        else if (k < 4) a = A_ERR;
        else if (k < 12) a = dsc_addrs[$urandom_range(dsc_addrs.size() - 1)];
        wr_en   <= $urandom_range(2) == 0;
        wr_addr <= ADDR_W'(a + ($urandom_range(7) == 0 ? $urandom_range(3) : 0));
        wr_data <= rnd_val(a);
        rd_en   <= $urandom_range(1);
        rd_addr <= ADDR_W'(addrs[$urandom_range(addrs.size() - 1)] + $urandom_range(3));
        // m_busy is the op state of the coming cycle (updated at the last negedge)
        done_i   <= m_busy && $urandom_range(99) < pdone;
        rd_err   <= $urandom_range(99) < pev / 3;
        wr_err   <= $urandom_range(99) < pev / 3;
        rd_stall <= $urandom_range(99) < pev;
        wr_stall <= $urandom_range(99) < pev;
      end
    end
    @(posedge clk);
    wr_en <= 0; rd_en <= 0; done_i <= 0; rd_err <= 0; wr_err <= 0;
    repeat (CHK + 2) @(posedge clk);
    // ---------------- coverage ----------------
    $display("coverage: accepted %0d, pass ATTN %0d KVW %0d, verdict fail %0d (BAD_DESC + MISALIGN %0d), BAD_OP %0d (KVW with DDR KV %0d)",
             n_acc, n_pass_a, n_pass_w, n_fail, n_both, n_badop, n_kvw_ddr);
    $display("coverage: START_BUSY in the op %0d (with BAD_OP %0d), CTRL in the done cycle start=0 %0d start=1 %0d, W1C vs set %0d, descriptor written during the check with another verdict %0d, ERR sets %p",
             n_sb_op, n_sb_badop, n_ctrl_done0, n_ctrl_done1, n_w1c_set, n_wr_chk_diff, n_err);
    if (n_pass_a < 20 || (KV_SRC == 0 && n_pass_w < 20) || n_both == 0 || n_sb_op == 0 || n_sb_badop == 0 ||
        n_ctrl_done0 == 0 || n_ctrl_done1 == 0 || n_w1c_set == 0 || n_wr_chk_diff == 0 ||
        (KV_SRC == 1 && n_kvw_ddr == 0))
      c_cov.fail("a pass / collision case did not happen");
    else c_cov.pass();
    for (int k = 1; k <= CHK; k++)
      if (!n_sb_chk.exists(k)) c_cov.fail($sformatf("START_BUSY in check cycle %0d never happened", k));
      else c_cov.pass();
    foreach (n_err[b]) if (n_err[b] == 0) c_cov.fail($sformatf("ERR bit %0d never set", b)); else c_cov.pass();
    for (int r = 0; r < NR; r++) begin
      automatic bit used = (r <= R_HS) || (r >= R_T && r <= R_PR) ||
                           (KV_SRC == 0 && r >= R_HSKL && r <= R_KVH) || (KV_SRC == 1 && r >= R_TSEQ && r <= R_VSR) ||
                           (KV_SRC == 0 && r >= R_NKV0);
      automatic bit is_rng = r == R_QR || r == R_OR || r == R_PR || (r >= R_KR && r <= R_VSR) || r >= R_WKR;
      // reasons that cannot be alone in this build
      if (r == R_HSKL && HS_MAX <= KL) used = 0;   // hs > KL implies hs > HS_MAX (reason HS)
      if (r == R_KBW && KW >= 16) used = 0;        // kb > KW implies kb not in {8, 12, 16}
      if (r == R_VBW && VW >= 16) used = 0;
      if (r == R_HEND && KV_SRC == 0 && NKV < 2) used = 0;   // HEAD0 + NHEAD > 256 implies kv head >= 1
      if (!used) continue;
      $display("coverage: %-14s alone %0d%s", rname[r], n_single[r],
               is_rng ? $sformatf(", edge 2^32 accepted %0d, +8 rejected %0d", n_edge_ok[r], n_edge_bad[r]) : "");
      if (n_single[r] == 0) c_cov.fail($sformatf("reason %s never alone", rname[r])); else c_cov.pass();
      if (is_rng && (n_edge_ok[r] == 0 || n_edge_bad[r] == 0))
        c_cov.fail($sformatf("2^32 edge of %s not covered", rname[r]));
      else if (is_rng) c_cov.pass();
    end
    void'(tb_final_report('{c_rd, c_ctl, c_lat, c_der, c_cov}));
    $finish;
  end
endmodule
