// tb_udiv_seq: udiv_seq against the golden C division (q = num / den on unsigned 64-bit
// values; the golden model divides with C "/": attention R = 2^48 / sum, actq M and R).
//
// Every operation: start in cycle c (random gap 0..3 cycles after the previous done; gap 0 =
// start in the done cycle), then done_o must be a 1-cycle pulse in exactly c + CYCLES with
// q_o == num / den, busy_o must be 1 exactly in c+1 .. c+Q_W, and q_o must hold its value
// from done until the next start.
// Vectors:
//   directed: q = 0, 1, 2^Q_W - 1 (largest), den = 1, den = 2^DEN_W - 1, remainders 0 and
//             den - 1, quotients 2^k and 2^k - 1, and for the attention sizes (NUM_W 49,
//             DEN_W 26, Q_W 33) num = 2^48 with every den = 2^16 .. 2^25 and its +-1
//   random  : +N operations (random den magnitude, random q < 2^Q_W, random remainder,
//             num = q den + r if it fits NUM_W), plus for the attention sizes num = 2^48
//             with den in [2^16, 2^25]
//   exhaustive (+EXH=1, small parameters only): every (num, den) with a fitting quotient
//   negative (+NEG=<k>): 1 division by zero (UDIV_ZERO), 2 quotient overflow (UDIV_OVF),
//             3 start while busy (UDIV_START, ignored: the running division must still
//             finish correctly)
// Plusargs: +SEED=<n> +N=<n> +EXH=1 +NEG=<k>.
`timescale 1ns / 1ps
module tb_udiv_seq;
  import tb_util_pkg::*;

  parameter int NUM_W = 49;
  parameter int DEN_W = 26;
  parameter int Q_W   = 33;
  localparam int CYCLES = Q_W + 1;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic             start_i = 1'b0, done_o, busy_o;
  logic [NUM_W-1:0] num_i = '0;
  logic [DEN_W-1:0] den_i = '0;
  logic [Q_W-1:0]   q_o;

  udiv_seq #(.NUM_W(NUM_W), .DEN_W(DEN_W), .Q_W(Q_W)) dut (
    .clk, .rst_n, .start_i, .num_i, .den_i, .q_o, .done_o, .busy_o);

  tb_checker c_dir = new("directed"), c_rnd = new("random"), c_exh = new("exhaustive"),
             c_tim = new("timing"), c_hold = new("hold");

  longint unsigned cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  typedef struct { longint unsigned num, den, q, t0; int kind; } op_t;
  op_t cur;
  bit  have_res = 0, mute = 0;
  logic [Q_W-1:0] last_q;
  longint unsigned n_ops = 0;

  localparam longint unsigned NMASK = (NUM_W == 64) ? '1 : ((64'd1 << NUM_W) - 1);
  localparam longint unsigned DMAX  = (64'd1 << DEN_W) - 1;
  localparam longint unsigned QMAX  = (Q_W == 64) ? '1 : ((64'd1 << Q_W) - 1);

  function automatic tb_checker ck(int kind);
    return kind == 0 ? c_dir : (kind == 1 ? c_rnd : c_exh);
  endfunction

  // monitor at negedge (ops queue: a new op may start in the done cycle of the previous one)
  op_t ops[$];
  always @(negedge clk) begin
    if (rst_n && !mute) begin
      automatic bit busy_exp = 0;
      foreach (ops[i]) if (cyc >= ops[i].t0 + 1 && cyc <= ops[i].t0 + Q_W) busy_exp = 1;
      if (busy_o !== busy_exp) c_tim.fail($sformatf("cycle %0d busy_o %b exp %b", cyc, busy_o, busy_exp));
      if (ops.size() > 0 && cyc == ops[0].t0 + CYCLES) begin
        automatic op_t o = ops.pop_front();
        if (done_o !== 1'b1) c_tim.fail($sformatf("no done at %0d (num %0d den %0d)", cyc, o.num, o.den));
        else c_tim.pass();
        if (64'(q_o) !== o.q)
          ck(o.kind).fail($sformatf("%0d / %0d: got %0d exp %0d", o.num, o.den, q_o, o.q));
        else ck(o.kind).pass();
        last_q   = q_o;
        have_res = 1;
      end else if (done_o !== 1'b0) c_tim.fail($sformatf("unexpected done_o %b at %0d", done_o, cyc));
      else if (have_res && (ops.size() == 0 || cyc <= ops[0].t0)) begin
        if (q_o !== last_q) c_hold.fail($sformatf("q_o changed while idle at %0d", cyc));
        else c_hold.pass();
      end
    end
  end

  // one division: start at the next posedge after a gap; returns at the start of the done cycle
  task automatic div(longint unsigned num, longint unsigned den, int kind, int gap = -1);
    int g = gap >= 0 ? gap : ($urandom_range(3) == 0 ? $urandom_range(3) : 0);
    repeat (g) @(posedge clk);
    @(posedge clk);
    start_i <= 1'b1;
    num_i   <= NUM_W'(num);
    den_i   <= DEN_W'(den);
    cur.num = num; cur.den = den; cur.q = num / den; cur.t0 = cyc + 1; cur.kind = kind;  // cyc updates after this posedge
    ops.push_back(cur);
    n_ops++;
    @(posedge clk);
    start_i <= 1'b0;
    num_i   <= NUM_W'({$urandom(), $urandom()});
    den_i   <= DEN_W'({$urandom(), $urandom()});
    repeat (CYCLES - 2) @(posedge clk);
  endtask

  function automatic bit fits(longint unsigned q, longint unsigned den, longint unsigned r,
                              output longint unsigned num);
    // num = q den + r must fit NUM_W bits (no 64-bit overflow for the sizes used here)
    longint unsigned hi;
    num = q * den + r;
    if (den != 0 && q != 0 && (num - r) / den != q) return 0;  // 64-bit overflow
    hi = (NUM_W == 64) ? 0 : (num >> NUM_W);
    return hi == 0;
  endfunction

  function automatic longint unsigned rbits(int b);
    longint unsigned v = {$urandom(), $urandom()};
    return b <= 0 ? 0 : (b >= 64 ? v : (v & ((64'd1 << b) - 1)));
  endfunction

  task automatic try(longint unsigned q, longint unsigned den, longint unsigned r, int kind);
    longint unsigned num;
    if (den == 0 || den > DMAX || q > QMAX || r >= den) return;
    if (!fits(q, den, r, num)) return;
    div(num, den, kind);
  endtask

  initial begin
    automatic int unsigned seed;
    automatic int n = 1000, exh = 0, neg = 0;
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("N=%d", n));
    void'($value$plusargs("EXH=%d", exh));
    void'($value$plusargs("NEG=%d", neg));
    $display("tb_udiv_seq: NUM_W %0d DEN_W %0d Q_W %0d CYCLES %0d seed %0d N %0d", NUM_W, DEN_W,
             Q_W, CYCLES, seed, n);
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);

    if (neg == 1 || neg == 2) begin
      // no value check (division by zero is undefined in C), only the assertion
      mute = 1;
      @(posedge clk);
      start_i <= 1'b1;
      num_i   <= neg == 1 ? NUM_W'(5) : NUM_W'(QMAX + 1);
      den_i   <= neg == 1 ? DEN_W'(0) : DEN_W'(1);
      @(posedge clk);
      start_i <= 1'b0;
      repeat (CYCLES + 3) @(posedge clk);
      mute = 0;
    end else if (neg == 3) begin
      // start again in the second busy cycle: must be ignored
      fork
        div(64'd1000, 64'd7, 0, 0);
        begin
          repeat (3) @(posedge clk);
          start_i <= 1'b1;
          num_i   <= NUM_W'(64'd999);
          den_i   <= DEN_W'(64'd3);
          @(posedge clk);
          start_i <= 1'b0;
        end
      join
      repeat (4) @(posedge clk);
    end

    // ---- directed ----
    begin
      automatic longint unsigned dens[$] = '{1, 2, 3, DMAX, DMAX - 1, (DMAX + 1) / 2, (DMAX + 1) / 2 + 1};
      foreach (dens[i]) begin
        automatic longint unsigned d = dens[i];
        if (d == 0 || d > DMAX) continue;
        try(0, d, 0, 0);
        try(0, d, d - 1, 0);
        try(1, d, 0, 0);
        try(1, d, d - 1, 0);
        try(QMAX, d, 0, 0);
        try(QMAX, d, d - 1, 0);
        try(QMAX - 1, d, d - 1, 0);
        for (int k = 1; k < Q_W; k++) begin
          try(64'd1 << k, d, 0, 0);
          try((64'd1 << k) - 1, d, d - 1, 0);
        end
      end
      if (NUM_W == 49 && Q_W == 33)
        for (int k = 16; k <= 25 && k < DEN_W; k++)
          for (int dd = -1; dd <= 1; dd++) begin
            automatic longint unsigned d = (64'd1 << k) + longint'(dd);
            if (d >= (64'd1 << 16)) div(64'd1 << 48, d, 0);
          end
    end

    // ---- exhaustive (small sizes) ----
    if (exh) begin
      for (longint unsigned d = 1; d <= DMAX; d++)
        for (longint unsigned x = 0; x < d * (QMAX + 1) && x <= NMASK; x++)
          div(x, d, 2, 0);
    end

    // ---- random ----
    for (int i = 0; i < n; i++) begin
      automatic int k = $urandom_range(99);
      if (NUM_W == 49 && Q_W == 33 && k < 20) begin
        // attention use: 2^48 / sum, sum in [2^16, 2^25]
        automatic longint unsigned d = (64'd1 << 16) + rbits($urandom_range(25, 1)) % ((64'd1 << 25) - (64'd1 << 16) + 1);
        div(64'd1 << 48, d, 1);
      end else begin
        automatic longint unsigned d = 0, q, r, num;
        while (d == 0) d = rbits($urandom_range(DEN_W, 1));
        q = rbits($urandom_range(Q_W, 0));
        r = rbits(DEN_W) % d;
        if ($urandom_range(9) == 0) r = d - 1;
        if ($urandom_range(19) == 0) q = QMAX;
        if (fits(q, d, r, num)) div(num, d, 1);
        else begin
          // shrink q until it fits NUM_W
          while (q != 0 && !fits(q, d, r, num)) q >>= 1;
          if (fits(q, d, r, num)) div(num, d, 1);
        end
      end
    end

    repeat (CYCLES + 4) @(posedge clk);
    $display("tb_udiv_seq: %0d operations", n_ops);
    begin
      automatic tb_checker_q l = '{c_dir, c_tim, c_hold};
      if (n > 0) l.push_back(c_rnd);
      if (exh) l.push_back(c_exh);
      void'(tb_final_report(l));
    end
    $finish;
  end

endmodule
