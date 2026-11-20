// tb_rsqrt_nr: rsqrt_nr against the golden k_rsqrt(u, &re) through DPI-C (kd_rsqrt).
// Table: every entry of lut_pkg::RSQ_TAB == k_rsq_lut (kd_rsq_lut).
// Inputs (all compared with rm and re):
//   edges   : u = 0, 1, 2, 3, 2^U_W - 1; for every bit length k = 1..U_W: 2^(k-1), 2^k - 1
//   per bit : +NPER random u of every bit length (the make test t_rsqrt pattern, 4000 there)
//   seed    : every seed index i = 0..47 at its edges mn = (16 + i) 2^26, + 1, (17 + i) 2^26 - 1,
//             shifted to every even t the width allows (u = mn << t, or mn >> -t)
//   random  : +N u with a random bit length (uniform over 1..U_W) and random lower bits
// Handshake (every op): start in cycle c -> busy_o 1 in c+1 .. c+14 and 0 otherwise, done_o
// exactly in c + 15 (CYCLES), rm_o / re_o hold from the done cycle until the next accepted start.
// The next start comes 0..3 cycles after the done cycle (0: in the done cycle itself).
// +NEG=1: three starts while busy (ignored, RSQ_START each).
// Inputs change at posedge (non-blocking), checks at negedge. Watchdog: TB_TIMEOUT.
`timescale 1ns / 1ps
module tb_rsqrt_nr;
  import tb_util_pkg::*;
  import kdpi_pkg::*;
  import llm_pkg::*;

  parameter int U_W = 42;
  localparam int CYC = 15;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic                  start_i = 1'b0, done_o, busy_o;
  logic [U_W-1:0]        u_i = '0;
  logic [16:0]           rm_o;
  logic signed [E_W-1:0] re_o;

  rsqrt_nr #(.U_W(U_W)) dut (.clk, .rst_n, .start_i, .u_i, .rm_o, .re_o, .done_o, .busy_o);

  tb_checker c_tab = new("table"), c_val = new("value"), c_hs = new("handshake"),
             c_hold = new("hold");

  // ---------------- monitor (negedge) ----------------
  longint cyc = 0, t_acc = -1, t_done = -1, n_acc = 0;
  logic [U_W-1:0] u_acc;
  int   e_rm, e_re;
  bit   have = 0;   // a result is held (after the first done)
  always @(negedge clk) begin
    cyc++;
    if (rst_n) begin
      automatic bit exp_busy = t_acc >= 0 && cyc > t_acc && cyc < t_acc + CYC;
      if (busy_o !== exp_busy) c_hs.fail($sformatf("busy_o %b exp %b at %0d (start %0d)", busy_o, exp_busy, cyc, t_acc));
      else c_hs.pass();
      if (done_o !== (cyc == t_done)) c_hs.fail($sformatf("done_o %b at %0d, done expected at %0d", done_o, cyc, t_done));
      else c_hs.pass();
      if (cyc == t_done) begin
        if (int'(rm_o) !== e_rm || int'(re_o) !== e_re)
          c_val.fail($sformatf("u %0d (0x%0h): rm %0d re %0d, golden %0d %0d", u_acc, u_acc, rm_o, re_o, e_rm, e_re));
        else c_val.pass();
        have = 1;
      end else if (have && t_done >= 0 && cyc > t_done) begin
        if (int'(rm_o) !== e_rm || int'(re_o) !== e_re) c_hold.fail($sformatf("result changed at %0d", cyc));
        else c_hold.pass();
      end
      if (start_i === 1'b1 && busy_o === 1'b0) begin   // accepted start in this cycle
        automatic int re;
        if (t_done >= 0 && cyc < t_done) c_hs.fail("start accepted before done");
        u_acc  = u_i;
        e_rm   = kd_rsqrt(longint'(u_i), re);
        e_re   = re;
        t_acc  = cyc;
        t_done = cyc + CYC;
        have   = 0;
        n_acc++;
      end
    end
  end

  // ---------------- driver ----------------
  int neg = 0, n_neg = 0;
  task automatic op(longint unsigned u);
    int gap = $urandom_range(3);
    start_i <= 1'b1;
    u_i     <= U_W'(u);
    @(posedge clk);
    start_i <= 1'b0;
    u_i     <= U_W'({$urandom(), $urandom()});
    for (int k = 1; k < CYC + gap; k++) begin
      if (neg && n_neg < 3 && k == 5 && $urandom_range(9) == 0) begin
        start_i <= 1'b1;               // while busy: ignored (RSQ_START)
        n_neg++;
      end else start_i <= 1'b0;
      @(posedge clk);
    end
    start_i <= 1'b0;
  endtask

  function automatic longint unsigned rnd_bits(int L);   // random value of bit length L >= 1
    longint unsigned r = {$urandom(), $urandom()};
    if (L >= 64) return r;
    return (64'd1 << (L - 1)) | (r & ((64'd1 << (L - 1)) - 1));
  endfunction

  initial begin
    automatic int unsigned seed;
    automatic int n = 1000000, nper = 4000;
    automatic longint unsigned umax = (U_W >= 64) ? '1 : ((64'd1 << U_W) - 1);
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("N=%d", n));
    void'($value$plusargs("NPER=%d", nper));
    void'($value$plusargs("NEG=%d", neg));
    $display("tb_rsqrt_nr: U_W %0d seed %0d N %0d NPER %0d NEG %0d", U_W, seed, n, nper, neg);
    for (int i = 0; i < 48; i++)
      if (int'(lut_pkg::RSQ_TAB[i]) !== kd_rsq_lut(i))
        c_tab.fail($sformatf("entry %0d: %0d golden %0d", i, lut_pkg::RSQ_TAB[i], kd_rsq_lut(i)));
      else c_tab.pass();
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    @(posedge clk);
    // edges
    op(0); op(1); op(2); op(3); op(umax);
    for (int k = 1; k <= U_W; k++) begin
      op(64'd1 << (k - 1));
      op((k >= 64) ? '1 : (64'd1 << k) - 1);
    end
    // seed index edges at every even t
    for (int t = -30; t <= U_W - 32; t += 2)
      for (int i = 0; i < 48; i++) begin
        automatic longint unsigned mns[3] = '{(64'd16 + i) << 26, ((64'd16 + i) << 26) + 1,
                                              ((64'd17 + i) << 26) - 1};
        foreach (mns[j]) op(t >= 0 ? mns[j] << t : mns[j] >> (-t));
      end
    // every bit length
    for (int k = 1; k <= U_W; k++)
      for (int i = 0; i < nper; i++) op(rnd_bits(k));
    // random
    for (int i = 0; i < n; i++) op(rnd_bits($urandom_range(U_W, 1)));
    repeat (CYC + 5) @(posedge clk);
    $display("tb_rsqrt_nr: %0d ops, %0d starts while busy", n_acc, n_neg);
    if (neg && n_neg != 3) c_hs.fail($sformatf("%0d starts while busy, 3 expected", n_neg));
    void'(tb_final_report('{c_tab, c_val, c_hs, c_hold}));
    $finish;
  end

  // watchdog
  initial begin
    static longint unsigned lim = 64'd400_000_000;
    void'($value$plusargs("TIMEOUT=%d", lim));
    repeat (lim) @(posedge clk);
    $fatal(1, "TB_TIMEOUT tb_rsqrt_nr");
  end

endmodule
