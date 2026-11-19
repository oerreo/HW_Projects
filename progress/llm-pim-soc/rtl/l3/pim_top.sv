// pim_top: GEMV PIM IP (L3, arch.md 3 and 7, hierarchy.md 1; register map, command format and
// run rules docs/spec/pim.md).
//
// The host builds commands in CMD0..CMD3 and pushes them (CMD_PUSH) into the command FIFO
// (pim_csr checks every command before it is queued). CTRL op RUN executes the queued commands
// in order until the FIFO is empty (commands pushed while the run is going are executed by the
// same run); op FLUSH discards the queued commands. Commands:
//   LDW   row records (arch.md 2.2) from DDR -> bank image (bimg_pack), once at initialization
//   WRGB  x (int8 [n]) from DDR -> global buffer
//   MACAB y[r] = sat32(rshr(dot(W[r], x) wm[r] xm, we + xe - fo)), r < rows -> DDR (int32 [rows])
//
// Structure (this module is instances, wiring and the run control only):
//   axil_slave + pim_csr      AXI4-Lite registers, push check, done_sticky, ERR, counters
//   sync_fifo                 command FIFO (CMD_DEPTH x 128)
//   pim_core                  banks, global buffer, controller, gather, scaler
//   axi_rd_eng                AXI read master (LDW row records, WRGB x)
//   packer + axi_wr_eng       AXI write master for y: two y per 64-bit beat (y[2k] in bits [31:0]);
//                             for odd rows the last beat of a MACAB carries one y and the engine
//                             writes only its 4 bytes (command length 4 rows)
// One HP port (arch.md 7.1: the PIM system shares one HP port through the interconnect): the read
// and write channels of m_axi.
//
// Run: the CTRL write that starts a run is performed in cycle s; busy from s + 1. RUN: the
// queued commands go to pim_core from s + 1. The run is complete in the first cycle e (busy) in
// which the command FIFO is empty, pim_core has nothing in flight (controller idle, every y popped,
// the last write command taken) and the write engine has no command left (busy_o = 0: every B
// received). FLUSH: the FIFO is popped one command per cycle without executing; complete in the
// first busy cycle with an empty FIFO. CYCLES = e - s.
// RD_STALL counts busy cycles in which the core is ready for a read beat and has none, WR_STALL
// busy cycles in which the packer offers a beat that axi_wr_eng does not take. RD_RESP / WR_RESP
// are set by every R beat / B response with RRESP[1] / BRESP[1] (data is used as returned).
// The push check makes every engine command legal (simulation check L3_ENGCMD).
module pim_top
  import llm_pkg::*;
#(
  parameter int NB         = 4,
  parameter int LB         = 16,
  parameter int DEPTH      = 4096,
  parameter int NMAX       = N_MAX,
  parameter int CMD_DEPTH  = 32,
  parameter int DOT_PIPE   = 2,
  parameter int SCALE_PIPE = 3,
  parameter int Y_DEPTH    = 32,
  parameter int MAX_BURST  = 16,
  parameter int OUTS       = 4,
  parameter int RD_FIFO    = MAX_BURST * OUTS,
  parameter int WR_FIFO    = 2 * MAX_BURST,
  parameter int IDW        = 1,
  parameter int FCLK_MHZ   = 100,
  parameter int ADDR_W     = 12
) (
  input  logic              clk,
  input  logic              rst_n,
  // AXI4-Lite slave (CSR)
  input  logic [ADDR_W-1:0] s_axi_awaddr_i,
  input  logic [2:0]        s_axi_awprot_i,
  input  logic              s_axi_awvalid_i,
  output logic              s_axi_awready_o,
  input  logic [31:0]       s_axi_wdata_i,
  input  logic [3:0]        s_axi_wstrb_i,
  input  logic              s_axi_wvalid_i,
  output logic              s_axi_wready_o,
  output logic [1:0]        s_axi_bresp_o,
  output logic              s_axi_bvalid_o,
  input  logic              s_axi_bready_i,
  input  logic [ADDR_W-1:0] s_axi_araddr_i,
  input  logic [2:0]        s_axi_arprot_i,
  input  logic              s_axi_arvalid_i,
  output logic              s_axi_arready_o,
  output logic [31:0]       s_axi_rdata_o,
  output logic [1:0]        s_axi_rresp_o,
  output logic              s_axi_rvalid_o,
  input  logic              s_axi_rready_i,
  // AXI4 master: write (y)
  output logic [IDW-1:0]    m_axi_awid_o,
  output logic [31:0]       m_axi_awaddr_o,
  output logic [7:0]        m_axi_awlen_o,
  output logic [2:0]        m_axi_awsize_o,
  output logic [1:0]        m_axi_awburst_o,
  output logic              m_axi_awlock_o,
  output logic [3:0]        m_axi_awcache_o,
  output logic [2:0]        m_axi_awprot_o,
  output logic [3:0]        m_axi_awqos_o,
  output logic              m_axi_awvalid_o,
  input  logic              m_axi_awready_i,
  output logic [63:0]       m_axi_wdata_o,
  output logic [7:0]        m_axi_wstrb_o,
  output logic              m_axi_wlast_o,
  output logic              m_axi_wvalid_o,
  input  logic              m_axi_wready_i,
  input  logic [IDW-1:0]    m_axi_bid_i,
  input  logic [1:0]        m_axi_bresp_i,
  input  logic              m_axi_bvalid_i,
  output logic              m_axi_bready_o,
  // AXI4 master: read (row records, x)
  output logic [IDW-1:0]    m_axi_arid_o,
  output logic [31:0]       m_axi_araddr_o,
  output logic [7:0]        m_axi_arlen_o,
  output logic [2:0]        m_axi_arsize_o,
  output logic [1:0]        m_axi_arburst_o,
  output logic              m_axi_arlock_o,
  output logic [3:0]        m_axi_arcache_o,
  output logic [2:0]        m_axi_arprot_o,
  output logic [3:0]        m_axi_arqos_o,
  output logic              m_axi_arvalid_o,
  input  logic              m_axi_arready_i,
  input  logic [IDW-1:0]    m_axi_rid_i,
  input  logic [63:0]       m_axi_rdata_i,
  input  logic [1:0]        m_axi_rresp_i,
  input  logic              m_axi_rlast_i,
  input  logic              m_axi_rvalid_i,
  output logic              m_axi_rready_o
);
  // parameters: checked by the instances
  localparam int AA   = $clog2(DEPTH);
  localparam int NW   = $clog2(NMAX + 1);
  localparam int LV_W = $clog2(CMD_DEPTH + 1);

  // ---------------- AXI4-Lite and CSR ----------------
  logic              wr_en, rd_en;
  logic [ADDR_W-1:0] wr_addr, rd_addr;
  logic [31:0]       wr_data, rd_data;

  axil_slave #(.ADDR_W(ADDR_W), .DATA_W(32)) u_axil (
    .clk, .rst_n,
    .s_axi_awaddr_i, .s_axi_awprot_i, .s_axi_awvalid_i, .s_axi_awready_o,
    .s_axi_wdata_i, .s_axi_wstrb_i, .s_axi_wvalid_i, .s_axi_wready_o,
    .s_axi_bresp_o, .s_axi_bvalid_o, .s_axi_bready_i,
    .s_axi_araddr_i, .s_axi_arprot_i, .s_axi_arvalid_i, .s_axi_arready_o,
    .s_axi_rdata_o, .s_axi_rresp_o, .s_axi_rvalid_o, .s_axi_rready_i,
    .wr_en_o(wr_en), .wr_addr_o(wr_addr), .wr_data_o(wr_data),
    .rd_en_o(rd_en), .rd_addr_o(rd_addr), .rd_data_i(rd_data)
  );

  logic             push, fifo_in_ready, fifo_valid, fifo_ready;
  logic [127:0]     push_data, fifo_data;
  logic [LV_W-1:0]  fifo_level;
  logic             start, busy, run_flush, run_done;
  logic             rd_err_ev, wr_err_ev, rd_stall_ev, wr_stall_ev;
  logic             ev_mac, ev_wrgb, ev_rdmac, done_ldw, done_wrgb, done_mac;

  pim_csr #(.ADDR_W(ADDR_W), .NB(NB), .LB(LB), .DEPTH(DEPTH), .NMAX(NMAX), .CMD_DEPTH(CMD_DEPTH),
            .FCLK_MHZ(FCLK_MHZ)) u_csr (
    .clk, .rst_n,
    .wr_en_i(wr_en), .wr_addr_i(wr_addr), .wr_data_i(wr_data),
    .rd_en_i(rd_en), .rd_addr_i(rd_addr), .rd_data_o(rd_data),
    .push_o(push), .push_data_o(push_data), .fifo_ready_i(fifo_in_ready), .fifo_level_i(fifo_level),
    .start_o(start), .busy_o(busy), .run_flush_o(run_flush), .done_i(run_done),
    .rd_err_i(rd_err_ev), .wr_err_i(wr_err_ev), .rd_stall_i(rd_stall_ev), .wr_stall_i(wr_stall_ev),
    .ev_mac_i(ev_mac), .ev_wrgb_i(ev_wrgb), .ev_rdmac_i(ev_rdmac), .done_ldw_i(done_ldw),
    .done_wrgb_i(done_wrgb), .done_mac_i(done_mac));

  // ---------------- command FIFO ----------------
  sync_fifo #(.W(128), .DEPTH(CMD_DEPTH)) u_cfifo (
    .clk, .rst_n, .in_valid_i(push), .in_ready_o(fifo_in_ready), .in_data_i(push_data),
    .out_valid_o(fifo_valid), .out_ready_i(fifo_ready), .out_data_o(fifo_data), .level_o(fifo_level));

  // ---------------- core ----------------
  logic        core_cmd_valid, core_cmd_ready, core_busy, core_rd_stall;
  logic        rcmd_valid, rcmd_ready, wcmd_valid, wcmd_ready;
  logic [31:0] rcmd_addr, rcmd_bytes, wcmd_addr, wcmd_bytes;
  logic        d_valid, d_ready, d_last;
  logic [63:0] d_data;
  logic        y_valid, y_ready, y_last;
  logic [31:0] y_data;

  assign core_cmd_valid = fifo_valid && busy && !run_flush;
  assign fifo_ready     = busy && (run_flush || core_cmd_ready);

  pim_core #(.NB(NB), .LB(LB), .DEPTH(DEPTH), .NMAX(NMAX), .DOT_PIPE(DOT_PIPE),
             .SCALE_PIPE(SCALE_PIPE), .Y_DEPTH(Y_DEPTH), .ROWS_W(16)) u_core (
    .clk, .rst_n,
    .cmd_valid_i(core_cmd_valid), .cmd_ready_o(core_cmd_ready),
    .cmd_op_i(fifo_data[3:0]), .cmd_rows_i(fifo_data[31:16]), .cmd_n_i(NW'(fifo_data[15:4])),
    .cmd_base_i(AA'(fifo_data[63:49])), .cmd_addr_i(fifo_data[95:64]),
    .cmd_xm_i(fifo_data[32 +: AM_W]), .cmd_we_i(fifo_data[103:96]), .cmd_xe_i(fifo_data[111:104]),
    .cmd_fo_i(fifo_data[119:112]),
    .rd_cmd_valid_o(rcmd_valid), .rd_cmd_ready_i(rcmd_ready), .rd_cmd_addr_o(rcmd_addr),
    .rd_cmd_bytes_o(rcmd_bytes),
    .d_valid_i(d_valid), .d_ready_o(d_ready), .d_data_i(d_data),
    .wr_cmd_valid_o(wcmd_valid), .wr_cmd_ready_i(wcmd_ready), .wr_cmd_addr_o(wcmd_addr),
    .wr_cmd_bytes_o(wcmd_bytes),
    .y_valid_o(y_valid), .y_ready_i(y_ready), .y_data_o(y_data), .y_last_o(y_last),
    .busy_o(core_busy), .rd_stall_o(core_rd_stall),
    .ev_mac_o(ev_mac), .ev_wrgb_o(ev_wrgb), .ev_rdmac_o(ev_rdmac), .done_ldw_o(done_ldw),
    .done_wrgb_o(done_wrgb), .done_mac_o(done_mac));

  // ---------------- read engine ----------------
  logic rd_ecmd;
  axi_rd_eng #(.AW(32), .IDW(IDW), .LEN_W(32), .MAX_BURST(MAX_BURST), .OUTS(OUTS),
               .FIFO_DEPTH(RD_FIFO)) u_rd (
    .clk, .rst_n,
    .cfg_burst_i(9'd0), .cfg_outs_i(7'd0),
    .cmd_valid_i(rcmd_valid), .cmd_ready_o(rcmd_ready), .cmd_addr_i(rcmd_addr), .cmd_bytes_i(rcmd_bytes),
    .d_valid_o(d_valid), .d_ready_i(d_ready), .d_data_o(d_data), .d_last_o(d_last),
    .busy_o(), .done_o(), .stall_o(), .err_resp_o(), .err_cmd_o(rd_ecmd), .err_clr_i(start),
    .m_axi_arid_o, .m_axi_araddr_o, .m_axi_arlen_o, .m_axi_arsize_o, .m_axi_arburst_o,
    .m_axi_arlock_o, .m_axi_arcache_o, .m_axi_arprot_o, .m_axi_arqos_o, .m_axi_arvalid_o,
    .m_axi_arready_i, .m_axi_rid_i, .m_axi_rdata_i, .m_axi_rresp_i, .m_axi_rlast_i,
    .m_axi_rvalid_i, .m_axi_rready_o);

  // ---------------- packer ----------------
  logic        pk_valid_q, half_q, pk_ready, wr_in_ready, y_hs, emit;
  logic [63:0] pk_data_q;
  logic [31:0] lo_q;

  assign pk_ready = !pk_valid_q || wr_in_ready;
  assign y_ready  = pk_ready;
  assign y_hs     = y_valid && y_ready;
  assign emit     = y_hs && (half_q || y_last);

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      pk_valid_q <= 1'b0;
      half_q     <= 1'b0;
    end else begin
      if (emit) pk_valid_q <= 1'b1;
      else if (wr_in_ready) pk_valid_q <= 1'b0;
      if (y_hs) half_q <= !half_q && !y_last;
    end

  always_ff @(posedge clk) begin
    if (y_hs && !half_q) lo_q <= y_data;
    if (emit) pk_data_q <= half_q ? {y_data, lo_q} : {32'd0, y_data};
  end

  // ---------------- write engine ----------------
  logic wr_busy, wr_ecmd;
  axi_wr_eng #(.AW(32), .IDW(IDW), .LEN_W(32), .MAX_BURST(MAX_BURST), .OUTS(OUTS),
               .FIFO_DEPTH(WR_FIFO)) u_wr (
    .clk, .rst_n,
    .cfg_burst_i(9'd0), .cfg_outs_i(7'd0),
    .cmd_valid_i(wcmd_valid), .cmd_ready_o(wcmd_ready), .cmd_addr_i(wcmd_addr),
    .cmd_bytes_i(wcmd_bytes),
    .in_valid_i(pk_valid_q), .in_ready_o(wr_in_ready), .in_data_i(pk_data_q),
    .busy_o(wr_busy), .done_o(), .stall_o(wr_stall_ev), .err_resp_o(), .err_cmd_o(wr_ecmd),
    .err_clr_i(start),
    .m_axi_awid_o, .m_axi_awaddr_o, .m_axi_awlen_o, .m_axi_awsize_o, .m_axi_awburst_o,
    .m_axi_awlock_o, .m_axi_awcache_o, .m_axi_awprot_o, .m_axi_awqos_o, .m_axi_awvalid_o,
    .m_axi_awready_i, .m_axi_wdata_o, .m_axi_wstrb_o, .m_axi_wlast_o, .m_axi_wvalid_o,
    .m_axi_wready_i, .m_axi_bid_i, .m_axi_bresp_i, .m_axi_bvalid_i, .m_axi_bready_o);

  // ---------------- run completion and events ----------------
  assign run_done = busy && fifo_level == '0 && (run_flush || (!core_busy && !wr_busy));

  assign rd_stall_ev = core_rd_stall;
  assign rd_err_ev   = m_axi_rvalid_i && m_axi_rready_o && m_axi_rresp_i[1];
  assign wr_err_ev   = m_axi_bvalid_i && m_axi_bready_o && m_axi_bresp_i[1];

  logic unused_d_last;
  assign unused_d_last = d_last;   // the core counts beats itself

`ifndef SYNTHESIS
  // L3_ENGCMD: an engine rejected a command (the push check must prevent it)
  logic c_ecmd_q;
  always @(posedge clk) begin
    if (rst_n === 1'b1 && (rd_ecmd || wr_ecmd) && !c_ecmd_q)
      $error("L3_ENGCMD pim_top %m: an AXI engine rejected a command");
    c_ecmd_q <= (rst_n === 1'b1) && (rd_ecmd || wr_ecmd);
  end
`endif

endmodule
