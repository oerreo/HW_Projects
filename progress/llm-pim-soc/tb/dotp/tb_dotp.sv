// tb_dotp: dotp (AW = BW = 8) against the golden k_dot8 through DPI-C (kd_dot8).
//
// Vectors: directed lane patterns (all -128 x -128, all 127 x 127, 127 x -128, -128 x 127,
// zero, alternating signs, one hot of each extreme in every lane, ramps), then +N random
// (default 1,000,000; per vector a value class: uniform bytes, extremes only, small
// magnitudes, or one operand constant). valid_i has random gaps. Inputs change at posedge
// (non-blocking), outputs are checked at negedge with the exact latency LATENCY.
// Plusargs: +SEED=<n> +N=<n>.
`timescale 1ns / 1ps
module tb_dotp;
  import tb_util_pkg::*;
  import kdpi_pkg::*;

  parameter int LANES = 8;
  parameter int PIPE  = 2;
  localparam int AW = 8, BW = 8;
  localparam int SW = AW + BW + $clog2(LANES);

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic                 valid_i = 1'b0, valid_o;
  logic [LANES*AW-1:0]  a_i = '0;
  logic [LANES*BW-1:0]  b_i = '0;
  logic signed [SW-1:0] sum_o;

  dotp #(.LANES(LANES), .AW(AW), .BW(BW), .PIPE(PIPE)) dut (
    .clk(clk), .rst_n(rst_n), .valid_i(valid_i), .a_i(a_i), .b_i(b_i),
    .valid_o(valid_o), .sum_o(sum_o));

  tb_checker c_dir = new("directed"), c_rnd = new("random"), c_lat = new("latency");

  typedef struct { int e; longint at; bit rnd; logic [LANES*AW-1:0] a, b; } item_t;
  item_t q[$];
  longint nidx = 0;
  int smin = 0, smax = 0;

  task automatic put(byte a[], byte b[], bit rnd);
    item_t it;
    logic [LANES*AW-1:0] av, bv;
    while ($urandom_range(3) == 0) begin
      @(posedge clk);
      valid_i <= 1'b0;
      a_i     <= {LANES{$urandom()}};
      b_i     <= {LANES{$urandom()}};
    end
    foreach (a[i]) begin
      av[i*AW +: AW] = a[i];
      bv[i*BW +: BW] = b[i];
    end
    @(posedge clk);
    valid_i <= 1'b1;
    a_i     <= av;
    b_i     <= bv;
    it.e = kd_dot8(a, b, LANES); it.rnd = rnd; it.a = av; it.b = bv;
    it.at = nidx + 1 + PIPE;
    q.push_back(it);
  endtask

  always @(negedge clk) begin
    nidx++;
    if (rst_n && valid_o === 1'b1) begin
      if (q.size() == 0) c_lat.fail($sformatf("valid_o without input at negedge %0d", nidx));
      else begin
        automatic item_t it = q.pop_front();
        automatic tb_checker c = it.rnd ? c_rnd : c_dir;
        if (it.at != nidx) c_lat.fail($sformatf("out at %0d exp %0d", nidx, it.at));
        else c_lat.pass();
        if (sum_o !== SW'(it.e)) c.fail($sformatf("a %h b %h got %0d exp %0d", it.a, it.b, sum_o, it.e));
        else c.pass();
        if (it.e < smin) smin = it.e;
        if (it.e > smax) smax = it.e;
      end
    end else if (rst_n && valid_o !== 1'b0) c_lat.fail($sformatf("valid_o = %b", valid_o));
    else if (rst_n && q.size() > 0 && q[0].at < nidx) c_lat.fail($sformatf("missing output due at %0d", q[0].at));
  end

  function automatic byte rbyte(int cls);
    case (cls)
      0: return byte'($urandom());
      1: return ($urandom_range(1)) ? 8'sd127 : -8'sd128;
      2: return byte'(int'($urandom_range(6)) - 3);
      default: return byte'($urandom());
    endcase
  endfunction

  int n_rnd = 1000000;
  int unsigned seed;

  initial begin
    byte a[], b[];
    static byte ext[] = '{-128, 127, -127, 0, 1, -1};
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("N=%d", n_rnd));
    $display("tb_dotp: LANES=%0d PIPE=%0d LATENCY=%0d seed=%0d N=%0d", LANES, PIPE, dut.LATENCY, seed, n_rnd);
    if (dut.LATENCY != PIPE) c_lat.fail("LATENCY localparam != PIPE");
    a = new[LANES];
    b = new[LANES];
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);

    // ---- directed: constant pairs over all lanes ----
    foreach (ext[i]) foreach (ext[j]) begin
      foreach (a[l]) begin a[l] = ext[i]; b[l] = ext[j]; end
      put(a, b, 1'b0);
    end
    // alternating signs, ramps
    foreach (a[l]) begin a[l] = (l % 2) ? -128 : 127; b[l] = (l % 2) ? -128 : -128; end
    put(a, b, 1'b0);
    foreach (a[l]) begin a[l] = byte'(l * 37 - 128); b[l] = byte'(127 - l * 19); end
    put(a, b, 1'b0);
    // one hot extreme in every lane
    for (int l = 0; l < LANES; l++)
      foreach (ext[i]) foreach (ext[j]) begin
        foreach (a[k]) begin a[k] = 0; b[k] = 0; end
        a[l] = ext[i];
        b[l] = ext[j];
        put(a, b, 1'b0);
      end

    // ---- random ----
    for (int i = 0; i < n_rnd; i++) begin
      automatic int ca = $urandom_range(4), cb = $urandom_range(4);
      if ($urandom_range(9) == 0) begin  // one operand constant
        automatic byte k = rbyte($urandom_range(2));
        foreach (a[l]) begin a[l] = k; b[l] = rbyte(cb); end
      end else
        foreach (a[l]) begin a[l] = rbyte(ca); b[l] = rbyte(cb); end
      put(a, b, 1'b1);
    end

    @(posedge clk);
    valid_i <= 1'b0;
    repeat (PIPE + 3) @(posedge clk);
    if (q.size() != 0) c_lat.fail($sformatf("%0d outputs missing at the end", q.size()));
    $display("coverage: sum range [%0d, %0d] (limits [%0d, %0d])", smin, smax,
             -LANES * 128 * 127, LANES * 128 * 128);
    void'(tb_final_report('{c_dir, c_rnd, c_lat}));
    $finish;
  end
endmodule
