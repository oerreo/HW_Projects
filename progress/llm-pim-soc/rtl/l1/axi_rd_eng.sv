// axi_rd_eng: AXI4 read master, (address, byte count) command -> 64-bit beat stream
// (hierarchy.md 3.3 and 3.6).
//
// Command (valid/ready): cmd_addr_i must be 8-byte aligned, cmd_bytes_i >= 1, and the range
// [addr, addr + bytes) must not pass 2^AW. The engine reads ceil(bytes / 8) beats starting at
// addr; the bytes of the last beat beyond the length are memory contents (the consumer ignores
// them). A command that breaks a rule is rejected: it is accepted only when the engine is idle
// (busy_o = 0), produces no AXI traffic and no data, sets err_cmd_o (sticky) and pulses done_o
// in its handshake cycle (simulation message ENG_CMD).
//
// Bursts: INCR, size 8 bytes, ID 0, beats per burst = min(remaining beats, burst limit, beats
// to the next 4 KiB boundary). The burst limit is cfg_burst_i (1..MAX_BURST; 0 or a larger
// value means MAX_BURST) and the outstanding-burst limit cfg_outs_i (1..OUTS; 0 or larger means
// OUTS); both are sampled at the command handshake. MAX_BURST <= 16 keeps every burst legal on
// the AXI3 HP port.
//
// R buffer and backpressure: the R beats go into a FIFO_DEPTH-entry FIFO. An AR is presented
// only when the FIFO space not yet promised to earlier bursts (space counter: FIFO_DEPTH minus
// beats buffered minus beats requested and not yet received) covers the whole burst, so RREADY
// (= FIFO not full) is 1 whenever RVALID comes and R is never stalled by the engine, whatever
// the consumer does (simulation message ENG_RSTALL otherwise).
//
// Data stream: d_valid_o / d_ready_i / d_data_o / d_last_o (last beat of a command).
// Status: busy_o = a command is accepted and its last beat not yet delivered;
// done_o = 1-cycle pulse at the handshake of a last beat (or of a rejected command);
// stall_o = busy_o && d_ready_i && !d_valid_o (consumer waits for read data);
// err_resp_o = sticky RRESP[1] (SLVERR / DECERR seen on any beat; data still delivered);
// err_cmd_o = sticky rejected command. err_clr_i clears both (a new error in the same cycle
// wins).
//
// Latency (no backpressure): command handshake in cycle c -> ARVALID in c + 1.
// Simulation-only checks (tag first): VR_X / VR_HOLD / VR_STABLE on the command channel
// (and on the R FIFO input inside sync_fifo), ENG_CMD, ENG_RSTALL, ENG_RUNEXP (R beat with no
// burst outstanding), ENG_RLAST (RLAST not on the last beat of the burst).
module axi_rd_eng #(
  parameter int         DW         = 64,              // data width (64 only)
  parameter int         AW         = 32,              // address width 12..64
  parameter int         IDW        = 1,               // AXI ID width (ID is always 0)
  parameter int         LEN_W      = 32,              // cmd_bytes_i width 4..40
  parameter int         MAX_BURST  = 16,              // beats per burst 1..256 (16: AXI3 / HP)
  parameter int         OUTS       = 4,               // outstanding bursts 1..64
  parameter int         FIFO_DEPTH = MAX_BURST * OUTS,// R buffer beats, >= MAX_BURST
  parameter logic [3:0] AXCACHE    = 4'b0011          // ARCACHE (normal non-cacheable bufferable)
) (
  input  logic              clk,
  input  logic              rst_n,
  // runtime limits, sampled at the command handshake
  input  logic [8:0]        cfg_burst_i,
  input  logic [6:0]        cfg_outs_i,
  // command
  input  logic              cmd_valid_i,
  output logic              cmd_ready_o,
  input  logic [AW-1:0]     cmd_addr_i,
  input  logic [LEN_W-1:0]  cmd_bytes_i,
  // data stream
  output logic              d_valid_o,
  input  logic              d_ready_i,
  output logic [DW-1:0]     d_data_o,
  output logic              d_last_o,
  // status
  output logic              busy_o,
  output logic              done_o,
  output logic              stall_o,
  output logic              err_resp_o,
  output logic              err_cmd_o,
  input  logic              err_clr_i,
  // AXI4 read address
  output logic [IDW-1:0]    m_axi_arid_o,
  output logic [AW-1:0]     m_axi_araddr_o,
  output logic [7:0]        m_axi_arlen_o,
  output logic [2:0]        m_axi_arsize_o,
  output logic [1:0]        m_axi_arburst_o,
  output logic              m_axi_arlock_o,
  output logic [3:0]        m_axi_arcache_o,
  output logic [2:0]        m_axi_arprot_o,
  output logic [3:0]        m_axi_arqos_o,
  output logic              m_axi_arvalid_o,
  input  logic              m_axi_arready_i,
  // AXI4 read data
  input  logic [IDW-1:0]    m_axi_rid_i,      // ignored (single ID, in order)
  input  logic [DW-1:0]     m_axi_rdata_i,
  input  logic [1:0]        m_axi_rresp_i,
  input  logic              m_axi_rlast_i,
  input  logic              m_axi_rvalid_i,
  output logic              m_axi_rready_o
);

  // ---------------- parameter checks ----------------
  if (DW != 64) $error("axi_rd_eng: DW=%0d must be 64", DW);
  if (AW < 12 || AW > 64) $error("axi_rd_eng: AW=%0d must be 12..64", AW);
  if (IDW < 1 || IDW > 16) $error("axi_rd_eng: IDW=%0d must be 1..16", IDW);
  if (LEN_W < 4 || LEN_W > 40) $error("axi_rd_eng: LEN_W=%0d must be 4..40", LEN_W);
  if (MAX_BURST < 1 || MAX_BURST > 256) $error("axi_rd_eng: MAX_BURST=%0d must be 1..256", MAX_BURST);
  if (OUTS < 1 || OUTS > 64) $error("axi_rd_eng: OUTS=%0d must be 1..64", OUTS);
  if (FIFO_DEPTH < MAX_BURST) $error("axi_rd_eng: FIFO_DEPTH=%0d must be >= MAX_BURST=%0d", FIFO_DEPTH, MAX_BURST);

  localparam int BT_W = LEN_W - 2;                 // beat count, up to 2^(LEN_W-3)
  localparam int XW   = ((AW > LEN_W) ? AW : LEN_W) + 1;
  localparam int SP_W = $clog2(FIFO_DEPTH + 1);
  localparam int OC_W = $clog2(OUTS + 1);
  localparam int PC_W = $clog2(FIFO_DEPTH + OUTS + 2);

  // ---------------- command ----------------
  logic            cmd_bad, cmd_hs, cmd_ok;
  logic [LEN_W:0]  bytes_p7;
  logic            act_q;                          // AR generator owns a command
  logic [AW-4:0]   wa_q;                           // next burst word address (addr / 8)
  logic [BT_W-1:0] rem_q;                          // beats not yet requested
  logic [8:0]      blim_q;                         // burst limit of the command
  logic [6:0]      olim_q;                         // outstanding limit of the command
  logic [PC_W-1:0] pend_q;                         // accepted commands not yet delivered

  assign bytes_p7 = {1'b0, cmd_bytes_i} + (LEN_W + 1)'(7);
  assign cmd_bad  = (cmd_addr_i[2:0] != 3'd0) || (cmd_bytes_i == '0) ||
                    (XW'(cmd_addr_i) + XW'(cmd_bytes_i) > (XW'(1) << AW));
  // a rejected command waits until the engine is idle, so its done pulse cannot meet another
  assign cmd_ready_o = !act_q && !(cmd_valid_i && cmd_bad && busy_o);
  assign cmd_hs      = cmd_valid_i && cmd_ready_o;
  assign cmd_ok      = cmd_hs && !cmd_bad;

  // ---------------- burst size ----------------
  logic [9:0] to4k, rem_c, blen;                   // beats, 1..512
  logic [8:0] blim_c;
  logic       last_burst;
  assign to4k   = 10'd512 - {1'b0, wa_q[8:0]};
  assign rem_c  = (64'(rem_q) > 64'd512) ? 10'd512 : 10'(rem_q);
  always_comb begin
    blen = rem_c;
    if ({1'b0, blim_q} < blen) blen = {1'b0, blim_q};
    if (to4k < blen) blen = to4k;
  end
  assign last_burst = (64'(blen) == 64'(rem_q));

  // ---------------- AR channel ----------------
  logic            arvalid_q;
  logic [AW-1:0]   araddr_q;
  logic [7:0]      arlen_q;
  logic [OC_W-1:0] outs_q;                         // bursts presented, RLAST not yet received
  logic [SP_W-1:0] space_q;                        // FIFO beats not promised to a burst
  logic            ar_free, ar_go;
  logic            ar_hs, r_hs, rlast_hs, d_hs;

  assign ar_free = !arvalid_q || m_axi_arready_i;
  assign ar_go   = act_q && ar_free && (outs_q < OC_W'(olim_q)) && (32'(space_q) >= 32'(blen));
  assign ar_hs   = arvalid_q && m_axi_arready_i;

  // burst information, one entry per presented burst, popped at its RLAST
  logic       bi_in_ready, bi_valid, bi_last;
  logic [7:0] bi_len;
  sync_fifo #(.W(9), .DEPTH(OUTS)) u_binfo (
    .clk, .rst_n,
    .in_valid_i (ar_go),
    .in_ready_o (bi_in_ready),
    .in_data_i  ({last_burst, 8'(blen - 10'd1)}),
    .out_valid_o(bi_valid),
    .out_ready_i(rlast_hs),
    .out_data_o ({bi_last, bi_len}),
    .level_o    ()
  );

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      act_q     <= 1'b0;
      arvalid_q <= 1'b0;
      outs_q    <= '0;
      space_q   <= SP_W'(FIFO_DEPTH);
      pend_q    <= '0;
    end else begin
      if (cmd_ok) act_q <= 1'b1;
      else if (ar_go && last_burst) act_q <= 1'b0;
      if (ar_go) arvalid_q <= 1'b1;
      else if (ar_hs) arvalid_q <= 1'b0;
      outs_q  <= outs_q + OC_W'(ar_go) - OC_W'(rlast_hs);
      space_q <= space_q - (ar_go ? SP_W'(blen) : SP_W'(0)) + SP_W'(d_hs);
      pend_q  <= pend_q + PC_W'(cmd_ok) - PC_W'(d_hs && d_last_o);
    end

  // command and AR payload registers (datapath, qualified by act_q / arvalid_q)
  always_ff @(posedge clk) begin
    if (cmd_ok) begin
      wa_q   <= cmd_addr_i[AW-1:3];
      rem_q  <= BT_W'(bytes_p7[LEN_W:3]);
      blim_q <= (cfg_burst_i == 9'd0 || cfg_burst_i > 9'(MAX_BURST)) ? 9'(MAX_BURST) : cfg_burst_i;
      olim_q <= (cfg_outs_i == 7'd0 || cfg_outs_i > 7'(OUTS)) ? 7'(OUTS) : cfg_outs_i;
    end else if (ar_go) begin
      wa_q  <= wa_q + (AW - 3)'(blen);
      rem_q <= rem_q - BT_W'(blen);
    end
    if (ar_go) begin
      araddr_q <= {wa_q, 3'b000};
      arlen_q  <= 8'(blen - 10'd1);
    end
  end

  assign m_axi_arid_o    = '0;
  assign m_axi_araddr_o  = araddr_q;
  assign m_axi_arlen_o   = arlen_q;
  assign m_axi_arsize_o  = 3'd3;
  assign m_axi_arburst_o = 2'b01;
  assign m_axi_arlock_o  = 1'b0;
  assign m_axi_arcache_o = AXCACHE;
  assign m_axi_arprot_o  = 3'b000;
  assign m_axi_arqos_o   = 4'd0;
  assign m_axi_arvalid_o = arvalid_q;

  // ---------------- R channel and buffer ----------------
  logic f_in_ready;
  assign m_axi_rready_o = f_in_ready;
  assign r_hs     = m_axi_rvalid_i && f_in_ready;
  assign rlast_hs = r_hs && m_axi_rlast_i;
  assign d_hs     = d_valid_o && d_ready_i;

  sync_fifo #(.W(DW + 1), .DEPTH(FIFO_DEPTH)) u_rbuf (
    .clk, .rst_n,
    .in_valid_i (m_axi_rvalid_i),
    .in_ready_o (f_in_ready),
    .in_data_i  ({m_axi_rlast_i && bi_last, m_axi_rdata_i}),
    .out_valid_o(d_valid_o),
    .out_ready_i(d_ready_i),
    .out_data_o ({d_last_o, d_data_o}),
    .level_o    ()
  );

  // ---------------- status ----------------
  logic err_resp_q, err_cmd_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      err_resp_q <= 1'b0;
      err_cmd_q  <= 1'b0;
    end else begin
      if (r_hs && m_axi_rresp_i[1]) err_resp_q <= 1'b1;
      else if (err_clr_i)           err_resp_q <= 1'b0;
      if (cmd_hs && cmd_bad)        err_cmd_q  <= 1'b1;
      else if (err_clr_i)           err_cmd_q  <= 1'b0;
    end

  assign busy_o     = pend_q != '0;
  assign done_o     = (d_hs && d_last_o) || (cmd_hs && cmd_bad);
  assign stall_o    = busy_o && d_ready_i && !d_valid_o;
  assign err_resp_o = err_resp_q;
  assign err_cmd_o  = err_cmd_q;

`ifndef SYNTHESIS
  // ---------------- simulation-only checks ----------------
  logic            c_pend_q;
  logic [AW+LEN_W-1:0] c_pl_q;
  logic [8:0]      c_rbeat_q;
  always @(posedge clk) begin
    if (rst_n === 1'b1) begin
      if ($isunknown({cmd_valid_i, d_ready_i, m_axi_arready_i, m_axi_rvalid_i, err_clr_i}))
        $error("VR_X axi_rd_eng %m: X/Z on cmd_valid_i / d_ready_i / arready / rvalid / err_clr_i");
      if (c_pend_q && cmd_valid_i !== 1'b1)
        $error("VR_HOLD axi_rd_eng %m: cmd_valid_i dropped before cmd_ready_o");
      else if (c_pend_q && {cmd_addr_i, cmd_bytes_i} !== c_pl_q)
        $error("VR_STABLE axi_rd_eng %m: command payload changed while waiting");
      if (cmd_hs && cmd_bad)
        $error("ENG_CMD axi_rd_eng %m: rejected command addr 0x%0h bytes %0d (8-byte alignment, bytes >= 1, no wrap)",
               cmd_addr_i, cmd_bytes_i);
      if (m_axi_rvalid_i === 1'b1 && !f_in_ready)
        $error("ENG_RSTALL axi_rd_eng %m: R beat while the buffer is full (space accounting broken)");
      if (r_hs && !bi_valid)
        $error("ENG_RUNEXP axi_rd_eng %m: R beat without an outstanding burst");
      if (r_hs && bi_valid && (m_axi_rlast_i !== (c_rbeat_q == {1'b0, bi_len})))
        $error("ENG_RLAST axi_rd_eng %m: RLAST=%b on beat %0d of a %0d-beat burst", m_axi_rlast_i,
               c_rbeat_q, bi_len + 1);
    end
    c_pend_q <= rst_n === 1'b1 && cmd_valid_i === 1'b1 && cmd_ready_o === 1'b0;
    c_pl_q   <= {cmd_addr_i, cmd_bytes_i};
    if (rst_n !== 1'b1) c_rbeat_q <= '0;
    else if (rlast_hs) c_rbeat_q <= '0;
    else if (r_hs) c_rbeat_q <= c_rbeat_q + 1'b1;
  end
`endif

endmodule
