// mod_red: reduction of a product-width value to [0, Q), variant chosen by ALGO.
//
// Thin wrapper: one instance of the selected variant and the port wiring, no
// logic of its own. All variants share the ports and LATENCY = PIPE.
//
//   ALGO           module              result            input domain
//   ALGO_BARRETT   mod_red_barrett     x mod Q           [0, 2^24)
//   ALGO_MONT12    mod_red_mont12      x * 2^-12 mod Q   [0, Q * 2^12)
//   ALGO_SHIFTADD  mod_red_shiftadd    x mod Q           [0, 2^24)
//   ALGO_K2RED     mod_red_k2red       169 * x mod Q     [0, 2^24)
//
// Scale factor (hierarchy.md): for MONT12 (S = 2^-12 = 2704 mod Q) and K2RED
// (S = 169) the output is x * S mod Q. The wrapper does NOT remove S. The
// datapath that uses mod_red removes it by operand pre-scaling, as fixed in
// docs/spec/arch.md: the zeta ROM stores zeta * S^-1, the gamma ROM stores
// gamma * S^-2, and basemul applies one extra multiply by K2 = S^-2 to
// data-by-data products. So a multiply mul(b, z) = b * z * S mod Q is exact
// whenever z comes from a pre-scaled ROM.
//
// Out-of-domain inputs are flagged by the variant's simulation assertion
// (tag L0_RANGE). Unsupported PIPE values fail elaboration in the variant.
module mod_red
  import mlkem_pkg::*;
#(
  parameter algo_e ALGO = ALGO_BARRETT, // reduction variant
  parameter int    PIPE = 0             // 0: comb, 1: output reg, 2: mid + output reg
) (
  input  logic              clk,
  input  logic              rst_n,      // async assert, sync deassert
  input  logic [PROD_W-1:0] x_i,        // variant domain, see table above
  input  logic              valid_i,
  output logic [COEF_W-1:0] r_o,        // x_i * S mod Q, [0, Q)
  output logic              valid_o
);

  // Every variant defines LATENCY = PIPE (the TB checks valid_o alignment
  // against this value).
  localparam int LATENCY = PIPE;

  if (ALGO == ALGO_BARRETT) begin : g_barrett
    mod_red_barrett #(.PIPE(PIPE)) u_red (.*);
  end else if (ALGO == ALGO_MONT12) begin : g_mont12
    mod_red_mont12 #(.PIPE(PIPE)) u_red (.*);
  end else if (ALGO == ALGO_SHIFTADD) begin : g_shiftadd
    mod_red_shiftadd #(.PIPE(PIPE)) u_red (.*);
  end else if (ALGO == ALGO_K2RED) begin : g_k2red
    mod_red_k2red #(.PIPE(PIPE)) u_red (.*);
  end else begin : g_bad_algo
    $error("mod_red: ALGO=%0d not supported", ALGO);
  end

endmodule
