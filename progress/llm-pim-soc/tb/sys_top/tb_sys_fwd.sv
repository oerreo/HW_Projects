// tb_sys_fwd: RTL system testbench of the L4 tops sys_a_top (BUILD 0) and sys_p_top (BUILD 1),
// S5-3 / S5-4 (docs/spec/system.md 3.2). The system program of fpga/sys/sw (executor, the four
// drivers, initialization, run list, log), unchanged C code, drives the RTL:
//   - DPI-C: import context task sys_tb_main (tb/sys_top/sys_tb.c) runs the program's main;
//     its HAL (tb/sys_top/hal_dpi.c) calls the exported tasks sv_axil_wr / sv_axil_rd, one
//     AXI4-Lite transaction of tb/common/axil_bfm.sv each (simulation time passes), and the
//     exported function sv_cycles is its time base (plat_dpi.c).
//   - one AXI memory model per HP port (tb/common/axi_mem_slave.sv, EXT_STORE = 1): every beat
//     goes to the one DDR image of the C cache model (fpga/sys/test/hal_cache.c), so all HP
//     ports and the program see the same memory, and the IP-side coherence checks of S5-1 see
//     every RTL beat.
// The C side judges the program log (sys_tb.c: build detection, token / logits hash per position
// against the PC expected values, run K kernel compare, COH, fallback, IPERR, CYCLES closed
// forms); this module adds the AXI protocol checks of the memory models (all tags) and the
// end-of-test idle check, and prints TB_RESULT.
// Fault injection (+TB_IPFAULT, hal_dpi.c) reaches the memory models through sv_inj: SLVERR
// windows on all addresses (read or write) or no responses (hang) on the HP ports of one IP.
// A hung port is left out of the idle check (its IP never finishes; the program disabled it).
// Memory stall (S5-4): +PROF=<n> sets random backpressure and latency on all four HP memory
// models (axi_mem_slave cfg_stall / cfg_lat, the profiles of tb_pim_top / tb_bw_top):
//   0 (default) no stall, latency 1 (the runs whose CYCLES the C side compares with closed forms)
//   1 AR/AW/W/R/B 20 % stall, R latency 1..30, B latency 1..20
//   2 AR/AW/W/R/B 50 % stall, R latency 1..60, B latency 1..40
//   3 per port different (HP0 1's, HP1 2's, HP2 30 % / R 5..40 / B 1..10, HP3 10 % / R 1..80 / B 1..60)
// The C side (hal_dpi.c) reads the same +PROF: with PROF != 0 the CYCLES closed forms become
// lower bounds and every RD_STALL / WR_STALL must be <= its CYCLES; sys_tb.c also requires a vec
// RD_STALL sum > 0 when the HP3 model stalled R (exported sv_mem_rstall). The models print their
// stall statistics (AXI_MEM_STALL) at the end.
// Plusargs: +SEED +MAXD (AXI-Lite gaps, default 0) +WDOG (cycles, default 60,000,000) +PROF, the
// program settings (+SX_LIST +SX_RUNS +SX_STEPS +SX_MODELS +SX_FAULT +DDR_CK +DDR_TK) and the
// expectations (+EXP_BUILD +EXP_CHECKS +EXP_IPERR +EXP_IPERR_IP +EXP_IPERR_KIND +EXP_FB).
// C-side traces: +CYCTRACE (CYCLES per op) and +VTRACE (viewer event trace, hal_dpi.c header; uses
// the exported sv_mem_beats for the HP beat counts).
`timescale 1ns / 1ps
module tb_sys_fwd;
  import tb_util_pkg::*;

  parameter int BUILD = 0;   // 0 sys_a_top, 1 sys_p_top
  parameter int VAR   = 0;   // 0 defaults, 1 A2 (GA_P 2) / PD (AT_KV_SRC 1), 2 XB_REG 0

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

  // DUT port connections (the same port list for both tops; copy of tb_sys_top.sv)
`define SYSF_CONN \
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
      sys_a_top #(.GA_P(2)) dut (`SYSF_CONN);
    end else if (VAR == 2) begin : g_v
      sys_a_top #(.XB_REG(0)) dut (`SYSF_CONN);
    end else begin : g_v
      sys_a_top dut (`SYSF_CONN);
    end
  end else begin : g_dut
    if (VAR == 1) begin : g_v
      sys_p_top #(.AT_KV_SRC(1)) dut (`SYSF_CONN);
    end else if (VAR == 2) begin : g_v
      sys_p_top #(.XB_REG(0)) dut (`SYSF_CONN);
    end else begin : g_v
      sys_p_top dut (`SYSF_CONN);
    end
  end

  for (genvar k = 0; k < 4; k++) begin : g_hp
    axi_mem_slave #(.DW(64), .AW(32), .IDW(1), .MAX_LEN(15), .EXT_STORE(1'b1), .NAME("hp")) mem (
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

  // ---------------- DPI-C ----------------
  import "DPI-C" context task sys_tb_main(output int rc);
  export "DPI-C" task sv_axil_wr;
  export "DPI-C" task sv_axil_rd;
  export "DPI-C" function sv_cycles;
  export "DPI-C" function sv_puts;
  export "DPI-C" function sv_plusarg;
  export "DPI-C" function sv_inj;
  export "DPI-C" function sv_mem_rstall;
  export "DPI-C" function sv_mem_beats;

  task automatic sv_axil_wr(input int unsigned a, input int unsigned d);
    bfm.write0(16'(a), d);
  endtask
  task automatic sv_axil_rd(input int unsigned a, output int unsigned d);
    logic [31:0] v;
    bfm.read(16'(a), v);
    d = v;
  endtask
  function automatic longint sv_cycles();
    return cyc;
  endfunction
  function automatic void sv_puts(input string s);
    $display("%s", s);
  endfunction
  function automatic int sv_plusarg(input string k, output string v);
    v = "";
    return $value$plusargs({k, "=%s"}, v);
  endfunction

  // cycles in which the memory model of HP port k held back an R beat (axi_mem_slave n_st_r);
  // sys_tb.c: R stalls on HP3 (vec) must show up in the vec RD_STALL sum
  function automatic longint sv_mem_rstall(input int k);
    case (k)
      0: return longint'(g_hp[0].mem.n_st_r);
      1: return longint'(g_hp[1].mem.n_st_r);
      2: return longint'(g_hp[2].mem.n_st_r);
      default: return longint'(g_hp[3].mem.n_st_r);
    endcase
  endfunction

  // R (w = 0) or W (w = 1) beats so far of the memory model of HP port k (axi_mem_slave
  // n_rd_beat / n_wr_beat); viewer trace of hal_dpi.c (+VTRACE), not a check
  function automatic longint sv_mem_beats(input int k, input int w);
    case (k)
      0: return longint'(w ? g_hp[0].mem.n_wr_beat : g_hp[0].mem.n_rd_beat);
      1: return longint'(w ? g_hp[1].mem.n_wr_beat : g_hp[1].mem.n_rd_beat);
      2: return longint'(w ? g_hp[2].mem.n_wr_beat : g_hp[2].mem.n_rd_beat);
      default: return longint'(w ? g_hp[3].mem.n_wr_beat : g_hp[3].mem.n_rd_beat);
    endcase
  endfunction

  // HP ports of the IP in slot s (system.md 1.3): bit k = HP k
  function automatic logic [3:0] ports_of(int s);
    case (s)
      0: return BUILD == 0 && VAR == 1 ? 4'b0101 : 4'b0001;  // gemv_acc (A2: slice 1 on HP2)
      1: return 4'b0001;                                  // pim
      2: return BUILD == 1 ? 4'b0110 : 4'b0010;           // attn (P: H_PAR 2 reads HP2 too)
      3: return 4'b1000;                                  // vec
      default: return 4'b0000;
    endcase
  endfunction
  logic [3:0] hung = '0;
  int n_inj = 0;
  function automatic void inj_port(int k, int kind, int on);
    case (k)
      0: begin
        if (!on) g_hp[0].mem.inj_clear();
        else if (kind == 1) g_hp[0].mem.inj_rd_err(0, 64'h1_0000_0000, 2'b10);
        else if (kind == 2) g_hp[0].mem.inj_wr_err(0, 64'h1_0000_0000, 2'b10);
        else g_hp[0].mem.inj_hang(1'b1, 1'b1);
      end
      1: begin
        if (!on) g_hp[1].mem.inj_clear();
        else if (kind == 1) g_hp[1].mem.inj_rd_err(0, 64'h1_0000_0000, 2'b10);
        else if (kind == 2) g_hp[1].mem.inj_wr_err(0, 64'h1_0000_0000, 2'b10);
        else g_hp[1].mem.inj_hang(1'b1, 1'b1);
      end
      2: begin
        if (!on) g_hp[2].mem.inj_clear();
        else if (kind == 1) g_hp[2].mem.inj_rd_err(0, 64'h1_0000_0000, 2'b10);
        else if (kind == 2) g_hp[2].mem.inj_wr_err(0, 64'h1_0000_0000, 2'b10);
        else g_hp[2].mem.inj_hang(1'b1, 1'b1);
      end
      default: begin
        if (!on) g_hp[3].mem.inj_clear();
        else if (kind == 1) g_hp[3].mem.inj_rd_err(0, 64'h1_0000_0000, 2'b10);
        else if (kind == 2) g_hp[3].mem.inj_wr_err(0, 64'h1_0000_0000, 2'b10);
        else g_hp[3].mem.inj_hang(1'b1, 1'b1);
      end
    endcase
  endfunction
  // kind 1 SLVERR on reads, 2 SLVERR on writes, 3 hang (R and B); on 0 ends the error windows
  function automatic void sv_inj(input int s, input int kind, input int on);
    logic [3:0] p = ports_of(s);
    for (int k = 0; k < 4; k++)
      if (p[k]) begin
        inj_port(k, kind, on);
        if (on && kind == 3) hung[k] = 1'b1;
      end
    if (on) n_inj++;
    $display("tb_sys_fwd: fault %s slot %0d kind %0d (HP ports %b) at cycle %0d", on ? "on" : "off", s, kind, p, cyc);
  endfunction

  // ---------------- main ----------------
  longint wdog = 60_000_000;
  int prof = 0;
  // stall profile of HP port k (see the header)
  function automatic void cfg_port(int k, int st, int rmin, int rmax, int bmin, int bmax);
    case (k)
      0: begin g_hp[0].mem.cfg_stall(st, st, st, st, st); g_hp[0].mem.cfg_lat(rmin, rmax, bmin, bmax); end
      1: begin g_hp[1].mem.cfg_stall(st, st, st, st, st); g_hp[1].mem.cfg_lat(rmin, rmax, bmin, bmax); end
      2: begin g_hp[2].mem.cfg_stall(st, st, st, st, st); g_hp[2].mem.cfg_lat(rmin, rmax, bmin, bmax); end
      default: begin g_hp[3].mem.cfg_stall(st, st, st, st, st); g_hp[3].mem.cfg_lat(rmin, rmax, bmin, bmax); end
    endcase
  endfunction
  function automatic void cfg_prof(int p);
    for (int k = 0; k < 4; k++)
      case (p)
        0: cfg_port(k, 0, 1, 1, 1, 1);
        1: cfg_port(k, 20, 1, 30, 1, 20);
        2: cfg_port(k, 50, 1, 60, 1, 40);
        default:
          case (k)
            0: cfg_port(k, 20, 1, 30, 1, 20);
            1: cfg_port(k, 50, 1, 60, 1, 40);
            2: cfg_port(k, 30, 5, 40, 1, 10);
            default: cfg_port(k, 10, 1, 80, 1, 60);
          endcase
      endcase
  endfunction

  initial begin
    automatic int unsigned seed;
    automatic int maxd = 0, rc = -1, viol;
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("MAXD=%d", maxd));
    void'($value$plusargs("WDOG=%d", wdog));
    void'($value$plusargs("PROF=%d", prof));
    bfm.maxd = maxd;
    cfg_prof(prof);
    $display("tb_sys_fwd: BUILD %s VAR %0d seed %0d MAXD %0d PROF %0d watchdog %0d cycles",
             BUILD == 0 ? "A (sys_a_top)" : "P (sys_p_top)", VAR, seed, maxd, prof, wdog);
    fork
      begin
        repeat (wdog) @(posedge clk);
        $fatal(1, "TB_WATCHDOG tb_sys_fwd: no end after %0d cycles", wdog);
      end
    join_none
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);
    sys_tb_main(rc);
    repeat (50) @(posedge clk);
    if (!hung[0]) g_hp[0].mem.check_idle();
    if (!hung[1]) g_hp[1].mem.check_idle();
    if (!hung[2]) g_hp[2].mem.check_idle();
    if (!hung[3]) g_hp[3].mem.check_idle();
    g_hp[0].mem.report(); g_hp[1].mem.report(); g_hp[2].mem.report(); g_hp[3].mem.report();
    if (prof != 0) begin
      g_hp[0].mem.report_stall(); g_hp[1].mem.report_stall();
      g_hp[2].mem.report_stall(); g_hp[3].mem.report_stall();
    end
    viol = g_hp[0].mem.n_viol + g_hp[1].mem.n_viol + g_hp[2].mem.n_viol + g_hp[3].mem.n_viol;
    $display("tb_sys_fwd: program checks %0d failed, AXI memory model violations %0d, hung ports %b, cycles %0d",
             rc, viol, hung, cyc);
    if (rc == 0 && viol == 0) $display("TB_RESULT: PASS");
    else $display("TB_RESULT: FAIL");
    $finish;
  end

endmodule
