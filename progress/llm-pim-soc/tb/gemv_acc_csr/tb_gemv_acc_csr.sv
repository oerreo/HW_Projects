// tb_gemv_acc_csr: gemv_acc_csr alone against a register-file model written from
// docs/spec/gemv_acc.md (section "register map" and "rules").
//
// Every cycle the TB drives (posedge, non-blocking) a random register access interface
// (write strobe with a random address / data, read strobe with a random address; both may come
// in every cycle, the CSR does not depend on axil_slave pacing) and random events: done_i (only
// while the model is busy, +PDONE percent per busy cycle), rd_err_i, wr_err_i, rd_stall_i,
// wr_stall_i, am_done_i with random am_idx_i / am_max_i. At negedge it compares with the model:
// rd_data_o for the presented read address (every cycle, the read mux is combinational),
// start_o, busy_o, and after every start the latched op_* outputs (descriptor, wbytes).
// Descriptor writes draw from legal and illegal values (ROWS 0, 1, 2^ROWS_W - 1, 2^ROWS_W,
// N 0, 1, NMAX, NMAX + 1, addresses unaligned, near 2^32, FLAGS 0..3), CTRL writes have start
// 0/1 and op 0..15, so every ERR cause, START_BUSY, CTRL in the done cycle and W1C against a
// set of the same bit happen many times (counted, each must happen).
// Plusargs: +SEED +N_CYC +PDONE +PEV
`timescale 1ns / 1ps
module tb_gemv_acc_csr #(
  parameter int P    = 1,
  parameter int NMAX = 1024
);
  import tb_util_pkg::*;
  import llm_pkg::*;

  localparam int ADDR_W = 12, ROWS_W = 16, IDX_W = 16;
  localparam int NW = $clog2(NMAX + 1);
  localparam int WB_W = ROWS_W + $clog2(NMAX / 8 + 2) + 3;
  localparam int A_ID = 'h00, A_CONFIG = 'h04, A_CTRL = 'h08, A_STATUS = 'h0C, A_ERR = 'h10,
                 A_CYCLES = 'h14, A_RDSTALL = 'h18, A_WRSTALL = 'h1C, A_OPS = 'h20,
                 A_WADDR = 'h40, A_XADDR = 'h44, A_YADDR = 'h48, A_ROWS = 'h4C, A_N = 'h50,
                 A_XM = 'h54, A_EXP = 'h58, A_FLAGS = 'h5C, A_AMIDX = 'h60, A_AMVAL = 'h64;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic                  wr_en = 0, rd_en = 0, done_i = 0, rd_err = 0, wr_err = 0;
  logic                  rd_stall = 0, wr_stall = 0, am_done = 0;
  logic [ADDR_W-1:0]     wr_addr = 0, rd_addr = 0;
  logic [31:0]           wr_data = 0, rd_data;
  logic [IDX_W-1:0]      am_idx = 0;
  logic signed [31:0]    am_max = 0;
  logic                  start_o, busy_o, op_am, op_ye;
  logic [31:0]           op_wa, op_xa, op_ya;
  logic [ROWS_W-1:0]     op_rows;
  logic [NW-1:0]         op_n;
  logic [AM_W-1:0]       op_xm;
  logic signed [E_W-1:0] op_we, op_xe, op_fo;
  logic [WB_W-1:0]       op_wb;

  gemv_acc_csr #(.ADDR_W(ADDR_W), .P(P), .LANES(8), .NMAX(NMAX), .ROWS_W(ROWS_W), .IDX_W(IDX_W),
                 .FCLK_MHZ(100)) dut (
    .clk, .rst_n,
    .wr_en_i(wr_en), .wr_addr_i(wr_addr), .wr_data_i(wr_data),
    .rd_en_i(rd_en), .rd_addr_i(rd_addr), .rd_data_o(rd_data),
    .start_o, .busy_o, .done_i,
    .op_w_addr_o(op_wa), .op_x_addr_o(op_xa), .op_y_addr_o(op_ya), .op_rows_o(op_rows),
    .op_n_o(op_n), .op_xm_o(op_xm), .op_we_o(op_we), .op_xe_o(op_xe), .op_fo_o(op_fo),
    .op_am_en_o(op_am), .op_y_en_o(op_ye), .op_wbytes_o(op_wb),
    .rd_err_i(rd_err), .wr_err_i(wr_err), .rd_stall_i(rd_stall), .wr_stall_i(wr_stall),
    .am_done_i(am_done), .am_idx_i(am_idx), .am_max_i(am_max));

  tb_checker c_rd = new("read_data"), c_ctl = new("start_busy"), c_op = new("op_outputs"),
             c_cov = new("coverage");

  // ---------------- model ----------------
  logic [31:0] m_wa, m_xa, m_ya, m_rows, m_n, m_xm, m_exp, m_flags;
  bit          m_busy, m_done;
  logic [5:0]  m_err;
  logic [31:0] m_cyc, m_rdst, m_wrst, m_ops, m_amidx, m_amval;
  // latched descriptor of the model
  logic [31:0] o_wa, o_xa, o_ya, o_rows, o_n, o_xm, o_exp, o_wb;
  bit          o_am, o_ye, o_valid = 0;

  function automatic void model_reset();
    m_wa = 0; m_xa = 0; m_ya = 0; m_rows = 0; m_n = 0; m_xm = 0; m_exp = 0; m_flags = 2;
    m_busy = 0; m_done = 0; m_err = 0; m_cyc = 0; m_rdst = 0; m_wrst = 0; m_ops = 0;
    m_amidx = 0; m_amval = 0;
  endfunction

  function automatic logic [31:0] model_read(int a);
    if (a >= 256) return 0;
    case (a & ~3)
      A_ID:      return 32'h4741_0001;
      A_CONFIG:  return {16'(NMAX), 4'd3, 4'(P), 8'd100};
      A_STATUS:  return {29'd0, m_err != 0, m_done, m_busy};
      A_ERR:     return 32'(m_err);
      A_CYCLES:  return m_cyc;
      A_RDSTALL: return m_rdst;
      A_WRSTALL: return m_wrst;
      A_OPS:     return m_ops;
      A_WADDR:   return m_wa;
      A_XADDR:   return m_xa;
      A_YADDR:   return m_ya;
      A_ROWS:    return m_rows;
      A_N:       return m_n;
      A_XM:      return m_xm;
      A_EXP:     return m_exp;
      A_FLAGS:   return m_flags;
      A_AMIDX:   return m_amidx;
      A_AMVAL:   return m_amval;
      default:   return 0;
    endcase
  endfunction

  function automatic longint unsigned wbytes();
    return longint'(m_rows) * 8 * (1 + (longint'(m_n) + 7) / 8);
  endfunction
  function automatic bit desc_ok();
    if (m_rows == 0 || m_rows > (1 << ROWS_W) - 1 || m_n == 0 || m_n > NMAX || m_flags == 0) return 0;
    if (longint'(m_wa) + wbytes() > 64'h1_0000_0000) return 0;
    if (longint'(m_xa) + longint'(m_n) > 64'h1_0000_0000) return 0;
    if (m_flags[1] && longint'(m_ya) + 4 * longint'(m_rows) > 64'h1_0000_0000) return 0;
    return 1;
  endfunction
  function automatic bit align_ok();
    return m_wa[2:0] == 0 && m_xa[2:0] == 0 && (!m_flags[1] || m_ya[2:0] == 0);
  endfunction

  longint n_start = 0, n_busy_start = 0, n_ctrl_done0 = 0, n_ctrl_done1 = 0, n_w1c_set = 0,
          n_err[6] = '{0, 0, 0, 0, 0, 0}, n_done = 0, n_badop_busy = 0, n_edge[3] = '{0, 0, 0};

  // ---------------- negedge: compare, then advance the model by this cycle ----------------
  always @(negedge clk) if (rst_n) begin
    bit ctrl, start_req, idle, op_ok, st, w1c;
    logic [5:0] set, clr;
    logic [31:0] e;
    // read data of the presented address (state before this cycle's write)
    e = model_read(int'(rd_addr));
    if (rd_data !== e) c_rd.fail($sformatf("rd_addr 0x%03h: %h, model %h", rd_addr, rd_data, e));
    else c_rd.pass();
    ctrl      = wr_en && wr_addr < 256 && (wr_addr & ~3) == A_CTRL;
    start_req = ctrl && wr_data[0];
    idle      = !m_busy || done_i;
    op_ok     = wr_data[7:4] == 4'd1;
    st        = start_req && idle && op_ok && desc_ok() && align_ok();
    if (start_o !== st || busy_o !== m_busy)
      c_ctl.fail($sformatf("start_o %b busy_o %b, model %b %b", start_o, busy_o, st, m_busy));
    else c_ctl.pass();
    if (o_valid) begin
      automatic bit ok = op_wa === o_wa && op_xa === o_xa && op_ya === o_ya && 32'(op_rows) === o_rows &&
               32'(op_n) === o_n && 32'(op_xm) === o_xm && op_am === o_am && op_ye === o_ye &&
               op_we === o_exp[7:0] && op_xe === o_exp[15:8] && op_fo === o_exp[23:16] &&
               32'(op_wb) === o_wb;
      if (!ok) c_op.fail($sformatf("op outputs %h %h %h rows %0d n %0d xm %h exp %h/%h/%h am %b ye %b wb %0d, model %h %h %h %0d %0d %h %h %b %b %0d",
                                    op_wa, op_xa, op_ya, op_rows, op_n, op_xm, op_we, op_xe, op_fo, op_am,
                                    op_ye, op_wb, o_wa, o_xa, o_ya, o_rows, o_n, o_xm, o_exp, o_am, o_ye, o_wb));
      else c_op.pass();
    end
    // coverage
    if (st) n_start++;
    if (start_req && !idle) n_busy_start++;
    if (start_req && !idle && !op_ok) n_badop_busy++;
    if (ctrl && done_i) begin if (wr_data[0]) n_ctrl_done1++; else n_ctrl_done0++; end
    // ERR
    set = '0;
    set[0] = start_req && !idle;
    set[1] = start_req && !op_ok;
    set[2] = start_req && idle && op_ok && !desc_ok();
    set[3] = start_req && idle && op_ok && !align_ok();
    set[4] = rd_err;
    set[5] = wr_err;
    w1c = wr_en && wr_addr < 256 && (wr_addr & ~3) == A_ERR;
    clr = w1c ? wr_data[5:0] : '0;
    if ((set & clr) != 0) n_w1c_set++;
    if (start_req && idle && op_ok && m_rows != 0 && m_rows < (1 << ROWS_W) && m_n != 0 && m_n <= NMAX) begin
      if (longint'(m_wa) + wbytes() == 64'h1_0000_0000) n_edge[0]++;
      if (longint'(m_xa) + longint'(m_n) == 64'h1_0000_0000) n_edge[1]++;
      if (m_flags[1] && longint'(m_ya) + 4 * longint'(m_rows) == 64'h1_0000_0000) n_edge[2]++;
    end
    for (int b = 0; b < 6; b++) if (set[b]) n_err[b]++;
    // next state
    if (ctrl && idle && !(wr_data[0] && !op_ok)) m_done = 0;
    else if (done_i) m_done = 1;
    m_err = (m_err & ~clr) | set;
    if (st) begin m_cyc = 0; m_rdst = 0; m_wrst = 0; end
    else if (m_busy) begin
      m_cyc++;
      if (rd_stall) m_rdst++;
      if (wr_stall) m_wrst++;
    end
    if (done_i) begin m_ops++; n_done++; end
    if (am_done) begin m_amidx = 32'(am_idx); m_amval = am_max; end
    if (st) begin
      o_wa = m_wa; o_xa = m_xa; o_ya = m_ya; o_rows = m_rows; o_n = m_n; o_xm = m_xm;
      o_exp = m_exp; o_am = m_flags[0]; o_ye = m_flags[1]; o_wb = 32'(wbytes()); o_valid = 1;
      m_busy = 1;
    end else if (done_i) m_busy = 0;
    if (wr_en && wr_addr < 256)
      case (wr_addr & ~3)
        A_WADDR: m_wa = wr_data;
        A_XADDR: m_xa = wr_data;
        A_YADDR: m_ya = wr_data;
        A_ROWS:  m_rows = wr_data;
        A_N:     m_n = wr_data;
        A_XM:    m_xm = wr_data & 32'h1FFFF;
        A_EXP:   m_exp = wr_data & 32'hFF_FFFF;
        A_FLAGS: m_flags = wr_data & 3;
        default: ;
      endcase
  end

  // ---------------- stimulus ----------------
  int pdone = 5, pev = 30;
  int addrs[] = '{A_ID, A_CONFIG, A_CTRL, A_STATUS, A_ERR, A_CYCLES, A_RDSTALL, A_WRSTALL, A_OPS,
                  A_WADDR, A_XADDR, A_YADDR, A_ROWS, A_N, A_XM, A_EXP, A_FLAGS, A_AMIDX, A_AMVAL,
                  'h24, 'h3C, 'h68, 'hFC, 'h100, 'hFFC};

  function automatic logic [31:0] rnd_val(int a);
    int k = $urandom_range(9);
    case (a)
      A_ROWS: case (k)
          0: return 0; 1: return 1; 2: return (1 << ROWS_W) - 1; 3: return 1 << ROWS_W;
          4: return $urandom; default: return $urandom_range(300, 1);
        endcase
      A_N: case (k)
          0: return 0; 1: return 1; 2: return NMAX; 3: return NMAX + 1; 4: return $urandom;
          5: return 32'h1_0000 + $urandom_range(NMAX, 1); default: return $urandom_range(NMAX, 1);
        endcase
      A_WADDR, A_XADDR, A_YADDR: case (k)
          0: return $urandom;
          1: return 32'hFFFF_FFFF - 8 * $urandom_range(40);
          2: return 32'hFFFF_FFF8 - 8 * $urandom_range(4000);
          3: return 8 * $urandom_range(1000) + $urandom_range(7, 1);
          // the buffer ends exactly at 2^32 (+-8): range rule boundary of the current ROWS / N
          4, 5: begin
            longint unsigned len = (a == A_WADDR) ? wbytes() : (a == A_XADDR) ? longint'(m_n) :
                                   4 * longint'(m_rows);
            return 32'(64'h1_0000_0000 - len + 8 * (longint'($urandom_range(2)) - 1));
          end
          default: return 8 * $urandom_range(32'h0FFF_FFFF);
        endcase
      A_FLAGS: return $urandom_range(9) == 0 ? $urandom : $urandom_range(3);
      A_CTRL: return k < 6 ? {24'($urandom_range(31)), 4'd1, 3'($urandom), 1'b1} :
                     (k < 8 ? {24'($urandom), 4'($urandom), 3'($urandom), 1'($urandom)} : 32'h10);
      A_ERR: return k < 6 ? 32'h3F : $urandom;
      default: return $urandom;
    endcase
  endfunction

  int unsigned seed;
  longint n_cyc = 200000;

  initial begin
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("N_CYC=%d", n_cyc));
    void'($value$plusargs("PDONE=%d", pdone));
    void'($value$plusargs("PEV=%d", pev));
    $display("tb_gemv_acc_csr: P %0d NMAX %0d SEED %0d N_CYC %0d PDONE %0d PEV %0d", P, NMAX, seed,
             n_cyc, pdone, pev);
    model_reset();
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    for (longint i = 0; i < n_cyc; i++) begin
      @(posedge clk);
      begin
        automatic int a = addrs[$urandom_range(addrs.size() - 1)];
        automatic int k = $urandom_range(9);
        // more CTRL and descriptor writes than other ones
        if (k < 3) a = A_CTRL;
        else if (k < 5) a = A_ERR;
        wr_en   <= $urandom_range(2) == 0;
        wr_addr <= ADDR_W'(a + ($urandom_range(7) == 0 ? $urandom_range(3) : 0));
        wr_data <= rnd_val(a);
        rd_en   <= $urandom_range(1);
        rd_addr <= ADDR_W'(addrs[$urandom_range(addrs.size() - 1)] + $urandom_range(3));
        // done only while the model is busy at the next cycle's negedge: m_busy is the state
        // of the coming cycle (updated at the last negedge)
        done_i   <= m_busy && $urandom_range(99) < pdone;
        rd_err   <= $urandom_range(99) < pev / 3;
        wr_err   <= $urandom_range(99) < pev / 3;
        rd_stall <= $urandom_range(99) < pev;
        wr_stall <= $urandom_range(99) < pev;
        am_done  <= $urandom_range(99) < pev / 3;
        am_idx   <= $urandom;
        am_max   <= $urandom;
      end
    end
    @(posedge clk);
    wr_en <= 0; rd_en <= 0; done_i <= 0;
    repeat (2) @(posedge clk);
    $display("coverage: starts %0d, dones %0d, START_BUSY %0d (with bad op %0d), CTRL in done cycle start=0 %0d start=1 %0d, W1C vs set %0d, ERR sets %p",
             n_start, n_done, n_busy_start, n_badop_busy, n_ctrl_done0, n_ctrl_done1, n_w1c_set, n_err);
    if (n_start < 20 || n_busy_start == 0 || n_badop_busy == 0 || n_ctrl_done0 == 0 ||
        n_ctrl_done1 == 0 || n_w1c_set == 0)
      c_cov.fail("a collision / error case did not happen");
    else c_cov.pass();
    $display("starts with a buffer ending exactly at 2^32: W %0d X %0d Y %0d", n_edge[0], n_edge[1], n_edge[2]);
    foreach (n_edge[b]) if (n_edge[b] == 0) c_cov.fail($sformatf("2^32 edge %0d never tried", b)); else c_cov.pass();
    foreach (n_err[b]) if (n_err[b] == 0) c_cov.fail($sformatf("ERR bit %0d never set", b)); else c_cov.pass();
    void'(tb_final_report('{c_rd, c_ctl, c_op, c_cov}));
    $finish;
  end
endmodule
