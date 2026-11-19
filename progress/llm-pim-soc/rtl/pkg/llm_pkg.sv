// llm_pkg: common widths of the llm-pim-soc kernel IPs (docs/spec/hierarchy.md 3.1).
// E_W and SH_W were fixed in S4-1 from the K12V8 dump ranges
// (model/results/range_k12v8.txt: exponents 0..33, shifts -1..40).
package llm_pkg;
  localparam int E_W    = 8;     // signed exponent (we, e, fo, qe, ke, ve)
  localparam int SH_W   = 10;    // signed shift built from exponent sums (sh = we + xe - fo)
  localparam int AM_W   = 17;    // activation scale mantissa m (< 2^17), unsigned
  localparam int WM_W   = 16;    // weight row mantissa wm, unsigned
  localparam int N_MAX  = 1024;  // gemv row length / vector length limit
  localparam int T_MAX  = 512;   // attention length limit
  localparam int HS_MAX = 64;    // head size limit
  localparam int IDX_W  = 16;    // argmax index
endpackage
