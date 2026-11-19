// tb_rshr_sat: rshr_sat against the golden k_rshr / k_sat32 through DPI-C.
//
// Expected value of one input (x, sh):
//   SAT_MODE 1            : kd_rshr(x, sh)                       (OUT_W = 64)
//   SAT_MODE 0, OUT_W 32  : kd_sat32(kd_rshr(x, sh))
//   SAT_MODE 0, other     : kd_rshr(x, sh) clamped to the OUT_W range (the golden has
//                           only sat32; this run checks the generic OUT_W saturation)
// Vectors: directed (zero, +-1, extremes, powers of two; every shift -70..70, the
// IN_W / OUT_W / 62 / 64 edges and both ends of the SH_W range), saturation boundaries
// (for every left shift 0..LS_LIM+1 the largest values that do and do not fit, both
// signs), then +N random (default 1,000,000; mixed magnitude classes and shift classes).
// valid_i has random gaps. Inputs change at posedge (non-blocking), outputs are checked
// at negedge with the exact latency LATENCY (valid_o of a gap cycle is an error).
// Plusargs: +SEED=<n> +N=<n>.
`timescale 1ns / 1ps
module tb_rshr_sat;
  import tb_util_pkg::*;
  import kdpi_pkg::*;
  import llm_pkg::*;

  parameter int IN_W     = 58;
  parameter int OUT_W    = 32;
  parameter int SAT_MODE = 0;
  parameter int PIPE     = 1;

  localparam int LS_LIM = (SAT_MODE == 1) ? 62 : OUT_W;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic                    valid_i = 1'b0, valid_o;
  logic signed [IN_W-1:0]  x_i = '0;
  logic signed [SH_W-1:0]  sh_i = '0;
  logic signed [OUT_W-1:0] y_o;

  rshr_sat #(.IN_W(IN_W), .OUT_W(OUT_W), .SAT_MODE(SAT_MODE), .PIPE(PIPE)) dut (
    .clk(clk), .rst_n(rst_n), .valid_i(valid_i), .x_i(x_i), .sh_i(sh_i),
    .valid_o(valid_o), .y_o(y_o));

  tb_checker c_dir = new("directed"), c_rnd = new("random"), c_lat = new("latency");

  typedef struct { longint x; int sh; longint e; longint at; bit rnd; } item_t;
  item_t q[$];
  longint nidx = 0;        // negedge counter
  int n_cov_zero_r = 0;

  localparam longint XMAX = (64'sd1 <<< (IN_W - 1)) - 1;
  localparam longint XMIN = -(64'sd1 <<< (IN_W - 1));

  function automatic longint expv(longint x, int sh);
    longint r = kd_rshr(x, sh);
    if (SAT_MODE == 1) return r;
    if (OUT_W == 32) return longint'(kd_sat32(r));
    begin
      longint hi = (64'sd1 <<< (OUT_W - 1)) - 1, lo = -(64'sd1 <<< (OUT_W - 1));
      return r > hi ? hi : (r < lo ? lo : r);
    end
  endfunction

  // drive one input at the next posedge
  task automatic put(longint x, int sh, bit rnd);
    item_t it;
    // random gap (25 %) before the vector
    while ($urandom_range(3) == 0) begin
      @(posedge clk);
      valid_i <= 1'b0;
      x_i     <= IN_W'($urandom());
      sh_i    <= SH_W'($urandom());
    end
    @(posedge clk);
    valid_i <= 1'b1;
    x_i     <= IN_W'(x);
    sh_i    <= SH_W'(sh);
    it.x = x; it.sh = sh; it.e = expv(x, sh); it.rnd = rnd;
    it.at = nidx + 1 + PIPE;  // negedge at which valid_o must show it
    q.push_back(it);
  endtask

  // output check at negedge
  always @(negedge clk) begin
    nidx++;
    if (rst_n && valid_o === 1'b1) begin
      if (q.size() == 0) c_lat.fail($sformatf("valid_o without input at negedge %0d", nidx));
      else begin
        automatic item_t it = q.pop_front();
        automatic longint got = longint'(y_o);
        automatic tb_checker c = it.rnd ? c_rnd : c_dir;
        if (it.at != nidx) c_lat.fail($sformatf("x %0d sh %0d out at %0d exp %0d", it.x, it.sh, nidx, it.at));
        else c_lat.pass();
        if (got !== it.e) c.fail($sformatf("x %0d sh %0d got %0d exp %0d", it.x, it.sh, got, it.e));
        else c.pass();
        if (it.sh > 0 && it.e == 0 && it.x != 0) n_cov_zero_r++;
      end
    end else if (rst_n && valid_o !== 1'b0) c_lat.fail($sformatf("valid_o = %b", valid_o));
    else if (rst_n && q.size() > 0 && q[0].at < nidx)
      c_lat.fail($sformatf("missing output for x %0d sh %0d (due at %0d)", q[0].x, q[0].sh, q[0].at));
  end

  function automatic longint rnd_x();
    int k = $urandom_range(99);
    longint v = {$urandom(), $urandom()};
    if (k < 45) return (v <<< (64 - IN_W)) >>> (64 - IN_W);       // full range
    if (k < 90) begin                                                 // random magnitude
      int b = $urandom_range(IN_W - 1, 1);
      return (v <<< (64 - b)) >>> (64 - b);
    end
    case ($urandom_range(5))
      0: return XMAX;
      1: return XMIN;
      2: return XMAX - $urandom_range(3);
      3: return XMIN + $urandom_range(3);
      4: return longint'($urandom_range(2)) - 1;
      default: return 0;
    endcase
  endfunction

  function automatic int rnd_sh();
    int k = $urandom_range(99);
    if (k < 55) return $urandom_range(140) - 70;
    if (k < 80) return $urandom_range(IN_W + LS_LIM + 4) - (LS_LIM + 2);
    return int'($urandom_range(1023)) - 512;  // whole SH_W range
  endfunction

  int n_rnd = 1000000;
  int unsigned seed;

  initial begin
    longint xs[$];
    int shs[$];
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("N=%d", n_rnd));
    $display("tb_rshr_sat: IN_W=%0d OUT_W=%0d SAT_MODE=%0d PIPE=%0d LATENCY=%0d seed=%0d N=%0d",
             IN_W, OUT_W, SAT_MODE, PIPE, dut.LATENCY, seed, n_rnd);
    if (dut.LATENCY != PIPE) c_lat.fail("LATENCY localparam != PIPE");
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);

    // ---- directed ----
    xs = '{0, 1, -1, 2, -2, 3, -3, 5, -5, 7, -7, XMAX, XMIN, XMAX - 1, XMIN + 1, XMAX >>> 1,
           XMIN >>> 1, (XMAX >>> 1) + 1, (XMIN >>> 1) - 1, 64'sd123456789 % (XMAX + 1)};
    for (int k = 1; k < IN_W - 1; k += 7) begin
      xs.push_back(64'sd1 <<< k);
      xs.push_back(-(64'sd1 <<< k));
      xs.push_back((64'sd1 <<< k) - 1);
      xs.push_back(-(64'sd1 <<< k) + 1);
      xs.push_back((64'sd1 <<< k) + (64'sd1 <<< (k - 1)));  // exact .5 cases after shift k
      xs.push_back(-(64'sd1 <<< k) - (64'sd1 <<< (k - 1)));
    end
    for (int s = -70; s <= 70; s++) shs.push_back(s);
    begin
      automatic int ed[] = '{IN_W - 2, IN_W - 1, IN_W, IN_W + 1, 61, 62, 63, 64, 65, OUT_W - 1, OUT_W,
                   OUT_W + 1, -(OUT_W - 1), -OUT_W, -(OUT_W + 1), -61, -62, -63, -64, -65, 200,
                   -200, 511, 510, -511, -512};
      foreach (ed[i]) shs.push_back(ed[i]);
    end
    foreach (xs[i]) foreach (shs[j]) put(xs[i], shs[j], 1'b0);

    // ---- saturation boundaries: for left shift ls, x = +-floor(B / 2^ls) (+0/+1) ----
    for (int ls = 0; ls <= LS_LIM + 1; ls++) begin
      automatic longint hb = (SAT_MODE == 1) ? 64'sh7FFF_FFFF_FFFF_FFFF : (64'sd1 <<< (OUT_W - 1)) - 1;
      automatic longint lim = (ls >= 63) ? 0 : (hb >>> ls);
      automatic longint cand[] = '{lim, lim + 1, -lim, -lim - 1, -lim - 2, lim - 1};
      foreach (cand[i])
        if (cand[i] <= XMAX && cand[i] >= XMIN) put(cand[i], -ls, 1'b0);
    end
    // right shift rounding of every shift for x = +-2^(s-1) (+-1)
    for (int s = 1; s < IN_W; s++) begin
      automatic longint h = 64'sd1 <<< (s - 1);
      automatic longint hv[] = '{h, h - 1, -h, -h + 1, -h - 1, h + 1};
      foreach (hv[i])
        if (hv[i] <= XMAX && hv[i] >= XMIN) put(hv[i], s, 1'b0);
    end

    // ---- random ----
    for (int i = 0; i < n_rnd; i++) put(rnd_x(), rnd_sh(), 1'b1);

    @(posedge clk);
    valid_i <= 1'b0;
    repeat (PIPE + 3) @(posedge clk);
    if (q.size() != 0) c_lat.fail($sformatf("%0d outputs missing at the end", q.size()));
    $display("coverage: right-shift-to-zero(nonzero x) %0d", n_cov_zero_r);
    void'(tb_final_report('{c_dir, c_rnd, c_lat}));
    $finish;
  end
endmodule
