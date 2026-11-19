// pim_gb: global buffer of the PIM IP (arch.md 3.2, hierarchy.md 3.3): one activation vector x
// (int8 [n]) broadcast to all banks as LB-lane words. Golden: the gbuf of model/src/bank.c
// bank_gemv (x copied into the global buffer, read by every bank).
//
//   load_i   : 1-cycle pulse, starts a load of n_i elements (1 <= n_i <= NMAX). The buffer is
//              logically cleared: every word reads 0 until its beats are written again.
//   wr stream: ceil(n/8) 64-bit beats (byte i of a beat = element 8 j + i of beat j), accepted
//              only while busy_o (wr_ready_o = busy_o, no other backpressure). Lanes >= n of the
//              last beat are written as 0. done_o = 1 in the cycle of the last beat handshake.
//   read     : rd_en_i / rd_addr_i (word w = elements 16 w .. 16 w + 15); rd_word_o shows the
//              word one cycle later (read latency 1) and holds it until the next read. Lane i of
//              the word = bits [8i+7:8i]. Half-words (8 elements) not written since the last
//              load read as 0, so x is 0 beyond n ("rest 0", arch.md 3.3 WRGB).
// Storage: two ram_sdp (64 bits x NMAX/16, low and high half of a word) and a beat counter; a
// half-word is valid if its beat index is below the counter.
//
// Simulation-only checks: PIM_RANGE (n_i out of range at load_i), PIM_GB_LOAD (load_i while a
// load is in progress; the new load restarts).
module pim_gb
  import llm_pkg::*;
#(
  parameter int NMAX = N_MAX,   // multiple of 16, >= 32
  parameter int LB   = 16       // lanes per word (two 64-bit beats)
) (
  input  logic                          clk,
  input  logic                          rst_n,
  // load
  input  logic                          load_i,
  input  logic [$clog2(NMAX+1)-1:0]     n_i,
  output logic                          busy_o,
  output logic                          done_o,
  // write stream (64-bit beats)
  input  logic                          wr_valid_i,
  output logic                          wr_ready_o,
  input  logic [63:0]                   wr_data_i,
  // broadcast read
  input  logic                          rd_en_i,
  input  logic [$clog2(NMAX/16)-1:0]    rd_addr_i,
  output logic [8*LB-1:0]               rd_word_o
);
  localparam int NW   = $clog2(NMAX + 1);
  localparam int NWD  = NMAX / 16;                 // words
  localparam int GA   = $clog2(NWD);
  localparam int NBT  = NMAX / 8;                  // beats
  localparam int BC_W = $clog2(NBT + 1);
  localparam int LATENCY = 1;

  if (LB != 16) $error("pim_gb: LB=%0d must be 16 (one word = two 64-bit beats)", LB);
  if (NMAX < 32 || NMAX % 16 != 0) $error("pim_gb: NMAX=%0d must be a multiple of 16, >= 32", NMAX);

  logic            busy_q;
  logic [BC_W-1:0] cnt_q, nb_q;     // beats written, beats of the load
  logic [7:0]      lmask_q;         // lanes kept in the last beat
  logic            hs, last;

  assign wr_ready_o = busy_q;
  assign busy_o     = busy_q;
  assign hs         = wr_valid_i && busy_q;
  assign last       = cnt_q == nb_q - 1'b1;
  assign done_o     = hs && last;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      busy_q <= 1'b0;
      cnt_q  <= '0;
    end else if (load_i) begin
      busy_q <= 1'b1;
      cnt_q  <= '0;
    end else if (hs) begin
      cnt_q <= cnt_q + 1'b1;
      if (last) busy_q <= 1'b0;
    end

  always_ff @(posedge clk)
    if (load_i) begin
      nb_q    <= BC_W'((n_i + 7) >> 3);
      lmask_q <= (n_i[2:0] == 3'd0) ? 8'hFF : 8'((9'd1 << n_i[2:0]) - 1'b1);
    end

  // ---- storage ----
  logic [63:0] wdata, rd_lo, rd_hi;
  always_comb
    for (int l = 0; l < 8; l++)
      wdata[l*8 +: 8] = (last && !lmask_q[l]) ? 8'h00 : wr_data_i[l*8 +: 8];

  ram_sdp #(.W(64), .DEPTH(NWD), .RD_LAT(1)) u_lo (
    .clk(clk), .rst_n(rst_n),
    .we_i(hs && !cnt_q[0]), .waddr_i(GA'(cnt_q >> 1)), .wdata_i(wdata),
    .re_i(rd_en_i), .raddr_i(rd_addr_i), .rdata_o(rd_lo));
  ram_sdp #(.W(64), .DEPTH(NWD), .RD_LAT(1)) u_hi (
    .clk(clk), .rst_n(rst_n),
    .we_i(hs && cnt_q[0]), .waddr_i(GA'(cnt_q >> 1)), .wdata_i(wdata),
    .re_i(rd_en_i), .raddr_i(rd_addr_i), .rdata_o(rd_hi));

  // half-word valid flags, registered with the read (beat 2w and 2w + 1 written)
  logic vlo_q, vhi_q;
  always_ff @(posedge clk)
    if (rd_en_i) begin
      vlo_q <= (BC_W + 1)'({rd_addr_i, 1'b0}) < (BC_W + 1)'(cnt_q);
      vhi_q <= (BC_W + 1)'({rd_addr_i, 1'b1}) < (BC_W + 1)'(cnt_q);
    end

  assign rd_word_o = {vhi_q ? rd_hi : 64'd0, vlo_q ? rd_lo : 64'd0};

`ifndef SYNTHESIS
  always @(posedge clk)
    if (rst_n === 1'b1 && load_i === 1'b1) begin
      if (n_i == '0 || int'(n_i) > NMAX) $error("PIM_RANGE pim_gb %m: n=%0d (1..%0d)", n_i, NMAX);
      if (busy_q) $error("PIM_GB_LOAD pim_gb %m: load_i while a load is in progress");
    end
`endif

endmodule
