// sys_p_top: system top of build P (L4, docs/spec/system.md 1.2, 1.3, 1.4, 1.7). Instances and
// wiring only (design-methodology.md): axil_xbar + pim_top + attn_top + vec_top. No logic.
//
// Build P (260K): pim_top NB 4, LB 16, DEPTH 4096 (slot 1), attn_top H_PAR 2, KV_SRC 0 (BRAM KV),
// HS_MAX 8, TMAX 512, NKV 4, NL 5, KW 12, VW 8 (slot 2), vec_top N_MAX 1024, IDX_W 16 (slot 3); slot 0
// (gemv_acc) absent. The parameter defaults are the build P values of system.md 1.2 (vec N_MAX 1024:
// decision O7); the IP parameters are passed through (PI_*, AT_*, VE_*). Variant PD (system.md 1.2):
// AT_KV_SRC 1 with the same wiring.
//
// GP0 slots (axil_xbar, slot = s_axi addr[15:12], 4 KiB each, SLOT_EN 4'b1110):
//   0 absent (reads 0), 1 pim_top, 2 attn_top, 3 vec_top, 4..15 absent (reads 0).
// HP ports (system.md 1.3):
//   HP0  R: pim                       W: pim
//   HP1  R: attn engine 0             W: attn
//   HP2  R: attn engine 1 (AT_H_PAR 2), otherwise tied off      W: tied off
//   HP3  R: vec                       W: vec
// Port names: s_axi_* (AXI4-Lite from GP0, S_ADDR_W bits), m_hp<k>_axi_* (AXI4 master toward
// S_AXI_HP<k>, k = 0..3, 64-bit data, IDW-bit IDs; suffix _o / _i as seen from this module). Every
// HP port has the full read channel set (AR, R) and write channel set (AW, W, B); the read set and
// the write set of one port may come from different IPs (system.md 1.3). An unused channel set is
// tied off: VALID 0, READY 1 (RREADY / BREADY), every other output 0. All four HP ports are
// always present so that the two builds have the same port list (one block design shell).
// Clock and reset: one clock (FCLK_CLK0) and one reset (proc_sys_reset peripheral_aresetn) for every
// instance (no CDC, system.md 1.3).
module sys_p_top #(
  parameter int S_ADDR_W      = 16,    // GP0 address bits seen by the xbar (64 KiB segment)
  parameter int XB_REG        = 1,     // axil_xbar register slice (1: no combinational path)
  parameter int IDW           = 1,     // AXI ID width of every IP master port
  parameter int MAX_BURST     = 16,    // AXI3 / HP burst limit
  parameter int OUTS          = 4,
  parameter int FCLK_MHZ      = 100,
  // pim_top
  parameter int PI_NB         = 4,
  parameter int PI_LB         = 16,
  parameter int PI_DEPTH      = 4096,
  parameter int PI_NMAX       = 1024,
  parameter int PI_CMD_DEPTH  = 32,
  parameter int PI_DOT_PIPE   = 2,
  parameter int PI_SCALE_PIPE = 3,
  parameter int PI_Y_DEPTH    = 32,
  // attn_top
  parameter int AT_H_PAR      = 2,
  parameter int AT_KV_SRC     = 0,
  parameter int AT_HS_MAX     = 8,
  parameter int AT_TMAX       = 512,
  parameter int AT_NKV        = 4,
  parameter int AT_NL         = 5,
  parameter int AT_KW         = 12,
  parameter int AT_VW         = 8,
  parameter int AT_CH         = 16,
  parameter int AT_DOT_PIPE   = 2,
  parameter int AT_SH_PIPE    = 1,
  parameter int AT_RS_PIPE    = 1,
  parameter int AT_LUT_PIPE   = 2,
  parameter int AT_OUT_DEPTH  = 16,
  // vec_top
  parameter int VE_N_MAX      = 1024,
  parameter int VE_IDX_W      = 16,
  parameter int VE_LUT_PIPE   = 2,
  parameter int VE_Q_DEPTH    = 8
) (
  input  logic                clk,
  input  logic                rst_n,           // async assert, sync deassert (all IPs)
  // ---- AXI4-Lite slave (from M_AXI_GP0, register slots of the IPs) ----
  input  logic [S_ADDR_W-1:0] s_axi_awaddr_i,
  input  logic [2:0]          s_axi_awprot_i,
  input  logic                s_axi_awvalid_i,
  output logic                s_axi_awready_o,
  input  logic [31:0]         s_axi_wdata_i,
  input  logic [3:0]          s_axi_wstrb_i,
  input  logic                s_axi_wvalid_i,
  output logic                s_axi_wready_o,
  output logic [1:0]          s_axi_bresp_o,
  output logic                s_axi_bvalid_o,
  input  logic                s_axi_bready_i,
  input  logic [S_ADDR_W-1:0] s_axi_araddr_i,
  input  logic [2:0]          s_axi_arprot_i,
  input  logic                s_axi_arvalid_i,
  output logic                s_axi_arready_o,
  output logic [31:0]         s_axi_rdata_o,
  output logic [1:0]          s_axi_rresp_o,
  output logic                s_axi_rvalid_o,
  input  logic                s_axi_rready_i,
  // ---- S_AXI_HP0 (AXI4 master, 64-bit data) ----
  output logic [IDW-1:0]      m_hp0_axi_awid_o,
  output logic [31:0]         m_hp0_axi_awaddr_o,
  output logic [7:0]          m_hp0_axi_awlen_o,
  output logic [2:0]          m_hp0_axi_awsize_o,
  output logic [1:0]          m_hp0_axi_awburst_o,
  output logic                m_hp0_axi_awlock_o,
  output logic [3:0]          m_hp0_axi_awcache_o,
  output logic [2:0]          m_hp0_axi_awprot_o,
  output logic [3:0]          m_hp0_axi_awqos_o,
  output logic                m_hp0_axi_awvalid_o,
  input  logic                m_hp0_axi_awready_i,
  output logic [63:0]         m_hp0_axi_wdata_o,
  output logic [7:0]          m_hp0_axi_wstrb_o,
  output logic                m_hp0_axi_wlast_o,
  output logic                m_hp0_axi_wvalid_o,
  input  logic                m_hp0_axi_wready_i,
  input  logic [IDW-1:0]      m_hp0_axi_bid_i,
  input  logic [1:0]          m_hp0_axi_bresp_i,
  input  logic                m_hp0_axi_bvalid_i,
  output logic                m_hp0_axi_bready_o,
  output logic [IDW-1:0]      m_hp0_axi_arid_o,
  output logic [31:0]         m_hp0_axi_araddr_o,
  output logic [7:0]          m_hp0_axi_arlen_o,
  output logic [2:0]          m_hp0_axi_arsize_o,
  output logic [1:0]          m_hp0_axi_arburst_o,
  output logic                m_hp0_axi_arlock_o,
  output logic [3:0]          m_hp0_axi_arcache_o,
  output logic [2:0]          m_hp0_axi_arprot_o,
  output logic [3:0]          m_hp0_axi_arqos_o,
  output logic                m_hp0_axi_arvalid_o,
  input  logic                m_hp0_axi_arready_i,
  input  logic [IDW-1:0]      m_hp0_axi_rid_i,
  input  logic [63:0]         m_hp0_axi_rdata_i,
  input  logic [1:0]          m_hp0_axi_rresp_i,
  input  logic                m_hp0_axi_rlast_i,
  input  logic                m_hp0_axi_rvalid_i,
  output logic                m_hp0_axi_rready_o,
  // ---- S_AXI_HP1 (AXI4 master, 64-bit data) ----
  output logic [IDW-1:0]      m_hp1_axi_awid_o,
  output logic [31:0]         m_hp1_axi_awaddr_o,
  output logic [7:0]          m_hp1_axi_awlen_o,
  output logic [2:0]          m_hp1_axi_awsize_o,
  output logic [1:0]          m_hp1_axi_awburst_o,
  output logic                m_hp1_axi_awlock_o,
  output logic [3:0]          m_hp1_axi_awcache_o,
  output logic [2:0]          m_hp1_axi_awprot_o,
  output logic [3:0]          m_hp1_axi_awqos_o,
  output logic                m_hp1_axi_awvalid_o,
  input  logic                m_hp1_axi_awready_i,
  output logic [63:0]         m_hp1_axi_wdata_o,
  output logic [7:0]          m_hp1_axi_wstrb_o,
  output logic                m_hp1_axi_wlast_o,
  output logic                m_hp1_axi_wvalid_o,
  input  logic                m_hp1_axi_wready_i,
  input  logic [IDW-1:0]      m_hp1_axi_bid_i,
  input  logic [1:0]          m_hp1_axi_bresp_i,
  input  logic                m_hp1_axi_bvalid_i,
  output logic                m_hp1_axi_bready_o,
  output logic [IDW-1:0]      m_hp1_axi_arid_o,
  output logic [31:0]         m_hp1_axi_araddr_o,
  output logic [7:0]          m_hp1_axi_arlen_o,
  output logic [2:0]          m_hp1_axi_arsize_o,
  output logic [1:0]          m_hp1_axi_arburst_o,
  output logic                m_hp1_axi_arlock_o,
  output logic [3:0]          m_hp1_axi_arcache_o,
  output logic [2:0]          m_hp1_axi_arprot_o,
  output logic [3:0]          m_hp1_axi_arqos_o,
  output logic                m_hp1_axi_arvalid_o,
  input  logic                m_hp1_axi_arready_i,
  input  logic [IDW-1:0]      m_hp1_axi_rid_i,
  input  logic [63:0]         m_hp1_axi_rdata_i,
  input  logic [1:0]          m_hp1_axi_rresp_i,
  input  logic                m_hp1_axi_rlast_i,
  input  logic                m_hp1_axi_rvalid_i,
  output logic                m_hp1_axi_rready_o,
  // ---- S_AXI_HP2 (AXI4 master, 64-bit data) ----
  output logic [IDW-1:0]      m_hp2_axi_awid_o,
  output logic [31:0]         m_hp2_axi_awaddr_o,
  output logic [7:0]          m_hp2_axi_awlen_o,
  output logic [2:0]          m_hp2_axi_awsize_o,
  output logic [1:0]          m_hp2_axi_awburst_o,
  output logic                m_hp2_axi_awlock_o,
  output logic [3:0]          m_hp2_axi_awcache_o,
  output logic [2:0]          m_hp2_axi_awprot_o,
  output logic [3:0]          m_hp2_axi_awqos_o,
  output logic                m_hp2_axi_awvalid_o,
  input  logic                m_hp2_axi_awready_i,
  output logic [63:0]         m_hp2_axi_wdata_o,
  output logic [7:0]          m_hp2_axi_wstrb_o,
  output logic                m_hp2_axi_wlast_o,
  output logic                m_hp2_axi_wvalid_o,
  input  logic                m_hp2_axi_wready_i,
  input  logic [IDW-1:0]      m_hp2_axi_bid_i,
  input  logic [1:0]          m_hp2_axi_bresp_i,
  input  logic                m_hp2_axi_bvalid_i,
  output logic                m_hp2_axi_bready_o,
  output logic [IDW-1:0]      m_hp2_axi_arid_o,
  output logic [31:0]         m_hp2_axi_araddr_o,
  output logic [7:0]          m_hp2_axi_arlen_o,
  output logic [2:0]          m_hp2_axi_arsize_o,
  output logic [1:0]          m_hp2_axi_arburst_o,
  output logic                m_hp2_axi_arlock_o,
  output logic [3:0]          m_hp2_axi_arcache_o,
  output logic [2:0]          m_hp2_axi_arprot_o,
  output logic [3:0]          m_hp2_axi_arqos_o,
  output logic                m_hp2_axi_arvalid_o,
  input  logic                m_hp2_axi_arready_i,
  input  logic [IDW-1:0]      m_hp2_axi_rid_i,
  input  logic [63:0]         m_hp2_axi_rdata_i,
  input  logic [1:0]          m_hp2_axi_rresp_i,
  input  logic                m_hp2_axi_rlast_i,
  input  logic                m_hp2_axi_rvalid_i,
  output logic                m_hp2_axi_rready_o,
  // ---- S_AXI_HP3 (AXI4 master, 64-bit data) ----
  output logic [IDW-1:0]      m_hp3_axi_awid_o,
  output logic [31:0]         m_hp3_axi_awaddr_o,
  output logic [7:0]          m_hp3_axi_awlen_o,
  output logic [2:0]          m_hp3_axi_awsize_o,
  output logic [1:0]          m_hp3_axi_awburst_o,
  output logic                m_hp3_axi_awlock_o,
  output logic [3:0]          m_hp3_axi_awcache_o,
  output logic [2:0]          m_hp3_axi_awprot_o,
  output logic [3:0]          m_hp3_axi_awqos_o,
  output logic                m_hp3_axi_awvalid_o,
  input  logic                m_hp3_axi_awready_i,
  output logic [63:0]         m_hp3_axi_wdata_o,
  output logic [7:0]          m_hp3_axi_wstrb_o,
  output logic                m_hp3_axi_wlast_o,
  output logic                m_hp3_axi_wvalid_o,
  input  logic                m_hp3_axi_wready_i,
  input  logic [IDW-1:0]      m_hp3_axi_bid_i,
  input  logic [1:0]          m_hp3_axi_bresp_i,
  input  logic                m_hp3_axi_bvalid_i,
  output logic                m_hp3_axi_bready_o,
  output logic [IDW-1:0]      m_hp3_axi_arid_o,
  output logic [31:0]         m_hp3_axi_araddr_o,
  output logic [7:0]          m_hp3_axi_arlen_o,
  output logic [2:0]          m_hp3_axi_arsize_o,
  output logic [1:0]          m_hp3_axi_arburst_o,
  output logic                m_hp3_axi_arlock_o,
  output logic [3:0]          m_hp3_axi_arcache_o,
  output logic [2:0]          m_hp3_axi_arprot_o,
  output logic [3:0]          m_hp3_axi_arqos_o,
  output logic                m_hp3_axi_arvalid_o,
  input  logic                m_hp3_axi_arready_i,
  input  logic [IDW-1:0]      m_hp3_axi_rid_i,
  input  logic [63:0]         m_hp3_axi_rdata_i,
  input  logic [1:0]          m_hp3_axi_rresp_i,
  input  logic                m_hp3_axi_rlast_i,
  input  logic                m_hp3_axi_rvalid_i,
  output logic                m_hp3_axi_rready_o
);

  if (AT_H_PAR != 1 && AT_H_PAR != 2) begin : g_bad_at_hpar
    $error("sys_p_top: AT_H_PAR=%0d must be 1 or 2", AT_H_PAR);
  end

  localparam logic [15:0] SLOT_EN = 16'b1110;   // slots 1 (pim), 2 (attn), 3 (vec)

  // ---------------- AXI4-Lite crossbar (GP0 -> IP CSR slots) ----------------
  logic [3:0][11:0] xb_awaddr, xb_araddr;
  logic [3:0][2:0]  xb_awprot, xb_arprot;
  logic [3:0]       xb_awvalid, xb_awready, xb_wvalid, xb_wready, xb_bvalid, xb_bready;
  logic [3:0]       xb_arvalid, xb_arready, xb_rvalid, xb_rready;
  logic [3:0][31:0] xb_wdata, xb_rdata;
  logic [3:0][3:0]  xb_wstrb;
  logic [3:0][1:0]  xb_bresp, xb_rresp;

  axil_xbar #(.N(4), .SLOT_W(4), .S_ADDR_W(S_ADDR_W), .SLOT_EN(SLOT_EN), .REG(XB_REG)) u_xbar (
    .clk, .rst_n,
    .s_axi_awaddr_i, .s_axi_awprot_i, .s_axi_awvalid_i, .s_axi_awready_o,
    .s_axi_wdata_i, .s_axi_wstrb_i, .s_axi_wvalid_i, .s_axi_wready_o,
    .s_axi_bresp_o, .s_axi_bvalid_o, .s_axi_bready_i,
    .s_axi_araddr_i, .s_axi_arprot_i, .s_axi_arvalid_i, .s_axi_arready_o,
    .s_axi_rdata_o, .s_axi_rresp_o, .s_axi_rvalid_o, .s_axi_rready_i,
    .m_axi_awaddr_o(xb_awaddr), .m_axi_awprot_o(xb_awprot), .m_axi_awvalid_o(xb_awvalid),
    .m_axi_awready_i(xb_awready), .m_axi_wdata_o(xb_wdata), .m_axi_wstrb_o(xb_wstrb),
    .m_axi_wvalid_o(xb_wvalid), .m_axi_wready_i(xb_wready), .m_axi_bresp_i(xb_bresp),
    .m_axi_bvalid_i(xb_bvalid), .m_axi_bready_o(xb_bready),
    .m_axi_araddr_o(xb_araddr), .m_axi_arprot_o(xb_arprot), .m_axi_arvalid_o(xb_arvalid),
    .m_axi_arready_i(xb_arready), .m_axi_rdata_i(xb_rdata), .m_axi_rresp_i(xb_rresp),
    .m_axi_rvalid_i(xb_rvalid), .m_axi_rready_o(xb_rready));

  // slot 0: no IP in this build (SLOT_EN bit 0 = 0, the xbar ignores these inputs)
  assign xb_awready[0] = 1'b0;
  assign xb_wready[0]  = 1'b0;
  assign xb_bresp[0]   = 2'b00;
  assign xb_bvalid[0]  = 1'b0;
  assign xb_arready[0] = 1'b0;
  assign xb_rdata[0]   = 32'd0;
  assign xb_rresp[0]   = 2'b00;
  assign xb_rvalid[0]  = 1'b0;

  // ---------------- slot 1: pim_top (HP0) ----------------
  logic [0:0][IDW-1:0] pi_arid;
  logic [0:0][31:0] pi_araddr;
  logic [0:0][7:0] pi_arlen;
  logic [0:0][2:0] pi_arsize;
  logic [0:0][1:0] pi_arburst;
  logic [0:0] pi_arlock;
  logic [0:0][3:0] pi_arcache;
  logic [0:0][2:0] pi_arprot;
  logic [0:0][3:0] pi_arqos;
  logic [0:0] pi_arvalid;
  logic [0:0] pi_arready;
  logic [0:0][IDW-1:0] pi_rid;
  logic [0:0][63:0] pi_rdata;
  logic [0:0][1:0] pi_rresp;
  logic [0:0] pi_rlast;
  logic [0:0] pi_rvalid;
  logic [0:0] pi_rready;
  logic [IDW-1:0] pi_awid;
  logic [31:0] pi_awaddr;
  logic [7:0] pi_awlen;
  logic [2:0] pi_awsize;
  logic [1:0] pi_awburst;
  logic pi_awlock;
  logic [3:0] pi_awcache;
  logic [2:0] pi_awprot;
  logic [3:0] pi_awqos;
  logic pi_awvalid;
  logic pi_awready;
  logic [63:0] pi_wdata;
  logic [7:0] pi_wstrb;
  logic pi_wlast;
  logic pi_wvalid;
  logic pi_wready;
  logic [IDW-1:0] pi_bid;
  logic [1:0] pi_bresp;
  logic pi_bvalid;
  logic pi_bready;

  pim_top #(.NB(PI_NB), .LB(PI_LB), .DEPTH(PI_DEPTH), .NMAX(PI_NMAX), .CMD_DEPTH(PI_CMD_DEPTH),
            .DOT_PIPE(PI_DOT_PIPE), .SCALE_PIPE(PI_SCALE_PIPE), .Y_DEPTH(PI_Y_DEPTH),
            .MAX_BURST(MAX_BURST), .OUTS(OUTS), .IDW(IDW), .FCLK_MHZ(FCLK_MHZ), .ADDR_W(12)) u_pi (
    .clk, .rst_n,
    .s_axi_awaddr_i(xb_awaddr[1]), .s_axi_awprot_i(xb_awprot[1]), .s_axi_awvalid_i(xb_awvalid[1]),
    .s_axi_awready_o(xb_awready[1]), .s_axi_wdata_i(xb_wdata[1]), .s_axi_wstrb_i(xb_wstrb[1]),
    .s_axi_wvalid_i(xb_wvalid[1]), .s_axi_wready_o(xb_wready[1]), .s_axi_bresp_o(xb_bresp[1]),
    .s_axi_bvalid_o(xb_bvalid[1]), .s_axi_bready_i(xb_bready[1]), .s_axi_araddr_i(xb_araddr[1]),
    .s_axi_arprot_i(xb_arprot[1]), .s_axi_arvalid_i(xb_arvalid[1]), .s_axi_arready_o(xb_arready[1]),
    .s_axi_rdata_o(xb_rdata[1]), .s_axi_rresp_o(xb_rresp[1]), .s_axi_rvalid_o(xb_rvalid[1]),
    .s_axi_rready_i(xb_rready[1]),
    .m_axi_awid_o(pi_awid),
    .m_axi_awaddr_o(pi_awaddr),
    .m_axi_awlen_o(pi_awlen),
    .m_axi_awsize_o(pi_awsize),
    .m_axi_awburst_o(pi_awburst),
    .m_axi_awlock_o(pi_awlock),
    .m_axi_awcache_o(pi_awcache),
    .m_axi_awprot_o(pi_awprot),
    .m_axi_awqos_o(pi_awqos),
    .m_axi_awvalid_o(pi_awvalid),
    .m_axi_awready_i(pi_awready),
    .m_axi_wdata_o(pi_wdata),
    .m_axi_wstrb_o(pi_wstrb),
    .m_axi_wlast_o(pi_wlast),
    .m_axi_wvalid_o(pi_wvalid),
    .m_axi_wready_i(pi_wready),
    .m_axi_bid_i(pi_bid),
    .m_axi_bresp_i(pi_bresp),
    .m_axi_bvalid_i(pi_bvalid),
    .m_axi_bready_o(pi_bready),
    .m_axi_arid_o(pi_arid[0]),
    .m_axi_araddr_o(pi_araddr[0]),
    .m_axi_arlen_o(pi_arlen[0]),
    .m_axi_arsize_o(pi_arsize[0]),
    .m_axi_arburst_o(pi_arburst[0]),
    .m_axi_arlock_o(pi_arlock[0]),
    .m_axi_arcache_o(pi_arcache[0]),
    .m_axi_arprot_o(pi_arprot[0]),
    .m_axi_arqos_o(pi_arqos[0]),
    .m_axi_arvalid_o(pi_arvalid[0]),
    .m_axi_arready_i(pi_arready[0]),
    .m_axi_rid_i(pi_rid[0]),
    .m_axi_rdata_i(pi_rdata[0]),
    .m_axi_rresp_i(pi_rresp[0]),
    .m_axi_rlast_i(pi_rlast[0]),
    .m_axi_rvalid_i(pi_rvalid[0]),
    .m_axi_rready_o(pi_rready[0])
  );

  // ---------------- slot 2: attn_top (HP1, HP2 read with AT_H_PAR 2) ----------------
  logic [AT_H_PAR-1:0][IDW-1:0] at_arid;
  logic [AT_H_PAR-1:0][31:0] at_araddr;
  logic [AT_H_PAR-1:0][7:0] at_arlen;
  logic [AT_H_PAR-1:0][2:0] at_arsize;
  logic [AT_H_PAR-1:0][1:0] at_arburst;
  logic [AT_H_PAR-1:0] at_arlock;
  logic [AT_H_PAR-1:0][3:0] at_arcache;
  logic [AT_H_PAR-1:0][2:0] at_arprot;
  logic [AT_H_PAR-1:0][3:0] at_arqos;
  logic [AT_H_PAR-1:0] at_arvalid;
  logic [AT_H_PAR-1:0] at_arready;
  logic [AT_H_PAR-1:0][IDW-1:0] at_rid;
  logic [AT_H_PAR-1:0][63:0] at_rdata;
  logic [AT_H_PAR-1:0][1:0] at_rresp;
  logic [AT_H_PAR-1:0] at_rlast;
  logic [AT_H_PAR-1:0] at_rvalid;
  logic [AT_H_PAR-1:0] at_rready;
  logic [IDW-1:0] at_awid;
  logic [31:0] at_awaddr;
  logic [7:0] at_awlen;
  logic [2:0] at_awsize;
  logic [1:0] at_awburst;
  logic at_awlock;
  logic [3:0] at_awcache;
  logic [2:0] at_awprot;
  logic [3:0] at_awqos;
  logic at_awvalid;
  logic at_awready;
  logic [63:0] at_wdata;
  logic [7:0] at_wstrb;
  logic at_wlast;
  logic at_wvalid;
  logic at_wready;
  logic [IDW-1:0] at_bid;
  logic [1:0] at_bresp;
  logic at_bvalid;
  logic at_bready;

  attn_top #(.H_PAR(AT_H_PAR), .KV_SRC(AT_KV_SRC), .HS_MAX(AT_HS_MAX), .TMAX(AT_TMAX), .NKV(AT_NKV),
             .NL(AT_NL), .KW(AT_KW), .VW(AT_VW), .CH(AT_CH), .DOT_PIPE(AT_DOT_PIPE),
             .SH_PIPE(AT_SH_PIPE), .RS_PIPE(AT_RS_PIPE), .LUT_PIPE(AT_LUT_PIPE),
             .OUT_DEPTH(AT_OUT_DEPTH), .MAX_BURST(MAX_BURST), .OUTS(OUTS), .IDW(IDW),
             .FCLK_MHZ(FCLK_MHZ), .ADDR_W(12)) u_at (
    .clk, .rst_n,
    .s_axi_awaddr_i(xb_awaddr[2]), .s_axi_awprot_i(xb_awprot[2]), .s_axi_awvalid_i(xb_awvalid[2]),
    .s_axi_awready_o(xb_awready[2]), .s_axi_wdata_i(xb_wdata[2]), .s_axi_wstrb_i(xb_wstrb[2]),
    .s_axi_wvalid_i(xb_wvalid[2]), .s_axi_wready_o(xb_wready[2]), .s_axi_bresp_o(xb_bresp[2]),
    .s_axi_bvalid_o(xb_bvalid[2]), .s_axi_bready_i(xb_bready[2]), .s_axi_araddr_i(xb_araddr[2]),
    .s_axi_arprot_i(xb_arprot[2]), .s_axi_arvalid_i(xb_arvalid[2]), .s_axi_arready_o(xb_arready[2]),
    .s_axi_rdata_o(xb_rdata[2]), .s_axi_rresp_o(xb_rresp[2]), .s_axi_rvalid_o(xb_rvalid[2]),
    .s_axi_rready_i(xb_rready[2]),
    .m_axi_awid_o(at_awid),
    .m_axi_awaddr_o(at_awaddr),
    .m_axi_awlen_o(at_awlen),
    .m_axi_awsize_o(at_awsize),
    .m_axi_awburst_o(at_awburst),
    .m_axi_awlock_o(at_awlock),
    .m_axi_awcache_o(at_awcache),
    .m_axi_awprot_o(at_awprot),
    .m_axi_awqos_o(at_awqos),
    .m_axi_awvalid_o(at_awvalid),
    .m_axi_awready_i(at_awready),
    .m_axi_wdata_o(at_wdata),
    .m_axi_wstrb_o(at_wstrb),
    .m_axi_wlast_o(at_wlast),
    .m_axi_wvalid_o(at_wvalid),
    .m_axi_wready_i(at_wready),
    .m_axi_bid_i(at_bid),
    .m_axi_bresp_i(at_bresp),
    .m_axi_bvalid_i(at_bvalid),
    .m_axi_bready_o(at_bready),
    .m_axi_arid_o(at_arid),
    .m_axi_araddr_o(at_araddr),
    .m_axi_arlen_o(at_arlen),
    .m_axi_arsize_o(at_arsize),
    .m_axi_arburst_o(at_arburst),
    .m_axi_arlock_o(at_arlock),
    .m_axi_arcache_o(at_arcache),
    .m_axi_arprot_o(at_arprot),
    .m_axi_arqos_o(at_arqos),
    .m_axi_arvalid_o(at_arvalid),
    .m_axi_arready_i(at_arready),
    .m_axi_rid_i(at_rid),
    .m_axi_rdata_i(at_rdata),
    .m_axi_rresp_i(at_rresp),
    .m_axi_rlast_i(at_rlast),
    .m_axi_rvalid_i(at_rvalid),
    .m_axi_rready_o(at_rready)
  );

  // ---------------- slot 3: vec_top (HP3) ----------------
  logic [0:0][IDW-1:0] ve_arid;
  logic [0:0][31:0] ve_araddr;
  logic [0:0][7:0] ve_arlen;
  logic [0:0][2:0] ve_arsize;
  logic [0:0][1:0] ve_arburst;
  logic [0:0] ve_arlock;
  logic [0:0][3:0] ve_arcache;
  logic [0:0][2:0] ve_arprot;
  logic [0:0][3:0] ve_arqos;
  logic [0:0] ve_arvalid;
  logic [0:0] ve_arready;
  logic [0:0][IDW-1:0] ve_rid;
  logic [0:0][63:0] ve_rdata;
  logic [0:0][1:0] ve_rresp;
  logic [0:0] ve_rlast;
  logic [0:0] ve_rvalid;
  logic [0:0] ve_rready;
  logic [IDW-1:0] ve_awid;
  logic [31:0] ve_awaddr;
  logic [7:0] ve_awlen;
  logic [2:0] ve_awsize;
  logic [1:0] ve_awburst;
  logic ve_awlock;
  logic [3:0] ve_awcache;
  logic [2:0] ve_awprot;
  logic [3:0] ve_awqos;
  logic ve_awvalid;
  logic ve_awready;
  logic [63:0] ve_wdata;
  logic [7:0] ve_wstrb;
  logic ve_wlast;
  logic ve_wvalid;
  logic ve_wready;
  logic [IDW-1:0] ve_bid;
  logic [1:0] ve_bresp;
  logic ve_bvalid;
  logic ve_bready;

  vec_top #(.N_MAX(VE_N_MAX), .IDX_W(VE_IDX_W), .LUT_PIPE(VE_LUT_PIPE), .Q_DEPTH(VE_Q_DEPTH),
            .MAX_BURST(MAX_BURST), .OUTS(OUTS), .IDW(IDW), .FCLK_MHZ(FCLK_MHZ), .ADDR_W(12)) u_ve (
    .clk, .rst_n,
    .s_axi_awaddr_i(xb_awaddr[3]), .s_axi_awprot_i(xb_awprot[3]), .s_axi_awvalid_i(xb_awvalid[3]),
    .s_axi_awready_o(xb_awready[3]), .s_axi_wdata_i(xb_wdata[3]), .s_axi_wstrb_i(xb_wstrb[3]),
    .s_axi_wvalid_i(xb_wvalid[3]), .s_axi_wready_o(xb_wready[3]), .s_axi_bresp_o(xb_bresp[3]),
    .s_axi_bvalid_o(xb_bvalid[3]), .s_axi_bready_i(xb_bready[3]), .s_axi_araddr_i(xb_araddr[3]),
    .s_axi_arprot_i(xb_arprot[3]), .s_axi_arvalid_i(xb_arvalid[3]), .s_axi_arready_o(xb_arready[3]),
    .s_axi_rdata_o(xb_rdata[3]), .s_axi_rresp_o(xb_rresp[3]), .s_axi_rvalid_o(xb_rvalid[3]),
    .s_axi_rready_i(xb_rready[3]),
    .m_axi_awid_o(ve_awid),
    .m_axi_awaddr_o(ve_awaddr),
    .m_axi_awlen_o(ve_awlen),
    .m_axi_awsize_o(ve_awsize),
    .m_axi_awburst_o(ve_awburst),
    .m_axi_awlock_o(ve_awlock),
    .m_axi_awcache_o(ve_awcache),
    .m_axi_awprot_o(ve_awprot),
    .m_axi_awqos_o(ve_awqos),
    .m_axi_awvalid_o(ve_awvalid),
    .m_axi_awready_i(ve_awready),
    .m_axi_wdata_o(ve_wdata),
    .m_axi_wstrb_o(ve_wstrb),
    .m_axi_wlast_o(ve_wlast),
    .m_axi_wvalid_o(ve_wvalid),
    .m_axi_wready_i(ve_wready),
    .m_axi_bid_i(ve_bid),
    .m_axi_bresp_i(ve_bresp),
    .m_axi_bvalid_i(ve_bvalid),
    .m_axi_bready_o(ve_bready),
    .m_axi_arid_o(ve_arid[0]),
    .m_axi_araddr_o(ve_araddr[0]),
    .m_axi_arlen_o(ve_arlen[0]),
    .m_axi_arsize_o(ve_arsize[0]),
    .m_axi_arburst_o(ve_arburst[0]),
    .m_axi_arlock_o(ve_arlock[0]),
    .m_axi_arcache_o(ve_arcache[0]),
    .m_axi_arprot_o(ve_arprot[0]),
    .m_axi_arqos_o(ve_arqos[0]),
    .m_axi_arvalid_o(ve_arvalid[0]),
    .m_axi_arready_i(ve_arready[0]),
    .m_axi_rid_i(ve_rid[0]),
    .m_axi_rdata_i(ve_rdata[0]),
    .m_axi_rresp_i(ve_rresp[0]),
    .m_axi_rlast_i(ve_rlast[0]),
    .m_axi_rvalid_i(ve_rvalid[0]),
    .m_axi_rready_o(ve_rready[0])
  );

  // ---------------- HP ports ----------------
  // HP0: pim read and write
  assign m_hp0_axi_arid_o = pi_arid[0];
  assign m_hp0_axi_araddr_o = pi_araddr[0];
  assign m_hp0_axi_arlen_o = pi_arlen[0];
  assign m_hp0_axi_arsize_o = pi_arsize[0];
  assign m_hp0_axi_arburst_o = pi_arburst[0];
  assign m_hp0_axi_arlock_o = pi_arlock[0];
  assign m_hp0_axi_arcache_o = pi_arcache[0];
  assign m_hp0_axi_arprot_o = pi_arprot[0];
  assign m_hp0_axi_arqos_o = pi_arqos[0];
  assign m_hp0_axi_arvalid_o = pi_arvalid[0];
  assign pi_arready[0] = m_hp0_axi_arready_i;
  assign pi_rid[0] = m_hp0_axi_rid_i;
  assign pi_rdata[0] = m_hp0_axi_rdata_i;
  assign pi_rresp[0] = m_hp0_axi_rresp_i;
  assign pi_rlast[0] = m_hp0_axi_rlast_i;
  assign pi_rvalid[0] = m_hp0_axi_rvalid_i;
  assign m_hp0_axi_rready_o = pi_rready[0];
  assign m_hp0_axi_awid_o = pi_awid;
  assign m_hp0_axi_awaddr_o = pi_awaddr;
  assign m_hp0_axi_awlen_o = pi_awlen;
  assign m_hp0_axi_awsize_o = pi_awsize;
  assign m_hp0_axi_awburst_o = pi_awburst;
  assign m_hp0_axi_awlock_o = pi_awlock;
  assign m_hp0_axi_awcache_o = pi_awcache;
  assign m_hp0_axi_awprot_o = pi_awprot;
  assign m_hp0_axi_awqos_o = pi_awqos;
  assign m_hp0_axi_awvalid_o = pi_awvalid;
  assign pi_awready = m_hp0_axi_awready_i;
  assign m_hp0_axi_wdata_o = pi_wdata;
  assign m_hp0_axi_wstrb_o = pi_wstrb;
  assign m_hp0_axi_wlast_o = pi_wlast;
  assign m_hp0_axi_wvalid_o = pi_wvalid;
  assign pi_wready = m_hp0_axi_wready_i;
  assign pi_bid = m_hp0_axi_bid_i;
  assign pi_bresp = m_hp0_axi_bresp_i;
  assign pi_bvalid = m_hp0_axi_bvalid_i;
  assign m_hp0_axi_bready_o = pi_bready;
  // HP1: attn engine 0 read, attn write
  assign m_hp1_axi_arid_o = at_arid[0];
  assign m_hp1_axi_araddr_o = at_araddr[0];
  assign m_hp1_axi_arlen_o = at_arlen[0];
  assign m_hp1_axi_arsize_o = at_arsize[0];
  assign m_hp1_axi_arburst_o = at_arburst[0];
  assign m_hp1_axi_arlock_o = at_arlock[0];
  assign m_hp1_axi_arcache_o = at_arcache[0];
  assign m_hp1_axi_arprot_o = at_arprot[0];
  assign m_hp1_axi_arqos_o = at_arqos[0];
  assign m_hp1_axi_arvalid_o = at_arvalid[0];
  assign at_arready[0] = m_hp1_axi_arready_i;
  assign at_rid[0] = m_hp1_axi_rid_i;
  assign at_rdata[0] = m_hp1_axi_rdata_i;
  assign at_rresp[0] = m_hp1_axi_rresp_i;
  assign at_rlast[0] = m_hp1_axi_rlast_i;
  assign at_rvalid[0] = m_hp1_axi_rvalid_i;
  assign m_hp1_axi_rready_o = at_rready[0];
  assign m_hp1_axi_awid_o = at_awid;
  assign m_hp1_axi_awaddr_o = at_awaddr;
  assign m_hp1_axi_awlen_o = at_awlen;
  assign m_hp1_axi_awsize_o = at_awsize;
  assign m_hp1_axi_awburst_o = at_awburst;
  assign m_hp1_axi_awlock_o = at_awlock;
  assign m_hp1_axi_awcache_o = at_awcache;
  assign m_hp1_axi_awprot_o = at_awprot;
  assign m_hp1_axi_awqos_o = at_awqos;
  assign m_hp1_axi_awvalid_o = at_awvalid;
  assign at_awready = m_hp1_axi_awready_i;
  assign m_hp1_axi_wdata_o = at_wdata;
  assign m_hp1_axi_wstrb_o = at_wstrb;
  assign m_hp1_axi_wlast_o = at_wlast;
  assign m_hp1_axi_wvalid_o = at_wvalid;
  assign at_wready = m_hp1_axi_wready_i;
  assign at_bid = m_hp1_axi_bid_i;
  assign at_bresp = m_hp1_axi_bresp_i;
  assign at_bvalid = m_hp1_axi_bvalid_i;
  assign m_hp1_axi_bready_o = at_bready;
  // HP2: read = attn engine 1 (AT_H_PAR 2) or tied off; write tied off
  if (AT_H_PAR == 2) begin : g_hp2_at
    assign m_hp2_axi_arid_o = at_arid[1];
    assign m_hp2_axi_araddr_o = at_araddr[1];
    assign m_hp2_axi_arlen_o = at_arlen[1];
    assign m_hp2_axi_arsize_o = at_arsize[1];
    assign m_hp2_axi_arburst_o = at_arburst[1];
    assign m_hp2_axi_arlock_o = at_arlock[1];
    assign m_hp2_axi_arcache_o = at_arcache[1];
    assign m_hp2_axi_arprot_o = at_arprot[1];
    assign m_hp2_axi_arqos_o = at_arqos[1];
    assign m_hp2_axi_arvalid_o = at_arvalid[1];
    assign at_arready[1] = m_hp2_axi_arready_i;
    assign at_rid[1] = m_hp2_axi_rid_i;
    assign at_rdata[1] = m_hp2_axi_rdata_i;
    assign at_rresp[1] = m_hp2_axi_rresp_i;
    assign at_rlast[1] = m_hp2_axi_rlast_i;
    assign at_rvalid[1] = m_hp2_axi_rvalid_i;
    assign m_hp2_axi_rready_o = at_rready[1];
  end else begin : g_hp2_off
    assign m_hp2_axi_arid_o = '0;
    assign m_hp2_axi_araddr_o = '0;
    assign m_hp2_axi_arlen_o = '0;
    assign m_hp2_axi_arsize_o = '0;
    assign m_hp2_axi_arburst_o = '0;
    assign m_hp2_axi_arlock_o = '0;
    assign m_hp2_axi_arcache_o = '0;
    assign m_hp2_axi_arprot_o = '0;
    assign m_hp2_axi_arqos_o = '0;
    assign m_hp2_axi_arvalid_o = '0;
    assign m_hp2_axi_rready_o = 1'b1;
  end
  assign m_hp2_axi_awid_o = '0;
  assign m_hp2_axi_awaddr_o = '0;
  assign m_hp2_axi_awlen_o = '0;
  assign m_hp2_axi_awsize_o = '0;
  assign m_hp2_axi_awburst_o = '0;
  assign m_hp2_axi_awlock_o = '0;
  assign m_hp2_axi_awcache_o = '0;
  assign m_hp2_axi_awprot_o = '0;
  assign m_hp2_axi_awqos_o = '0;
  assign m_hp2_axi_awvalid_o = '0;
  assign m_hp2_axi_wdata_o = '0;
  assign m_hp2_axi_wstrb_o = '0;
  assign m_hp2_axi_wlast_o = '0;
  assign m_hp2_axi_wvalid_o = '0;
  assign m_hp2_axi_bready_o = 1'b1;
  // HP3: vec read and write
  assign m_hp3_axi_arid_o = ve_arid[0];
  assign m_hp3_axi_araddr_o = ve_araddr[0];
  assign m_hp3_axi_arlen_o = ve_arlen[0];
  assign m_hp3_axi_arsize_o = ve_arsize[0];
  assign m_hp3_axi_arburst_o = ve_arburst[0];
  assign m_hp3_axi_arlock_o = ve_arlock[0];
  assign m_hp3_axi_arcache_o = ve_arcache[0];
  assign m_hp3_axi_arprot_o = ve_arprot[0];
  assign m_hp3_axi_arqos_o = ve_arqos[0];
  assign m_hp3_axi_arvalid_o = ve_arvalid[0];
  assign ve_arready[0] = m_hp3_axi_arready_i;
  assign ve_rid[0] = m_hp3_axi_rid_i;
  assign ve_rdata[0] = m_hp3_axi_rdata_i;
  assign ve_rresp[0] = m_hp3_axi_rresp_i;
  assign ve_rlast[0] = m_hp3_axi_rlast_i;
  assign ve_rvalid[0] = m_hp3_axi_rvalid_i;
  assign m_hp3_axi_rready_o = ve_rready[0];
  assign m_hp3_axi_awid_o = ve_awid;
  assign m_hp3_axi_awaddr_o = ve_awaddr;
  assign m_hp3_axi_awlen_o = ve_awlen;
  assign m_hp3_axi_awsize_o = ve_awsize;
  assign m_hp3_axi_awburst_o = ve_awburst;
  assign m_hp3_axi_awlock_o = ve_awlock;
  assign m_hp3_axi_awcache_o = ve_awcache;
  assign m_hp3_axi_awprot_o = ve_awprot;
  assign m_hp3_axi_awqos_o = ve_awqos;
  assign m_hp3_axi_awvalid_o = ve_awvalid;
  assign ve_awready = m_hp3_axi_awready_i;
  assign m_hp3_axi_wdata_o = ve_wdata;
  assign m_hp3_axi_wstrb_o = ve_wstrb;
  assign m_hp3_axi_wlast_o = ve_wlast;
  assign m_hp3_axi_wvalid_o = ve_wvalid;
  assign ve_wready = m_hp3_axi_wready_i;
  assign ve_bid = m_hp3_axi_bid_i;
  assign ve_bresp = m_hp3_axi_bresp_i;
  assign ve_bvalid = m_hp3_axi_bvalid_i;
  assign m_hp3_axi_bready_o = ve_bready;

endmodule
