// axi_wr_eng: AXI4 write master, (address, byte count) command + 64-bit beat stream -> bursts
// (hierarchy.md 3.3 and 3.6).
//
// Command (valid/ready): same rules as axi_rd_eng: cmd_addr_i 8-byte aligned, cmd_bytes_i >= 1,
// no wrap past 2^AW. A rejected command is accepted only when the engine is idle, produces no
// AXI traffic, consumes no data, sets err_cmd_o (sticky) and pulses done_o in its handshake
// cycle (simulation message ENG_CMD).
//
// Data: in_valid_i / in_ready_o / in_data_i, ceil(bytes / 8) beats per command, in command
// order, byte i of the command in lane i mod 8 of beat i / 8. Beats may arrive before their
// command (they wait in the buffer). The caller sends exactly ceil(bytes / 8) beats for every
// accepted good command and none for a rejected one. A 32-bit producer packs two words per beat.
//
// Bursts: INCR, size 8, ID 0, beats = min(remaining, burst limit, beats to the 4 KiB boundary),
// limits cfg_burst_i / cfg_outs_i as in axi_rd_eng (sampled at the command handshake).
// WSTRB = 8'hFF on every beat except the last beat of a command whose length is not a
// multiple of 8: there WSTRB = (1 << (bytes mod 8)) - 1.
// Store and forward per burst: an AW is presented only when all beats of the burst are in the
// buffer (uncommitted-beat counter), and W of a burst starts after its AW handshake, so WVALID
// stays high through a burst whenever the slave takes it. FIFO_DEPTH >= 2 * MAX_BURST lets the
// next burst fill while the current one drains (1 beat per cycle).
// BREADY is always 1. Outstanding bursts (AW presented, B not yet received) <= limit.
//
// Status: busy_o = a command is accepted and its last B not yet received; done_o = 1-cycle
// pulse at the B handshake of the last burst of a command (or at a rejected command);
// stall_o = in_valid_i && !in_ready_o (producer held by the write side);
// err_resp_o = sticky BRESP[1]; err_cmd_o = sticky rejected command; err_clr_i clears both
// (a new error in the same cycle wins).
//
// Simulation-only checks (tag first): VR_X / VR_HOLD / VR_STABLE on the command channel (the
// data input is checked by the sync_fifo), ENG_CMD, ENG_BUNEXP (B with no burst outstanding).
module axi_wr_eng #(
  parameter int         DW         = 64,
  parameter int         AW         = 32,
  parameter int         IDW        = 1,
  parameter int         LEN_W      = 32,
  parameter int         MAX_BURST  = 16,
  parameter int         OUTS       = 4,
  parameter int         FIFO_DEPTH = 2 * MAX_BURST,   // write buffer beats, >= MAX_BURST
  parameter logic [3:0] AXCACHE    = 4'b0011
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic [8:0]        cfg_burst_i,
  input  logic [6:0]        cfg_outs_i,
  // command
  input  logic              cmd_valid_i,
  output logic              cmd_ready_o,
  input  logic [AW-1:0]     cmd_addr_i,
  input  logic [LEN_W-1:0]  cmd_bytes_i,
  // data stream
  input  logic              in_valid_i,
  output logic              in_ready_o,
  input  logic [DW-1:0]     in_data_i,
  // status
  output logic              busy_o,
  output logic              done_o,
  output logic              stall_o,
  output logic              err_resp_o,
  output logic              err_cmd_o,
  input  logic              err_clr_i,
  // AXI4 write address
  output logic [IDW-1:0]    m_axi_awid_o,
  output logic [AW-1:0]     m_axi_awaddr_o,
  output logic [7:0]        m_axi_awlen_o,
  output logic [2:0]        m_axi_awsize_o,
  output logic [1:0]        m_axi_awburst_o,
  output logic              m_axi_awlock_o,
  output logic [3:0]        m_axi_awcache_o,
  output logic [2:0]        m_axi_awprot_o,
  output logic [3:0]        m_axi_awqos_o,
  output logic              m_axi_awvalid_o,
  input  logic              m_axi_awready_i,
  // AXI4 write data
  output logic [DW-1:0]     m_axi_wdata_o,
  output logic [DW/8-1:0]   m_axi_wstrb_o,
  output logic              m_axi_wlast_o,
  output logic              m_axi_wvalid_o,
  input  logic              m_axi_wready_i,
  // AXI4 write response
  input  logic [IDW-1:0]    m_axi_bid_i,      // ignored (single ID, in order)
  input  logic [1:0]        m_axi_bresp_i,
  input  logic              m_axi_bvalid_i,
  output logic              m_axi_bready_o
);

  if (DW != 64) $error("axi_wr_eng: DW=%0d must be 64", DW);
  if (AW < 12 || AW > 64) $error("axi_wr_eng: AW=%0d must be 12..64", AW);
  if (IDW < 1 || IDW > 16) $error("axi_wr_eng: IDW=%0d must be 1..16", IDW);
  if (LEN_W < 4 || LEN_W > 40) $error("axi_wr_eng: LEN_W=%0d must be 4..40", LEN_W);
  if (MAX_BURST < 1 || MAX_BURST > 256) $error("axi_wr_eng: MAX_BURST=%0d must be 1..256", MAX_BURST);
  if (OUTS < 1 || OUTS > 64) $error("axi_wr_eng: OUTS=%0d must be 1..64", OUTS);
  if (FIFO_DEPTH < MAX_BURST) $error("axi_wr_eng: FIFO_DEPTH=%0d must be >= MAX_BURST=%0d", FIFO_DEPTH, MAX_BURST);

  localparam int BT_W = LEN_W - 2;
  localparam int XW   = ((AW > LEN_W) ? AW : LEN_W) + 1;
  localparam int UC_W = $clog2(FIFO_DEPTH + 1);
  localparam int OC_W = $clog2(OUTS + 1);
  localparam int PC_W = $clog2(OUTS + 2);

  // ---------------- command ----------------
  logic            cmd_bad, cmd_hs, cmd_ok;
  logic [LEN_W:0]  bytes_p7;
  logic            act_q;
  logic [AW-4:0]   wa_q;
  logic [BT_W-1:0] rem_q;
  logic [8:0]      blim_q;
  logic [6:0]      olim_q;
  logic [7:0]      lstrb_q;                        // WSTRB of the last beat of the command
  logic [PC_W-1:0] pend_q;

  assign bytes_p7 = {1'b0, cmd_bytes_i} + (LEN_W + 1)'(7);
  assign cmd_bad  = (cmd_addr_i[2:0] != 3'd0) || (cmd_bytes_i == '0) ||
                    (XW'(cmd_addr_i) + XW'(cmd_bytes_i) > (XW'(1) << AW));
  assign cmd_ready_o = !act_q && !(cmd_valid_i && cmd_bad && busy_o);
  assign cmd_hs      = cmd_valid_i && cmd_ready_o;
  assign cmd_ok      = cmd_hs && !cmd_bad;

  // ---------------- burst size ----------------
  logic [9:0] to4k, rem_c, blen;
  logic       last_burst;
  assign to4k  = 10'd512 - {1'b0, wa_q[8:0]};
  assign rem_c = (64'(rem_q) > 64'd512) ? 10'd512 : 10'(rem_q);
  always_comb begin
    blen = rem_c;
    if ({1'b0, blim_q} < blen) blen = {1'b0, blim_q};
    if (to4k < blen) blen = to4k;
  end
  assign last_burst = (64'(blen) == 64'(rem_q));

  // ---------------- AW channel ----------------
  logic            awvalid_q, aw_lastc_q;
  logic [7:0]      aw_strb_q;                      // last-beat WSTRB of the presented burst
  logic            bq_valid, bq_last;
  logic [AW-1:0]   awaddr_q;
  logic [7:0]      awlen_q;
  logic [OC_W-1:0] outs_q;
  logic [UC_W-1:0] unc_q;                          // buffered beats not yet given to an AW
  logic            aw_free, aw_go, aw_hs, in_hs, w_hs, wlast_hs, b_hs;

  assign aw_free = !awvalid_q || m_axi_awready_i;
  assign aw_go   = act_q && aw_free && (outs_q < OC_W'(olim_q)) && (32'(unc_q) >= 32'(blen));
  assign aw_hs   = awvalid_q && m_axi_awready_i;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      act_q     <= 1'b0;
      awvalid_q <= 1'b0;
      outs_q    <= '0;
      unc_q     <= '0;
      pend_q    <= '0;
    end else begin
      if (cmd_ok) act_q <= 1'b1;
      else if (aw_go && last_burst) act_q <= 1'b0;
      if (aw_go) awvalid_q <= 1'b1;
      else if (aw_hs) awvalid_q <= 1'b0;
      outs_q <= outs_q + OC_W'(aw_go) - OC_W'(b_hs);
      unc_q  <= unc_q + UC_W'(in_hs) - (aw_go ? UC_W'(blen) : UC_W'(0));
      pend_q <= pend_q + PC_W'(cmd_ok) - PC_W'(b_hs && bq_last);
    end

  always_ff @(posedge clk) begin
    if (cmd_ok) begin
      wa_q    <= cmd_addr_i[AW-1:3];
      rem_q   <= BT_W'(bytes_p7[LEN_W:3]);
      blim_q  <= (cfg_burst_i == 9'd0 || cfg_burst_i > 9'(MAX_BURST)) ? 9'(MAX_BURST) : cfg_burst_i;
      olim_q  <= (cfg_outs_i == 7'd0 || cfg_outs_i > 7'(OUTS)) ? 7'(OUTS) : cfg_outs_i;
      lstrb_q <= (cmd_bytes_i[2:0] == 3'd0) ? 8'hFF : 8'((9'd1 << cmd_bytes_i[2:0]) - 9'd1);
    end else if (aw_go) begin
      wa_q  <= wa_q + (AW - 3)'(blen);
      rem_q <= rem_q - BT_W'(blen);
    end
    if (aw_go) begin
      awaddr_q   <= {wa_q, 3'b000};
      awlen_q    <= 8'(blen - 10'd1);
      aw_lastc_q <= last_burst;
      aw_strb_q  <= last_burst ? lstrb_q : 8'hFF;
    end
  end

  assign m_axi_awid_o    = '0;
  assign m_axi_awaddr_o  = awaddr_q;
  assign m_axi_awlen_o   = awlen_q;
  assign m_axi_awsize_o  = 3'd3;
  assign m_axi_awburst_o = 2'b01;
  assign m_axi_awlock_o  = 1'b0;
  assign m_axi_awcache_o = AXCACHE;
  assign m_axi_awprot_o  = 3'b000;
  assign m_axi_awqos_o   = 4'd0;
  assign m_axi_awvalid_o = awvalid_q;

  // ---------------- data buffer ----------------
  logic          f_valid;
  logic [DW-1:0] f_data;
  assign in_hs = in_valid_i && in_ready_o;

  sync_fifo #(.W(DW), .DEPTH(FIFO_DEPTH)) u_wbuf (
    .clk, .rst_n,
    .in_valid_i (in_valid_i),
    .in_ready_o (in_ready_o),
    .in_data_i  (in_data_i),
    .out_valid_o(f_valid),
    .out_ready_i(w_hs),
    .out_data_o (f_data),
    .level_o    ()
  );

  // ---------------- W channel: bursts whose AW was accepted ----------------
  logic       wq_valid;
  logic [7:0] wq_len, wq_strb, wbeat_q;
  sync_fifo #(.W(16), .DEPTH(OUTS)) u_wq (
    .clk, .rst_n,
    .in_valid_i (aw_hs),
    .in_ready_o (),
    .in_data_i  ({awlen_q, aw_strb_q}),
    .out_valid_o(wq_valid),
    .out_ready_i(wlast_hs),
    .out_data_o ({wq_len, wq_strb}),
    .level_o    ()
  );

  assign m_axi_wvalid_o = f_valid && wq_valid;
  assign m_axi_wdata_o  = f_data;
  assign m_axi_wlast_o  = wbeat_q == wq_len;
  assign m_axi_wstrb_o  = m_axi_wlast_o ? wq_strb : 8'hFF;
  assign w_hs     = m_axi_wvalid_o && m_axi_wready_i;
  assign wlast_hs = w_hs && m_axi_wlast_o;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) wbeat_q <= '0;
    else if (wlast_hs) wbeat_q <= '0;
    else if (w_hs) wbeat_q <= wbeat_q + 1'b1;

  // ---------------- B channel ----------------
  sync_fifo #(.W(1), .DEPTH(OUTS)) u_bq (
    .clk, .rst_n,
    .in_valid_i (aw_hs),
    .in_ready_o (),
    .in_data_i  (aw_lastc_q),
    .out_valid_o(bq_valid),
    .out_ready_i(b_hs),
    .out_data_o (bq_last),
    .level_o    ()
  );
  assign m_axi_bready_o = 1'b1;
  assign b_hs = m_axi_bvalid_i;

  // ---------------- status ----------------
  logic err_resp_q, err_cmd_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      err_resp_q <= 1'b0;
      err_cmd_q  <= 1'b0;
    end else begin
      if (b_hs && m_axi_bresp_i[1]) err_resp_q <= 1'b1;
      else if (err_clr_i)           err_resp_q <= 1'b0;
      if (cmd_hs && cmd_bad)        err_cmd_q  <= 1'b1;
      else if (err_clr_i)           err_cmd_q  <= 1'b0;
    end

  assign busy_o     = pend_q != '0;
  assign done_o     = (b_hs && bq_last) || (cmd_hs && cmd_bad);
  assign stall_o    = in_valid_i && !in_ready_o;
  assign err_resp_o = err_resp_q;
  assign err_cmd_o  = err_cmd_q;

`ifndef SYNTHESIS
  logic                c_pend_q;
  logic [AW+LEN_W-1:0] c_pl_q;
  always @(posedge clk) begin
    if (rst_n === 1'b1) begin
      if ($isunknown({cmd_valid_i, m_axi_awready_i, m_axi_wready_i, m_axi_bvalid_i, err_clr_i}))
        $error("VR_X axi_wr_eng %m: X/Z on cmd_valid_i / awready / wready / bvalid / err_clr_i");
      if (c_pend_q && cmd_valid_i !== 1'b1)
        $error("VR_HOLD axi_wr_eng %m: cmd_valid_i dropped before cmd_ready_o");
      else if (c_pend_q && {cmd_addr_i, cmd_bytes_i} !== c_pl_q)
        $error("VR_STABLE axi_wr_eng %m: command payload changed while waiting");
      if (cmd_hs && cmd_bad)
        $error("ENG_CMD axi_wr_eng %m: rejected command addr 0x%0h bytes %0d (8-byte alignment, bytes >= 1, no wrap)",
               cmd_addr_i, cmd_bytes_i);
      if (m_axi_bvalid_i === 1'b1 && !bq_valid)
        $error("ENG_BUNEXP axi_wr_eng %m: B response without an outstanding burst");
    end
    c_pend_q <= rst_n === 1'b1 && cmd_valid_i === 1'b1 && cmd_ready_o === 1'b0;
    c_pl_q   <= {cmd_addr_i, cmd_bytes_i};
  end
`endif

endmodule
