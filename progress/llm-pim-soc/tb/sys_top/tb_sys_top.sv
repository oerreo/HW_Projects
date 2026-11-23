// tb_sys_top: smoke testbench of the L4 system tops sys_a_top (BUILD 0) and sys_p_top (BUILD 1),
// S5-2. The DUT is a black box: AXI4-Lite master BFM (tb/common/axil_bfm.sv, 16-bit addresses) on
// s_axi, one AXI memory model (tb/common/axi_mem_slave.sv) per HP port with its own contents (no
// shared memory: calls that need two HP ports to see the same buffer are left to S5-3).
//
// Variants (VAR): 0 the build defaults (no parameter override), 1 build A2 (GA_P 2, HP2 read =
// gemv_acc slice 1) or build PD (AT_KV_SRC 1, DDR KV over HP1 / HP2), 2 the build defaults with
// XB_REG 0 (pass-through xbar).
//
// Checks:
//  (a) slot map: ID, CONFIG (and CONFIG2 / CONFIG3 for pim / attn) of every slot 0..15 against the
//      values of the register maps (docs/spec/gemv_acc.md, pim.md, attn.md, vec.md) with the build
//      parameters of docs/spec/system.md 1.2 written in this TB (not taken from the RTL); absent
//      slots read 0 at every probed offset; writes to absent slots are ignored (they reach no IP:
//      the descriptor registers at 0x40 of every present IP still read 0).
//  (b) one call per IP, result == golden model (DPI-C, tb/dpi/kdpi.c):
//      gemv_acc: synthetic GEMV (odd rows, y_en + argmax_en), y == kd_gemv1 per row, ARGMAX_IDX /
//        ARGMAX_VAL == kd_argmax; A2: x on HP0 and HP2, even rows only in the HP0 memory, odd rows
//        only in the HP2 memory (garbage at the other rows)
//      pim: LDW + WRGB + MACAB in one RUN, y == kd_bank_syn, ST_WRGB / ST_MAC / ST_RDMAC and the
//        command counters
//      attn: K_ATTN2 records (+VEC_AT) of the first NGRP (position, layer) groups in forward order
//        (BRAM KV: KVW of every new position first), p_en 1: o and p of every head == record; with
//        H_PAR 2 the q records (and with KV_SRC 1 the KV of a kv head) are only in the memory of the
//        HP port of the engine that serves them (head h -> engine (h / KVMUL) mod 2 -> HP1 / HP2),
//        garbage at the same addresses in the other memory
//      vec: ACTQ (q, scale) and ARGMAX (idx in memory and ARGMAX_IDX / ARGMAX_VAL), kd_vec_*
//      after every call: STATUS done_sticky, ERR == 0, guard bytes around every output unwritten.
//  (c) HP port assignment: during every call only the expected HP ports see read / write bursts
//      (axi_mem_slave burst counters before / after the call), and the unused channel sets stay
//      tied off every cycle (VALID 0, READY 1, other outputs 0).
// Plusargs: +SEED +MAXD (AXI-Lite gaps) +VEC_AT=<record dir> +NGRP (attention groups).
`timescale 1ns / 1ps
module tb_sys_top;
  import tb_util_pkg::*;
  import kdpi_pkg::*;
  import attn_tb_pkg::*;
  import vec_tb_pkg::*;

  parameter int BUILD = 0;   // 0 sys_a_top, 1 sys_p_top
  parameter int VAR   = 0;   // 0 defaults, 1 A2 / PD, 2 XB_REG 0

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;
  longint cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // ---------------- AXI4-Lite ----------------
  logic [15:0] awaddr, araddr;
  logic [2:0]  awprot, arprot;
  logic        awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;
  logic [31:0] wdata, rdata;
  logic [3:0]  wstrb;
  logic [1:0]  bresp, rresp;

  axil_bfm #(.ADDR_W(16)) bfm (
    .clk, .rst_n, .awaddr, .awprot, .awvalid, .awready, .wdata, .wstrb, .wvalid, .wready,
    .bresp, .bvalid, .bready, .araddr, .arprot, .arvalid, .arready, .rdata, .rresp, .rvalid, .rready);

  // ---------------- HP ports (index = HP port) ----------------
  logic [3:0][0:0]  hp_awid, hp_bid, hp_arid, hp_rid;
  logic [3:0][31:0] hp_awaddr, hp_araddr;
  logic [3:0][7:0]  hp_awlen, hp_arlen, hp_wstrb;
  logic [3:0][2:0]  hp_awsize, hp_awprot, hp_arsize, hp_arprot;
  logic [3:0][1:0]  hp_awburst, hp_arburst, hp_bresp, hp_rresp;
  logic [3:0][3:0]  hp_awcache, hp_awqos, hp_arcache, hp_arqos;
  logic [3:0]       hp_awlock, hp_awvalid, hp_awready, hp_wlast, hp_wvalid, hp_wready;
  logic [3:0]       hp_bvalid, hp_bready, hp_arlock, hp_arvalid, hp_arready, hp_rlast, hp_rvalid, hp_rready;
  logic [3:0][63:0] hp_wdata, hp_rdata;

  // DUT port connections (the same port list for both tops), generated
`define SYS_CONN \
    .clk, .rst_n, .s_axi_awaddr_i(awaddr), .s_axi_awprot_i(awprot), \
    .s_axi_awvalid_i(awvalid), .s_axi_awready_o(awready), .s_axi_wdata_i(wdata), .s_axi_wstrb_i(wstrb), \
    .s_axi_wvalid_i(wvalid), .s_axi_wready_o(wready), .s_axi_bresp_o(bresp), .s_axi_bvalid_o(bvalid), \
    .s_axi_bready_i(bready), .s_axi_araddr_i(araddr), .s_axi_arprot_i(arprot), .s_axi_arvalid_i(arvalid), \
    .s_axi_arready_o(arready), .s_axi_rdata_o(rdata), .s_axi_rresp_o(rresp), .s_axi_rvalid_o(rvalid), \
    .s_axi_rready_i(rready), .m_hp0_axi_awid_o(hp_awid[0]), .m_hp0_axi_awaddr_o(hp_awaddr[0]), .m_hp0_axi_awlen_o(hp_awlen[0]), \
    .m_hp0_axi_awsize_o(hp_awsize[0]), .m_hp0_axi_awburst_o(hp_awburst[0]), .m_hp0_axi_awlock_o(hp_awlock[0]), .m_hp0_axi_awcache_o(hp_awcache[0]), \
    .m_hp0_axi_awprot_o(hp_awprot[0]), .m_hp0_axi_awqos_o(hp_awqos[0]), .m_hp0_axi_awvalid_o(hp_awvalid[0]), .m_hp0_axi_wdata_o(hp_wdata[0]), \
    .m_hp0_axi_wstrb_o(hp_wstrb[0]), .m_hp0_axi_wlast_o(hp_wlast[0]), .m_hp0_axi_wvalid_o(hp_wvalid[0]), .m_hp0_axi_bready_o(hp_bready[0]), \
    .m_hp0_axi_arid_o(hp_arid[0]), .m_hp0_axi_araddr_o(hp_araddr[0]), .m_hp0_axi_arlen_o(hp_arlen[0]), .m_hp0_axi_arsize_o(hp_arsize[0]), \
    .m_hp0_axi_arburst_o(hp_arburst[0]), .m_hp0_axi_arlock_o(hp_arlock[0]), .m_hp0_axi_arcache_o(hp_arcache[0]), .m_hp0_axi_arprot_o(hp_arprot[0]), \
    .m_hp0_axi_arqos_o(hp_arqos[0]), .m_hp0_axi_arvalid_o(hp_arvalid[0]), .m_hp0_axi_rready_o(hp_rready[0]), .m_hp0_axi_awready_i(hp_awready[0]), \
    .m_hp0_axi_wready_i(hp_wready[0]), .m_hp0_axi_bid_i(hp_bid[0]), .m_hp0_axi_bresp_i(hp_bresp[0]), .m_hp0_axi_bvalid_i(hp_bvalid[0]), \
    .m_hp0_axi_arready_i(hp_arready[0]), .m_hp0_axi_rid_i(hp_rid[0]), .m_hp0_axi_rdata_i(hp_rdata[0]), .m_hp0_axi_rresp_i(hp_rresp[0]), \
    .m_hp0_axi_rlast_i(hp_rlast[0]), .m_hp0_axi_rvalid_i(hp_rvalid[0]), .m_hp1_axi_awid_o(hp_awid[1]), .m_hp1_axi_awaddr_o(hp_awaddr[1]), \
    .m_hp1_axi_awlen_o(hp_awlen[1]), .m_hp1_axi_awsize_o(hp_awsize[1]), .m_hp1_axi_awburst_o(hp_awburst[1]), .m_hp1_axi_awlock_o(hp_awlock[1]), \
    .m_hp1_axi_awcache_o(hp_awcache[1]), .m_hp1_axi_awprot_o(hp_awprot[1]), .m_hp1_axi_awqos_o(hp_awqos[1]), .m_hp1_axi_awvalid_o(hp_awvalid[1]), \
    .m_hp1_axi_wdata_o(hp_wdata[1]), .m_hp1_axi_wstrb_o(hp_wstrb[1]), .m_hp1_axi_wlast_o(hp_wlast[1]), .m_hp1_axi_wvalid_o(hp_wvalid[1]), \
    .m_hp1_axi_bready_o(hp_bready[1]), .m_hp1_axi_arid_o(hp_arid[1]), .m_hp1_axi_araddr_o(hp_araddr[1]), .m_hp1_axi_arlen_o(hp_arlen[1]), \
    .m_hp1_axi_arsize_o(hp_arsize[1]), .m_hp1_axi_arburst_o(hp_arburst[1]), .m_hp1_axi_arlock_o(hp_arlock[1]), .m_hp1_axi_arcache_o(hp_arcache[1]), \
    .m_hp1_axi_arprot_o(hp_arprot[1]), .m_hp1_axi_arqos_o(hp_arqos[1]), .m_hp1_axi_arvalid_o(hp_arvalid[1]), .m_hp1_axi_rready_o(hp_rready[1]), \
    .m_hp1_axi_awready_i(hp_awready[1]), .m_hp1_axi_wready_i(hp_wready[1]), .m_hp1_axi_bid_i(hp_bid[1]), .m_hp1_axi_bresp_i(hp_bresp[1]), \
    .m_hp1_axi_bvalid_i(hp_bvalid[1]), .m_hp1_axi_arready_i(hp_arready[1]), .m_hp1_axi_rid_i(hp_rid[1]), .m_hp1_axi_rdata_i(hp_rdata[1]), \
    .m_hp1_axi_rresp_i(hp_rresp[1]), .m_hp1_axi_rlast_i(hp_rlast[1]), .m_hp1_axi_rvalid_i(hp_rvalid[1]), .m_hp2_axi_awid_o(hp_awid[2]), \
    .m_hp2_axi_awaddr_o(hp_awaddr[2]), .m_hp2_axi_awlen_o(hp_awlen[2]), .m_hp2_axi_awsize_o(hp_awsize[2]), .m_hp2_axi_awburst_o(hp_awburst[2]), \
    .m_hp2_axi_awlock_o(hp_awlock[2]), .m_hp2_axi_awcache_o(hp_awcache[2]), .m_hp2_axi_awprot_o(hp_awprot[2]), .m_hp2_axi_awqos_o(hp_awqos[2]), \
    .m_hp2_axi_awvalid_o(hp_awvalid[2]), .m_hp2_axi_wdata_o(hp_wdata[2]), .m_hp2_axi_wstrb_o(hp_wstrb[2]), .m_hp2_axi_wlast_o(hp_wlast[2]), \
    .m_hp2_axi_wvalid_o(hp_wvalid[2]), .m_hp2_axi_bready_o(hp_bready[2]), .m_hp2_axi_arid_o(hp_arid[2]), .m_hp2_axi_araddr_o(hp_araddr[2]), \
    .m_hp2_axi_arlen_o(hp_arlen[2]), .m_hp2_axi_arsize_o(hp_arsize[2]), .m_hp2_axi_arburst_o(hp_arburst[2]), .m_hp2_axi_arlock_o(hp_arlock[2]), \
    .m_hp2_axi_arcache_o(hp_arcache[2]), .m_hp2_axi_arprot_o(hp_arprot[2]), .m_hp2_axi_arqos_o(hp_arqos[2]), .m_hp2_axi_arvalid_o(hp_arvalid[2]), \
    .m_hp2_axi_rready_o(hp_rready[2]), .m_hp2_axi_awready_i(hp_awready[2]), .m_hp2_axi_wready_i(hp_wready[2]), .m_hp2_axi_bid_i(hp_bid[2]), \
    .m_hp2_axi_bresp_i(hp_bresp[2]), .m_hp2_axi_bvalid_i(hp_bvalid[2]), .m_hp2_axi_arready_i(hp_arready[2]), .m_hp2_axi_rid_i(hp_rid[2]), \
    .m_hp2_axi_rdata_i(hp_rdata[2]), .m_hp2_axi_rresp_i(hp_rresp[2]), .m_hp2_axi_rlast_i(hp_rlast[2]), .m_hp2_axi_rvalid_i(hp_rvalid[2]), \
    .m_hp3_axi_awid_o(hp_awid[3]), .m_hp3_axi_awaddr_o(hp_awaddr[3]), .m_hp3_axi_awlen_o(hp_awlen[3]), .m_hp3_axi_awsize_o(hp_awsize[3]), \
    .m_hp3_axi_awburst_o(hp_awburst[3]), .m_hp3_axi_awlock_o(hp_awlock[3]), .m_hp3_axi_awcache_o(hp_awcache[3]), .m_hp3_axi_awprot_o(hp_awprot[3]), \
    .m_hp3_axi_awqos_o(hp_awqos[3]), .m_hp3_axi_awvalid_o(hp_awvalid[3]), .m_hp3_axi_wdata_o(hp_wdata[3]), .m_hp3_axi_wstrb_o(hp_wstrb[3]), \
    .m_hp3_axi_wlast_o(hp_wlast[3]), .m_hp3_axi_wvalid_o(hp_wvalid[3]), .m_hp3_axi_bready_o(hp_bready[3]), .m_hp3_axi_arid_o(hp_arid[3]), \
    .m_hp3_axi_araddr_o(hp_araddr[3]), .m_hp3_axi_arlen_o(hp_arlen[3]), .m_hp3_axi_arsize_o(hp_arsize[3]), .m_hp3_axi_arburst_o(hp_arburst[3]), \
    .m_hp3_axi_arlock_o(hp_arlock[3]), .m_hp3_axi_arcache_o(hp_arcache[3]), .m_hp3_axi_arprot_o(hp_arprot[3]), .m_hp3_axi_arqos_o(hp_arqos[3]), \
    .m_hp3_axi_arvalid_o(hp_arvalid[3]), .m_hp3_axi_rready_o(hp_rready[3]), .m_hp3_axi_awready_i(hp_awready[3]), .m_hp3_axi_wready_i(hp_wready[3]), \
    .m_hp3_axi_bid_i(hp_bid[3]), .m_hp3_axi_bresp_i(hp_bresp[3]), .m_hp3_axi_bvalid_i(hp_bvalid[3]), .m_hp3_axi_arready_i(hp_arready[3]), \
    .m_hp3_axi_rid_i(hp_rid[3]), .m_hp3_axi_rdata_i(hp_rdata[3]), .m_hp3_axi_rresp_i(hp_rresp[3]), .m_hp3_axi_rlast_i(hp_rlast[3]), \
    .m_hp3_axi_rvalid_i(hp_rvalid[3])

  if (BUILD == 0) begin : g_dut
    if (VAR == 1) begin : g_v
      sys_a_top #(.GA_P(2)) dut (`SYS_CONN);
    end else if (VAR == 2) begin : g_v
      sys_a_top #(.XB_REG(0)) dut (`SYS_CONN);
    end else begin : g_v
      sys_a_top dut (`SYS_CONN);
    end
  end else begin : g_dut
    if (VAR == 1) begin : g_v
      sys_p_top #(.AT_KV_SRC(1)) dut (`SYS_CONN);
    end else if (VAR == 2) begin : g_v
      sys_p_top #(.XB_REG(0)) dut (`SYS_CONN);
    end else begin : g_v
      sys_p_top dut (`SYS_CONN);
    end
  end

  for (genvar k = 0; k < 4; k++) begin : g_hp
    axi_mem_slave #(.DW(64), .AW(32), .IDW(1), .MAX_LEN(15), .NAME("hp")) mem (
      .clk, .rst_n,
      .awid_i(hp_awid[k]), .awaddr_i(hp_awaddr[k]), .awlen_i(hp_awlen[k]), .awsize_i(hp_awsize[k]),
      .awburst_i(hp_awburst[k]), .awvalid_i(hp_awvalid[k]), .awready_o(hp_awready[k]),
      .wdata_i(hp_wdata[k]), .wstrb_i(hp_wstrb[k]), .wlast_i(hp_wlast[k]), .wvalid_i(hp_wvalid[k]),
      .wready_o(hp_wready[k]), .bid_o(hp_bid[k]), .bresp_o(hp_bresp[k]), .bvalid_o(hp_bvalid[k]),
      .bready_i(hp_bready[k]),
      .arid_i(hp_arid[k]), .araddr_i(hp_araddr[k]), .arlen_i(hp_arlen[k]), .arsize_i(hp_arsize[k]),
      .arburst_i(hp_arburst[k]), .arvalid_i(hp_arvalid[k]), .arready_o(hp_arready[k]),
      .rid_o(hp_rid[k]), .rdata_o(hp_rdata[k]), .rresp_o(hp_rresp[k]), .rlast_o(hp_rlast[k]),
      .rvalid_o(hp_rvalid[k]), .rready_i(hp_rready[k]));
  end

  tb_checker c_id = new("slot_map"), c_ga = new("gemv_acc"), c_pi = new("pim"), c_at = new("attn"),
             c_ve = new("vec"), c_err = new("status_err"), c_guard = new("guard"),
             c_port = new("hp_ports"), c_tie = new("tie_off"), c_rec = new("record");

  // ---------------- expected build (docs/spec/system.md 1.2) ----------------
  localparam bit A2 = BUILD == 0 && VAR == 1;
  localparam bit PD = BUILD == 1 && VAR == 1;
  localparam int GA_P = A2 ? 2 : 1;
  localparam int AT_HPAR = BUILD == 0 ? 1 : 2;
  localparam int AT_KVSRC = BUILD == 0 ? 1 : (PD ? 1 : 0);
  localparam int AT_HSMAX = BUILD == 0 ? 64 : 8;
  // HP ports with a used read / write channel set (bit k = HP k)
  localparam logic [3:0] RD_USED = BUILD == 0 ? (A2 ? 4'b1111 : 4'b1011) : 4'b1111;
  localparam logic [3:0] WR_USED = 4'b1011;

  // slot k: present, ID, CONFIG, CONFIG2 (0x24), CONFIG3 (0x28) (-1: not a config register)
  typedef struct { bit pres; logic [31:0] id, cfg; longint cfg2, cfg3; } slot_t;
  function automatic slot_t exp_slot(int k);
    slot_t s = '{0, 32'd0, 32'd0, 0, 0};
    case (k)
      0: if (BUILD == 0) s = '{1, 32'h4741_0001, {16'd1024, 4'd3, 4'(GA_P), 8'd100}, -1, -1};
      1: if (BUILD == 1) s = '{1, 32'h5049_0001, {16'd1024, 4'd4, 4'd4, 8'd100}, {16'd32, 16'd4096}, -1};
      2: s = '{1, 32'h4154_0001, {16'd512, 4'd3, 1'(AT_KVSRC), 3'(AT_HPAR), 8'd100},
               AT_KVSRC ? {24'd0, 8'(AT_HSMAX)} : {8'd0, 8'd5, 8'd4, 8'(AT_HSMAX)},
               AT_KVSRC ? 0 : {16'd512, 8'd8, 8'd12}};
      3: s = '{1, 32'h5645_0001, {16'd1024, 8'd16, 8'd100}, -1, -1};
      default: ;
    endcase
    return s;
  endfunction

  // ---------------- memory helpers ----------------
  function automatic void mw8(int k, longint unsigned a, byte unsigned d);
    case (k)
      0: g_hp[0].mem.bd_write8(a, d);
      1: g_hp[1].mem.bd_write8(a, d);
      2: g_hp[2].mem.bd_write8(a, d);
      default: g_hp[3].mem.bd_write8(a, d);
    endcase
  endfunction
  function automatic byte unsigned mr8(int k, longint unsigned a);
    case (k)
      0: return g_hp[0].mem.bd_read8(a);
      1: return g_hp[1].mem.bd_read8(a);
      2: return g_hp[2].mem.bd_read8(a);
      default: return g_hp[3].mem.bd_read8(a);
    endcase
  endfunction
  function automatic bit mwr(int k, longint unsigned a);
    case (k)
      0: return g_hp[0].mem.bd_written(a);
      1: return g_hp[1].mem.bd_written(a);
      2: return g_hp[2].mem.bd_written(a);
      default: return g_hp[3].mem.bd_written(a);
    endcase
  endfunction
  function automatic void mw64(int k, longint unsigned a, logic [63:0] d);
    for (int i = 0; i < 8; i++) mw8(k, a + i, d[8*i +: 8]);
  endfunction
  function automatic int mr32(int k, longint unsigned a);
    logic [31:0] v;
    for (int i = 0; i < 4; i++) v[8*i +: 8] = mr8(k, a + i);
    return int'(v);
  endfunction
  function automatic void bursts(output longint unsigned r[4], output longint unsigned w[4]);
    r[0] = g_hp[0].mem.n_rd_burst; w[0] = g_hp[0].mem.n_wr_burst;
    r[1] = g_hp[1].mem.n_rd_burst; w[1] = g_hp[1].mem.n_wr_burst;
    r[2] = g_hp[2].mem.n_rd_burst; w[2] = g_hp[2].mem.n_wr_burst;
    r[3] = g_hp[3].mem.n_rd_burst; w[3] = g_hp[3].mem.n_wr_burst;
  endfunction

  // guard: n bytes before and after [a, a + len) unwritten in memory k
  function automatic void guard(int k, longint unsigned a, longint unsigned len, string what);
    for (int i = 1; i <= 16; i++)
      if (mwr(k, a - i) || mwr(k, a + len + i - 1)) begin
        c_guard.fail($sformatf("%s: guard byte %0d around 0x%0h + %0d written (HP%0d)", what, i, a, len, k));
        return;
      end
    c_guard.pass();
  endfunction

  // ---------------- port traffic of one call ----------------
  longint unsigned br0[4], bw0[4];
  task automatic port_begin();
    bursts(br0, bw0);
  endtask
  task automatic port_end(string what, logic [3:0] rd_exp, logic [3:0] wr_exp);
    longint unsigned r[4], w[4];
    logic [3:0] rd_got, wr_got;
    bursts(r, w);
    for (int k = 0; k < 4; k++) begin
      rd_got[k] = r[k] != br0[k];
      wr_got[k] = w[k] != bw0[k];
    end
    if (rd_got !== rd_exp || wr_got !== wr_exp)
      c_port.fail($sformatf("%s: HP ports with read bursts %b (expected %b), with write bursts %b (expected %b)",
                            what, rd_got, rd_exp, wr_got, wr_exp));
    else c_port.pass();
  endtask

  // tie-off of the unused channel sets, every cycle
  longint n_tie_cyc = 0, n_tie_bad = 0;
  always @(negedge clk)
    if (rst_n) begin
      n_tie_cyc++;
      for (int k = 0; k < 4; k++) begin
        if (!RD_USED[k] && (hp_arvalid[k] !== 1'b0 || hp_rready[k] !== 1'b1 || hp_araddr[k] !== '0 ||
                            hp_arlen[k] !== '0 || hp_arsize[k] !== '0 || hp_arburst[k] !== '0 ||
                            hp_arid[k] !== '0 || hp_arlock[k] !== 1'b0 || hp_arcache[k] !== '0 ||
                            hp_arprot[k] !== '0 || hp_arqos[k] !== '0)) begin
          n_tie_bad++;
          if (n_tie_bad <= 5) c_tie.fail($sformatf("HP%0d read channel not tied off (ARVALID %b RREADY %b ARADDR %h)",
                                                   k, hp_arvalid[k], hp_rready[k], hp_araddr[k]));
        end
        if (!WR_USED[k] && (hp_awvalid[k] !== 1'b0 || hp_wvalid[k] !== 1'b0 || hp_bready[k] !== 1'b1 ||
                            hp_awaddr[k] !== '0 || hp_awlen[k] !== '0 || hp_awsize[k] !== '0 ||
                            hp_awburst[k] !== '0 || hp_awid[k] !== '0 || hp_awlock[k] !== 1'b0 ||
                            hp_awcache[k] !== '0 || hp_awprot[k] !== '0 || hp_awqos[k] !== '0 ||
                            hp_wdata[k] !== '0 || hp_wstrb[k] !== '0 || hp_wlast[k] !== 1'b0)) begin
          n_tie_bad++;
          if (n_tie_bad <= 5) c_tie.fail($sformatf("HP%0d write channel not tied off (AWVALID %b WVALID %b BREADY %b)",
                                                   k, hp_awvalid[k], hp_wvalid[k], hp_bready[k]));
        end
      end
    end

  // ---------------- CSR access ----------------
  function automatic logic [15:0] sa(int slot, int off);
    return 16'((slot << 12) | off);
  endfunction
  task automatic wr(int slot, int off, logic [31:0] d);
    bfm.write0(sa(slot, off), d);
  endtask
  task automatic rd(int slot, int off, output logic [31:0] d);
    bfm.read(sa(slot, off), d);
  endtask

  // CTRL write, wait for busy = 0, then done_sticky and ERR == 0
  task automatic run_ctrl(int slot, logic [31:0] ctrl, string what, tb_checker c);
    logic [31:0] st, err, cy;
    longint t0 = cyc;
    wr(slot, 'h08, ctrl);
    do begin
      repeat ($urandom_range(20)) @(posedge clk);
      rd(slot, 'h0C, st);
      if (cyc - t0 > 3_000_000) $fatal(1, "TB_WATCHDOG tb_sys_top: %s did not finish", what);
    end while (st[0] !== 1'b0);
    rd(slot, 'h10, err);
    rd(slot, 'h14, cy);
    if (st[1] !== 1'b1 || err !== 32'd0 || cy == 32'd0)
      c_err.fail($sformatf("%s: STATUS 0x%0h ERR 0x%0h CYCLES %0d", what, st, err, cy));
    else c_err.pass();
    $display("tb_sys_top: %s: CYCLES %0d", what, cy);
  endtask

  // ---------------- (a) slot map ----------------
  task automatic slot_map();
    logic [31:0] d;
    int offs[$] = '{'h00, 'h04, 'h24, 'h28, 'h0C, 'h40, 'hFFC};
    // writes to absent slots (must reach no IP)
    for (int k = 0; k < 16; k++)
      if (!exp_slot(k).pres) begin
        wr(k, 'h40, 32'hA5A5_0000 | k);
        wr(k, 'h08, 32'h11);                   // a CTRL start if it reached an IP
        wr(k, 4 * $urandom_range(1023), $urandom);
      end
    for (int k = 0; k < 16; k++) begin
      slot_t s = exp_slot(k);
      if (s.pres) begin
        rd(k, 'h00, d);
        if (d !== s.id) c_id.fail($sformatf("slot %0d ID 0x%08h expected 0x%08h", k, d, s.id)); else c_id.pass();
        rd(k, 'h04, d);
        if (d !== s.cfg) c_id.fail($sformatf("slot %0d CONFIG 0x%08h expected 0x%08h", k, d, s.cfg)); else c_id.pass();
        if (s.cfg2 >= 0) begin
          rd(k, 'h24, d);
          if (d !== 32'(s.cfg2)) c_id.fail($sformatf("slot %0d CONFIG2 0x%08h expected 0x%08h", k, d, 32'(s.cfg2))); else c_id.pass();
        end
        if (s.cfg3 >= 0) begin
          rd(k, 'h28, d);
          if (d !== 32'(s.cfg3)) c_id.fail($sformatf("slot %0d CONFIG3 0x%08h expected 0x%08h", k, d, 32'(s.cfg3))); else c_id.pass();
        end
        // descriptor register at 0x40 (reset 0, written by nothing so far) and STATUS idle
        rd(k, 'h40, d);
        if (d !== 32'd0) c_id.fail($sformatf("slot %0d 0x40 = 0x%08h: a write to an absent slot reached it", k, d)); else c_id.pass();
        rd(k, 'h0C, d);
        if (d[1:0] !== 2'b00) c_id.fail($sformatf("slot %0d STATUS 0x%08h after reset", k, d)); else c_id.pass();
        $display("tb_sys_top: slot %0d ID 0x%08h CONFIG 0x%08h", k, s.id, s.cfg);
      end else begin
        int bad = 0;
        foreach (offs[i]) begin
          rd(k, offs[i], d);
          if (d !== 32'd0) bad++;
        end
        rd(k, 4 * $urandom_range(1023), d);
        if (d !== 32'd0) bad++;
        if (bad != 0) c_id.fail($sformatf("absent slot %0d: %0d of %0d reads not 0", k, bad, offs.size() + 1));
        else c_id.pass();
      end
    end
  endtask

  // ---------------- (b) gemv_acc ----------------
  task automatic call_gemv();
    int rows = $urandom_range(20, 8) * 2 + 1, n = $urandom_range(200, 9), nb, rb;
    int xm = $urandom_range((1 << 17) - 1), we = $urandom_range(30, 18), xe = $urandom_range(30, 15), fo = 16;
    longint unsigned wa = 64'h1800_0000 + 8 * $urandom_range(4095), xa = 64'h1900_0000 + 8 * $urandom_range(511),
                     ya = 64'h1A00_0000 + 16 + 8 * $urandom_range(511);
    byte xb[] = new[n], wb[] = new[n];
    int ey[] = new[rows];
    int ai, av;
    logic [31:0] d;
    nb = (n + 7) / 8;
    rb = 8 * (1 + nb);
    foreach (xb[i]) xb[i] = byte'(int'($urandom_range(254)) - 127);
    for (int i = 0; i < 8 * nb; i++) begin
      mw8(0, xa + i, i < n ? xb[i] : 8'($urandom));
      if (GA_P == 2) mw8(2, xa + i, i < n ? xb[i] : 8'($urandom));
    end
    for (int r = 0; r < rows; r++) begin
      int wm = $urandom_range(65535), port = (GA_P == 2) ? 2 * (r % 2) : 0;
      logic [63:0] h = {$urandom, 16'($urandom), 16'(wm)};
      foreach (wb[i]) wb[i] = byte'($urandom);
      for (int i = 0; i < rb; i++) begin
        byte unsigned v = i < 8 ? h[8*i +: 8] : (i - 8 < n ? wb[i - 8] : 8'($urandom));
        mw8(port, wa + r * rb + i, v);
        if (GA_P == 2) mw8(2 - port, wa + r * rb + i, 8'($urandom));   // garbage for the other slice
      end
      ey[r] = kd_gemv1(wb, xb, n, wm, xm, we + xe - fo);
    end
    ai = kd_argmax(ey, rows);
    av = ey[ai];
    wr(0, 'h40, 32'(wa)); wr(0, 'h44, 32'(xa)); wr(0, 'h48, 32'(ya));
    wr(0, 'h4C, rows); wr(0, 'h50, n); wr(0, 'h54, xm);
    wr(0, 'h58, {8'd0, 8'(fo), 8'(xe), 8'(we)}); wr(0, 'h5C, 32'h3);
    port_begin();
    run_ctrl(0, 32'h11, $sformatf("gemv_acc rows %0d n %0d P %0d", rows, n, GA_P), c_ga);
    port_end("gemv_acc", GA_P == 2 ? 4'b0101 : 4'b0001, 4'b0001);
    for (int r = 0; r < rows; r++) begin
      int got = mr32(0, ya + 4 * r);
      if (got !== ey[r]) c_ga.fail($sformatf("y[%0d] = %0d golden %0d", r, got, ey[r])); else c_ga.pass();
    end
    guard(0, ya, 4 * rows, "gemv_acc y");
    rd(0, 'h60, d);
    if (int'(d) !== ai) c_ga.fail($sformatf("ARGMAX_IDX %0d golden %0d", d, ai)); else c_ga.pass();
    rd(0, 'h64, d);
    if (int'(d) !== av) c_ga.fail($sformatf("ARGMAX_VAL %0d golden %0d", int'(d), av)); else c_ga.pass();
  endtask

  // ---------------- (b) pim ----------------
  function automatic logic [127:0] pcmd(int op, int n, int rows, int base, int xm, longint unsigned a,
                                        int we, int xe, int fo);
    return {8'd0, 8'(fo), 8'(xe), 8'(we), 32'(a), 15'(base), 17'(xm), 16'(rows), 12'(n), 4'(op)};
  endfunction
  task automatic push(logic [127:0] c);
    logic [31:0] st;
    wr(1, 'h40, c[31:0]); wr(1, 'h44, c[63:32]); wr(1, 'h48, c[95:64]); wr(1, 'h4C, c[127:96]);
    wr(1, 'h50, 32'd0);
    do rd(1, 'h0C, st); while (st[3] !== 1'b0);
  endtask
  task automatic call_pim();
    int rows = $urandom_range(40, 9), n = $urandom_range(200, 1), nw, used, base, rb;
    int xm = $urandom_range((1 << 17) - 1), we = $urandom_range(30, 18), xe = $urandom_range(30, 15), fo = 16;
    longint unsigned wa = 64'h1800_0000 + 8 * $urandom_range(4095), xa = 64'h1900_0000 + 8 * $urandom_range(511),
                     ya = 64'h1A00_0000 + 16 + 8 * $urandom_range(511);
    byte w[] = new[rows * n], xb[] = new[n];
    shortint wm[] = new[rows];
    int ey[] = new[rows];
    longint st[] = new[3];
    logic [31:0] d;
    nw = (n + 15) / 16;
    used = (rows + 3) / 4 * nw;
    base = $urandom_range(4096 - used);
    rb = 8 * (1 + (n + 7) / 8);
    foreach (w[i]) w[i] = byte'($urandom);
    foreach (wm[i]) wm[i] = 16'($urandom);
    foreach (xb[i]) xb[i] = byte'(int'($urandom_range(254)) - 127);
    for (int r = 0; r < rows; r++) begin
      logic [63:0] h = {$urandom, 16'($urandom), wm[r]};
      for (int i = 0; i < 8; i++) mw8(0, wa + r * rb + i, h[8*i +: 8]);
      for (int i = 0; i < rb - 8; i++) mw8(0, wa + r * rb + 8 + i, i < n ? w[r * n + i] : 8'($urandom));
    end
    for (int i = 0; i < 8 * ((n + 7) / 8); i++) mw8(0, xa + i, i < n ? xb[i] : 8'($urandom));
    if (kd_bank_syn(w, wm, xb, rows, n, we, xm, xe, fo, 4, ey, st) != 0) c_pi.fail("kd_bank_syn");
    push(pcmd(1, n, rows, base, 0, wa, 0, 0, 0));          // LDW
    push(pcmd(2, n, 0, 0, 0, xa, 0, 0, 0));                // WRGB
    push(pcmd(3, n, rows, base, xm, ya, we, xe, fo));      // MACAB
    rd(1, 'h0C, d);
    if (d[23:8] !== 16'd3) c_pi.fail($sformatf("FIFO level %0d after 3 pushes", d[23:8])); else c_pi.pass();
    port_begin();
    run_ctrl(1, 32'h11, $sformatf("pim LDW + WRGB + MACAB rows %0d n %0d base %0d", rows, n, base), c_pi);
    port_end("pim", 4'b0001, 4'b0001);
    for (int r = 0; r < rows; r++) begin
      int got = mr32(0, ya + 4 * r);
      if (got !== ey[r]) c_pi.fail($sformatf("y[%0d] = %0d golden %0d", r, got, ey[r])); else c_pi.pass();
    end
    guard(0, ya, 4 * rows, "pim y");
    rd(1, 'h20, d); if (d !== 32'd3) c_pi.fail($sformatf("OPS %0d", d)); else c_pi.pass();
    rd(1, 'h60, d); if (longint'(d) !== st[0]) c_pi.fail($sformatf("ST_WRGB %0d golden %0d", d, st[0])); else c_pi.pass();
    rd(1, 'h64, d); if (longint'(d) !== st[1]) c_pi.fail($sformatf("ST_MAC %0d golden %0d", d, st[1])); else c_pi.pass();
    rd(1, 'h68, d); if (longint'(d) !== st[2]) c_pi.fail($sformatf("ST_RDMAC %0d golden %0d", d, st[2])); else c_pi.pass();
    rd(1, 'h6C, d); if (d !== 32'd1) c_pi.fail($sformatf("N_LDW %0d", d)); else c_pi.pass();
    rd(1, 'h70, d); if (d !== 32'd1) c_pi.fail($sformatf("N_WRGB %0d", d)); else c_pi.pass();
    rd(1, 'h74, d); if (d !== 32'd1) c_pi.fail($sformatf("N_MACAB %0d", d)); else c_pi.pass();
  endtask

  // ---------------- (b) attn ----------------
  localparam longint unsigned KC = 64'h1B00_0000, VC = 64'h1C00_0000, KCS = 64'h1D00_0000,
                              VCS = 64'h1D80_0000, QB0 = 64'h1E00_0000;
  longint unsigned obase = 64'h1E80_0000;
  int nh, nkv, seq, kvmul;
  int last_w[8] = '{-1, -1, -1, -1, -1, -1, -1, -1};

  function automatic longint unsigned slot_a(longint unsigned base, int l, int j, int t, int row);
    return base + (longint'(l * nkv + j) * seq + t) * row;
  endfunction
  // HP port of the engine that serves kv head j
  function automatic int kv_port(int j);
    return 1 + (j % AT_HPAR);
  endfunction
  // golden layout of position t of kv head j (record c), layer l, into memory k
  function automatic void put_kv(int k, att_case c, int l, int j, int t);
    int ek = c.kb > 8 ? 2 : 1, ev = c.vb > 8 ? 2 : 1;
    for (int i = 0; i < c.hs; i++) begin
      for (int b = 0; b < ek; b++) mw8(k, slot_a(KC, l, j, t, c.hs * ek) + i * ek + b, 8'(c.K[t * c.hs + i] >> (8 * b)));
      for (int b = 0; b < ev; b++) mw8(k, slot_a(VC, l, j, t, c.hs * ev) + i * ev + b, 8'(c.V[t * c.hs + i] >> (8 * b)));
    end
    mw64(k, slot_a(KCS, l, j, t, 8), {32'(c.kse[t]), 32'(c.ksm[t])});
    mw64(k, slot_a(VCS, l, j, t, 8), {32'(c.vse[t]), 32'(c.vsm[t])});
  endfunction

  longint n_attn = 0, n_kvw = 0;
  task automatic attn_group(att_case g[$], int l);
    att_case c0 = g[0];
    int T = c0.T, hs = c0.hs, ek = c0.kb > 8 ? 2 : 1, ev = c0.vb > 8 ? 2 : 1, ps = ((T + 1) / 2) * 8;
    longint unsigned qa = QB0 + 8 * $urandom_range(500), oa, pa;
    logic [3:0] rd_exp;
    wr(2, 'h4C, 32'(slot_a(KC, l, 0, 0, hs * ek)));
    wr(2, 'h50, 32'(slot_a(VC, l, 0, 0, hs * ev)));
    wr(2, 'h54, 32'(slot_a(KCS, l, 0, 0, 8)));
    wr(2, 'h58, 32'(slot_a(VCS, l, 0, 0, 8)));
    wr(2, 'h70, seq); wr(2, 'h6C, l); wr(2, 'h60, hs);
    wr(2, 'h64, {15'd0, 1'b0, 3'd0, 5'(c0.vb), 3'd0, 5'(c0.kb)});
    if (AT_KVSRC == 0) begin
      // BRAM KV: KVW of every new position (source = golden layout in the HP1 memory)
      for (int t = last_w[l] + 1; t < T; t++) begin
        for (int j = 0; j < nkv; j++) put_kv(1, g[j * kvmul], l, j, t);
        wr(2, 'h74, t);
        wr(2, 'h78, {16'd0, 8'(nkv), 8'd0});
        port_begin();
        run_ctrl(2, 32'h21, $sformatf("attn KVW layer %0d pos %0d", l, t), c_at);
        port_end("attn KVW", 4'b0010, 4'b0000);
        n_kvw++;
      end
      last_w[l] = T - 1;
    end else
      for (int j = 0; j < nkv; j++)
        for (int t = 0; t < T; t++) put_kv(kv_port(j), g[j * kvmul], l, j, t);
    // q records: real one in the memory of the engine's port, garbage in the other
    for (int h = 0; h < nh; h++) begin
      longint unsigned a = qa + h * (8 + 2 * hs);
      int pk = kv_port(h / kvmul);
      mw64(pk, a, {32'(g[h].qe), 32'(g[h].qm)});
      for (int i = 0; i < hs; i++) begin
        mw8(pk, a + 8 + 2 * i, 8'(g[h].q[i]));
        mw8(pk, a + 9 + 2 * i, 8'(g[h].q[i] >> 8));
      end
      if (AT_HPAR == 2) for (int i = 0; i < 8 + 2 * hs; i++) mw8(3 - pk, a + i, 8'($urandom));
    end
    oa = obase + 16 + 8 * $urandom_range(3);
    pa = oa + 32 + longint'(nh) * hs * 4 + 8 * $urandom_range(3);
    obase = (pa + 32 + longint'(nh) * ps + 4096 + 7) & ~64'd7;
    wr(2, 'h40, 32'(qa)); wr(2, 'h44, 32'(oa)); wr(2, 'h48, 32'(pa)); wr(2, 'h5C, T);
    wr(2, 'h64, {15'd0, 1'b1, 3'd0, 5'(c0.vb), 3'd0, 5'(c0.kb)});
    wr(2, 'h68, {8'd0, 8'(kvmul), 8'(nh), 8'd0});
    rd_exp = AT_HPAR == 2 ? 4'b0110 : 4'b0010;
    port_begin();
    run_ctrl(2, 32'h11, $sformatf("attn ATTN layer %0d T %0d heads %0d", l, T, nh), c_at);
    port_end("attn ATTN", rd_exp, 4'b0010);
    n_attn++;
    for (int h = 0; h < nh; h++) begin
      for (int i = 0; i < hs; i++) begin
        int got = mr32(1, oa + (h * hs + i) * 4);
        if (got !== g[h].o[i]) c_at.fail($sformatf("T %0d layer %0d head %0d o[%0d] %0d golden %0d", T, l, h, i, got, g[h].o[i]));
        else c_at.pass();
      end
      for (int t = 0; t < T; t++) begin
        int got = mr32(1, pa + h * ps + t * 4);
        if (got !== g[h].p[t]) c_at.fail($sformatf("T %0d layer %0d head %0d p[%0d] %0d golden %0d", T, l, h, t, got, g[h].p[t]));
        else c_at.pass();
      end
    end
    guard(1, oa, longint'(nh) * hs * 4, "attn o");
    guard(1, pa, longint'(nh - 1) * ps + T * 4, "attn p");
  endtask

  task automatic call_attn(string vdir, int ngrp);
    att_case g[$];
    int cur_T = -1, cur_l = 0, done = 0;
    if (kd_rec_open({vdir, "/attn2.bin"}) != 0) $fatal(1, "tb_sys_top: no record file %s/attn2.bin", vdir);
    while (done < ngrp) begin
      att_case c = new();
      int rc;
      if (kd_rec_next() <= 0) break;
      rc = c.load_rec();
      if (rc != 0) begin c_rec.fail($sformatf("record %0d load %0d", kd_rec_index(), rc)); continue; end
      c_rec.pass();
      g.push_back(c);
      if (g.size() == nh) begin
        if (g[0].T != cur_T) begin cur_T = g[0].T; cur_l = 0; end
        attn_group(g, cur_l);
        cur_l++;
        done++;
        g.delete();
      end
    end
    void'(kd_rec_close());
    if (done != ngrp) c_rec.fail($sformatf("only %0d of %0d attention groups", done, ngrp));
    $display("tb_sys_top: attention: %0d groups (%0d ATTN, %0d KVW ops), last T %0d", done, n_attn, n_kvw, cur_T);
  endtask

  // ---------------- (b) vec ----------------
  task automatic call_vec_actq();
    vcase c = new();
    int n = $urandom_range(300, 1), qb;
    longint unsigned ia = 64'h1F00_0000 + 8 * $urandom_range(511), oa = 64'h1F80_0000 + 16 + 8 * $urandom_range(63), sca;
    c.gen_syn(K_ACTQ, n, 0);
    qb = c.p1 != 127 ? 2 : 1;
    sca = (oa + n * qb + 16 + 7) & ~64'd7;
    for (int i = 0; i < n; i++) for (int b = 0; b < 4; b++) mw8(3, ia + 4 * i + b, 8'(c.in0[i] >> (8 * b)));
    wr(3, 'h40, 32'(ia)); wr(3, 'h48, 32'(oa)); wr(3, 'h4C, 32'(sca)); wr(3, 'h50, n);
    wr(3, 'h54, {4'd0, 4'd8, 7'd0, 1'b1, 16'(c.p1)});
    wr(3, 'h58, {16'd0, 8'd0, 8'(c.p0)});
    port_begin();
    run_ctrl(3, 32'h31, $sformatf("vec ACTQ n %0d qmax %0d", n, c.p1), c_ve);
    port_end("vec ACTQ", 4'b1000, 4'b1000);
    for (int i = 0; i < n; i++) begin
      int got = qb == 2 ? int'(shortint'({mr8(3, oa + 2 * i + 1), mr8(3, oa + 2 * i)})) : int'(byte'(mr8(3, oa + i)));
      if (got !== c.q[i]) c_ve.fail($sformatf("ACTQ q[%0d] %0d golden %0d", i, got, c.q[i])); else c_ve.pass();
    end
    if (mr32(3, sca) !== c.sm || mr32(3, sca + 4) !== c.se)
      c_ve.fail($sformatf("ACTQ scale %0d %0d golden %0d %0d", mr32(3, sca), mr32(3, sca + 4), c.sm, c.se));
    else c_ve.pass();
    guard(3, oa, n * qb, "vec q");
    guard(3, sca, 8, "vec scale");
  endtask

  task automatic call_vec_argmax();
    vcase c = new();
    int n = $urandom_range(2000, 2);
    longint unsigned ia = 64'h1F40_0000 + 8 * $urandom_range(511), oa = 64'h1FC0_0000 + 16 + 8 * $urandom_range(63);
    logic [31:0] d;
    c.gen_syn(K_ARGMAX, n, 0);
    for (int i = 0; i < n; i++) for (int b = 0; b < 4; b++) mw8(3, ia + 4 * i + b, 8'(c.in0[i] >> (8 * b)));
    wr(3, 'h40, 32'(ia)); wr(3, 'h48, 32'(oa)); wr(3, 'h50, n);
    port_begin();
    run_ctrl(3, 32'h41, $sformatf("vec ARGMAX n %0d", n), c_ve);
    port_end("vec ARGMAX", 4'b1000, 4'b1000);
    if (mr32(3, oa) !== c.idx) c_ve.fail($sformatf("ARGMAX idx in memory %0d golden %0d", mr32(3, oa), c.idx)); else c_ve.pass();
    rd(3, 'h24, d);
    if (int'(d) !== c.idx) c_ve.fail($sformatf("ARGMAX_IDX %0d golden %0d", d, c.idx)); else c_ve.pass();
    rd(3, 'h28, d);
    if (int'(d) !== c.in0[c.idx]) c_ve.fail($sformatf("ARGMAX_VAL %0d golden %0d", int'(d), c.in0[c.idx])); else c_ve.pass();
    guard(3, oa, 4, "vec argmax idx");
  endtask

  // ---------------- main ----------------
  initial begin
    automatic int unsigned seed;
    automatic int maxd = 1, ngrp;
    automatic string vat = "";
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("MAXD=%d", maxd));
    void'($value$plusargs("VEC_AT=%s", vat));
    // record model: 260K (build P) nh 8, nkv 4, seq 512; 15M (build A) nh 6, nkv 6, seq 256
    nh = BUILD == 0 ? 6 : 8;
    nkv = BUILD == 0 ? 6 : 4;
    seq = BUILD == 0 ? 256 : 512;
    kvmul = nh / nkv;
    ngrp = (BUILD == 0 ? 6 : 5) + 1;   // every layer of position 0, then position 1 layer 0 (T 2)
    void'($value$plusargs("NGRP=%d", ngrp));
    $display("tb_sys_top: BUILD %s VAR %0d seed %0d MAXD %0d attention records %s, %0d groups",
             BUILD == 0 ? "A (sys_a_top)" : "P (sys_p_top)", VAR, seed, maxd, vat, ngrp);
    bfm.maxd = maxd;
    fork
      begin
        repeat (5_000_000) @(posedge clk);
        $fatal(1, "TB_WATCHDOG tb_sys_top: no end after 5,000,000 cycles");
      end
    join_none
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);
    slot_map();
    if (BUILD == 0) call_gemv(); else call_pim();
    call_vec_actq();
    call_attn(vat, ngrp);
    call_vec_argmax();
    repeat (50) @(posedge clk);
    g_hp[0].mem.check_idle(); g_hp[1].mem.check_idle(); g_hp[2].mem.check_idle(); g_hp[3].mem.check_idle();
    if (n_tie_bad == 0 && n_tie_cyc > 0) c_tie.pass();
    $display("tb_sys_top: tie-off monitored %0d cycles, %0d violations; HP bursts rd %0d %0d %0d %0d, wr %0d %0d %0d %0d",
             n_tie_cyc, n_tie_bad, g_hp[0].mem.n_rd_burst, g_hp[1].mem.n_rd_burst, g_hp[2].mem.n_rd_burst,
             g_hp[3].mem.n_rd_burst, g_hp[0].mem.n_wr_burst, g_hp[1].mem.n_wr_burst, g_hp[2].mem.n_wr_burst,
             g_hp[3].mem.n_wr_burst);
    begin
      automatic tb_checker_q l = '{c_id, c_at, c_ve, c_err, c_guard, c_port, c_tie, c_rec};
      if (BUILD == 0) l.push_back(c_ga); else l.push_back(c_pi);
      void'(tb_final_report(l));
    end
    $finish;
  end

endmodule
