// mlkem_pkg: common parameters of the ML-KEM (FIPS 203) NTT datapath.
// Coefficients are canonical unsigned values in [0, Q) held in COEF_W bits.
package mlkem_pkg;

  localparam int COEF_W = 12;            // coefficient width
  localparam int Q      = 3329;          // ML-KEM modulus
  localparam int Q_INV2 = (Q + 1) / 2;   // 2^-1 mod Q = 1665
  localparam int PROD_W = 2 * COEF_W;    // product width before reduction (24)

  // Supported range of the per-module PIPE parameter of the L0 modules.
  localparam int L0_PIPE_MAX = 1;
  // mod_red variants have one internal cut point, so PIPE may also be 2.
  localparam int MOD_RED_PIPE_MAX = 2;

  // Reduction variant (docs/spec/arch.md, "correction" section). The numeric
  // values equal the algo argument of the golden model DPI-C functions
  // (model/include/mlkem_dpi.h). They differ from the older mul_kind encoding
  // of mlkem_dpi_reduce(); do not mix the two.
  //   BARRETT  : r = x mod Q
  //   MONT12   : r = x * 2^-12 mod Q
  //   SHIFTADD : r = x mod Q
  //   K2RED    : r = 169 * x mod Q
  typedef enum logic [1:0] {
    ALGO_BARRETT  = 2'd0,
    ALGO_MONT12   = 2'd1,
    ALGO_SHIFTADD = 2'd2,
    ALGO_K2RED    = 2'd3
  } algo_e;

  // bfu butterfly mode, same values as the DPI-C mode argument.
  typedef enum logic {
    MODE_CT = 1'b0,
    MODE_GS = 1'b1
  } mode_e;

endpackage
