// tb_mod_half: exhaustive self-checking testbench for mod_half.
//
// Expected values come from the golden model mod_half() through DPI-C
// (mlkem_dpi_mod_half). Two auxiliary checks are kept:
//   "property"     : the DUT output satisfies the defining property
//                    h_o < Q and (2 * h_o) mod Q == x_i (unique for x_i in [0, Q)),
//   "model_xcheck" : the DPI value equals the plain SV expression (x * Q_INV2) % Q,
//                    to catch a broken link.
//
// Stimulus: every x in [0, Q), ascending, repeated REPEAT times (later passes
// use random order). valid_i is dropped at random with probability GAP_PCT
// percent per cycle; junk data (any 12-bit value) is driven while it is low.
//
// Checking: a reference delay line of depth LATENCY (read from the DUT).
// Every cycle valid_o must equal the delayed valid exactly, and when it is 1
// h_o must equal the delayed expected value (and satisfy the property).
// Inputs are driven at the rising edge, outputs checked at the falling edge
// (see cycle()).
//
// Plusargs:
//   +SEED=<n>      RNG seed (default 1)
//   +GAP_PCT=<n>   percent of idle cycles inserted before each vector (default 0)
//   +REPEAT=<n>    number of sweeps over [0, Q) (default 1)
//   +OOR_TEST      instead of the sweep, drive OOR_N = 3 valid out-of-range
//                  inputs (the RTL assertion must fire exactly 3 times) plus a
//                  few in-range vectors.
`timescale 1ns / 1ps

module tb_mod_half;
  import mlkem_pkg::*;
  import mlkem_dpi_pkg::*;
  import tb_util_pkg::*;

  parameter int PIPE = 0;

  localparam time T_CLK   = 10ns;
  localparam int  MAX_LAT = 8;
  localparam int  OOR_N   = 3;

  logic              clk     = 1'b0;
  logic              rst_n   = 1'b0;
  logic [COEF_W-1:0] x_i     = '0;
  logic              valid_i = 1'b0;
  logic [COEF_W-1:0] h_o;
  logic              valid_o;

  mod_half #(.PIPE(PIPE)) dut (.*);

  always #(T_CLK / 2) clk = ~clk;

  // --------------------------------------------------------------------------
  // Reference delay line and checkers
  // --------------------------------------------------------------------------
  typedef struct {
    bit v;
    int x;
    int exp;   // -1: do not check data (out-of-range stimulus)
  } ref_t;

  ref_t      ref_pipe [0:MAX_LAT];
  int        lat;
  tb_checker chk_data;
  tb_checker chk_prop;
  tb_checker chk_valid;
  tb_checker chk_model;
  longint    n_vec;

  function automatic int expected(int x);
    int e = mlkem_dpi_mod_half(x);
    if (e == (x * Q_INV2) % Q) chk_model.pass();
    else chk_model.fail($sformatf("DPI mod_half(%0d) = %0d, SV ref = %0d", x, e,
                                  (x * Q_INV2) % Q));
    return e;
  endfunction

  task automatic check_outputs();
    ref_t r = ref_pipe[lat];
    if (valid_o === r.v) chk_valid.pass();
    else chk_valid.fail($sformatf("valid_o=%b expected %b", valid_o, r.v));
    if (r.v && r.exp >= 0) begin
      if (h_o === COEF_W'(r.exp)) chk_data.pass();
      else chk_data.fail($sformatf("x=%0d expected h=%0d got %0d", r.x, r.exp, h_o));
      if (!$isunknown(h_o) && int'(h_o) < Q && (2 * int'(h_o)) % Q == r.x) chk_prop.pass();
      else chk_prop.fail($sformatf("x=%0d h=%0d violates h < Q and 2h mod Q == x", r.x, h_o));
    end
  endtask

  // One clock cycle. At the rising edge the DUT captures the previous inputs,
  // so the reference delay line advances, and the new inputs are applied with
  // nonblocking assignments (race free against the DUT flops). Outputs are
  // checked at the falling edge, when the inputs already hold the new vector:
  // a combinational path where a register is expected (or the reverse) then
  // shows up as a mismatch.
  task automatic cycle(bit v, int x, int exp);
    @(posedge clk);
    for (int i = lat; i > 0; i--) ref_pipe[i] = ref_pipe[i - 1];
    valid_i     <= v;
    x_i         <= COEF_W'(x);
    ref_pipe[0] = '{v: v, x: x, exp: exp};
    @(negedge clk);
    check_outputs();
  endtask

  task automatic idle();
    cycle(1'b0, $urandom_range(2 ** COEF_W - 1), -1);
  endtask

  task automatic send(int x, int gap_pct);
    while ($urandom_range(99) < gap_pct) idle();
    cycle(1'b1, x, expected(x));
    n_vec++;
  endtask

  // --------------------------------------------------------------------------
  // Main sequence
  // --------------------------------------------------------------------------
  initial begin
    int unsigned seed;
    int          gap_pct;
    int          repeat_n;
    bit          oor_test;
    bit          ok;
    int          order[];

    seed     = tb_seed_from_plusarg();
    gap_pct  = 0;
    repeat_n = 1;
    void'($value$plusargs("GAP_PCT=%d", gap_pct));
    void'($value$plusargs("REPEAT=%d", repeat_n));
    oor_test  = $test$plusargs("OOR_TEST");
    lat       = dut.LATENCY;
    chk_data  = new("data");
    chk_prop  = new("property");
    chk_valid = new("valid_align");
    chk_model = new("model_xcheck");
    n_vec     = 0;
    foreach (ref_pipe[i]) ref_pipe[i] = '{v: 1'b0, x: 0, exp: -1};

    $display("TB_CONFIG: tb_mod_half PIPE=%0d LATENCY=%0d SEED=%0d GAP_PCT=%0d REPEAT=%0d OOR_TEST=%0d",
             PIPE, lat, seed, gap_pct, repeat_n, oor_test);
    if (lat < 0 || lat > MAX_LAT) $fatal(1, "LATENCY %0d outside TB support", lat);

    repeat (3) idle();
    @(negedge clk);
    rst_n = 1'b1;
    repeat (2) idle();

    if (oor_test) begin
      send(1, 0);
      cycle(1'b1, Q, -1);         idle();
      cycle(1'b1, 4095, -1);      idle();
      cycle(1'b1, Q + 1, -1);     idle();
      send(Q - 1, 0);
      send(Q - 2, 0);
      $display("OOR_TEST: drove %0d out-of-range valid inputs (assertion must fire %0d times)",
               OOR_N, OOR_N);
    end else begin
      order = new[Q];
      foreach (order[i]) order[i] = i;
      for (int p = 0; p < repeat_n; p++) begin
        if (p > 0) order.shuffle();
        foreach (order[i]) send(order[i], gap_pct);
      end
    end

    repeat (lat + 2) idle();

    $display("VECTORS: driven=%0d data_checks=%0d%s", n_vec, chk_data.n_checks,
             oor_test ? "" : $sformatf(" exhaustive_expected=%0d", longint'(Q) * repeat_n));
    if (!oor_test && n_vec != longint'(Q) * repeat_n) chk_data.fail("vector count is not Q * REPEAT");
    if (chk_data.n_checks != n_vec) chk_data.fail("data check count != vectors driven");
    ok = tb_final_report('{chk_data, chk_prop, chk_valid, chk_model});
    $finish;
  end

endmodule
