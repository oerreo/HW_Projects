// gemv_core: one GEMV slice of the accelerator IP (arch.md 2.3, hierarchy.md 3.4).
// y[r] = sat32(rshr(dot8(W[r], x) * wm[r] * xm, we + xe - fo)) for r = 0..rows-1
// (golden: model/src/kern.c k_gemv with gs = n, records K_GEMV).
//
// Interface (64-bit beats, byte i of a beat = bits [8i+7:8i], little-endian like the DDR
// buffers):
//   start_i  : 1-cycle pulse in IDLE; latches rows_i, n_i, we_i, xe_i, fo_i, xm_i
//              (1 <= n <= N_MAX, rows >= 1; checked in simulation, L2_RANGE)
//   x stream : ceil(n/8) beats of int8 x. Lanes >= n of the last beat are ignored
//              (masked to 0 when written to the x buffer)
//   w stream : rows row records (arch.md 2.2): header beat (wm = bits [15:0], the rest
//              ignored) then ceil(n/8) weight beats (padding lanes must be 0, rrec_pack)
//   y stream : rows int32 values in row order
//   done_o   : 1-cycle pulse after the last y was accepted; busy_o from start to done
// The x stream is accepted only in phase LOADX (after start), the w stream only in RUN
// (after the last x beat). Both may present data earlier (valid without ready).
//
// Datapath: x buffer (ram_sdp, 64 x N_MAX/8, read latency 1) -> mac_row (LANES 8,
// ACC_W 25) -> gemv_scale -> y FIFO (sync_fifo, Y_DEPTH). One w beat per cycle. The
// pipeline has no backpressure: a row header is accepted only while fewer than Y_DEPTH
// rows are between header acceptance and y acceptance (credit), so the FIFO never
// overflows when y_ready_i is low.
//
// Cycle count with every input beat available and y_ready_i high (start_i asserted in
// cycle 0, done_o in cycle C):
//   C = ceil(n/8) + rows * (1 + ceil(n/8)) + L_PIPE
//   L_PIPE = 3 + mac_row.LATENCY + gemv_scale.LATENCY = 4 + DOT_PIPE + SCALE_PIPE
//   (1 x buffer read stage, 1 FIFO write, 1 registered done)
// Y_DEPTH must cover the rows in flight for that rate: rows are >= 2 beats, so
// Y_DEPTH >= (L_PIPE + 3) / 2 + 1 is checked at elaboration.
module gemv_core
  import llm_pkg::*;
#(
  parameter int LANES      = 8,
  parameter int NMAX       = N_MAX,
  parameter int ROWS_W     = 16,
  parameter int DOT_PIPE   = 2,
  parameter int SCALE_PIPE = 3,
  parameter int Y_DEPTH    = 16
) (
  input  logic                         clk,
  input  logic                         rst_n,
  // control
  input  logic                         start_i,
  input  logic [ROWS_W-1:0]            rows_i,
  input  logic [$clog2(NMAX+1)-1:0]    n_i,
  input  logic signed [E_W-1:0]        we_i,
  input  logic signed [E_W-1:0]        xe_i,
  input  logic signed [E_W-1:0]        fo_i,
  input  logic [AM_W-1:0]              xm_i,
  output logic                         busy_o,
  output logic                         done_o,
  // x stream
  input  logic                         x_valid_i,
  output logic                         x_ready_o,
  input  logic [63:0]                  x_data_i,
  // row record stream
  input  logic                         w_valid_i,
  output logic                         w_ready_o,
  input  logic [63:0]                  w_data_i,
  // y stream
  output logic                         y_valid_o,
  input  logic                         y_ready_i,
  output logic [31:0]                  y_data_o
);
  localparam int NW      = $clog2(NMAX + 1);
  localparam int XD      = NMAX / 8;               // x buffer words
  localparam int XA      = (XD > 1) ? $clog2(XD) : 1;
  localparam int BW_     = $clog2(XD + 1);          // beat index 0..ceil(n/8)
  localparam int ACC_W   = 15 + $clog2(NMAX);      // 25 for N_MAX 1024 (hierarchy.md 3.3)
  localparam int LAT_M   = DOT_PIPE + 1;
  localparam int LAT_S   = SCALE_PIPE;
  localparam int L_PIPE  = 3 + LAT_M + LAT_S;
  localparam int CW      = $clog2(Y_DEPTH + 1);

  if (LANES != 8) $error("gemv_core: LANES=%0d must be 8 (one 64-bit beat = 8 int8 lanes, arch.md 2.3)", LANES);
  if (NMAX < 8 || NMAX % 8 != 0 || ACC_W > 29)
    $error("gemv_core: NMAX=%0d must be a multiple of 8 in 8..16384", NMAX);
  if (ROWS_W < 1 || ROWS_W > 24) $error("gemv_core: ROWS_W=%0d must be 1..24", ROWS_W);
  if (Y_DEPTH < (L_PIPE + 3) / 2 + 1)
    $error("gemv_core: Y_DEPTH=%0d must be >= %0d for L_PIPE=%0d", Y_DEPTH, (L_PIPE + 3) / 2 + 1, L_PIPE);

  typedef enum logic [1:0] {S_IDLE, S_LOADX, S_RUN, S_WAIT} state_t;
  state_t state_q;

  // ---- configuration registers (datapath, loaded at start) ----
  logic [ROWS_W-1:0]      rows_q;
  logic [BW_-1:0]         nb_q;       // ceil(n/8)
  logic [7:0]             lmask_q;    // lanes kept in the last x beat
  logic signed [SH_W-1:0] sh_q;
  logic [AM_W-1:0]        xm_q;

  // ---- control counters ----
  logic [BW_-1:0]    xcnt_q;      // x beats accepted
  logic [BW_-1:0]    bidx_q;      // beat index within the row record (0 = header)
  logic [ROWS_W-1:0] rcnt_q;      // row records completed (last weight beat accepted)
  logic [ROWS_W-1:0] ycnt_q;      // y accepted
  logic [CW-1:0]     cred_q;      // rows between header acceptance and y acceptance
  logic              done_q;

  logic x_hs, w_hs, hdr_hs, wbeat_hs, y_hs, last_beat, last_row;

  assign x_ready_o = (state_q == S_LOADX);
  assign w_ready_o = (state_q == S_RUN) && (bidx_q != '0 || cred_q < CW'(Y_DEPTH));
  assign x_hs      = x_valid_i && x_ready_o;
  assign w_hs      = w_valid_i && w_ready_o;
  assign hdr_hs    = w_hs && (bidx_q == '0);
  assign wbeat_hs  = w_hs && (bidx_q != '0);
  assign last_beat = (bidx_q == nb_q);
  assign last_row  = (rcnt_q == rows_q - 1'b1);
  assign busy_o    = (state_q != S_IDLE);
  assign done_o    = done_q;

  always_ff @(posedge clk)
    if (start_i && state_q == S_IDLE) begin
      rows_q  <= rows_i;
      nb_q    <= BW_'((n_i + 7) >> 3);
      lmask_q <= (n_i[2:0] == 3'd0) ? 8'hFF : 8'((9'd1 << n_i[2:0]) - 1'b1);
      sh_q    <= SH_W'(we_i) + SH_W'(xe_i) - SH_W'(fo_i);
      xm_q    <= xm_i;
    end

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      state_q <= S_IDLE;
      xcnt_q  <= '0;
      bidx_q  <= '0;
      rcnt_q  <= '0;
      ycnt_q  <= '0;
      cred_q  <= '0;
      done_q  <= 1'b0;
    end else begin
      done_q <= 1'b0;
      cred_q <= cred_q + CW'(hdr_hs) - CW'(y_hs);
      if (y_hs) ycnt_q <= ycnt_q + 1'b1;
      unique case (state_q)
        S_IDLE:
          if (start_i) begin
            state_q <= S_LOADX;
            xcnt_q  <= '0;
            bidx_q  <= '0;
            rcnt_q  <= '0;
            ycnt_q  <= '0;
          end
        S_LOADX:
          if (x_hs) begin
            xcnt_q <= xcnt_q + 1'b1;
            if (xcnt_q == nb_q - 1'b1) state_q <= S_RUN;
          end
        S_RUN:
          if (w_hs) begin
            if (last_beat) begin
              bidx_q <= '0;
              rcnt_q <= rcnt_q + 1'b1;
              if (last_row) state_q <= S_WAIT;
            end else bidx_q <= bidx_q + 1'b1;
          end
        S_WAIT:
          if (y_hs && ycnt_q == rows_q - 1'b1) begin
            state_q <= S_IDLE;
            done_q  <= 1'b1;
          end
        default: state_q <= S_IDLE;
      endcase
    end

  // ---- x buffer ----
  logic [63:0] x_wdata, x_rdata;
  always_comb
    for (int l = 0; l < 8; l++)
      x_wdata[l*8 +: 8] = (xcnt_q == nb_q - 1'b1 && !lmask_q[l]) ? 8'h00 : x_data_i[l*8 +: 8];

  ram_sdp #(.W(64), .DEPTH(XD), .RD_LAT(1)) u_xbuf (
    .clk(clk), .rst_n(rst_n),
    .we_i(x_hs), .waddr_i(XA'(xcnt_q)), .wdata_i(x_wdata),
    .re_i(wbeat_hs), .raddr_i(XA'(bidx_q - 1'b1)), .rdata_o(x_rdata));

  // ---- weight beat stage (aligned with the x buffer read) ----
  logic            ws_valid_q;
  logic            ws_first_q, ws_last_q;
  logic [63:0]     ws_data_q;
  logic [WM_W-1:0] wm_q, ws_wm_q;

  always_ff @(posedge clk)
    if (hdr_hs) wm_q <= w_data_i[WM_W-1:0];

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) ws_valid_q <= 1'b0;
    else        ws_valid_q <= wbeat_hs;

  always_ff @(posedge clk)
    if (wbeat_hs) begin
      ws_data_q  <= w_data_i;
      ws_first_q <= (bidx_q == BW_'(1));
      ws_last_q  <= last_beat;
      ws_wm_q    <= wm_q;
    end

  // ---- row sums ----
  logic                    acc_valid;
  logic signed [ACC_W-1:0] acc;

  mac_row #(.LANES(8), .AW(8), .BW(8), .ACC_W(ACC_W), .N_MAX(NMAX), .DOT_PIPE(DOT_PIPE)) u_mac (
    .clk(clk), .rst_n(rst_n), .valid_i(ws_valid_q), .first_i(ws_first_q), .last_i(ws_last_q),
    .a_i(ws_data_q), .b_i(x_rdata), .acc_o(acc), .acc_valid_o(acc_valid));

  // wm of the row, delayed by mac_row.LATENCY (shifts every cycle; rows are >= 1 weight
  // beat apart, so the value at the tap is the one of the row whose sum leaves mac_row)
  logic [WM_W-1:0] wm_dl [LAT_M];
  always_ff @(posedge clk) begin
    wm_dl[0] <= ws_wm_q;
    for (int i = 1; i < LAT_M; i++) wm_dl[i] <= wm_dl[i-1];
  end

  // ---- scale ----
  logic               sv;
  logic signed [31:0] sy;

  gemv_scale #(.ACC_W(ACC_W), .PIPE(SCALE_PIPE)) u_scale (
    .clk(clk), .rst_n(rst_n), .valid_i(acc_valid), .acc_i(acc), .wm_i(wm_dl[LAT_M-1]),
    .xm_i(xm_q), .sh_i(sh_q), .valid_o(sv), .y_o(sy));

  // ---- y FIFO ----
  logic fifo_in_ready;
  sync_fifo #(.W(32), .DEPTH(Y_DEPTH)) u_yfifo (
    .clk(clk), .rst_n(rst_n), .in_valid_i(sv), .in_ready_o(fifo_in_ready), .in_data_i(sy),
    .out_valid_o(y_valid_o), .out_ready_i(y_ready_i), .out_data_o(y_data_o), .level_o());

  assign y_hs = y_valid_o && y_ready_i;

`ifndef SYNTHESIS
  // L2_RANGE: configuration outside the supported range; L2_START: start while busy;
  // L2_OVF: y FIFO full when a result arrives (credit logic error)
  always @(posedge clk)
    if (rst_n === 1'b1) begin
      if (start_i === 1'b1 && state_q == S_IDLE &&
          (n_i == '0 || int'(n_i) > NMAX || rows_i == '0))
        $error("L2_RANGE gemv_core %m: n=%0d (1..%0d) rows=%0d (>= 1)", n_i, NMAX, rows_i);
      if (start_i === 1'b1 && state_q != S_IDLE)
        $error("L2_START gemv_core %m: start_i while busy (ignored)");
      if (sv === 1'b1 && fifo_in_ready !== 1'b1)
        $error("L2_OVF gemv_core %m: y FIFO full");
    end
`endif

endmodule
