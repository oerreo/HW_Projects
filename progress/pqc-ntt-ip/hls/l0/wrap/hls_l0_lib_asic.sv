// Selects which Catapult build (target library) the HLS wrappers mod_red.sv
// and mod_mul.sv instantiate. Compile exactly one hls_l0_lib_<lib>.sv before
// the wrappers (sim/tests/hls_l0_*_<lib>.cfg).
package hls_l0_cfg_pkg;
  localparam string HLS_LIB = "asic";
endpackage
