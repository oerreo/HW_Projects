// vec_csr: register file, descriptor check and run control of the vector IP vec_top (L3).
// Register map and rules: docs/spec/vec.md (common frame arch.md 7.2; the decided behaviour of
// attn_csr / gemv_acc_csr: done_sticky priority, W1C with set winning, undefined addresses read 0,
// WSTRB ignored, a read in the cycle of a write returns the state before the write).
//
//   0x00 ID         R     0x5645_0001 ("VE", version 1)
//   0x04 CONFIG     R     [7:0] FCLK_MHZ, [15:8] IDX_W, [31:16] N_MAX
//   0x08 CTRL       W     bit0 start, [7:4] op (1 RMSNORM, 2 SWIGLU, 3 ACTQ, 4 ARGMAX); reads 0
//   0x0C STATUS     R     bit0 busy (check or op), bit1 done_sticky, bit2 err_any
//   0x10 ERR        R/W1C bit0 START_BUSY, bit1 BAD_OP, bit2 BAD_DESC, bit3 MISALIGN, bit4 RD_RESP,
//                         bit5 WR_RESP
//   0x14 CYCLES     R     cycles of the last accepted call (CTRL write to done, check included)
//   0x18 RD_STALL   R     cycles of the last call in which the core waited for read data
//   0x1C WR_STALL   R     cycles of the last call in which the packer was held by the writer
//   0x20 OPS        R     ops completed since reset
//   0x24 ARGMAX_IDX R     [IDX_W-1:0] index of the last ARGMAX call
//   0x28 ARGMAX_VAL R     its maximum (int32)
//   0x40 IN0_ADDR, 0x44 IN1_ADDR, 0x48 OUT_ADDR, 0x4C SCL_ADDR  RW (32 bits)
//   0x50 N          RW    32 bits as written (no aliasing; legal 1..N_MAX, ARGMAX 1..2^IDX_W)
//   0x54 FMT        RW    [15:0] qmax (ACTQ), [16] mode (1 MANT), [27:24] sb (SWIGLU LUT bits);
//                         reset 0x0801_007F
//   0x58 EXP        RW    [7:0] f (ACTQ f, RMSNORM fy), [15:8] ge (RMSNORM), signed
//   0x5C EPSC       RW    RMSNORM epsc (int32, must be >= 0)
// Descriptor registers keep the written bits of their fields (other bits read 0).
//
// Call: CTRL write in cycle s while idle (= no check and no op running, or the done cycle e of the
// running op): op 1..4 accepted: descriptor latched (outputs valid from s + 1), done_sticky,
// CYCLES / RD_STALL / WR_STALL cleared, STATUS.busy = 1 from s + 1. The check is CHK_CYC = 1 cycle:
// the verdict cycle is v = s + 1, on the latched descriptor (only shifts and adds: byte counts
// 4N, 2N, N, N qb; no multiplier). Legal: start_o in v, the op runs from v + 1 (busy_o v + 1 .. e).
// Illegal: BAD_DESC and / or MISALIGN (visible v + 1), no start, STATUS.busy = 0 from v + 1, no done,
// OPS unchanged, CYCLES = 1. Another op: BAD_OP only, in s (done_sticky unchanged). start = 0:
// done_sticky cleared. While busy (check or op, not the done cycle): start = 1 -> START_BUSY
// (+ BAD_OP for an illegal op), ignored.
// Check (docs/spec/vec.md 4.2): N range; mode 1 (RMSNORM, SWIGLU, ACTQ); qmax 127 / 2047 / 32767
// (ACTQ); sb 8 (SWIGLU); epsc >= 0 (RMSNORM); every buffer [addr, addr + bytes) inside 2^32;
// MISALIGN: the [2:0] of every used address.
module vec_csr
  import llm_pkg::*;
#(
  parameter int ADDR_W   = 12,
  parameter int N_MAX    = 1024,
  parameter int IDX_W    = 16,
  parameter int FCLK_MHZ = 100,
  localparam int NV_W    = IDX_W + 1
) (
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic                   wr_en_i,
  input  logic [ADDR_W-1:0]      wr_addr_i,
  input  logic [31:0]            wr_data_i,
  input  logic                   rd_en_i,
  input  logic [ADDR_W-1:0]      rd_addr_i,
  output logic [31:0]            rd_data_o,
  // run control
  output logic                   start_o,      // legal call: cycle v = s + 1
  output logic                   busy_o,       // op running: v + 1 .. e
  input  logic                   done_i,
  // latched descriptor (valid from s + 1); op 0 RMSNORM, 1 SWIGLU, 2 ACTQ, 3 ARGMAX
  output logic [1:0]             op_o,
  output logic [31:0]            in0_o, in1_o, out_o, scl_o,
  output logic [NV_W-1:0]        n_o,
  output logic [15:0]            qmax_o,
  output logic signed [E_W-1:0]  f_o, ge_o,
  output logic [31:0]            epsc_o,
  // ARGMAX result (pulse at the done of an ARGMAX call)
  input  logic                   am_valid_i,
  input  logic [IDX_W-1:0]       am_idx_i,
  input  logic [31:0]            am_val_i,
  // events
  input  logic                   rd_err_i,
  input  logic                   wr_err_i,
  input  logic                   rd_stall_i,
  input  logic                   wr_stall_i
);
  if (ADDR_W < 8 || ADDR_W > 32) $error("vec_csr: ADDR_W=%0d must be 8..32", ADDR_W);
  if (N_MAX < 2 || N_MAX > 65535) $error("vec_csr: N_MAX=%0d must be 2..65535", N_MAX);
  if (IDX_W < 1 || IDX_W > 30 || (1 << IDX_W) < N_MAX) $error("vec_csr: IDX_W=%0d must be 1..30 with 2^IDX_W >= N_MAX", IDX_W);

  localparam logic [31:0] ID_VAL     = 32'h5645_0001;
  localparam logic [31:0] CONFIG_VAL = {16'(N_MAX), 8'(IDX_W), 8'(FCLK_MHZ)};
  localparam logic [31:0] FMT_RST    = 32'h0801_007F;
  localparam int E_START_BUSY = 0, E_BAD_OP = 1, E_BAD_DESC = 2, E_MISALIGN = 3, E_RD_RESP = 4,
                 E_WR_RESP = 5, ERR_W = 6;
  localparam logic [1:0] OP_RMS = 2'd0, OP_SWI = 2'd1, OP_ACTQ = 2'd2, OP_AMAX = 2'd3;
  localparam logic [5:0] R_ID = 6'h00, R_CONFIG = 6'h01, R_CTRL = 6'h02, R_STATUS = 6'h03,
                         R_ERR = 6'h04, R_CYCLES = 6'h05, R_RDSTALL = 6'h06, R_WRSTALL = 6'h07,
                         R_OPS = 6'h08, R_AMIDX = 6'h09, R_AMVAL = 6'h0A,
                         R_IN0 = 6'h10, R_IN1 = 6'h11, R_OUT = 6'h12, R_SCL = 6'h13, R_N = 6'h14,
                         R_FMT = 6'h15, R_EXP = 6'h16, R_EPSC = 6'h17;

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

  // ---------------- descriptor registers ----------------
  logic [31:0] in0_r, in1_r, out_r, scl_r, n_r, epsc_r;
  logic [15:0] qmax_r;
  logic        mode_r;
  logic [3:0]  sb_r;
  logic [7:0]  f_r, ge_r;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      in0_r <= '0; in1_r <= '0; out_r <= '0; scl_r <= '0; n_r <= '0; epsc_r <= '0;
      qmax_r <= FMT_RST[15:0]; mode_r <= FMT_RST[16]; sb_r <= FMT_RST[27:24]; f_r <= '0; ge_r <= '0;
    end else if (wr_hit)
      unique case (wr_w)
        R_IN0:  in0_r  <= wr_data_i;
        R_IN1:  in1_r  <= wr_data_i;
        R_OUT:  out_r  <= wr_data_i;
        R_SCL:  scl_r  <= wr_data_i;
        R_N:    n_r    <= wr_data_i;
        R_FMT:  begin qmax_r <= wr_data_i[15:0]; mode_r <= wr_data_i[16]; sb_r <= wr_data_i[27:24]; end
        R_EXP:  begin f_r <= wr_data_i[7:0]; ge_r <= wr_data_i[15:8]; end
        R_EPSC: epsc_r <= wr_data_i;
        default: ;
      endcase

  // ---------------- CTRL and call state ----------------
  logic             chk_q, busy_q, done_q;
  logic             ctrl_wr, start_req, idle, op_ok, acc, verdict, v_desc_ok, v_al_ok;
  logic [3:0]       op_w;
  logic [ERR_W-1:0] err_q, err_set;
  // latched (s + 1)
  logic [1:0]       op_q;
  logic [31:0]      nl_q;
  logic             model_q;
  logic [3:0]       sbl_q;

  assign ctrl_wr   = wr_hit && (wr_w == R_CTRL);
  assign start_req = ctrl_wr && wr_data_i[0];
  assign op_w      = wr_data_i[7:4];
  assign idle      = (!chk_q && !busy_q) || done_i;
  assign op_ok     = op_w >= 4'd1 && op_w <= 4'd4;
  assign acc       = start_req && idle && op_ok;           // accepted call: cycle s
  assign verdict   = chk_q;                                // cycle v = s + 1
  assign start_o   = verdict && v_desc_ok && v_al_ok;
  assign busy_o    = busy_q;

  always_ff @(posedge clk)
    if (acc) begin
      op_q    <= 2'(op_w - 4'd1);
      in0_o   <= in0_r; in1_o <= in1_r; out_o <= out_r; scl_o <= scl_r;
      nl_q    <= n_r;
      qmax_o  <= qmax_r;
      model_q <= mode_r;
      sbl_q   <= sb_r;
      f_o     <= f_r;
      ge_o    <= ge_r;
      epsc_o  <= epsc_r;
    end
  assign op_o = op_q;
  assign n_o  = NV_W'(nl_q);

  // ---------------- descriptor check (shifts and adds only) ----------------
  localparam logic [35:0] LIM = 36'h1_0000_0000;   // 2^32
  logic        am, rms, swi, actq, q16;
  logic [35:0] in0_end, in1_end, out_end, scl_end;
  assign am   = op_q == OP_AMAX;
  assign rms  = op_q == OP_RMS;
  assign swi  = op_q == OP_SWI;
  assign actq = op_q == OP_ACTQ;
  assign q16  = qmax_o != 16'd127;
  assign in0_end = 36'(in0_o) + {2'b00, nl_q, 2'b00};                          // + 4N
  assign in1_end = 36'(in1_o) + (rms ? {3'b000, nl_q, 1'b0} : {2'b00, nl_q, 2'b00});  // + 2N / 4N
  assign out_end = 36'(out_o) + (am ? 36'd4 : (actq && q16) ? {3'b000, nl_q, 1'b0} : 36'(nl_q));
  assign scl_end = 36'(scl_o) + 36'd8;

  always_comb begin
    v_desc_ok = nl_q != '0 && (am ? nl_q <= 32'(1 << IDX_W) : nl_q <= 32'(N_MAX)) &&
                (am || model_q) &&
                (!actq || qmax_o == 16'd127 || qmax_o == 16'd2047 || qmax_o == 16'd32767) &&
                (!swi || sbl_q == 4'd8) && (!rms || !epsc_o[31]) &&
                in0_end <= LIM && out_end <= LIM && (!(rms || swi) || in1_end <= LIM) &&
                (am || scl_end <= LIM);
    v_al_ok   = in0_o[2:0] == '0 && out_o[2:0] == '0 && (!(rms || swi) || in1_o[2:0] == '0) &&
                (am || scl_o[2:0] == '0);
  end

  always_comb begin
    err_set               = '0;
    err_set[E_START_BUSY] = start_req && !idle;
    err_set[E_BAD_OP]     = start_req && !op_ok;
    err_set[E_BAD_DESC]   = verdict && !v_desc_ok;
    err_set[E_MISALIGN]   = verdict && !v_al_ok;
    err_set[E_RD_RESP]    = rd_err_i;
    err_set[E_WR_RESP]    = wr_err_i;
  end

  logic [31:0]      cyc_q, rdst_q, wrst_q, ops_q, amv_q;
  logic [IDX_W-1:0] ami_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      chk_q  <= 1'b0;
      busy_q <= 1'b0;
      done_q <= 1'b0;
      err_q  <= '0;
      cyc_q  <= '0;
      rdst_q <= '0;
      wrst_q <= '0;
      ops_q  <= '0;
      ami_q  <= '0;
      amv_q  <= '0;
    end else begin
      chk_q <= acc;
      if (start_o) busy_q <= 1'b1;
      else if (done_i) busy_q <= 1'b0;
      if (ctrl_wr && idle && !(wr_data_i[0] && !op_ok)) done_q <= 1'b0;
      else if (done_i) done_q <= 1'b1;
      err_q <= (err_q & ~((wr_hit && wr_w == R_ERR) ? wr_data_i[ERR_W-1:0] : '0)) | err_set;
      if (acc) begin
        cyc_q  <= '0;
        rdst_q <= '0;
        wrst_q <= '0;
      end else if (chk_q || busy_q) begin
        cyc_q <= cyc_q + 32'd1;
        if (rd_stall_i) rdst_q <= rdst_q + 32'd1;
        if (wr_stall_i) wrst_q <= wrst_q + 32'd1;
      end
      if (done_i) ops_q <= ops_q + 32'd1;
      if (am_valid_i) begin
        ami_q <= am_idx_i;
        amv_q <= am_val_i;
      end
    end

  // ---------------- read mux ----------------
  always_comb begin
    rd_data_o = 32'd0;
    if (rd_hit)
      case (rd_w)
        R_ID:      rd_data_o = ID_VAL;
        R_CONFIG:  rd_data_o = CONFIG_VAL;
        R_STATUS:  rd_data_o = {29'd0, err_q != '0, done_q, chk_q || busy_q};
        R_ERR:     rd_data_o = 32'(err_q);
        R_CYCLES:  rd_data_o = cyc_q;
        R_RDSTALL: rd_data_o = rdst_q;
        R_WRSTALL: rd_data_o = wrst_q;
        R_OPS:     rd_data_o = ops_q;
        R_AMIDX:   rd_data_o = 32'(ami_q);
        R_AMVAL:   rd_data_o = amv_q;
        R_IN0:     rd_data_o = in0_r;
        R_IN1:     rd_data_o = in1_r;
        R_OUT:     rd_data_o = out_r;
        R_SCL:     rd_data_o = scl_r;
        R_N:       rd_data_o = n_r;
        R_FMT:     rd_data_o = {4'd0, sb_r, 7'd0, mode_r, qmax_r};
        R_EXP:     rd_data_o = {16'd0, ge_r, f_r};
        R_EPSC:    rd_data_o = epsc_r;
        default:   rd_data_o = 32'd0;
      endcase
  end

  logic unused_rd_en;
  assign unused_rd_en = rd_en_i;

`ifndef SYNTHESIS
  always @(posedge clk)
    if (rst_n === 1'b1) begin
      if (done_i === 1'b1 && busy_q !== 1'b1) $error("L3_DONE vec_csr %m: done_i while not busy");
      if (am_valid_i === 1'b1 && !(done_i === 1'b1 && op_q == OP_AMAX))
        $error("L3_AM vec_csr %m: argmax result outside the done of an ARGMAX call");
    end
`endif

endmodule
