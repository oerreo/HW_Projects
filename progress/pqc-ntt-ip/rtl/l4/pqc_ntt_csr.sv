// pqc_ntt_csr: register file of pqc_ntt_axi_top (L4).
//
// Spec: docs/spec/l4_axi.md ("register map", "decided behaviour"). The
// software view of the same map is fpga/sw/pqc_ntt_regs.h.
//
// Input: the register access interface of axil_slave (one write strobe and
// one read strobe per cycle, both from flip-flops). Output: the ntt_core
// command and stream handshakes. Every register action happens in the cycle
// of the strobe; a read and a write in the same cycle are independent, the
// read returns the state before the write of that cycle.
//
//   offset reg      access  cycle of wr_en / rd_en
//   0x00   CTRL     W       start_o = 1 in the same cycle if start = 1, op is
//                           legal and busy_i = 0 (the core accepts it in this
//                           cycle). done_sticky cleared (see below).
//   0x04   STATUS   R       {out_valid, in_ready, result_bank, done_sticky, busy}
//   0x08   DIN      W       s_valid_o = 1 in the same cycle only if s_ready_i
//                           = 1 (one write = one handshake), else dropped
//   0x0C   DOUT     R       m_ready_o = 1 in the same cycle only if m_valid_i
//                           = 1 (one read = one pop), data m_data_i; else 0
//   0x10   CYCLES   R       last op, core start acceptance to done_o
//   0x14   VERSION  R       {ID, BFU_LATENCY, ALGO} (constant)
//   0x18   ERR      R/W1C   sticky error bits, see below
//   0x1C   CONFIG   R       build parameters (constant)
//   other           -       read 0, write ignored (CTRL / DIN read 0)
//
// done_sticky: set by done_i, cleared by every CTRL write except a start with
// an illegal op (l4_axi.md: an illegal op changes neither busy nor
// done_sticky). A clear wins over a set in the same cycle; a start written in
// the done_i cycle is accepted because busy_i = 0 in that cycle.
// ERR bits (set wins over a W1C clear of the same bit in the same cycle, so
// that no error event is lost):
//   0 start_busy    CTRL write with start = 1 while busy_i = 1 (start ignored)
//   1 din_notready  DIN write while s_ready_i = 0 (word dropped)
//   2 dout_notvalid DOUT read while m_valid_i = 0 (returns 0, no pop)
//   3 bad_op        CTRL write with start = 1 and op not in op_e (ignored)
//   4 din_range     accepted DIN word with bits [11:0] >= Q; the word enters
//                   the core unchanged. A dropped DIN write sets only bit 1.
//   A start with an illegal op while busy sets bits 0 and 3.
// CYCLES: counter cnt_q is set to 1 in the cycle after the core accepts a
// start and counts every cycle while busy_i = 1; CYCLES takes cnt_q in the
// done_i cycle. With acceptance in cycle t0 and done_o in cycle td (busy_i =
// 1 in t0+1 .. td-1, ntt_ctrl contract) CYCLES = td - t0, the definition of
// arch.md "L2 results" (the TB checks it against that formula). cnt_q
// saturates at 2^32 - 1 (a LOAD / UNLOAD can wait for the PS indefinitely).
//
// Reset: done_sticky, ERR, the counter and CYCLES (control registers) are
// reset to 0. STATUS bits come from the core (reset there).
module pqc_ntt_csr
  import mlkem_pkg::*;
  import ntt_l2_pkg::*;
#(
  parameter int ADDR_W       = 12,   // byte address width of the register access
  parameter int ALGO         = 0,    // VERSION[7:0]
  parameter int PRE_REG      = 0,    // CONFIG and VERSION.BFU_LATENCY
  parameter int MUL_REG      = 0,
  parameter int RED_PIPE     = 0,
  parameter int OUT_REG      = 0,
  parameter int SHARE_ADDSUB = 0,
  parameter int ROM_OUT_REG  = 1,
  parameter int IMPL         = 0,    // CONFIG[0]: 0 hand RTL, 1 HLS
  parameter int FCLK_MHZ     = 100   // CONFIG[23:16]
) (
  input  logic              clk,
  input  logic              rst_n,         // async assert, sync deassert
  // register access (axil_slave)
  input  logic              wr_en_i,
  input  logic [ADDR_W-1:0] wr_addr_i,
  input  logic [31:0]       wr_data_i,
  input  logic              rd_en_i,
  input  logic [ADDR_W-1:0] rd_addr_i,
  output logic [31:0]       rd_data_o,     // valid in the rd_en_i cycle
  // ntt_core command / status
  output logic              start_o,
  output op_e               op_o,
  output logic              bank_o,
  input  logic              busy_i,
  input  logic              done_i,
  input  logic              result_bank_i,
  // ntt_core input stream (no backpressure towards AXI: dropped if not ready)
  output logic              s_valid_o,
  input  logic              s_ready_i,
  output logic [COEF_W-1:0] s_data_o,
  // ntt_core output stream
  input  logic              m_valid_i,
  output logic              m_ready_o,
  input  logic [COEF_W-1:0] m_data_i
);

  // --------------------------------------------------------------------------
  // Register map (docs/spec/l4_axi.md; fpga/sw/pqc_ntt_regs.h)
  // --------------------------------------------------------------------------
  localparam int IDX_W = ADDR_W - 2;               // word index width
  localparam logic [IDX_W-1:0] IDX_CTRL    = IDX_W'(8'h00 >> 2);
  localparam logic [IDX_W-1:0] IDX_STATUS  = IDX_W'(8'h04 >> 2);
  localparam logic [IDX_W-1:0] IDX_DIN     = IDX_W'(8'h08 >> 2);
  localparam logic [IDX_W-1:0] IDX_DOUT    = IDX_W'(8'h0C >> 2);
  localparam logic [IDX_W-1:0] IDX_CYCLES  = IDX_W'(8'h10 >> 2);
  localparam logic [IDX_W-1:0] IDX_VERSION = IDX_W'(8'h14 >> 2);
  localparam logic [IDX_W-1:0] IDX_ERR     = IDX_W'(8'h18 >> 2);
  localparam logic [IDX_W-1:0] IDX_CONFIG  = IDX_W'(8'h1C >> 2);

  localparam int ERR_START_BUSY = 0;
  localparam int ERR_DIN        = 1;
  localparam int ERR_DOUT       = 2;
  localparam int ERR_BAD_OP     = 3;
  localparam int ERR_DIN_RANGE  = 4;
  localparam int ERR_W          = 5;

  localparam logic [15:0] VERSION_ID  = 16'h4E54;  // PQC_NTT_VERSION_ID_VALUE
  localparam int          BFU_LATENCY = PRE_REG + MUL_REG + RED_PIPE + OUT_REG;

  localparam logic [31:0] VERSION_VALUE = {VERSION_ID, 8'(BFU_LATENCY), 8'(ALGO)};
  localparam logic [31:0] CONFIG_VALUE  = {8'h00, 8'(FCLK_MHZ), 8'h00,
                                           1'(OUT_REG), 2'(RED_PIPE), 1'(MUL_REG),
                                           1'(PRE_REG), 1'(ROM_OUT_REG),
                                           1'(SHARE_ADDSUB), 1'(IMPL)};

  // Parameters that do not fit their register field. The pipeline ranges
  // themselves are checked by bfu / zeta_rom.
  if (ADDR_W < 5 || ADDR_W > 32) begin : g_bad_addr_w
    $error("pqc_ntt_csr: ADDR_W=%0d not supported (5..32, register map up to 0x1C)", ADDR_W);
  end
  if (ALGO < 0 || ALGO > 3) begin : g_bad_algo
    $error("pqc_ntt_csr: ALGO=%0d not supported (0..3)", ALGO);
  end
  if (IMPL < 0 || IMPL > 1) begin : g_bad_impl
    $error("pqc_ntt_csr: IMPL=%0d not supported (0 hand RTL, 1 HLS)", IMPL);
  end
  if (FCLK_MHZ < 1 || FCLK_MHZ > 255) begin : g_bad_fclk
    $error("pqc_ntt_csr: FCLK_MHZ=%0d does not fit CONFIG[23:16] (1..255)", FCLK_MHZ);
  end
  if (PRE_REG < 0 || PRE_REG > 1 || MUL_REG < 0 || MUL_REG > 1 || RED_PIPE < 0 || RED_PIPE > 3
      || OUT_REG < 0 || OUT_REG > 1 || SHARE_ADDSUB < 0 || SHARE_ADDSUB > 1
      || ROM_OUT_REG < 0 || ROM_OUT_REG > 1) begin : g_bad_cfg_field
    $error("pqc_ntt_csr: a pipeline parameter does not fit its CONFIG field");
  end

  // --------------------------------------------------------------------------
  // Decode
  // --------------------------------------------------------------------------
  logic [IDX_W-1:0] wr_idx, rd_idx;
  logic             wr_ctrl, wr_din, wr_err, rd_dout;
  logic             ctrl_start, op_legal;
  op_e              ctrl_op;
  logic             din_hs, dout_hs, start_acc;

  assign wr_idx  = wr_addr_i[ADDR_W-1:2];
  assign rd_idx  = rd_addr_i[ADDR_W-1:2];
  assign wr_ctrl = wr_en_i && (wr_idx == IDX_CTRL);
  assign wr_din  = wr_en_i && (wr_idx == IDX_DIN);
  assign wr_err  = wr_en_i && (wr_idx == IDX_ERR);
  assign rd_dout = rd_en_i && (rd_idx == IDX_DOUT);

  // CTRL fields: bit0 start, bits[3:1] op, bit4 bank
  assign ctrl_start = wr_data_i[0];
  assign ctrl_op    = op_e'(wr_data_i[3:1]);
  assign op_legal   = (wr_data_i[3:1] inside {OP_LOAD, OP_NTT, OP_INTT, OP_BASEMUL, OP_UNLOAD});
  // start accepted by the core in this cycle
  assign start_acc  = wr_ctrl && ctrl_start && op_legal && !busy_i;
  assign din_hs     = wr_din && s_ready_i;
  assign dout_hs    = rd_dout && m_valid_i;

  // --------------------------------------------------------------------------
  // Core command and streams
  // --------------------------------------------------------------------------
  assign start_o   = start_acc;
  assign op_o      = start_acc ? ctrl_op : OP_LOAD;   // never an illegal encoding
  assign bank_o    = wr_data_i[4];
  assign s_valid_o = din_hs;
  assign s_data_o  = wr_data_i[COEF_W-1:0];
  assign m_ready_o = dout_hs;

  // --------------------------------------------------------------------------
  // done_sticky, ERR, CYCLES
  // --------------------------------------------------------------------------
  logic              done_sticky_q, done_sticky_d;
  logic [ERR_W-1:0]  err_q, err_d, err_set, err_clr;
  logic [31:0]       cnt_q, cnt_d, cycles_q, cycles_d;

  always_comb begin
    err_set                 = '0;
    err_set[ERR_START_BUSY] = wr_ctrl && ctrl_start && busy_i;
    err_set[ERR_DIN]        = wr_din && !s_ready_i;
    err_set[ERR_DOUT]       = rd_dout && !m_valid_i;
    err_set[ERR_BAD_OP]     = wr_ctrl && ctrl_start && !op_legal;
    err_set[ERR_DIN_RANGE]  = din_hs && (wr_data_i[COEF_W-1:0] >= COEF_W'(Q));
    err_clr                 = wr_err ? wr_data_i[ERR_W-1:0] : '0;
    err_d                   = (err_q & ~err_clr) | err_set;

    // CTRL write clears (wins over done_i); a start with an illegal op is
    // not a command and leaves done_sticky unchanged
    if (wr_ctrl && !(ctrl_start && !op_legal)) done_sticky_d = 1'b0;
    else if (done_i)                           done_sticky_d = 1'b1;
    else                                       done_sticky_d = done_sticky_q;

    if (start_acc)                cnt_d = 32'd1;
    else if (busy_i && cnt_q != '1) cnt_d = cnt_q + 32'd1;
    else                          cnt_d = cnt_q;

    cycles_d = done_i ? cnt_q : cycles_q;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      done_sticky_q <= 1'b0;
      err_q         <= '0;
      cnt_q         <= '0;
      cycles_q      <= '0;
    end else begin
      done_sticky_q <= done_sticky_d;
      err_q         <= err_d;
      cnt_q         <= cnt_d;
      cycles_q      <= cycles_d;
    end
  end

  // --------------------------------------------------------------------------
  // Read data (state before any write of the same cycle)
  // --------------------------------------------------------------------------
  always_comb begin
    rd_data_o = '0;
    case (rd_idx)
      IDX_STATUS:  rd_data_o = {27'd0, m_valid_i, s_ready_i, result_bank_i, done_sticky_q, busy_i};
      IDX_DOUT:    rd_data_o = m_valid_i ? {20'd0, m_data_i} : 32'd0;
      IDX_CYCLES:  rd_data_o = cycles_q;
      IDX_VERSION: rd_data_o = VERSION_VALUE;
      IDX_ERR:     rd_data_o = {{(32 - ERR_W){1'b0}}, err_q};
      IDX_CONFIG:  rd_data_o = CONFIG_VALUE;
      default:     rd_data_o = '0;   // CTRL, DIN (write only), no register
    endcase
  end

endmodule
