// pim_csr: register file and command FIFO entrance of the PIM IP pim_top (L3).
// Register map, command format and rules: docs/spec/pim.md (common frame arch.md 7.2; the
// decided behaviour of gemv_acc_csr / pqc-ntt-ip l4_axi.md: done_sticky priority, W1C with set
// winning, undefined addresses read 0, WSTRB ignored).
//
// Input: the register access interface of axil_slave (one write and one read strobe per cycle).
// Every register action happens in the cycle of the strobe; a read in the same cycle as a write
// returns the state before that write.
//
//   0x00 ID        R     0x5049_0001 ("PI", version 1)
//   0x04 CONFIG    R     [7:0] FCLK_MHZ, [11:8] NB, [15:12] log2(LB), [31:16] NMAX
//   0x08 CTRL      W     bit0 start, [7:4] op (1 = RUN, 2 = FLUSH); reads 0
//   0x0C STATUS    R     bit0 busy, bit1 done_sticky, bit2 err_any, bit3 push_busy (push check in
//                        progress), [23:8] command FIFO level
//   0x10 ERR       R/W1C bit0 START_BUSY, bit1 BAD_OP, bit2 BAD_CMD, bit3 BAD_DESC, bit4 MISALIGN,
//                        bit5 RD_RESP, bit6 WR_RESP, bit7 FIFO_OVF, bit8 PUSH_BUSY
//   0x14 CYCLES    R     cycles of the last run (start to done)
//   0x18 RD_STALL  R     cycles of the last run with the core waiting for read data
//   0x1C WR_STALL  R     cycles of the last run with the y packer held by the write engine
//   0x20 OPS       R     commands completed since reset (LDW + WRGB + MACAB)
//   0x24 CONFIG2   R     [15:0] DEPTH (bank words), [31:16] CMD_DEPTH (command FIFO entries)
//   0x40..0x4C CMD0..CMD3  RW  the command being built (32 bits each, stored as written)
//   0x50 CMD_PUSH  W     a write takes {CMD3, CMD2, CMD1, CMD0}, checks it and pushes it into the
//                        command FIFO (the written data is ignored); reads 0
//   0x60 ST_WRGB   R     bank_stat_t wrgb: 32-byte units of every WRGB (ceil(n/32) each)
//   0x64 ST_MAC    R     bank_stat_t mac: all-bank MAC steps (ceil(rows/NB) ceil(n/16) per MACAB)
//   0x68 ST_RDMAC  R     bank_stat_t rdmac: results gathered (rows per MACAB)
//   0x6C N_LDW, 0x70 N_WRGB, 0x74 N_MACAB  R   commands of each kind completed
//   other                read 0, write ignored
// Counters 0x20, 0x60..0x74 count from reset and wrap at 2^32.
//
// Command (pushed word): CMD0 [3:0] op (1 LDW, 2 WRGB, 3 MACAB), [15:4] n, [31:16] rows;
// CMD1 [16:0] xm, [31:17] base (bank word); CMD2 DDR address; CMD3 [7:0] we, [15:8] xe,
// [23:16] fo. Push check (S4-6b: sequential products, no runtime multiplier): a CMD_PUSH write in
// cycle c while no check is in progress takes a copy of CMD0..CMD3 and starts the check
// (umul_seq ceil(rows/NB) x ceil(n/16) and rows x (1 + ceil(n/8)), started in c); push_busy is 1
// in c + 1 .. p, p = c + PCHK_CYC (PCHK_CYC = the wider multiplier operand + 1). In p, on the copy:
// op not 1..3 -> BAD_CMD only; otherwise BAD_DESC (n 0 or > NMAX; LDW/MACAB: rows 0 or
// base + ceil(rows/NB) ceil(n/16) > DEPTH; the DDR range passes 2^32: LDW addr + rows 8
// (1 + ceil(n/8)), WRGB addr + n, MACAB addr + 4 rows) and MISALIGN (addr[2:0] != 0)
// independently. A command with an error is not queued. A legal command meeting a full FIFO
// (fifo_ready_i = 0 in p) is not queued and sets FIFO_OVF. Otherwise push_o in p (the FIFO level
// counts it from p + 1). A CMD_PUSH write in c + 1 .. p sets PUSH_BUSY and is ignored. The
// verdict is the one of the S4-5 combinational check, bit for bit; only its cycle moved.
//
// Run control: busy_q is 1 from the cycle after an accepted start (s) up to and including the
// done_i cycle (e). push_busy_o tells pim_top that a pushed command is still being checked (the
// run does not end while one is). "Idle" for a CTRL write is !busy_q or the done_i cycle. CTRL write while idle:
// clears done_sticky (wins over done_i of the same cycle), except a start with an op other than
// 1, 2 (BAD_OP, nothing else changes); with start = 1 and op 1 or 2 the run starts: start_o = 1,
// run_flush_o latched (s + 1 on: 1 for FLUSH), CYCLES / RD_STALL / WR_STALL cleared. CTRL with
// start = 1 while busy (not in the done_i cycle): START_BUSY (and BAD_OP if op is illegal),
// ignored. CTRL with start = 0 while busy: no effect.
// ERR: W1C, a set wins over a clear of the same bit in the same cycle.
module pim_csr
  import llm_pkg::*;
#(
  parameter int ADDR_W    = 12,
  parameter int NB        = 4,
  parameter int LB        = 16,
  parameter int DEPTH     = 4096,
  parameter int NMAX      = N_MAX,
  parameter int CMD_DEPTH = 32,
  parameter int FCLK_MHZ  = 100,
  localparam int LV_W     = $clog2(CMD_DEPTH + 1)
) (
  input  logic              clk,
  input  logic              rst_n,
  // register access (axil_slave)
  input  logic              wr_en_i,
  input  logic [ADDR_W-1:0] wr_addr_i,
  input  logic [31:0]       wr_data_i,
  input  logic              rd_en_i,
  input  logic [ADDR_W-1:0] rd_addr_i,
  output logic [31:0]       rd_data_o,
  // command FIFO entrance
  output logic              push_o,
  output logic [127:0]      push_data_o,
  input  logic              fifo_ready_i,
  input  logic [LV_W-1:0]   fifo_level_i,
  // run control
  output logic              start_o,      // accepted start (cycle s)
  output logic              busy_o,       // s + 1 .. e
  output logic              push_busy_o,  // a CMD_PUSH is being checked (c + 1 .. p)
  output logic              run_flush_o,  // op of the current run is FLUSH (valid from s + 1)
  input  logic              done_i,       // the run is complete (cycle e, only while busy)
  // events of the current cycle
  input  logic              rd_err_i,
  input  logic              wr_err_i,
  input  logic              rd_stall_i,
  input  logic              wr_stall_i,
  input  logic              ev_mac_i,
  input  logic              ev_wrgb_i,
  input  logic              ev_rdmac_i,
  input  logic              done_ldw_i,
  input  logic              done_wrgb_i,
  input  logic              done_mac_i
);
  if (ADDR_W < 8 || ADDR_W > 32) $error("pim_csr: ADDR_W=%0d must be 8..32", ADDR_W);
  if (NB < 1 || NB > 15) $error("pim_csr: NB=%0d does not fit CONFIG[11:8]", NB);
  if (LB < 1 || LB > 32768 || (LB & (LB - 1)) != 0) $error("pim_csr: LB=%0d must be a power of two", LB);
  if (DEPTH < 2 || DEPTH > 32768) $error("pim_csr: DEPTH=%0d must be 2..32768 (CMD1 base field 15 bits)", DEPTH);
  if (NMAX < 1 || NMAX > 4095) $error("pim_csr: NMAX=%0d must be 1..4095 (CMD0 n field 12 bits)", NMAX);
  if (CMD_DEPTH < 1 || CMD_DEPTH > 65535) $error("pim_csr: CMD_DEPTH=%0d must be 1..65535", CMD_DEPTH);
  if (FCLK_MHZ < 1 || FCLK_MHZ > 255) $error("pim_csr: FCLK_MHZ=%0d must be 1..255", FCLK_MHZ);

  localparam logic [31:0] ID_VAL      = 32'h5049_0001;
  localparam logic [31:0] CONFIG_VAL  = {16'(NMAX), 4'($clog2(LB)), 4'(NB), 8'(FCLK_MHZ)};
  localparam logic [31:0] CONFIG2_VAL = {16'(CMD_DEPTH), 16'(DEPTH)};
  localparam int          ERR_W       = 9;

  localparam logic [5:0] R_ID = 6'h00, R_CONFIG = 6'h01, R_CTRL = 6'h02, R_STATUS = 6'h03,
                         R_ERR = 6'h04, R_CYCLES = 6'h05, R_RDSTALL = 6'h06, R_WRSTALL = 6'h07,
                         R_OPS = 6'h08, R_CONFIG2 = 6'h09, R_CMD0 = 6'h10, R_CMD1 = 6'h11,
                         R_CMD2 = 6'h12, R_CMD3 = 6'h13, R_PUSH = 6'h14, R_STWRGB = 6'h18,
                         R_STMAC = 6'h19, R_STRDMAC = 6'h1A, R_NLDW = 6'h1B, R_NWRGB = 6'h1C,
                         R_NMACAB = 6'h1D;
  localparam int E_START_BUSY = 0, E_BAD_OP = 1, E_BAD_CMD = 2, E_BAD_DESC = 3, E_MISALIGN = 4,
                 E_RD_RESP = 5, E_WR_RESP = 6, E_FIFO_OVF = 7, E_PUSH_BUSY = 8;

  // ---------------- decode ----------------
  logic        wr_hit, rd_hit;
  logic [5:0]  wr_w, rd_w;
  logic [31:0] wr_a32, rd_a32;
  assign wr_a32 = 32'(wr_addr_i);
  assign rd_a32 = 32'(rd_addr_i);
  assign wr_hit = wr_en_i && (wr_a32[31:8] == 24'd0);
  assign rd_hit = rd_a32[31:8] == 24'd0;
  assign wr_w   = wr_a32[7:2];
  assign rd_w   = rd_a32[7:2];

  // ---------------- command registers ----------------
  logic [31:0] cmd_r [4];
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) for (int i = 0; i < 4; i++) cmd_r[i] <= '0;
    else if (wr_hit && wr_w >= R_CMD0 && wr_w <= R_CMD3) cmd_r[wr_w[1:0]] <= wr_data_i;

  // ---------------- push check ----------------
  // multiplier operands narrowed to their legal range (exact whenever n <= NMAX)
  localparam int NR_W  = $clog2((65535 + NB - 1) / NB + 1);   // ceil(rows / NB)
  localparam int NWB_W = $clog2((NMAX + 15) / 16 + 1);        // ceil(n / 16)
  localparam int N8B_W = $clog2((NMAX + 7) / 8 + 2);          // 1 + ceil(n / 8)
  localparam int PCHK_CYC = ((NWB_W > N8B_W) ? NWB_W : N8B_W) + 1;
  localparam int PC_W  = $clog2(PCHK_CYC + 1);
  logic [127:0] pc_q;            // the command being checked (copy taken in c)
  logic         pchk_q, pverdict, push_req, push_acc;
  logic [PC_W-1:0] pcnt_q;
  logic [NR_W+NWB_W-1:0] p_bank;   // ceil(rows/NB) x ceil(n/16)
  logic [16+N8B_W-1:0]   p_ldw;    // rows x (1 + ceil(n/8))
  logic                  ub_busy, ul_busy;
  logic [11:0]           w_n;
  logic [15:0]           w_rows;

  assign push_req = wr_hit && wr_w == R_PUSH;
  assign push_acc = push_req && !pchk_q;                 // cycle c
  assign pverdict = pchk_q && pcnt_q == PC_W'(1);        // cycle p = c + PCHK_CYC
  assign w_n      = cmd_r[0][15:4];
  assign w_rows   = cmd_r[0][31:16];

  // started in c on the registers (= the copy)
  umul_seq #(.A_W(NR_W), .B_W(NWB_W)) u_bmul (
    .clk, .rst_n, .start_i(push_acc), .a_i(NR_W'((17'(w_rows) + 17'(NB - 1)) / 17'(NB))),
    .b_i(NWB_W'((13'(w_n) + 13'd15) >> 4)), .p_o(p_bank), .done_o(), .busy_o(ub_busy));
  umul_seq #(.A_W(16), .B_W(N8B_W)) u_lmul (
    .clk, .rst_n, .start_i(push_acc), .a_i(w_rows), .b_i(N8B_W'(((13'(w_n) + 13'd7) >> 3) + 13'd1)),
    .p_o(p_ldw), .done_o(), .busy_o(ul_busy));

  // verdict in p on the copy
  logic [3:0]  c_op;
  logic [11:0] c_n;
  logic [15:0] c_rows;
  logic [14:0] c_base;
  logic [31:0] c_addr;
  logic        c_isop, c_rowcmd, n_ok, rows_ok, base_ok, ddr_ok, c_desc_ok, c_align_ok;
  logic [32:0] c_ddr_len;

  assign c_op   = pc_q[3:0];
  assign c_n    = pc_q[15:4];
  assign c_rows = pc_q[31:16];
  assign c_base = pc_q[63:49];
  assign c_addr = pc_q[95:64];

  assign c_isop    = c_op == 4'd1 || c_op == 4'd2 || c_op == 4'd3;
  assign c_rowcmd  = c_op != 4'd2;                       // LDW, MACAB
  assign n_ok      = c_n != '0 && 32'(c_n) <= 32'(NMAX);
  assign rows_ok   = !c_rowcmd || c_rows != '0;
  assign base_ok   = !c_rowcmd || (33'(c_base) + 33'(p_bank) <= 33'(DEPTH));
  always_comb
    unique case (c_op)
      4'd1:    c_ddr_len = 33'({p_ldw, 3'b000});
      4'd2:    c_ddr_len = 33'(c_n);
      default: c_ddr_len = 33'({c_rows, 2'b00});
    endcase
  assign ddr_ok     = {1'b0, c_addr} + c_ddr_len <= 33'h1_0000_0000;
  assign c_desc_ok  = n_ok && rows_ok && base_ok && ddr_ok;
  assign c_align_ok = c_addr[2:0] == 3'd0;
  assign push_o     = pverdict && c_isop && c_desc_ok && c_align_ok && fifo_ready_i;
  assign push_data_o = pc_q;
  assign push_busy_o = pchk_q;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      pchk_q <= 1'b0;
      pcnt_q <= '0;
    end else if (push_acc) begin
      pchk_q <= 1'b1;
      pcnt_q <= PC_W'(PCHK_CYC);
    end else if (pchk_q) begin
      pcnt_q <= pcnt_q - 1'b1;
      if (pverdict) pchk_q <= 1'b0;
    end
  always_ff @(posedge clk)
    if (push_acc) pc_q <= {cmd_r[3], cmd_r[2], cmd_r[1], cmd_r[0]};

  // ---------------- CTRL ----------------
  logic busy_q, done_q, flush_q;
  logic ctrl_wr, start_req, idle, op_ok;
  logic [ERR_W-1:0] err_q, err_set;

  assign ctrl_wr     = wr_hit && (wr_w == R_CTRL);
  assign start_req   = ctrl_wr && wr_data_i[0];
  assign idle        = !busy_q || done_i;
  assign op_ok       = wr_data_i[7:4] == 4'd1 || wr_data_i[7:4] == 4'd2;
  assign start_o     = start_req && idle && op_ok;
  assign busy_o      = busy_q;
  assign run_flush_o = flush_q;

  always_comb begin
    err_set               = '0;
    err_set[E_START_BUSY] = start_req && !idle;
    err_set[E_BAD_OP]     = start_req && !op_ok;
    err_set[E_BAD_CMD]    = pverdict && !c_isop;
    err_set[E_BAD_DESC]   = pverdict && c_isop && !c_desc_ok;
    err_set[E_MISALIGN]   = pverdict && c_isop && !c_align_ok;
    err_set[E_RD_RESP]    = rd_err_i;
    err_set[E_WR_RESP]    = wr_err_i;
    err_set[E_FIFO_OVF]   = pverdict && c_isop && c_desc_ok && c_align_ok && !fifo_ready_i;
    err_set[E_PUSH_BUSY]  = push_req && pchk_q;
  end

  // ---------------- state, ERR, counters ----------------
  logic [31:0] cyc_q, rdst_q, wrst_q, ops_q, stw_q, stm_q, str_q, nl_q, nx_q, nm_q;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      busy_q  <= 1'b0;
      done_q  <= 1'b0;
      flush_q <= 1'b0;
      err_q   <= '0;
      cyc_q   <= '0;
      rdst_q  <= '0;
      wrst_q  <= '0;
      ops_q   <= '0;
      stw_q   <= '0;
      stm_q   <= '0;
      str_q   <= '0;
      nl_q    <= '0;
      nx_q    <= '0;
      nm_q    <= '0;
    end else begin
      if (start_o) begin
        busy_q  <= 1'b1;
        flush_q <= wr_data_i[7:4] == 4'd2;
      end else if (done_i) busy_q <= 1'b0;
      if (ctrl_wr && idle && !(wr_data_i[0] && !op_ok)) done_q <= 1'b0;
      else if (done_i) done_q <= 1'b1;
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
      if (done_ldw_i || done_wrgb_i || done_mac_i) ops_q <= ops_q + 32'd1;
      if (ev_wrgb_i)   stw_q <= stw_q + 32'd1;
      if (ev_mac_i)    stm_q <= stm_q + 32'd1;
      if (ev_rdmac_i)  str_q <= str_q + 32'd1;
      if (done_ldw_i)  nl_q  <= nl_q + 32'd1;
      if (done_wrgb_i) nx_q  <= nx_q + 32'd1;
      if (done_mac_i)  nm_q  <= nm_q + 32'd1;
    end

  // ---------------- read mux (state before the write of the same cycle) ----------------
  always_comb begin
    rd_data_o = 32'd0;
    if (rd_hit)
      case (rd_w)
        R_ID:      rd_data_o = ID_VAL;
        R_CONFIG:  rd_data_o = CONFIG_VAL;
        R_STATUS:  rd_data_o = {8'd0, 16'(fifo_level_i), 4'd0, pchk_q, err_q != '0, done_q, busy_q};
        R_ERR:     rd_data_o = 32'(err_q);
        R_CYCLES:  rd_data_o = cyc_q;
        R_RDSTALL: rd_data_o = rdst_q;
        R_WRSTALL: rd_data_o = wrst_q;
        R_OPS:     rd_data_o = ops_q;
        R_CONFIG2: rd_data_o = CONFIG2_VAL;
        R_CMD0:    rd_data_o = cmd_r[0];
        R_CMD1:    rd_data_o = cmd_r[1];
        R_CMD2:    rd_data_o = cmd_r[2];
        R_CMD3:    rd_data_o = cmd_r[3];
        R_STWRGB:  rd_data_o = stw_q;
        R_STMAC:   rd_data_o = stm_q;
        R_STRDMAC: rd_data_o = str_q;
        R_NLDW:    rd_data_o = nl_q;
        R_NWRGB:   rd_data_o = nx_q;
        R_NMACAB:  rd_data_o = nm_q;
        default:   rd_data_o = 32'd0;
      endcase
  end

  logic unused_rd_en;
  assign unused_rd_en = rd_en_i;  // reads have no side effects

`ifndef SYNTHESIS
  always @(posedge clk)
    if (rst_n === 1'b1) begin
      if (done_i === 1'b1 && busy_q !== 1'b1)
        $error("L3_DONE pim_csr %m: done_i while not busy");
      if (pverdict && (ub_busy || ul_busy))
        $error("L3_CHK pim_csr %m: a push check product is not ready in the verdict cycle");
    end
`endif

endmodule
