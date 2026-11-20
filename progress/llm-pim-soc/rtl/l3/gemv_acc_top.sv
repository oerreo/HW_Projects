// gemv_acc_top: GEMV accelerator IP (L3, arch.md 2, hierarchy.md 1; register map and call
// rules docs/spec/gemv_acc.md).
//
// One call (descriptor W_ADDR, X_ADDR, Y_ADDR, ROWS, N, XM, EXP, FLAGS) computes
//   y[r] = sat32(rshr(dot8(W[r], x) * wm[r] * xm, we + xe - fo)),  r = 0 .. ROWS - 1
// (golden K_GEMV with gs = n) from the row records at W_ADDR (arch.md 2.2: row r at
// W_ADDR + r * RB, RB = 8 (1 + ceil(N/8)), header beat with wm in bits [15:0]) and x (N int8
// at X_ADDR), writes y (int32 [ROWS]) to Y_ADDR if FLAGS.y_en and reduces y to its argmax
// (first maximum, ARGMAX_IDX / ARGMAX_VAL) if FLAGS.argmax_en.
//
// Structure (this module is instances, wiring and the call control only):
//   axil_slave + gemv_acc_csr     AXI4-Lite registers, done_sticky, ERR, counters
//   slice p < P (port p):         axi_rd_eng (HP port p, read only) + gemv_core
//     slice p computes the rows r with r mod P = p (arch.md 2.3). Its command sequencer
//     issues x (X_ADDR, N bytes) and then the row records: P = 1 one command
//     (W_ADDR, ROWS x RB), P = 2 one command per row (W_ADDR + r RB, RB). The read stream of
//     the slice goes to the core's x port until the last beat of the x command, then to its w
//     port. A slice without rows (P = 2, ROWS = 1) is not started.
//   y merge                       takes y in row order from slice (r mod P)
//   argmax_red                    on the merged y stream (FLAGS.argmax_en)
//   packer + axi_wr_eng (port 0)  two y per 64-bit beat (y[2k] in bits [31:0], y[2k+1] in
//                                 [63:32]); for odd ROWS the last beat carries one y and the
//                                 engine writes only its 4 bytes (WSTRB 0x0F, command length
//                                 4 ROWS). Not used if !FLAGS.y_en (the merge then never waits).
//
// Timing: the CTRL write of a call is performed in cycle s; gemv_acc_csr latches the descriptor
// and checks it in s + 1 .. v (v = s + CHK_CYC, sequential W range product) and gives start_o in
// v. In v + 1 the cores get start_i and the sequencers are loaded; the read and write commands
// are presented from v + 2. The call is complete in cycle e when every
// started core has given done_o (last y accepted), the y write has its last B response (y_en)
// and argmax_red has given done_o (argmax_en). CYCLES = e - s.
// RD_STALL counts the cycles in which a slice's core is ready for a read beat (x port in
// LOADX, w port in RUN) and has none; WR_STALL the cycles in which the packer offers a beat
// that axi_wr_eng does not take (axi_wr_eng stall_o). RD_RESP / WR_RESP are set by every R beat
// / B response with RRESP[1] / BRESP[1] on the AXI ports (data is used as returned).
// The descriptor check in gemv_acc_csr (alignment, ranges, no wrap past 2^32) makes every
// engine command legal, so the engines never reject one (simulation check L3_ENGCMD).
//
// Parameters: P (1, 2), engine MAX_BURST / OUTS / RD_FIFO / WR_FIFO / IDW, gemv_core NMAX /
// ROWS_W / DOT_PIPE / SCALE_PIPE / Y_DEPTH, IDX_W (argmax index, >= ROWS_W), FCLK_MHZ (CONFIG),
// ADDR_W (AXI4-Lite).
module gemv_acc_top
  import llm_pkg::*;
#(
  parameter int P          = 1,
  parameter int MAX_BURST  = 16,
  parameter int OUTS       = 4,
  parameter int RD_FIFO    = MAX_BURST * OUTS,
  parameter int WR_FIFO    = 2 * MAX_BURST,
  parameter int IDW        = 1,
  parameter int NMAX       = N_MAX,
  parameter int ROWS_W     = 16,
  parameter int IDX_W      = llm_pkg::IDX_W,
  parameter int DOT_PIPE   = 2,
  parameter int SCALE_PIPE = 3,
  parameter int Y_DEPTH    = 16,
  parameter int FCLK_MHZ   = 100,
  parameter int ADDR_W     = 12
) (
  input  logic                    clk,
  input  logic                    rst_n,
  // AXI4-Lite slave (CSR)
  input  logic [ADDR_W-1:0]       s_axi_awaddr_i,
  input  logic [2:0]              s_axi_awprot_i,
  input  logic                    s_axi_awvalid_i,
  output logic                    s_axi_awready_o,
  input  logic [31:0]             s_axi_wdata_i,
  input  logic [3:0]              s_axi_wstrb_i,
  input  logic                    s_axi_wvalid_i,
  output logic                    s_axi_wready_o,
  output logic [1:0]              s_axi_bresp_o,
  output logic                    s_axi_bvalid_o,
  input  logic                    s_axi_bready_i,
  input  logic [ADDR_W-1:0]       s_axi_araddr_i,
  input  logic [2:0]              s_axi_arprot_i,
  input  logic                    s_axi_arvalid_i,
  output logic                    s_axi_arready_o,
  output logic [31:0]             s_axi_rdata_o,
  output logic [1:0]              s_axi_rresp_o,
  output logic                    s_axi_rvalid_o,
  input  logic                    s_axi_rready_i,
  // AXI4 write master (port 0: y)
  output logic [IDW-1:0]          m_axi_awid_o,
  output logic [31:0]             m_axi_awaddr_o,
  output logic [7:0]              m_axi_awlen_o,
  output logic [2:0]              m_axi_awsize_o,
  output logic [1:0]              m_axi_awburst_o,
  output logic                    m_axi_awlock_o,
  output logic [3:0]              m_axi_awcache_o,
  output logic [2:0]              m_axi_awprot_o,
  output logic [3:0]              m_axi_awqos_o,
  output logic                    m_axi_awvalid_o,
  input  logic                    m_axi_awready_i,
  output logic [63:0]             m_axi_wdata_o,
  output logic [7:0]              m_axi_wstrb_o,
  output logic                    m_axi_wlast_o,
  output logic                    m_axi_wvalid_o,
  input  logic                    m_axi_wready_i,
  input  logic [IDW-1:0]          m_axi_bid_i,
  input  logic [1:0]              m_axi_bresp_i,
  input  logic                    m_axi_bvalid_i,
  output logic                    m_axi_bready_o,
  // AXI4 read masters, index = port (slice)
  output logic [P-1:0][IDW-1:0]   m_axi_arid_o,
  output logic [P-1:0][31:0]      m_axi_araddr_o,
  output logic [P-1:0][7:0]       m_axi_arlen_o,
  output logic [P-1:0][2:0]       m_axi_arsize_o,
  output logic [P-1:0][1:0]       m_axi_arburst_o,
  output logic [P-1:0]            m_axi_arlock_o,
  output logic [P-1:0][3:0]       m_axi_arcache_o,
  output logic [P-1:0][2:0]       m_axi_arprot_o,
  output logic [P-1:0][3:0]       m_axi_arqos_o,
  output logic [P-1:0]            m_axi_arvalid_o,
  input  logic [P-1:0]            m_axi_arready_i,
  input  wire  [P-1:0][IDW-1:0]   m_axi_rid_i,
  input  wire  [P-1:0][63:0]      m_axi_rdata_i,
  input  wire  [P-1:0][1:0]       m_axi_rresp_i,
  input  logic [P-1:0]            m_axi_rlast_i,
  input  logic [P-1:0]            m_axi_rvalid_i,
  output logic [P-1:0]            m_axi_rready_o
);

  if (P < 1 || P > 2) $error("gemv_acc_top: P=%0d must be 1 or 2", P);
  if (IDX_W < ROWS_W) $error("gemv_acc_top: IDX_W=%0d must be >= ROWS_W=%0d", IDX_W, ROWS_W);
  // other parameters: checked by the instances

  localparam int NW   = $clog2(NMAX + 1);
  localparam int NBW  = $clog2(NMAX / 8 + 2);
  localparam int WB_W = ROWS_W + NBW + 3;
  localparam int SW   = (P > 1) ? $clog2(P) : 1;

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

  logic                  start, busy, all_done;
  logic [31:0]           w_addr, x_addr, y_addr;
  logic [ROWS_W-1:0]     rows;
  logic [NW-1:0]         n;
  logic [AM_W-1:0]       xm;
  logic signed [E_W-1:0] we, xe, fo;
  logic                  am_en, y_en;
  logic [WB_W-1:0]       wbytes;
  logic                  rd_err_ev, wr_err_ev, rd_stall_ev, wr_stall_ev;
  logic                  am_done;
  logic [IDX_W-1:0]      am_idx;
  logic signed [31:0]    am_max;

  gemv_acc_csr #(.ADDR_W(ADDR_W), .P(P), .LANES(8), .NMAX(NMAX), .ROWS_W(ROWS_W), .IDX_W(IDX_W),
                 .FCLK_MHZ(FCLK_MHZ)) u_csr (
    .clk, .rst_n,
    .wr_en_i(wr_en), .wr_addr_i(wr_addr), .wr_data_i(wr_data),
    .rd_en_i(rd_en), .rd_addr_i(rd_addr), .rd_data_o(rd_data),
    .start_o(start), .busy_o(busy), .done_i(all_done),
    .op_w_addr_o(w_addr), .op_x_addr_o(x_addr), .op_y_addr_o(y_addr), .op_rows_o(rows),
    .op_n_o(n), .op_xm_o(xm), .op_we_o(we), .op_xe_o(xe), .op_fo_o(fo), .op_am_en_o(am_en),
    .op_y_en_o(y_en), .op_wbytes_o(wbytes),
    .rd_err_i(rd_err_ev), .wr_err_i(wr_err_ev), .rd_stall_i(rd_stall_ev),
    .wr_stall_i(wr_stall_ev), .am_done_i(am_done), .am_idx_i(am_idx), .am_max_i(am_max)
  );

  // start_q: cycle v + 1 (descriptor latched since s + 1, wbytes valid from v)
  logic start_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) start_q <= 1'b0;
    else        start_q <= start;

  // row record size RB = 8 (1 + ceil(N/8)) bytes
  logic [NBW+2:0] rb;
  assign rb = (NBW + 3)'((({1'b0, n} + (NW + 1)'(7)) >> 3) + 1) << 3;

  // ---------------- slices ----------------
  logic [P-1:0]             y_valid, y_ready, core_fin_now, rd_stall_p, rd_ecmd;
  logic [P-1:0][31:0]       y_data;

  for (genvar p = 0; p < P; p++) begin : g_slice
    logic [ROWS_W-1:0] rows_p, wleft_q;
    logic              act_p, xpend_q, xph_q, fin_q, core_done;
    logic              cmd_valid, cmd_ready, cmd_hs;
    logic [31:0]       cmd_addr, cmd_bytes, wa_q;
    logic              d_valid, d_ready, d_last, d_hs;
    logic [63:0]       d_data;
    logic              x_valid, x_ready, w_valid, w_ready;

    // rows of this slice: r = p, p + P, ...
    assign rows_p = (P == 1) ? rows : ROWS_W'(({1'b0, rows} + (ROWS_W + 1)'(P - 1 - p)) >> 1);
    assign act_p  = rows_p != '0;

    // command sequencer: x, then the row records
    assign cmd_valid = xpend_q || (wleft_q != '0);
    assign cmd_addr  = xpend_q ? x_addr : wa_q;
    assign cmd_bytes = xpend_q ? 32'(n) : ((P == 1) ? 32'(wbytes) : 32'(rb));
    assign cmd_hs    = cmd_valid && cmd_ready;

    always_ff @(posedge clk or negedge rst_n)
      if (!rst_n) begin
        xpend_q <= 1'b0;
        wleft_q <= '0;
        xph_q   <= 1'b0;
        fin_q   <= 1'b1;
      end else if (start) begin
        xpend_q <= 1'b0;
        wleft_q <= '0;
        xph_q   <= 1'b0;
        fin_q   <= 1'b0;
      end else if (start_q) begin
        xpend_q <= act_p;
        wleft_q <= (P == 1) ? ROWS_W'(act_p) : rows_p;
        xph_q   <= act_p;
        fin_q   <= !act_p;
      end else begin
        if (cmd_hs) begin
          if (xpend_q) xpend_q <= 1'b0;
          else         wleft_q <= wleft_q - 1'b1;
        end
        if (d_hs && d_last && xph_q) xph_q <= 1'b0;
        if (core_done) fin_q <= 1'b1;
      end

    always_ff @(posedge clk)
      if (start_q) wa_q <= w_addr + ((p == 0) ? 32'd0 : 32'(rb));
      else if (cmd_hs && !xpend_q) wa_q <= wa_q + 32'(P) * 32'(rb);

    axi_rd_eng #(.AW(32), .IDW(IDW), .LEN_W(32), .MAX_BURST(MAX_BURST), .OUTS(OUTS),
                 .FIFO_DEPTH(RD_FIFO)) u_rd (
      .clk, .rst_n,
      .cfg_burst_i(9'd0), .cfg_outs_i(7'd0),
      .cmd_valid_i(cmd_valid), .cmd_ready_o(cmd_ready), .cmd_addr_i(cmd_addr), .cmd_bytes_i(cmd_bytes),
      .d_valid_o(d_valid), .d_ready_i(d_ready), .d_data_o(d_data), .d_last_o(d_last),
      .busy_o(), .done_o(), .stall_o(), .err_resp_o(), .err_cmd_o(rd_ecmd[p]), .err_clr_i(start),
      .m_axi_arid_o(m_axi_arid_o[p]), .m_axi_araddr_o(m_axi_araddr_o[p]),
      .m_axi_arlen_o(m_axi_arlen_o[p]), .m_axi_arsize_o(m_axi_arsize_o[p]),
      .m_axi_arburst_o(m_axi_arburst_o[p]), .m_axi_arlock_o(m_axi_arlock_o[p]),
      .m_axi_arcache_o(m_axi_arcache_o[p]), .m_axi_arprot_o(m_axi_arprot_o[p]),
      .m_axi_arqos_o(m_axi_arqos_o[p]), .m_axi_arvalid_o(m_axi_arvalid_o[p]),
      .m_axi_arready_i(m_axi_arready_i[p]),
      .m_axi_rid_i(m_axi_rid_i[p]), .m_axi_rdata_i(m_axi_rdata_i[p]), .m_axi_rresp_i(m_axi_rresp_i[p]),
      .m_axi_rlast_i(m_axi_rlast_i[p]), .m_axi_rvalid_i(m_axi_rvalid_i[p]),
      .m_axi_rready_o(m_axi_rready_o[p]));

    // read stream router: x port until the last beat of the x command, then w port
    assign x_valid = d_valid && xph_q;
    assign w_valid = d_valid && !xph_q;
    assign d_ready = xph_q ? x_ready : w_ready;
    assign d_hs    = d_valid && d_ready;

    gemv_core #(.LANES(8), .NMAX(NMAX), .ROWS_W(ROWS_W), .DOT_PIPE(DOT_PIPE),
                .SCALE_PIPE(SCALE_PIPE), .Y_DEPTH(Y_DEPTH)) u_core (
      .clk, .rst_n,
      .start_i(start_q && act_p), .rows_i(rows_p), .n_i(n), .we_i(we), .xe_i(xe), .fo_i(fo),
      .xm_i(xm), .busy_o(), .done_o(core_done),
      .x_valid_i(x_valid), .x_ready_o(x_ready), .x_data_i(d_data),
      .w_valid_i(w_valid), .w_ready_o(w_ready), .w_data_i(d_data),
      .y_valid_o(y_valid[p]), .y_ready_i(y_ready[p]), .y_data_o(y_data[p]));

    assign core_fin_now[p] = fin_q || core_done;
    // the core is ready for a read beat and has none
    assign rd_stall_p[p]   = d_ready && !d_valid;
  end

  // ---------------- y merge (row order) ----------------
  logic [SW-1:0]     sel_q;
  logic [ROWS_W-1:0] yrow_q;
  logic              m_valid, m_ready, m_hs, m_first, m_last;
  logic [31:0]       m_data;

  assign m_valid = y_valid[sel_q];
  assign m_data  = y_data[sel_q];
  assign m_hs    = m_valid && m_ready;
  assign m_first = yrow_q == '0;
  assign m_last  = yrow_q == rows - 1'b1;
  always_comb
    for (int p = 0; p < P; p++) y_ready[p] = m_ready && (sel_q == SW'(p));

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      sel_q  <= '0;
      yrow_q <= '0;
    end else if (start_q) begin
      sel_q  <= '0;
      yrow_q <= '0;
    end else if (m_hs) begin
      yrow_q <= yrow_q + 1'b1;
      sel_q  <= (P == 1 || sel_q == SW'(P - 1)) ? '0 : sel_q + 1'b1;
    end

  // ---------------- argmax ----------------
  logic am_fin_q;
  argmax_red #(.IDX_W(IDX_W)) u_am (
    .clk, .rst_n,
    .valid_i(m_hs && am_en), .first_i(m_first), .last_i(m_last), .v_i(m_data),
    .done_o(am_done), .idx_o(am_idx), .max_o(am_max));

  // ---------------- packer ----------------
  logic        pk_valid_q, half_q, pk_ready, wr_in_ready, emit;
  logic [63:0] pk_data_q;
  logic [31:0] lo_q;

  assign pk_ready = !pk_valid_q || wr_in_ready;
  assign m_ready  = !y_en || pk_ready;
  assign emit     = m_hs && y_en && (half_q || m_last);

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      pk_valid_q <= 1'b0;
      half_q     <= 1'b0;
    end else begin
      if (emit) pk_valid_q <= 1'b1;
      else if (wr_in_ready) pk_valid_q <= 1'b0;
      if (start_q) half_q <= 1'b0;
      else if (m_hs && y_en) half_q <= !half_q && !m_last;
    end

  always_ff @(posedge clk) begin
    if (m_hs && !half_q) lo_q <= m_data;
    if (emit) pk_data_q <= half_q ? {m_data, lo_q} : {32'd0, m_data};
  end

  // ---------------- y write ----------------
  logic wcmd_q, wcmd_ready, wr_done, wr_fin_q, wr_ecmd;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      wcmd_q   <= 1'b0;
      wr_fin_q <= 1'b1;
      am_fin_q <= 1'b1;
    end else if (start) begin
      wcmd_q   <= 1'b0;
      wr_fin_q <= 1'b0;
      am_fin_q <= 1'b0;
    end else if (start_q) begin
      wcmd_q   <= y_en;
      wr_fin_q <= !y_en;
      am_fin_q <= !am_en;
    end else begin
      if (wcmd_ready) wcmd_q <= 1'b0;
      if (wr_done) wr_fin_q <= 1'b1;
      if (am_done) am_fin_q <= 1'b1;
    end

  axi_wr_eng #(.AW(32), .IDW(IDW), .LEN_W(32), .MAX_BURST(MAX_BURST), .OUTS(OUTS),
               .FIFO_DEPTH(WR_FIFO)) u_wr (
    .clk, .rst_n,
    .cfg_burst_i(9'd0), .cfg_outs_i(7'd0),
    .cmd_valid_i(wcmd_q), .cmd_ready_o(wcmd_ready), .cmd_addr_i(y_addr),
    .cmd_bytes_i(32'({rows, 2'b00})),
    .in_valid_i(pk_valid_q), .in_ready_o(wr_in_ready), .in_data_i(pk_data_q),
    .busy_o(), .done_o(wr_done), .stall_o(wr_stall_ev), .err_resp_o(), .err_cmd_o(wr_ecmd),
    .err_clr_i(start),
    .m_axi_awid_o, .m_axi_awaddr_o, .m_axi_awlen_o, .m_axi_awsize_o, .m_axi_awburst_o,
    .m_axi_awlock_o, .m_axi_awcache_o, .m_axi_awprot_o, .m_axi_awqos_o, .m_axi_awvalid_o,
    .m_axi_awready_i, .m_axi_wdata_o, .m_axi_wstrb_o, .m_axi_wlast_o, .m_axi_wvalid_o,
    .m_axi_wready_i, .m_axi_bid_i, .m_axi_bresp_i, .m_axi_bvalid_i, .m_axi_bready_o);

  // ---------------- completion and events ----------------
  assign all_done = busy && (&core_fin_now) && (wr_fin_q || wr_done) && (am_fin_q || am_done);

  assign rd_stall_ev = |rd_stall_p;
  assign rd_err_ev   = |(m_axi_rvalid_i & m_axi_rready_o & rresp_err(m_axi_rresp_i));
  assign wr_err_ev   = m_axi_bvalid_i && m_axi_bready_o && m_axi_bresp_i[1];

  function automatic logic [P-1:0] rresp_err(logic [P-1:0][1:0] r);
    for (int p = 0; p < P; p++) rresp_err[p] = r[p][1];
  endfunction

`ifndef SYNTHESIS
  // L3_ENGCMD: an engine rejected a command (the descriptor check must prevent it)
  logic c_ecmd_q;
  always @(posedge clk) begin
    if (rst_n === 1'b1 && ((|rd_ecmd) || wr_ecmd) && !c_ecmd_q)
      $error("L3_ENGCMD gemv_acc_top %m: an AXI engine rejected a command");
    c_ecmd_q <= (rst_n === 1'b1) && ((|rd_ecmd) || wr_ecmd);
  end
`endif

endmodule
