// pqc_ntt_axi_bd: Verilog-2001 shell around pqc_ntt_axi_top for the Vivado
// block design (RTL module reference). FPGA build only.
//
// Why a shell: as far as known (not verified on the user's Vivado version),
// the module reference flow does not accept a SystemVerilog module as the
// referenced top, and SV typed parameters (algo_e) cannot be set from the
// block design. This shell has plain integer parameters and standard AXI
// port names (s_axi_*, aclk, aresetn) so that IP integrator infers the
// AXI4-Lite slave interface, the clock and the reset.
// create_project.tcl REF_TOP=direct skips this shell.
//
// The instance matches rtl/l4/pqc_ntt_axi_top.sv (int parameters, ports
// clk, rst_n, s_axi_*_i / _o; A22 in fpga/sw/ASSUMPTIONS.md, confirmed).
// IMPL and FCLK_MHZ only set the CONFIG register (build information);
// create_project.tcl sets them from IMPL= and FCLK_MHZ=.
module pqc_ntt_axi_bd #(
  parameter integer ALGO               = 0,  // 0 BARRETT, 1 MONT12, 2 SHIFTADD, 3 K2RED
  parameter integer PRE_REG            = 0,
  parameter integer MUL_REG            = 0,
  parameter integer RED_PIPE           = 0,
  parameter integer OUT_REG            = 0,
  parameter integer SHARE_ADDSUB       = 0,
  parameter integer ROM_OUT_REG        = 1,
  parameter integer IMPL               = 0,  // CONFIG.impl: 0 hand RTL, 1 HLS
  parameter integer FCLK_MHZ           = 100,// CONFIG.fclk_mhz, 1..255
  parameter integer C_S_AXI_ADDR_WIDTH = 12  // 4 KB window (PQC_NTT_ADDR_RANGE)
) (
  (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET aresetn" *)
  input  wire                          aclk,
  (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
  (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
  input  wire                          aresetn,
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
  input  wire                          s_axi_rready
);

  pqc_ntt_axi_top #(
    .ALGO               (ALGO),
    .PRE_REG            (PRE_REG),
    .MUL_REG            (MUL_REG),
    .RED_PIPE           (RED_PIPE),
    .OUT_REG            (OUT_REG),
    .SHARE_ADDSUB       (SHARE_ADDSUB),
    .ROM_OUT_REG        (ROM_OUT_REG),
    .IMPL               (IMPL),
    .FCLK_MHZ           (FCLK_MHZ),
    .C_S_AXI_ADDR_WIDTH (C_S_AXI_ADDR_WIDTH)
  ) u_top (
    .clk             (aclk),
    .rst_n           (aresetn),
    .s_axi_awaddr_i  (s_axi_awaddr),
    .s_axi_awprot_i  (s_axi_awprot),
    .s_axi_awvalid_i (s_axi_awvalid),
    .s_axi_awready_o (s_axi_awready),
    .s_axi_wdata_i   (s_axi_wdata),
    .s_axi_wstrb_i   (s_axi_wstrb),
    .s_axi_wvalid_i  (s_axi_wvalid),
    .s_axi_wready_o  (s_axi_wready),
    .s_axi_bresp_o   (s_axi_bresp),
    .s_axi_bvalid_o  (s_axi_bvalid),
    .s_axi_bready_i  (s_axi_bready),
    .s_axi_araddr_i  (s_axi_araddr),
    .s_axi_arprot_i  (s_axi_arprot),
    .s_axi_arvalid_i (s_axi_arvalid),
    .s_axi_arready_o (s_axi_arready),
    .s_axi_rdata_o   (s_axi_rdata),
    .s_axi_rresp_o   (s_axi_rresp),
    .s_axi_rvalid_o  (s_axi_rvalid),
    .s_axi_rready_i  (s_axi_rready)
  );

endmodule
