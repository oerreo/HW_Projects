// bw_bd: Verilog-2001 shell around rtl/l3/bw_top.sv for the Vivado block design (RTL module
// reference). FPGA build only, not simulated (the RTL below it is, tb/bw_top).
//
// Why a shell (as in pqc-ntt-ip fpga/vivado/src): the module reference flow is not known to
// accept a SystemVerilog top with packed 2-D ports, and IP integrator infers interfaces from
// the standard names used here: s_axi_* (AXI4-Lite slave), m00_axi_* and m01_axi_* (AXI4
// masters), aclk, aresetn. Both master interfaces always exist; with P = 1 the m01 outputs
// are tied to 0 and create_project.tcl leaves m01_axi unconnected. UNVERIFIED on Vivado.
module bw_bd #(
  parameter integer P                  = 1,    // ports 1 or 2
  parameter integer MAX_BURST          = 16,   // beats per burst (16 = AXI3 HP limit)
  parameter integer OUTS               = 4,    // outstanding bursts per engine
  parameter integer FCLK_MHZ           = 100,  // CONFIG register only
  parameter integer C_S_AXI_ADDR_WIDTH = 12,
  parameter integer C_M_AXI_ID_WIDTH   = 1
) (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi:m00_axi:m01_axi, ASSOCIATED_RESET aresetn" *)
  input  wire                          aclk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire                          aresetn,
  // AXI4-Lite slave
  input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
  input  wire [2:0]                    s_axi_awprot,
  input  wire                          s_axi_awvalid,
  output wire                          s_axi_awready,
  input  wire [31:0]                   s_axi_wdata,
  input  wire [3:0]                    s_axi_wstrb,
  input  wire                          s_axi_wvalid,
  output wire                          s_axi_wready,
  output wire [1:0]                    s_axi_bresp,
  output wire                          s_axi_bvalid,
  input  wire                          s_axi_bready,
  input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
  input  wire [2:0]                    s_axi_arprot,
  input  wire                          s_axi_arvalid,
  output wire                          s_axi_arready,
  output wire [31:0]                   s_axi_rdata,
  output wire [1:0]                    s_axi_rresp,
  output wire                          s_axi_rvalid,
  input  wire                          s_axi_rready,
  // AXI4 master 0 (HP0)
  output wire [C_M_AXI_ID_WIDTH-1:0]   m00_axi_awid,
  output wire [31:0]                   m00_axi_awaddr,
  output wire [7:0]                    m00_axi_awlen,
  output wire [2:0]                    m00_axi_awsize,
  output wire [1:0]                    m00_axi_awburst,
  output wire                          m00_axi_awlock,
  output wire [3:0]                    m00_axi_awcache,
  output wire [2:0]                    m00_axi_awprot,
  output wire [3:0]                    m00_axi_awqos,
  output wire                          m00_axi_awvalid,
  input  wire                          m00_axi_awready,
  output wire [63:0]                   m00_axi_wdata,
  output wire [7:0]                    m00_axi_wstrb,
  output wire                          m00_axi_wlast,
  output wire                          m00_axi_wvalid,
  input  wire                          m00_axi_wready,
  input  wire [C_M_AXI_ID_WIDTH-1:0]   m00_axi_bid,
  input  wire [1:0]                    m00_axi_bresp,
  input  wire                          m00_axi_bvalid,
  output wire                          m00_axi_bready,
  output wire [C_M_AXI_ID_WIDTH-1:0]   m00_axi_arid,
  output wire [31:0]                   m00_axi_araddr,
  output wire [7:0]                    m00_axi_arlen,
  output wire [2:0]                    m00_axi_arsize,
  output wire [1:0]                    m00_axi_arburst,
  output wire                          m00_axi_arlock,
  output wire [3:0]                    m00_axi_arcache,
  output wire [2:0]                    m00_axi_arprot,
  output wire [3:0]                    m00_axi_arqos,
  output wire                          m00_axi_arvalid,
  input  wire                          m00_axi_arready,
  input  wire [C_M_AXI_ID_WIDTH-1:0]   m00_axi_rid,
  input  wire [63:0]                   m00_axi_rdata,
  input  wire [1:0]                    m00_axi_rresp,
  input  wire                          m00_axi_rlast,
  input  wire                          m00_axi_rvalid,
  output wire                          m00_axi_rready,
  // AXI4 master 1 (HP2), used when P = 2
  output wire [C_M_AXI_ID_WIDTH-1:0]   m01_axi_awid,
  output wire [31:0]                   m01_axi_awaddr,
  output wire [7:0]                    m01_axi_awlen,
  output wire [2:0]                    m01_axi_awsize,
  output wire [1:0]                    m01_axi_awburst,
  output wire                          m01_axi_awlock,
  output wire [3:0]                    m01_axi_awcache,
  output wire [2:0]                    m01_axi_awprot,
  output wire [3:0]                    m01_axi_awqos,
  output wire                          m01_axi_awvalid,
  input  wire                          m01_axi_awready,
  output wire [63:0]                   m01_axi_wdata,
  output wire [7:0]                    m01_axi_wstrb,
  output wire                          m01_axi_wlast,
  output wire                          m01_axi_wvalid,
  input  wire                          m01_axi_wready,
  input  wire [C_M_AXI_ID_WIDTH-1:0]   m01_axi_bid,
  input  wire [1:0]                    m01_axi_bresp,
  input  wire                          m01_axi_bvalid,
  output wire                          m01_axi_bready,
  output wire [C_M_AXI_ID_WIDTH-1:0]   m01_axi_arid,
  output wire [31:0]                   m01_axi_araddr,
  output wire [7:0]                    m01_axi_arlen,
  output wire [2:0]                    m01_axi_arsize,
  output wire [1:0]                    m01_axi_arburst,
  output wire                          m01_axi_arlock,
  output wire [3:0]                    m01_axi_arcache,
  output wire [2:0]                    m01_axi_arprot,
  output wire [3:0]                    m01_axi_arqos,
  output wire                          m01_axi_arvalid,
  input  wire                          m01_axi_arready,
  input  wire [C_M_AXI_ID_WIDTH-1:0]   m01_axi_rid,
  input  wire [63:0]                   m01_axi_rdata,
  input  wire [1:0]                    m01_axi_rresp,
  input  wire                          m01_axi_rlast,
  input  wire                          m01_axi_rvalid,
  output wire                          m01_axi_rready
);

  localparam integer IW = C_M_AXI_ID_WIDTH;

  // port arrays of bw_top, index 0 = m00, 1 = m01
  wire [P*IW-1:0] awid, bid, arid, rid;
  wire [P*32-1:0] awaddr, araddr;
  wire [P*8-1:0]  awlen, arlen, wstrb;
  wire [P*3-1:0]  awsize, arsize, awprot, arprot;
  wire [P*2-1:0]  awburst, arburst, bresp, rresp;
  wire [P*4-1:0]  awcache, arcache, awqos, arqos;
  wire [P-1:0]    awlock, arlock, awvalid, awready, wlast, wvalid, wready, bvalid, bready,
                  arvalid, arready, rlast, rvalid, rready;
  wire [P*64-1:0] wdata, rdata;

  bw_top #(
    .P(P), .MAX_BURST(MAX_BURST), .OUTS(OUTS), .IDW(IW), .FCLK_MHZ(FCLK_MHZ),
    .ADDR_W(C_S_AXI_ADDR_WIDTH)
  ) u_top (
    .clk(aclk), .rst_n(aresetn),
    .s_axi_awaddr_i(s_axi_awaddr), .s_axi_awprot_i(s_axi_awprot), .s_axi_awvalid_i(s_axi_awvalid),
    .s_axi_awready_o(s_axi_awready), .s_axi_wdata_i(s_axi_wdata), .s_axi_wstrb_i(s_axi_wstrb),
    .s_axi_wvalid_i(s_axi_wvalid), .s_axi_wready_o(s_axi_wready), .s_axi_bresp_o(s_axi_bresp),
    .s_axi_bvalid_o(s_axi_bvalid), .s_axi_bready_i(s_axi_bready), .s_axi_araddr_i(s_axi_araddr),
    .s_axi_arprot_i(s_axi_arprot), .s_axi_arvalid_i(s_axi_arvalid), .s_axi_arready_o(s_axi_arready),
    .s_axi_rdata_o(s_axi_rdata), .s_axi_rresp_o(s_axi_rresp), .s_axi_rvalid_o(s_axi_rvalid),
    .s_axi_rready_i(s_axi_rready),
    .m_axi_awid_o(awid), .m_axi_awaddr_o(awaddr), .m_axi_awlen_o(awlen), .m_axi_awsize_o(awsize),
    .m_axi_awburst_o(awburst), .m_axi_awlock_o(awlock), .m_axi_awcache_o(awcache),
    .m_axi_awprot_o(awprot), .m_axi_awqos_o(awqos), .m_axi_awvalid_o(awvalid),
    .m_axi_awready_i(awready), .m_axi_wdata_o(wdata), .m_axi_wstrb_o(wstrb), .m_axi_wlast_o(wlast),
    .m_axi_wvalid_o(wvalid), .m_axi_wready_i(wready), .m_axi_bid_i(bid), .m_axi_bresp_i(bresp),
    .m_axi_bvalid_i(bvalid), .m_axi_bready_o(bready), .m_axi_arid_o(arid), .m_axi_araddr_o(araddr),
    .m_axi_arlen_o(arlen), .m_axi_arsize_o(arsize), .m_axi_arburst_o(arburst),
    .m_axi_arlock_o(arlock), .m_axi_arcache_o(arcache), .m_axi_arprot_o(arprot),
    .m_axi_arqos_o(arqos), .m_axi_arvalid_o(arvalid), .m_axi_arready_i(arready),
    .m_axi_rid_i(rid), .m_axi_rdata_i(rdata), .m_axi_rresp_i(rresp), .m_axi_rlast_i(rlast),
    .m_axi_rvalid_i(rvalid), .m_axi_rready_o(rready)
  );

  // master 0
  assign m00_axi_awid = awid[IW-1:0];          assign m00_axi_awaddr = awaddr[31:0];
  assign m00_axi_awlen = awlen[7:0];           assign m00_axi_awsize = awsize[2:0];
  assign m00_axi_awburst = awburst[1:0];       assign m00_axi_awlock = awlock[0];
  assign m00_axi_awcache = awcache[3:0];       assign m00_axi_awprot = awprot[2:0];
  assign m00_axi_awqos = awqos[3:0];           assign m00_axi_awvalid = awvalid[0];
  assign awready[0] = m00_axi_awready;
  assign m00_axi_wdata = wdata[63:0];          assign m00_axi_wstrb = wstrb[7:0];
  assign m00_axi_wlast = wlast[0];             assign m00_axi_wvalid = wvalid[0];
  assign wready[0] = m00_axi_wready;
  assign bid[IW-1:0] = m00_axi_bid;            assign bresp[1:0] = m00_axi_bresp;
  assign bvalid[0] = m00_axi_bvalid;           assign m00_axi_bready = bready[0];
  assign m00_axi_arid = arid[IW-1:0];          assign m00_axi_araddr = araddr[31:0];
  assign m00_axi_arlen = arlen[7:0];           assign m00_axi_arsize = arsize[2:0];
  assign m00_axi_arburst = arburst[1:0];       assign m00_axi_arlock = arlock[0];
  assign m00_axi_arcache = arcache[3:0];       assign m00_axi_arprot = arprot[2:0];
  assign m00_axi_arqos = arqos[3:0];           assign m00_axi_arvalid = arvalid[0];
  assign arready[0] = m00_axi_arready;
  assign rid[IW-1:0] = m00_axi_rid;            assign rdata[63:0] = m00_axi_rdata;
  assign rresp[1:0] = m00_axi_rresp;           assign rlast[0] = m00_axi_rlast;
  assign rvalid[0] = m00_axi_rvalid;           assign m00_axi_rready = rready[0];

  // master 1
  generate
    if (P == 2) begin : g_m01
      assign m01_axi_awid = awid[2*IW-1:IW];     assign m01_axi_awaddr = awaddr[63:32];
      assign m01_axi_awlen = awlen[15:8];        assign m01_axi_awsize = awsize[5:3];
      assign m01_axi_awburst = awburst[3:2];     assign m01_axi_awlock = awlock[1];
      assign m01_axi_awcache = awcache[7:4];     assign m01_axi_awprot = awprot[5:3];
      assign m01_axi_awqos = awqos[7:4];         assign m01_axi_awvalid = awvalid[1];
      assign awready[1] = m01_axi_awready;
      assign m01_axi_wdata = wdata[127:64];      assign m01_axi_wstrb = wstrb[15:8];
      assign m01_axi_wlast = wlast[1];           assign m01_axi_wvalid = wvalid[1];
      assign wready[1] = m01_axi_wready;
      assign bid[2*IW-1:IW] = m01_axi_bid;       assign bresp[3:2] = m01_axi_bresp;
      assign bvalid[1] = m01_axi_bvalid;         assign m01_axi_bready = bready[1];
      assign m01_axi_arid = arid[2*IW-1:IW];     assign m01_axi_araddr = araddr[63:32];
      assign m01_axi_arlen = arlen[15:8];        assign m01_axi_arsize = arsize[5:3];
      assign m01_axi_arburst = arburst[3:2];     assign m01_axi_arlock = arlock[1];
      assign m01_axi_arcache = arcache[7:4];     assign m01_axi_arprot = arprot[5:3];
      assign m01_axi_arqos = arqos[7:4];         assign m01_axi_arvalid = arvalid[1];
      assign arready[1] = m01_axi_arready;
      assign rid[2*IW-1:IW] = m01_axi_rid;       assign rdata[127:64] = m01_axi_rdata;
      assign rresp[3:2] = m01_axi_rresp;         assign rlast[1] = m01_axi_rlast;
      assign rvalid[1] = m01_axi_rvalid;         assign m01_axi_rready = rready[1];
    end else begin : g_m01_off
      assign m01_axi_awid = {IW{1'b0}};          assign m01_axi_awaddr = 32'd0;
      assign m01_axi_awlen = 8'd0;               assign m01_axi_awsize = 3'd3;
      assign m01_axi_awburst = 2'b01;            assign m01_axi_awlock = 1'b0;
      assign m01_axi_awcache = 4'd0;             assign m01_axi_awprot = 3'd0;
      assign m01_axi_awqos = 4'd0;               assign m01_axi_awvalid = 1'b0;
      assign m01_axi_wdata = 64'd0;              assign m01_axi_wstrb = 8'd0;
      assign m01_axi_wlast = 1'b0;               assign m01_axi_wvalid = 1'b0;
      assign m01_axi_bready = 1'b1;
      assign m01_axi_arid = {IW{1'b0}};          assign m01_axi_araddr = 32'd0;
      assign m01_axi_arlen = 8'd0;               assign m01_axi_arsize = 3'd3;
      assign m01_axi_arburst = 2'b01;            assign m01_axi_arlock = 1'b0;
      assign m01_axi_arcache = 4'd0;             assign m01_axi_arprot = 3'd0;
      assign m01_axi_arqos = 4'd0;               assign m01_axi_arvalid = 1'b0;
      assign m01_axi_rready = 1'b1;
    end
  endgenerate

endmodule
