// tb_umul_seq: umul_seq against the exact integer product (128-bit TB arithmetic).
//
// Every operation: start in cycle c (random gap 0..3 cycles after the previous done; gap 0 =
// start in the done cycle), then done_o must be a 1-cycle pulse in exactly c + CYCLES with
// p_o == a * b, busy_o must be 1 exactly in c+1 .. c+B_W, and p_o must hold its value from
// done until the next start. The operand inputs get random values in every cycle except the
// start cycle (sampled only then).
// Vectors:
//   directed: a and b from {0, 1, 2, max - 1, max, 2^k, 2^k - 1, 2^k + 1, alternating bits},
//             every pair
//   random  : +N operations (random magnitudes of a and b, 1/16 each forced to 0 or max)
//   exhaustive (+EXH=1, small parameters only): every (a, b)
//   negative (+NEG=<k>): 1 start while busy (UMUL_START, ignored: the running product must
//             still be correct), 2 X on an operand of a start (UMUL_X)
// Plusargs: +SEED=<n> +N=<n> +EXH=1 +NEG=<k>.
`timescale 1ns / 1ps
module tb_umul_seq;
  import tb_util_pkg::*;

  parameter int A_W = 25;
  parameter int B_W = 9;
  localparam int CYCLES = B_W + 1;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic                 start_i = 1'b0, done_o, busy_o;
  logic [A_W-1:0]       a_i = '0;
  logic [B_W-1:0]       b_i = '0;
  logic [A_W+B_W-1:0]   p_o;

  umul_seq #(.A_W(A_W), .B_W(B_W)) dut (
    .clk, .rst_n, .start_i, .a_i, .b_i, .p_o, .done_o, .busy_o);

  tb_checker c_dir = new("directed"), c_rnd = new("random"), c_exh = new("exhaustive"),
             c_tim = new("timing"), c_hold = new("hold");

  longint unsigned cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  typedef logic [127:0] u128;
  typedef struct { u128 a, b, p; longint unsigned t0; int kind; } op_t;
  op_t cur;
  bit  have_res = 0, mute = 0;
  logic [A_W+B_W-1:0] last_p;
  longint unsigned n_ops = 0;

  localparam u128 AMAX = (u128'(1) << A_W) - 1;
  localparam u128 BMAX = (u128'(1) << B_W) - 1;

  function automatic tb_checker ck(int kind);
    return kind == 0 ? c_dir : (kind == 1 ? c_rnd : c_exh);
  endfunction

  // monitor at negedge (ops queue: a new op may start in the done cycle of the previous one)
  op_t ops[$];
  always @(negedge clk) begin
    if (rst_n && !mute) begin
      automatic bit busy_exp = 0;
      foreach (ops[i]) if (cyc >= ops[i].t0 + 1 && cyc <= ops[i].t0 + B_W) busy_exp = 1;
      if (busy_o !== busy_exp) c_tim.fail($sformatf("cycle %0d busy_o %b exp %b", cyc, busy_o, busy_exp));
      if (ops.size() > 0 && cyc == ops[0].t0 + CYCLES) begin
        automatic op_t o = ops.pop_front();
        if (done_o !== 1'b1) c_tim.fail($sformatf("no done at %0d (a %0d b %0d)", cyc, o.a, o.b));
        else c_tim.pass();
        if (u128'(p_o) !== o.p)
          ck(o.kind).fail($sformatf("%0d * %0d: got %0d exp %0d", o.a, o.b, p_o, o.p));
        else ck(o.kind).pass();
        last_p   = p_o;
        have_res = 1;
      end else if (done_o !== 1'b0) c_tim.fail($sformatf("unexpected done_o %b at %0d", done_o, cyc));
      else if (have_res && (ops.size() == 0 || cyc <= ops[0].t0)) begin
        if (p_o !== last_p) c_hold.fail($sformatf("p_o changed while idle at %0d", cyc));
        else c_hold.pass();
      end
    end
  end

  function automatic u128 rnd128();
    return {$urandom(), $urandom(), $urandom(), $urandom()};
  endfunction
  function automatic u128 rbits(int b);
    return b <= 0 ? u128'(0) : (b >= 128 ? rnd128() : (rnd128() & ((u128'(1) << b) - 1)));
  endfunction

  // one multiplication: start at the next posedge after a gap; returns at the start of the
  // done cycle
  task automatic mul(u128 a, u128 b, int kind, int gap = -1);
    int g = gap >= 0 ? gap : ($urandom_range(3) == 0 ? $urandom_range(3) : 0);
    repeat (g) begin
      @(posedge clk);
      a_i <= A_W'(rnd128());
      b_i <= B_W'(rnd128());
    end
    @(posedge clk);
    start_i <= 1'b1;
    a_i     <= A_W'(a);
    b_i     <= B_W'(b);
    cur.a = a & AMAX; cur.b = b & BMAX; cur.p = cur.a * cur.b; cur.t0 = cyc + 1; cur.kind = kind;
    ops.push_back(cur);
    n_ops++;
    @(posedge clk);
    start_i <= 1'b0;
    a_i     <= A_W'(rnd128());
    b_i     <= B_W'(rnd128());
    repeat (CYCLES - 2) begin
      @(posedge clk);
      a_i <= A_W'(rnd128());
      b_i <= B_W'(rnd128());
    end
  endtask

  initial begin
    automatic int unsigned seed;
    automatic int n = 1000, exh = 0, neg = 0;
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("N=%d", n));
    void'($value$plusargs("EXH=%d", exh));
    void'($value$plusargs("NEG=%d", neg));
    $display("tb_umul_seq: A_W %0d B_W %0d CYCLES %0d seed %0d N %0d", A_W, B_W, CYCLES, seed, n);
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);

    if (neg == 1) begin
      // start again in the second busy cycle: must be ignored
      fork
        mul(AMAX, BMAX, 0, 0);
        begin
          repeat (3) @(posedge clk);
          start_i <= 1'b1;
          @(posedge clk);
          start_i <= 1'b0;
        end
      join
      repeat (4) @(posedge clk);
    end else if (neg == 2) begin
      mute = 1;
      @(posedge clk);
      start_i <= 1'b1;
      a_i     <= 'x;
      b_i     <= B_W'(1);
      @(posedge clk);
      start_i <= 1'b0;
      a_i     <= '0;
      repeat (CYCLES + 3) @(posedge clk);
      mute = 0;
    end

    // ---- directed ----
    begin
      automatic u128 av[$], bv[$];
      av = '{0, 1, 2, AMAX - 1, AMAX, AMAX & {32{4'b0101}}, AMAX & {32{4'b1010}}};
      bv = '{0, 1, 2, BMAX - 1, BMAX, BMAX & {32{4'b0101}}, BMAX & {32{4'b1010}}};
      for (int k = 1; k < A_W; k++) begin av.push_back(u128'(1) << k); av.push_back((u128'(1) << k) - 1); av.push_back((u128'(1) << k) + 1); end
      for (int k = 1; k < B_W; k++) begin bv.push_back(u128'(1) << k); bv.push_back((u128'(1) << k) - 1); bv.push_back((u128'(1) << k) + 1); end
      foreach (av[i]) foreach (bv[j]) mul(av[i] & AMAX, bv[j] & BMAX, 0);
    end

    // ---- exhaustive (small sizes) ----
    if (exh) begin
      for (u128 a = 0; a <= AMAX; a++)
        for (u128 b = 0; b <= BMAX; b++)
          mul(a, b, 2, 0);
    end

    // ---- random ----
    for (int i = 0; i < n; i++) begin
      automatic u128 a = rbits($urandom_range(A_W, 0)), b = rbits($urandom_range(B_W, 0));
      if ($urandom_range(15) == 0) a = $urandom_range(1) ? AMAX : 0;
      if ($urandom_range(15) == 0) b = $urandom_range(1) ? BMAX : 0;
      mul(a, b, 1);
    end

    repeat (CYCLES + 4) @(posedge clk);
    $display("tb_umul_seq: %0d operations", n_ops);
    begin
      automatic tb_checker_q l = '{c_dir, c_tim, c_hold};
      if (n > 0) l.push_back(c_rnd);
      if (exh) l.push_back(c_exh);
      void'(tb_final_report(l));
    end
    $finish;
  end

endmodule
