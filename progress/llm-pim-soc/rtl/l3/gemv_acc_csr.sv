// gemv_acc_csr: register file of the GEMV accelerator IP gemv_acc_top (L3).
// Register map and behaviour: docs/spec/gemv_acc.md (common frame arch.md 7.2; decided
// behaviour of pqc-ntt-ip l4_axi.md: done_sticky priority, W1C with set winning, undefined
// addresses read 0, WSTRB ignored).
//
// Input: the register access interface of axil_slave (one write and one read strobe per cycle,
// both from flip-flops). Every register action happens in the cycle of the strobe; a read in
// the same cycle as a write returns the state before that write.
//
//   0x00 ID          R     0x4741_0001 ("GA", version 1)
//   0x04 CONFIG      R     [7:0] FCLK_MHZ, [11:8] P, [15:12] log2(LANES), [31:16] NMAX
//   0x08 CTRL        W     bit0 start, [7:4] op (1 = GEMV); reads 0
//   0x0C STATUS      R     bit0 busy, bit1 done_sticky, bit2 err_any (ERR != 0)
//   0x10 ERR         R/W1C bit0 START_BUSY, bit1 BAD_OP, bit2 BAD_DESC, bit3 MISALIGN,
//                          bit4 RD_RESP, bit5 WR_RESP
//   0x14 CYCLES      R     cycles of the last call (start to done)
//   0x18 RD_STALL    R     cycles of the last call with a slice waiting for read data
//   0x1C WR_STALL    R     cycles of the last call with the y packer held by the write engine
//   0x20 OPS         R     completed calls
//   0x40 W_ADDR      RW    row records (arch.md 2.2)
//   0x44 X_ADDR      RW    x (int8 [N])
//   0x48 Y_ADDR      RW    y (int32 [ROWS])
//   0x4C ROWS        RW    32 bits (legal 1 .. 2^ROWS_W - 1)
//   0x50 N           RW    32 bits (legal 1 .. NMAX)
//   0x54 XM          RW    [16:0]
//   0x58 EXP         RW    [7:0] we, [15:8] xe, [23:16] fo (signed)
//   0x5C FLAGS       RW    bit0 argmax_en, bit1 y_en (reset 0x2)
//   0x60 ARGMAX_IDX  R     [IDX_W-1:0] index of the first maximum of y (last argmax call)
//   0x64 ARGMAX_VAL  R     that maximum (int32)
//   other                  read 0, write ignored
//
// Op state: busy_q is 1 from the cycle after an accepted start (s) up to and including the
// done_i cycle (e). "Idle" for a CTRL write is !busy_q or the done_i cycle itself (the call has
// finished in that cycle: a start written then is accepted).
// CTRL write while idle: clears done_sticky (wins over done_i of the same cycle), except a
// start with an op other than 1 (BAD_OP, nothing else changes). With start = 1 and op = 1 the
// descriptor is checked: BAD_DESC (ROWS or N out of range, FLAGS[1:0] = 0, a used buffer
// passing 2^32: W_ADDR + ROWS x 8 (1 + ceil(N/8)), X_ADDR + N, Y_ADDR + 4 ROWS if y_en) and
// MISALIGN (W_ADDR, X_ADDR, Y_ADDR if y_en not 8-byte aligned) are set independently; with
// either one the call does not start. Otherwise start_o = 1 in that cycle and the descriptor
// is latched into the op_* outputs (valid from s + 1 until the next start).
// CTRL write with start = 1 while busy (not in the done_i cycle): START_BUSY, ignored (also
// BAD_OP if op != 1, as in pqc-ntt-ip; the descriptor is not checked while busy). A CTRL
// write with start = 0 while busy has no effect.
// ERR: W1C; a set wins over a clear of the same bit in the same cycle. RD_RESP / WR_RESP are
// set by every read beat / write response with SLVERR or DECERR (rd_err_i / wr_err_i).
// Counters: CYCLES, RD_STALL, WR_STALL are cleared by the start (cycle s) and count the busy_q
// cycles (s + 1 .. e; RD_STALL / WR_STALL only those with rd_stall_i / wr_stall_i), so
// CYCLES = e - s. They wrap at 2^32. OPS counts done_i. ARGMAX_IDX / ARGMAX_VAL take
// am_idx_i / am_max_i at am_done_i.
// Reset: all registers 0 except FLAGS (y_en = 1); ID and CONFIG are constants.
module gemv_acc_csr
  import llm_pkg::*;
#(
  parameter int ADDR_W   = 12,       // AXI4-Lite byte address width 8..32
  parameter int P        = 1,        // CONFIG only
  parameter int LANES    = 8,        // CONFIG only (power of two)
  parameter int NMAX     = N_MAX,    // N limit, 8..65535
  parameter int ROWS_W   = 16,       // ROWS limit 2^ROWS_W - 1, 1..24
  parameter int IDX_W    = 16,       // argmax index width 1..31
  parameter int FCLK_MHZ = 100,      // CONFIG only, 1..255
  localparam int NW      = $clog2(NMAX + 1),
  localparam int WB_W    = ROWS_W + $clog2(NMAX / 8 + 2) + 3  // W bytes of a call
) (
  input  logic                    clk,
  input  logic                    rst_n,
  // register access (axil_slave)
  input  logic                    wr_en_i,
  input  logic [ADDR_W-1:0]       wr_addr_i,
  input  logic [31:0]             wr_data_i,
  input  logic                    rd_en_i,
  input  logic [ADDR_W-1:0]       rd_addr_i,
  output logic [31:0]             rd_data_o,
  // op control
  output logic                    start_o,     // accepted start (cycle s)
  output logic                    busy_o,      // s + 1 .. e
  input  logic                    done_i,      // the call is complete (cycle e, only while busy)
  // latched descriptor (from s + 1)
  output logic [31:0]             op_w_addr_o,
  output logic [31:0]             op_x_addr_o,
  output logic [31:0]             op_y_addr_o,
  output logic [ROWS_W-1:0]       op_rows_o,
  output logic [NW-1:0]           op_n_o,
  output logic [AM_W-1:0]         op_xm_o,
  output logic signed [E_W-1:0]   op_we_o,
  output logic signed [E_W-1:0]   op_xe_o,
  output logic signed [E_W-1:0]   op_fo_o,
  output logic                    op_am_en_o,
  output logic                    op_y_en_o,
  output logic [WB_W-1:0]         op_wbytes_o, // ROWS x 8 (1 + ceil(N/8))
  // events of the current cycle
  input  logic                    rd_err_i,    // read beat with RRESP[1]
  input  logic                    wr_err_i,    // write response with BRESP[1]
  input  logic                    rd_stall_i,  // a slice waits for read data
  input  logic                    wr_stall_i,  // packer beat not taken by the write engine
  input  logic                    am_done_i,
  input  logic [IDX_W-1:0]        am_idx_i,
  input  logic signed [31:0]      am_max_i
);
  if (ADDR_W < 8 || ADDR_W > 32) $error("gemv_acc_csr: ADDR_W=%0d must be 8..32", ADDR_W);
  if (P < 1 || P > 15) $error("gemv_acc_csr: P=%0d does not fit CONFIG[11:8]", P);
  if (LANES < 1 || LANES > 32768 || (LANES & (LANES - 1)) != 0)
    $error("gemv_acc_csr: LANES=%0d must be a power of two", LANES);
  if (NMAX < 8 || NMAX > 65535) $error("gemv_acc_csr: NMAX=%0d must be 8..65535", NMAX);
  if (ROWS_W < 1 || ROWS_W > 24) $error("gemv_acc_csr: ROWS_W=%0d must be 1..24", ROWS_W);
  if (IDX_W < 1 || IDX_W > 31) $error("gemv_acc_csr: IDX_W=%0d must be 1..31", IDX_W);
  if (FCLK_MHZ < 1 || FCLK_MHZ > 255) $error("gemv_acc_csr: FCLK_MHZ=%0d must be 1..255", FCLK_MHZ);

  localparam logic [31:0] ID_VAL     = 32'h4741_0001;
  localparam logic [31:0] CONFIG_VAL = {16'(NMAX), 4'($clog2(LANES)), 4'(P), 8'(FCLK_MHZ)};
  localparam int          NBW        = $clog2(NMAX / 8 + 2);    // 1 + ceil(N/8)
  localparam int          ERR_W      = 6;

  // register word offsets (byte offset / 4)
  localparam logic [5:0] R_ID = 6'h00, R_CONFIG = 6'h01, R_CTRL = 6'h02, R_STATUS = 6'h03,
                         R_ERR = 6'h04, R_CYCLES = 6'h05, R_RDSTALL = 6'h06, R_WRSTALL = 6'h07,
                         R_OPS = 6'h08, R_WADDR = 6'h10, R_XADDR = 6'h11, R_YADDR = 6'h12,
                         R_ROWS = 6'h13, R_N = 6'h14, R_XM = 6'h15, R_EXP = 6'h16,
                         R_FLAGS = 6'h17, R_AMIDX = 6'h18, R_AMVAL = 6'h19;
  localparam int E_START_BUSY = 0, E_BAD_OP = 1, E_BAD_DESC = 2, E_MISALIGN = 3, E_RD_RESP = 4,
                 E_WR_RESP = 5;

  // ---------------- decode ----------------
  logic        wr_hit, rd_hit;
  logic [5:0]  wr_w, rd_w;
  logic [31:0] wr_a32, rd_a32;
  assign wr_a32 = 32'(wr_addr_i);
  assign rd_a32 = 32'(rd_addr_i);
  assign wr_hit = wr_en_i && (wr_a32[31:8] == 24'd0);   // registers in the first 256 bytes
  assign rd_hit = rd_a32[31:8] == 24'd0;
  assign wr_w   = wr_a32[7:2];
  assign rd_w   = rd_a32[7:2];

  // ---------------- descriptor registers ----------------
  logic [31:0]     waddr_r, xaddr_r, yaddr_r, rows_r, n_r, exp_r;
  logic [AM_W-1:0] xm_r;
  logic [1:0]      flags_r;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      waddr_r <= '0;
      xaddr_r <= '0;
      yaddr_r <= '0;
      rows_r  <= '0;
      n_r     <= '0;
      xm_r    <= '0;
      exp_r   <= '0;
      flags_r <= 2'b10;
    end else if (wr_hit) begin
      case (wr_w)
        R_WADDR: waddr_r <= wr_data_i;
        R_XADDR: xaddr_r <= wr_data_i;
        R_YADDR: yaddr_r <= wr_data_i;
        R_ROWS:  rows_r  <= wr_data_i;
        R_N:     n_r     <= wr_data_i;
        R_XM:    xm_r    <= wr_data_i[AM_W-1:0];
        R_EXP:   exp_r   <= {8'd0, wr_data_i[23:0]};
        R_FLAGS: flags_r <= wr_data_i[1:0];
        default: ;
      endcase
    end

  // ---------------- descriptor check ----------------
  logic            rows_ok, n_ok, flags_ok, desc_ok, align_ok;
  logic [NBW-1:0]  nb1;      // 1 + ceil(N/8), from the low bits of N (used only if n_ok)
  logic [WB_W-1:0] wbytes;
  logic            y_en_r;

  assign y_en_r   = flags_r[1];
  assign rows_ok  = (rows_r != 32'd0) && (rows_r <= 32'((64'd1 << ROWS_W) - 1));
  assign n_ok     = (n_r != 32'd0) && (n_r <= 32'(NMAX));
  assign flags_ok = flags_r != 2'b00;
  assign nb1      = NBW'((({1'b0, n_r[NW-1:0]} + (NW + 1)'(7)) >> 3) + 1);
  assign wbytes   = WB_W'(rows_r[ROWS_W-1:0]) * WB_W'(nb1) * WB_W'(8);
  assign desc_ok  = rows_ok && n_ok && flags_ok &&
                    ({1'b0, waddr_r} + 33'(wbytes) <= 33'h1_0000_0000) &&
                    ({1'b0, xaddr_r} + 33'(n_r) <= 33'h1_0000_0000) &&
                    (!y_en_r || ({1'b0, yaddr_r} + {1'b0, rows_r[30:0], 2'b00} <= 33'h1_0000_0000));
  assign align_ok = (waddr_r[2:0] == 3'd0) && (xaddr_r[2:0] == 3'd0) &&
                    (!y_en_r || yaddr_r[2:0] == 3'd0);

  // ---------------- CTRL ----------------
  logic busy_q, done_q;
  logic ctrl_wr, start_req, idle, op_ok;
  logic [ERR_W-1:0] err_q, err_set;

  assign ctrl_wr   = wr_hit && (wr_w == R_CTRL);
  assign start_req = ctrl_wr && wr_data_i[0];
  assign idle      = !busy_q || done_i;
  assign op_ok     = wr_data_i[7:4] == 4'd1;
  assign start_o   = start_req && idle && op_ok && desc_ok && align_ok;
  assign busy_o    = busy_q;

  always_comb begin
    err_set               = '0;
    err_set[E_START_BUSY] = start_req && !idle;
    err_set[E_BAD_OP]     = start_req && !op_ok;
    err_set[E_BAD_DESC]   = start_req && idle && op_ok && !desc_ok;
    err_set[E_MISALIGN]   = start_req && idle && op_ok && !align_ok;
    err_set[E_RD_RESP]    = rd_err_i;
    err_set[E_WR_RESP]    = wr_err_i;
  end

  // latched descriptor
  always_ff @(posedge clk)
    if (start_o) begin
      op_w_addr_o <= waddr_r;
      op_x_addr_o <= xaddr_r;
      op_y_addr_o <= yaddr_r;
      op_rows_o   <= rows_r[ROWS_W-1:0];
      op_n_o      <= n_r[NW-1:0];
      op_xm_o     <= xm_r;
      op_we_o     <= exp_r[7:0];
      op_xe_o     <= exp_r[15:8];
      op_fo_o     <= exp_r[23:16];
      op_am_en_o  <= flags_r[0];
      op_y_en_o   <= flags_r[1];
      op_wbytes_o <= wbytes;
    end

  // ---------------- state, ERR, counters ----------------
  logic [31:0]        cyc_q, rdst_q, wrst_q, ops_q;
  logic [IDX_W-1:0]   amidx_q;
  logic signed [31:0] amval_q;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      busy_q  <= 1'b0;
      done_q  <= 1'b0;
      err_q   <= '0;
      cyc_q   <= '0;
      rdst_q  <= '0;
      wrst_q  <= '0;
      ops_q   <= '0;
      amidx_q <= '0;
      amval_q <= '0;
    end else begin
      if (start_o) busy_q <= 1'b1;
      else if (done_i) busy_q <= 1'b0;
      // done_sticky: a CTRL write while idle clears it (wins over done_i), except a start with
      // an illegal op
      if (ctrl_wr && idle && !(wr_data_i[0] && !op_ok)) done_q <= 1'b0;
      else if (done_i) done_q <= 1'b1;
      // ERR: W1C, set wins
      err_q <= (err_q & ~((wr_hit && wr_w == R_ERR) ? wr_data_i[ERR_W-1:0] : '0)) | err_set;
      if (start_o) begin
        cyc_q  <= '0;
        rdst_q <= '0;
        wrst_q <= '0;
      end else if (busy_q) begin
        cyc_q <= cyc_q + 32'd1;
        if (rd_stall_i) rdst_q <= rdst_q + 32'd1;
        if (wr_stall_i) wrst_q <= wrst_q + 32'd1;
      end
      if (done_i) ops_q <= ops_q + 32'd1;
      if (am_done_i) begin
        amidx_q <= am_idx_i;
        amval_q <= am_max_i;
      end
    end

  // ---------------- read mux (state before the write of the same cycle) ----------------
  always_comb begin
    rd_data_o = 32'd0;
    if (rd_hit)
      case (rd_w)
        R_ID:      rd_data_o = ID_VAL;
        R_CONFIG:  rd_data_o = CONFIG_VAL;
        R_STATUS:  rd_data_o = {29'd0, err_q != '0, done_q, busy_q};
        R_ERR:     rd_data_o = 32'(err_q);
        R_CYCLES:  rd_data_o = cyc_q;
        R_RDSTALL: rd_data_o = rdst_q;
        R_WRSTALL: rd_data_o = wrst_q;
        R_OPS:     rd_data_o = ops_q;
        R_WADDR:   rd_data_o = waddr_r;
        R_XADDR:   rd_data_o = xaddr_r;
        R_YADDR:   rd_data_o = yaddr_r;
        R_ROWS:    rd_data_o = rows_r;
        R_N:       rd_data_o = n_r;
        R_XM:      rd_data_o = 32'(xm_r);
        R_EXP:     rd_data_o = exp_r;
        R_FLAGS:   rd_data_o = {30'd0, flags_r};
        R_AMIDX:   rd_data_o = 32'(amidx_q);
        R_AMVAL:   rd_data_o = amval_q;
        default:   rd_data_o = 32'd0;
      endcase
  end

  logic unused_rd_en;
  assign unused_rd_en = rd_en_i;  // reads have no side effects

`ifndef SYNTHESIS
  always @(posedge clk)
    if (rst_n === 1'b1 && done_i === 1'b1 && busy_q !== 1'b1)
      $error("L3_DONE gemv_acc_csr %m: done_i while not busy");
`endif

endmodule
