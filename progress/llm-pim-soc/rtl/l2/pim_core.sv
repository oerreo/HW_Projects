// pim_core: GEMV PIM core (arch.md 3, hierarchy.md 3.4; command format and cycle formula
// docs/spec/pim.md). NB banks of LB lanes (BANK_ROW), the global buffer, the command controller,
// the gather and one shared scaler. Golden: model/src/bank.c bank_gemv (BANK_ROW, nb = NB) =
// k_gemv (K_GEMV records), bank RAM image bimg_pack, command counts bank_stat_t.
//
// Interfaces (no AXI; the L3 top connects the engines):
//   cmd      : one command per handshake (pim_ctrl: LDW, WRGB, MACAB; fields already checked)
//   rd_cmd   : (addr, bytes) for the read engine (LDW row records, WRGB x)
//   d stream : 64-bit read beats; routed to pim_gb during WRGB, to pim_ctrl during LDW
//   wr_cmd   : (addr, 4 rows bytes) for the write engine (MACAB y)
//   y stream : int32 y in row order, y_last_o on the last row of a MACAB (valid/ready)
//   busy_o   : something of the core is in flight (!pim_ctrl idle_o)
//   rd_stall_o: the core is ready for a read beat and has none (CSR RD_STALL)
//   events   : pim_ctrl event pulses (CSR counters)
//
// Structure (instances, wiring, the read-stream router and the gather mux):
//   pim_ctrl -> pim_bank x NB (write port: LDW words, read port: lock-step MAC address)
//   pim_gb (WRGB load, read word broadcast to every bank one cycle after the MAC read)
//   gather mux: MAC_REG of bank g_sel -> gemv_scale (xm, sh of the round) -> y FIFO (sync_fifo,
//   Y_DEPTH x 33: y and the last flag). pim_ctrl reserves FIFO space per round, so the scaler
//   output never meets a full FIFO (simulation check PIM_YOVF).
// MACAB cycle count with every y taken at once (cmd handshake in cycle 0, the last y of the
// command valid at y_valid_o in cycle C): docs/spec/pim.md.
module pim_core
  import llm_pkg::*;
#(
  parameter int NB         = 4,
  parameter int LB         = 16,
  parameter int DEPTH      = 4096,
  parameter int NMAX       = N_MAX,
  parameter int DOT_PIPE   = 2,
  parameter int SCALE_PIPE = 3,
  parameter int Y_DEPTH    = 32,
  parameter int ROWS_W     = 16,
  localparam int AA        = $clog2(DEPTH),
  localparam int NW        = $clog2(NMAX + 1)
) (
  input  logic                   clk,
  input  logic                   rst_n,
  // command
  input  logic                   cmd_valid_i,
  output logic                   cmd_ready_o,
  input  logic [3:0]             cmd_op_i,
  input  logic [ROWS_W-1:0]      cmd_rows_i,
  input  logic [NW-1:0]          cmd_n_i,
  input  logic [AA-1:0]          cmd_base_i,
  input  logic [31:0]            cmd_addr_i,
  input  logic [AM_W-1:0]        cmd_xm_i,
  input  logic signed [E_W-1:0]  cmd_we_i,
  input  logic signed [E_W-1:0]  cmd_xe_i,
  input  logic signed [E_W-1:0]  cmd_fo_i,
  // read command and data
  output logic                   rd_cmd_valid_o,
  input  logic                   rd_cmd_ready_i,
  output logic [31:0]            rd_cmd_addr_o,
  output logic [31:0]            rd_cmd_bytes_o,
  input  logic                   d_valid_i,
  output logic                   d_ready_o,
  input  logic [63:0]            d_data_i,
  // write command and y
  output logic                   wr_cmd_valid_o,
  input  logic                   wr_cmd_ready_i,
  output logic [31:0]            wr_cmd_addr_o,
  output logic [31:0]            wr_cmd_bytes_o,
  output logic                   y_valid_o,
  input  logic                   y_ready_i,
  output logic [31:0]            y_data_o,
  output logic                   y_last_o,
  // status and events
  output logic                   busy_o,
  output logic                   rd_stall_o,
  output logic                   ev_mac_o,
  output logic                   ev_wrgb_o,
  output logic                   ev_rdmac_o,
  output logic                   done_ldw_o,
  output logic                   done_wrgb_o,
  output logic                   done_mac_o
);
  localparam int GA     = $clog2(NMAX / LB);
  localparam int BI_W   = (NB > 1) ? $clog2(NB) : 1;
  localparam int W_WORD = 8 * LB + WM_W;
  localparam int ACC_W  = 15 + $clog2(NMAX);
  localparam int L_BANK = 3 + DOT_PIPE;             // pim_bank LATENCY

  // ---------------- controller ----------------
  logic                   gb_sel, gb_load, gb_beat, gb_done, gb_rd_en, gb_ready, ld_ready;
  logic [NW-1:0]          gb_n;
  logic [GA-1:0]          gb_rd_addr;
  logic [NB-1:0]          bw_en, mr_en;
  logic [AA-1:0]          bw_addr, mr_addr;
  logic [W_WORD-1:0]      bw_data;
  logic                   mr_first, mr_last;
  logic                   g_valid, g_last, y_pop, idle;
  logic [BI_W-1:0]        g_sel;
  logic [AM_W-1:0]        g_xm;
  logic signed [SH_W-1:0] g_sh;

  pim_ctrl #(.NB(NB), .LB(LB), .DEPTH(DEPTH), .NMAX(NMAX), .Y_DEPTH(Y_DEPTH), .L_BANK(L_BANK),
             .ROWS_W(ROWS_W)) u_ctrl (
    .clk, .rst_n,
    .cmd_valid_i, .cmd_ready_o, .cmd_op_i, .cmd_rows_i, .cmd_n_i, .cmd_base_i, .cmd_addr_i,
    .cmd_xm_i, .cmd_we_i, .cmd_xe_i, .cmd_fo_i,
    .rd_cmd_valid_o, .rd_cmd_ready_i, .rd_cmd_addr_o, .rd_cmd_bytes_o,
    .wr_cmd_valid_o, .wr_cmd_ready_i, .wr_cmd_addr_o, .wr_cmd_bytes_o,
    .ld_valid_i(d_valid_i && !gb_sel), .ld_ready_o(ld_ready), .ld_data_i(d_data_i),
    .gb_sel_o(gb_sel), .gb_load_o(gb_load), .gb_n_o(gb_n), .gb_beat_i(gb_beat),
    .gb_done_i(gb_done), .gb_rd_en_o(gb_rd_en), .gb_rd_addr_o(gb_rd_addr),
    .bw_en_o(bw_en), .bw_addr_o(bw_addr), .bw_data_o(bw_data),
    .mr_en_o(mr_en), .mr_addr_o(mr_addr), .mr_first_o(mr_first), .mr_last_o(mr_last),
    .g_valid_o(g_valid), .g_sel_o(g_sel), .g_last_o(g_last), .g_xm_o(g_xm), .g_sh_o(g_sh),
    .y_pop_i(y_pop),
    .busy_o(), .idle_o(idle), .ev_mac_o, .ev_wrgb_o, .ev_rdmac_o, .done_ldw_o, .done_wrgb_o,
    .done_mac_o);

  // read stream router
  assign d_ready_o  = gb_sel ? gb_ready : ld_ready;
  assign gb_beat    = d_valid_i && gb_sel && gb_ready;
  assign rd_stall_o = d_ready_o && !d_valid_i;
  assign busy_o     = !idle;

  // ---------------- global buffer ----------------
  logic [8*LB-1:0] xw;
  pim_gb #(.NMAX(NMAX), .LB(LB)) u_gb (
    .clk, .rst_n,
    .load_i(gb_load), .n_i(gb_n), .busy_o(), .done_o(gb_done),
    .wr_valid_i(d_valid_i && gb_sel), .wr_ready_o(gb_ready), .wr_data_i(d_data_i),
    .rd_en_i(gb_rd_en), .rd_addr_i(gb_rd_addr), .rd_word_o(xw));

  // ---------------- banks ----------------
  logic signed [ACC_W-1:0] r_acc [NB];
  logic [WM_W-1:0]         r_wm  [NB];

  for (genvar b = 0; b < NB; b++) begin : g_bank
    pim_bank #(.LB(LB), .DEPTH(DEPTH), .NMAX(NMAX), .DOT_PIPE(DOT_PIPE)) u_bank (
      .clk, .rst_n,
      .we_i(bw_en[b]), .waddr_i(bw_addr), .wdata_i(bw_data),
      .re_i(mr_en[b]), .raddr_i(mr_addr), .first_i(mr_first), .last_i(mr_last), .x_i(xw),
      .res_valid_o(), .res_acc_o(r_acc[b]), .res_wm_o(r_wm[b]));
  end

  // ---------------- gather and scale ----------------
  logic               sv;
  logic signed [31:0] sy;
  logic               s_last;     // g_last aligned with the scaler output

  gemv_scale #(.ACC_W(ACC_W), .PIPE(SCALE_PIPE)) u_scale (
    .clk, .rst_n, .valid_i(g_valid), .acc_i(r_acc[g_sel]), .wm_i(r_wm[g_sel]), .xm_i(g_xm),
    .sh_i(g_sh), .valid_o(sv), .y_o(sy));

  if (SCALE_PIPE > 0) begin : g_ldl
    logic [SCALE_PIPE-1:0] ldl_q;
    always_ff @(posedge clk or negedge rst_n)
      if (!rst_n) ldl_q <= '0;
      else        ldl_q <= SCALE_PIPE'({ldl_q, g_last});
    assign s_last = ldl_q[SCALE_PIPE-1];
  end else begin : g_ldl0
    assign s_last = g_last;
  end

  // ---------------- y FIFO ----------------
  logic fifo_in_ready;
  sync_fifo #(.W(33), .DEPTH(Y_DEPTH)) u_yfifo (
    .clk, .rst_n, .in_valid_i(sv), .in_ready_o(fifo_in_ready), .in_data_i({s_last, sy}),
    .out_valid_o(y_valid_o), .out_ready_i(y_ready_i), .out_data_o({y_last_o, y_data_o}), .level_o());

  assign y_pop = y_valid_o && y_ready_i;

`ifndef SYNTHESIS
  always @(posedge clk)
    if (rst_n === 1'b1 && sv === 1'b1 && fifo_in_ready !== 1'b1)
      $error("PIM_YOVF pim_core %m: y FIFO full when a result arrives");
`endif

endmodule
