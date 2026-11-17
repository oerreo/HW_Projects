// Catapult top-level function for mod_mul, ALGO = BARRETT.
// p = barrett_reduce(a * b), see hls/l0/include/mlkem_red_hls.h. a, b in [0, q).
//
// The function name is HLS_TOP so that every Catapult configuration of this
// block can get a unique top-level module name (the Tcl flow passes
// -DHLS_TOP=<name>); it defaults to mod_mul_barrett_hls for the C test.
#include "mlkem_red_hls.h"

#ifndef HLS_TOP
#define HLS_TOP mod_mul_barrett_hls
#endif

#pragma hls_design top
void HLS_TOP(mlkem_hls::coef_t a, mlkem_hls::coef_t b, mlkem_hls::coef_t &p) {
  p = mlkem_hls::mod_mul_barrett_hls(a, b);
}
