// tb_lut_lerp: lut_lerp against the golden model through DPI-C.
// FUNC 0 (EXP2N): k_exp2neg(u, 8, k_exp_lut(8)) (kd_exp2neg). First every table entry of
// lut_pkg::EXP2N_TAB is compared with k_exp_lut(8) (kd_exp_lut8). Then
//   exhaustive: every u in [0, 2^21) (I = u >> 16 = 0..31: every index, fraction and shift)
//   random    : +N inputs with I >= 32 (u >= 2^21, uniform 32-bit and edges 2^21, 2^32 - 1,
//               I = 32 .. 40 with every fraction class)
// FUNC 1 (SIGM, S4-7): k_sigmoid(a, 8, k_sig_lut(8)) (kd_sigmoid). Every entry of
// lut_pkg::SIGM_TAB == k_sig_lut(8) (kd_sig_lut8). Then
//   exhaustive: every a in [-2^20, 2^20] (both signs: 1 - s for a < 0; every index and fraction)
//   directed  : every index with the fraction edges 0, 1, 2047, 2048, 2049, 4095 of both signs,
//               |a| = 2^20 - 1 .. 2^20 + 1, a = 0, -1, 1, 2^31 - 1, -2^31, -2^31 + 1
//   random    : +N inputs with |a| > 2^20 (saturation T[256], 1 - T[256] for a < 0)
// valid_i has random gaps (+GAP percent). Inputs change at posedge, outputs are checked at
// negedge with the exact LATENCY (= PIPE).
// Plusargs: +SEED=<n> +N=<n> +EXH=0|1 +GAP=<percent>.
`timescale 1ns / 1ps
module tb_lut_lerp;
  import tb_util_pkg::*;
  import kdpi_pkg::*;

  parameter int PIPE = 2;
  parameter int FUNC = 0;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic        valid_i = 1'b0, valid_o;
  logic [31:0] u_i = '0;
  logic [16:0] y_o;

  lut_lerp #(.FUNC(FUNC), .PIPE(PIPE)) dut (.clk, .rst_n, .valid_i, .u_i, .valid_o, .y_o);

  tb_checker c_tab = new("table"), c_exh = new("exhaustive"), c_rnd = new("random"),
             c_lat = new("latency");

  typedef struct { longint unsigned u; int e; longint at; bit rnd; } item_t;
  item_t q[$];
  longint nidx = 0;
  int gap = 10;

  task automatic put(longint unsigned u, bit rnd);
    item_t it;
    while ($urandom_range(99) < gap) begin
      @(posedge clk);
      valid_i <= 1'b0;
      u_i     <= $urandom();
    end
    @(posedge clk);
    valid_i <= 1'b1;
    u_i     <= 32'(u);
    it.u = u; it.rnd = rnd;
    it.e = FUNC == 0 ? kd_exp2neg(int'(32'(u)), 8) : kd_sigmoid(int'(32'(u)), 8);
    it.at = nidx + 1 + PIPE;
    q.push_back(it);
  endtask

  always @(negedge clk) begin
    nidx++;
    if (rst_n && valid_o === 1'b1) begin
      if (q.size() == 0) c_lat.fail($sformatf("valid_o without input at %0d", nidx));
      else begin
        automatic item_t it = q.pop_front();
        automatic tb_checker c = it.rnd ? c_rnd : c_exh;
        if (it.at != nidx) c_lat.fail($sformatf("u %0d out at %0d exp %0d", it.u, nidx, it.at));
        else c_lat.pass();
        if (int'(y_o) !== it.e) c.fail($sformatf("in 0x%08h got %0d exp %0d", it.u, y_o, it.e));
        else c.pass();
      end
    end else if (rst_n && valid_o !== 1'b0) c_lat.fail($sformatf("valid_o = %b", valid_o));
    else if (rst_n && q.size() > 0 && q[0].at < nidx)
      c_lat.fail($sformatf("missing output for u %0d", q[0].u));
  end

  initial begin
    automatic int unsigned seed;
    automatic int n = 1000000, exh = 1;
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("N=%d", n));
    void'($value$plusargs("EXH=%d", exh));
    void'($value$plusargs("GAP=%d", gap));
    $display("tb_lut_lerp: FUNC %0d PIPE %0d seed %0d N %0d EXH %0d GAP %0d", FUNC, PIPE, seed, n, exh, gap);
    for (int i = 0; i <= 256; i++)
      if (FUNC == 0 ? int'(lut_pkg::EXP2N_TAB[i]) !== kd_exp_lut8(i)
                    : int'(lut_pkg::SIGM_TAB[i]) !== kd_sig_lut8(i))
        c_tab.fail($sformatf("entry %0d: %0d / %0d golden %0d / %0d", i, lut_pkg::EXP2N_TAB[i],
                             lut_pkg::SIGM_TAB[i], kd_exp_lut8(i), kd_sig_lut8(i)));
      else c_tab.pass();
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    if (FUNC == 0) begin
      if (exh)
        for (longint unsigned u = 0; u < (64'd1 << 21); u++) put(u, 0);
      else
        for (int i = 0; i < 200000; i++) put($urandom_range((1 << 21) - 1), 0);
      // directed corners in every mode: each shift I = 0..40 with the fraction edges
      for (int I = 0; I <= 40; I++) begin
        automatic int fs[$] = '{0, 1, 127, 128, 129, 255, 256, 257, 32767, 32768, 65279, 65280, 65535};
        foreach (fs[k]) put((longint'(I) << 16) | longint'(fs[k]), I >= 32);
      end
      put(64'd1 << 21, 1);
      put(64'hFFFF_FFFF, 1);
      for (int I = 32; I <= 40; I++)
        for (int k = 0; k < 64; k++) put((longint'(I) << 16) | longint'($urandom_range(16'hFFFF)), 1);
      for (int i = 0; i < n; i++) begin
        automatic longint unsigned u = $urandom();
        if (u < (64'd1 << 21)) u += 64'd1 << 21;
        put(u, 1);
      end
    end else begin
      // a as a 32-bit pattern (put takes the low 32 bits)
      if (exh)
        for (int a = -(1 << 20); a <= (1 << 20); a++) put(longint'(32'(a)), 0);
      else
        for (int i = 0; i < 200000; i++) put(longint'(32'($urandom_range(1 << 21) - (1 << 20))), 0);
      for (int idx = 0; idx < 256; idx++) begin
        automatic int fs[$] = '{0, 1, 2047, 2048, 2049, 4095};
        foreach (fs[k]) begin
          put(longint'(32'((idx << 12) | fs[k])), 0);
          put(longint'(32'(-((idx << 12) | fs[k]))), 0);
        end
      end
      begin
        automatic int es[$] = '{0, -1, 1, (1 << 20) - 1, -((1 << 20) - 1), 1 << 20, -(1 << 20),
                                (1 << 20) + 1, -((1 << 20) + 1), 32'h7FFF_FFFF, 32'h8000_0000,
                                32'h8000_0001};
        foreach (es[k]) put(longint'(32'(es[k])), es[k] > (1 << 20) || es[k] < -(1 << 20));
      end
      for (int i = 0; i < n; i++) begin
        automatic int a = $urandom();
        if (a <= (1 << 20) && a >= -(1 << 20)) a = (a < 0) ? a - (1 << 20) - 1 : a + (1 << 20) + 1;
        put(longint'(32'(a)), 1);
      end
    end
    @(posedge clk);
    valid_i <= 1'b0;
    repeat (PIPE + 3) @(posedge clk);
    void'(tb_final_report('{c_tab, c_exh, c_rnd, c_lat}));
    $finish;
  end

endmodule
