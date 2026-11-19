// tb_bw_top: HP bandwidth measurement top (rtl/l3/bw_top.sv) driven over AXI4-Lite by
// tb/common/axil_bfm.sv, AXI masters on one memory model per port (tb/common/axi_mem_slave.sv).
//
// Every op is checked against values the TB computes on its own (docs/spec/bwtest.md):
//   csum     RD: XOR and SUM (mod 2^64) of the 64-bit words of [RD_ADDRp, RD_ADDRp + LEN) read
//            from the memory model through the backdoor, bytes beyond LEN in the last word = 0
//   wmem     WR: memory [WR_ADDRp, + LEN) == pattern {SEED_HI ^ p, SEED_LO} + k * INC, 8 guard
//            bytes on both sides unchanged (random prefill)
//   cycles   s = cycle after the later AW / W handshake of the CTRL write (BFM). From the AXI
//            buses: e_rd = last R handshake + 1, e_wr = last B handshake. CYCLES = max(e) - s,
//            RD_CYCp = e_rd - s, WR_CYCp = e_wr - s, RD_STALLp = RD_CYCp - 1 - beats,
//            RD_BEATSp / WR_BEATSp = ceil(LEN / 8), WR_STALLp <= WR_CYCp, 0x18 / 0x1C = port 0
//   csr      reset values, ID, CONFIG, read-back of the R/W registers, 0 for unused addresses,
//            STATUS (busy, done_sticky, err_any), ERR bits (W1C), OPS
//   err      START_BUSY, BAD_OP, BAD_DESC (each rule), RD_RESP / WR_RESP (injected SLVERR /
//            DECERR), ENG_CMD (range past 2^32); the op still finishes where the spec says so
// Plusargs: +SEED +PROF=<0|1|2> (memory stalls/latency) +MAXD (AXI-Lite gaps) +N_OP
`timescale 1ns / 1ps
module tb_bw_top #(
  parameter int P         = 1,
  parameter int MAX_BURST = 16,
  parameter int OUTS      = 4
);
  import tb_util_pkg::*;

  localparam int IDW = 1, AW_L = 12;
  localparam logic [63:0] INC = 64'h9E37_79B9_7F4A_7C15;
  localparam longint unsigned RBASE = 64'h1000_0000, WBASE = 64'h2000_0000, SPAN = 64'h2_0000;
  // register byte offsets
  localparam int A_ID = 'h00, A_CONFIG = 'h04, A_CTRL = 'h08, A_STATUS = 'h0C, A_ERR = 'h10,
                 A_CYCLES = 'h14, A_RDSTALL = 'h18, A_WRSTALL = 'h1C, A_OPS = 'h20, A_LEN = 'h40,
                 A_BURST = 'h44, A_OUTS = 'h48, A_PORTS = 'h4C, A_SEEDLO = 'h50, A_SEEDHI = 'h54,
                 A_RDADDR0 = 'h60, A_WRADDR0 = 'h68;
  function automatic int a_res(int p, int i); return 'h80 + 'h20 * p + 4 * i; endfunction
  function automatic int a_rdbeats(int p); return 'hC0 + 8 * p; endfunction
  function automatic int a_wrbeats(int p); return 'hC4 + 8 * p; endfunction

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  // AXI-Lite
  logic [AW_L-1:0] awaddr, araddr;
  logic [2:0] awprot, arprot;
  logic awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;
  logic [31:0] wdata, rdata;
  logic [3:0] wstrb;
  logic [1:0] bresp, rresp;

  axil_bfm #(.ADDR_W(AW_L)) bfm (.clk, .rst_n, .awaddr, .awprot, .awvalid, .awready, .wdata,
    .wstrb, .wvalid, .wready, .bresp, .bvalid, .bready, .araddr, .arprot, .arvalid, .arready,
    .rdata, .rresp, .rvalid, .rready);

  // AXI masters (two ports always present in the TB; port 1 idle when P = 1)
  logic [1:0][IDW-1:0] m_awid, m_arid, m_bid, m_rid;
  logic [1:0][31:0] m_awaddr, m_araddr;
  logic [1:0][7:0] m_awlen, m_arlen, m_wstrb;
  logic [1:0][2:0] m_awsize, m_arsize, m_awprot, m_arprot;
  logic [1:0][1:0] m_awburst, m_arburst, m_bresp, m_rresp;
  logic [1:0][3:0] m_awcache, m_arcache, m_awqos, m_arqos;
  logic [1:0] m_awlock, m_arlock, m_awvalid, m_awready, m_wlast, m_wvalid, m_wready, m_bvalid,
              m_bready, m_arvalid, m_arready, m_rlast, m_rvalid, m_rready;
  logic [1:0][63:0] m_wdata, m_rdata;

  bw_top #(.P(P), .MAX_BURST(MAX_BURST), .OUTS(OUTS), .IDW(IDW), .FCLK_MHZ(100), .ADDR_W(AW_L)) dut (
    .clk, .rst_n,
    .s_axi_awaddr_i(awaddr), .s_axi_awprot_i(awprot), .s_axi_awvalid_i(awvalid), .s_axi_awready_o(awready),
    .s_axi_wdata_i(wdata), .s_axi_wstrb_i(wstrb), .s_axi_wvalid_i(wvalid), .s_axi_wready_o(wready),
    .s_axi_bresp_o(bresp), .s_axi_bvalid_o(bvalid), .s_axi_bready_i(bready),
    .s_axi_araddr_i(araddr), .s_axi_arprot_i(arprot), .s_axi_arvalid_i(arvalid), .s_axi_arready_o(arready),
    .s_axi_rdata_o(rdata), .s_axi_rresp_o(rresp), .s_axi_rvalid_o(rvalid), .s_axi_rready_i(rready),
    .m_axi_awid_o(m_awid[P-1:0]), .m_axi_awaddr_o(m_awaddr[P-1:0]), .m_axi_awlen_o(m_awlen[P-1:0]),
    .m_axi_awsize_o(m_awsize[P-1:0]), .m_axi_awburst_o(m_awburst[P-1:0]), .m_axi_awlock_o(m_awlock[P-1:0]),
    .m_axi_awcache_o(m_awcache[P-1:0]), .m_axi_awprot_o(m_awprot[P-1:0]), .m_axi_awqos_o(m_awqos[P-1:0]),
    .m_axi_awvalid_o(m_awvalid[P-1:0]), .m_axi_awready_i(m_awready[P-1:0]),
    .m_axi_wdata_o(m_wdata[P-1:0]), .m_axi_wstrb_o(m_wstrb[P-1:0]), .m_axi_wlast_o(m_wlast[P-1:0]),
    .m_axi_wvalid_o(m_wvalid[P-1:0]), .m_axi_wready_i(m_wready[P-1:0]),
    .m_axi_bid_i(m_bid[P-1:0]), .m_axi_bresp_i(m_bresp[P-1:0]), .m_axi_bvalid_i(m_bvalid[P-1:0]),
    .m_axi_bready_o(m_bready[P-1:0]),
    .m_axi_arid_o(m_arid[P-1:0]), .m_axi_araddr_o(m_araddr[P-1:0]), .m_axi_arlen_o(m_arlen[P-1:0]),
    .m_axi_arsize_o(m_arsize[P-1:0]), .m_axi_arburst_o(m_arburst[P-1:0]), .m_axi_arlock_o(m_arlock[P-1:0]),
    .m_axi_arcache_o(m_arcache[P-1:0]), .m_axi_arprot_o(m_arprot[P-1:0]), .m_axi_arqos_o(m_arqos[P-1:0]),
    .m_axi_arvalid_o(m_arvalid[P-1:0]), .m_axi_arready_i(m_arready[P-1:0]),
    .m_axi_rid_i(m_rid[P-1:0]), .m_axi_rdata_i(m_rdata[P-1:0]), .m_axi_rresp_i(m_rresp[P-1:0]),
    .m_axi_rlast_i(m_rlast[P-1:0]), .m_axi_rvalid_i(m_rvalid[P-1:0]), .m_axi_rready_o(m_rready[P-1:0]));

  if (P == 1) begin : g_idle1  // port 1 of the TB is not connected to the DUT
    assign m_awid[1] = '0; assign m_awaddr[1] = '0; assign m_awlen[1] = '0; assign m_awsize[1] = 3'd3;
    assign m_awburst[1] = 2'b01; assign m_awvalid[1] = 1'b0; assign m_wdata[1] = '0; assign m_wstrb[1] = '0;
    assign m_wlast[1] = 1'b0; assign m_wvalid[1] = 1'b0; assign m_bready[1] = 1'b1; assign m_arid[1] = '0;
    assign m_araddr[1] = '0; assign m_arlen[1] = '0; assign m_arsize[1] = 3'd3; assign m_arburst[1] = 2'b01;
    assign m_arvalid[1] = 1'b0; assign m_rready[1] = 1'b1;
  end

  axi_mem_slave #(.DW(64), .AW(32), .IDW(IDW), .MAX_LEN(MAX_BURST - 1), .MAX_OUTS(16), .NAME("mem0")) mem0 (
    .clk, .rst_n,
    .awid_i(m_awid[0]), .awaddr_i(m_awaddr[0]), .awlen_i(m_awlen[0]), .awsize_i(m_awsize[0]),
    .awburst_i(m_awburst[0]), .awvalid_i(m_awvalid[0]), .awready_o(m_awready[0]),
    .wdata_i(m_wdata[0]), .wstrb_i(m_wstrb[0]), .wlast_i(m_wlast[0]), .wvalid_i(m_wvalid[0]), .wready_o(m_wready[0]),
    .bid_o(m_bid[0]), .bresp_o(m_bresp[0]), .bvalid_o(m_bvalid[0]), .bready_i(m_bready[0]),
    .arid_i(m_arid[0]), .araddr_i(m_araddr[0]), .arlen_i(m_arlen[0]), .arsize_i(m_arsize[0]),
    .arburst_i(m_arburst[0]), .arvalid_i(m_arvalid[0]), .arready_o(m_arready[0]),
    .rid_o(m_rid[0]), .rdata_o(m_rdata[0]), .rresp_o(m_rresp[0]), .rlast_o(m_rlast[0]),
    .rvalid_o(m_rvalid[0]), .rready_i(m_rready[0]));
  axi_mem_slave #(.DW(64), .AW(32), .IDW(IDW), .MAX_LEN(MAX_BURST - 1), .MAX_OUTS(16), .NAME("mem1")) mem1 (
    .clk, .rst_n,
    .awid_i(m_awid[1]), .awaddr_i(m_awaddr[1]), .awlen_i(m_awlen[1]), .awsize_i(m_awsize[1]),
    .awburst_i(m_awburst[1]), .awvalid_i(m_awvalid[1]), .awready_o(m_awready[1]),
    .wdata_i(m_wdata[1]), .wstrb_i(m_wstrb[1]), .wlast_i(m_wlast[1]), .wvalid_i(m_wvalid[1]), .wready_o(m_wready[1]),
    .bid_o(m_bid[1]), .bresp_o(m_bresp[1]), .bvalid_o(m_bvalid[1]), .bready_i(m_bready[1]),
    .arid_i(m_arid[1]), .araddr_i(m_araddr[1]), .arlen_i(m_arlen[1]), .arsize_i(m_arsize[1]),
    .arburst_i(m_arburst[1]), .arvalid_i(m_arvalid[1]), .arready_o(m_arready[1]),
    .rid_o(m_rid[1]), .rdata_o(m_rdata[1]), .rresp_o(m_rresp[1]), .rlast_o(m_rlast[1]),
    .rvalid_o(m_rvalid[1]), .rready_i(m_rready[1]));

  tb_checker c_csum = new("csum"), c_wmem = new("wmem"), c_cyc = new("cycles"), c_csr = new("csr"),
             c_err = new("err");

  // ---------------- memory helpers (port 0 / 1 memory) ----------------
  function automatic byte unsigned mrd(int p, longint unsigned a);
    return p == 0 ? mem0.bd_read8(a) : mem1.bd_read8(a);
  endfunction
  function automatic void mwr(int p, longint unsigned a, byte unsigned v);
    if (p == 0) mem0.bd_write8(a, v); else mem1.bd_write8(a, v);
  endfunction

  // ---------------- bus monitor: last R / B handshake per port ----------------
  longint unsigned last_r[2], last_b[2], n_r[2], n_w[2];
  always @(negedge clk) if (rst_n)
    for (int p = 0; p < 2; p++) begin
      if (m_rvalid[p] && m_rready[p]) begin last_r[p] = bfm.cyc; n_r[p]++; end
      if (m_bvalid[p] && m_bready[p]) last_b[p] = bfm.cyc;
      if (m_wvalid[p] && m_wready[p]) n_w[p]++;
    end

  // ---------------- CSR helpers ----------------
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

  // ---------------- op model ----------------
  typedef struct {
    int op;                     // 1 RD, 2 WR, 3 RW
    longint unsigned len;
    int burst, outs, ports;
    longint unsigned ra[2], wa[2];
    logic [31:0] seed_lo, seed_hi;
  } op_t;

  logic [31:0] ops_exp = 0;

  function automatic logic [63:0] pat(int p, op_t o, longint unsigned k);
    logic [63:0] d = {o.seed_hi ^ 32'(p), o.seed_lo};
    return d + 64'(k) * INC;
  endfunction

  task automatic prog_regs(op_t o);
    wr(A_LEN, 32'(o.len));
    wr(A_BURST, 32'(o.burst));
    wr(A_OUTS, 32'(o.outs));
    wr(A_PORTS, 32'(o.ports));
    wr(A_SEEDLO, o.seed_lo);
    wr(A_SEEDHI, o.seed_hi);
    for (int p = 0; p < 2; p++) begin
      wr(A_RDADDR0 + 4 * p, 32'(o.ra[p]));
      wr(A_WRADDR0 + 4 * p, 32'(o.wa[p]));
    end
  endtask

  // run one legal op and check every result; exp_err: ERR bits expected at the end
  task automatic run_op(op_t o, logic [5:0] exp_err = 6'd0);
    longint unsigned t_hs, s, e_rd[2], e_wr[2], e_max, nb;
    logic [31:0] d, st;
    bit use_rd, use_wr;
    logic [63:0] x_exp[2], s_exp[2];
    byte unsigned guard[2][16];
    nb = (o.len + 7) / 8;
    use_rd = o.op[0];
    use_wr = o.op[1];
    for (int p = 0; p < P; p++) begin
      x_exp[p] = '0;
      s_exp[p] = '0;
      if (use_rd && o.ports[p])
        for (longint unsigned k = 0; k < nb; k++) begin
          logic [63:0] w = '0;
          for (int b = 0; b < 8; b++)
            if (8 * k + b < o.len) w[8*b +: 8] = mrd(p, o.ra[p] + 8 * k + b);
          x_exp[p] ^= w;
          s_exp[p] += w;
        end
      for (int b = 0; b < 8; b++) begin
        guard[p][b] = mrd(p, o.wa[p] - 8 + b);
        guard[p][8 + b] = mrd(p, o.wa[p] + o.len + b);
      end
      last_r[p] = 0; last_b[p] = 0; n_r[p] = 0; n_w[p] = 0;
    end
    prog_regs(o);
    bfm.write(AW_L'(A_CTRL), {26'd0, 2'(o.op), 3'd0, 1'b1}, t_hs);
    s = t_hs + 1;
    // poll STATUS (busy, then done_sticky)
    do rd(A_STATUS, st); while (st[0] === 1'b1);
    if (st[1] !== 1'b1 || st[2] !== (exp_err != 0))
      c_csr.fail($sformatf("STATUS after op %h (exp done 1 err_any %b)", st, exp_err != 0));
    else c_csr.pass();
    ops_exp++;
    expect_reg(A_OPS, ops_exp, "OPS", c_csr);
    expect_reg(A_ERR, {26'd0, exp_err}, "ERR after op", c_err);
    if (exp_err != 0) wr(A_ERR, 32'h3F);
    e_max = s;
    for (int p = 0; p < P; p++) begin
      bit on_rd, on_wr;
      on_rd = use_rd && o.ports[p];
      on_wr = use_wr && o.ports[p];
      e_rd[p] = last_r[p] + 1;
      e_wr[p] = last_b[p];
      if (on_rd && e_rd[p] > e_max) e_max = e_rd[p];
      if (on_wr && e_wr[p] > e_max) e_max = e_wr[p];
      // checksums
      if (on_rd) begin
        expect_reg(a_res(p, 0), x_exp[p][31:0], $sformatf("XOR_LO p%0d", p), c_csum);
        expect_reg(a_res(p, 1), x_exp[p][63:32], $sformatf("XOR_HI p%0d", p), c_csum);
        expect_reg(a_res(p, 2), s_exp[p][31:0], $sformatf("SUM_LO p%0d", p), c_csum);
        expect_reg(a_res(p, 3), s_exp[p][63:32], $sformatf("SUM_HI p%0d", p), c_csum);
        expect_reg(a_res(p, 4), 32'(e_rd[p] - s), $sformatf("RD_CYC p%0d", p), c_cyc);
        expect_reg(a_res(p, 6), 32'(e_rd[p] - s - 1 - nb), $sformatf("RD_STALL p%0d", p), c_cyc);
        expect_reg(a_rdbeats(p), 32'(nb), $sformatf("RD_BEATS p%0d", p), c_cyc);
        if (n_r[p] != nb) c_cyc.fail($sformatf("p%0d R beats on the bus %0d, expected %0d", p, n_r[p], nb));
        if (p == 0) begin
          rd(a_res(0, 6), d);
          expect_reg(A_RDSTALL, d, "RD_STALL mirror", c_csr);
        end
      end else begin
        expect_reg(a_res(p, 0), 32'd0, $sformatf("XOR_LO idle p%0d", p), c_csum);
        expect_reg(a_res(p, 4), 32'd0, $sformatf("RD_CYC idle p%0d", p), c_cyc);
        expect_reg(a_rdbeats(p), 32'd0, $sformatf("RD_BEATS idle p%0d", p), c_cyc);
      end
      if (on_wr) begin
        expect_reg(a_res(p, 5), 32'(e_wr[p] - s), $sformatf("WR_CYC p%0d", p), c_cyc);
        expect_reg(a_wrbeats(p), 32'(nb), $sformatf("WR_BEATS p%0d", p), c_cyc);
        rd(a_res(p, 7), d);
        if (d > 32'(e_wr[p] - s)) c_cyc.fail($sformatf("WR_STALL p%0d %0d > WR_CYC", p, d));
        else c_cyc.pass();
        if (p == 0) expect_reg(A_WRSTALL, d, "WR_STALL mirror", c_csr);
        begin
          int bad = 0;
          for (longint unsigned k = 0; k < nb; k++) begin
            logic [63:0] e = pat(p, o, k);
            for (int b = 0; b < 8; b++) if (8 * k + b < o.len) begin
              byte unsigned m = mrd(p, o.wa[p] + 8 * k + b);
              if (m !== e[8*b +: 8]) begin
                bad++;
                c_wmem.fail($sformatf("p%0d byte 0x%0h = %h, pattern %h", p, o.wa[p] + 8 * k + b, m, e[8*b +: 8]));
              end else c_wmem.pass();
            end
          end
        end
        for (int b = 0; b < 8; b++) begin
          if (mrd(p, o.wa[p] - 8 + b) !== guard[p][b] || mrd(p, o.wa[p] + o.len + b) !== guard[p][8 + b])
            c_wmem.fail($sformatf("p%0d guard byte %0d changed", p, b));
          else c_wmem.pass();
        end
      end else begin
        expect_reg(a_res(p, 5), 32'd0, $sformatf("WR_CYC idle p%0d", p), c_cyc);
        expect_reg(a_wrbeats(p), 32'd0, $sformatf("WR_BEATS idle p%0d", p), c_cyc);
      end
    end
    expect_reg(A_CYCLES, 32'(e_max - s), "CYCLES", c_cyc);
    $display("OP op %0d len %0d burst %0d outs %0d ports %0d: CYCLES %0d", o.op, o.len, o.burst,
             o.outs, o.ports, e_max - s);
  endtask

  // ---------------- random op ----------------
  function automatic op_t rnd_op();
    op_t o;
    o.op = $urandom_range(3, 1);
    case ($urandom_range(5))
      0: o.len = $urandom_range(16, 1);
      1: o.len = $urandom_range(512, 1);
      2: o.len = 4096 + 8 * $urandom_range(2) - 8;
      3: o.len = $urandom_range(65536, 1);
      default: o.len = $urandom_range(16384, 1);
    endcase
    o.burst = $urandom_range(2) == 0 ? $urandom_range(MAX_BURST, 1) : MAX_BURST;
    o.outs = $urandom_range(OUTS, 1);
    o.ports = P == 1 ? 1 : $urandom_range(3, 1);
    for (int p = 0; p < 2; p++) begin
      o.ra[p] = RBASE + 8 * $urandom_range(int'((SPAN - o.len) / 8) - 2, 1);
      o.wa[p] = WBASE + 8 * $urandom_range(int'((SPAN - o.len) / 8) - 2, 1);
    end
    o.seed_lo = $urandom;
    o.seed_hi = $urandom;
    return o;
  endfunction

  function automatic op_t base_op(int op, longint unsigned len);
    op_t o = rnd_op();
    o.op = op; o.len = len; o.burst = MAX_BURST; o.outs = OUTS; o.ports = P == 1 ? 1 : 3;
    for (int p = 0; p < 2; p++) begin
      o.ra[p] = RBASE + 4096;
      o.wa[p] = WBASE + 4096 + 8 * p;
    end
    return o;
  endfunction

  // ---------------- CSR and error tests ----------------
  int unused_a[] = '{'h24, 'h3C, 'h58, 'h70, 'h7C, 'hD0, 'hFC, 'h100, 'h800, 'hFFC};
  longint unsigned dir_len[] = '{1, 7, 8, 9, 15, 16, 17, 8 * MAX_BURST - 1, 8 * MAX_BURST,
                                 8 * MAX_BURST + 1, 4095, 4096, 4097, 65536};

  task automatic csr_tests();
    expect_reg(A_ID, 32'h4257_0001, "ID", c_csr);
    expect_reg(A_CONFIG, {3'd0, 9'(MAX_BURST), 8'(OUTS), 4'(P), 8'd100}, "CONFIG", c_csr);
    expect_reg(A_STATUS, 32'd0, "STATUS reset", c_csr);
    expect_reg(A_ERR, 32'd0, "ERR reset", c_csr);
    expect_reg(A_CYCLES, 32'd0, "CYCLES reset", c_csr);
    expect_reg(A_OPS, 32'd0, "OPS reset", c_csr);
    expect_reg(A_LEN, 32'd0, "LEN reset", c_csr);
    expect_reg(A_BURST, 32'(MAX_BURST), "BURST reset", c_csr);
    expect_reg(A_OUTS, 32'(OUTS), "OUTS reset", c_csr);
    expect_reg(A_PORTS, 32'd1, "PORTS reset", c_csr);
    // read-back (field widths)
    wr(A_LEN, 32'hDEAD_BEEF);    expect_reg(A_LEN, 32'hDEAD_BEEF, "LEN rb", c_csr);
    wr(A_BURST, 32'hFFFF_FFFF);  expect_reg(A_BURST, 32'h1FF, "BURST rb", c_csr);
    wr(A_OUTS, 32'hFFFF_FFFF);   expect_reg(A_OUTS, 32'h7F, "OUTS rb", c_csr);
    wr(A_PORTS, 32'hFFFF_FFFF);  expect_reg(A_PORTS, 32'h3, "PORTS rb", c_csr);
    wr(A_SEEDLO, 32'h1234_5678); expect_reg(A_SEEDLO, 32'h1234_5678, "SEED_LO rb", c_csr);
    wr(A_SEEDHI, 32'h9ABC_DEF0); expect_reg(A_SEEDHI, 32'h9ABC_DEF0, "SEED_HI rb", c_csr);
    for (int i = 0; i < 4; i++) begin
      wr(A_RDADDR0 + 4 * i, 32'hA000_0000 + i);
      expect_reg(A_RDADDR0 + 4 * i, 32'hA000_0000 + i, "ADDR rb", c_csr);
    end
    // read-only and unused addresses
    wr(A_ID, 32'h0); expect_reg(A_ID, 32'h4257_0001, "ID after write", c_csr);
    wr(A_CYCLES, 32'h55); expect_reg(A_CYCLES, 32'd0, "CYCLES after write", c_csr);
    expect_reg(A_CTRL, 32'd0, "CTRL reads 0", c_csr);
    foreach (unused_a[i]) begin
      int a;
      a = unused_a[i];
      wr(a, 32'hFFFF_FFFF);
      expect_reg(a, 32'd0, "unused address", c_csr);
    end
    if (P == 1) begin  // port 1 results do not exist
      expect_reg(a_res(1, 0), 32'd0, "port 1 block (P = 1)", c_csr);
      expect_reg(a_rdbeats(1), 32'd0, "port 1 beats (P = 1)", c_csr);
    end
  endtask

  task automatic expect_err_only(logic [5:0] e, string what);
    expect_reg(A_ERR, {26'd0, e}, what, c_err);
    expect_reg(A_STATUS, {29'd0, e != 0, 1'b0, 1'b0}, {what, " STATUS"}, c_err);
    wr(A_ERR, {26'd0, e});
    expect_reg(A_ERR, 32'd0, {what, " W1C"}, c_err);
  endtask

  task automatic err_tests();
    op_t o;
    logic [31:0] st;
    longint unsigned t;
    // bad op
    o = base_op(1, 64); prog_regs(o);
    wr(A_CTRL, 32'h01);                        expect_err_only(6'b000010, "BAD_OP");
    // descriptor rules
    o = base_op(1, 0); prog_regs(o);
    wr(A_CTRL, 32'h11);                        expect_err_only(6'b000100, "BAD_DESC len 0");
    o = base_op(1, 64); o.burst = 0; prog_regs(o);
    wr(A_CTRL, 32'h11);                        expect_err_only(6'b000100, "BAD_DESC burst 0");
    o = base_op(1, 64); o.burst = MAX_BURST + 1; prog_regs(o);
    wr(A_CTRL, 32'h11);                        expect_err_only(6'b000100, "BAD_DESC burst > MAX");
    o = base_op(1, 64); o.outs = 0; prog_regs(o);
    wr(A_CTRL, 32'h11);                        expect_err_only(6'b000100, "BAD_DESC outs 0");
    o = base_op(1, 64); o.outs = OUTS + 1; prog_regs(o);
    wr(A_CTRL, 32'h11);                        expect_err_only(6'b000100, "BAD_DESC outs > OUTS");
    o = base_op(1, 64); o.ports = 0; prog_regs(o);
    wr(A_CTRL, 32'h11);                        expect_err_only(6'b000100, "BAD_DESC ports 0");
    if (P == 1) begin
      o = base_op(1, 64); o.ports = 2; prog_regs(o);
      wr(A_CTRL, 32'h11);                      expect_err_only(6'b000100, "BAD_DESC port 1 (P = 1)");
    end
    o = base_op(1, 64); o.ra[0] += 4; prog_regs(o);
    wr(A_CTRL, 32'h11);                        expect_err_only(6'b000100, "BAD_DESC rd misaligned");
    o = base_op(2, 64); o.wa[P - 1] += 2; prog_regs(o);
    wr(A_CTRL, 32'h21);                        expect_err_only(6'b000100, "BAD_DESC wr misaligned");
    o = base_op(2, 64); o.ra[0] += 4; prog_regs(o);  // read address unused by a WR op: legal
    run_op(o);
    // CTRL write with start = 0 clears done_sticky only
    wr(A_CTRL, 32'h10);
    expect_reg(A_STATUS, 32'd0, "STATUS after CTRL start=0", c_csr);
    // start while busy: START_BUSY, the running op is unaffected
    o = base_op(3, 32768); o.outs = 1; o.burst = 1;
    run_busy(o);
    // range past 2^32 is a descriptor error (no op, engines never see it); ending exactly at
    // 2^32 is legal (not run here: the memory model has no data there)
    o = base_op(1, 16); o.ra[0] = 64'hFFFF_FFF8; o.ports = 1; prog_regs(o);
    wr(A_CTRL, 32'h11);                        expect_err_only(6'b000100, "BAD_DESC rd past 2^32");
    o = base_op(2, 24); o.wa[0] = 64'hFFFF_FFF0; o.ports = 1; prog_regs(o);
    wr(A_CTRL, 32'h21);                        expect_err_only(6'b000100, "BAD_DESC wr past 2^32");
    o = base_op(3, 16); o.ra[0] = 64'hFFFF_FFF8; o.wa[0] = 64'hFFFF_FFF0; o.ports = 1; prog_regs(o);
    wr(A_CTRL, 32'h01 | 32'h30);               expect_err_only(6'b000100, "BAD_DESC rw past 2^32");
    // injected error responses
    o = base_op(3, 1024);
    mem0.inj_rd_err(o.ra[0] + 256, o.ra[0] + 264, 2'b10);
    mem0.inj_wr_err(o.wa[0] + 512, o.wa[0] + 520, 2'b11);
    if (P == 2) begin
      mem1.inj_rd_err(o.ra[1] + 8, o.ra[1] + 16, 2'b11);
      mem1.inj_wr_err(o.wa[1], o.wa[1] + 8, 2'b10);
    end
    run_op(o, 6'b011000);
    mem0.inj_clear();
    mem1.inj_clear();
    run_op(base_op(3, 1024));                  // errors gone, sticky cleared by the start
  endtask

  // op with a second start while it runs
  task automatic run_busy(op_t o);
    logic [31:0] st;
    fork
      run_op(o, 6'b000001);
      begin
        do rd(A_STATUS, st); while (st[0] !== 1'b1);
        repeat (50) @(posedge clk);
        wr(A_CTRL, 32'h11);                    // start while busy
        rd(A_STATUS, st);
        if (st[0] !== 1'b1 || st[2] !== 1'b1) c_err.fail($sformatf("STATUS while busy %h", st));
        else c_err.pass();
      end
    join
  endtask

  // ---------------- main ----------------
  initial begin
    int unsigned seed;
    int prof, n_op, maxd;
    prof = 1; n_op = 40; maxd = 2;
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("PROF=%d", prof));
    void'($value$plusargs("N_OP=%d", n_op));
    void'($value$plusargs("MAXD=%d", maxd));
    $display("tb_bw_top: SEED %0d P %0d MAX_BURST %0d OUTS %0d PROF %0d N_OP %0d MAXD %0d",
             seed, P, MAX_BURST, OUTS, prof, n_op, maxd);
    case (prof)
      0: begin mem0.cfg_stall(0, 0, 0, 0, 0); mem0.cfg_lat(1, 1, 1, 1); mem1.cfg_stall(0, 0, 0, 0, 0); mem1.cfg_lat(1, 1, 1, 1); end
      1: begin mem0.cfg_stall(20, 20, 20, 20, 20); mem0.cfg_lat(1, 30, 1, 20); mem1.cfg_stall(30, 10, 30, 10, 30); mem1.cfg_lat(5, 40, 1, 10); end
      default: begin mem0.cfg_stall(60, 60, 60, 60, 60); mem0.cfg_lat(1, 60, 1, 40); mem1.cfg_stall(50, 50, 50, 50, 50); mem1.cfg_lat(1, 80, 1, 40); end
    endcase
    for (longint unsigned i = 0; i < SPAN; i += 8) begin
      mem0.bd_write64(RBASE + i, {$urandom, $urandom}); mem0.bd_write64(WBASE + i, {$urandom, $urandom});
      mem1.bd_write64(RBASE + i, {$urandom, $urandom}); mem1.bd_write64(WBASE + i, {$urandom, $urandom});
    end
    mem0.cfg_uninit_err(1'b1);
    mem1.cfg_uninit_err(1'b1);
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    repeat (3) @(posedge clk);
    bfm.maxd = maxd;

    csr_tests();
    // directed lengths around the beat and 4 KiB edges, every op, all ports
    foreach (dir_len[i])
      for (int op = 1; op <= 3; op++) run_op(base_op(op, dir_len[i]));
    err_tests();
    for (int i = 0; i < n_op; i++) run_op(rnd_op());

    expect_reg(A_STATUS, 32'h2, "STATUS end", c_csr);
    mem0.check_idle();
    mem1.check_idle();
    mem0.report();
    mem1.report();
    $display("tb_bw_top: ops %0d, AXI-Lite writes %0d reads %0d", ops_exp, bfm.n_wr, bfm.n_rd);
    void'(tb_final_report('{c_csum, c_wmem, c_cyc, c_csr, c_err}));
    $finish;
  end

  initial begin
    #2s;
    $error("TB_TIMEOUT global");
    $finish;
  end

endmodule
