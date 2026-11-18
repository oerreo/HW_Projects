// pqc_ntt_axi_top: AXI4-Lite top of pqc-ntt-ip (L4, v1).
//
// Spec: docs/spec/l4_axi.md, docs/spec/hierarchy.md. Instances and wiring
// only (hierarchy rule: no logic of the sub-modules is repeated here):
//   u_axil   axil_slave    AXI4-Lite channels -> one register write / read
//                          strobe per cycle (handshakes, B / R backpressure)
//   u_csr    pqc_ntt_csr   register map, done_sticky, ERR, CYCLES, DIN / DOUT
//                          to stream handshakes, start to the core
//   u_core   ntt_core      L3 core (verified alone, tb/l3)
// Single clock domain (FCLK_CLK0), active-low reset (peripheral aresetn of
// proc_sys_reset, synchronous deassert assumed from that block).
//
// Parameters: the ntt_core parameters as plain integers (the Vivado module
// reference shell fpga/vivado/src/pqc_ntt_axi_bd.v sets them from the block
// design), IMPL and FCLK_MHZ (CONFIG register only, no effect on the logic),
// C_S_AXI_ADDR_WIDTH (AXI address width of the 4 KB window). Illegal values
// fail at elaboration in the sub-module that owns them.
//
// Path from AXI to the core: every core input comes from axil_slave flip-flops
// through the pqc_ntt_csr decode (no AXI input reaches the core
// combinationally). Inside ntt_core there is a combinational path m_ready_i ->
// RAM read enable (arch.md "L2 results"); here m_ready_i comes from the read
// strobe flip-flops and the address decode.
module pqc_ntt_axi_top
  import mlkem_pkg::*;
  import ntt_l2_pkg::*;
#(
  parameter int ALGO               = 0,    // 0 BARRETT, 1 MONT12, 2 SHIFTADD, 3 K2RED
  parameter int PRE_REG            = 0,    // bfu pipeline (rtl/l1/bfu.sv)
  parameter int MUL_REG            = 0,
  parameter int RED_PIPE           = 0,
  parameter int OUT_REG            = 0,
  parameter int SHARE_ADDSUB       = 0,
  parameter int ROM_OUT_REG        = 1,    // zeta_rom OUT_REG
  parameter int IMPL               = 0,    // CONFIG.impl: 0 hand RTL, 1 HLS L0 datapath
  parameter int FCLK_MHZ           = 100,  // CONFIG.fclk_mhz (build information)
  parameter int C_S_AXI_ADDR_WIDTH = 12    // 4 KB window (PQC_NTT_ADDR_RANGE)
) (
  input  logic                          clk,
  input  logic                          rst_n,   // async assert, sync deassert
  // AXI4-Lite slave
  input  logic [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr_i,
  input  logic [2:0]                    s_axi_awprot_i,
  input  logic                          s_axi_awvalid_i,
  output logic                          s_axi_awready_o,
  input  logic [31:0]                   s_axi_wdata_i,
  input  logic [3:0]                    s_axi_wstrb_i,
  input  logic                          s_axi_wvalid_i,
  output logic                          s_axi_wready_o,
  output logic [1:0]                    s_axi_bresp_o,
  output logic                          s_axi_bvalid_o,
  input  logic                          s_axi_bready_i,
  input  logic [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr_i,
  input  logic [2:0]                    s_axi_arprot_i,
  input  logic                          s_axi_arvalid_i,
  output logic                          s_axi_arready_o,
  output logic [31:0]                   s_axi_rdata_o,
  output logic [1:0]                    s_axi_rresp_o,
  output logic                          s_axi_rvalid_o,
  input  logic                          s_axi_rready_i
);

  if (ALGO < 0 || ALGO > 3) begin : g_bad_algo
    $error("pqc_ntt_axi_top: ALGO=%0d not supported (0..3)", ALGO);
  end

  // register access
  logic                          wr_en, rd_en;
  logic [C_S_AXI_ADDR_WIDTH-1:0] wr_addr, rd_addr;
  logic [31:0]                   wr_data, rd_data;
  // core command / status / streams
  logic              start, bank, busy, done, result_bank;
  op_e               op;
  logic              s_valid, s_ready, m_valid, m_ready;
  logic [COEF_W-1:0] s_data, m_data;

  axil_slave #(
    .ADDR_W (C_S_AXI_ADDR_WIDTH),
    .DATA_W (32)
  ) u_axil (
    .clk             (clk),
    .rst_n           (rst_n),
    .s_axi_awaddr_i  (s_axi_awaddr_i),
    .s_axi_awprot_i  (s_axi_awprot_i),
    .s_axi_awvalid_i (s_axi_awvalid_i),
    .s_axi_awready_o (s_axi_awready_o),
    .s_axi_wdata_i   (s_axi_wdata_i),
    .s_axi_wstrb_i   (s_axi_wstrb_i),
    .s_axi_wvalid_i  (s_axi_wvalid_i),
    .s_axi_wready_o  (s_axi_wready_o),
    .s_axi_bresp_o   (s_axi_bresp_o),
    .s_axi_bvalid_o  (s_axi_bvalid_o),
    .s_axi_bready_i  (s_axi_bready_i),
    .s_axi_araddr_i  (s_axi_araddr_i),
    .s_axi_arprot_i  (s_axi_arprot_i),
    .s_axi_arvalid_i (s_axi_arvalid_i),
    .s_axi_arready_o (s_axi_arready_o),
    .s_axi_rdata_o   (s_axi_rdata_o),
    .s_axi_rresp_o   (s_axi_rresp_o),
    .s_axi_rvalid_o  (s_axi_rvalid_o),
    .s_axi_rready_i  (s_axi_rready_i),
    .wr_en_o         (wr_en),
    .wr_addr_o       (wr_addr),
    .wr_data_o       (wr_data),
    .rd_en_o         (rd_en),
    .rd_addr_o       (rd_addr),
    .rd_data_i       (rd_data)
  );

  pqc_ntt_csr #(
    .ADDR_W       (C_S_AXI_ADDR_WIDTH),
    .ALGO         (ALGO),
    .PRE_REG      (PRE_REG),
    .MUL_REG      (MUL_REG),
    .RED_PIPE     (RED_PIPE),
    .OUT_REG      (OUT_REG),
    .SHARE_ADDSUB (SHARE_ADDSUB),
    .ROM_OUT_REG  (ROM_OUT_REG),
    .IMPL         (IMPL),
    .FCLK_MHZ     (FCLK_MHZ)
  ) u_csr (
    .clk           (clk),
    .rst_n         (rst_n),
    .wr_en_i       (wr_en),
    .wr_addr_i     (wr_addr),
    .wr_data_i     (wr_data),
    .rd_en_i       (rd_en),
    .rd_addr_i     (rd_addr),
    .rd_data_o     (rd_data),
    .start_o       (start),
    .op_o          (op),
    .bank_o        (bank),
    .busy_i        (busy),
    .done_i        (done),
    .result_bank_i (result_bank),
    .s_valid_o     (s_valid),
    .s_ready_i     (s_ready),
    .s_data_o      (s_data),
    .m_valid_i     (m_valid),
    .m_ready_o     (m_ready),
    .m_data_i      (m_data)
  );

  ntt_core #(
    .ALGO         (algo_e'(ALGO)),
    .PRE_REG      (PRE_REG),
    .MUL_REG      (MUL_REG),
    .RED_PIPE     (RED_PIPE),
    .OUT_REG      (OUT_REG),
    .SHARE_ADDSUB (SHARE_ADDSUB),
    .ROM_OUT_REG  (ROM_OUT_REG)
  ) u_core (
    .clk           (clk),
    .rst_n         (rst_n),
    .start_i       (start),
    .op_i          (op),
    .bank_i        (bank),
    .busy_o        (busy),
    .done_o        (done),
    .result_bank_o (result_bank),
    .s_valid_i     (s_valid),
    .s_ready_o     (s_ready),
    .s_data_i      (s_data),
    .m_valid_o     (m_valid),
    .m_ready_i     (m_ready),
    .m_data_o      (m_data)
  );

  // --------------------------------------------------------------------------
  // Simulation-only elaboration check: VERSION.BFU_LATENCY (computed in
  // pqc_ntt_csr) must equal the bfu LATENCY localparam.
  // --------------------------------------------------------------------------
`ifndef SYNTHESIS
  if (u_csr.BFU_LATENCY != u_core.u_bfu.LATENCY) begin : g_bad_version_lat
    $error("L4_LAT pqc_ntt_axi_top: VERSION.BFU_LATENCY=%0d != bfu LATENCY=%0d",
           u_csr.BFU_LATENCY, u_core.u_bfu.LATENCY);
  end
`endif

endmodule
