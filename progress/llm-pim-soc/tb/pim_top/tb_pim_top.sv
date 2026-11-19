// tb_pim_top: GEMV PIM IP (rtl/l3/pim_top.sv) driven over AXI4-Lite by tb/common/axil_bfm.sv in the
// order of the PS driver (docs/spec/pim.md "host sequence"), AXI master on tb/common/axi_mem_slave.sv.
//
// Expected values (none taken from the RTL):
//   bank RAM   after the LDW run of the 36 260K matrices: every bank == model/build/vec/pim/
//              bank<b>.hex (bimg_pack) for the used 4,072 words, words above unchanged (prefill).
//   y          K_GEMV records (recorded y), synthetic matrices: kd_bank_syn (bank_pack BANK_ROW +
//              bank_gemv). y region of every MACAB == y, 16 guard bytes on both sides unchanged.
//   counters   ST_WRGB / ST_MAC / ST_RDMAC / N_LDW / N_WRGB / N_MACAB / OPS == the sums of bank_stat_t
//              of the same calls (kd_rec_bank / kd_bank_syn; wrgb counted once per WRGB command).
//   CSR model  a register model written from the spec steps every cycle with the accesses taken
//              from the AXI4-Lite bus (performed in the cycle before the B / R response) and the
//              observed events; it predicts every read word, the start acceptance, the push
//              acceptance (its own FIFO level; the popped word must equal its queue front) and the
//              run end e: the first busy cycle with an empty FIFO (FLUSH), or with an empty FIFO and
//              every popped command finished (LDW: last row record beat + zero-fill words + 1,
//              WRGB: last x beat + 1, MACAB: its last B response + 1). CYCLES = e - s.
//   bus        every AR inside the popped LDW / WRGB source range, every AW inside its MACAB's y
//              region, R beats per command, W beats per MACAB = ceil(rows/2).
// Scenarios: +CSR=1 reset values / read-back / read-only / unused; +VEC records: LDW run, then per
// position +MODE=0 one run per layer (WRGB / MACAB in the arch.md 3.3 order) and one for cls,
// +MODE=1 the whole token in one run with the FIFO filled to CMD_DEPTH and refilled while running,
// +MODE=2 WRGB + MACAB per record (one run each); +MAXPOS; +SYN=k synthetic groups; +ERR=1 every ERR
// cause, FIFO overflow, FLUSH and SLVERR recovery; +COLL=1 CTRL in the done cycle and W1C vs set;
// +WBLK / +RBLK long write / read blocks (limits: write buffer full, y credit, read outstanding).
// +CYC=1 (PROF=0): CYCLES of every single-MACAB run == the formula in pim.md.
// Plusargs: +SEED +PROF +MAXD +VEC +MAXPOS +MODE +SYN +ERR +COLL +CSR +CYC +WBLK +RBLK
`timescale 1ns / 1ps
module tb_pim_top #(
  parameter int CMD_DEPTH  = 32,
  parameter int DOT_PIPE   = 2,
  parameter int SCALE_PIPE = 3,
  parameter int Y_DEPTH    = 32,
  parameter int MAX_BURST  = 16,
  parameter int OUTS       = 4
);
  import tb_util_pkg::*;
  import kdpi_pkg::*;
  import llm_pkg::*;

  localparam int NB = 4, LB = 16, DEPTH = 4096, NMAX = 1024, IDW = 1, AW_L = 12, WW = 8 * LB + 16;
  localparam int L_BANK = 3 + DOT_PIPE, L_S = SCALE_PIPE;
  localparam longint unsigned W_BASE = 64'h1000_0000, SW_BASE = 64'h0400_0000,
                              X_BASE = 64'h2000_0000, Y_BASE = 64'h3000_0000;
  localparam int A_ID = 'h00, A_CONFIG = 'h04, A_CTRL = 'h08, A_STATUS = 'h0C, A_ERR = 'h10,
                 A_CYCLES = 'h14, A_RDSTALL = 'h18, A_WRSTALL = 'h1C, A_OPS = 'h20, A_CONFIG2 = 'h24,
                 A_CMD0 = 'h40, A_CMD1 = 'h44, A_CMD2 = 'h48, A_CMD3 = 'h4C, A_PUSH = 'h50,
                 A_STWRGB = 'h60, A_STMAC = 'h64, A_STRDMAC = 'h68, A_NLDW = 'h6C, A_NWRGB = 'h70,
                 A_NMACAB = 'h74;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  // ---------------- AXI-Lite ----------------
  logic [AW_L-1:0] awaddr, araddr;
  logic [2:0] awprot, arprot;
  logic awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;
  logic [31:0] wdata, rdata;
  logic [3:0] wstrb;
  logic [1:0] bresp, rresp;

  axil_bfm #(.ADDR_W(AW_L)) bfm (.clk, .rst_n, .awaddr, .awprot, .awvalid, .awready, .wdata,
    .wstrb, .wvalid, .wready, .bresp, .bvalid, .bready, .araddr, .arprot, .arvalid, .arready,
    .rdata, .rresp, .rvalid, .rready);

  // ---------------- AXI master ----------------
  logic [IDW-1:0] m_awid, m_bid, m_arid, m_rid;
  logic [31:0] m_awaddr, m_araddr;
  logic [7:0] m_awlen, m_wstrb, m_arlen;
  logic [2:0] m_awsize, m_awprot, m_arsize, m_arprot;
  logic [1:0] m_awburst, m_bresp, m_arburst, m_rresp;
  logic [3:0] m_awcache, m_awqos, m_arcache, m_arqos;
  logic m_awlock, m_awvalid, m_awready, m_wlast, m_wvalid, m_wready, m_bvalid, m_bready;
  logic m_arlock, m_arvalid, m_arready, m_rlast, m_rvalid, m_rready;
  logic [63:0] m_wdata, m_rdata;

  pim_top #(.NB(NB), .LB(LB), .DEPTH(DEPTH), .NMAX(NMAX), .CMD_DEPTH(CMD_DEPTH), .DOT_PIPE(DOT_PIPE),
            .SCALE_PIPE(SCALE_PIPE), .Y_DEPTH(Y_DEPTH), .MAX_BURST(MAX_BURST), .OUTS(OUTS), .IDW(IDW),
            .FCLK_MHZ(100), .ADDR_W(AW_L)) dut (
    .clk, .rst_n,
    .s_axi_awaddr_i(awaddr), .s_axi_awprot_i(awprot), .s_axi_awvalid_i(awvalid), .s_axi_awready_o(awready),
    .s_axi_wdata_i(wdata), .s_axi_wstrb_i(wstrb), .s_axi_wvalid_i(wvalid), .s_axi_wready_o(wready),
    .s_axi_bresp_o(bresp), .s_axi_bvalid_o(bvalid), .s_axi_bready_i(bready),
    .s_axi_araddr_i(araddr), .s_axi_arprot_i(arprot), .s_axi_arvalid_i(arvalid), .s_axi_arready_o(arready),
    .s_axi_rdata_o(rdata), .s_axi_rresp_o(rresp), .s_axi_rvalid_o(rvalid), .s_axi_rready_i(rready),
    .m_axi_awid_o(m_awid), .m_axi_awaddr_o(m_awaddr), .m_axi_awlen_o(m_awlen), .m_axi_awsize_o(m_awsize),
    .m_axi_awburst_o(m_awburst), .m_axi_awlock_o(m_awlock), .m_axi_awcache_o(m_awcache),
    .m_axi_awprot_o(m_awprot), .m_axi_awqos_o(m_awqos), .m_axi_awvalid_o(m_awvalid), .m_axi_awready_i(m_awready),
    .m_axi_wdata_o(m_wdata), .m_axi_wstrb_o(m_wstrb), .m_axi_wlast_o(m_wlast), .m_axi_wvalid_o(m_wvalid),
    .m_axi_wready_i(m_wready), .m_axi_bid_i(m_bid), .m_axi_bresp_i(m_bresp), .m_axi_bvalid_i(m_bvalid),
    .m_axi_bready_o(m_bready),
    .m_axi_arid_o(m_arid), .m_axi_araddr_o(m_araddr), .m_axi_arlen_o(m_arlen), .m_axi_arsize_o(m_arsize),
    .m_axi_arburst_o(m_arburst), .m_axi_arlock_o(m_arlock), .m_axi_arcache_o(m_arcache),
    .m_axi_arprot_o(m_arprot), .m_axi_arqos_o(m_arqos), .m_axi_arvalid_o(m_arvalid), .m_axi_arready_i(m_arready),
    .m_axi_rid_i(m_rid), .m_axi_rdata_i(m_rdata), .m_axi_rresp_i(m_rresp), .m_axi_rlast_i(m_rlast),
    .m_axi_rvalid_i(m_rvalid), .m_axi_rready_o(m_rready));

  axi_mem_slave #(.DW(64), .AW(32), .IDW(IDW), .MAX_LEN(MAX_BURST - 1), .MAX_OUTS(16), .NAME("mem0")) mem0 (
    .clk, .rst_n,
    .awid_i(m_awid), .awaddr_i(m_awaddr), .awlen_i(m_awlen), .awsize_i(m_awsize),
    .awburst_i(m_awburst), .awvalid_i(m_awvalid), .awready_o(m_awready),
    .wdata_i(m_wdata), .wstrb_i(m_wstrb), .wlast_i(m_wlast), .wvalid_i(m_wvalid), .wready_o(m_wready),
    .bid_o(m_bid), .bresp_o(m_bresp), .bvalid_o(m_bvalid), .bready_i(m_bready),
    .arid_i(m_arid), .araddr_i(m_araddr), .arlen_i(m_arlen), .arsize_i(m_arsize),
    .arburst_i(m_arburst), .arvalid_i(m_arvalid), .arready_o(m_arready),
    .rid_o(m_rid), .rdata_o(m_rdata), .rresp_o(m_rresp), .rlast_o(m_rlast),
    .rvalid_o(m_rvalid), .rready_i(m_rready));

  // ---------------- probes ----------------
  wire pr_pop = dut.fifo_valid && dut.fifo_ready;
  wire [127:0] pr_pop_d = dut.fifo_data;
  wire [15:0] pr_level = 16'(dut.fifo_level);
  wire pr_start = dut.start, pr_done = dut.run_done;
  wire pr_cdr = dut.d_ready, pr_cdv = dut.d_valid;
  wire pr_wiv = dut.u_wr.in_valid_i, pr_wir = dut.u_wr.in_ready_o;
  wire pr_ev_mac = dut.ev_mac, pr_ev_wrgb = dut.ev_wrgb, pr_ev_rdmac = dut.ev_rdmac;
  wire pr_dn_ldw = dut.done_ldw, pr_dn_wrgb = dut.done_wrgb, pr_dn_mac = dut.done_mac;
  wire pr_cred = int'(dut.u_core.u_ctrl.state_q) == 4 && dut.u_core.u_ctrl.m_first &&
                 32'(dut.u_core.u_ctrl.yres_q) + 32'(dut.u_core.u_ctrl.m_nv) > Y_DEPTH;
  wire pr_routs = 32'(dut.u_rd.outs_q) == OUTS;

  tb_checker c_y = new("y"), c_mem = new("memory"), c_cyc = new("cycles"), c_model = new("csr_model"),
             c_csr = new("csr"), c_err = new("err"), c_img = new("bank_image"), c_cnt = new("counters"),
             c_reach = new("limits");

  // ---------------- command description ----------------
  typedef struct {
    int op, rows, n, base, xm, we, xe, fo;
    longint unsigned addr;
    int ey[$];                  // MACAB: expected y
    longint st[3];              // bank_stat of this command (wrgb, mac, rdmac)
    string tag;
  } cmd_t;

  function automatic logic [127:0] cmd_word(cmd_t c);
    return {8'd0, 8'(c.fo), 8'(c.xe), 8'(c.we), 32'(c.addr), 15'(c.base), 17'(c.xm),
            16'(c.rows), 12'(c.n), 4'(c.op)};
  endfunction

  // ---------------- CSR reference model ----------------
  logic [31:0] m_cmd[4];
  bit          m_busy, m_done, m_flush;
  logic [7:0]  m_err;
  logic [31:0] m_cyc, m_rdst, m_wrst, m_ops, m_stw, m_stm, m_str, m_nl, m_nx, m_nm;
  int          m_level;
  logic [127:0] m_fifo[$];      // model command FIFO (words)
  bit          model_on = 0;

  function automatic void model_reset();
    m_cmd = '{0, 0, 0, 0};
    m_busy = 0; m_done = 0; m_flush = 0; m_err = 0; m_level = 0;
    m_cyc = 0; m_rdst = 0; m_wrst = 0; m_ops = 0; m_stw = 0; m_stm = 0; m_str = 0;
    m_nl = 0; m_nx = 0; m_nm = 0;
    m_fifo.delete();
  endfunction

  function automatic logic [31:0] model_read(int a);
    if (a >= 256) return 0;
    case (a & ~3)
      A_ID:      return 32'h5049_0001;
      A_CONFIG:  return {16'(NMAX), 4'd4, 4'(NB), 8'd100};
      A_STATUS:  return {8'd0, 16'(m_level), 5'd0, m_err != 0, m_done, m_busy};
      A_ERR:     return 32'(m_err);
      A_CYCLES:  return m_cyc;
      A_RDSTALL: return m_rdst;
      A_WRSTALL: return m_wrst;
      A_OPS:     return m_ops;
      A_CONFIG2: return {16'(CMD_DEPTH), 16'(DEPTH)};
      A_CMD0:    return m_cmd[0];
      A_CMD1:    return m_cmd[1];
      A_CMD2:    return m_cmd[2];
      A_CMD3:    return m_cmd[3];
      A_STWRGB:  return m_stw;
      A_STMAC:   return m_stm;
      A_STRDMAC: return m_str;
      A_NLDW:    return m_nl;
      A_NWRGB:   return m_nx;
      A_NMACAB:  return m_nm;
      default:   return 0;
    endcase
  endfunction

  function automatic int f_op();   return m_cmd[0][3:0]; endfunction
  function automatic int f_n();    return m_cmd[0][15:4]; endfunction
  function automatic int f_rows(); return m_cmd[0][31:16]; endfunction
  function automatic int f_base(); return m_cmd[1][31:17]; endfunction
  function automatic bit m_desc_ok();
    longint unsigned len;
    longint used = longint'((f_rows() + NB - 1) / NB) * ((f_n() + 15) / 16);
    case (f_op())
      1: len = longint'(f_rows()) * 8 * (1 + (f_n() + 7) / 8);
      2: len = longint'(f_n());
      default: len = 4 * longint'(f_rows());
    endcase
    if (f_n() == 0 || f_n() > NMAX) return 0;
    if (f_op() != 2 && (f_rows() == 0 || longint'(f_base()) + used > DEPTH)) return 0;
    return longint'(m_cmd[2]) + len <= 64'h1_0000_0000;
  endfunction

  typedef struct {
    bit rd_err, wr_err, rd_stall, wr_stall, done, pop;
    bit ev_mac, ev_wrgb, ev_rdmac, dn_ldw, dn_wrgb, dn_mac, dut_start, dut_done;
    logic [127:0] pop_d;
    int level;
  } ev_t;
  ev_t ev_prev;

  longint cl_s = -1, cl_e = -1, n_starts = 0, n_dones = 0, n_push = 0;
  longint t_rdst = 0, t_wrst = 0;
  longint n_coll_c0 = 0, n_coll_c1 = 0, n_coll_err = 0, n_ovf = 0;

  function automatic void model_step(longint k, ev_t ev, bit pw, int pwa, logic [31:0] pwd,
                                     bit prd, int pra, logic [31:0] prdata);
    bit ctrl, start_req, idle, op_ok, start, preq, isop, pok;
    logic [7:0] set, clr;
    if (prd) begin
      logic [31:0] e = model_read(pra);
      if (prdata !== e) c_model.fail($sformatf("read 0x%03h performed in cycle %0d: got %h, model %h", pra, k, prdata, e));
      else c_model.pass();
    end
    if (ev.level != m_level) c_model.fail($sformatf("cycle %0d: FIFO level %0d, model %0d", k, ev.level, m_level));
    ctrl      = pw && pwa < 256 && (pwa & ~3) == A_CTRL;
    start_req = ctrl && pwd[0];
    idle      = !m_busy || ev.done;
    op_ok     = pwd[7:4] == 1 || pwd[7:4] == 2;
    start     = start_req && idle && op_ok;
    if (start !== ev.dut_start) c_model.fail($sformatf("cycle %0d: DUT start %b, model %b", k, ev.dut_start, start));
    if (ev.done !== ev.dut_done) c_model.fail($sformatf("cycle %0d: DUT done %b, TB done %b", k, ev.dut_done, ev.done));
    else if (ev.done) c_model.pass();
    if (ctrl && ev.done) begin if (pwd[0]) n_coll_c1++; else n_coll_c0++; end
    preq = pw && pwa < 256 && (pwa & ~3) == A_PUSH;
    isop = f_op() >= 1 && f_op() <= 3;
    pok  = preq && isop && m_desc_ok() && m_cmd[2][2:0] == 0 && m_level < CMD_DEPTH;
    set = '0;
    set[0] = start_req && !idle;
    set[1] = start_req && !op_ok;
    set[2] = preq && !isop;
    set[3] = preq && isop && !m_desc_ok();
    set[4] = preq && isop && m_cmd[2][2:0] != 0;
    set[5] = ev.rd_err;
    set[6] = ev.wr_err;
    set[7] = preq && isop && m_desc_ok() && m_cmd[2][2:0] == 0 && m_level >= CMD_DEPTH;
    if (set[7]) n_ovf++;
    clr = (pw && pwa < 256 && (pwa & ~3) == A_ERR) ? pwd[7:0] : '0;
    if ((set & clr) != 0) n_coll_err++;
    // popped command == model FIFO front
    if (ev.pop) begin
      if (m_fifo.size() == 0) c_model.fail($sformatf("cycle %0d: pop from an empty model FIFO", k));
      else begin
        logic [127:0] f = m_fifo.pop_front();
        if (f !== ev.pop_d) c_model.fail($sformatf("cycle %0d: popped %h, model %h", k, ev.pop_d, f));
        else c_model.pass();
      end
    end
    // next state
    if (ctrl && idle && !(pwd[0] && !op_ok)) m_done = 0;
    else if (ev.done) m_done = 1;
    m_err = (m_err & ~clr) | set;
    if (start) begin m_cyc = 0; m_rdst = 0; m_wrst = 0; end
    else if (m_busy) begin
      m_cyc++;
      if (ev.rd_stall) m_rdst++;
      if (ev.wr_stall) m_wrst++;
    end
    if (ev.dn_ldw || ev.dn_wrgb || ev.dn_mac) m_ops++;
    m_stw += ev.ev_wrgb; m_stm += ev.ev_mac; m_str += ev.ev_rdmac;
    m_nl += ev.dn_ldw; m_nx += ev.dn_wrgb; m_nm += ev.dn_mac;
    if (ev.done) begin n_dones++; cl_e = k; end
    if (start) begin m_busy = 1; m_flush = pwd[7:4] == 2; cl_s = k; cl_e = -1; n_starts++; t_rdst = 0; t_wrst = 0; end
    else if (ev.done) m_busy = 0;
    if (pok) begin m_fifo.push_back({m_cmd[3], m_cmd[2], m_cmd[1], m_cmd[0]}); n_push++; end
    m_level = m_level + int'(pok) - int'(ev.pop);
    if (pw && pwa < 256 && (pwa & ~3) >= A_CMD0 && (pwa & ~3) <= A_CMD3) m_cmd[((pwa & ~3) - A_CMD0) / 4] = pwd;
  endfunction

  // ---------------- run-end tracking: popped commands ----------------
  typedef struct {
    int op, rows, n;
    longint unsigned lo, hi;    // source (LDW / WRGB) or y (MACAB) byte range
    int beats_left;             // R beats (LDW / WRGB) or W beats (MACAB) still to come
    int aw_open;                // MACAB: AWs whose B has not come
    int fill;                   // LDW zero-fill words
    longint fin;                // first cycle in which the controller part is finished (-1 open)
  } oc_t;
  oc_t oc[$];                   // popped, not finished (in pop order)
  int  ord_rd[$], ord_aw[$];    // indexes (ids) of commands owning the next R beats / AW bursts
  int  awq_id[$];               // AW in flight: command id (B in AW order)
  int  oc_id[$];                // id of each oc entry
  int  next_id = 0;
  int  wb_left[int];            // MACAB id -> W beats still to come
  int  aw_beats_left[int];      // MACAB id -> beats not yet covered by an AW

  function automatic int oc_find(int id);
    foreach (oc_id[i]) if (oc_id[i] == id) return i;
    return -1;
  endfunction

  // ---------------- monitor (negedge) ----------------
  int  aw_q[$], ar_q[$];
  logic [31:0] w_q[$];
  bit  p_bv = 0, p_bhs = 0, p_rv = 0, p_rhs = 0;
  bit  pw_v, pr_v;
  int  pw_a, pr_a;
  logic [31:0] pw_d, pr_d;
  longint mcyc = 0;
  longint n_wfull = 0, n_cred = 0, n_routs = 0;
  int     rbeats_cmd[int];      // R beats per command id (counted)

  always @(negedge clk) begin
    if (!rst_n) begin
      model_reset();
      model_on = 1'b0;
      p_bv = 0; p_bhs = 0; p_rv = 0; p_rhs = 0;
    end else begin
      mcyc = bfm.cyc;
      pw_v = 0; pr_v = 0;
      if (bvalid && (!p_bv || p_bhs)) begin
        pw_v = 1;
        if (aw_q.size() == 0 || w_q.size() == 0) c_model.fail("B without a recorded AW / W");
        else begin pw_a = aw_q.pop_front(); pw_d = w_q.pop_front(); end
      end
      if (rvalid && (!p_rv || p_rhs)) begin
        pr_v = 1;
        if (ar_q.size() == 0) c_model.fail("R without a recorded AR");
        else begin pr_a = ar_q.pop_front(); pr_d = rdata; end
      end
      if (model_on) model_step(mcyc - 1, ev_prev, pw_v, pw_a, pw_d, pr_v, pr_a, pr_d);
      else if (pw_v || pr_v) c_model.fail("access performed in the first cycle after reset");
      model_on = 1'b1;
      p_bv = bvalid; p_bhs = bvalid && bready;
      p_rv = rvalid; p_rhs = rvalid && rready;
      if (awvalid && awready) aw_q.push_back(int'(awaddr));
      if (wvalid && wready) w_q.push_back(wdata);
      if (arvalid && arready) ar_q.push_back(int'(araddr));

      // ---- events of cycle mcyc ----
      begin
        automatic ev_t ev;
        automatic bit all_fin = 1;
        ev = '{default: 0};
        // popped command (enters the tracking list; its finish is still open)
        if (pr_pop) begin
          automatic oc_t o;
          automatic logic [127:0] d = pr_pop_d;
          automatic int id = next_id++;
          o.op = d[3:0]; o.n = d[15:4]; o.rows = d[31:16]; o.lo = d[95:64]; o.fin = -1;
          o.aw_open = 0; o.fill = 0;
          case (o.op)
            1: begin
              o.hi = o.lo + longint'(o.rows) * 8 * (1 + (o.n + 7) / 8);
              o.beats_left = o.rows * (1 + (o.n + 7) / 8);
              o.fill = ((o.rows + NB - 1) / NB * NB - o.rows) * ((o.n + 15) / 16);
              ord_rd.push_back(id);
            end
            2: begin
              o.hi = o.lo + o.n;
              o.beats_left = (o.n + 7) / 8;
              ord_rd.push_back(id);
            end
            default: begin
              o.hi = o.lo + 4 * o.rows;
              o.beats_left = (o.rows + 1) / 2;
              wb_left[id] = o.beats_left;
              aw_beats_left[id] = o.beats_left;
              ord_aw.push_back(id);
            end
          endcase
          if (!m_flush) begin oc.push_back(o); oc_id.push_back(id); end
          else begin
            // FLUSH: discarded, nothing of it may happen
            if (o.op == 3) begin void'(ord_aw.pop_back()); end else void'(ord_rd.pop_back());
          end
          ev.pop = 1;
          ev.pop_d = d;
        end
        // R beats
        if (m_rvalid && m_rready) begin
          if (m_rresp[1]) ev.rd_err = 1;
          if (ord_rd.size() == 0) c_mem.fail("R beat without a read command");
          else begin
            automatic int i = oc_find(ord_rd[0]);
            if (i < 0) c_mem.fail("R beat of an unknown command");
            else begin
              oc[i].beats_left--;
              if (oc[i].beats_left == 0) begin
                // the beat reaches the core one cycle later (axi_rd_eng R buffer), the controller is
                // idle the cycle after its last write (zero-fill words after the last beat)
                oc[i].fin = mcyc + 2 + oc[i].fill;
                void'(ord_rd.pop_front());
              end
            end
          end
        end
        // AR range
        if (m_arvalid && m_arready) begin
          automatic longint unsigned a = m_araddr, b = a + 8 * (longint'(m_arlen) + 1);
          automatic bit ok = 0;
          // the burst belongs to a not yet fully requested read command (in order)
          foreach (ord_rd[j]) begin
            automatic int i = oc_find(ord_rd[j]);
            if (i >= 0 && a >= oc[i].lo && b <= 8 * ((oc[i].hi + 7) / 8)) ok = 1;
          end
          if (!ok) c_mem.fail($sformatf("AR 0x%0h len %0d outside the open read commands", a, m_arlen));
          else c_mem.pass();
        end
        // AW / W / B
        if (m_awvalid && m_awready) begin
          automatic longint unsigned a = m_awaddr;
          automatic int bl = m_awlen + 1;
          if (ord_aw.size() == 0) c_mem.fail("AW without a MACAB");
          else begin
            automatic int id = ord_aw[0], i = oc_find(id);
            if (i < 0 || a < oc[i].lo || a + 8 * bl > 8 * ((oc[i].hi + 7) / 8))
              c_mem.fail($sformatf("AW 0x%0h len %0d outside its y region", a, m_awlen));
            else c_mem.pass();
            if (i >= 0) oc[i].aw_open++;
            awq_id.push_back(id);
            aw_beats_left[id] -= bl;
            if (aw_beats_left[id] <= 0) void'(ord_aw.pop_front());
          end
        end
        if (m_bvalid && m_bready) begin
          if (m_bresp[1]) ev.wr_err = 1;
          if (awq_id.size() == 0) c_mem.fail("B without an AW");
          else begin
            automatic int id = awq_id.pop_front(), i = oc_find(id);
            if (i >= 0) begin
              oc[i].aw_open--;
              if (oc[i].aw_open == 0 && aw_beats_left[id] <= 0) oc[i].fin = mcyc + 1;
            end
          end
        end
        // finished commands leave the list
        for (int i = oc.size() - 1; i >= 0; i--)
          if (oc[i].fin >= 0 && oc[i].fin <= mcyc) begin oc.delete(i); oc_id.delete(i); end
        // events
        if (pr_cdr && !pr_cdv) ev.rd_stall = 1;
        if (pr_wiv && !pr_wir) begin ev.wr_stall = 1; n_wfull++; end
        if (pr_cred) n_cred++;
        if (pr_routs) n_routs++;
        ev.ev_mac = pr_ev_mac; ev.ev_wrgb = pr_ev_wrgb; ev.ev_rdmac = pr_ev_rdmac;
        ev.dn_ldw = pr_dn_ldw; ev.dn_wrgb = pr_dn_wrgb; ev.dn_mac = pr_dn_mac;
        ev.level = pr_level;
        // run end (model level before this cycle's pop / push)
        ev.done = m_busy && m_level == 0 && (m_flush || oc.size() == 0);
        if (m_busy) begin
          if (ev.rd_stall) t_rdst++;
          if (ev.wr_stall) t_wrst++;
        end
        ev.dut_start = pr_start;
        ev.dut_done  = pr_done;
        if ($isunknown({pr_start, pr_done})) c_model.fail($sformatf("X on start / done at %0d", mcyc));
        ev_prev = ev;
      end
    end
  end

  // ---------------- CSR access helpers ----------------
  task automatic wr(int a, logic [31:0] d);
    bfm.write0(AW_L'(a), d);
  endtask
  task automatic rd(int a, output logic [31:0] d);
    bfm.read(AW_L'(a), d);
  endtask
  task automatic expect_reg(int a, logic [31:0] e, string what, tb_checker c);
    logic [31:0] d;
    rd(a, d);
    if (d !== e) c.fail($sformatf("%s: reg 0x%02h = %h, expected %h", what, a, d, e));
    else c.pass();
  endtask

  // ---------------- host-side command handling ----------------
  cmd_t   hq[$];                // pushed, not yet checked (in order)
  longint x_st[3] = '{0, 0, 0}, x_nl = 0, x_nx = 0, x_nm = 0;   // expected counters (sums)
  int     prof = 0, maxd = 0, cyc_mode = 0;
  longint last_cycles = 0;
  cmd_t   none_q[$];
  byte unsigned ypre[longint unsigned];

  task automatic push(cmd_t c);
    logic [127:0] w = cmd_word(c);
    wr(A_CMD0, w[31:0]);
    wr(A_CMD1, w[63:32]);
    wr(A_CMD2, w[95:64]);
    wr(A_CMD3, w[127:96]);
    wr(A_PUSH, 32'h0);
    hq.push_back(c);
    case (c.op)
      1: x_nl++;
      2: begin x_nx++; x_st[0] += c.st[0]; end
      3: begin x_nm++; x_st[1] += c.st[1]; x_st[2] += c.st[2]; end
      default: ;
    endcase
  endtask

  // y region and guards: random prefill
  task automatic prefill_y(cmd_t c);
    for (longint i = -16; i < 4 * c.rows + 16; i++) begin
      byte unsigned v = $urandom;
      mem0.bd_write8(c.addr + i, v);
      ypre[c.addr + i] = v;
    end
  endtask

  task automatic check_y(cmd_t c);
    int bad = 0;
    for (longint i = -16; i < 4 * c.rows + 16; i++) begin
      byte unsigned m = mem0.bd_read8(c.addr + i), e;
      bit is_y = i >= 0 && i < 4 * c.rows;
      if (is_y) begin
        logic [31:0] yv = c.ey[i / 4];
        e = yv[8 * (i % 4) +: 8];
      end else e = ypre[c.addr + i];
      if (m !== e) begin
        bad++;
        if (bad <= 4) begin
          string msg = $sformatf("%s: byte y%0d (row %0d) = %h, expected %h%s", c.tag, i, i / 4, m, e, is_y ? "" : " (guard)");
          if (is_y) c_y.fail(msg); else c_mem.fail(msg);
        end
      end
    end
    if (bad == 0) begin c_y.pass(); c_mem.pass(); end
    for (longint i = -16; i < 4 * c.rows + 16; i++) ypre.delete(c.addr + i);
  endtask

  task automatic poll_done(longint lim = 3_000_000);
    logic [31:0] st;
    longint t0 = bfm.cyc;
    do begin
      repeat ($urandom_range(30)) @(posedge clk);
      rd(A_STATUS, st);
      if (bfm.cyc - t0 > lim) begin
        c_model.fail($sformatf("WATCHDOG: no done_sticky after %0d cycles", lim));
        void'(tb_final_report('{c_y, c_mem, c_cyc, c_model, c_csr}));
        $finish;
      end
    end while (st[1] !== 1'b1);
  endtask

  // start a run (RUN) for the pushed commands, wait, check every command of hq, the counters and
  // CYCLES / stalls; exp_err < 0: ERR not compared
  task automatic run_and_check(int exp_err = 0, string tag = "run", bit refill = 0, ref cmd_t more[$]);
    logic [31:0] d;
    longint e_s;
    wr(A_CTRL, 32'h11);
    // refill while running: push the rest when the FIFO has room
    while (refill && more.size() > 0) begin
      rd(A_STATUS, d);
      if (int'(d[23:8]) < CMD_DEPTH) begin
        cmd_t c = more.pop_front();
        if (c.op == 3) prefill_y(c);
        push(c);
      end
    end
    poll_done();
    @(negedge clk);
    e_s = cl_e - cl_s;
    if (exp_err >= 0) expect_reg(A_ERR, 32'(exp_err), {tag, " ERR"}, exp_err != 0 ? c_err : c_csr);
    if (exp_err != 0) wr(A_ERR, 32'hFF);
    rd(A_CYCLES, d);
    if (cl_e < 0 || 32'(e_s) !== d) c_cyc.fail($sformatf("%s: CYCLES %0d, TB e - s = %0d", tag, d, e_s));
    else c_cyc.pass();
    if (cyc_mode && hq.size() == 1 && hq[0].op == 3) begin
      automatic longint f = cyc_formula(hq[0]);
      $display("CYCF rows %0d n %0d ya 0x%0h: %0d (formula %0d)", hq[0].rows, hq[0].n, hq[0].addr, e_s, f);
      if (f != e_s) c_cyc.fail($sformatf("%s: rows %0d n %0d: %0d cycles, formula %0d", tag, hq[0].rows, hq[0].n, e_s, f));
      else c_cyc.pass();
    end
    rd(A_RDSTALL, d);
    if (d !== 32'(t_rdst)) c_cyc.fail($sformatf("%s: RD_STALL %0d, TB %0d", tag, d, t_rdst)); else c_cyc.pass();
    rd(A_WRSTALL, d);
    if (d !== 32'(t_wrst)) c_cyc.fail($sformatf("%s: WR_STALL %0d, TB %0d", tag, d, t_wrst)); else c_cyc.pass();
    last_cycles = e_s;
    foreach (hq[i]) if (hq[i].op == 3) check_y(hq[i]);
    hq.delete();
    check_counters(tag);
  endtask

  task automatic check_counters(string tag);
    expect_reg(A_STWRGB, 32'(x_st[0]), {tag, " ST_WRGB"}, c_cnt);
    expect_reg(A_STMAC, 32'(x_st[1]), {tag, " ST_MAC"}, c_cnt);
    expect_reg(A_STRDMAC, 32'(x_st[2]), {tag, " ST_RDMAC"}, c_cnt);
    expect_reg(A_NLDW, 32'(x_nl), {tag, " N_LDW"}, c_cnt);
    expect_reg(A_NWRGB, 32'(x_nx), {tag, " N_WRGB"}, c_cnt);
    expect_reg(A_NMACAB, 32'(x_nm), {tag, " N_MACAB"}, c_cnt);
    expect_reg(A_OPS, 32'(x_nl + x_nx + x_nm), {tag, " OPS"}, c_cnt);
  endtask

  // ---------------- single-MACAB run formula (no memory stall, latency 1) ----------------
  // s: CTRL write; the command is popped in s + 1 (core handshake). The last y is valid at the core
  // output in s + 1 + C_core, C_core = (R - 1) max(nw, NB) + nw + L_BANK + nvl + L_S (pim.md; the
  // previous round's last word is long past). y write tail: docs/spec/pim.md 5 (the packer gives
  // beat j one cycle after its second y; burst k starts max(beat + 3, previous end + 1)); e = last
  // W + 2. Rows in the steady state come one per cycle in groups (gather), so the y times are
  // modelled row by row.
  function automatic int nbursts(longint unsigned a, int beats, ref int lens[$]);
    longint unsigned w = a / 8;
    lens.delete();
    while (beats > 0) begin
      int to4k = 512 - int'(w % 512);
      int b = beats < MAX_BURST ? beats : MAX_BURST;
      if (to4k < b) b = to4k;
      lens.push_back(b);
      w += b;
      beats -= b;
    end
    return lens.size();
  endfunction

  function automatic longint cyc_formula(cmd_t c);
    int nw = (c.n + LB - 1) / LB, R = (c.rows + NB - 1) / NB, P = nw > NB ? nw : NB;
    longint ty[$], we = -1000000;
    int lens[$], j = 0;
    // y valid at the core output (FIFO): round i, bank b: s + 1 + 1 + i P + nw - 1 + L_BANK + b + L_S + 1
    for (int r = 0; r < c.rows; r++) begin
      int i = r / NB, b = r % NB;
      ty.push_back(longint'(2) + longint'(i) * P + nw - 1 + L_BANK + b + L_S + 1);
    end
    void'(nbursts(c.addr, (c.rows + 1) / 2, lens));
    foreach (lens[k]) begin
      int jl = j + lens[k] - 1, ry = 2 * jl + 1 < c.rows - 1 ? 2 * jl + 1 : c.rows - 1;
      longint h = ty[ry] + 1, ws = h + 3 > we + 1 ? h + 3 : we + 1;
      we = ws + lens[k] - 1;
      j += lens[k];
    end
    return we + 3;   // B of the last burst in we + 2 (latency 1), the write engine is idle one cycle later
  endfunction

  // ---------------- memory helpers ----------------
  function automatic longint load_file(string f, longint unsigned base);
    int fd = $fopen(f, "rb");
    logic [7:0] buf8 [4096];
    byte unsigned pg [4096];
    bit pv [4096];
    longint tot = 0;
    int k;
    if (fd == 0) return -1;
    while (1) begin
      k = $fread(buf8, fd);
      if (k <= 0) break;
      for (int i = 0; i < 4096; i++) begin
        pg[i] = (i < k) ? buf8[i] : 8'h00;
        pv[i] = i < k;
      end
      mem0.mem[(base + tot) / 4096] = pg;
      mem0.vld[(base + tot) / 4096] = pv;
      tot += k;
      if (k < 4096) break;
    end
    $fclose(fd);
    return tot;
  endfunction

  function automatic logic [WW-1:0] bank_word(int b, int a);
    case (b)
      0: return dut.u_core.g_bank[0].u_bank.u_ram.mem[a];
      1: return dut.u_core.g_bank[1].u_bank.u_ram.mem[a];
      2: return dut.u_core.g_bank[2].u_bank.u_ram.mem[a];
      default: return dut.u_core.g_bank[3].u_bank.u_ram.mem[a];
    endcase
  endfunction
  task automatic set_bank_word(int b, int a, logic [WW-1:0] v);
    case (b)
      0: dut.u_core.g_bank[0].u_bank.u_ram.mem[a] = v;
      1: dut.u_core.g_bank[1].u_bank.u_ram.mem[a] = v;
      2: dut.u_core.g_bank[2].u_bank.u_ram.mem[a] = v;
      default: dut.u_core.g_bank[3].u_bank.u_ram.mem[a] = v;
    endcase
  endtask

  // ---------------- records ----------------
  typedef struct { string name; int rows, n, base; } bm_t;
  bm_t bmap[$];
  typedef struct { string name; int rows, n; longint unsigned off; } rm_t;
  rm_t rmap[$];

  function automatic void read_maps(string vdir);
    int fd;
    string line, nm;
    int rows, n, nw, base, words, we;
    longint unsigned off, bytes;
    fd = $fopen({vdir, "/../pim/bimg_map.txt"}, "r");
    while (fd != 0 && !$feof(fd)) begin
      line = ""; void'($fgets(line, fd));
      if (line.len() > 4 && line.substr(0, 3) == "mat " &&
          $sscanf(line, "mat %s %d %d %d %d %d %d", nm, rows, n, nw, base, words, we) == 7)
        bmap.push_back('{nm, rows, n, base});
    end
    if (fd) $fclose(fd);
    fd = $fopen({vdir, "/rrec_map.txt"}, "r");
    while (fd != 0 && !$feof(fd)) begin
      line = ""; void'($fgets(line, fd));
      if (line.len() > 4 && line.substr(0, 3) == "mat " &&
          $sscanf(line, "mat %s %d %d %d %d %d", nm, rows, n, off, bytes, we) == 6)
        rmap.push_back('{nm, rows, n, off});
    end
    if (fd) $fclose(fd);
  endfunction

  longint tok_cycles[$];        // per position: sum of run CYCLES

  task automatic run_records(string vdir, int maxpos, int mode);
    logic [WW-1:0] pre [NB][DEPTH];
    int nrec = 0, pos = 0;
    cmd_t ldw[$], tok[$];
    byte gx[];
    longint tcyc = 0;
    read_maps(vdir);
    if (bmap.size() != 36 || rmap.size() != 36 || load_file({vdir, "/rrec.bin"}, W_BASE) <= 0) begin
      c_img.fail("maps / rrec.bin");
      return;
    end
    for (int b = 0; b < NB; b++) for (int a = 0; a < DEPTH; a++) begin
      pre[b][a] = {$urandom, $urandom, $urandom, $urandom, $urandom};
      set_bank_word(b, a, pre[b][a]);
    end
    // LDW of all matrices: the FIFO is filled, the rest is pushed while the run goes
    for (int m = 0; m < 36; m++) begin
      cmd_t c;
      c.op = 1; c.rows = bmap[m].rows; c.n = bmap[m].n; c.base = bmap[m].base;
      c.addr = W_BASE + rmap[m].off; c.tag = {"LDW ", bmap[m].name};
      ldw.push_back(c);
    end
    while (ldw.size() > 0 && hq.size() < CMD_DEPTH) push(ldw.pop_front());
    run_and_check(0, "LDW", 1, ldw);
    $display("LDW run: 36 matrices, CYCLES %0d", last_cycles);
    for (int b = 0; b < NB; b++) begin
      int fd = $fopen($sformatf("%s/../pim/bank%0d.hex", vdir, b), "r");
      int a = 0, bad = 0;
      logic [WW-1:0] v;
      if (fd == 0) begin c_img.fail("bank hex"); continue; end
      while ($fscanf(fd, "%h", v) == 1) begin
        automatic logic [WW-1:0] got = bank_word(b, a), e = (a < 4072) ? v : pre[b][a];
        if (got !== e) begin
          bad++;
          if (bad <= 3) c_img.fail($sformatf("bank %0d word %0d: %h, expected %h", b, a, got, e));
        end
        a++;
      end
      $fclose(fd);
      if (a != DEPTH) c_img.fail("bank hex length");
      if (bad == 0) c_img.pass();
    end
    // MACABs
    if (kd_rec_open({vdir, "/gemv.bin"}) != 0) begin c_y.fail("gemv.bin"); return; end
    while (kd_rec_next() == K_GEMV) begin
      int m = nrec % 36;
      string nm = bmap[m].name;
      bit grp = mode == 2 || m == 0 || nm.substr(0, 1) == "wq" || nm.substr(0, 1) == "wo" ||
                nm.substr(0, 1) == "w1" || nm.substr(0, 1) == "w2" || nm == "cls";
      bit run_end = mode == 2 || (mode == 0 && (nm.substr(0, 1) == "w2" || nm == "cls")) || (mode == 1 && nm == "cls");
      cmd_t c;
      byte xb[];
      longint st[] = new[3];
      if (m == 0) begin
        if (maxpos > 0 && pos == maxpos) break;
        pos++;
        tcyc = 0;
      end
      c.op = 3; c.rows = kd_rec_prm(0); c.n = kd_rec_prm(1); c.base = bmap[m].base;
      c.we = kd_rec_prm(3); c.xm = kd_rec_prm(4); c.xe = kd_rec_prm(5); c.fo = kd_rec_prm(6);
      c.addr = Y_BASE + 64'h1_0000 * m + 8 * $urandom_range(511) + 16;
      c.tag = $sformatf("rec %0d %s", kd_rec_index(), nm);
      for (int r = 0; r < c.rows; r++) c.ey.push_back(kd_rec_get(3, r));
      if (kd_rec_bank(NB, st) != 0) c_cnt.fail({c.tag, ": bank_gemv differs from the record (golden)"});
      c.st[0] = st[0]; c.st[1] = st[1]; c.st[2] = st[2];
      xb = new[c.n];
      void'(kd_rec_bytes(2, 0, xb, c.n));
      if (grp) begin
        cmd_t x;
        x.op = 2; x.n = c.n; x.rows = 0; x.base = 0; x.addr = X_BASE + 64'h1000 * m + 8 * $urandom_range(63);
        x.st[0] = st[0]; x.tag = {"WRGB ", nm};
        for (int i = 0; i < 8 * ((c.n + 7) / 8); i++) begin
          mem0.bd_write8(x.addr + i, (i < c.n) ? xb[i] : 8'($urandom));
        end
        gx = xb;
        tok.push_back(x);
      end else begin
        bit same = gx.size() == c.n;
        for (int i = 0; same && i < c.n; i++) same = gx[i] == xb[i];
        if (!same) c_mem.fail({c.tag, ": x differs from its group"});
      end
      prefill_y(c);
      tok.push_back(c);
      if (run_end) begin
        while (tok.size() > 0 && hq.size() < CMD_DEPTH) push(tok.pop_front());
        run_and_check(0, c.tag, 1, tok);
        tcyc += last_cycles;
        if (nm == "cls") begin
          tok_cycles.push_back(tcyc);
          $display("TOKEN %0d (mode %0d): sum of run CYCLES %0d", pos - 1, mode, tcyc);
        end
      end
      nrec++;
    end
    void'(kd_rec_close());
    $display("records: %0d MACAB (%0d positions), mode %0d", nrec, pos, mode);
  endtask

  // ---------------- synthetic ----------------
  int ncorner[] = '{1, 15, 16, 17, 48, 49, NMAX};
  int xslot = 0;

  task automatic syn_group(int s, bit single_mac, output cmd_t cs[$]);
    int k = $urandom_range(9);
    int n = s < ncorner.size() ? ncorner[s] : (k < 4 ? $urandom_range(48, 1) : $urandom_range(NMAX, 1));
    int rows = k == 4 ? $urandom_range(3, 1) : (k == 5 ? NB * $urandom_range(30, 1) : $urandom_range(300, 1));
    int nw = (n + LB - 1) / LB, used, base, nmac = single_mac ? 1 : $urandom_range(3, 1), rb = 8 * (1 + (n + 7) / 8);
    byte w[], xb[];
    shortint wm[];
    cmd_t c;
    cs.delete();
    while ((rows + NB - 1) / NB * nw > DEPTH) rows = rows / 2 + 1;
    w = new[rows * n]; xb = new[n]; wm = new[rows];
    used = (rows + NB - 1) / NB * nw;
    base = $urandom_range(2) == 0 ? DEPTH - used : $urandom_range(DEPTH - used);
    foreach (w[i]) w[i] = (k == 6) ? -128 : byte'($urandom);
    foreach (wm[i]) wm[i] = (k == 7) ? 16'hFFFF : 16'($urandom);
    c.op = 1; c.rows = rows; c.n = n; c.base = base; c.tag = $sformatf("syn %0d LDW", s);
    c.addr = SW_BASE + 64'h40_0000 * (s % 32) + 8 * $urandom_range(511);
    // a quarter of the groups: sources and y start just below a 4 KiB boundary
    if ($urandom_range(3) == 0) c.addr = SW_BASE + 64'h40_0000 * (s % 32) + 4096 - 8 * $urandom_range(3, 1);
    for (int r = 0; r < rows; r++) begin
      longint unsigned a = c.addr + longint'(r) * rb;
      logic [63:0] h = {$urandom, 16'($urandom), wm[r]};
      for (int i = 0; i < 8; i++) mem0.bd_write8(a + i, h[8*i +: 8]);
      for (int i = 0; i < rb - 8; i++) mem0.bd_write8(a + 8 + i, (i < n) ? w[r * n + i] : 8'($urandom));
    end
    cs.push_back(c);
    for (int mi = 0; mi < nmac; mi++) begin
      int ey[] = new[rows];
      longint st[] = new[3];
      bit newx = mi == 0 || $urandom_range(1);
      cmd_t mc, x;
      if (newx) foreach (xb[i]) xb[i] = (k == 6) ? -127 : byte'(int'($urandom_range(254)) - 127);
      mc.op = 3; mc.rows = rows; mc.n = n; mc.base = base;
      mc.xm = (k == 8) ? (1 << AM_W) - 1 : $urandom_range((1 << AM_W) - 1);
      mc.we = (k == 9) ? int'($urandom_range(255)) - 128 : $urandom_range(30, 18);
      mc.xe = (k == 9) ? int'($urandom_range(255)) - 128 : $urandom_range(30, 15);
      mc.fo = (k == 9) ? int'($urandom_range(255)) - 128 : 16;
      mc.addr = Y_BASE + 64'h10_0000 * (xslot % 64) + 16 + 8 * $urandom_range(511);
      if ($urandom_range(3) == 0) mc.addr = Y_BASE + 64'h10_0000 * (xslot % 64) + 4096 - 8 * $urandom_range(20, 1);
      mc.tag = $sformatf("syn %0d MACAB %0d rows %0d n %0d", s, mi, rows, n);
      if (kd_bank_syn(w, wm, xb, rows, n, mc.we, mc.xm, mc.xe, mc.fo, NB, ey, st) != 0) c_y.fail("kd_bank_syn");
      foreach (ey[r]) mc.ey.push_back(ey[r]);
      mc.st[0] = st[0]; mc.st[1] = st[1]; mc.st[2] = st[2];
      if (newx) begin
        x.op = 2; x.n = n; x.rows = 0; x.base = 0; x.tag = $sformatf("syn %0d WRGB", s);
        x.addr = X_BASE + 64'h10_0000 + 64'h2000 * (xslot % 256) + 8 * $urandom_range(127);
        if ($urandom_range(3) == 0) x.addr = X_BASE + 64'h10_0000 + 64'h2000 * (xslot % 256) + 4096 - 8 * $urandom_range(3, 1);
        x.st[0] = st[0];
        for (int i = 0; i < 8 * ((n + 7) / 8); i++) mem0.bd_write8(x.addr + i, (i < n) ? xb[i] : 8'($urandom));
        cs.push_back(x);
      end
      xslot++;
      cs.push_back(mc);
    end
  endtask

  task automatic run_syn(int nsyn);
    cmd_t all[$], g[$];
    for (int s = 0; s < nsyn; s++) begin
      syn_group(s, 0, g);
      foreach (g[i]) all.push_back(g[i]);
      // a run when the batch is big enough (FIFO filled, the rest pushed while running)
      if (all.size() >= CMD_DEPTH || s == nsyn - 1 || $urandom_range(3) == 0) begin
        while (all.size() > 0 && hq.size() < CMD_DEPTH) begin
          if (all[0].op == 3) prefill_y(all[0]);
          push(all.pop_front());
        end
        run_and_check(0, $sformatf("syn %0d", s), 1, all);
      end
    end
  endtask

  // single-MACAB runs for the CYCLES formula (data preloaded by earlier commands)
  task automatic run_cyc(int ncyc);
    cmd_t g[$];
    for (int s = 0; s < ncyc; s++) begin
      syn_group(1000 + s, 1, g);
      // LDW (+ WRGB) in one run, the MACAB alone in the next
      foreach (g[i]) if (g[i].op != 3) push(g[i]);
      run_and_check(0, "cyc prep", 0, none_q);
      foreach (g[i]) if (g[i].op == 3) begin prefill_y(g[i]); push(g[i]); end
      run_and_check(0, $sformatf("cyc %0d", s), 0, none_q);
    end
  endtask

  // ---------------- main ----------------
  string vdir = "";
  int maxpos = 0, mode = 0, nsyn = 0, err_t = 0, coll = 0, csr_t = 0, wblk = 0, rblk = 0, ncyc = 0;
  int pst[5], plat[4];
  int unsigned seed;

  initial begin
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("PROF=%d", prof));
    void'($value$plusargs("MAXD=%d", maxd));
    void'($value$plusargs("VEC=%s", vdir));
    void'($value$plusargs("MAXPOS=%d", maxpos));
    void'($value$plusargs("MODE=%d", mode));
    void'($value$plusargs("SYN=%d", nsyn));
    void'($value$plusargs("ERR=%d", err_t));
    void'($value$plusargs("COLL=%d", coll));
    void'($value$plusargs("CSR=%d", csr_t));
    void'($value$plusargs("CYC=%d", ncyc));
    void'($value$plusargs("WBLK=%d", wblk));
    void'($value$plusargs("RBLK=%d", rblk));
    cyc_mode = ncyc > 0;
    $display("tb_pim_top: CMD_DEPTH %0d PIPE %0d/%0d Y_DEPTH %0d MAX_BURST %0d OUTS %0d SEED %0d PROF %0d MAXD %0d VEC %s MAXPOS %0d MODE %0d SYN %0d ERR %0d COLL %0d CSR %0d CYC %0d WBLK %0d RBLK %0d",
             CMD_DEPTH, DOT_PIPE, SCALE_PIPE, Y_DEPTH, MAX_BURST, OUTS, seed, prof, maxd, vdir, maxpos, mode,
             nsyn, err_t, coll, csr_t, ncyc, wblk, rblk);
    case (prof)
      0: begin pst = '{0, 0, 0, 0, 0}; plat = '{1, 1, 1, 1}; end
      1: begin pst = '{20, 20, 20, 20, 20}; plat = '{1, 30, 1, 20}; end
      default: begin pst = '{60, 60, 60, 60, 60}; plat = '{1, 60, 1, 40}; end
    endcase
    mem0.cfg_stall(pst[0], pst[1], pst[2], pst[3], pst[4]); mem0.cfg_lat(plat[0], plat[1], plat[2], plat[3]);
    mem0.cfg_uninit_err(1'b1);
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    repeat (3) @(posedge clk);
    bfm.maxd = maxd;
    if (wblk || rblk) fork blocker(); join_none

    if (csr_t) csr_tests();
    if (vdir != "") run_records(vdir, maxpos, mode);
    if (nsyn > 0) run_syn(nsyn);
    if (ncyc > 0) run_cyc(ncyc);
    if (err_t) begin $display("PHASE err %0t", $time); err_tests(); end
    if (coll) begin $display("PHASE coll %0t", $time); coll_tests(); end

    repeat (20) @(posedge clk);
    if (wblk || rblk) disable fork;
    expect_reg(A_STATUS, 32'h2, "STATUS end", c_csr);
    mem0.check_idle();
    mem0.report();
    $display("tb_pim_top: runs %0d (dones %0d), pushes %0d, AXI-Lite writes %0d reads %0d", n_starts, n_dones,
             n_push, bfm.n_wr, bfm.n_rd);
    $display("limits: write buffer full %0d, y credit %0d, read outstanding at OUTS %0d, FIFO overflows %0d",
             n_wfull, n_cred, n_routs, n_ovf);
    $display("collisions: CTRL start=0 at done %0d, CTRL start=1 at done %0d, ERR set and W1C same bit %0d",
             n_coll_c0, n_coll_c1, n_coll_err);
    if (wblk) begin
      if (n_wfull == 0) c_reach.fail("WBLK: write buffer never full"); else c_reach.pass();
      if (n_cred == 0) c_reach.fail("WBLK: y credit limit never reached"); else c_reach.pass();
    end
    if (rblk) begin
      if (n_routs == 0) c_reach.fail("RBLK: read outstanding limit never reached"); else c_reach.pass();
    end
    if (coll) begin
      if (n_coll_c0 == 0 || n_coll_c1 == 0 || n_coll_err == 0) c_reach.fail("COLL: a collision case did not happen");
      else c_reach.pass();
    end
    begin
      automatic tb_checker_q chks;
      if (vdir != "" || nsyn > 0 || ncyc > 0 || err_t || coll) begin chks.push_back(c_y); chks.push_back(c_cyc); chks.push_back(c_cnt); end
      if (vdir != "") chks.push_back(c_img);
      chks.push_back(c_mem);
      chks.push_back(c_model);
      chks.push_back(c_csr);
      if (err_t) chks.push_back(c_err);
      if (wblk || rblk || coll) chks.push_back(c_reach);
      void'(tb_final_report(chks));
    end
    $finish;
  end

  // ---------------- long blocks ----------------
  task automatic blocker();
    forever begin
      int len;
      repeat ($urandom_range(5000, 500)) @(posedge clk);
      len = $urandom_range(3000, 200);
      if (wblk && (!rblk || $urandom_range(1))) begin
        // W blocked until the y credit limit has held for len cycles (at most 100,000)
        mem0.cfg_stall(pst[0], 100, 100, pst[3], pst[4]);
        for (int w = 0, k = 0; k < len && w < 100000; w++) begin
          @(posedge clk);
          if (pr_cred) k++;
        end
        mem0.cfg_stall(pst[0], pst[1], pst[2], pst[3], pst[4]);
      end else begin
        mem0.cfg_stall(pst[0], pst[1], pst[2], 100, pst[4]);
        repeat (len) @(posedge clk);
        mem0.cfg_stall(pst[0], pst[1], pst[2], pst[3], pst[4]);
      end
    end
  endtask

  // ---------------- CSR tests ----------------
  int unused_a[] = '{'h28, 'h3C, 'h54, 'h5C, 'h78, 'h7C, 'hFC, 'h100, 'h800, 'hFFC};
  int zero_a[] = '{A_STATUS, A_ERR, A_CYCLES, A_RDSTALL, A_WRSTALL, A_OPS, A_CMD0, A_CMD1, A_CMD2, A_CMD3,
                   A_STWRGB, A_STMAC, A_STRDMAC, A_NLDW, A_NWRGB, A_NMACAB};
  int ro_a[] = '{A_ID, A_CONFIG, A_STATUS, A_CYCLES, A_RDSTALL, A_WRSTALL, A_OPS, A_CONFIG2, A_STWRGB,
                 A_STMAC, A_STRDMAC, A_NLDW, A_NWRGB, A_NMACAB};

  task automatic csr_tests();
    expect_reg(A_ID, 32'h5049_0001, "ID", c_csr);
    expect_reg(A_CONFIG, {16'(NMAX), 4'd4, 4'(NB), 8'd100}, "CONFIG", c_csr);
    expect_reg(A_CONFIG2, {16'(CMD_DEPTH), 16'(DEPTH)}, "CONFIG2", c_csr);
    foreach (zero_a[i]) expect_reg(zero_a[i], 32'd0, $sformatf("reset 0x%02h", zero_a[i]), c_csr);
    for (int i = 0; i < 4; i++) begin
      wr(A_CMD0 + 4 * i, 32'hDEAD_BEE0 + i);
      expect_reg(A_CMD0 + 4 * i, 32'hDEAD_BEE0 + i, "CMD rb", c_csr);
    end
    foreach (ro_a[i]) begin
      int a = ro_a[i];
      logic [31:0] bfr;
      rd(a, bfr);
      wr(a, 32'h5A5A_5A5A);
      expect_reg(a, bfr, $sformatf("read-only 0x%02h after write", a), c_csr);
    end
    expect_reg(A_CTRL, 32'd0, "CTRL reads 0", c_csr);
    expect_reg(A_PUSH, 32'd0, "CMD_PUSH reads 0", c_csr);
    foreach (unused_a[i]) begin
      wr(unused_a[i], 32'hFFFF_FFFF);
      expect_reg(unused_a[i], 32'd0, $sformatf("unused 0x%03h", unused_a[i]), c_csr);
    end
    wr(A_CTRL, 32'h10);
    expect_reg(A_STATUS, 32'd0, "STATUS after CTRL start=0", c_csr);
    // RUN with an empty FIFO: a run of one cycle
    wr(A_CTRL, 32'h11);
    poll_done();
    expect_reg(A_CYCLES, 32'd1, "CYCLES of an empty run", c_csr);
    expect_reg(A_STATUS, 32'd2, "STATUS after an empty run", c_csr);
  endtask

  // ---------------- error tests ----------------
  task automatic expect_err_only(logic [7:0] e, string what);
    expect_reg(A_ERR, 32'(e), what, c_err);
    wr(A_ERR, 32'hFF);
    expect_reg(A_ERR, 32'd0, {what, " W1C"}, c_err);
  endtask

  task automatic bad_push(cmd_t c, logic [7:0] e, string what);
    logic [127:0] w = cmd_word(c);
    logic [31:0] st;
    longint p0 = n_push;
    wr(A_CMD0, w[31:0]); wr(A_CMD1, w[63:32]); wr(A_CMD2, w[95:64]); wr(A_CMD3, w[127:96]);
    wr(A_PUSH, 32'h0);
    repeat (2) @(posedge clk);
    if (n_push != p0) c_err.fail({what, ": command queued"}); else c_err.pass();
    expect_err_only(e, what);
  endtask

  task automatic err_tests();
    cmd_t g[$], c, m;
    logic [31:0] st;
    // a small legal group to start from
    syn_group(2000, 1, g);
    foreach (g[i]) begin if (g[i].op == 3) prefill_y(g[i]); push(g[i]); end
    run_and_check(0, "err base", 0, none_q);
    foreach (g[i]) if (g[i].op == 3) m = g[i];
    c = m;
    // BAD_CMD: op 0, 4 (RDROW, not implemented), 15
    c.op = 0;  bad_push(c, 8'h04, "BAD_CMD op 0");
    c.op = 4;  bad_push(c, 8'h04, "BAD_CMD op 4 (RDROW)");
    c.op = 15; bad_push(c, 8'h04, "BAD_CMD op 15");
    // BAD_DESC reasons
    c = m; c.n = 0;          bad_push(c, 8'h08, "BAD_DESC n 0");
    c = m; c.n = NMAX + 1;   bad_push(c, 8'h08, "BAD_DESC n NMAX+1");
    c = m; c.rows = 0;       bad_push(c, 8'h08, "BAD_DESC rows 0");
    c = m; c.base = DEPTH - ((m.rows + NB - 1) / NB) * ((m.n + 15) / 16) + 1;
                             bad_push(c, 8'h08, "BAD_DESC bank range");
    c = m; c.op = 1; c.base = DEPTH; bad_push(c, 8'h08, "BAD_DESC LDW bank range");
    c = m; c.rows = 3; c.base = 0; c.addr = 64'hFFFF_FFF8; bad_push(c, 8'h08, "BAD_DESC y past 2^32");
    c = m; c.op = 2; c.addr = 64'hFFFF_FFF8; c.n = 9; bad_push(c, 8'h08, "BAD_DESC x past 2^32");
    c = m; c.op = 1; c.addr = 64'hFFFF_FF00; bad_push(c, 8'h08, "BAD_DESC W past 2^32");
    // MISALIGN, alone and with BAD_DESC
    c = m; c.addr = m.addr + 4;          bad_push(c, 8'h10, "MISALIGN y");
    c = m; c.op = 2; c.addr = X_BASE + 1; bad_push(c, 8'h10, "MISALIGN x");
    c = m; c.rows = 0; c.addr = m.addr + 2; bad_push(c, 8'h18, "MISALIGN + BAD_DESC");
    // BAD_OP (done_sticky stays 1), CTRL op 0 / 3 / 15
    wr(A_CTRL, 32'h01); wr(A_CTRL, 32'h31); wr(A_CTRL, 32'hF1);
    expect_reg(A_STATUS, 32'h6, "STATUS after BAD_OP (done stays)", c_err);
    expect_err_only(8'h02, "BAD_OP");
    // FIFO_OVF: fill the FIFO, one more push; then FLUSH (nothing executed)
    begin
      longint o0 = x_nm;
      for (int i = 0; i < CMD_DEPTH; i++) push(m);
      expect_reg(A_STATUS, {8'd0, 16'(CMD_DEPTH), 8'h02}, "STATUS with a full FIFO", c_err);
      bad_push(m, 8'h80, "FIFO_OVF");
      hq.delete();
      x_nm -= CMD_DEPTH; x_st[1] -= CMD_DEPTH * m.st[1]; x_st[2] -= CMD_DEPTH * m.st[2];
      prefill_y(m);
      wr(A_CTRL, 32'h21);                  // FLUSH
      poll_done();
      expect_reg(A_CYCLES, 32'(CMD_DEPTH + 1), "CYCLES of a FLUSH of a full FIFO", c_err);
      expect_reg(A_STATUS, 32'h2, "STATUS after FLUSH", c_err);
      check_counters("after FLUSH");
      // y memory untouched by the flushed MACABs
      m.ey.delete();
      for (int r = 0; r < m.rows; r++) begin
        logic [31:0] v;
        for (int b = 0; b < 4; b++) v[8*b +: 8] = ypre[m.addr + 4 * r + b];
        m.ey.push_back(v);
      end
      m.tag = "flushed MACAB";
      check_y(m);
      if (x_nm != o0) c_err.fail("counter bookkeeping");
    end
    // the same group runs correctly after all this
    foreach (g[i]) begin if (g[i].op == 3) prefill_y(g[i]); push(g[i]); end
    run_and_check(0, "err recovery", 0, none_q);
    $display("PHASE start_busy %0t", $time);
    // START_BUSY: start while a long run goes (the run is not disturbed); push during the run works
    syn_group(2001, 1, g);
    foreach (g[i]) begin if (g[i].op == 3) prefill_y(g[i]); push(g[i]); end
    wr(A_CTRL, 32'h11);
    wr(A_CTRL, 32'h11);
    wr(A_CTRL, 32'h10);                    // start = 0 while busy: no effect
    wr(A_CTRL, 32'h01);                    // illegal op while busy: START_BUSY and BAD_OP
    wr(A_CTRL, 32'h21);                    // FLUSH while busy: START_BUSY
    poll_done();
    @(negedge clk);
    foreach (hq[i]) if (hq[i].op == 3) check_y(hq[i]);
    hq.delete();
    expect_err_only(8'h03, "START_BUSY");
    check_counters("start_busy");
    $display("PHASE resp %0t", $time);
    // error responses: read (LDW row records, WRGB x) and write (y); data used as returned
    syn_group(2002, 1, g);
    foreach (g[i]) begin
      if (g[i].op == 1) mem0.inj_rd_err(g[i].addr + 8, g[i].addr + 16, 2'b10);
      if (g[i].op == 2) mem0.inj_rd_err(g[i].addr, g[i].addr + 8, 2'b11);
      if (g[i].op == 3) begin prefill_y(g[i]); mem0.inj_wr_err(g[i].addr, g[i].addr + 8, 2'b10); end
      push(g[i]);
    end
    run_and_check(8'h60, "rd_wr_resp", 0, none_q);
    mem0.inj_clear();
    foreach (g[i]) if (g[i].op == 3) begin
      prefill_y(g[i]);
      push(g[i]);
    end
    run_and_check(0, "after errors", 0, none_q);
  endtask

  // ---------------- collision tests ----------------
  task automatic coll_tests();
    cmd_t g[$], m;
    longint d0, t0, tg;
    logic [31:0] dd;
    syn_group(3000, 1, g);
    foreach (g[i]) if (g[i].op != 3) push(g[i]);
    run_and_check(0, "coll prep", 0, none_q);
    // a MACAB repeated (deterministic with PROF 0, MAXD 0), CTRL write swept around its end
    foreach (g[i]) if (g[i].op == 3) m = g[i];
    prefill_y(m); push(m);
    run_and_check(0, "coll base", 0, none_q);
    d0 = last_cycles;
    for (int st = 0; st < 2; st++)
      for (int off = -8; off <= 4; off++) begin
        prefill_y(m);
        push(m);
        hq.delete();
        wr(A_CTRL, 32'h11);
        t0 = bfm.cyc;
        tg = t0 + d0 + longint'(off);
        while (longint'(bfm.cyc) < tg) @(posedge clk);
        wr(A_CTRL, st ? 32'h11 : 32'h10);
        for (int w = 0; m_busy; w++) begin
          if (w > 100000) begin c_model.fail("WATCHDOG: collision run does not end"); break; end
          @(posedge clk);
        end
        repeat (4) @(posedge clk);
        check_y(m);
        rd(A_ERR, dd);
        wr(A_ERR, 32'hFF);
      end
    $display("PHASE w1c %0t", $time);
    // ERR W1C against a set: every B of a long run is SLVERR, W1C of WR_RESP repeated
    prefill_y(m);
    mem0.inj_wr_err(m.addr - 16, m.addr + 64'h1_0000, 2'b10);
    for (int i = 0; i < 6; i++) push(m);
    hq.delete();
    wr(A_CTRL, 32'h11);
    for (int w = 0; m_busy && w < 100000; w++) wr(A_ERR, 32'h40);
    poll_done();
    mem0.inj_clear();
    wr(A_ERR, 32'hFF);
    check_counters("coll");
  endtask

  initial begin
    #5s;
    $error("TB_TIMEOUT global");
    $finish;
  end

endmodule
