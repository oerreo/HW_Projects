// tb_mod_red: exhaustive self-checking testbench for mod_red (all variants).
//
// The DUT is the wrapper mod_red with ALGO and PIPE taken from the TB
// parameters, so the wrapper wiring is exercised for every variant.
//
// Expected values come from the golden model reduce function of the variant
// through DPI-C:
//   ALGO 0 BARRETT  mlkem_dpi_barrett_reduce   x mod Q
//   ALGO 1 MONT12   mlkem_dpi_mont12_reduce    x * 2^-12 mod Q
//   ALGO 2 SHIFTADD mlkem_dpi_shiftadd_reduce  x mod Q
//   ALGO 3 K2RED    mlkem_dpi_k2red_reduce     169 * x mod Q
// The DPI result is also cross-checked against the plain SV expression
// (x * SCALE) % Q with SCALE = 1, 2704, 1, 169 written here independently
// ("model_xcheck"), and SCALE against mlkem_dpi_algo_scale().
//
// Stimulus: every x of the variant's input domain, ascending:
//   [0, 2^24) = 16,777,216 values (BARRETT, SHIFTADD, K2RED)
//   [0, Q * 2^12) = 13,635,584 values (MONT12)
// valid_i is dropped at random with probability GAP_PCT percent per cycle;
// junk data (any 24-bit value) is driven while valid_i is low.
//
// Checking: a reference delay line of depth LATENCY (read from the DUT) holds
// (valid, input, expected). Every cycle, valid_o must equal the delayed valid
// exactly, and when it is 1 r_o must equal the delayed expected value.
// Inputs are driven at the rising edge, outputs checked at the falling edge.
//
// Plusargs:
//   +SEED=<n>      RNG seed (default 1)
//   +GAP_PCT=<n>   percent of idle cycles inserted before each vector (default 0)
//   +OOR_TEST      instead of the sweep, drive OOR_N = 3 valid out-of-domain
//                  inputs (the RTL assertion must fire exactly 3 times) plus
//                  in-domain boundary vectors. MONT12: Q*2^12 (first value
//                  outside the domain), Q*2^12 + 1, 2^24 - 1; Q*2^12 - 1 must
//                  pass. The other variants accept every 24-bit value, so the
//                  out-of-domain stimulus is an input with unknown bits (all X,
//                  one X bit, all Z); 2^24 - 1 must pass.
`timescale 1ns / 1ps

module tb_mod_red;
  import mlkem_pkg::*;
  import mlkem_dpi_pkg::*;
  import tb_util_pkg::*;

  parameter int ALGO = 0;               // mlkem_pkg::algo_e value
  parameter int PIPE = 0;

  localparam time    T_CLK   = 10ns;
  localparam int     MAX_LAT = 8;
  localparam int     OOR_N   = 3;
  localparam longint DOM_HI  = (ALGO == int'(ALGO_MONT12)) ? (longint'(Q) << 12)
                                                         : (longint'(1) << PROD_W);
  localparam int     SCALE   = (ALGO == int'(ALGO_MONT12)) ? 2704 :
                               (ALGO == int'(ALGO_K2RED))  ? 169  : 1;

  if (ALGO < 0 || ALGO > 3) begin : g_bad_algo
    $error("tb_mod_red: ALGO=%0d not supported", ALGO);
  end

  logic              clk     = 1'b0;
  logic              rst_n   = 1'b0;
  logic [PROD_W-1:0] x_i     = '0;
  logic              valid_i = 1'b0;
  logic [COEF_W-1:0] r_o;
  logic              valid_o;

  mod_red #(.ALGO(algo_e'(ALGO)), .PIPE(PIPE)) dut (.*);

  always #(T_CLK / 2) clk = ~clk;

  // --------------------------------------------------------------------------
  // Reference delay line and checkers
  // --------------------------------------------------------------------------
  typedef struct {
    bit                v;
    logic [PROD_W-1:0] x;
    int                exp;   // -1: do not check data (out-of-domain stimulus)
  } ref_t;

  ref_t      ref_pipe [0:MAX_LAT];
  int        lat;
  tb_checker chk_data;
  tb_checker chk_valid;
  tb_checker chk_model;
  longint    n_vec;

  function automatic string algo_name(int a);
    case (a)
      0:       return "BARRETT";
      1:       return "MONT12";
      2:       return "SHIFTADD";
      3:       return "K2RED";
      default: return "?";
    endcase
  endfunction

  function automatic int golden(int x);
    case (ALGO)
      0:       return mlkem_dpi_barrett_reduce(x);
      1:       return mlkem_dpi_mont12_reduce(x);
      2:       return mlkem_dpi_shiftadd_reduce(x);
      3:       return mlkem_dpi_k2red_reduce(x);
      default: return -1;
    endcase
  endfunction

  function automatic int expected(int x);
    int e     = golden(x);
    int ref_v = int'((longint'(x) * SCALE) % Q);
    if (e == ref_v) chk_model.pass();
    else chk_model.fail($sformatf("DPI %s(%0d) = %0d, SV ref = %0d", algo_name(ALGO), x, e,
                                  ref_v));
    return e;
  endfunction

  task automatic check_outputs();
    ref_t r = ref_pipe[lat];
    if (valid_o === r.v) chk_valid.pass();
    else chk_valid.fail($sformatf("valid_o=%b expected %b", valid_o, r.v));
    if (r.v && r.exp >= 0) begin
      if (r_o === COEF_W'(r.exp)) chk_data.pass();
      else chk_data.fail($sformatf("x=%0d expected r=%0d got %0d", r.x, r.exp, r_o));
    end
  endtask

  // One clock cycle. At the rising edge the DUT captures the previous inputs,
  // so the reference delay line advances, and the new inputs are applied with
  // nonblocking assignments (race free against the DUT flops). Outputs are
  // checked at the falling edge, when the inputs already hold the new vector:
  // a combinational path where a register is expected (or the reverse) then
  // shows up as a mismatch.
  task automatic cycle(bit v, logic [PROD_W-1:0] x, int exp);
    @(posedge clk);
    for (int i = lat; i > 0; i--) ref_pipe[i] = ref_pipe[i - 1];
    valid_i     <= v;
    x_i         <= x;
    ref_pipe[0] = '{v: v, x: x, exp: exp};
    @(negedge clk);
    check_outputs();
  endtask

  task automatic idle();
    cycle(1'b0, PROD_W'($urandom_range(2 ** PROD_W - 1)), -1);
  endtask

  task automatic send(int x, int gap_pct);
    while ($urandom_range(99) < gap_pct) idle();
    cycle(1'b1, PROD_W'(x), expected(x));
    n_vec++;
  endtask

  // --------------------------------------------------------------------------
  // Main sequence
  // --------------------------------------------------------------------------
  initial begin
    int unsigned seed;
    int          gap_pct;
    bit          oor_test;
    bit          ok;
    int          s_dpi;

    seed     = tb_seed_from_plusarg();
    gap_pct  = 0;
    void'($value$plusargs("GAP_PCT=%d", gap_pct));
    oor_test = $test$plusargs("OOR_TEST");
    lat      = dut.LATENCY;
    chk_data  = new("data");
    chk_valid = new("valid_align");
    chk_model = new("model_xcheck");
    n_vec     = 0;
    foreach (ref_pipe[i]) ref_pipe[i] = '{v: 1'b0, x: '0, exp: -1};

    $display("TB_CONFIG: tb_mod_red ALGO=%0d(%s) PIPE=%0d LATENCY=%0d SEED=%0d GAP_PCT=%0d OOR_TEST=%0d DOMAIN=[0,%0d)",
             ALGO, algo_name(ALGO), PIPE, lat, seed, gap_pct, oor_test, DOM_HI);
    if (lat < 0 || lat > MAX_LAT) $fatal(1, "LATENCY %0d outside TB support", lat);

    // The scale written in this TB must agree with the golden model.
    s_dpi = mlkem_dpi_algo_scale(ALGO, 1);
    if (s_dpi == SCALE) chk_model.pass();
    else chk_model.fail($sformatf("algo_scale(%0d) = %0d, TB SCALE = %0d", ALGO, s_dpi, SCALE));

    // Reset: valid_o must be 0 while rst_n is low. Release at a falling edge.
    repeat (3) idle();
    @(negedge clk);
    rst_n = 1'b1;
    repeat (2) idle();

    if (oor_test) begin
      send(1, 0);
      if (ALGO == int'(ALGO_MONT12)) begin
        // The golden model must also reject the first value outside the domain.
        if (golden(int'(DOM_HI)) == -1) chk_model.pass();
        else chk_model.fail($sformatf("DPI accepted x=%0d outside the domain", DOM_HI));
        cycle(1'b1, PROD_W'(DOM_HI), -1);       idle();
        cycle(1'b1, PROD_W'(DOM_HI + 1), -1);   idle();
        cycle(1'b1, '1, -1);                    idle();
        send(int'(DOM_HI - 1), 0);
      end else begin
        cycle(1'b1, 'x, -1);                    idle();
        cycle(1'b1, {{(PROD_W - 1){1'b0}}, 1'bx}, -1);  idle();
        cycle(1'b1, 'z, -1);                    idle();
        send(int'(DOM_HI - 1), 0);
      end
      send(0, 0);
      $display("OOR_TEST: drove %0d out-of-domain valid inputs (assertion must fire %0d times)",
               OOR_N, OOR_N);
    end else begin
      for (longint x = 0; x < DOM_HI; x++) begin
        send(int'(x), gap_pct);
        if (x % (longint'(1) << 22) == 0)
          $display("PROGRESS: x=%0d vectors=%0d time=%0t", x, n_vec, $time);
      end
    end

    repeat (lat + 2) idle();

    $display("VECTORS: driven=%0d data_checks=%0d%s", n_vec, chk_data.n_checks,
             oor_test ? "" : $sformatf(" exhaustive_expected=%0d", DOM_HI));
    if (!oor_test && n_vec != DOM_HI) chk_data.fail("vector count is not the domain size");
    if (chk_data.n_checks != n_vec) chk_data.fail("data check count != vectors driven");
    ok = tb_final_report('{chk_data, chk_valid, chk_model});
    $finish;
  end

endmodule
