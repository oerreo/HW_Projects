// axil_slave: AXI4-Lite slave channel handling of pqc-ntt-ip (L4).
//
// Spec: docs/spec/l4_axi.md ("register map", "decided behaviour").
// Turns the five AXI4-Lite channels into a register access interface with
// one write strobe and one read strobe per cycle. It knows nothing about the
// register map: pqc_ntt_csr decodes the addresses.
//
// Register access interface (all outputs come from flip-flops of this
// module, so no AXI input reaches the register file or the core
// combinationally):
//   wr_en_o / wr_addr_o / wr_data_o   one write, performed in the cycle with
//                                     wr_en_o = 1 (exactly once per AXI write)
//   rd_en_o / rd_addr_o / rd_data_i   one read, performed in the cycle with
//                                     rd_en_o = 1 (exactly once per AXI read);
//                                     rd_data_i is sampled in that cycle
// Read side effects (DOUT pop) therefore happen once per accepted AR
// request, never again while the R channel is stalled.
//
// Write path:
//   AW and W are captured independently into one-entry buffers (aw_full_q,
//   w_full_q), in any order and with any delay between them (AWREADY =
//   !aw_full_q, WREADY = !w_full_q). The write is performed when both
//   buffers are full and no B response is pending (wr_en_o), which frees
//   both buffers and raises BVALID in the next cycle. BVALID and BRESP are
//   held until BREADY. While a B response waits for BREADY, the next AW / W
//   pair can already be captured; it is performed after the B handshake, so
//   responses stay in request order and there is exactly one B per write.
// Read path:
//   AR is captured into a one-entry buffer (ARREADY = !ar_full_q). The read
//   is performed when the buffer is full and no R response is pending
//   (rd_en_o): rd_data_i is stored in the R data register, RVALID rises in
//   the next cycle, RDATA / RRESP are held until RREADY.
// Latency (no backpressure): AW+W handshake cycle c -> write in c+1 -> BVALID
// in c+2; AR handshake c -> read in c+1 -> RVALID in c+2. Throughput one
// write and one read every 3 cycles; read and write paths are independent
// and may perform an access in the same cycle (the register file defines
// what a read sees in that case).
//
// Ignored inputs (allowed for an AXI4-Lite slave): WSTRB (every write is a
// full 32-bit write, l4_axi.md), AWPROT, ARPROT. Responses are always OKAY,
// also for addresses without a register (l4_axi.md). The address is passed
// unchanged; the register file ignores bits [1:0].
//
// Reset: the handshake state (buffer full flags, BVALID, RVALID) is reset;
// the address and data registers are datapath registers loaded by their
// handshake, without reset (design-methodology.md), and are only used while
// the matching full flag / valid is 1.
module axil_slave #(
  parameter int ADDR_W = 12,   // AXI address width, 3..32 (word access needs 2 low bits)
  parameter int DATA_W = 32    // AXI4-Lite data width, 32 only
) (
  input  logic              clk,
  input  logic              rst_n,           // async assert, sync deassert
  // AXI4-Lite slave
  input  logic [ADDR_W-1:0] s_axi_awaddr_i,
  input  logic [2:0]        s_axi_awprot_i,  // ignored
  input  logic              s_axi_awvalid_i,
  output logic              s_axi_awready_o,
  input  logic [DATA_W-1:0] s_axi_wdata_i,
  input  logic [DATA_W/8-1:0] s_axi_wstrb_i, // ignored: every write is a full word
  input  logic              s_axi_wvalid_i,
  output logic              s_axi_wready_o,
  output logic [1:0]        s_axi_bresp_o,   // always OKAY
  output logic              s_axi_bvalid_o,
  input  logic              s_axi_bready_i,
  input  logic [ADDR_W-1:0] s_axi_araddr_i,
  input  logic [2:0]        s_axi_arprot_i,  // ignored
  input  logic              s_axi_arvalid_i,
  output logic              s_axi_arready_o,
  output logic [DATA_W-1:0] s_axi_rdata_o,
  output logic [1:0]        s_axi_rresp_o,   // always OKAY
  output logic              s_axi_rvalid_o,
  input  logic              s_axi_rready_i,
  // register access
  output logic              wr_en_o,
  output logic [ADDR_W-1:0] wr_addr_o,
  output logic [DATA_W-1:0] wr_data_o,
  output logic              rd_en_o,
  output logic [ADDR_W-1:0] rd_addr_o,
  input  logic [DATA_W-1:0] rd_data_i
);

  if (ADDR_W < 3 || ADDR_W > 32) begin : g_bad_addr_w
    $error("axil_slave: ADDR_W=%0d not supported (3..32)", ADDR_W);
  end
  if (DATA_W != 32) begin : g_bad_data_w
    $error("axil_slave: DATA_W=%0d not supported (32)", DATA_W);
  end

  localparam logic [1:0] RESP_OKAY = 2'b00;

  // --------------------------------------------------------------------------
  // Write path
  // --------------------------------------------------------------------------
  logic              aw_full_q, w_full_q, bvalid_q;
  logic [ADDR_W-1:0] aw_addr_q;
  logic [DATA_W-1:0] w_data_q;
  logic              aw_hs, w_hs, b_hs, wr_en;

  assign s_axi_awready_o = !aw_full_q;
  assign s_axi_wready_o  = !w_full_q;
  assign aw_hs           = s_axi_awvalid_i && !aw_full_q;
  assign w_hs            = s_axi_wvalid_i && !w_full_q;
  assign b_hs            = bvalid_q && s_axi_bready_i;
  // perform the write: address and data present, B channel free
  assign wr_en           = aw_full_q && w_full_q && !bvalid_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_full_q <= 1'b0;
      w_full_q  <= 1'b0;
      bvalid_q  <= 1'b0;
    end else begin
      // a buffer is never captured and freed in the same cycle: capture
      // needs full = 0, freeing (wr_en) needs full = 1
      if (aw_hs)      aw_full_q <= 1'b1;
      else if (wr_en) aw_full_q <= 1'b0;
      if (w_hs)       w_full_q  <= 1'b1;
      else if (wr_en) w_full_q  <= 1'b0;
      if (wr_en)      bvalid_q  <= 1'b1;
      else if (b_hs)  bvalid_q  <= 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (aw_hs) aw_addr_q <= s_axi_awaddr_i;
    if (w_hs)  w_data_q  <= s_axi_wdata_i;
  end

  assign s_axi_bvalid_o = bvalid_q;
  assign s_axi_bresp_o  = RESP_OKAY;
  assign wr_en_o        = wr_en;
  assign wr_addr_o      = aw_addr_q;
  assign wr_data_o      = w_data_q;

  // --------------------------------------------------------------------------
  // Read path
  // --------------------------------------------------------------------------
  logic              ar_full_q, rvalid_q;
  logic [ADDR_W-1:0] ar_addr_q;
  logic [DATA_W-1:0] rdata_q;
  logic              ar_hs, r_hs, rd_en;

  assign s_axi_arready_o = !ar_full_q;
  assign ar_hs           = s_axi_arvalid_i && !ar_full_q;
  assign r_hs            = rvalid_q && s_axi_rready_i;
  // perform the read: address present, R channel free (the R data register
  // is never overwritten while RVALID = 1)
  assign rd_en           = ar_full_q && !rvalid_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ar_full_q <= 1'b0;
      rvalid_q  <= 1'b0;
    end else begin
      if (ar_hs)      ar_full_q <= 1'b1;
      else if (rd_en) ar_full_q <= 1'b0;
      if (rd_en)      rvalid_q  <= 1'b1;
      else if (r_hs)  rvalid_q  <= 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (ar_hs) ar_addr_q <= s_axi_araddr_i;
    if (rd_en) rdata_q   <= rd_data_i;
  end

  assign s_axi_rvalid_o = rvalid_q;
  assign s_axi_rdata_o  = rdata_q;
  assign s_axi_rresp_o  = RESP_OKAY;
  assign rd_en_o        = rd_en;
  assign rd_addr_o      = ar_addr_q;

  // --------------------------------------------------------------------------
  // Simulation-only checks of the master side (AXI rule: a request valid is
  // held, with its payload, until ready). A violation would not break this
  // slave (it captures at the handshake) but means a broken master / BFM.
  // --------------------------------------------------------------------------
`ifndef SYNTHESIS
  logic              p_awv, p_wv, p_arv;
  logic [ADDR_W-1:0] p_awa, p_ara;
  logic [DATA_W-1:0] p_wd;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p_awv <= 1'b0;
      p_wv  <= 1'b0;
      p_arv <= 1'b0;
    end else begin
      p_awv <= s_axi_awvalid_i && !s_axi_awready_o;
      p_wv  <= s_axi_wvalid_i && !s_axi_wready_o;
      p_arv <= s_axi_arvalid_i && !s_axi_arready_o;
      p_awa <= s_axi_awaddr_i;
      p_wd  <= s_axi_wdata_i;
      p_ara <= s_axi_araddr_i;
    end
  end
  always_ff @(posedge clk) begin
    if (rst_n === 1'b1) begin
      if (p_awv) aw_hold : assert (s_axi_awvalid_i === 1'b1 && s_axi_awaddr_i === p_awa)
        else $error("L4_AXI_AW axil_slave: AWVALID / AWADDR changed before AWREADY");
      if (p_wv) w_hold : assert (s_axi_wvalid_i === 1'b1 && s_axi_wdata_i === p_wd)
        else $error("L4_AXI_W axil_slave: WVALID / WDATA changed before WREADY");
      if (p_arv) ar_hold : assert (s_axi_arvalid_i === 1'b1 && s_axi_araddr_i === p_ara)
        else $error("L4_AXI_AR axil_slave: ARVALID / ARADDR changed before ARREADY");
    end
  end
`endif

endmodule
