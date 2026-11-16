// mlkem_dpi_pkg: DPI-C imports of the golden model C linkage wrapper
// (model/include/mlkem_dpi.h, model/src/mlkem_dpi.cpp).
//
// The C++ sources are compiled by vlog together with the SV files
// (see sim/run.sh, DPI=1 in sim/tests/<name>.cfg). All values are int.
// mul_kind: 0 ref, 1 barrett, 2 shiftadd, 3 mont12, 4 mont16, 5 k2red.
package mlkem_dpi_pkg;

  import "DPI-C" pure function int mlkem_dpi_mod_add(input int a, input int b);
  import "DPI-C" pure function int mlkem_dpi_mod_sub(input int a, input int b);
  import "DPI-C" pure function int mlkem_dpi_mod_mul(input int a, input int b);
  // Returns -1 when x is outside the domain of the candidate or kind is unknown.
  import "DPI-C" pure function int mlkem_dpi_reduce(input int kind, input int x);
  import "DPI-C" pure function int mlkem_dpi_twiddle_prescale(input int kind, input int w);
  import "DPI-C" pure function int mlkem_dpi_zeta(input int i);
  import "DPI-C" pure function int mlkem_dpi_gamma(input int i);

  import "DPI-C" function void mlkem_dpi_ct_butterfly(input int kind, input int a, input int b,
      input int zeta_rom, output int a_out, output int b_out);
  import "DPI-C" function void mlkem_dpi_gs_butterfly(input int kind, input int a, input int b,
      input int zeta_rom, output int a_out, output int b_out);
  import "DPI-C" function void mlkem_dpi_basecase_multiply(input int a0, input int a1,
      input int b0, input int b1, input int gamma, output int c0, output int c1);

  import "DPI-C" function void mlkem_dpi_ntt(input int f[256], output int f_hat[256]);
  import "DPI-C" function void mlkem_dpi_intt(input int f_hat[256], output int f[256]);
  import "DPI-C" function void mlkem_dpi_multiply_ntts(input int f_hat[256], input int g_hat[256],
      output int h_hat[256]);

  // --------------------------------------------------------------------------
  // Hardware-structure model (model/include/mlkem_dpi.h is the authority)
  // --------------------------------------------------------------------------
  // algo: 0 BARRETT, 1 MONT12, 2 SHIFTADD, 3 K2RED (mlkem_pkg::algo_e, NOT the
  // mul_kind encoding above). mode: 0 CT, 1 GS (mlkem_pkg::mode_e).
  // Invalid algo / mode / out-of-domain inputs return -1.

  // Scalar reductions:
  //   barrett  x in [0, 2^24)   -> x mod q
  //   mont12   x in [0, q*2^12) -> x * 2^-12 mod q
  //   shiftadd x in [0, 2^24)   -> x mod q
  //   k2red    x in [0, 2^24)   -> 169 * x mod q
  //   mod_half x in [0, q)      -> x * 2^-1 mod q
  import "DPI-C" pure function int mlkem_dpi_barrett_reduce(input int x);
  import "DPI-C" pure function int mlkem_dpi_mont12_reduce(input int x);
  import "DPI-C" pure function int mlkem_dpi_shiftadd_reduce(input int x);
  import "DPI-C" pure function int mlkem_dpi_k2red_reduce(input int x);
  import "DPI-C" pure function int mlkem_dpi_mod_half(input int x);

  // CT: x = a + mul(b,z), y = a - mul(b,z); GS: x = half(a+b), y = half(mul(b-a,z)).
  import "DPI-C" function void mlkem_dpi_bfu(input int algo, input int mode, input int a,
      input int b, input int z, output int x, output int y);
  // power: 1 (S), -1 (S^-1), -2 (S^-2)
  import "DPI-C" pure function int mlkem_dpi_algo_scale(input int algo, input int power);
  // rom_kind: 0 zeta ROM (index 0..127), 1 gamma ROM (0..127), 2 K2 (index 0)
  import "DPI-C" pure function int mlkem_dpi_rom(input int algo, input int rom_kind,
      input int index);
  // mode 0 NTT, 1 INTT; step 0..895. read bank = in_bank ^ (layer & 1)
  import "DPI-C" function int mlkem_dpi_hw_sched(input int mode, input int step,
      output int layer, output int len, output int addr0, output int addr1,
      output int zeta_addr);
  import "DPI-C" pure function int mlkem_dpi_basemul_nops(input int algo);
  // src: 0 ZERO 1 A0 2 A1 3 B0 4 B1 5 R0 6 R1 7 GAMMA 8 K2; dst: 0 R0 1 R1 2 C0 3 C1
  import "DPI-C" function int mlkem_dpi_basemul_op(input int algo, input int idx,
      output int a_src, output int b_src, output int z_src, output int dst);
  import "DPI-C" function int mlkem_dpi_hw_basemul_pair(input int algo, input int a0,
      input int a1, input int b0, input int b1, input int pair, output int c0, output int c1);
  import "DPI-C" function int mlkem_dpi_hw_ntt(input int algo, input int f[256],
      output int f_hat[256]);
  import "DPI-C" function int mlkem_dpi_hw_intt(input int algo, input int f_hat[256],
      output int f[256]);
  import "DPI-C" function int mlkem_dpi_hw_basemul(input int algo, input int f_hat[256],
      input int g_hat[256], output int h_hat[256]);

endpackage
