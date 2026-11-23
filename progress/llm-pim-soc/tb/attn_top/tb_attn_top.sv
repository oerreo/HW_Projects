// tb_attn_top: attn_top over AXI4-Lite (tb/common/axil_bfm.sv) with AXI memory models
// (tb/common/axi_mem_slave.sv: one per read port with the same contents, one for the writes).
//
// Records (+VEC, K_ATTN2 of the K12V8 dumps, golden outputs p and o): the records of one
// (position, layer) group (NH heads) give q of every head and the full K / V cache of every kv head
// (head j KVMUL holds kv head j). The TB writes them in the golden buffer layout (model/src/fwd_h.c:
// kv head j position t at base + ((l NKV + j) SEQ + t) x row bytes, scales {int32 m, int32 e}) and
// the q records (Q_ADDR + h QB: {qm, qe}, q int16 [hs]).
//   KV_SRC 0 (BRAM), forward order: for each recorded position in order and each layer l: KVW of
//     every position not yet stored (all kv heads, one op per position), then ATTN (T = pos + 1),
//     heads split into one or two ops at random. KV is written only through KVW.
//   KV_SRC 1 (DDR): ATTN per group on the DDR cache (+ random head split).
// Checks: o of every head (and p if p_en, random per op) == record outputs; 16-byte guards before
// and after every o / p region unwritten; ERR == 0 after each op; CYCLES == e - s (STATUS model).
// CSR reference model (every cycle, docs/spec/attn.md 4): descriptor registers, ERR (W1C, set
// wins), done_sticky, busy (check s + 1 .. v and op), call acceptance in s and the verdict in
// v = s + CHK_CYC with an independent descriptor check of the descriptor latched in s,
// CYCLES / RD_STALL / WR_STALL / OPS, and the read data of every register read.
// +ERR=1: error paths and recovery: BAD_OP (op 0, 3, 15; KVW with KV_SRC 1), BAD_DESC (each
// reason alone), MISALIGN, START_BUSY, SLVERR / DECERR on a q record read (RD_RESP) and on an o
// write (WR_RESP); after each, a correct op must still give the golden result.
// +RND=1: random register traffic (writes to every register, reads) between ops.
// +MSTALL: memory stalls and latency; +WBLK=1: long write-channel blocks (WREADY 0 for 100..1200
// cycles): the write buffer, the packer and a core's output credit must be held (coverage).
// Stall counters: +MSTALL runs must count RD_STALL > 0 and +WBLK runs WR_STALL > 0 (sums over the
// run), so that a counter whose event can never be true is not hidden by the per-cycle CSR model.
// Plusargs: +SEED +VEC +NH +NKV +SEQ +MAXGRP +MAXPOS +MSTALL +WBLK +ERR +RND +MAXD.
`timescale 1ns / 1ps
module tb_attn_top;
  import tb_util_pkg::*;
  import kdpi_pkg::*;
  import attn_tb_pkg::*;
  import llm_pkg::*;

  parameter int H_PAR     = 2;
  parameter int KV_SRC    = 0;
  parameter int HS_MAX    = 8;
  parameter int TMAX      = 512;
  parameter int NKV       = 4;
  parameter int NL        = 5;
  parameter int KW        = 12;
  parameter int VW        = 8;
  parameter int OUT_DEPTH = 16;
  parameter int MAX_BURST = 16;
  parameter int OUTS      = 4;
  parameter int ADDR_W    = 12;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  // AXI-Lite
  logic [ADDR_W-1:0] awaddr, araddr;
  logic [2:0]  awprot, arprot;
  logic        awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;
  logic [31:0] wdata, rdata;
  logic [3:0]  wstrb;
  logic [1:0]  bresp, rresp;
  // AXI write
  logic [0:0]  m_awid, m_bid;
  logic [31:0] m_awaddr;
  logic [7:0]  m_awlen;
  logic [2:0]  m_awsize, m_awprot;
  logic [1:0]  m_awburst, m_bresp;
  logic        m_awlock, m_awvalid, m_awready, m_wlast, m_wvalid, m_wready, m_bvalid, m_bready;
  logic [3:0]  m_awcache, m_awqos;
  logic [63:0] m_wdata;
  logic [7:0]  m_wstrb;
  // AXI read ports
  logic [H_PAR-1:0][0:0]  m_arid, m_rid;
  logic [H_PAR-1:0][31:0] m_araddr;
  logic [H_PAR-1:0][7:0]  m_arlen;
  logic [H_PAR-1:0][2:0]  m_arsize, m_arprot;
  logic [H_PAR-1:0][1:0]  m_arburst, m_rresp;
  logic [H_PAR-1:0]       m_arlock, m_arvalid, m_arready, m_rlast, m_rvalid, m_rready;
  logic [H_PAR-1:0][3:0]  m_arcache, m_arqos;
  logic [H_PAR-1:0][63:0] m_rdata;

  attn_top #(.H_PAR(H_PAR), .KV_SRC(KV_SRC), .HS_MAX(HS_MAX), .TMAX(TMAX), .NKV(NKV), .NL(NL),
             .KW(KW), .VW(VW), .OUT_DEPTH(OUT_DEPTH), .MAX_BURST(MAX_BURST), .OUTS(OUTS),
             .ADDR_W(ADDR_W)) dut (
    .clk, .rst_n,
    .s_axi_awaddr_i(awaddr), .s_axi_awprot_i(awprot), .s_axi_awvalid_i(awvalid), .s_axi_awready_o(awready),
    .s_axi_wdata_i(wdata), .s_axi_wstrb_i(wstrb), .s_axi_wvalid_i(wvalid), .s_axi_wready_o(wready),
    .s_axi_bresp_o(bresp), .s_axi_bvalid_o(bvalid), .s_axi_bready_i(bready),
    .s_axi_araddr_i(araddr), .s_axi_arprot_i(arprot), .s_axi_arvalid_i(arvalid), .s_axi_arready_o(arready),
    .s_axi_rdata_o(rdata), .s_axi_rresp_o(rresp), .s_axi_rvalid_o(rvalid), .s_axi_rready_i(rready),
    .m_axi_awid_o(m_awid), .m_axi_awaddr_o(m_awaddr), .m_axi_awlen_o(m_awlen), .m_axi_awsize_o(m_awsize),
    .m_axi_awburst_o(m_awburst), .m_axi_awlock_o(m_awlock), .m_axi_awcache_o(m_awcache),
    .m_axi_awprot_o(m_awprot), .m_axi_awqos_o(m_awqos), .m_axi_awvalid_o(m_awvalid),
    .m_axi_awready_i(m_awready), .m_axi_wdata_o(m_wdata), .m_axi_wstrb_o(m_wstrb),
    .m_axi_wlast_o(m_wlast), .m_axi_wvalid_o(m_wvalid), .m_axi_wready_i(m_wready),
    .m_axi_bid_i(m_bid), .m_axi_bresp_i(m_bresp), .m_axi_bvalid_i(m_bvalid), .m_axi_bready_o(m_bready),
    .m_axi_arid_o(m_arid), .m_axi_araddr_o(m_araddr), .m_axi_arlen_o(m_arlen), .m_axi_arsize_o(m_arsize),
    .m_axi_arburst_o(m_arburst), .m_axi_arlock_o(m_arlock), .m_axi_arcache_o(m_arcache),
    .m_axi_arprot_o(m_arprot), .m_axi_arqos_o(m_arqos), .m_axi_arvalid_o(m_arvalid),
    .m_axi_arready_i(m_arready), .m_axi_rid_i(m_rid), .m_axi_rdata_i(m_rdata), .m_axi_rresp_i(m_rresp),
    .m_axi_rlast_i(m_rlast), .m_axi_rvalid_i(m_rvalid), .m_axi_rready_o(m_rready));

  axil_bfm #(.ADDR_W(ADDR_W)) bfm (
    .clk, .rst_n, .awaddr, .awprot, .awvalid, .awready, .wdata, .wstrb, .wvalid, .wready,
    .bresp, .bvalid, .bready, .araddr, .arprot, .arvalid, .arready, .rdata, .rresp, .rvalid, .rready);

  axi_mem_slave #(.DW(64), .AW(32), .IDW(1), .MAX_LEN(15), .NAME("wmem")) wmem (
    .clk, .rst_n,
    .awid_i(m_awid), .awaddr_i(m_awaddr), .awlen_i(m_awlen), .awsize_i(m_awsize), .awburst_i(m_awburst),
    .awvalid_i(m_awvalid), .awready_o(m_awready), .wdata_i(m_wdata), .wstrb_i(m_wstrb), .wlast_i(m_wlast),
    .wvalid_i(m_wvalid), .wready_o(m_wready), .bid_o(m_bid), .bresp_o(m_bresp), .bvalid_o(m_bvalid),
    .bready_i(m_bready),
    .arid_i(1'b0), .araddr_i('0), .arlen_i('0), .arsize_i(3'd3), .arburst_i(2'b01), .arvalid_i(1'b0),
    .arready_o(), .rid_o(), .rdata_o(), .rresp_o(), .rlast_o(), .rvalid_o(), .rready_i(1'b1));

  for (genvar p = 0; p < H_PAR; p++) begin : g_rmem
    axi_mem_slave #(.DW(64), .AW(32), .IDW(1), .MAX_LEN(15), .NAME("rmem")) mem (
      .clk, .rst_n,
      .awid_i(1'b0), .awaddr_i('0), .awlen_i('0), .awsize_i(3'd3), .awburst_i(2'b01), .awvalid_i(1'b0),
      .awready_o(), .wdata_i('0), .wstrb_i('0), .wlast_i(1'b0), .wvalid_i(1'b0), .wready_o(),
      .bid_o(), .bresp_o(), .bvalid_o(), .bready_i(1'b1),
      .arid_i(m_arid[p]), .araddr_i(m_araddr[p]), .arlen_i(m_arlen[p]), .arsize_i(m_arsize[p]),
      .arburst_i(m_arburst[p]), .arvalid_i(m_arvalid[p]), .arready_o(m_arready[p]),
      .rid_o(m_rid[p]), .rdata_o(m_rdata[p]), .rresp_o(m_rresp[p]), .rlast_o(m_rlast[p]),
      .rvalid_o(m_rvalid[p]), .rready_i(m_rready[p]));
  end

  tb_checker c_o = new("o"), c_p = new("p"), c_guard = new("guard"), c_err = new("err"),
             c_csr = new("csr_model"), c_rd = new("csr_read"), c_cov = new("coverage"),
             c_rec = new("record"), c_stl = new("stall_count");

  // ---------------- memory helpers ----------------
  function automatic void rmem_w64(longint unsigned a, logic [63:0] d);
    for (int p = 0; p < H_PAR; p++) begin
      case (p)
        0: g_rmem[0].mem.bd_write64(a, d);
        1: if (H_PAR > 1) g_rmem[H_PAR > 1 ? 1 : 0].mem.bd_write64(a, d);
        2: if (H_PAR > 2) g_rmem[H_PAR > 2 ? 2 : 0].mem.bd_write64(a, d);
        default: if (H_PAR > 3) g_rmem[H_PAR > 3 ? 3 : 0].mem.bd_write64(a, d);
      endcase
    end
  endfunction
  function automatic void rmem_w8(longint unsigned a, byte unsigned d);
    for (int p = 0; p < H_PAR; p++) begin
      case (p)
        0: g_rmem[0].mem.bd_write8(a, d);
        1: if (H_PAR > 1) g_rmem[H_PAR > 1 ? 1 : 0].mem.bd_write8(a, d);
        2: if (H_PAR > 2) g_rmem[H_PAR > 2 ? 2 : 0].mem.bd_write8(a, d);
        default: if (H_PAR > 3) g_rmem[H_PAR > 3 ? 3 : 0].mem.bd_write8(a, d);
      endcase
    end
  endfunction
  function automatic int wmem_r32(longint unsigned a);
    logic [63:0] w = wmem.bd_read64(a & ~64'd7);
    return (a & 4) ? int'(w[63:32]) : int'(w[31:0]);
  endfunction

  // ---------------- CSR access ----------------
  localparam int A_ID = 'h00, A_CONFIG = 'h04, A_CTRL = 'h08, A_STATUS = 'h0C, A_ERR = 'h10,
                 A_CYCLES = 'h14, A_RDST = 'h18, A_WRST = 'h1C, A_OPS = 'h20, A_CFG2 = 'h24,
                 A_CFG3 = 'h28, A_QA = 'h40, A_OA = 'h44, A_PA = 'h48, A_KA = 'h4C, A_VA = 'h50,
                 A_KSA = 'h54, A_VSA = 'h58, A_T = 'h5C, A_HS = 'h60, A_FMT = 'h64, A_HEAD = 'h68,
                 A_LAYER = 'h6C, A_SEQ = 'h70, A_POS = 'h74, A_KVH = 'h78;

  task automatic csr_w(int a, logic [31:0] d);
    bfm.write0(ADDR_W'(a), d);
  endtask
  task automatic csr_r(int a, output logic [31:0] d);
    bfm.read(ADDR_W'(a), d);
  endtask

  // run one op; returns ERR after it (W1C cleared); checks done
  longint n_ops = 0;
  task automatic run_op(int op, output logic [31:0] err, output logic [31:0] cycles, input bit expect_run = 1);
    logic [31:0] st;
    int n = 0;
    csr_w(A_CTRL, 32'((op << 4) | 1));
    if (expect_run) begin
      do begin
        csr_r(A_STATUS, st);
        if (++n > 2000000) $fatal(1, "tb_attn_top: op %0d did not finish", op);
      end while (st[1] !== 1'b1);
      n_ops++;
    end
    csr_r(A_ERR, err);
    csr_r(A_CYCLES, cycles);
    if (err != 0) csr_w(A_ERR, err);
  endtask

  // ---------------- CSR reference model (every cycle) ----------------
  typedef struct {
    longint unsigned qa, oa, pa, ka, va, ksa, vsa;
    int t, hs, kb, vb, pen, h0, nh, km, ly, seq, pos, kv0, nkv;
  } desc_t;
  desc_t md, mdl;                 // registers, descriptor latched by the accepted call
  int    m_err = 0, m_done = 0, m_busy = 0, m_kvw = 0, m_chk = 0;
  // check cycles (attn.md 4.1): KV_SRC 1: 18; KV_SRC 0: max(10, w(hs) + 1, w(kv) + w(hs) + 2),
  // w(hs) = bits of min(KL, HS_MAX) = 8, w(kv) = bits of NKV - 1 (at least 1)
  localparam int W_HS = $clog2(9), W_KV = (NKV > 1) ? $clog2(NKV) : 1;
  localparam int CHK  = KV_SRC ? 18 : ((W_KV + W_HS + 2 > 10) ? W_KV + W_HS + 2 : 10);
  longint unsigned m_cyc = 0, m_rdst = 0, m_wrst = 0, m_ops = 0;
  // RD_STALL / WR_STALL cycles of all ops (the counters the CSR model checks every cycle): a
  // counter that never moves is caught by the stall-run requirements at the end
  longint n_rdst = 0, n_wrst = 0;
  logic [31:0] m_rd_exp;
  bit    m_rd_pend = 0;

  function automatic bit d_ok(desc_t d, bit kvw);
    longint unsigned lim = 64'h1_0000_0000;
    int hend = d.h0 + d.nh;
    int kvmax = d.km == 0 ? 0 : (hend - 1) / d.km;
    longint unsigned rowk = d.hs * (d.kb > 8 ? 2 : 1), rowv = d.hs * (d.vb > 8 ? 2 : 1), qb = 8 + 2 * d.hs;
    bit fmt = (d.kb == 8 || d.kb == 12 || d.kb == 16) && (d.vb == 8 || d.vb == 12 || d.vb == 16);
    bit hs_ok = d.hs != 0 && d.hs % 8 == 0 && d.hs <= HS_MAX;
    if (!kvw) begin
      longint unsigned slot = longint'(kvmax) * d.seq + d.t;
      bit ok = fmt && hs_ok && d.t != 0 && d.t <= TMAX && d.nh != 0 && d.km != 0 && hend <= 256 &&
               d.qa + hend * qb <= lim && d.oa + hend * d.hs * 4 <= lim &&
               (!d.pen || d.pa + longint'(hend) * ((d.t + 1) / 2) * 8 <= lim);
      if (KV_SRC == 0) ok = ok && d.hs <= 8 && d.kb <= KW && d.vb <= VW && d.ly < NL && kvmax < NKV;
      else ok = ok && d.t <= d.seq && d.ka + slot * rowk <= lim && d.va + slot * rowv <= lim &&
                d.ksa + slot * 8 <= lim && d.vsa + slot * 8 <= lim;
      return ok;
    end else begin
      longint unsigned slot = longint'(d.kv0 + d.nkv - 1) * d.seq + d.pos + 1;
      return fmt && hs_ok && d.hs <= 8 && d.kb <= KW && d.vb <= VW && d.nkv != 0 &&
             d.kv0 + d.nkv <= NKV && d.pos < TMAX && d.ly < NL && d.pos < d.seq &&
             d.ka + slot * rowk <= lim && d.va + slot * rowv <= lim && d.ksa + slot * 8 <= lim &&
             d.vsa + slot * 8 <= lim;
    end
  endfunction
  function automatic bit al_ok(desc_t d, bit kvw);
    bit kv = (d.ka % 8 == 0) && (d.va % 8 == 0) && (d.ksa % 8 == 0) && (d.vsa % 8 == 0);
    if (kvw) return kv;
    return d.qa % 8 == 0 && d.oa % 8 == 0 && (!d.pen || d.pa % 8 == 0) && (KV_SRC == 0 || kv);
  endfunction

  function automatic logic [31:0] m_read(int a);
    case (a & 'hFC)
      A_ID: return 32'h4154_0001;
      A_CONFIG: return {16'(TMAX), 4'd3, 1'(KV_SRC), 3'(H_PAR), 8'd100};
      A_STATUS: return {29'd0, m_err != 0, 1'(m_done), 1'(m_busy || m_chk != 0)};
      A_ERR: return 32'(m_err);
      A_CYCLES: return 32'(m_cyc);
      A_RDST: return 32'(m_rdst);
      A_WRST: return 32'(m_wrst);
      A_OPS: return 32'(m_ops);
      A_CFG2: return KV_SRC ? 32'(HS_MAX) : {8'd0, 8'(NL), 8'(NKV), 8'(HS_MAX)};
      A_CFG3: return KV_SRC ? 32'd0 : {16'(TMAX), 8'(VW), 8'(KW)};
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

  longint n_starts = 0;
  always @(negedge clk) begin
    if (rst_n) begin
      automatic bit we = dut.u_csr.wr_en_i, wr_hit;
      automatic int wa = int'(32'(dut.u_csr.wr_addr_i)), w = wa & 'hFC;
      automatic logic [31:0] wd = dut.u_csr.wr_data_i;
      automatic bit done = dut.run_done;
      automatic bit idle = (!m_busy && m_chk == 0) || done;
      automatic bit verdict = m_chk == 1, was_busy = m_busy || m_chk != 0;
      automatic int set = 0, op = int'(wd[7:4]);
      automatic bit sreq, op_ok, acc, ok_d = 0, ok_a = 0, st;
      automatic logic [31:0] got;
      wr_hit = we && (wa >> 8) == 0;
      // read data of this cycle (state before the write of the same cycle)
      if (dut.u_csr.rd_en_i === 1'b1) begin
        got = dut.u_csr.rd_data_o;
        if (got !== m_read(int'(32'(dut.u_csr.rd_addr_i))) && (int'(32'(dut.u_csr.rd_addr_i)) >> 8) == 0)
          c_rd.fail($sformatf("read 0x%0h: 0x%08h model 0x%08h", dut.u_csr.rd_addr_i, got,
                              m_read(int'(32'(dut.u_csr.rd_addr_i)))));
        else c_rd.pass();
      end
      // state compare (before this cycle's update)
      if (int'(dut.u_csr.err_q) !== m_err || int'(dut.u_csr.done_q) !== m_done ||
          int'(dut.u_csr.busy_q) !== m_busy || int'(dut.u_csr.chk_q) !== int'(m_chk != 0) ||
          longint'(dut.u_csr.cyc_q) !== m_cyc ||
          longint'(dut.u_csr.rdst_q) !== m_rdst || longint'(dut.u_csr.wrst_q) !== m_wrst ||
          longint'(dut.u_csr.ops_q) !== m_ops)
        c_csr.fail($sformatf("state err %0h/%0h done %0d/%0d busy %0d/%0d cyc %0d/%0d ops %0d/%0d",
                             dut.u_csr.err_q, m_err, dut.u_csr.done_q, m_done, dut.u_csr.busy_q, m_busy,
                             dut.u_csr.cyc_q, m_cyc, dut.u_csr.ops_q, m_ops));
      else c_csr.pass();
      // call acceptance (s) and verdict (v) on the latched descriptor
      sreq  = wr_hit && w == A_CTRL && wd[0];
      op_ok = op == 1 || (op == 2 && KV_SRC == 0);
      acc   = sreq && idle && op_ok;
      if (verdict) begin
        ok_d = d_ok(mdl, m_kvw);
        ok_a = al_ok(mdl, m_kvw);
      end
      st = verdict && ok_d && ok_a;
      if (st !== dut.start) c_csr.fail($sformatf("start %b model %b (kvw %0d d %0d a %0d)", dut.start, st, m_kvw, ok_d, ok_a));
      if (sreq && !idle) set |= 1;
      if (sreq && !op_ok) set |= 2;
      if (verdict && !ok_d) set |= 4;
      if (verdict && !ok_a) set |= 8;
      if (dut.rd_err_ev) set |= 16;
      if (dut.wr_err_ev) set |= 32;
      if (done && !m_busy) c_csr.fail("done while not busy");
      // update
      if (acc) begin
        m_chk = CHK;
        mdl   = md;
        m_kvw = op == 2;
      end else if (m_chk != 0) m_chk--;
      if (st) begin
        m_busy = 1;
        n_starts++;
      end else if (done) m_busy = 0;
      if (wr_hit && w == A_CTRL && idle && !(wd[0] && !op_ok)) m_done = 0;
      else if (done) m_done = 1;
      m_err = (m_err & ~((wr_hit && w == A_ERR) ? int'(wd[5:0]) : 0)) | set;
      if (acc) begin m_cyc = 0; m_rdst = 0; m_wrst = 0; end
      else if (was_busy) begin
        m_cyc++;
        if (dut.rd_stall_ev) begin m_rdst++; n_rdst++; end
        if (dut.wr_stall_ev) begin m_wrst++; n_wrst++; end
      end
      if (done) m_ops++;
      if (wr_hit)
        case (w)
          A_QA: md.qa = wd; A_OA: md.oa = wd; A_PA: md.pa = wd; A_KA: md.ka = wd; A_VA: md.va = wd;
          A_KSA: md.ksa = wd; A_VSA: md.vsa = wd; A_T: md.t = wd[15:0]; A_HS: md.hs = wd[7:0];
          A_FMT: begin md.kb = wd[4:0]; md.vb = wd[12:8]; md.pen = wd[16]; end
          A_HEAD: begin md.h0 = wd[7:0]; md.nh = wd[15:8]; md.km = wd[23:16]; end
          A_LAYER: md.ly = wd[7:0]; A_SEQ: md.seq = wd[15:0]; A_POS: md.pos = wd[15:0];
          A_KVH: begin md.kv0 = wd[7:0]; md.nkv = wd[15:8]; end
          default: ;
        endcase
    end
  end

  // ---------------- write-channel blocks and coverage ----------------
  int wblk = 0, split = 1, mstall = 0, pen_mode = 2;   // PEN 0 off, 1 on, 2 random
  longint kvw_cyc = 0, kvw_n = 0, kvw_split = 0;
  longint n_wfull = 0, n_credit = 0, n_pkhold = 0, n_pkv = 0, n_blk = 0;
  // a block starts (probability 1/8 per cycle) while the packer holds a beat, at most every
  // 200 cycles, and keeps WREADY at 0 for 100..1200 cycles
  initial begin
    wait (rst_n === 1'b1);
    forever begin
      @(posedge clk);
      if (wblk && dut.pk_valid_q === 1'b1 && $urandom_range(7) == 0) begin
        wmem.cfg_stall(0, 0, 100, 0, 0);
        n_blk++;
        repeat ($urandom_range(1200, 100)) @(posedge clk);
        wmem.cfg_stall(0, 0, mstall ? 20 : 0, 0, 0);
        repeat (200) @(posedge clk);
      end
    end
  end
  logic [H_PAR-1:0] credit_hold;
  for (genvar e = 0; e < H_PAR; e++) begin : g_cov
    // P3 first beat held by the output credit, or an o read held in O
    assign credit_hold[e] = (int'(dut.g_eng[e].u_core.st_q) == 8 && dut.g_eng[e].u_core.kv_valid_i &&
                             !dut.g_eng[e].u_core.kv_ready_o) ||
                            (int'(dut.g_eng[e].u_core.st_q) == 10 && !dut.g_eng[e].u_core.credit_ok);
  end
  always @(negedge clk)
    if (rst_n) begin
      if (!dut.u_wr.in_ready_o) n_wfull++;
      if (|credit_hold) n_credit++;
      if (dut.pk_valid_q && !dut.wr_in_ready) n_pkhold++;
      if (dut.pk_valid_q) n_pkv++;
    end

  // ---------------- record groups ----------------
  localparam longint unsigned KC = 64'h1000_0000, VC = 64'h1800_0000, KCS = 64'h2000_0000,
                              VCS = 64'h2400_0000, QB0 = 64'h0800_0000;
  longint unsigned obase = 64'h4000_0000;
  int nh = 8, nkv = NKV, seq = 512, kvmul;
  int last_w [NL];
  longint tok_cyc [int];   // ATTN CYCLES per position (sum over layers, one-op runs)

  function automatic longint unsigned slot_a(longint unsigned base, int l, int j, int t, int row);
    return base + (longint'(l * nkv + j) * seq + t) * row;
  endfunction

  // golden layout writes of position t of kv head j (from record c) in layer l
  function automatic void put_kv(att_case c, int l, int j, int t);
    int ek = c.kb > 8 ? 2 : 1, ev = c.vb > 8 ? 2 : 1;
    for (int i = 0; i < c.hs; i++) begin
      for (int b = 0; b < ek; b++) rmem_w8(slot_a(KC, l, j, t, c.hs * ek) + i * ek + b, 8'(c.K[t * c.hs + i] >> (8 * b)));
      for (int b = 0; b < ev; b++) rmem_w8(slot_a(VC, l, j, t, c.hs * ev) + i * ev + b, 8'(c.V[t * c.hs + i] >> (8 * b)));
    end
    rmem_w64(slot_a(KCS, l, j, t, 8), {32'(c.kse[t]), 32'(c.ksm[t])});
    rmem_w64(slot_a(VCS, l, j, t, 8), {32'(c.vse[t]), 32'(c.vsm[t])});
  endfunction

  task automatic set_kv_desc(att_case c, int l);
    int ek = c.kb > 8 ? 2 : 1, ev = c.vb > 8 ? 2 : 1;
    csr_w(A_KA, 32'(slot_a(KC, l, 0, 0, c.hs * ek)));
    csr_w(A_VA, 32'(slot_a(VC, l, 0, 0, c.hs * ev)));
    csr_w(A_KSA, 32'(slot_a(KCS, l, 0, 0, 8)));
    csr_w(A_VSA, 32'(slot_a(VCS, l, 0, 0, 8)));
    csr_w(A_SEQ, 32'(seq));
    csr_w(A_LAYER, 32'(l));
    csr_w(A_HS, 32'(c.hs));
    csr_w(A_FMT, {15'd0, 1'b0, 3'd0, 5'(c.vb), 3'd0, 5'(c.kb)});
  endtask

  // ATTN for heads [h0, h0 + n) of group g; checks o (and p) and guards
  int err_allow = 0;
  logic [31:0] last_err;
  function automatic void put_q(att_case g[$], longint unsigned qa);
    for (int h = 0; h < nh; h++) begin
      longint unsigned a = qa + h * (8 + 2 * g[h].hs);
      rmem_w64(a, {32'(g[h].qe), 32'(g[h].qm)});
      for (int i = 0; i < g[h].hs; i++) begin
        rmem_w8(a + 8 + 2 * i, 8'(g[h].q[i]));
        rmem_w8(a + 9 + 2 * i, 8'(g[h].q[i] >> 8));
      end
    end
  endfunction

  task automatic attn_op(att_case g[$], int l, int h0, int n, bit pen, output longint cycles);
    logic [31:0] err, cyc;
    att_case c0 = g[0];
    int T = c0.T, hs = c0.hs, ps = ((T + 1) / 2) * 8;   // p stride of a head (bytes)
    longint unsigned qa = QB0 + 8 * $urandom_range(500), oa, pa;
    oa = obase + 8 * $urandom_range(3) + 16;
    pa = oa + 32 + longint'(nh) * hs * 4 + 8 * $urandom_range(3);
    obase = (pa + 32 + longint'(nh) * ps + 4096 + 7) & ~64'd7;
    put_q(g, qa);
    csr_w(A_QA, 32'(qa));
    csr_w(A_OA, 32'(oa));
    csr_w(A_PA, 32'(pa));
    csr_w(A_T, 32'(T));
    csr_w(A_FMT, {15'd0, pen, 3'd0, 5'(c0.vb), 3'd0, 5'(c0.kb)});
    csr_w(A_HEAD, {8'd0, 8'(kvmul), 8'(n), 8'(h0)});
    run_op(1, err, cyc);
    cycles = cyc;
    last_err = err;
    if ((err & ~32'(err_allow)) != 0) c_err.fail($sformatf("ATTN T %0d layer %0d: ERR 0x%0h", T, l, err));
    else c_err.pass();
    for (int h = h0; h < h0 + n; h++) begin
      for (int i = 0; i < hs; i++) begin
        int got = wmem_r32(oa + (h * hs + i) * 4);
        if (got !== g[h].o[i]) c_o.fail($sformatf("T %0d layer %0d head %0d o[%0d] %0d exp %0d", T, l, h, i, got, g[h].o[i]));
        else c_o.pass();
      end
      if (pen)
        for (int t = 0; t < T; t++) begin
          int got = wmem_r32(pa + h * ps + t * 4);
          if (got !== g[h].p[t]) c_p.fail($sformatf("T %0d layer %0d head %0d p[%0d] %0d exp %0d", T, l, h, t, got, g[h].p[t]));
          else c_p.pass();
        end
    end
    // guards: bytes before / after the o and p regions of the op's heads, and other heads untouched
    for (int k = 1; k <= 16; k++) begin
      if (wmem.bd_written(oa + h0 * hs * 4 - k) || wmem.bd_written(oa + (h0 + n) * hs * 4 + k - 1) ||
          wmem.bd_written(pa + h0 * ps - k) || wmem.bd_written(pa + (h0 + n - 1) * ps + T * 4 + k - 1))
        c_guard.fail($sformatf("T %0d layer %0d heads %0d..%0d: guard byte %0d written", T, l, h0, h0 + n - 1, k));
      else c_guard.pass();
    end
    if (!pen && wmem.bd_written(pa + h0 * ps)) c_guard.fail("p written with p_en = 0");
  endtask

  task automatic kvw_op(att_case g[$], int l, int t);
    logic [31:0] err, cyc;
    for (int j = 0; j < nkv; j++) put_kv(g[j * kvmul], l, j, t);
    csr_w(A_POS, 32'(t));
    if (split && nkv > 1 && $urandom_range(1)) begin
      // kv heads in two ops (the second with KVH0 > 0)
      int k = $urandom_range(nkv - 1, 1);
      csr_w(A_KVH, {16'd0, 8'(k), 8'd0});
      run_op(2, err, cyc);
      if (err != 0) c_err.fail($sformatf("KVW layer %0d pos %0d heads 0..%0d: ERR 0x%0h", l, t, k - 1, err));
      else c_err.pass();
      csr_w(A_KVH, {16'd0, 8'(nkv - k), 8'(k)});
      run_op(2, err, cyc);
      kvw_split++;
    end else begin
      csr_w(A_KVH, {16'd0, 8'(nkv), 8'd0});
      run_op(2, err, cyc);
      kvw_cyc += cyc;
      kvw_n++;
    end
    if (err != 0) c_err.fail($sformatf("KVW layer %0d pos %0d: ERR 0x%0h", l, t, err));
    else c_err.pass();
  endtask

  task automatic do_group(att_case g[$], int l);
    att_case c0 = g[0];
    int T = c0.T;
    longint cyc_all = 0, cy;
    set_kv_desc(c0, l);
    if (KV_SRC == 0) begin
      for (int t = last_w[l] + 1; t < T; t++) kvw_op(g, l, t);
      last_w[l] = T - 1;
    end else
      for (int j = 0; j < nkv; j++)
        for (int t = 0; t < T; t++) put_kv(g[j * kvmul], l, j, t);
    if (split && $urandom_range(2) == 0) begin
      int k = $urandom_range(nh - 1, 1);
      attn_op(g, l, 0, k, pen_mode == 2 ? $urandom_range(3) != 0 : pen_mode, cy);
      attn_op(g, l, k, nh - k, pen_mode == 2 ? $urandom_range(3) != 0 : pen_mode, cy);
    end else begin
      attn_op(g, l, 0, nh, pen_mode == 2 ? $urandom_range(3) != 0 : pen_mode, cy);
      cyc_all = cy;
      if (tok_cyc.exists(T)) tok_cyc[T] += cyc_all; else tok_cyc[T] = cyc_all;
    end
  endtask

  // ---------------- error paths ----------------
  // PS rule (attn.md 4.1): after the CTRL write wait for STATUS.busy = 0 (the check), then ERR
  task automatic expect_err(int op, int bits, string what, bit restore = 1);
    logic [31:0] err, cyc, st;
    csr_w(A_CTRL, 32'((op << 4) | 1));
    do csr_r(A_STATUS, st); while (st[0] !== 1'b0);
    csr_r(A_ERR, err);
    csr_r(A_STATUS, st);
    if (err !== 32'(bits) || st[0] !== 1'b0) c_err.fail($sformatf("%s: ERR 0x%0h exp 0x%0h busy %b", what, err, bits, st[0]));
    else c_err.pass();
    csr_w(A_ERR, err);
  endtask

  task automatic err_paths(att_case g[$], int l);
    att_case c0 = g[0];
    logic [31:0] err, cyc;
    longint cy;
    set_kv_desc(c0, l);
    csr_w(A_QA, 32'(QB0)); csr_w(A_OA, 32'(obase)); csr_w(A_PA, 32'(obase + 64'h10000));
    csr_w(A_T, 32'(c0.T));
    csr_w(A_HEAD, {8'd0, 8'(kvmul), 8'(nh), 8'd0});
    csr_w(A_POS, 32'd0); csr_w(A_KVH, {16'd0, 8'(nkv), 8'd0});
    expect_err(0, 2, "op 0");
    expect_err(3, 2, "op 3");
    expect_err(15, 2, "op 15");
    if (KV_SRC == 1) expect_err(2, 2, "KVW with DDR KV");
    // BAD_DESC, one reason each (restored after)
    csr_w(A_T, 0); expect_err(1, 4, "T 0"); csr_w(A_T, 32'(TMAX + 1)); expect_err(1, 4, "T > TMAX");
    csr_w(A_T, 32'(c0.T));
    csr_w(A_HS, 0); expect_err(1, 4, "hs 0"); csr_w(A_HS, 12); expect_err(1, 4, "hs 12");
    csr_w(A_HS, 4); expect_err(1, 4, "hs 4"); if (KV_SRC == 0) expect_err(2, 4, "KVW hs 4");
    csr_w(A_HS, HS_MAX + 8); expect_err(1, 4, "hs > HS_MAX"); csr_w(A_HS, 32'(c0.hs));
    csr_w(A_FMT, {15'd0, 1'b0, 3'd0, 5'd8, 3'd0, 5'd10}); expect_err(1, 4, "kb 10");
    csr_w(A_FMT, {15'd0, 1'b0, 3'd0, 5'd9, 3'd0, 5'd12}); expect_err(1, 4, "vb 9");
    if (KV_SRC == 0) begin
      csr_w(A_FMT, {15'd0, 1'b0, 3'd0, 5'd8, 3'd0, 5'd16}); expect_err(1, 4, "kb 16 > KW");
      csr_w(A_FMT, {15'd0, 1'b0, 3'd0, 5'd16, 3'd0, 5'd12}); expect_err(1, 4, "vb 16 > VW");
    end
    csr_w(A_FMT, {15'd0, 1'b0, 3'd0, 5'(c0.vb), 3'd0, 5'(c0.kb)});
    csr_w(A_HEAD, {8'd0, 8'(kvmul), 8'd0, 8'd0}); expect_err(1, 4, "NHEAD 0");
    csr_w(A_HEAD, {8'd0, 8'd0, 8'(nh), 8'd0}); expect_err(1, 4, "KVMUL 0");
    csr_w(A_HEAD, {8'd0, 8'(kvmul), 8'(nh), 8'd255}); expect_err(1, 4, "HEAD0 + NHEAD > 256");
    if (KV_SRC == 0) begin
      csr_w(A_HEAD, {8'd0, 8'(kvmul), 8'(nh + kvmul), 8'd0}); expect_err(1, 4, "kv head >= NKV");
      csr_w(A_HEAD, {8'd0, 8'(kvmul), 8'(nh), 8'd0});
      csr_w(A_LAYER, NL); expect_err(1, 4, "LAYER >= NL"); expect_err(2, 4, "KVW LAYER >= NL");
      csr_w(A_LAYER, 32'(l));
      csr_w(A_POS, TMAX); expect_err(2, 4, "KVW POS >= TMAX"); csr_w(A_POS, 0);
      csr_w(A_KVH, {16'd0, 8'(nkv), 8'd1}); expect_err(2, 4, "KVW KVH0 + NKVH > NKV");
      csr_w(A_KVH, {16'd0, 8'd0, 8'd0}); expect_err(2, 4, "KVW NKVH 0");
      csr_w(A_KVH, {16'd0, 8'(nkv), 8'd0});
      csr_w(A_SEQ, 0); expect_err(2, 4, "KVW POS >= SEQ"); csr_w(A_SEQ, 32'(seq));
      csr_w(A_KA, 32'hFFFF_FFF8); expect_err(2, 4, "KVW K range"); csr_w(A_KA, 32'(KC));
    end else begin
      csr_w(A_HEAD, {8'd0, 8'(kvmul), 8'(nh), 8'd0});
      csr_w(A_SEQ, 32'(c0.T - 1)); expect_err(1, 4, "T > SEQ"); csr_w(A_SEQ, 32'(seq));
      csr_w(A_KA, 32'hFFFF_FF00); expect_err(1, 4, "K range"); csr_w(A_KA, 32'(slot_a(KC, l, 0, 0, c0.hs * (c0.kb > 8 ? 2 : 1))));
      csr_w(A_VSA, 32'hFFFF_FF00); expect_err(1, 4, "VS range"); csr_w(A_VSA, 32'(slot_a(VCS, l, 0, 0, 8)));
    end
    csr_w(A_HEAD, {8'd0, 8'(kvmul), 8'(nh), 8'd0});
    csr_w(A_QA, 32'hFFFF_FFF0); expect_err(1, 4, "Q range"); csr_w(A_QA, 32'(QB0));
    csr_w(A_OA, 32'hFFFF_FFF0); expect_err(1, 4, "O range"); csr_w(A_OA, 32'(obase));
    csr_w(A_FMT, {15'd0, 1'b1, 3'd0, 5'(c0.vb), 3'd0, 5'(c0.kb)});
    csr_w(A_PA, 32'hFFFF_FFF0); expect_err(1, 4, "P range (p_en)"); csr_w(A_PA, 32'(obase + 64'h10000));
    csr_w(A_FMT, {15'd0, 1'b0, 3'd0, 5'(c0.vb), 3'd0, 5'(c0.kb)});
    // MISALIGN, and both together
    csr_w(A_QA, 32'(QB0 + 4)); expect_err(1, 8, "Q misaligned"); csr_w(A_QA, 32'(QB0));
    csr_w(A_OA, 32'(obase + 2)); expect_err(1, 8, "O misaligned"); csr_w(A_OA, 32'(obase));
    if (KV_SRC == 1) begin csr_w(A_KSA, 32'(slot_a(KCS, l, 0, 0, 8) + 4)); expect_err(1, 8, "KS misaligned"); end
    else begin csr_w(A_KSA, 32'(slot_a(KCS, l, 0, 0, 8) + 4)); expect_err(2, 8, "KVW KS misaligned"); end
    csr_w(A_KSA, 32'(slot_a(KCS, l, 0, 0, 8)));
    csr_w(A_T, 0); csr_w(A_QA, 32'(QB0 + 4)); expect_err(1, 12, "BAD_DESC and MISALIGN");
    csr_w(A_T, 32'(c0.T)); csr_w(A_QA, 32'(QB0));
    // START_BUSY: start again during a run, then a correct result
    set_kv_desc(c0, l);
    if (KV_SRC == 0) for (int t = last_w[l] + 1; t < c0.T; t++) kvw_op(g, l, t);
    if (KV_SRC == 0) last_w[l] = c0.T > last_w[l] + 1 ? c0.T - 1 : last_w[l];
    else for (int j = 0; j < nkv; j++) for (int t = 0; t < c0.T; t++) put_kv(g[j * kvmul], l, j, t);
    err_allow = 1;
    fork
      attn_op(g, l, 0, nh, 1, cy);
      begin
        wait (dut.busy === 1'b1);
        repeat (5) @(posedge clk);
        bfm.write0(ADDR_W'(A_CTRL), 32'h11);   // while busy: START_BUSY (cleared by run_op's W1C)
      end
    join
    err_allow = 0;
    if (last_err !== 32'h1) c_err.fail($sformatf("START_BUSY: ERR 0x%0h exp 0x1", last_err));
    else c_err.pass();
    // RD_RESP on the q record reads, WR_RESP on the o writes; the op still completes
    for (int p = 0; p < H_PAR; p++)
      case (p)
        0: g_rmem[0].mem.inj_rd_err(QB0, QB0 + 64'h10000, 2'b10);
        default: g_rmem[H_PAR > 1 ? 1 : 0].mem.inj_rd_err(QB0, QB0 + 64'h10000, 2'b11);
      endcase
    wmem.inj_wr_err(obase, obase + 64'h100000, 2'b11);
    put_q(g, QB0);
    begin
      logic [31:0] e2, c2, st;
      csr_w(A_QA, 32'(QB0)); csr_w(A_OA, 32'(obase)); csr_w(A_T, 32'(c0.T));
      csr_w(A_HEAD, {8'd0, 8'(kvmul), 8'(nh), 8'd0});
      csr_w(A_CTRL, 32'h11);
      do csr_r(A_STATUS, st); while (st[1] !== 1'b1);
      csr_r(A_ERR, e2);
      if (e2 !== 32'h30) c_err.fail($sformatf("RD_RESP / WR_RESP: ERR 0x%0h exp 0x30", e2));
      else c_err.pass();
      csr_w(A_ERR, e2);
      csr_r(A_ERR, e2);
      if (e2 !== 0) c_err.fail("ERR not cleared by W1C"); else c_err.pass();
    end
    for (int p = 0; p < H_PAR; p++)
      case (p)
        0: g_rmem[0].mem.inj_clear();
        default: g_rmem[H_PAR > 1 ? 1 : 0].mem.inj_clear();
      endcase
    wmem.inj_clear();
    obase += 64'h200000;
    // recovery: a correct op
    attn_op(g, l, 0, nh, 1, cy);
  endtask

  // random register traffic (no start)
  task automatic rnd_regs();
    int regs[$] = '{A_ID, A_CONFIG, A_STATUS, A_CYCLES, A_RDST, A_WRST, A_OPS, A_CFG2, A_CFG3, A_QA,
                    A_OA, A_PA, A_KA, A_VA, A_KSA, A_VSA, A_T, A_HS, A_FMT, A_HEAD, A_LAYER, A_SEQ,
                    A_POS, A_KVH, 'h2C, 'h7C, 'h80, 'hFC};
    logic [31:0] d;
    for (int i = 0; i < 20; i++) begin
      int a = regs[$urandom_range(regs.size() - 1)];
      if ($urandom_range(1)) csr_r(a | $urandom_range(3), d);
      else if (a >= A_QA) csr_w(a, $urandom());
    end
  endtask

  initial begin
    automatic int unsigned seed;
    automatic int maxgrp = 1 << 30, maxpos = 1 << 30, errm = 0, rnd = 0, maxd = 0, ngrp = 0;
    automatic string vec = "";
    automatic att_case g[$];
    automatic int cur_T = -1, cur_l = 0;
    automatic logic [31:0] d;
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("VEC=%s", vec));
    void'($value$plusargs("NH=%d", nh));
    void'($value$plusargs("NKV=%d", nkv));
    void'($value$plusargs("SEQ=%d", seq));
    void'($value$plusargs("MAXGRP=%d", maxgrp));
    void'($value$plusargs("MAXPOS=%d", maxpos));
    void'($value$plusargs("MSTALL=%d", mstall));
    void'($value$plusargs("WBLK=%d", wblk));
    void'($value$plusargs("ERR=%d", errm));
    void'($value$plusargs("RND=%d", rnd));
    void'($value$plusargs("MAXD=%d", maxd));
    void'($value$plusargs("SPLIT=%d", split));
    void'($value$plusargs("PEN=%d", pen_mode));
    kvmul = nh / nkv;
    $display("tb_attn_top: H_PAR %0d KV_SRC %0d HS_MAX %0d NH %0d NKV %0d SEQ %0d seed %0d", H_PAR, KV_SRC,
             HS_MAX, nh, nkv, seq, seed);
    foreach (last_w[l]) last_w[l] = -1;
    bfm.maxd = maxd;
    if (mstall) begin
      wmem.cfg_stall(0, 20, 20, 0, 20);
      wmem.cfg_lat(1, 1, 1, 12);
      for (int p = 0; p < H_PAR; p++)
        case (p)
          0: begin g_rmem[0].mem.cfg_stall(20, 0, 0, 25, 0); g_rmem[0].mem.cfg_lat(1, 16, 1, 1); end
          default: begin
            g_rmem[H_PAR > 1 ? 1 : 0].mem.cfg_stall(20, 0, 0, 25, 0);
            g_rmem[H_PAR > 1 ? 1 : 0].mem.cfg_lat(1, 16, 1, 1);
          end
        endcase
    end
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);
    csr_r(A_ID, d);
    if (kd_rec_open({vec, "/attn2.bin"}) != 0) $fatal(1, "tb_attn_top: no record file %s", vec);
    // groups of nh records = one (position, layer)
    forever begin
      automatic att_case c = new();
      automatic int rc;
      if (kd_rec_next() <= 0) break;
      rc = c.load_rec();
      if (rc != 0) begin c_rec.fail($sformatf("record %0d load %0d", kd_rec_index(), rc)); continue; end
      c_rec.pass();
      g.push_back(c);
      if (g.size() == nh) begin
        if (g[0].T > maxpos) break;
        if (g[0].T != cur_T) begin cur_T = g[0].T; cur_l = 0; end
        if (errm && ngrp == 1) err_paths(g, cur_l);
        else do_group(g, cur_l);
        if (rnd) rnd_regs();
        cur_l++;
        ngrp++;
        g.delete();
        if (ngrp >= maxgrp) break;
      end
    end
    void'(kd_rec_close());
    repeat (50) @(posedge clk);
    $display("tb_attn_top: %0d groups, %0d ops, %0d starts; write buffer full %0d, packer held %0d, credit hold %0d cycles; packer valid %0d cycles, %0d blocks",
             ngrp, n_ops, n_starts, n_wfull, n_pkhold, n_credit, n_pkv, n_blk);
    if (kvw_n > 0) $display("tb_attn_top: KVW ops %0d, CYCLES sum %0d (%0d heads each)", kvw_n, kvw_cyc, nkv);
    foreach (tok_cyc[T]) $display("tb_attn_top: ATTN CYCLES sum over layers at T %0d: %0d", T, tok_cyc[T]);
    $display("tb_attn_top: RD_STALL sum %0d, WR_STALL sum %0d", n_rdst, n_wrst);
    // memory stalls: some core must wait for a KV beat (RD_STALL); write blocks: WR_STALL
    if (mstall) begin
      if (n_rdst > 0) c_stl.pass(); else c_stl.fail("memory stall run: RD_STALL 0 in every op");
    end
    if (wblk) begin
      if (n_wrst > 0) c_stl.pass(); else c_stl.fail("write block run: WR_STALL 0 in every op");
    end
    if (wblk) begin
      if (n_wfull > 0 && n_pkhold > 0 && n_credit > 0) c_cov.pass();
      else c_cov.fail($sformatf("blocks did not reach the limits: wfull %0d pk %0d credit %0d", n_wfull, n_pkhold, n_credit));
    end
    if (KV_SRC == 0 && split && nkv > 1) begin
      $display("tb_attn_top: KVW split into two ops (second with KVH0 > 0) %0d times", kvw_split);
      if (kvw_split > 0) c_cov.pass(); else c_cov.fail("KVW with KVH0 > 0 never run");
    end
    wmem.check_idle();
    begin
      automatic tb_checker_q l = '{c_o, c_guard, c_err, c_csr, c_rd, c_rec};
      if (c_p.n_checks > 0) l.push_back(c_p);
      if (wblk || (KV_SRC == 0 && split && nkv > 1)) l.push_back(c_cov);
      if (c_stl.n_checks > 0) l.push_back(c_stl);
      void'(tb_final_report(l));
    end
    $finish;
  end

endmodule
