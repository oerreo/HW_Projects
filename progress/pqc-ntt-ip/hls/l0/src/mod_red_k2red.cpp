// Catapult top-level function for mod_red, ALGO = K2RED.
// r = k2red_reduce(x), see hls/l0/include/mlkem_red_hls.h. x in [0, 2^24).
//
// The function name is HLS_TOP so that every Catapult configuration of this
// block can get a unique top-level module name (the Tcl flow passes
// -DHLS_TOP=<name>); it defaults to mod_red_k2red_hls for the C test.
#include "mlkem_red_hls.h"

#ifndef HLS_TOP
#define HLS_TOP mod_red_k2red_hls
#endif

#pragma hls_design top
void HLS_TOP(mlkem_hls::prod_t x, mlkem_hls::coef_t &r) {
  r = mlkem_hls::k2red_reduce_hls(x);
}
