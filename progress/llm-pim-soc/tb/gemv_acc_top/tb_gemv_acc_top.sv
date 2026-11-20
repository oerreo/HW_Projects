// tb_gemv_acc_top: GEMV accelerator IP (rtl/l3/gemv_acc_top.sv) driven over AXI4-Lite by
// tb/common/axil_bfm.sv in the order of the PS driver (docs/spec/gemv_acc.md "call sequence"),
// AXI masters on tb/common/axi_mem_slave.sv (port 0: reads + y writes, port 1 (P = 2): reads,
// same x / W contents loaded into both models).
//
// Expected values (none taken from the RTL):
//   y          K_GEMV records of +VEC (the recorded y; the row records are model/build/vec/<m>/
//              rrec.bin, loaded once at W_BASE, matrix offsets from rrec_map.txt; row 0 and the
//              last row of every record are compared with the golden packer kd_rec_rrec_row),
//              or synthetic calls (kd_gemv1 per row = golden k_gemv_out(k_gemv_row(...))).
//   argmax     classifier records: the K_ARGMAX record of the same position (its v must equal
//              the classifier y, its idx must equal kd_argmax of it); every other call:
//              kd_argmax (golden k_argmax) of the expected y.
//   memory     y region == expected y (y_en) or unchanged (!y_en), 16 guard bytes on both sides
//              unchanged; every AW burst inside the y region; every AR burst inside x or inside
//              one row record of the slice's rows (r mod P = port); R beats per port.
//   timing     s = cycle in which the start CTRL write is performed, e = first cycle in which
//              (all y handshakes done, e > last y handshake) and (!y_en or every W beat written
//              and every AW answered by B). CYCLES = e - s. With +CYC=1 (no memory stalls,
//              latency 1) CYCLES must also equal the formula of docs/spec/gemv_acc.md.
//              RD_STALL = busy cycles with a core ready for a read beat without one (core
//              ports), WR_STALL = busy cycles with the write engine input valid and not ready.
//   CSR model  a register-file model written from the spec steps every cycle with the
//              accesses the DUT performed (taken from the AXI4-Lite bus: a write / read is
//              performed in the cycle before its B / R response starts) and the events above;
//              it predicts every read data word, the start acceptance (DUT start) and the done
//              cycle (DUT all_done) and the argmax done (DUT argmax_red done_o).
// Scenarios: +CSR=1 reset values, read-back, read-only and unused addresses; +VEC records
// (+MAXREC, +Y0=1 adds a y_en = 0 call per classifier record); +SYN=<k> synthetic calls
// (n 1..NMAX, rows 1..600 incl. odd, ties, 4 KiB crossing addresses, FLAGS mixes,
// +B2B=1: next descriptor written while a call runs, start right after done);
// +ERR=1 every ERR cause and the recovery; +COLL=1 CTRL write in the done cycle (start 0 and
// 1, swept) and ERR W1C against a set of the same bit; +WBLK / +RBLK long write / read
// blocks (limits must be reached: write buffer full, gemv_core credit, read space).
// Plusargs: +SEED +PROF(0|1|2) +MAXD +VEC +MAXREC +Y0 +SYN +B2B +ERR +COLL +CSR +CYC +WBLK
// +RBLK +PGAP
`timescale 1ns / 1ps
module tb_gemv_acc_top #(
  parameter int P          = 1,
  parameter int MAX_BURST  = 16,
  parameter int OUTS       = 4,
  parameter int DOT_PIPE   = 2,
  parameter int SCALE_PIPE = 3,
  parameter int Y_DEPTH    = 16
);
  import tb_util_pkg::*;
  import kdpi_pkg::*;
  import llm_pkg::*;

  localparam int IDW = 1, AW_L = 12, NMAX = 1024, ROWS_W = 16;
  localparam int RD_FIFO = MAX_BURST * OUTS;
  localparam int L_PIPE = 4 + DOT_PIPE + SCALE_PIPE;
  localparam longint unsigned W_BASE = 64'h1000_0000, SW_BASE = 64'h0400_0000,
                              X_BASE = 64'h2000_0000, Y_BASE = 64'h3000_0000;
  localparam int A_ID = 'h00, A_CONFIG = 'h04, A_CTRL = 'h08, A_STATUS = 'h0C, A_ERR = 'h10,
                 A_CYCLES = 'h14, A_RDSTALL = 'h18, A_WRSTALL = 'h1C, A_OPS = 'h20,
                 A_WADDR = 'h40, A_XADDR = 'h44, A_YADDR = 'h48, A_ROWS = 'h4C, A_N = 'h50,
                 A_XM = 'h54, A_EXP = 'h58, A_FLAGS = 'h5C, A_AMIDX = 'h60, A_AMVAL = 'h64;

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

  // ---------------- AXI masters ----------------
  logic [IDW-1:0] m_awid, m_bid;
  logic [31:0] m_awaddr;
  logic [7:0] m_awlen, m_wstrb;
  logic [2:0] m_awsize, m_awprot;
  logic [1:0] m_awburst, m_bresp;
  logic [3:0] m_awcache, m_awqos;
  logic m_awlock, m_awvalid, m_awready, m_wlast, m_wvalid, m_wready, m_bvalid, m_bready;
  logic [63:0] m_wdata;
  logic [1:0][IDW-1:0] m_arid, m_rid;
  logic [1:0][31:0] m_araddr;
  logic [1:0][7:0] m_arlen;
  logic [1:0][2:0] m_arsize, m_arprot;
  logic [1:0][1:0] m_arburst, m_rresp;
  logic [1:0][3:0] m_arcache, m_arqos;
  logic [1:0] m_arlock, m_arvalid, m_arready, m_rlast, m_rvalid, m_rready;
  logic [1:0][63:0] m_rdata;

  gemv_acc_top #(.P(P), .MAX_BURST(MAX_BURST), .OUTS(OUTS), .IDW(IDW), .NMAX(NMAX),
                 .ROWS_W(ROWS_W), .IDX_W(16), .DOT_PIPE(DOT_PIPE), .SCALE_PIPE(SCALE_PIPE),
                 .Y_DEPTH(Y_DEPTH), .FCLK_MHZ(100), .ADDR_W(AW_L)) dut (
    .clk, .rst_n,
    .s_axi_awaddr_i(awaddr), .s_axi_awprot_i(awprot), .s_axi_awvalid_i(awvalid), .s_axi_awready_o(awready),
    .s_axi_wdata_i(wdata), .s_axi_wstrb_i(wstrb), .s_axi_wvalid_i(wvalid), .s_axi_wready_o(wready),
    .s_axi_bresp_o(bresp), .s_axi_bvalid_o(bvalid), .s_axi_bready_i(bready),
    .s_axi_araddr_i(araddr), .s_axi_arprot_i(arprot), .s_axi_arvalid_i(arvalid), .s_axi_arready_o(arready),
    .s_axi_rdata_o(rdata), .s_axi_rresp_o(rresp), .s_axi_rvalid_o(rvalid), .s_axi_rready_i(rready),
    .m_axi_awid_o(m_awid), .m_axi_awaddr_o(m_awaddr), .m_axi_awlen_o(m_awlen),
    .m_axi_awsize_o(m_awsize), .m_axi_awburst_o(m_awburst), .m_axi_awlock_o(m_awlock),
    .m_axi_awcache_o(m_awcache), .m_axi_awprot_o(m_awprot), .m_axi_awqos_o(m_awqos),
    .m_axi_awvalid_o(m_awvalid), .m_axi_awready_i(m_awready),
    .m_axi_wdata_o(m_wdata), .m_axi_wstrb_o(m_wstrb), .m_axi_wlast_o(m_wlast),
    .m_axi_wvalid_o(m_wvalid), .m_axi_wready_i(m_wready),
    .m_axi_bid_i(m_bid), .m_axi_bresp_i(m_bresp), .m_axi_bvalid_i(m_bvalid), .m_axi_bready_o(m_bready),
    .m_axi_arid_o(m_arid[P-1:0]), .m_axi_araddr_o(m_araddr[P-1:0]), .m_axi_arlen_o(m_arlen[P-1:0]),
    .m_axi_arsize_o(m_arsize[P-1:0]), .m_axi_arburst_o(m_arburst[P-1:0]), .m_axi_arlock_o(m_arlock[P-1:0]),
    .m_axi_arcache_o(m_arcache[P-1:0]), .m_axi_arprot_o(m_arprot[P-1:0]), .m_axi_arqos_o(m_arqos[P-1:0]),
    .m_axi_arvalid_o(m_arvalid[P-1:0]), .m_axi_arready_i(m_arready[P-1:0]),
    .m_axi_rid_i(m_rid[P-1:0]), .m_axi_rdata_i(m_rdata[P-1:0]), .m_axi_rresp_i(m_rresp[P-1:0]),
    .m_axi_rlast_i(m_rlast[P-1:0]), .m_axi_rvalid_i(m_rvalid[P-1:0]), .m_axi_rready_o(m_rready[P-1:0]));

  if (P == 1) begin : g_idle1   // read port 1 of the TB is not connected to the DUT
    assign m_arid[1] = '0; assign m_araddr[1] = '0; assign m_arlen[1] = '0; assign m_arsize[1] = 3'd3;
    assign m_arburst[1] = 2'b01; assign m_arvalid[1] = 1'b0; assign m_rready[1] = 1'b1;
  end

  axi_mem_slave #(.DW(64), .AW(32), .IDW(IDW), .MAX_LEN(MAX_BURST - 1), .MAX_OUTS(16), .NAME("mem0")) mem0 (
    .clk, .rst_n,
    .awid_i(m_awid), .awaddr_i(m_awaddr), .awlen_i(m_awlen), .awsize_i(m_awsize),
    .awburst_i(m_awburst), .awvalid_i(m_awvalid), .awready_o(m_awready),
    .wdata_i(m_wdata), .wstrb_i(m_wstrb), .wlast_i(m_wlast), .wvalid_i(m_wvalid), .wready_o(m_wready),
    .bid_o(m_bid), .bresp_o(m_bresp), .bvalid_o(m_bvalid), .bready_i(m_bready),
    .arid_i(m_arid[0]), .araddr_i(m_araddr[0]), .arlen_i(m_arlen[0]), .arsize_i(m_arsize[0]),
    .arburst_i(m_arburst[0]), .arvalid_i(m_arvalid[0]), .arready_o(m_arready[0]),
    .rid_o(m_rid[0]), .rdata_o(m_rdata[0]), .rresp_o(m_rresp[0]), .rlast_o(m_rlast[0]),
    .rvalid_o(m_rvalid[0]), .rready_i(m_rready[0]));
  logic [IDW-1:0] m1_bid;
  logic [1:0] m1_bresp;
  logic m1_awready, m1_wready, m1_bvalid;
  axi_mem_slave #(.DW(64), .AW(32), .IDW(IDW), .MAX_LEN(MAX_BURST - 1), .MAX_OUTS(16), .NAME("mem1")) mem1 (
    .clk, .rst_n,
    .awid_i('0), .awaddr_i('0), .awlen_i('0), .awsize_i(3'd3), .awburst_i(2'b01), .awvalid_i(1'b0),
    .awready_o(m1_awready), .wdata_i('0), .wstrb_i('0), .wlast_i(1'b0), .wvalid_i(1'b0),
    .wready_o(m1_wready), .bid_o(m1_bid), .bresp_o(m1_bresp), .bvalid_o(m1_bvalid), .bready_i(1'b1),
    .arid_i(m_arid[1]), .araddr_i(m_araddr[1]), .arlen_i(m_arlen[1]), .arsize_i(m_arsize[1]),
    .arburst_i(m_arburst[1]), .arvalid_i(m_arvalid[1]), .arready_o(m_arready[1]),
    .rid_o(m_rid[1]), .rdata_o(m_rdata[1]), .rresp_o(m_rresp[1]), .rlast_o(m_rlast[1]),
    .rvalid_o(m_rvalid[1]), .rready_i(m_rready[1]));

  // ---------------- probes (sub-module ports, counted by the TB) ----------------
  logic [1:0] pr_xr, pr_xv, pr_wr, pr_wv, pr_yv, pr_yr, pr_cred, pr_rspace, pr_rfull;
  for (genvar p = 0; p < 2; p++) begin : g_pr
    if (p < P) begin : g_on
      assign pr_xr[p] = dut.g_slice[p].u_core.x_ready_o;
      assign pr_xv[p] = dut.g_slice[p].u_core.x_valid_i;
      assign pr_wr[p] = dut.g_slice[p].u_core.w_ready_o;
      assign pr_wv[p] = dut.g_slice[p].u_core.w_valid_i;
      assign pr_yv[p] = dut.g_slice[p].u_core.y_valid_o;
      assign pr_yr[p] = dut.g_slice[p].u_core.y_ready_i;
      // header held back by the gemv_core credit (y FIFO full of reserved rows)
      assign pr_cred[p] = dut.g_slice[p].u_core.w_valid_i && !dut.g_slice[p].u_core.w_ready_o &&
                          dut.g_slice[p].u_core.bidx_q == '0 &&
                          dut.g_slice[p].u_core.cred_q >= Y_DEPTH;
      // AR held because the read buffer space does not cover the next burst
      assign pr_rspace[p] = dut.g_slice[p].u_rd.act_q &&
                            32'(dut.g_slice[p].u_rd.space_q) < 32'(dut.g_slice[p].u_rd.blen);
      assign pr_rfull[p] = 32'(dut.g_slice[p].u_rd.u_rbuf.level_o) == RD_FIFO;
    end else begin : g_off
      assign pr_xr[p] = 1'b0; assign pr_xv[p] = 1'b0; assign pr_wr[p] = 1'b0; assign pr_wv[p] = 1'b0;
      assign pr_yv[p] = 1'b0; assign pr_yr[p] = 1'b0; assign pr_cred[p] = 1'b0;
      assign pr_rspace[p] = 1'b0; assign pr_rfull[p] = 1'b0;
    end
  end
  wire pr_wiv = dut.u_wr.in_valid_i, pr_wir = dut.u_wr.in_ready_o;
  wire pr_start = dut.start, pr_done = dut.all_done, pr_amdone = dut.am_done;

  tb_checker c_y = new("y"), c_am = new("argmax"), c_mem = new("memory"), c_cyc = new("cycles"),
             c_model = new("csr_model"), c_csr = new("csr"), c_err = new("err"),
             c_pair = new("records"), c_reach = new("limits");

  // ---------------- per-call information for the monitor ----------------
  // set by the main thread before the CTRL write that starts a call ("next"), taken by the
  // model at the accepted start
  int  nx_am_idx = 0, nx_am_val = 0;
  // current call (model)
  int  cl_rows, cl_n, cl_nb, cl_ye, cl_am, cl_am_idx, cl_am_val;
  longint unsigned cl_wa, cl_xa, cl_ya;
  longint cl_s = -1, cl_e = -1;
  int  ny, nw_hs, naw, nb_hs, rbeats[2];
  longint c_ly = -1;
  longint n_starts = 0, n_dones = 0;
  longint t_rdst = 0, t_wrst = 0;          // TB stall counts of the current call
  longint n_wfull = 0, n_cred[2] = '{0, 0}, n_rspace[2] = '{0, 0}, n_rfull[2] = '{0, 0};
  longint n_coll_c0 = 0, n_coll_c1 = 0, n_coll_err = 0;
  bit  model_on = 1'b0;

  // ---------------- CSR reference model ----------------
  // gemv_acc.md 3: a call accepted in s is checked on the descriptor latched in s; the verdict
  // is in v = s + CHK (CHK = bits of 1 + NMAX/8 + 1); STATUS.busy covers the check
  localparam int CHK = $clog2(NMAX / 8 + 2) + 1;
  logic [31:0] m_wa, m_xa, m_ya, m_rows, m_n, m_xm, m_exp, m_flags;
  logic [31:0] l_wa, l_xa, l_ya, l_rows, l_n, l_flags;    // latched in s
  bit          m_busy, m_done;
  int          m_chk;
  longint      m_s;
  logic [5:0]  m_err;
  logic [31:0] m_cyc, m_rdst, m_wrst, m_ops, m_amidx, m_amval;

  function automatic void model_reset();
    m_wa = 0; m_xa = 0; m_ya = 0; m_rows = 0; m_n = 0; m_xm = 0; m_exp = 0; m_flags = 2;
    m_busy = 0; m_done = 0; m_err = 0; m_cyc = 0; m_rdst = 0; m_wrst = 0; m_ops = 0;
    m_amidx = 0; m_amval = 0; m_chk = 0; m_s = -1;
  endfunction

  function automatic logic [31:0] model_read(int a);
    if (a >= 256) return 0;
    case (a & ~3)
      A_ID:      return 32'h4741_0001;
      A_CONFIG:  return {16'(NMAX), 4'd3, 4'(P), 8'd100};
      A_STATUS:  return {29'd0, m_err != 0, m_done, m_busy || m_chk != 0};
      A_ERR:     return 32'(m_err);
      A_CYCLES:  return m_cyc;
      A_RDSTALL: return m_rdst;
      A_WRSTALL: return m_wrst;
      A_OPS:     return m_ops;
      A_WADDR:   return m_wa;
      A_XADDR:   return m_xa;
      A_YADDR:   return m_ya;
      A_ROWS:    return m_rows;
      A_N:       return m_n;
      A_XM:      return m_xm & 32'h1FFFF;
      A_EXP:     return m_exp & 32'hFF_FFFF;
      A_FLAGS:   return m_flags & 3;
      A_AMIDX:   return m_amidx & 32'hFFFF;
      A_AMVAL:   return m_amval;
      default:   return 0;
    endcase
  endfunction

  // descriptor rules on the latched values
  function automatic bit model_desc_ok();
    longint unsigned rb = 8 * (1 + (longint'(l_n) + 7) / 8);
    bit ye = l_flags[1];
    if (l_rows == 0 || l_rows > 65535 || l_n == 0 || l_n > NMAX || l_flags[1:0] == 0) return 0;
    if (longint'(l_wa) + longint'(l_rows) * rb > 64'h1_0000_0000) return 0;
    if (longint'(l_xa) + longint'(l_n) > 64'h1_0000_0000) return 0;
    if (ye && longint'(l_ya) + 4 * longint'(l_rows) > 64'h1_0000_0000) return 0;
    return 1;
  endfunction

  function automatic bit model_align_ok();
    return l_wa[2:0] == 0 && l_xa[2:0] == 0 && (!l_flags[1] || l_ya[2:0] == 0);
  endfunction

  typedef struct {
    bit rd_err, wr_err, rd_stall, wr_stall, done, am_done, dut_start, dut_done, dut_am;
  } ev_t;
  ev_t ev_prev;

  // one cycle k of the model: write / read performed in k, events of k
  function automatic void model_step(longint k, ev_t ev, bit pw, int pwa, logic [31:0] pwd,
                                     bit prd, int pra, logic [31:0] prdata);
    bit ctrl, start_req, idle, op_ok, start, w1c_hit, busy_old, acc, verdict, d_ok = 1, a_ok = 1;
    logic [5:0] set, clr;
    if (prd) begin
      logic [31:0] e = model_read(pra);
      if (prdata !== e)
        c_model.fail($sformatf("read 0x%03h performed in cycle %0d: got %h, model %h", pra, k, prdata, e));
      else c_model.pass();
    end
    ctrl      = pw && pwa < 256 && (pwa & ~3) == A_CTRL;
    start_req = ctrl && pwd[0];
    idle      = (!m_busy && m_chk == 0) || ev.done;
    op_ok     = pwd[7:4] == 4'd1;
    acc       = start_req && idle && op_ok;
    verdict   = m_chk == 1;
    if (verdict) begin d_ok = model_desc_ok(); a_ok = model_align_ok(); end
    start     = verdict && d_ok && a_ok;
    if (start !== ev.dut_start)
      c_model.fail($sformatf("cycle %0d: DUT start %b, model %b", k, ev.dut_start, start));
    if (ev.done !== ev.dut_done)
      c_model.fail($sformatf("cycle %0d: DUT done %b, TB done %b", k, ev.dut_done, ev.done));
    else if (ev.done) c_model.pass();
    if (ev.am_done !== ev.dut_am)
      c_model.fail($sformatf("cycle %0d: DUT argmax done %b, TB %b", k, ev.dut_am, ev.am_done));
    if (ctrl && ev.done) begin
      if (pwd[0]) n_coll_c1++; else n_coll_c0++;
    end
    set = '0;
    set[0] = start_req && !idle;
    set[1] = start_req && !op_ok;
    set[2] = verdict && !d_ok;
    set[3] = verdict && !a_ok;
    set[4] = ev.rd_err;
    set[5] = ev.wr_err;
    w1c_hit = pw && pwa < 256 && (pwa & ~3) == A_ERR;
    clr = w1c_hit ? pwd[5:0] : '0;
    if ((set & clr) != 0) n_coll_err++;
    // next state
    busy_old = m_busy || m_chk != 0;
    if (ctrl && idle && !(pwd[0] && !op_ok)) m_done = 0;
    else if (ev.done) m_done = 1;
    m_err = (m_err & ~clr) | set;
    if (acc) begin
      m_cyc = 0; m_rdst = 0; m_wrst = 0;
    end else if (busy_old) begin
      m_cyc++;
      if (ev.rd_stall) m_rdst++;
      if (ev.wr_stall) m_wrst++;
    end
    if (ev.done) begin
      m_ops++;
      n_dones++;
      cl_e = k;
    end
    if (ev.am_done) begin
      m_amidx = cl_am_idx;
      m_amval = cl_am_val;
    end
    if (acc) begin
      m_chk = CHK; m_s = k;
      l_wa = m_wa; l_xa = m_xa; l_ya = m_ya; l_rows = m_rows; l_n = m_n; l_flags = m_flags;
    end else if (m_chk != 0) m_chk--;
    if (start) m_busy = 1;
    else if (ev.done) m_busy = 0;
    if (start) begin   // the call the monitor follows from now on (CYCLES from the CTRL write s)
      cl_s = m_s; cl_e = -1;
      cl_rows = l_rows; cl_n = l_n; cl_nb = (l_n + 7) / 8; cl_ye = l_flags[1]; cl_am = l_flags[0];
      cl_wa = l_wa; cl_xa = l_xa; cl_ya = l_ya;
      cl_am_idx = nx_am_idx; cl_am_val = nx_am_val;
      ny = 0; nw_hs = 0; naw = 0; nb_hs = 0; rbeats = '{0, 0}; c_ly = -1; t_rdst = 0; t_wrst = 0;
      n_starts++;
    end
    if (pw && pwa < 256)
      case (pwa & ~3)
        A_WADDR: m_wa = pwd;
        A_XADDR: m_xa = pwd;
        A_YADDR: m_ya = pwd;
        A_ROWS:  m_rows = pwd;
        A_N:     m_n = pwd;
        A_XM:    m_xm = pwd & 32'h1FFFF;
        A_EXP:   m_exp = pwd & 32'hFF_FFFF;
        A_FLAGS: m_flags = pwd & 3;
        default: ;
      endcase
  endfunction

  // ---------------- monitor (negedge) ----------------
  int  aw_q[$], ar_q[$];
  logic [31:0] w_q[$];
  bit  p_bv = 0, p_bhs = 0, p_rv = 0, p_rhs = 0;
  bit  pw_v, pr_v;
  int  pw_a, pr_a;
  logic [31:0] pw_d, pr_d;
  longint mcyc = 0;

  always @(negedge clk) begin
    if (!rst_n) begin
      model_reset();
      model_on = 1'b0;
      p_bv = 0; p_bhs = 0; p_rv = 0; p_rhs = 0;
    end else begin
      mcyc = bfm.cyc;
      // performed accesses of cycle mcyc - 1 (response starts in mcyc)
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
        automatic int need_w;
        ev = '{default: 0};
        for (int p = 0; p < P; p++) begin
          if (m_rvalid[p] && m_rready[p]) begin
            rbeats[p]++;
            if (m_rresp[p][1]) ev.rd_err = 1;
          end
          if ((pr_xr[p] && !pr_xv[p]) || (pr_wr[p] && !pr_wv[p])) ev.rd_stall = 1;
          if (pr_yv[p] && pr_yr[p]) begin
            ny++;
            if (ny == cl_rows) c_ly = mcyc;
          end
          if (pr_cred[p]) n_cred[p]++;
          if (pr_rspace[p]) n_rspace[p]++;
          if (pr_rfull[p]) n_rfull[p]++;
          // AR range: x, or one row record of this slice
          if (m_arvalid[p] && m_arready[p]) begin
            automatic longint unsigned a = m_araddr[p], b = a + 8 * (longint'(m_arlen[p]) + 1);
            automatic longint unsigned rb = 8 * (1 + cl_nb);
            automatic bit ok = 0;
            if (a >= cl_xa && b <= cl_xa + 8 * cl_nb) ok = 1;
            else if (a >= cl_wa && b <= cl_wa + rb * cl_rows) begin
              automatic longint unsigned r0 = (a - cl_wa) / rb, r1 = (b - 1 - cl_wa) / rb;
              ok = (P == 1) || (r0 == r1 && int'(r0 % P) == p);
            end
            if (!ok) c_mem.fail($sformatf("port %0d AR 0x%0h len %0d outside x / own rows (x 0x%0h w 0x%0h rb %0d rows %0d)",
                                          p, a, m_arlen[p], cl_xa, cl_wa, rb, cl_rows));
            else c_mem.pass();
          end
        end
        if (m_awvalid && m_awready) begin
          automatic longint unsigned a = m_awaddr, b = a + 8 * (longint'(m_awlen) + 1);
          naw++;
          if (!cl_ye || a < cl_ya || b > cl_ya + 8 * ((cl_rows + 1) / 2))
            c_mem.fail($sformatf("AW 0x%0h len %0d outside y [0x%0h, +%0d)", a, m_awlen, cl_ya, 4 * cl_rows));
          else c_mem.pass();
        end
        if (m_wvalid && m_wready) nw_hs++;
        if (m_bvalid && m_bready) begin
          nb_hs++;
          if (m_bresp[1]) ev.wr_err = 1;
        end
        if (pr_wiv && !pr_wir) begin
          ev.wr_stall = 1;
          n_wfull++;
        end
        need_w = (cl_rows + 1) / 2;
        ev.done = m_busy && ny == cl_rows && c_ly >= 0 && mcyc >= c_ly + 1 &&
                  (!cl_ye || (nw_hs == need_w && nb_hs == naw));
        ev.am_done = m_busy && cl_am && c_ly >= 0 && mcyc == c_ly + 1;
        if (m_busy) begin
          if (ev.rd_stall) t_rdst++;
          if (ev.wr_stall) t_wrst++;
        end
        ev.dut_start = pr_start;
        ev.dut_done  = pr_done;
        ev.dut_am    = pr_amdone;
        if ($isunknown({pr_start, pr_done, pr_amdone})) c_model.fail($sformatf("X on start / done at %0d", mcyc));
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

  // ---------------- memory helpers ----------------
  function automatic void mw8(longint unsigned a, byte unsigned v);
    mem0.bd_write8(a, v);
    if (P == 2) mem1.bd_write8(a, v);
  endfunction

  // raw file into both memories, base page-aligned (whole pages assigned)
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
      if (P == 2) begin
        mem1.mem[(base + tot) / 4096] = pg;
        mem1.vld[(base + tot) / 4096] = pv;
      end
      tot += k;
      if (k < 4096) break;
    end
    $fclose(fd);
    return tot;
  endfunction

  // ---------------- call description ----------------
  typedef struct {
    longint unsigned wa, xa, ya;
    int rows, n, xm, we, xe, fo;
    bit am, ye;
    string tag;
  } call_t;

  int unsigned seed;
  int prof = 0, maxd = 0, pgap = 30, cyc_mode = 0;
  longint n_calls = 0, n_ychk = 0;
  byte unsigned ypre[$];

  // x in memory: n bytes + random padding to the next 8-byte boundary
  task automatic put_x(call_t c, byte xb[]);
    for (int i = 0; i < 8 * ((c.n + 7) / 8); i++) mw8(c.xa + i, (i < c.n) ? xb[i] : $urandom);
  endtask

  // y region and guards: random prefill (16 bytes before, after)
  task automatic prefill_y(call_t c);
    ypre.delete();
    for (longint i = -16; i < 4 * c.rows + 16; i++) begin
      byte unsigned v = $urandom;
      mem0.bd_write8(c.ya + i, v);
      ypre.push_back(v);
    end
  endtask

  task automatic write_desc(call_t c);
    wr(A_XADDR, 32'(c.xa));
    wr(A_WADDR, 32'(c.wa));
    wr(A_YADDR, 32'(c.ya));
    wr(A_ROWS, c.rows);
    wr(A_N, c.n);
    wr(A_XM, c.xm);
    wr(A_EXP, {8'd0, 8'(c.fo), 8'(c.xe), 8'(c.we)});
    wr(A_FLAGS, {30'd0, c.ye, c.am});
  endtask

  // the "next call" expectation for the model, then CTRL start
  task automatic go(int ey[$]);
    int v[] = new[ey.size()];
    foreach (ey[i]) v[i] = ey[i];
    nx_am_idx = kd_argmax(v, ey.size());
    nx_am_val = ey[nx_am_idx];
    wr(A_CTRL, 32'h11);
  endtask

  // poll done_sticky (gap between polls)
  // watchdog: a call may take at most 200 x (its beats) + 200,000 cycles (slowest memory
  // profile with long blocks is far below)
  task automatic poll_done(int rows, int n);
    logic [31:0] st;
    int g = rows > 2000 ? 2000 : pgap;
    longint t0 = bfm.cyc, lim = 200 * longint'(rows) * (2 + (n + 7) / 8) + 200000;
    do begin
      repeat ($urandom_range(g)) @(posedge clk);
      rd(A_STATUS, st);
      if (bfm.cyc - t0 > lim) begin
        c_model.fail($sformatf("WATCHDOG: no done_sticky %0d cycles after the call (rows %0d n %0d)", lim, rows, n));
        void'(tb_final_report('{c_y, c_am, c_mem, c_cyc, c_model, c_csr}));
        $finish;
      end
    end while (st[1] !== 1'b1);
  endtask

  // check the finished call c (expected y ey, ERR bits exp_err, argmax override am_idx >= 0)
  // exp_err < 0: ERR not compared here (the CSR model still checks the value read)
  task automatic finish(call_t c, int ey[$], int exp_err = 0, int am_idx = -1);
    logic [31:0] d;
    longint e_s;
    int bad = 0;
    poll_done(c.rows, c.n);
    @(negedge clk);
    e_s = cl_e - cl_s;
    if (exp_err >= 0) expect_reg(A_ERR, 32'(exp_err), {c.tag, " ERR"}, exp_err != 0 ? c_err : c_csr);
    if (exp_err != 0) wr(A_ERR, 32'h3F);
    rd(A_CYCLES, d);
    if (cl_e < 0 || 32'(e_s) !== d) c_cyc.fail($sformatf("%s: CYCLES %0d, TB e - s = %0d", c.tag, d, e_s));
    else c_cyc.pass();
    if (cyc_mode) begin
      longint f = cyc_formula(c);
      $display("CYCF %0d %0d %0d %0d %0d %0d %0d %0d", c.rows, c.n, c.ye, c.am, c.wa, c.xa, c.ya, e_s);
      if (f != e_s) c_cyc.fail($sformatf("%s: rows %0d n %0d ye %0d wa 0x%0h xa 0x%0h ya 0x%0h: %0d cycles, formula %0d",
                                         c.tag, c.rows, c.n, c.ye, c.wa, c.xa, c.ya, e_s, f));
      else c_cyc.pass();
    end
    rd(A_RDSTALL, d);
    if (d !== 32'(t_rdst)) c_cyc.fail($sformatf("%s: RD_STALL %0d, TB %0d", c.tag, d, t_rdst)); else c_cyc.pass();
    rd(A_WRSTALL, d);
    if (d !== 32'(t_wrst)) c_cyc.fail($sformatf("%s: WR_STALL %0d, TB %0d", c.tag, d, t_wrst)); else c_cyc.pass();
    // R beats per port
    for (int p = 0; p < P; p++) begin
      int rp = (P == 1) ? c.rows : (p == 0 ? (c.rows + 1) / 2 : c.rows / 2);
      int eb = rp == 0 ? 0 : (c.n + 7) / 8 + rp * (1 + (c.n + 7) / 8);
      if (rbeats[p] != eb) c_mem.fail($sformatf("%s: port %0d R beats %0d, expected %0d", c.tag, p, rbeats[p], eb));
      else c_mem.pass();
    end
    // argmax
    if (c.am) begin
      int v[] = new[ey.size()];
      int ei;
      foreach (ey[i]) v[i] = ey[i];
      ei = am_idx >= 0 ? am_idx : kd_argmax(v, ey.size());
      expect_reg(A_AMIDX, 32'(ei), {c.tag, " ARGMAX_IDX"}, c_am);
      expect_reg(A_AMVAL, ey[ei], {c.tag, " ARGMAX_VAL"}, c_am);
    end
    // y memory and guards
    for (longint i = -16; i < 4 * c.rows + 16; i++) begin
      byte unsigned m = mem0.bd_read8(c.ya + i), e;
      bit is_y = c.ye && i >= 0 && i < 4 * c.rows;
      if (is_y) begin
        logic [31:0] yv = ey[i / 4];
        e = yv[8 * (i % 4) +: 8];
      end else e = ypre[i + 16];
      if (m !== e) begin
        bad++;
        if (bad <= 4) begin
          string msg = $sformatf("%s: byte y%0d (row %0d) = %h, expected %h%s", c.tag, i, i / 4, m,
                                 e, is_y ? "" : " (guard / y_en = 0)");
          if (is_y) c_y.fail(msg); else c_mem.fail(msg);
        end
      end
    end
    if (bad == 0) begin
      if (c.ye) begin c_y.pass(); n_ychk += c.rows; end
      c_mem.pass();
    end else if (bad > 4) c_y.fail($sformatf("%s: %0d bytes differ", c.tag, bad));
    n_calls++;
    if (n_calls % 50 == 0 || c.rows > 2000)
      $display("CALL %0d %s rows %0d n %0d ye %0d am %0d: CYCLES %0d RD_STALL %0d WR_STALL %0d (t=%0t)",
               n_calls, c.tag, c.rows, c.n, c.ye, c.am, e_s, t_rdst, t_wrst, $time);
  endtask

  // ---------------- CYCLES formula (no memory stall, latency 1; docs/spec/gemv_acc.md) ----------------
  // Read side: every command of a read engine takes (bursts + 1) cycles of AR issue and its data
  // arrive at one beat per cycle; a command with more bursts than that delays the next one.
  //   x command (mx bursts, nb beats) -> the row records start max(0, mx + 1 - nb) later
  //   P = 2: row command of slice p with mr bursts (1 + nb beats) delays the slice's later rows
  //          by max(0, mr - nb) (only a 2-beat record split at 4 KiB, nb = 1)
  // y of row k of slice p ready at Y0 + k (1 + nb) + delays, Y0 = nb + (1 + nb) + 14 + x delay;
  // merge: t(r) = max(ready(r), t(r - 1) + 1). !y_en: e = t(rows - 1) + 1.
  // y_en: beat j (rows 2j, 2j+1) enters the write buffer at h_j = t(min(2j + 1, rows - 1)) + 1;
  // burst k (L_k beats, last beat j_k, split from Y_ADDR by MAX_BURST and 4 KiB) puts its first
  // W beat at ws_k = max(h_jk + 3, we_(k-1) + 1), its last at we_k = ws_k + L_k - 1;
  // e = we_last + 2. All times relative to s; CYCLES = e.
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

  function automatic longint cyc_formula(call_t c);
    int nb = (c.n + 7) / 8, R = 1 + nb, lens[$], mx, j = 0;
    longint y0, t[$], ready[2][$], tt = -1000000, we = -1000000;
    mx = nbursts(c.xa, nb, lens);
    y0 = nb + R + 14 + ((mx + 1 - nb) > 0 ? mx + 1 - nb : 0);
    for (int p = 0; p < P; p++) begin
      longint d = 0;
      for (int r = p; r < c.rows; r += P) begin
        ready[p].push_back(y0 + longint'(r / P) * R + d);
        if (P == 2) begin
          int mr = nbursts(c.wa + longint'(r) * 8 * R, R, lens);
          if (mr - nb > 0) d += mr - nb;
        end
      end
    end
    for (int r = 0; r < c.rows; r++) begin
      longint rd = ready[r % P][r / P];
      tt = rd > tt + 1 ? rd : tt + 1;
      t.push_back(tt);
    end
    // gemv_acc.md 5: times from the verdict cycle v = s + CHK, CYCLES = CHK + (formula from v)
    if (!c.ye) return CHK + t[c.rows - 1] + 1;
    void'(nbursts(c.ya, (c.rows + 1) / 2, lens));
    foreach (lens[k]) begin
      int jl = j + lens[k] - 1, ry = 2 * jl + 1 < c.rows - 1 ? 2 * jl + 1 : c.rows - 1;
      longint h = t[ry] + 1, ws = h + 3 > we + 1 ? h + 3 : we + 1;
      we = ws + lens[k] - 1;
      j += lens[k];
    end
    return CHK + we + 2;
  endfunction

  // ---------------- synthetic calls ----------------
  task automatic syn_data(ref call_t c, ref int ey[$], input int region, input int kind);
    int nb = (c.n + 7) / 8;
    byte xb[] = new[c.n], wb[] = new[c.n];
    int tie = $urandom_range(4) == 0 ? $urandom_range(2, 1) : 0;   // 1: rows in pairs, 2: all equal
    int wm = 0;
    ey.delete();
    foreach (xb[i]) xb[i] = byte'(int'($urandom_range(254)) - 127);
    put_x(c, xb);
    for (int r = 0; r < c.rows; r++) begin
      longint unsigned a = c.wa + longint'(r) * 8 * (1 + nb);
      logic [63:0] h;
      if (!(tie == 2 && r > 0) && !(tie == 1 && r % 2 == 1)) begin
        wm = ($urandom_range(9) == 0) ? 65535 : $urandom_range(65535);
        foreach (wb[i]) wb[i] = byte'($urandom());
      end
      h = {$urandom(), 16'($urandom()), 16'(wm)};           // garbage above wm
      for (int b = 0; b < 8; b++) mw8(a + b, h[8*b +: 8]);
      for (int i = 0; i < 8 * nb; i++) mw8(a + 8 + i, (i < c.n) ? wb[i] : $urandom);  // garbage padding
      ey.push_back(kd_gemv1(wb, xb, c.n, wm, c.xm, c.we + c.xe - c.fo));
    end
  endtask

  function automatic call_t syn_desc(int s, int region);
    call_t c;
    int k = $urandom_range(9);
    int nl[] = '{1, 7, 8, 9, NMAX - 1, NMAX};
    int f = $urandom_range(9);
    c.n = (s < nl.size()) ? nl[s] : (k < 3 ? $urandom_range(24, 1) : $urandom_range(NMAX, 1));
    case (k)
      0: c.rows = 1;
      1: c.rows = 2;
      2: c.rows = 3;
      3: c.rows = 2 * $urandom_range(49) + 1;
      9: c.rows = $urandom_range(600, 100);
      default: c.rows = $urandom_range(64, 1);
    endcase
    c.xm = (k == 2) ? (1 << AM_W) - 1 : $urandom_range((1 << AM_W) - 1);
    c.we = (k == 3) ? int'($urandom_range(255)) - 128 : $urandom_range(30, 18);
    c.xe = (k == 4) ? int'($urandom_range(255)) - 128 : $urandom_range(30, 15);
    c.fo = (k == 5) ? int'($urandom_range(255)) - 128 : 16;
    c.am = f >= 4;
    c.ye = f < 7;
    c.wa = SW_BASE + longint'(region) * 64'h0100_0000 + 8 * $urandom_range(2047);
    c.xa = X_BASE + longint'(region) * 64'h1_0000 + 8 * $urandom_range(1023);
    c.ya = Y_BASE + longint'(region) * 64'h20_0000 + 8 * $urandom_range(1023) + 16;
    // a quarter of the calls: x, the row records and y start just below a 4 KiB boundary
    if ($urandom_range(3) == 0) begin
      c.xa = X_BASE + longint'(region) * 64'h1_0000 + 4096 - 8 * $urandom_range(2, 1);
      c.wa = SW_BASE + longint'(region) * 64'h0100_0000 + 4096 - 8 * $urandom_range(3, 1);
      c.ya = Y_BASE + longint'(region) * 64'h20_0000 + 4096 - 8 * $urandom_range(20, 1);
    end
    c.tag = $sformatf("syn %0d", s);
    return c;
  endfunction

  // ---------------- records ----------------
  typedef struct { string name; int rows, n, we; longint unsigned off; } mat_t;
  mat_t mats[$];
  int   am_idx_rec[$];
  int   am_v[$][$];

  function automatic int read_map(string f);
    int fd = $fopen(f, "r");
    string line, nm;
    int rows, n, we, rc;
    longint unsigned off, bytes;
    if (fd == 0) return -1;
    while (!$feof(fd)) begin
      line = "";
      void'($fgets(line, fd));
      if (line.len() < 4 || line.substr(0, 3) != "mat ") continue;
      rc = $sscanf(line, "mat %s %d %d %d %d %d", nm, rows, n, off, bytes, we);
      if (rc == 6) begin
        mat_t m;
        m.name = nm; m.rows = rows; m.n = n; m.off = off; m.we = we;
        mats.push_back(m);
      end
    end
    $fclose(fd);
    return mats.size();
  endfunction

  task automatic run_records(string vdir, int maxrec, int y0);
    int nrec = 0, ncls = 0, nm;
    longint sz;
    // K_ARGMAX records first (one record file open at a time)
    if (kd_rec_open({vdir, "/argmax.bin"}) != 0) c_pair.fail({"cannot open ", vdir, "/argmax.bin"});
    else
      while (kd_rec_next() == K_ARGMAX) begin
        int v[$];
        for (int i = 0; i < kd_rec_prm(0); i++) v.push_back(kd_rec_get(0, i));
        am_v.push_back(v);
        am_idx_rec.push_back(kd_rec_get(1, 0));
      end
    void'(kd_rec_close());
    nm = read_map({vdir, "/rrec_map.txt"});
    sz = load_file({vdir, "/rrec.bin"}, W_BASE);
    $display("records: %0d K_ARGMAX, %0d matrices, rrec.bin %0d bytes", am_idx_rec.size(), nm, sz);
    if (nm <= 0 || sz <= 0) begin
      c_pair.fail("cannot read rrec_map.txt / rrec.bin");
      return;
    end
    if (kd_rec_open({vdir, "/gemv.bin"}) != 0) begin
      c_pair.fail({"cannot open ", vdir, "/gemv.bin"});
      return;
    end
    while ((maxrec == 0 || nrec < maxrec) && kd_rec_next() == K_GEMV) begin
      call_t c;
      int ey[$];
      byte xb[];
      mat_t m = mats[nrec % nm];
      bit cls = m.name == "cls";
      int am_ref = -1;
      c.rows = kd_rec_prm(0); c.n = kd_rec_prm(1); c.we = kd_rec_prm(3); c.xm = kd_rec_prm(4);
      c.xe = kd_rec_prm(5); c.fo = kd_rec_prm(6);
      if (kd_rec_prm(2) != c.n || m.rows != c.rows || m.n != c.n || m.we != c.we) begin
        c_pair.fail($sformatf("record %0d (%s): rows/n/gs/we %0d/%0d/%0d/%0d, map %0d/%0d/-/%0d",
                              kd_rec_index(), m.name, c.rows, c.n, kd_rec_prm(2), c.we, m.rows, m.n, m.we));
        nrec++;
        continue;
      end
      for (int r = 0; r < c.rows; r++) ey.push_back(kd_rec_get(3, r));
      // row records in memory == golden packer (first and last row)
      for (int j = 0; j < 2; j++) begin
        int r = (j == 0) ? 0 : c.rows - 1;
        longint bt[] = new[1 + (c.n + 7) / 8];
        bit ok = 1;
        void'(kd_rec_rrec_row(r, bt));
        foreach (bt[b])
          if (mem0.bd_read64(W_BASE + m.off + longint'(r) * 8 * bt.size() + 8 * b) !== bt[b]) ok = 0;
        if (!ok) c_pair.fail($sformatf("record %0d row %0d: rrec.bin differs from rrec_pack", kd_rec_index(), r));
        else c_pair.pass();
      end
      if (cls) begin
        if (ncls >= am_v.size()) c_pair.fail($sformatf("classifier record %0d without a K_ARGMAX record", kd_rec_index()));
        else begin
          int v[] = new[c.rows];
          bit same = am_v[ncls].size() == c.rows;
          for (int i = 0; i < c.rows && same; i++) if (am_v[ncls][i] != ey[i]) same = 0;
          foreach (ey[i]) v[i] = ey[i];
          if (!same || kd_argmax(v, c.rows) != am_idx_rec[ncls])
            c_pair.fail($sformatf("classifier record %0d: K_ARGMAX record %0d does not match (same v %b)",
                                  kd_rec_index(), ncls, same));
          else c_pair.pass();
          am_ref = am_idx_rec[ncls];
        end
        ncls++;
      end
      xb = new[c.n];
      void'(kd_rec_bytes(2, 0, xb, c.n));
      c.wa = W_BASE + m.off;
      c.xa = X_BASE + 8 * $urandom_range(1023);
      c.ya = Y_BASE + 8 * $urandom_range(1023) + 16;
      c.am = cls ? 1 : $urandom_range(1);
      c.ye = 1;
      c.tag = $sformatf("rec %0d %s", kd_rec_index(), m.name);
      put_x(c, xb);
      prefill_y(c);
      write_desc(c);
      if (am_ref >= 0) begin nx_am_idx = am_ref; nx_am_val = ey[am_ref]; wr(A_CTRL, 32'h11); end
      else go(ey);
      finish(c, ey, 0, am_ref);
      if (cls && y0 && am_ref >= 0) begin   // the classifier again with y_en = 0 (argmax only)
        c.ye = 0;
        c.ya = Y_BASE + 64'h10_0000 + 8 * $urandom_range(1023) + 16;
        c.tag = {c.tag, " y_en=0"};
        prefill_y(c);
        write_desc(c);
        nx_am_idx = am_ref; nx_am_val = ey[am_ref];
        wr(A_CTRL, 32'h11);
        finish(c, ey, 0, am_ref);
      end
      nrec++;
    end
    void'(kd_rec_close());
    $display("records: %0d K_GEMV calls (%0d classifier)", nrec, ncls);
    if (nrec == 0) c_pair.fail("no K_GEMV record read");
    if (ncls > 0 && ncls != am_v.size() && maxrec == 0)
      c_pair.fail($sformatf("%0d classifier records, %0d K_ARGMAX records", ncls, am_v.size()));
  endtask

  // ---------------- main ----------------
  string vdir = "";
  int maxrec = 0, y0 = 1, nsyn = 0, b2b = 0, err_t = 0, coll = 0, csr_t = 0, wblk = 0, rblk = 0;
  int pst[5], plat[4];

  initial begin
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("PROF=%d", prof));
    void'($value$plusargs("MAXD=%d", maxd));
    void'($value$plusargs("VEC=%s", vdir));
    void'($value$plusargs("MAXREC=%d", maxrec));
    void'($value$plusargs("Y0=%d", y0));
    void'($value$plusargs("SYN=%d", nsyn));
    void'($value$plusargs("B2B=%d", b2b));
    void'($value$plusargs("ERR=%d", err_t));
    void'($value$plusargs("COLL=%d", coll));
    void'($value$plusargs("CSR=%d", csr_t));
    void'($value$plusargs("CYC=%d", cyc_mode));
    void'($value$plusargs("WBLK=%d", wblk));
    void'($value$plusargs("RBLK=%d", rblk));
    void'($value$plusargs("PGAP=%d", pgap));
    $display("tb_gemv_acc_top: P %0d MAX_BURST %0d OUTS %0d PIPE %0d/%0d Y_DEPTH %0d SEED %0d PROF %0d MAXD %0d VEC %s MAXREC %0d Y0 %0d SYN %0d B2B %0d ERR %0d COLL %0d CSR %0d CYC %0d WBLK %0d RBLK %0d",
             P, MAX_BURST, OUTS, DOT_PIPE, SCALE_PIPE, Y_DEPTH, seed, prof, maxd, vdir, maxrec, y0,
             nsyn, b2b, err_t, coll, csr_t, cyc_mode, wblk, rblk);
    case (prof)
      0: begin pst = '{0, 0, 0, 0, 0}; plat = '{1, 1, 1, 1}; end
      1: begin pst = '{20, 20, 20, 20, 20}; plat = '{1, 30, 1, 20}; end
      default: begin pst = '{60, 60, 60, 60, 60}; plat = '{1, 60, 1, 40}; end
    endcase
    mem0.cfg_stall(pst[0], pst[1], pst[2], pst[3], pst[4]); mem0.cfg_lat(plat[0], plat[1], plat[2], plat[3]);
    mem1.cfg_stall(pst[0], pst[1], pst[2], pst[3], pst[4]); mem1.cfg_lat(plat[0], plat[1], plat[2], plat[3]);
    mem0.cfg_uninit_err(1'b1);
    mem1.cfg_uninit_err(1'b1);
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    repeat (3) @(posedge clk);
    bfm.maxd = maxd;
    if (wblk || rblk) fork blocker(); join_none

    if (csr_t) csr_tests();
    if (vdir != "") run_records(vdir, maxrec, y0);
    if (nsyn > 0) run_syn(nsyn);
    if (err_t) begin $display("PHASE err %0t", $time); err_tests(); end
    if (coll) begin $display("PHASE coll %0t", $time); coll_tests(); end

    repeat (20) @(posedge clk);
    if (wblk || rblk) disable fork;
    expect_reg(A_STATUS, 32'h2, "STATUS end", c_csr);
    expect_reg(A_OPS, 32'(n_dones), "OPS end", c_csr);
    mem0.check_idle();
    mem1.check_idle();
    mem0.report();
    mem1.report();
    $display("tb_gemv_acc_top: calls %0d (starts %0d, dones %0d), y values checked %0d, AXI-Lite writes %0d reads %0d",
             n_calls, n_starts, n_dones, n_ychk, bfm.n_wr, bfm.n_rd);
    $display("limits: write buffer full %0d, credit %0d/%0d, read space %0d/%0d, read buffer full %0d/%0d",
             n_wfull, n_cred[0], n_cred[1], n_rspace[0], n_rspace[1], n_rfull[0], n_rfull[1]);
    $display("collisions: CTRL start=0 at done %0d, CTRL start=1 at done %0d, ERR set and W1C same bit %0d",
             n_coll_c0, n_coll_c1, n_coll_err);
    if (wblk) begin
      if (n_wfull == 0) c_reach.fail("WBLK: write buffer never full"); else c_reach.pass();
      for (int p = 0; p < P; p++) begin
        if (n_cred[p] == 0) c_reach.fail($sformatf("WBLK: slice %0d credit limit never reached", p)); else c_reach.pass();
        if (n_rspace[p] == 0) c_reach.fail($sformatf("WBLK: slice %0d read space never exhausted", p)); else c_reach.pass();
      end
    end
    if (coll) begin
      if (n_coll_c0 == 0 || n_coll_c1 == 0 || n_coll_err == 0)
        c_reach.fail("COLL: a collision case did not happen");
      else c_reach.pass();
    end
    begin
      automatic tb_checker_q chks;
      if (vdir != "" || nsyn > 0) begin chks.push_back(c_y); chks.push_back(c_am); chks.push_back(c_cyc); end
      if (vdir != "") chks.push_back(c_pair);
      chks.push_back(c_mem);
      chks.push_back(c_model);
      chks.push_back(c_csr);
      if (err_t) chks.push_back(c_err);
      if (wblk || coll) chks.push_back(c_reach);
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
        // held until the gemv_core credit limit has been in force for len cycles (the
        // write buffer and the core's y FIFO are full by then), at most 100,000 cycles
        mem0.cfg_stall(pst[0], 100, 100, pst[3], pst[4]);
        for (int w = 0, k = 0; k < len && w < 100000; w++) begin
          @(posedge clk);
          if (|pr_cred) k++;
        end
        mem0.cfg_stall(pst[0], pst[1], pst[2], pst[3], pst[4]);
      end else begin
        int p = $urandom_range(P - 1);
        if (p == 0) mem0.cfg_stall(pst[0], pst[1], pst[2], 100, pst[4]);
        else        mem1.cfg_stall(pst[0], pst[1], pst[2], 100, pst[4]);
        repeat (len) @(posedge clk);
        mem0.cfg_stall(pst[0], pst[1], pst[2], pst[3], pst[4]);
        mem1.cfg_stall(pst[0], pst[1], pst[2], pst[3], pst[4]);
      end
    end
  endtask

  // ---------------- synthetic run ----------------
  task automatic run_syn(int nsyn);
    call_t c, cn;
    int ey[$], eyn[$];
    c = syn_desc(0, 0);
    syn_data(c, ey, 0, 0);
    prefill_y(c);
    write_desc(c);
    go(ey);
    for (int s = 1; s <= nsyn; s++) begin
      bit pre = b2b && s < nsyn && $urandom_range(2) != 0;
      if (pre) begin   // next call prepared and its descriptor written while this one runs
        cn = syn_desc(s, s % 2);
        syn_data(cn, eyn, s % 2, 0);
        write_desc(cn);
      end
      finish(c, ey);
      if (s == nsyn) break;
      if (!pre) begin
        cn = syn_desc(s, s % 2);
        syn_data(cn, eyn, s % 2, 0);
      end
      c = cn;
      ey = eyn;
      prefill_y(c);
      if (!pre) write_desc(c);
      if (!b2b) repeat ($urandom_range(20)) @(posedge clk);
      go(ey);
    end
  endtask

  // ---------------- CSR tests ----------------
  int unused_a[] = '{'h24, 'h28, 'h3C, 'h68, 'h7C, 'h80, 'hFC, 'h100, 'h800, 'hFFC};
  int zero_a[] = '{A_STATUS, A_ERR, A_CYCLES, A_RDSTALL, A_WRSTALL, A_OPS, A_WADDR, A_XADDR, A_YADDR,
                   A_ROWS, A_N, A_XM, A_EXP, A_AMIDX, A_AMVAL};
  int ro_a[] = '{A_ID, A_CONFIG, A_STATUS, A_CYCLES, A_RDSTALL, A_WRSTALL, A_OPS, A_AMIDX, A_AMVAL};

  task automatic csr_tests();
    expect_reg(A_ID, 32'h4741_0001, "ID", c_csr);
    expect_reg(A_CONFIG, {16'(NMAX), 4'd3, 4'(P), 8'd100}, "CONFIG", c_csr);
    foreach (zero_a[i]) expect_reg(zero_a[i], 32'd0, $sformatf("reset 0x%02h", zero_a[i]), c_csr);
    expect_reg(A_FLAGS, 32'd2, "FLAGS reset", c_csr);
    wr(A_WADDR, 32'hDEAD_BEEF); expect_reg(A_WADDR, 32'hDEAD_BEEF, "W_ADDR rb", c_csr);
    wr(A_XADDR, 32'h1234_5678); expect_reg(A_XADDR, 32'h1234_5678, "X_ADDR rb", c_csr);
    wr(A_YADDR, 32'hFFFF_FFFF); expect_reg(A_YADDR, 32'hFFFF_FFFF, "Y_ADDR rb", c_csr);
    wr(A_ROWS, 32'hFFFF_FFFF);  expect_reg(A_ROWS, 32'hFFFF_FFFF, "ROWS rb", c_csr);
    wr(A_N, 32'h8000_0001);     expect_reg(A_N, 32'h8000_0001, "N rb", c_csr);
    wr(A_XM, 32'hFFFF_FFFF);    expect_reg(A_XM, 32'h0001_FFFF, "XM rb", c_csr);
    wr(A_EXP, 32'hFFFF_FFFF);   expect_reg(A_EXP, 32'h00FF_FFFF, "EXP rb", c_csr);
    wr(A_FLAGS, 32'hFFFF_FFFD); expect_reg(A_FLAGS, 32'h1, "FLAGS rb", c_csr);
    wr(A_FLAGS, 32'h2);
    foreach (ro_a[i]) begin
      int a = ro_a[i];
      logic [31:0] bfr;
      rd(a, bfr);
      wr(a, 32'h5A5A_5A5A);
      expect_reg(a, bfr, $sformatf("read-only 0x%02h after write", a), c_csr);
    end
    expect_reg(A_CTRL, 32'd0, "CTRL reads 0", c_csr);
    foreach (unused_a[i]) begin
      wr(unused_a[i], 32'hFFFF_FFFF);
      expect_reg(unused_a[i], 32'd0, $sformatf("unused 0x%03h", unused_a[i]), c_csr);
    end
    // CTRL write with start = 0 while idle: no call, nothing set
    wr(A_CTRL, 32'h10);
    expect_reg(A_STATUS, 32'd0, "STATUS after CTRL start=0", c_csr);
  endtask

  // ---------------- error tests ----------------
  task automatic expect_err_only(logic [5:0] e, bit done, string what);
    expect_reg(A_ERR, 32'(e), what, c_err);
    expect_reg(A_STATUS, {29'd0, e != 0, done, 1'b0}, {what, " STATUS"}, c_err);
    wr(A_ERR, 32'(e));
    expect_reg(A_ERR, 32'd0, {what, " W1C"}, c_err);
  endtask

  // a small legal call in region 0 (data written, descriptor written, not started)
  task automatic small_call(output call_t c, output int ey[$], input int rows = 7, input int n = 40);
    c = syn_desc(100, 0);
    c.rows = rows; c.n = n; c.am = 1; c.ye = 1; c.tag = "err";
    syn_data(c, ey, 0, 0);
    prefill_y(c);
    write_desc(c);
  endtask

  // PS rule (gemv_acc.md 3): after the CTRL write wait for STATUS.busy = 0 (the check)
  task automatic bad_start(logic [31:0] ctrl, logic [5:0] e, bit done, string what);
    longint st0 = n_starts;
    logic [31:0] st;
    wr(A_CTRL, ctrl);
    do rd(A_STATUS, st); while (st[0] !== 1'b0);
    repeat (3) @(posedge clk);
    if (n_starts != st0) c_err.fail({what, ": call started"}); else c_err.pass();
    expect_err_only(e, done, what);
  endtask

  task automatic err_tests();
    call_t c;
    int ey[$];
    logic [31:0] st;
    small_call(c, ey);
    go(ey);
    finish(c, ey);                       // done_sticky = 1 from here
    // BAD_OP: op 0, 2, 15 (done_sticky stays 1)
    bad_start(32'h01, 6'b000010, 1'b1, "BAD_OP op 0");
    bad_start(32'h21, 6'b000010, 1'b1, "BAD_OP op 2");
    bad_start(32'hF1, 6'b000010, 1'b1, "BAD_OP op 15");
    // BAD_DESC rules (a CTRL write with op 1 clears done_sticky)
    wr(A_ROWS, 0);          bad_start(32'h11, 6'b000100, 1'b0, "BAD_DESC rows 0");
    wr(A_ROWS, 65536);      bad_start(32'h11, 6'b000100, 1'b0, "BAD_DESC rows 65536");
    wr(A_ROWS, c.rows);
    wr(A_N, 0);             bad_start(32'h11, 6'b000100, 1'b0, "BAD_DESC n 0");
    wr(A_N, NMAX + 1);      bad_start(32'h11, 6'b000100, 1'b0, "BAD_DESC n NMAX+1");
    wr(A_N, 32'h1_0000 + c.n); bad_start(32'h11, 6'b000100, 1'b0, "BAD_DESC n 2^16 + n");
    wr(A_N, c.n);
    wr(A_FLAGS, 0);         bad_start(32'h11, 6'b000100, 1'b0, "BAD_DESC flags 0");
    wr(A_FLAGS, 3);
    wr(A_WADDR, 32'hFFFF_FF00); bad_start(32'h11, 6'b000100, 1'b0, "BAD_DESC W past 2^32");
    wr(A_WADDR, 32'(c.wa));
    wr(A_XADDR, 32'hFFFF_FFF8); wr(A_N, 9); bad_start(32'h11, 6'b000100, 1'b0, "BAD_DESC X past 2^32");
    wr(A_XADDR, 32'(c.xa)); wr(A_N, c.n);
    wr(A_YADDR, 32'hFFFF_FFF8); bad_start(32'h11, 6'b000100, 1'b0, "BAD_DESC Y past 2^32 (y_en)");
    // MISALIGN, alone and with BAD_DESC
    wr(A_YADDR, 32'(c.ya + 4)); bad_start(32'h11, 6'b001000, 1'b0, "MISALIGN Y (y_en)");
    wr(A_YADDR, 32'(c.ya));
    wr(A_WADDR, 32'(c.wa + 2)); bad_start(32'h11, 6'b001000, 1'b0, "MISALIGN W");
    wr(A_WADDR, 32'(c.wa));
    wr(A_XADDR, 32'(c.xa + 1)); bad_start(32'h11, 6'b001000, 1'b0, "MISALIGN X");
    wr(A_ROWS, 0);          bad_start(32'h11, 6'b001100, 1'b0, "MISALIGN + BAD_DESC");
    wr(A_XADDR, 32'(c.xa)); wr(A_ROWS, c.rows);
    // y_en = 0: Y_ADDR is not used (unaligned, past 2^32: legal)
    c.ye = 0; c.ya = Y_BASE + 64'h40_0000; c.tag = "err y_en=0";
    prefill_y(c);
    write_desc(c);
    wr(A_YADDR, 32'hFFFF_FFFC);
    go(ey);
    finish(c, ey);
    // the same descriptor is legal again with y_en = 1 and a good Y_ADDR
    c.ye = 1; c.ya = Y_BASE + 64'h41_0000; c.tag = "err recovery";
    prefill_y(c);
    write_desc(c);
    go(ey);
    finish(c, ey);
    $display("PHASE start_busy %0t", $time);
    // START_BUSY: a start while a long call runs, the call is not disturbed
    small_call(c, ey, 300, NMAX);
    go(ey);
    for (int w = 0; w < 1000; w++) begin
      rd(A_STATUS, st);
      if (st[0] === 1'b1) break;
    end
    wr(A_CTRL, 32'h11);
    rd(A_STATUS, st);
    if (st !== 32'h5) c_err.fail($sformatf("STATUS while busy after START_BUSY %h", st)); else c_err.pass();
    wr(A_CTRL, 32'h10);                  // start = 0 while busy: no effect
    wr(A_CTRL, 32'h01);                  // illegal op while busy: START_BUSY and BAD_OP
    c.tag = "start_busy";
    finish(c, ey, 6'b000011);
    $display("PHASE resp %0t", $time);
    // error responses: read (x DECERR, a row SLVERR, port 1 rows for P = 2), write SLVERR
    small_call(c, ey, 9, 100);
    begin
      longint unsigned rb = 8 * (1 + (c.n + 7) / 8);
      mem0.inj_rd_err(c.xa, c.xa + 8, 2'b11);
      mem0.inj_rd_err(c.wa + 2 * rb + 8, c.wa + 2 * rb + 16, 2'b10);
      if (P == 2) mem1.inj_rd_err(c.wa + 3 * rb, c.wa + 3 * rb + 8, 2'b10);
      go(ey);
      c.tag = "rd_resp";
      finish(c, ey, 6'b010000);
      mem0.inj_clear(); mem1.inj_clear();
      if (P == 2) begin   // an error on port 1 only
        small_call(c, ey, 9, 100);
        mem1.inj_rd_err(c.wa + 5 * rb + 16, c.wa + 5 * rb + 24, 2'b11);
        go(ey);
        c.tag = "rd_resp port 1";
        finish(c, ey, 6'b010000);
        mem1.inj_clear();
      end
      small_call(c, ey, 9, 100);
      mem0.inj_wr_err(c.ya + 8, c.ya + 16, 2'b10);
      go(ey);
      c.tag = "wr_resp";
      finish(c, ey, 6'b100000);
      mem0.inj_clear();
      small_call(c, ey, 9, 100);
      mem0.inj_rd_err(c.wa, c.wa + 8, 2'b10);
      mem0.inj_wr_err(c.ya, c.ya + 8, 2'b11);
      go(ey);
      c.tag = "rd_wr_resp";
      finish(c, ey, 6'b110000);
      mem0.inj_clear();
    end
    small_call(c, ey);
    go(ey);
    c.tag = "after errors";
    finish(c, ey);
  endtask

  // ---------------- collision tests ----------------
  // CTRL write performed in the done cycle: the call is repeated (deterministic with PROF 0
  // and MAXD 0) and the write is swept over the cycles around the measured end.
  task automatic coll_tests();
    call_t c;
    int ey[$];
    longint d0, t0, tg;
    logic [31:0] dd;
    small_call(c, ey, 5, 16);
    go(ey);
    finish(c, ey);
    d0 = cl_e - cl_s;
    for (int st = 0; st < 2; st++)
      for (int off = -8; off <= 4; off++) begin
        prefill_y(c);
        go(ey);
        t0 = bfm.cyc;
        tg = t0 + d0 + longint'(off);   // signed target (an unsigned compare would zero-extend off)
        while (longint'(bfm.cyc) < tg) @(posedge clk);
        wr(A_CTRL, st ? 32'h11 : 32'h10);
        for (int w = 0; m_busy || m_chk != 0; w++) begin
          if (w > 100000) begin
            c_model.fail("WATCHDOG: call of the collision sweep does not end");
            void'(tb_final_report('{c_y, c_am, c_mem, c_cyc, c_model, c_csr}));
            $finish;
          end
          @(posedge clk);
        end
        repeat (4) @(posedge clk);
        rd(A_ERR, dd);
        wr(A_ERR, 32'h3F);
      end
    $display("PHASE w1c %0t", $time);
    // ERR W1C against a set of the same bit: every R beat of a call is SLVERR, W1C of
    // RD_RESP repeated while the call runs
    small_call(c, ey, 200, 200);
    mem0.inj_rd_err(c.wa, c.wa + 64'h10_0000, 2'b10);
    if (P == 2) mem1.inj_rd_err(c.wa, c.wa + 64'h10_0000, 2'b10);
    go(ey);
    repeat (40) @(posedge clk);
    for (int w = 0; m_busy && w < 100000; w++) wr(A_ERR, 32'h10);
    c.tag = "w1c";
    finish(c, ey, -1);
    mem0.inj_clear(); mem1.inj_clear();
  endtask

  initial begin
    #2s;
    $error("TB_TIMEOUT global");
    $finish;
  end

endmodule
