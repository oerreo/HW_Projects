// tb_mod_mul: exhaustive self-checking testbench for mod_mul (all variants).
//
// The DUT is mod_mul with ALGO, MUL_REG and RED_PIPE taken from the TB
// parameters.
//
// Expected values come from the golden model reduce function of the variant
// applied to the plain product a * b, through DPI-C:
//   ALGO 0 BARRETT  mlkem_dpi_barrett_reduce(a*b)    a * b mod Q
//   ALGO 1 MONT12   mlkem_dpi_mont12_reduce(a*b)     a * b * 2^-12 mod Q
//   ALGO 2 SHIFTADD mlkem_dpi_shiftadd_reduce(a*b)   a * b mod Q
//   ALGO 3 K2RED    mlkem_dpi_k2red_reduce(a*b)      a * b * 169 mod Q
// This is mul(b, z) of the golden bfu. The DPI result is also cross-checked
// against the plain SV expression (a * b * SCALE) % Q with SCALE = 1, 2704,
// 1, 169 written here independently ("model_xcheck"), and SCALE against
// mlkem_dpi_algo_scale().
//
// Stimulus: every (a, b) in [0, Q) x [0, Q), a outer, b inner (Q^2 vectors).
// valid_i is dropped at random with probability GAP_PCT percent per cycle;
// junk data (any 12-bit values) is driven while valid_i is low.
//
// Checking: a reference delay line of depth LATENCY (read from the DUT) holds
// (valid, inputs, expected). Every cycle, valid_o must equal the delayed valid
// exactly, and when it is 1 p_o must equal the delayed expected value.
// Inputs are driven at the rising edge, outputs checked at the falling edge.
//
// Plusargs:
//   +SEED=<n>      RNG seed (default 1)
//   +GAP_PCT=<n>   percent of idle cycles inserted before each vector (default 0)
//   +OOR_TEST      instead of the exhaustive sweep, drive OOR_N = 3 valid
//                  out-of-range inputs, (Q, 0), (0, Q), (4095, 1) (the mod_mul
//                  assertion must fire exactly 3 times; their products stay
//                  inside every mod_red domain, so mod_red must not fire),
//                  plus in-range boundary vectors.
`timescale 1ns / 1ps

module tb_mod_mul;
  import mlkem_pkg::*;
  import mlkem_dpi_pkg::*;
  import tb_util_pkg::*;

  parameter int ALGO     = 0;           // mlkem_pkg::algo_e value
  parameter int MUL_REG  = 0;
  parameter int RED_PIPE = 0;

  localparam time T_CLK   = 10ns;
  localparam int  MAX_LAT = 8;
  localparam int  OOR_N   = 3;
  localparam int  SCALE   = (ALGO == int'(ALGO_MONT12)) ? 2704 :
                            (ALGO == int'(ALGO_K2RED))  ? 169  : 1;

  if (ALGO < 0 || ALGO > 3) begin : g_bad_algo
    $error("tb_mod_mul: ALGO=%0d not supported", ALGO);
  end

  logic              clk     = 1'b0;
  logic              rst_n   = 1'b0;
  logic [COEF_W-1:0] a_i     = '0;
  logic [COEF_W-1:0] b_i     = '0;
  logic              valid_i = 1'b0;
  logic [COEF_W-1:0] p_o;
  logic              valid_o;

  mod_mul #(.ALGO(algo_e'(ALGO)), .MUL_REG(MUL_REG), .RED_PIPE(RED_PIPE)) dut (.*);

  always #(T_CLK / 2) clk = ~clk;

  // --------------------------------------------------------------------------
  // Reference delay line and checkers
  // --------------------------------------------------------------------------
  typedef struct {
    bit v;
    int a;
    int b;
    int exp;   // -1: do not check data (out-of-range stimulus)
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

  function automatic int expected(int a, int b);
    int e     = golden(a * b);
    int ref_v = int'((longint'(a) * longint'(b) * SCALE) % Q);
    if (e == ref_v) chk_model.pass();
    else chk_model.fail($sformatf("DPI %s(%0d * %0d) = %0d, SV ref = %0d", algo_name(ALGO),
                                  a, b, e, ref_v));
    return e;
  endfunction

  task automatic check_outputs();
    ref_t r = ref_pipe[lat];
    if (valid_o === r.v) chk_valid.pass();
    else chk_valid.fail($sformatf("valid_o=%b expected %b", valid_o, r.v));
    if (r.v && r.exp >= 0) begin
      if (p_o === COEF_W'(r.exp)) chk_data.pass();
      else chk_data.fail($sformatf("a=%0d b=%0d expected p=%0d got %0d",
                                   r.a, r.b, r.exp, p_o));
    end
  endtask

  // One clock cycle. At the rising edge the DUT captures the previous inputs,
  // so the reference delay line advances, and the new inputs are applied with
  // nonblocking assignments (race free against the DUT flops). Outputs are
  // checked at the falling edge, when the inputs already hold the new vector:
  // a combinational path where a register is expected (or the reverse) then
  // shows up as a mismatch.
  task automatic cycle(bit v, int a, int b, int exp);
    @(posedge clk);
    for (int i = lat; i > 0; i--) ref_pipe[i] = ref_pipe[i - 1];
    valid_i     <= v;
    a_i         <= COEF_W'(a);
    b_i         <= COEF_W'(b);
    ref_pipe[0] = '{v: v, a: a, b: b, exp: exp};
    @(negedge clk);
    check_outputs();
  endtask

  task automatic idle();
    cycle(1'b0, $urandom_range(2 ** COEF_W - 1), $urandom_range(2 ** COEF_W - 1), -1);
  endtask

  task automatic send(int a, int b, int gap_pct);
    while ($urandom_range(99) < gap_pct) idle();
    cycle(1'b1, a, b, expected(a, b));
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
    foreach (ref_pipe[i]) ref_pipe[i] = '{v: 1'b0, a: 0, b: 0, exp: -1};

    $display("TB_CONFIG: tb_mod_mul ALGO=%0d(%s) MUL_REG=%0d RED_PIPE=%0d LATENCY=%0d SEED=%0d GAP_PCT=%0d OOR_TEST=%0d",
             ALGO, algo_name(ALGO), MUL_REG, RED_PIPE, lat, seed, gap_pct, oor_test);
    if (lat < 0 || lat > MAX_LAT) $fatal(1, "LATENCY %0d outside TB support", lat);
    // The DUT latency must be the documented sum of its two cut points.
    if (lat != MUL_REG + RED_PIPE)
      $fatal(1, "dut.LATENCY=%0d != MUL_REG + RED_PIPE = %0d", lat, MUL_REG + RED_PIPE);

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
      send(1, 2, 0);
      cycle(1'b1, Q, 0, -1);            idle();
      cycle(1'b1, 0, Q, -1);            idle();
      cycle(1'b1, 4095, 1, -1);         idle();
      send(Q - 1, Q - 1, 0);
      send(0, 0, 0);
      $display("OOR_TEST: drove %0d out-of-range valid inputs (assertion must fire %0d times)",
               OOR_N, OOR_N);
    end else begin
      for (int a = 0; a < Q; a++) begin
        for (int b = 0; b < Q; b++) send(a, b, gap_pct);
        if (a % 512 == 0) $display("PROGRESS: a=%0d vectors=%0d time=%0t", a, n_vec, $time);
      end
    end

    repeat (lat + 2) idle();

    $display("VECTORS: driven=%0d data_checks=%0d%s", n_vec, chk_data.n_checks,
             oor_test ? "" : $sformatf(" exhaustive_expected=%0d", longint'(Q) * Q));
    if (!oor_test && n_vec != longint'(Q) * Q) chk_data.fail("vector count is not Q^2");
    if (chk_data.n_checks != n_vec) chk_data.fail("data check count != vectors driven");
    ok = tb_final_report('{chk_data, chk_valid, chk_model});
    $finish;
  end

endmodule
