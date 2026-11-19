// pim_bank: one PIM bank (arch.md 3.1-3.2, hierarchy.md 3.3): weight RAM + LB-lane MAC + row
// mantissa extraction + MAC_REG. Golden: one bank of model/src/bank.c bank_gemv (BANK_ROW) on
// the bank RAM image of bimg_pack: the int32 row sum k_dot8(W[r], x) and the row mantissa wm[r].
//
// Word (W_WORD = 8 LB + 16 bits, bimg_word_t): bits [8i+7:8i] = lane i (int8 weight of column
// 16 w + i of the row), bits [8 LB + 15 : 8 LB] = tag (the row mantissa wm in the first word of a
// row, 0 in the others; arch.md 3.1 D6: the parity bits of the BRAM).
//
//   write  : we_i writes wdata_i to waddr_i (LDW; never in the same cycle as a MAC read)
//   MAC    : re_i reads raddr_i (lock-step with the other banks); first_i / last_i mark the first /
//            last word of a row (a one-word row has both). x_i is the global buffer word of that
//            read and must arrive one cycle after re_i (the read latency of the RAM and of pim_gb).
//            Gaps (re_i low) are allowed anywhere; no backpressure.
//   result : res_valid_o = 1 for one cycle when MAC_REG is loaded with the row sum (res_acc_o) and
//            the row mantissa (res_wm_o, the tag of the row's first word). MAC_REG holds them until
//            the next row ends: the second buffer of the "double buffer" (the first is the
//            accumulator inside mac_row, which starts the next row right away).
// LATENCY = 3 + DOT_PIPE: re_i of the last word of a row in cycle t -> res_valid_o in t + LATENCY
// (RAM read 1, mac_row DOT_PIPE + 1, MAC_REG 1).
// Accumulator width ACC_W = 15 + clog2(NMAX) (25 for N_MAX 1024; hierarchy.md 3.3, mac_row rule).
module pim_bank
  import llm_pkg::*;
#(
  parameter int LB       = 16,
  parameter int DEPTH    = 4096,
  parameter int NMAX     = N_MAX,
  parameter int DOT_PIPE = 2,
  localparam int AA      = $clog2(DEPTH),
  localparam int ACC_W   = 15 + $clog2(NMAX),
  localparam int W_WORD  = 8 * LB + WM_W
) (
  input  logic                    clk,
  input  logic                    rst_n,
  // weight write (LDW)
  input  logic                    we_i,
  input  logic [AA-1:0]           waddr_i,
  input  logic [W_WORD-1:0]       wdata_i,
  // lock-step MAC read
  input  logic                    re_i,
  input  logic [AA-1:0]           raddr_i,
  input  logic                    first_i,
  input  logic                    last_i,
  input  logic [8*LB-1:0]         x_i,
  // MAC_REG
  output logic                    res_valid_o,
  output logic signed [ACC_W-1:0] res_acc_o,
  output logic [WM_W-1:0]         res_wm_o
);
  localparam int LAT_M   = DOT_PIPE + 1;
  localparam int LATENCY = 2 + LAT_M;

  if (LB < 2 || (LB & (LB - 1)) != 0) $error("pim_bank: LB=%0d must be a power of two >= 2", LB);
  if (DEPTH < 2) $error("pim_bank: DEPTH=%0d must be >= 2", DEPTH);
  if (NMAX < LB) $error("pim_bank: NMAX=%0d must be >= LB=%0d", NMAX, LB);

  // ---- weight RAM ----
  logic [W_WORD-1:0] rdata;
  ram_sdp #(.W(W_WORD), .DEPTH(DEPTH), .RD_LAT(1)) u_ram (
    .clk(clk), .rst_n(rst_n),
    .we_i(we_i), .waddr_i(waddr_i), .wdata_i(wdata_i),
    .re_i(re_i), .raddr_i(raddr_i), .rdata_o(rdata));

  // control aligned with the RAM output
  logic v1_q, first1_q, last1_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      v1_q     <= 1'b0;
      first1_q <= 1'b0;
      last1_q  <= 1'b0;
    end else begin
      v1_q     <= re_i;
      first1_q <= re_i && first_i;
      last1_q  <= re_i && last_i;
    end

  // ---- row mantissa: tag of the first word, held over the row ----
  logic [WM_W-1:0] wm_beat, wm_hold_q;
  assign wm_beat = first1_q ? rdata[W_WORD-1 -: WM_W] : wm_hold_q;
  always_ff @(posedge clk)
    if (v1_q) wm_hold_q <= wm_beat;

  // ---- row sum ----
  logic                    acc_valid;
  logic signed [ACC_W-1:0] acc;
  mac_row #(.LANES(LB), .AW(8), .BW(8), .ACC_W(ACC_W), .N_MAX(NMAX), .DOT_PIPE(DOT_PIPE)) u_mac (
    .clk(clk), .rst_n(rst_n), .valid_i(v1_q), .first_i(first1_q), .last_i(last1_q),
    .a_i(rdata[8*LB-1:0]), .b_i(x_i), .acc_o(acc), .acc_valid_o(acc_valid));

  // wm delayed by mac_row.LATENCY (shifts every cycle; rows are >= 1 word apart, so the tap holds
  // the mantissa of the row whose sum leaves mac_row)
  logic [WM_W-1:0] wm_dl [LAT_M];
  always_ff @(posedge clk) begin
    wm_dl[0] <= wm_beat;
    for (int i = 1; i < LAT_M; i++) wm_dl[i] <= wm_dl[i-1];
  end

  // ---- MAC_REG ----
  logic                    res_v_q;
  logic signed [ACC_W-1:0] res_acc_q;
  logic [WM_W-1:0]         res_wm_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) res_v_q <= 1'b0;
    else        res_v_q <= acc_valid;
  always_ff @(posedge clk)
    if (acc_valid) begin
      res_acc_q <= acc;
      res_wm_q  <= wm_dl[LAT_M-1];
    end

  assign res_valid_o = res_v_q;
  assign res_acc_o   = res_acc_q;
  assign res_wm_o    = res_wm_q;

endmodule
