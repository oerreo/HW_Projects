// tb_vec_top: vec_top over AXI4-Lite (tb/common/axil_bfm.sv) with AXI memory models
// (tb/common/axi_mem_slave.sv: rmem serves the read channel, wmem the write channel).
// Calls (golden from DPI-C, tb/common/vec_tb_pkg.sv): the TB writes the inputs in the golden buffer
// layout (int32 arrays, the RMSNORM g int16) at random 8-byte aligned addresses, sets the
// descriptor, writes CTRL and polls STATUS until busy = 0, then checks
//   q (int8 / int16) == golden, scale {int32 m, int32 e} == golden, ARGMAX: idx int32 at OUT and
//   ARGMAX_IDX / ARGMAX_VAL; 16 guard bytes before and after every written region (and the 4 bytes
//   after the ARGMAX idx) unwritten; ERR == 0; done_sticky.
//   +VEC=<dir> +FWD=1: every K_RMSNORM / K_SWIGLU / K_ACTQ / K_ARGMAX record of the model, in the
//   forward order of the manifest (+MAXPOS positions), CYCLES summed per position and op (token).
//   +NSYN: synthetic calls of random ops (n 1..N_MAX, ARGMAX up to +AMAXN), descriptor rewritten
//   in random order, sometimes while the previous call still runs (back-to-back: the CTRL write is
//   issued as soon as STATUS shows busy = 0, the descriptor of the next call during the previous).
// CSR reference model (every cycle, docs/spec/vec.md 3 and 4): descriptor registers, ERR (W1C, set
// wins), done_sticky, busy (check s + 1 and op), call acceptance in s, the verdict in v = s + 1 with
// an independent descriptor check of the descriptor latched in s, CYCLES / RD_STALL / WR_STALL /
// OPS, ARGMAX registers, the read data of every register read.
// +CYC=1 (no memory stalls): CYCLES == the model of docs/spec/vec.md 6.2 (top_cyc, every call).
// Stall counters read after every call (not the DUT event the CSR model uses): RD_STALL and
// WR_STALL <= CYCLES; +CYC=1: RD_STALL == RD_STALL0 (read start-up, vec.md 3) and WR_STALL == 0;
// +MSTALL: RD_STALL sum > 0; +WBLK: WR_STALL sum > 0 (a stall event that can never be true fails).
// +ERR=1: error paths and recovery (BAD_OP, each BAD_DESC reason, MISALIGN, both, START_BUSY,
// SLVERR / DECERR on a read (RD_RESP) and on a write (WR_RESP)).
// +RND=1 random register traffic between calls; +MSTALL memory stalls and latency; +WBLK=1 long
// write-channel blocks (write buffer full, packer held, q FIFO full required, coverage).
`timescale 1ns / 1ps
module tb_vec_top;
  import tb_util_pkg::*;
  import kdpi_pkg::*;
  import vec_tb_pkg::*;
  import llm_pkg::*;

  parameter int N_MAX     = 1024;
  parameter int IDX_W     = 16;
  parameter int Q_DEPTH   = 8;
  parameter int MAX_BURST = 16;
  parameter int OUTS      = 4;
  parameter int ADDR_W    = 12;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [ADDR_W-1:0] awaddr, araddr;
  logic [2:0]  awprot, arprot;
  logic        awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;
  logic [31:0] wdata, rdata;
  logic [3:0]  wstrb;
  logic [1:0]  bresp, rresp;
  logic [0:0]  m_awid, m_bid, m_arid, m_rid;
  logic [31:0] m_awaddr, m_araddr;
  logic [7:0]  m_awlen, m_arlen;
  logic [2:0]  m_awsize, m_awprot, m_arsize, m_arprot;
  logic [1:0]  m_awburst, m_bresp, m_arburst, m_rresp;
  logic        m_awlock, m_awvalid, m_awready, m_wlast, m_wvalid, m_wready, m_bvalid, m_bready;
  logic        m_arlock, m_arvalid, m_arready, m_rlast, m_rvalid, m_rready;
  logic [3:0]  m_awcache, m_awqos, m_arcache, m_arqos;
  logic [63:0] m_wdata, m_rdata;
  logic [7:0]  m_wstrb;

  vec_top #(.N_MAX(N_MAX), .IDX_W(IDX_W), .Q_DEPTH(Q_DEPTH), .MAX_BURST(MAX_BURST), .OUTS(OUTS),
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
  axi_mem_slave #(.DW(64), .AW(32), .IDW(1), .MAX_LEN(15), .NAME("rmem")) rmem (
    .clk, .rst_n,
    .awid_i(1'b0), .awaddr_i('0), .awlen_i('0), .awsize_i(3'd3), .awburst_i(2'b01), .awvalid_i(1'b0),
    .awready_o(), .wdata_i('0), .wstrb_i('0), .wlast_i(1'b0), .wvalid_i(1'b0), .wready_o(),
    .bid_o(), .bresp_o(), .bvalid_o(), .bready_i(1'b1),
    .arid_i(m_arid), .araddr_i(m_araddr), .arlen_i(m_arlen), .arsize_i(m_arsize),
    .arburst_i(m_arburst), .arvalid_i(m_arvalid), .arready_o(m_arready),
    .rid_o(m_rid), .rdata_o(m_rdata), .rresp_o(m_rresp), .rlast_o(m_rlast),
    .rvalid_o(m_rvalid), .rready_i(m_rready));

  tb_checker c_q = new("q"), c_s = new("scale"), c_am = new("argmax"), c_guard = new("guard"),
             c_err = new("err"), c_csr = new("csr_model"), c_rd = new("csr_read"),
             c_cyc = new("cycles"), c_cov = new("coverage"), c_rec = new("record"),
             c_stl = new("stall_count");

  // ---------------- CSR access ----------------
  localparam int A_ID = 'h00, A_CONFIG = 'h04, A_CTRL = 'h08, A_STATUS = 'h0C, A_ERR = 'h10,
                 A_CYCLES = 'h14, A_RDST = 'h18, A_WRST = 'h1C, A_OPS = 'h20, A_AMIDX = 'h24,
                 A_AMVAL = 'h28, A_IN0 = 'h40, A_IN1 = 'h44, A_OUT = 'h48, A_SCL = 'h4C, A_N = 'h50,
                 A_FMT = 'h54, A_EXP = 'h58, A_EPSC = 'h5C;
  task automatic csr_w(int a, logic [31:0] d);
    bfm.write0(ADDR_W'(a), d);
  endtask
  task automatic csr_r(int a, output logic [31:0] d);
    bfm.read(ADDR_W'(a), d);
  endtask

  // ---------------- CSR reference model (every cycle) ----------------
  typedef struct {
    longint unsigned in0, in1, out, scl, n, epsc;
    int qmax, mode, sb, f, ge;
  } desc_t;
  desc_t md, mdl;
  int    m_err = 0, m_done = 0, m_busy = 0, m_chk = 0, m_op = 0, m_rop = 0;
  longint unsigned m_cyc = 0, m_rdst = 0, m_wrst = 0, m_ops = 0, m_ami = 0, m_amv = 0;

  function automatic bit d_ok(desc_t d, int op);   // op 1..4
    longint unsigned lim = 64'h1_0000_0000;
    longint unsigned qb = (op == 3 && d.qmax != 127) ? 2 : 1;
    bit ok = d.n >= 1 && (op == 4 ? d.n <= (64'd1 << IDX_W) : d.n <= N_MAX);
    if (op != 4) ok = ok && d.mode == 1 && d.scl + 8 <= lim;
    if (op == 3) ok = ok && (d.qmax == 127 || d.qmax == 2047 || d.qmax == 32767);
    if (op == 2) ok = ok && d.sb == 8;
    if (op == 1) ok = ok && d.epsc < 64'h8000_0000;
    ok = ok && d.in0 + 4 * d.n <= lim;
    if (op == 1) ok = ok && d.in1 + 2 * d.n <= lim;
    if (op == 2) ok = ok && d.in1 + 4 * d.n <= lim;
    ok = ok && d.out + (op == 4 ? 4 : qb * d.n) <= lim;
    return ok;
  endfunction
  function automatic bit al_ok(desc_t d, int op);
    return d.in0 % 8 == 0 && d.out % 8 == 0 && (!(op == 1 || op == 2) || d.in1 % 8 == 0) &&
           (op == 4 || d.scl % 8 == 0);
  endfunction
  function automatic logic [31:0] m_read(int a);
    case (a & 'hFC)
      A_ID: return 32'h5645_0001;
      A_CONFIG: return {16'(N_MAX), 8'(IDX_W), 8'd100};
      A_STATUS: return {29'd0, m_err != 0, 1'(m_done), 1'(m_busy || m_chk != 0)};
      A_ERR: return 32'(m_err);
      A_CYCLES: return 32'(m_cyc);
      A_RDST: return 32'(m_rdst);
      A_WRST: return 32'(m_wrst);
      A_OPS: return 32'(m_ops);
      A_AMIDX: return 32'(m_ami);
      A_AMVAL: return 32'(m_amv);
      A_IN0: return 32'(md.in0); A_IN1: return 32'(md.in1); A_OUT: return 32'(md.out);
      A_SCL: return 32'(md.scl); A_N: return 32'(md.n); A_EPSC: return 32'(md.epsc);
      A_FMT: return {4'd0, 4'(md.sb), 7'd0, 1'(md.mode), 16'(md.qmax)};
      A_EXP: return {16'd0, 8'(md.ge), 8'(md.f)};
      default: return 32'd0;
    endcase
  endfunction

  longint n_starts = 0, cyc = 0;
  always @(negedge clk) begin
    cyc++;
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
      if (dut.u_csr.rd_en_i === 1'b1) begin
        got = dut.u_csr.rd_data_o;
        if (got !== m_read(int'(32'(dut.u_csr.rd_addr_i))) && (int'(32'(dut.u_csr.rd_addr_i)) >> 8) == 0)
          c_rd.fail($sformatf("read 0x%0h: 0x%08h model 0x%08h", dut.u_csr.rd_addr_i, got,
                              m_read(int'(32'(dut.u_csr.rd_addr_i)))));
        else c_rd.pass();
      end
      if (int'(dut.u_csr.err_q) !== m_err || int'(dut.u_csr.done_q) !== m_done ||
          int'(dut.u_csr.busy_q) !== m_busy || int'(dut.u_csr.chk_q) !== int'(m_chk != 0) ||
          longint'(dut.u_csr.cyc_q) !== m_cyc || longint'(dut.u_csr.rdst_q) !== m_rdst ||
          longint'(dut.u_csr.wrst_q) !== m_wrst || longint'(dut.u_csr.ops_q) !== m_ops)
        c_csr.fail($sformatf("state err %0h/%0h done %0d/%0d busy %0d/%0d cyc %0d/%0d ops %0d/%0d",
                             dut.u_csr.err_q, m_err, dut.u_csr.done_q, m_done, dut.u_csr.busy_q, m_busy,
                             dut.u_csr.cyc_q, m_cyc, dut.u_csr.ops_q, m_ops));
      else c_csr.pass();
      sreq  = wr_hit && w == A_CTRL && wd[0];
      op_ok = op >= 1 && op <= 4;
      acc   = sreq && idle && op_ok;
      if (verdict) begin
        ok_d = d_ok(mdl, m_op);
        ok_a = al_ok(mdl, m_op);
      end
      st = verdict && ok_d && ok_a;
      if (st !== dut.start) c_csr.fail($sformatf("start %b model %b (op %0d d %0d a %0d)", dut.start, st, m_op, ok_d, ok_a));
      if (sreq && !idle) set |= 1;
      if (sreq && !op_ok) set |= 2;
      if (verdict && !ok_d) set |= 4;
      if (verdict && !ok_a) set |= 8;
      if (dut.rd_err_ev) set |= 16;
      if (dut.wr_err_ev) set |= 32;
      if (done && !m_busy) c_csr.fail("done while not busy");
      if (acc) begin
        m_chk = 1;
        mdl   = md;
        m_op  = op;
      end else if (m_chk != 0) m_chk--;
      if (done && m_rop == 4) begin
        m_ami = longint'(dut.u_core.am_idx_o);
        m_amv = longint'(32'(dut.u_core.am_max_o));
      end
      if (st) begin m_busy = 1; n_starts++; m_rop = m_op; end
      else if (done) m_busy = 0;
      if (wr_hit && w == A_CTRL && idle && !(wd[0] && !op_ok)) m_done = 0;
      else if (done) m_done = 1;
      m_err = (m_err & ~((wr_hit && w == A_ERR) ? int'(wd[5:0]) : 0)) | set;
      if (acc) begin m_cyc = 0; m_rdst = 0; m_wrst = 0; end
      else if (was_busy) begin
        m_cyc++;
        if (dut.rd_stall_ev) m_rdst++;
        if (dut.wr_stall_ev) m_wrst++;
      end
      if (done) m_ops++;
      if (wr_hit)
        case (w)
          A_IN0: md.in0 = wd; A_IN1: md.in1 = wd; A_OUT: md.out = wd; A_SCL: md.scl = wd;
          A_N: md.n = wd; A_EPSC: md.epsc = wd;
          A_FMT: begin md.qmax = wd[15:0]; md.mode = wd[16]; md.sb = wd[27:24]; end
          A_EXP: begin md.f = wd[7:0]; md.ge = wd[15:8]; end
          default: ;
        endcase
    end
  end

  // ---------------- write-channel blocks and coverage ----------------
  int wblk = 0, mstall = 0;
  longint n_wfull = 0, n_pkhold = 0, n_qfull = 0, n_blk = 0;
  initial begin
    wait (rst_n === 1'b1);
    forever begin
      @(posedge clk);
      if (wblk && dut.pk_valid_q === 1'b1 && $urandom_range(7) == 0) begin
        wmem.cfg_stall(0, 0, 100, 0, 0);
        n_blk++;
        repeat ($urandom_range(1000, 100)) @(posedge clk);
        wmem.cfg_stall(0, mstall ? 20 : 0, mstall ? 20 : 0, 0, mstall ? 20 : 0);
        repeat (200) @(posedge clk);
      end
    end
  end
  always @(negedge clk)
    if (rst_n) begin
      if (!dut.u_wr.in_ready_o) n_wfull++;
      if (dut.pk_valid_q && !dut.wr_in_ready) n_pkhold++;
      if (int'(dut.u_core.u_aq.f_level) == Q_DEPTH) n_qfull++;
    end

  // ---------------- one call ----------------
  longint unsigned ibase = 64'h1000_0000, obase = 64'h4000_0000;
  bit chk_cyc = 0, back = 0;
  // RD_STALL of a call with no memory stall, latency 1 (read start-up, docs/spec/vec.md 3): the
  // read command handshake is in s + 2 (engine busy from s + 3), ARVALID s + 4, first R s + 6, first
  // beat at the core s + 7: stall cycles s + 3 .. s + 6. Same for every op and n (later beats are
  // buffered before the core wants them).
  localparam longint RD_STALL0 = 4;
  int err_allow = 0;
  logic [31:0] last_err;
  longint op_cyc[4][int];     // CYCLES sum per op and position
  longint op_n[4] = '{0, 0, 0, 0}, op_sum[4] = '{0, 0, 0, 0};
  longint dmin[4] = '{1 << 30, 1 << 30, 1 << 30, 1 << 30}, dmax[4] = '{-(1 << 30), -(1 << 30), -(1 << 30), -(1 << 30)};
  // RD_STALL / WR_STALL of the calls (read after each call; not the CSR model's per-cycle event):
  // per op min / max of RD_STALL, sums over the run
  longint rsmin[4] = '{1 << 30, 1 << 30, 1 << 30, 1 << 30}, rsmax[4] = '{-1, -1, -1, -1};
  longint rs_sum = 0, ws_sum = 0;

  // CYCLES model (docs/spec/vec.md 6.2, no memory stalls, latency 1). s = CTRL cycle, the core runs
  // from s + 1 and is done at D = s + 1 + C_core. Ops 1..3: q value i is handed to the packer at
  // D - n + i; beat j (P = 8 / qb values) is complete at h_j = D - n + min(P j + P - 1, n - 1); the
  // q write splits into bursts k (16 beats, 4 KiB) with W from ws_k = max(h_(last beat of k) + 10,
  // we_(k-1) + 1) to we_k = ws_k + L_k - 1; the scale beat's W is ws = max(D + 11, we_last + 1);
  // the run ends at e = ws + 2. ARGMAX: e = D + 13. Returns e - s.
  function automatic longint top_cyc(vcase c, longint unsigned ao, int qb);
    longint D = 1 + core_cyc(c), we = -(64'sd1 << 40), ws, h;
    longint unsigned a = ao, beats = (longint'(c.n) * qb + 7) / 8, j0 = 0, l;
    int P = 8 / qb;
    if (opof(c) == 4) return D + 13;
    while (beats > 0) begin
      longint unsigned to4k = (4096 - (a % 4096)) / 8;
      l = beats < 16 ? beats : 16;
      if (to4k < l) l = to4k;
      h  = D - c.n + ((P * (j0 + l - 1) + P - 1 < c.n - 1) ? P * (j0 + l - 1) + P - 1 : c.n - 1);
      ws = (h + 10 > we + 1) ? h + 10 : we + 1;
      we = ws + longint'(l) - 1;
      j0 += l; beats -= l; a += 8 * l;
    end
    ws = (D + 11 > we + 1) ? D + 11 : we + 1;
    return ws + 2;
  endfunction
  function automatic int opof(vcase c);
    return c.kid == K_RMSNORM ? 1 : c.kid == K_SWIGLU ? 2 : c.kid == K_ACTQ ? 3 : 4;
  endfunction
  // core formula (vec_core) of an op; the top adds a constant (CYC check, docs/spec/vec.md 6)
  function automatic longint core_cyc(vcase c);
    case (opof(c))
      1: return 4 * c.n + (c.ymax != 0 ? 87 : 34);
      2: return 3 * c.n + (c.amax != 0 ? 67 : 14);
      3: return 2 * c.n + (c.amax != 0 ? 59 : 6);
      default: return c.n + 1;
    endcase
  endfunction

  function automatic void put_arr(longint unsigned a, int v[], int esz);
    for (int i = 0; i < v.size(); i++)
      for (int b = 0; b < esz; b++) rmem.bd_write8(a + i * esz + b, 8'(v[i] >> (8 * b)));
  endfunction
  function automatic longint unsigned alloc_in(longint unsigned nbytes);
    longint unsigned a = ibase + 8 * $urandom_range(64);
    ibase = (a + nbytes + 8 * $urandom_range(8) + 7) & ~64'd7;
    if (ibase > 64'h1800_0000) ibase = 64'h1000_0000;
    return a;
  endfunction
  function automatic bit wwr(longint unsigned a);
    return wmem.bd_written(a);
  endfunction

  // returns CYCLES
  task automatic do_call(vcase c, output longint cycles);
    int op = opof(c), qb = (op == 3 && c.p1 != 127) ? 2 : 1;
    longint unsigned a0, a1 = 0, ao, as;
    logic [31:0] st, err, cy, d, rst, wst;
    a0 = alloc_in(4 * c.n);
    put_arr(a0, c.in0, 4);
    if (op == 1) begin a1 = alloc_in(2 * c.n); put_arr(a1, c.in1, 2); end
    if (op == 2) begin a1 = alloc_in(4 * c.n); put_arr(a1, c.in1, 4); end
    ao = obase + 16 + 8 * $urandom_range(3);
    as = (ao + c.n * qb + 16 + 8 * $urandom_range(3) + 7) & ~64'd7;
    if (op == 4) as = ao;
    obase = (as + 64 + 7) & ~64'd7;
    if ($urandom_range(15) == 0) obase = (obase | 64'hFFF) - 8 * $urandom_range(3) + 1;   // near 4 KiB
    obase = (obase + 7) & ~64'd7;
    // descriptor (random order of the writes)
    begin
      automatic int ord[$] = '{0, 1, 2, 3, 4, 5, 6, 7};
      ord.shuffle();
      foreach (ord[k])
        case (ord[k])
          0: csr_w(A_IN0, 32'(a0));
          1: if (op <= 2) csr_w(A_IN1, 32'(a1));
          2: csr_w(A_OUT, 32'(ao));
          3: if (op != 4) csr_w(A_SCL, 32'(as));
          4: csr_w(A_N, 32'(c.n));
          5: csr_w(A_FMT, {4'd0, 4'd8, 7'd0, 1'b1, 16'(op == 3 ? c.p1 : 127)});
          6: csr_w(A_EXP, {16'd0, 8'(op == 1 ? c.p0 : 0), 8'(op == 1 ? c.p2 : c.p0)});
          default: if (op == 1) csr_w(A_EPSC, c.p1);
        endcase
    end
    // wait for the previous call (busy = 0), then start
    do csr_r(A_STATUS, st); while (st[0] !== 1'b0);
    csr_w(A_CTRL, 32'((op << 4) | 1));
    do csr_r(A_STATUS, st); while (st[0] !== 1'b0);
    csr_r(A_ERR, err);
    csr_r(A_CYCLES, cy);
    csr_r(A_RDST, rst);
    csr_r(A_WRST, wst);
    cycles = cy;
    last_err = err;
    if ((err & ~32'(err_allow)) != 0 || st[1] !== 1'b1) c_err.fail($sformatf("%s: ERR 0x%0h STATUS 0x%0h", c.desc(), err, st));
    else c_err.pass();
    if (err != 0) csr_w(A_ERR, err);
    // outputs
    if (op != 4) begin
      for (int i = 0; i < c.n; i++) begin
        automatic int got = q_at(ao, i, qb);
        if (got !== c.q[i]) c_q.fail($sformatf("%s: q[%0d] %0d golden %0d", c.desc(), i, got, c.q[i]));
        else c_q.pass();
      end
      begin
        automatic logic [63:0] s = wmem.bd_read64(as);
        if (int'(s[31:0]) !== c.sm || int'(s[63:32]) !== c.se)
          c_s.fail($sformatf("%s: scale %0d %0d golden %0d %0d", c.desc(), int'(s[31:0]), int'(s[63:32]), c.sm, c.se));
        else c_s.pass();
      end
      for (int k = 1; k <= 16; k++)
        if (wwr(ao - k) || wwr(ao + c.n * qb + k - 1) || wwr(as - k) || wwr(as + 8 + k - 1))
          c_guard.fail($sformatf("%s: guard byte %0d written", c.desc(), k));
        else c_guard.pass();
    end else begin
      automatic logic [63:0] s = wmem.bd_read64(ao);
      logic [31:0] ri, rv;
      csr_r(A_AMIDX, ri);
      csr_r(A_AMVAL, rv);
      if (int'(s[31:0]) !== c.idx || int'(ri) !== c.idx || rv !== c.in0[c.idx])
        c_am.fail($sformatf("%s: idx mem %0d reg %0d val %0d golden %0d %0d", c.desc(), s[31:0], ri, rv, c.idx, c.in0[c.idx]));
      else c_am.pass();
      for (int k = 1; k <= 16; k++)
        if (wwr(ao - k) || wwr(ao + 4 + k - 1)) c_guard.fail($sformatf("%s: guard byte %0d written", c.desc(), k));
        else c_guard.pass();
    end
    begin
      automatic longint dlt = longint'(cycles) - top_cyc(c, ao, qb);
      op_n[op - 1]++;
      op_sum[op - 1] += cycles;
      if (dlt < dmin[op - 1]) dmin[op - 1] = dlt;
      if (dlt > dmax[op - 1]) dmax[op - 1] = dlt;
      // stall counters (docs/spec/vec.md 3): never above CYCLES; with no memory stall and latency
      // 1 (chk_cyc) RD_STALL is the read start-up only (RD_STALL0) and WR_STALL 0 (the write buffer
      // never fills)
      rs_sum += rst;
      ws_sum += wst;
      if (longint'(rst) < rsmin[op - 1]) rsmin[op - 1] = rst;
      if (longint'(rst) > rsmax[op - 1]) rsmax[op - 1] = rst;
      if (rst > cycles || wst > cycles)
        c_stl.fail($sformatf("%s: RD_STALL %0d / WR_STALL %0d > CYCLES %0d", c.desc(), rst, wst, cycles));
      else c_stl.pass();
      if (chk_cyc) begin
        if (rst !== RD_STALL0 || wst !== 0)
          c_stl.fail($sformatf("%s: RD_STALL %0d (model %0d) WR_STALL %0d (model 0), no memory stall",
                               c.desc(), rst, RD_STALL0, wst));
        else c_stl.pass();
      end
      if (chk_cyc) begin
        if (dlt !== 0) c_cyc.fail($sformatf("%s: CYCLES %0d, model %0d (OUT 0x%0h)", c.desc(), cycles,
                                            top_cyc(c, ao, qb), ao));
        else c_cyc.pass();
      end
    end
  endtask

  // ---------------- error paths ----------------
  task automatic expect_err(int op, int bits, string what);
    logic [31:0] err, st;
    csr_w(A_CTRL, 32'((op << 4) | 1));
    do csr_r(A_STATUS, st); while (st[0] !== 1'b0);
    csr_r(A_ERR, err);
    if (err !== 32'(bits) || st[1] !== 1'b0) c_err.fail($sformatf("%s: ERR 0x%0h exp 0x%0h STATUS 0x%0h", what, err, bits, st));
    else c_err.pass();
    csr_w(A_ERR, err);
  endtask

  task automatic err_paths();
    vcase c = new();
    longint cy;
    logic [31:0] st, e2;
    int NT = N_MAX < 100 ? N_MAX : 100;       // legal N of the template
    c.gen_syn(K_ACTQ, NT, 0);
    // legal template
    csr_w(A_IN0, 32'h1000_0000); csr_w(A_IN1, 32'h1100_0000); csr_w(A_OUT, 32'h4F00_0000);
    csr_w(A_SCL, 32'h4F10_0000); csr_w(A_N, NT); csr_w(A_FMT, 32'h0801_007F); csr_w(A_EXP, 32'h0000_0A10);
    csr_w(A_EPSC, 1000);
    expect_err(0, 2, "op 0"); expect_err(5, 2, "op 5"); expect_err(15, 2, "op 15");
    csr_w(A_N, 0); for (int op = 1; op <= 4; op++) expect_err(op, 4, "N 0");
    csr_w(A_N, N_MAX + 1); for (int op = 1; op <= 3; op++) expect_err(op, 4, "N > N_MAX");
    csr_w(A_N, (1 << IDX_W) + 1); expect_err(4, 4, "ARGMAX N > 2^IDX_W");
    csr_w(A_N, 32'h0002_0064); expect_err(3, 4, "N 2^17 + 100 (no aliasing)"); expect_err(4, 4, "ARGMAX N 2^17 + 100");
    csr_w(A_N, NT);
    csr_w(A_FMT, 32'h0800_007F); for (int op = 1; op <= 3; op++) expect_err(op, 4, "mode POW2");
    csr_w(A_FMT, 32'h0801_0080); expect_err(3, 4, "qmax 128");
    csr_w(A_FMT, 32'h0801_7FFE); expect_err(3, 4, "qmax 32766");
    csr_w(A_FMT, 32'h0701_007F); expect_err(2, 4, "sb 7");
    csr_w(A_FMT, 32'h0801_007F);
    csr_w(A_EPSC, 32'h8000_0000); expect_err(1, 4, "epsc < 0"); csr_w(A_EPSC, 1000);
    csr_w(A_IN0, 32'(64'h1_0000_0000 - 4 * NT + 8)); expect_err(3, 4, "IN0 range"); csr_w(A_IN0, 32'h1000_0000);
    csr_w(A_IN1, 32'(64'h1_0000_0000 - ((2 * NT + 7) & ~7) + 8)); expect_err(1, 4, "IN1 range (2N)"); expect_err(2, 4, "IN1 range (4N)");
    csr_w(A_IN1, 32'h1100_0000);
    csr_w(A_OUT, 32'(64'h1_0000_0000 - ((NT + 7) & ~7) + 8)); expect_err(3, 4, "OUT range");
    csr_w(A_OUT, 32'hFFFF_FFFE); expect_err(4, 12, "ARGMAX OUT range (+4 > 2^32) and misaligned");
    csr_w(A_OUT, 32'h4F00_0000);
    csr_w(A_SCL, 32'hFFFF_FFFC); expect_err(3, 12, "SCL range and misaligned");
    csr_w(A_SCL, 32'h4F10_0000);
    csr_w(A_IN0, 32'h1000_0004); expect_err(3, 8, "IN0 misaligned"); csr_w(A_IN0, 32'h1000_0000);
    csr_w(A_IN1, 32'h1100_0002); expect_err(2, 8, "IN1 misaligned"); csr_w(A_IN1, 32'h1100_0000);
    csr_w(A_OUT, 32'h4F00_0001); expect_err(4, 8, "OUT misaligned"); csr_w(A_OUT, 32'h4F00_0000);
    csr_w(A_SCL, 32'h4F10_0004); expect_err(1, 8, "SCL misaligned");
    csr_w(A_N, 0); expect_err(1, 12, "BAD_DESC and MISALIGN"); csr_w(A_N, NT);
    csr_w(A_SCL, 32'h4F10_0000);
    // START_BUSY during a call, the call still correct
    err_allow = 1;
    fork
      do_call(c, cy);
      begin
        wait (dut.busy === 1'b1);
        repeat (20) @(posedge clk);
        bfm.write0(ADDR_W'(A_CTRL), 32'h31);
      end
    join
    err_allow = 0;
    if (last_err !== 32'h1) c_err.fail($sformatf("START_BUSY: ERR 0x%0h exp 0x1", last_err));
    else c_err.pass();
    // RD_RESP and WR_RESP: the call completes, both bits set
    begin
      automatic vcase c2 = new();
      automatic longint unsigned a0;
      c2.gen_syn(K_ACTQ, 64, 0);
      a0 = alloc_in(256);
      put_arr(a0, c2.in0, 4);
      rmem.inj_rd_err(a0 + 64, a0 + 72, 2'b10);
      wmem.inj_wr_err(64'h4E00_0000, 64'h4E00_1000, 2'b11);
      csr_w(A_IN0, 32'(a0)); csr_w(A_OUT, 32'h4E00_0000); csr_w(A_SCL, 32'h4E00_0100); csr_w(A_N, 64);
      csr_w(A_FMT, {4'd0, 4'd8, 7'd0, 1'b1, 16'(c2.p1)}); csr_w(A_EXP, {16'd0, 8'd0, 8'(c2.p0)});
      csr_w(A_CTRL, 32'h31);
      do csr_r(A_STATUS, st); while (st[0] !== 1'b0);
      csr_r(A_ERR, e2);
      if (e2 !== 32'h30 || st[1] !== 1'b1) c_err.fail($sformatf("RD_RESP / WR_RESP: ERR 0x%0h STATUS 0x%0h", e2, st));
      else c_err.pass();
      for (int i = 0; i < 64; i++) begin
        automatic int got = q_at(64'h4E00_0000, i, c2.p1 == 127 ? 1 : 2);
        if (got !== c2.q[i]) c_q.fail($sformatf("RESP call: q[%0d] %0d golden %0d", i, got, c2.q[i]));
        else c_q.pass();
      end
      csr_w(A_ERR, e2);
      csr_r(A_ERR, e2);
      if (e2 !== 0) c_err.fail("ERR not cleared by W1C"); else c_err.pass();
      rmem.inj_clear();
      wmem.inj_clear();
    end
    // recovery
    begin
      automatic vcase c3 = new();
      c3.gen_syn(K_RMSNORM, NT - 3, 0);
      do_call(c3, cy);
    end
  endtask
  function automatic int q_at(longint unsigned a, int i, int qb);
    return qb == 1 ? int'($signed(wmem.bd_read8(a + i)))
                   : int'($signed({wmem.bd_read8(a + 2 * i + 1), wmem.bd_read8(a + 2 * i)}));
  endfunction

  task automatic rnd_regs();
    int regs[$] = '{A_ID, A_CONFIG, A_STATUS, A_CYCLES, A_RDST, A_WRST, A_OPS, A_AMIDX, A_AMVAL,
                    A_IN0, A_IN1, A_OUT, A_SCL, A_N, A_FMT, A_EXP, A_EPSC, 'h2C, 'h3C, 'h60, 'hFC};
    logic [31:0] d;
    for (int i = 0; i < 12; i++) begin
      int a = regs[$urandom_range(regs.size() - 1)];
      if ($urandom_range(1)) csr_r(a | $urandom_range(3), d);
      else if (a >= A_IN0) csr_w(a, $urandom());
    end
  endtask

  // ---------------- main ----------------
  initial begin
    automatic int unsigned seed;
    automatic string vec = "";
    automatic int fwd = 0, nsyn = 0, errm = 0, rnd = 0, maxd = 0, maxpos = 1 << 30, amaxn = 4096;
    automatic int nrec = 0;
    automatic longint cy;
    automatic logic [31:0] d;
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("VEC=%s", vec));
    void'($value$plusargs("FWD=%d", fwd));
    void'($value$plusargs("NSYN=%d", nsyn));
    void'($value$plusargs("AMAXN=%d", amaxn));
    void'($value$plusargs("MAXPOS=%d", maxpos));
    void'($value$plusargs("MSTALL=%d", mstall));
    void'($value$plusargs("WBLK=%d", wblk));
    void'($value$plusargs("ERR=%d", errm));
    void'($value$plusargs("RND=%d", rnd));
    void'($value$plusargs("MAXD=%d", maxd));
    void'($value$plusargs("CYC=%d", chk_cyc));
    $display("tb_vec_top: N_MAX %0d IDX_W %0d seed %0d VEC %s FWD %0d NSYN %0d MSTALL %0d WBLK %0d ERR %0d CYC %0d",
             N_MAX, IDX_W, seed, vec, fwd, nsyn, mstall, wblk, errm, chk_cyc);
    bfm.maxd = maxd;
    if (mstall) begin
      wmem.cfg_stall(0, 20, 20, 0, 20);
      wmem.cfg_lat(1, 1, 1, 12);
      rmem.cfg_stall(20, 0, 0, 25, 0);
      rmem.cfg_lat(1, 16, 1, 1);
    end
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);
    csr_r(A_ID, d);
    if (errm) err_paths();
    if (fwd) begin
      // every record of the four kernels, then the manifest order (forward)
      automatic string kn[4] = '{"rmsnorm", "swiglu", "actq", "argmax"};
      automatic vcase recs[4][$];
      automatic int fd, rc, idx, pos;
      automatic string line, kname;
      for (int k = 0; k < 4; k++) begin
        if (kd_rec_open({vec, "/", kn[k], ".bin"}) != 0) $fatal(1, "tb_vec_top: no %s records in %s", kn[k], vec);
        while (kd_rec_next() > 0) begin
          automatic vcase c = new();
          if (c.load_rec() != 0) begin c_rec.fail($sformatf("%s record %0d", kn[k], kd_rec_index())); continue; end
          c_rec.pass();
          c.tag = $sformatf("%s %0d", kn[k], c.rec);
          recs[k].push_back(c);
        end
        void'(kd_rec_close());
      end
      fd = $fopen({vec, "/manifest.txt"}, "r");
      if (fd == 0) $fatal(1, "tb_vec_top: no manifest in %s", vec);
      while ($fgets(line, fd)) begin
        automatic int kk = -1;
        if ($sscanf(line, "rec %s %d %d", kname, idx, pos) != 3) continue;
        foreach (kn[k]) if (kname == kn[k]) kk = k;
        if (kk < 0) continue;
        if (pos >= maxpos) break;
        if (idx >= recs[kk].size()) begin c_rec.fail($sformatf("manifest %s %0d beyond the records", kname, idx)); continue; end
        do_call(recs[kk][idx], cy);
        if (op_cyc[kk].exists(pos)) op_cyc[kk][pos] += cy; else op_cyc[kk][pos] = cy;
        nrec++;
        if (rnd) rnd_regs();
      end
      $fclose(fd);
    end
    for (int i = 0; i < nsyn; i++) begin
      automatic vcase c = new();
      automatic int op = i < 8 ? i / 2 : $urandom_range(3);
      automatic int kids[4] = '{K_RMSNORM, K_SWIGLU, K_ACTQ, K_ARGMAX};
      automatic int nm = op == 3 ? amaxn : N_MAX;
      automatic int n = i < 8 ? (i % 2 == 0 ? 1 : nm) : $urandom_range(3) == 0 ? $urandom_range(16, 1) : $urandom_range(nm, 1);
      c.gen_syn(kids[op], n, $urandom_range(7));
      do_call(c, cy);
      if (rnd) rnd_regs();
    end
    repeat (50) @(posedge clk);
    $display("tb_vec_top: %0d record calls, %0d synthetic, %0d starts; write buffer full %0d, packer held %0d, q FIFO full %0d cycles, %0d blocks",
             nrec, nsyn, n_starts, n_wfull, n_pkhold, n_qfull, n_blk);
    for (int k = 0; k < 4; k++)
      if (op_n[k] > 0)
        $display("tb_vec_top: op %0d: %0d calls, CYCLES sum %0d, CYCLES - model %0d..%0d, RD_STALL %0d..%0d", k + 1, op_n[k],
                 op_sum[k], dmin[k], dmax[k], rsmin[k], rsmax[k]);
    $display("tb_vec_top: RD_STALL sum %0d, WR_STALL sum %0d", rs_sum, ws_sum);
    for (int k = 0; k < 4; k++) begin
      automatic longint tot = 0, np = 0;
      automatic longint m[int] = op_cyc[k];
      foreach (m[p]) begin tot += m[p]; np++; end
      if (np > 0) $display("tb_vec_top: token sums op %0d: %0d positions, mean %0.1f CYCLES per token, position 0: %0d",
                           k + 1, np, real'(tot) / np, op_cyc[k].exists(0) ? op_cyc[k][0] : -1);
    end
    wmem.check_idle();
    begin
      automatic tb_checker_q l = '{c_err, c_guard, c_csr, c_rd};
      if (c_q.n_checks > 0) l.push_back(c_q);
      if (c_s.n_checks > 0) l.push_back(c_s);
      if (c_am.n_checks > 0) l.push_back(c_am);
      if (fwd) l.push_back(c_rec);
      if (chk_cyc) l.push_back(c_cyc);
      // memory stalls (read latency up to 16, R / AR stalls) must show up in RD_STALL, write blocks
      // (write buffer full) in WR_STALL
      if (mstall) begin
        if (rs_sum > 0) c_stl.pass();
        else c_stl.fail("memory stall run: RD_STALL 0 in every call");
      end
      if (wblk) begin
        if (ws_sum > 0) c_stl.pass();
        else c_stl.fail("write block run: WR_STALL 0 in every call");
      end
      l.push_back(c_stl);
      if (wblk) begin
        if (n_wfull > 0 && n_pkhold > 0 && n_qfull > 0) c_cov.pass();
        else c_cov.fail($sformatf("limits not reached: wfull %0d pk %0d qfull %0d", n_wfull, n_pkhold, n_qfull));
        l.push_back(c_cov);
      end
      void'(tb_final_report(l));
    end
    $finish;
  end

  initial begin
    static longint unsigned lim = 64'd300_000_000;
    void'($value$plusargs("TIMEOUT=%d", lim));
    repeat (lim) @(posedge clk);
    $fatal(1, "TB_TIMEOUT tb_vec_top");
  end

endmodule
