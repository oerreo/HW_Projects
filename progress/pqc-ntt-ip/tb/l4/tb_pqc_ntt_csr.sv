// tb_pqc_ntt_csr: self-checking testbench of pqc_ntt_csr alone (L4).
//
// Reference: a cycle model of the register file written from
// docs/spec/l4_axi.md (register map, "decided behaviour", "L4 implementation
// results"), compared every cycle:
//   start_o (and op_o / bank_o when start_o = 1), s_valid_o (and s_data_o when
//   s_valid_o = 1), m_ready_o, rd_data_o in every rd_en_i cycle.
// The register state (done_sticky, ERR, CYCLES) is observed through reads
// only; reads are issued in about half of all cycles.
//   - a read sees the state before the write of the same cycle
//   - CTRL write: start accepted (start_o) when start = 1, op legal and
//     busy = 0; done_sticky cleared by every CTRL write except a start with an
//     illegal op; clear wins over done in the same cycle
//   - ERR set rules of the register map and the decided behaviour; a set wins
//     over a W1C of the same bit in the same cycle
//   - CYCLES = (done cycle) - (cycle the start was accepted), visible from the
//     cycle after done, saturating at 2^32 - 1
//   - DIN write = one stream handshake if in_ready, else dropped; DOUT read =
//     one pop if out_valid, else reads 0; address bits [1:0] ignored; other
//     addresses read 0, writes ignored; VERSION / CONFIG from the parameters
//   - reset values 0 (VERSION / CONFIG constant)
//
// Core side: a behavioural model of the ntt_core contract (rtl/l3/ntt_core.sv,
// rtl/l2/ntt_ctrl.sv headers) driven by the DUT outputs: start accepted only
// with busy = 0; busy from the cycle after the start until the op ends; done
// a one-cycle pulse in the first cycle with busy = 0 (a start in that cycle
// is accepted); result_bank updated with done (LOAD / UNLOAD bank, NTT / INTT
// ~bank, BASEMUL 0) and held; LOAD: s_ready = 1 for the whole op, done in the
// cycle after the last handshake; UNLOAD: m_valid from a one-entry read-ahead
// stage, m_data held while m_valid = 1 and no pop, done after the last pop.
// m_data changes randomly while m_valid = 0 (RAM output of other ops).
// Shortened ops: LOAD / UNLOAD move 1..WORDS_MAX words (the real core: 256)
// and NTT / INTT / BASEMUL stay busy 1..WAIT_MAX cycles (occasionally up to
// 200); the first LONG_OPS ops use the real lengths (256 words, CYCLES 904
// for NTT / INTT, 643 for BASEMUL with L = 0). The register file does not
// depend on these lengths.
//
// Register access stimulus: write and read strobes independent, each in about
// half of the cycles, back-to-back allowed; addresses biased to the
// registers with random bits [1:0], some unmapped addresses (ADDR_W > 5);
// CTRL data with random start / op (also illegal) / bank; DIN data partly
// >= Q; ERR data random. Address and data are random junk while the strobe is
// 0. Random resets (1..3 cycles) in the middle of ops.
// Directed: register reset values after reset; CYCLES saturation (the counter
// is forced to 2^32 - 16 during a long op, the model is moved by the same
// amount).
//
// Coverage: same-cycle collisions (done x CTRL write, done x accepted start,
// done x illegal start, ERR set x W1C of the same bit, read x write, ...) and
// every ERR bit; every counter must be non-zero, else FAIL.
//
// Plusargs: +SEED=<n> (1) +N_CYC=<n> (200000) +WORDS_MAX=<n> (8)
//           +WAIT_MAX=<n> (24) +LONG_OPS=<n> (5) +RST_RATE=<n> resets per
//           100000 cycles (20)
`timescale 1ns / 1ps

module tb_pqc_ntt_csr;
  import mlkem_pkg::*;
  import ntt_l2_pkg::*;
  import tb_util_pkg::*;

  parameter int ADDR_W       = 12;
  parameter int ALGO         = 0;
  parameter int PRE_REG      = 0;
  parameter int MUL_REG      = 0;
  parameter int RED_PIPE     = 0;
  parameter int OUT_REG      = 0;
  parameter int SHARE_ADDSUB = 0;
  parameter int ROM_OUT_REG  = 1;
  parameter int IMPL         = 0;
  parameter int FCLK_MHZ     = 100;

  localparam time T_CLK = 10ns;

  // constant registers, field positions of the l4_axi.md register map
  localparam logic [31:0] EXP_VERSION = (32'h4E54 << 16)
                                      | (32'(PRE_REG + MUL_REG + RED_PIPE + OUT_REG) << 8)
                                      | 32'(ALGO);
  localparam logic [31:0] EXP_CONFIG  = 32'(IMPL) | (32'(SHARE_ADDSUB) << 1) | (32'(ROM_OUT_REG) << 2)
                                      | (32'(PRE_REG) << 3) | (32'(MUL_REG) << 4)
                                      | (32'(RED_PIPE) << 5) | (32'(OUT_REG) << 7)
                                      | (32'(FCLK_MHZ) << 16);

  // word index of each register (byte offset / 4)
  localparam int R_CTRL = 0, R_STATUS = 1, R_DIN = 2, R_DOUT = 3, R_CYCLES = 4, R_VERSION = 5,
                 R_ERR = 6, R_CONFIG = 7, R_NONE = 8;

  logic              clk = 1'b0;
  logic              rst_n = 1'b0;
  logic              wr_en = 1'b0, rd_en = 1'b0;
  logic [ADDR_W-1:0] wr_addr = '0, rd_addr = '0;
  logic [31:0]       wr_data = '0, rd_data;
  logic              start, bank;
  op_e               op;
  logic              busy = 1'b0, done = 1'b0, result_bank = 1'b0;
  logic              s_valid, s_ready = 1'b0;
  logic [COEF_W-1:0] s_data;
  logic              m_valid = 1'b0, m_ready;
  logic [COEF_W-1:0] m_data = '0;

  pqc_ntt_csr #(
    .ADDR_W       (ADDR_W),
    .ALGO         (ALGO),
    .PRE_REG      (PRE_REG),
    .MUL_REG      (MUL_REG),
    .RED_PIPE     (RED_PIPE),
    .OUT_REG      (OUT_REG),
    .SHARE_ADDSUB (SHARE_ADDSUB),
    .ROM_OUT_REG  (ROM_OUT_REG),
    .IMPL         (IMPL),
    .FCLK_MHZ     (FCLK_MHZ)
  ) dut (
    .clk           (clk),
    .rst_n         (rst_n),
    .wr_en_i       (wr_en),
    .wr_addr_i     (wr_addr),
    .wr_data_i     (wr_data),
    .rd_en_i       (rd_en),
    .rd_addr_i     (rd_addr),
    .rd_data_o     (rd_data),
    .start_o       (start),
    .op_o          (op),
    .bank_o        (bank),
    .busy_i        (busy),
    .done_i        (done),
    .result_bank_i (result_bank),
    .s_valid_o     (s_valid),
    .s_ready_i     (s_ready),
    .s_data_o      (s_data),
    .m_valid_i     (m_valid),
    .m_ready_o     (m_ready),
    .m_data_i      (m_data)
  );

  always #(T_CLK / 2) clk = ~clk;

  tb_checker chk_cmd = new("cmd");
  tb_checker chk_s   = new("s_stream");
  tb_checker chk_m   = new("m_stream");
  tb_checker chk_rd  = new("rd_data");
  tb_checker chk_dir = new("dir");
  tb_checker chk_cov = new("cover");

  longint cov [string];
  string  cov_names [$] = '{"done_x_ctrl_wr", "done_x_start_acc", "done_x_bad_op_wr",
                            "done_x_ctrl_nostart", "err_set_x_w1c_same_bit", "rd_x_wr",
                            "rd_status_x_wr_ctrl", "rd_err_x_wr_err", "rd_cycles_x_done",
                            "rd_status_x_done", "rd_dout_x_wr_din", "err_start_busy", "err_din",
                            "err_dout", "err_bad_op", "err_din_range", "err_busy_bad_op",
                            "w1c_clear", "start_acc", "start_busy", "dout_pop", "din_acc",
                            "unload_stall", "rd_version", "rd_config", "rd_low_bits",
                            "wr_low_bits", "reset_mid_op", "cycles_sat", "cycles_long_op"};

  function automatic void cv(string n);
    if (cov.exists(n)) cov[n]++; else cov[n] = 1;
  endfunction

  // --------------------------------------------------------------------------
  // Core model (ntt_core contract), state for the next cycle
  // --------------------------------------------------------------------------
  typedef enum int { C_IDLE, C_LOAD, C_UNLOAD, C_XF } cst_e;
  cst_e              c_st = C_IDLE;
  int                c_cnt = 0, c_n = 0, c_wait = 0;
  bit                c_bank = 0, c_ovld = 0, c_done = 0, c_rb = 0;
  op_e               c_op = OP_LOAD;
  logic [COEF_W-1:0] c_data = '0;
  int                words_max = 8, wait_max = 24, long_ops = 5, force_wait = 0;

  function automatic int pick_words();
    if (long_ops > 0) return N_COEF;
    return $urandom_range(1, words_max);
  endfunction

  function automatic int pick_wait(op_e o);
    int w;
    if (force_wait > 0) begin w = force_wait; force_wait = 0; return w; end
    if (long_ops > 0) return (o == OP_BASEMUL) ? 642 : 903;
    if ($urandom_range(99) < 5) return $urandom_range(60, 200);
    return $urandom_range(1, wait_max);
  endfunction

  function automatic void core_reset();
    c_st = C_IDLE; c_cnt = 0; c_ovld = 0; c_done = 0; c_rb = 0;
  endfunction

  // next state from the DUT outputs of the current cycle
  function automatic void core_step(bit st, op_e o, bit bk, bit sv, bit mr);
    bit ul_rd, fin;
    c_done = 0;
    case (c_st)
      C_IDLE: if (st) begin
        c_bank = bk; c_op = o; c_cnt = 0; c_ovld = 0;
        case (o)
          OP_LOAD:   begin c_st = C_LOAD;   c_n = pick_words(); end
          OP_UNLOAD: begin c_st = C_UNLOAD; c_n = pick_words(); end
          default:   begin c_st = C_XF;     c_wait = pick_wait(o); end
        endcase
        if (long_ops > 0) long_ops--;
      end
      C_LOAD: if (sv) begin
        c_cnt++;
        if (c_cnt == c_n) begin c_st = C_IDLE; c_done = 1; c_rb = c_bank; end
      end
      C_UNLOAD: begin
        ul_rd = (c_cnt != c_n) && (!c_ovld || mr);
        fin   = (c_cnt == c_n) && (!c_ovld || mr);
        if (ul_rd) begin c_cnt++; c_ovld = 1; c_data = COEF_W'($urandom); end
        else if (mr) c_ovld = 0;
        if (fin) begin c_st = C_IDLE; c_done = 1; c_rb = c_bank; c_ovld = 0; end
      end
      C_XF: begin
        if (c_wait <= 1) begin
          c_st = C_IDLE; c_done = 1; c_rb = (c_op == OP_BASEMUL) ? 1'b0 : !c_bank;
        end else c_wait--;
      end
    endcase
    // RAM output of other activity while no word is offered
    if (!c_ovld && $urandom_range(3) == 0) c_data = COEF_W'($urandom);
  endfunction

  // --------------------------------------------------------------------------
  // Register file reference model and per-cycle check (negedge)
  // --------------------------------------------------------------------------
  longint      cyc = 0;            // index of the cycle being checked
  bit          m_done = 0;
  logic [4:0]  m_err = '0;
  logic [31:0] m_cycles = '0;
  longint      m_tacc = 0;
  bit          m_tacc_valid = 0;
  longint      n_acc_wr = 0, n_acc_rd = 0, n_start = 0, n_done = 0, n_rst = 0;
  logic [31:0] last_rd_data;
  int          last_rd_idx = -1;

  function automatic int reg_idx(logic [ADDR_W-1:0] a);
    longint unsigned w = longint'(a) >> 2;
    return (w < 8) ? int'(w) : R_NONE;
  endfunction

  function automatic void chk(tb_checker c, bit ok, string msg);
    if (ok) c.pass(); else c.fail($sformatf("cyc %0d: %s", cyc, msg));
  endfunction

  always @(negedge clk) begin
    bit          we, re, wctrl, wdin, werr, rdout, st_bit, legal, e_start, e_sv, e_mr;
    int          widx, ridx;
    logic [31:0] wd, e_rd;
    logic [4:0]  set, clr;
    longint      d;
    last_rd_idx = -1;
    if (rst_n !== 1'b1) begin
      m_done = 0; m_err = '0; m_cycles = '0; m_tacc_valid = 0;
      core_reset();
      chk(chk_cmd, start === 1'b0, "start_o in reset");
      chk(chk_s, s_valid === 1'b0, "s_valid_o in reset");
      chk(chk_m, m_ready === 1'b0, "m_ready_o in reset");
    end else begin
      we    = (wr_en === 1'b1);
      re    = (rd_en === 1'b1);
      wd    = wr_data;
      widx  = reg_idx(wr_addr);
      ridx  = reg_idx(rd_addr);
      wctrl = we && widx == R_CTRL;
      wdin  = we && widx == R_DIN;
      werr  = we && widx == R_ERR;
      rdout = re && ridx == R_DOUT;
      st_bit  = wd[0];
      legal   = (wd[3:1] <= 3'd4);
      e_start = wctrl && st_bit && legal && !busy;
      e_sv    = wdin && s_ready;
      e_mr    = rdout && m_valid;

      // ---- outputs ----
      chk(chk_cmd, start === e_start, $sformatf("start_o %b expected %b (wr_en %b addr %h data %h busy %b)",
                                                start, e_start, wr_en, wr_addr, wd, busy));
      if (e_start)
        chk(chk_cmd, op === op_e'(wd[3:1]) && bank === wd[4],
            $sformatf("op_o %0d bank_o %b, expected %0d %b", op, bank, wd[3:1], wd[4]));
      chk(chk_s, s_valid === e_sv, $sformatf("s_valid_o %b expected %b (DIN write %b s_ready %b)",
                                             s_valid, e_sv, wdin, s_ready));
      if (e_sv) chk(chk_s, s_data === wd[COEF_W-1:0],
                    $sformatf("s_data_o %h expected %h", s_data, wd[COEF_W-1:0]));
      chk(chk_m, m_ready === e_mr, $sformatf("m_ready_o %b expected %b (DOUT read %b m_valid %b)",
                                             m_ready, e_mr, rdout, m_valid));
      if (re) begin
        case (ridx)
          R_STATUS:  e_rd = {27'd0, m_valid, s_ready, result_bank, m_done, busy};
          R_DOUT:    e_rd = m_valid ? {20'd0, m_data} : 32'd0;
          R_CYCLES:  e_rd = m_cycles;
          R_VERSION: e_rd = EXP_VERSION;
          R_ERR:     e_rd = {27'd0, m_err};
          R_CONFIG:  e_rd = EXP_CONFIG;
          default:   e_rd = 32'd0;
        endcase
        chk(chk_rd, rd_data === e_rd, $sformatf("read addr %h (reg %0d): got %h expected %h",
                                               rd_addr, ridx, rd_data, e_rd));
        last_rd_idx  = ridx;
        last_rd_data = rd_data;
      end

      // ---- coverage ----
      if (we) n_acc_wr++;
      if (re) n_acc_rd++;
      if (done) n_done++;
      if (done && wctrl) cv("done_x_ctrl_wr");
      if (done && e_start) cv("done_x_start_acc");
      if (done && wctrl && st_bit && !legal) cv("done_x_bad_op_wr");
      if (done && wctrl && !st_bit) cv("done_x_ctrl_nostart");
      if (re && we) cv("rd_x_wr");
      if (re && ridx == R_STATUS && wctrl) cv("rd_status_x_wr_ctrl");
      if (re && ridx == R_ERR && werr) cv("rd_err_x_wr_err");
      if (re && ridx == R_CYCLES && done) cv("rd_cycles_x_done");
      if (re && ridx == R_STATUS && done) cv("rd_status_x_done");
      if (rdout && wdin) cv("rd_dout_x_wr_din");
      if (re && ridx == R_VERSION) cv("rd_version");
      if (re && ridx == R_CONFIG) cv("rd_config");
      if (re && ridx != R_NONE && rd_addr[1:0] != 2'b00) cv("rd_low_bits");
      if (we && widx != R_NONE && wr_addr[1:0] != 2'b00) cv("wr_low_bits");
      if (re && ridx == R_NONE) cv("unmapped_rd");
      if (we && widx == R_NONE) cv("unmapped_wr");
      if (e_start) begin cv("start_acc"); n_start++; end
      if (wctrl && st_bit && busy) cv("start_busy");
      if (e_mr) cv("dout_pop");
      if (e_sv) cv("din_acc");
      if (m_valid && !e_mr) cv("unload_stall");

      // ---- next state ----
      set    = '0;
      set[0] = wctrl && st_bit && busy;
      set[1] = wdin && !s_ready;
      set[2] = rdout && !m_valid;
      set[3] = wctrl && st_bit && !legal;
      set[4] = e_sv && (wd[COEF_W-1:0] >= COEF_W'(Q));
      clr    = werr ? wd[4:0] : 5'd0;
      if (set[0]) cv("err_start_busy");
      if (set[1]) cv("err_din");
      if (set[2]) cv("err_dout");
      if (set[3]) cv("err_bad_op");
      if (set[4]) cv("err_din_range");
      if (set[0] && set[3]) cv("err_busy_bad_op");
      if ((set & clr) != 0) cv("err_set_x_w1c_same_bit");
      if ((m_err & clr) != 0) cv("w1c_clear");
      m_err = (m_err & ~clr) | set;

      if (wctrl && !(st_bit && !legal)) m_done = 0;
      else if (done)                    m_done = 1;

      if (done) begin
        if (!m_tacc_valid) chk(chk_cmd, 0, "done_i without an accepted start (TB core model)");
        d = cyc - m_tacc;
        if (d >= 64'h0000_0000_FFFF_FFFF) begin m_cycles = 32'hFFFF_FFFF; cv("cycles_sat"); end
        else m_cycles = 32'(d);
        if (d == 904 || d == 643) cv("cycles_long_op");
      end
      if (e_start) begin m_tacc = cyc; m_tacc_valid = 1; end

      // core model next state, from the DUT outputs (equal to the model when the checks pass)
      core_step(start === 1'b1, op, bank === 1'b1, s_valid === 1'b1, m_ready === 1'b1);
    end
    cyc++;
  end

  // --------------------------------------------------------------------------
  // Stimulus (one call per cycle, at posedge)
  // --------------------------------------------------------------------------
  int rst_rate = 20, rst_hold = 0;

  function automatic logic [ADDR_W-1:0] mk_addr(int idx);
    logic [ADDR_W-1:0] a;
    if (idx == R_NONE && ADDR_W > 5) begin
      a = ADDR_W'({$urandom, $urandom});
      if ((longint'(a) >> 2) < 8) a = a | ADDR_W'(64'd32);   // word index >= 8
      return a;
    end
    if (idx == R_NONE) idx = $urandom_range(7);
    return ADDR_W'(idx * 4 + $urandom_range(3));
  endfunction

  function automatic int pick(int w [9]);
    int s = 0, k;
    foreach (w[i]) s += w[i];
    k = $urandom_range(s - 1);
    foreach (w[i]) begin
      if (k < w[i]) return i;
      k -= w[i];
    end
    return 0;
  endfunction

  function automatic logic [31:0] mk_wdata(int idx);
    logic [31:0] r = $urandom;
    logic [2:0]  o;
    case (idx)
      R_CTRL: begin
        o = ($urandom_range(99) < 75) ? 3'($urandom_range(4)) : 3'($urandom_range(5, 7));
        r[0]   = ($urandom_range(99) < 85);
        r[3:1] = o;
      end
      R_DIN: r[11:0] = ($urandom_range(99) < 85) ? 12'($urandom_range(Q - 1))
                                                 : 12'($urandom_range(Q, 4095));
      default: ;
    endcase
    return r;
  endfunction

  // drive the core model outputs and one register access cycle
  task automatic drive(bit we, int widx, logic [31:0] wd, bit re, int ridx);
    busy        <= (c_st != C_IDLE);
    done        <= c_done;
    result_bank <= c_rb;
    s_ready     <= (c_st == C_LOAD);
    m_valid     <= c_ovld;
    m_data      <= c_data;
    wr_en       <= we;
    wr_addr     <= we ? mk_addr(widx) : ADDR_W'({$urandom, $urandom});
    wr_data     <= we ? wd : $urandom;
    rd_en       <= re;
    rd_addr     <= re ? mk_addr(ridx) : ADDR_W'({$urandom, $urandom});
  endtask

  task automatic rand_cycle();
    int  widx, ridx;
    bit  we, re;
    //                  CTRL STAT DIN DOUT CYC VER ERR CONF NONE
    int  ww [9]    = '{ 25,   4,  15,   4,  4,  4,  20,  4,  15 };
    int  rw [9]    = '{  5,  20,   5,  20, 15,  5,  15,  5,  10 };
    @(posedge clk);
    if (rst_hold > 0) begin
      rst_hold--;
      if (rst_hold == 0) rst_n <= 1'b1;
      busy <= 0; done <= 0; result_bank <= 0; s_ready <= 0; m_valid <= 0;
      wr_en <= 0; rd_en <= 0;
      return;
    end
    if ($urandom_range(99_999) < rst_rate) begin
      rst_n    <= 1'b0;
      rst_hold = $urandom_range(1, 3);
      n_rst++;
      if (c_st != C_IDLE) cv("reset_mid_op");
      busy <= 0; done <= 0; result_bank <= 0; s_ready <= 0; m_valid <= 0;
      wr_en <= 0; rd_en <= 0;
      return;
    end
    we   = ($urandom_range(99) < 45);
    re   = ($urandom_range(99) < 50);
    widx = (c_st == C_LOAD && $urandom_range(1)) ? R_DIN : pick(ww);
    ridx = (c_st == C_UNLOAD && $urandom_range(1)) ? R_DOUT : pick(rw);
    drive(we, widx, mk_wdata(widx), re, ridx);
  endtask

  task automatic reset_dut(int n);
    @(posedge clk);
    rst_n <= 1'b0;
    busy <= 0; done <= 0; result_bank <= 0; s_ready <= 0; m_valid <= 0; wr_en <= 0; rd_en <= 0;
    repeat (n) @(posedge clk);
    rst_n <= 1'b1;
    // the model state is reset at the negedges with rst_n = 0
  endtask

  // read every register index once (reset values right after a reset)
  task automatic read_all();
    for (int i = 0; i <= R_NONE; i++) begin
      @(posedge clk);
      drive(0, 0, 0, 1, i);
    end
  endtask

  task automatic idle_cycle(bit re = 0, int ridx = 0);
    @(posedge clk);
    drive(0, 0, 0, re, ridx);
  endtask

  // --------------------------------------------------------------------------
  // Main
  // --------------------------------------------------------------------------
  initial begin
    int unsigned seed;
    int          n_cyc;
    longint      t0;
    bit          ok;
    n_cyc = 200000;
    seed  = tb_seed_from_plusarg();
    void'($value$plusargs("N_CYC=%d", n_cyc));
    void'($value$plusargs("WORDS_MAX=%d", words_max));
    void'($value$plusargs("WAIT_MAX=%d", wait_max));
    void'($value$plusargs("LONG_OPS=%d", long_ops));
    void'($value$plusargs("RST_RATE=%d", rst_rate));
    $display("tb_pqc_ntt_csr: ADDR_W=%0d ALGO=%0d PRE=%0d MUL=%0d RED=%0d OUT=%0d SHARE=%0d ROM=%0d IMPL=%0d FCLK=%0d",
             ADDR_W, ALGO, PRE_REG, MUL_REG, RED_PIPE, OUT_REG, SHARE_ADDSUB, ROM_OUT_REG, IMPL, FCLK_MHZ);
    $display("  SEED=%0d N_CYC=%0d WORDS_MAX=%0d WAIT_MAX=%0d LONG_OPS=%0d RST_RATE=%0d/100000",
             seed, n_cyc, words_max, wait_max, long_ops, rst_rate);
    $display("  expected VERSION=%h CONFIG=%h", EXP_VERSION, EXP_CONFIG);

    reset_dut(3);
    read_all();

    // random phase (the first LONG_OPS ops have the real lengths)
    t0 = cyc;
    repeat (n_cyc) rand_cycle();
    while (rst_hold > 0) rand_cycle();
    $display("random phase: %0d cycles, %0d writes, %0d reads, %0d starts accepted, %0d done, %0d resets",
             cyc - t0, n_acc_wr, n_acc_rd, n_start, n_done, n_rst);

    // directed: reset values, then CYCLES saturation
    reset_dut(2);
    read_all();
    force_wait = 100;
    @(posedge clk);
    drive(1, R_CTRL, 32'h0000_0003, 0, 0);          // start NTT, bank 0
    repeat (5) idle_cycle();
    @(negedge clk);
    #1;
    chk(chk_dir, c_st == C_XF && busy === 1'b1, "saturation test: core not busy");
    force dut.cnt_q = 32'hFFFF_FFF0;
    #1;
    release dut.cnt_q;
    m_tacc = (cyc - 1) - 64'h0000_0000_FFFF_FFF0;   // counter value of the current cycle
    while (c_st != C_IDLE) idle_cycle(1, R_CYCLES);
    repeat (3) idle_cycle(1, R_CYCLES);
    @(negedge clk);
    #1;
    chk(chk_dir, last_rd_idx == R_CYCLES && last_rd_data === 32'hFFFF_FFFF,
        $sformatf("saturation test: CYCLES read %h", last_rd_data));
    // next op is counted from 1 again
    @(posedge clk);
    drive(1, R_CTRL, 32'h0000_0005, 0, 0);          // start INTT, bank 0
    while (c_st == C_IDLE) idle_cycle();
    while (c_st != C_IDLE) idle_cycle();
    repeat (2) idle_cycle(1, R_CYCLES);
    @(negedge clk);
    #1;
    chk(chk_dir, last_rd_idx == R_CYCLES && last_rd_data != 32'hFFFF_FFFF && last_rd_data > 0,
        $sformatf("after saturation: CYCLES read %h", last_rd_data));
    $display("saturation test: CYCLES after the forced counter = FFFFFFFF, next op = %0d", last_rd_data);
    repeat (3) idle_cycle();

    // coverage
    if (ADDR_W > 5) begin
      cov_names.push_back("unmapped_rd");
      cov_names.push_back("unmapped_wr");
    end
    foreach (cov_names[i]) begin
      longint v;
      v = cov.exists(cov_names[i]) ? cov[cov_names[i]] : 0;
      $display("COVER %-24s %0d", cov_names[i], v);
      if (v > 0) chk_cov.pass(); else chk_cov.fail($sformatf("coverage item %s never hit", cov_names[i]));
    end

    ok = tb_final_report('{chk_cmd, chk_s, chk_m, chk_rd, chk_dir, chk_cov});
    $finish;
  end

  initial begin
    #(T_CLK * 64'd50_000_000);
    $display("MISMATCH [watchdog] simulation did not finish");
    $display("TB_RESULT: FAIL");
    $finish;
  end

endmodule
