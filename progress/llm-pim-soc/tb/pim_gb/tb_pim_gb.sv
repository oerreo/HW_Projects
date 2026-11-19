// tb_pim_gb: pim_gb (rtl/l1/pim_gb.sv) alone. Golden: the global buffer of model/src/bank.c
// bank_gemv is x copied into gbuf (int8 [n]); a word w of the buffer is gbuf[16 w .. 16 w + 15]
// with 0 beyond n (arch.md 3.3 WRGB "rest 0"). The expected word is built from the TB's x array
// (the RTL is not used to form expectations).
// Each load: random n (1..NMAX, corners 1, 7, 8, 9, 15, 16, 17, NMAX - 1, NMAX), random x, garbage
// in the lanes >= n of the last beat, random gaps on wr_valid_i (+GAP percent), then every word
// 0..NMAX/16 - 1 is read in random order (random read gaps) and compared at negedge (read latency 1).
// Checks: wr_ready_o only while busy, busy/done timing (done_o in the last beat handshake, busy_o
// low after it), beats offered after the load are not taken, a smaller load after a larger one
// hides the old contents. +NEG=1: load_i during a load (PIM_GB_LOAD expected once).
// Plusargs: +SEED +NLOAD +GAP +NEG
`timescale 1ns / 1ps
module tb_pim_gb #(
  parameter int NMAX = 1024
);
  import tb_util_pkg::*;
  import llm_pkg::*;

  localparam int NW = $clog2(NMAX + 1), NWD = NMAX / 16, GA = $clog2(NWD);

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic           load = 0, wv = 0, re = 0;
  logic [NW-1:0]  n = 0;
  logic [63:0]    wd = 0;
  logic [GA-1:0]  ra = 0;
  logic           busy, done, wr_ready;
  logic [127:0]   rw;

  pim_gb #(.NMAX(NMAX), .LB(16)) dut (
    .clk, .rst_n, .load_i(load), .n_i(n), .busy_o(busy), .done_o(done),
    .wr_valid_i(wv), .wr_ready_o(wr_ready), .wr_data_i(wd),
    .rd_en_i(re), .rd_addr_i(ra), .rd_word_o(rw));

  tb_checker c_word = new("word"), c_ctl = new("control");

  byte xv[];      // current x (n elements)
  int  cur_n = 0;

  function automatic logic [127:0] exp_word(int w);
    logic [127:0] e = '0;
    for (int l = 0; l < 16; l++) if (16 * w + l < cur_n) e[8*l +: 8] = xv[16 * w + l];
    return e;
  endfunction

  int gap = 20;

  task automatic do_load(int nn, bit neg);
    int nb = (nn + 7) / 8;
    @(posedge clk);
    load <= 1'b1;
    n    <= NW'(nn);
    @(posedge clk);
    load <= 1'b0;
    n    <= NW'($urandom);
    xv = new[nn];
    foreach (xv[i]) xv[i] = byte'($urandom);
    cur_n = nn;
    @(negedge clk);
    if (busy !== 1'b1 || wr_ready !== 1'b1) c_ctl.fail($sformatf("n %0d: busy %b ready %b after load", nn, busy, wr_ready));
    else c_ctl.pass();
    for (int j = 0; j < nb; j++) begin
      logic [63:0] d;
      for (int l = 0; l < 8; l++) d[8*l +: 8] = (8 * j + l < nn) ? xv[8 * j + l] : 8'($urandom);
      while ($urandom_range(99) < gap) begin
        @(posedge clk);
        wv <= 1'b0;
        wd <= $urandom;
      end
      @(posedge clk);
      wv <= 1'b1;
      wd <= d;
      if (neg && j == nb / 2) begin            // negative test: load during a load
        load <= 1'b1;
        n    <= NW'(nn);
      end
      @(negedge clk);
      if (neg && j == nb / 2) begin
        @(posedge clk);
        load <= 1'b0;
        return;
      end
      if (done !== (j == nb - 1)) c_ctl.fail($sformatf("n %0d beat %0d: done %b", nn, j, done));
      else c_ctl.pass();
    end
    @(posedge clk);
    wv <= $urandom_range(1);   // beats after the load must not be taken
    wd <= $urandom;
    @(negedge clk);
    if (busy !== 1'b0 || wr_ready !== 1'b0 || done !== 1'b0)
      c_ctl.fail($sformatf("n %0d: busy %b ready %b done %b after the last beat", nn, busy, wr_ready, done));
    else c_ctl.pass();
    @(posedge clk);
    wv <= 1'b0;
  endtask

  task automatic read_all();
    int ord[] = new[NWD];
    foreach (ord[i]) ord[i] = i;
    ord.shuffle();
    foreach (ord[k]) begin
      repeat ($urandom_range(2) == 0 ? $urandom_range(3) : 0) begin
        @(posedge clk);
        re <= 1'b0;
        ra <= GA'($urandom);
      end
      @(posedge clk);
      re <= 1'b1;
      ra <= GA'(ord[k]);
      @(posedge clk);
      re <= 1'b0;
      ra <= GA'($urandom);
      @(negedge clk);
      if (rw !== exp_word(ord[k])) c_word.fail($sformatf("n %0d word %0d: %h, expected %h", cur_n, ord[k], rw, exp_word(ord[k])));
      else c_word.pass();
      // the output holds without a read
      @(negedge clk);
      if (rw !== exp_word(ord[k])) c_word.fail($sformatf("n %0d word %0d not held: %h", cur_n, ord[k], rw));
      else c_word.pass();
    end
  endtask

  int unsigned seed;
  int nload = 200, neg = 0;
  int corner[] = '{1, 7, 8, 9, 15, 16, 17, NMAX - 1, NMAX, 1, NMAX};

  initial begin
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("NLOAD=%d", nload));
    void'($value$plusargs("GAP=%d", gap));
    void'($value$plusargs("NEG=%d", neg));
    $display("tb_pim_gb: NMAX %0d SEED %0d NLOAD %0d GAP %0d NEG %0d", NMAX, seed, nload, gap, neg);
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);
    if (neg) begin
      do_load(NMAX, 1);
      repeat (5) @(posedge clk);
      void'(tb_final_report('{c_ctl}));
      $finish;
    end
    for (int i = 0; i < nload; i++) begin
      automatic int nn = (i < corner.size()) ? corner[i] : ($urandom_range(3) == 0 ? $urandom_range(48, 1) : $urandom_range(NMAX, 1));
      do_load(nn, 0);
      read_all();
    end
    void'(tb_final_report('{c_word, c_ctl}));
    $finish;
  end

  initial begin
    #1s;
    $error("TB_TIMEOUT global");
    $finish;
  end
endmodule
