/* C linkage wrapper of the ML-KEM golden model for SystemVerilog DPI-C.
 *
 * All values are canonical coefficients in [0, q) passed as int.
 * Polynomials are int[256]. In SystemVerilog, a fixed-size unpacked array
 * "int p[256]" maps to "const int*" (input) or "int*" (output).
 * mul_kind: 0 ref, 1 barrett, 2 shiftadd, 3 mont12, 4 mont16, 5 k2red.
 *
 * Example SystemVerilog imports:
 *   import "DPI-C" function int  mlkem_dpi_mod_mul(input int a, input int b);
 *   import "DPI-C" function int  mlkem_dpi_reduce(input int kind, input int x);
 *   import "DPI-C" function void mlkem_dpi_ct_butterfly(input int kind, input int a,
 *       input int b, input int zeta, output int a_out, output int b_out);
 *   import "DPI-C" function void mlkem_dpi_ntt(input int f[256], output int f_hat[256]);
 *   import "DPI-C" function void mlkem_dpi_intt(input int f_hat[256], output int f[256]);
 *   import "DPI-C" function void mlkem_dpi_multiply_ntts(input int a[256], input int b[256],
 *       output int c[256]);
 * Imports of the hardware-structure functions are listed in model/README.md.
 */
#ifndef MLKEM_DPI_H
#define MLKEM_DPI_H

#ifdef __cplusplus
extern "C" {
#endif

int mlkem_dpi_mod_add(int a, int b);
int mlkem_dpi_mod_sub(int a, int b);
int mlkem_dpi_mod_mul(int a, int b);

/* Raw reduction of x by the given candidate (bit-accurate model).
 * kind 0: x mod q          (any x >= 0)
 * kind 1: barrett          x in [0, 2^24)   returns x mod q
 * kind 2: shiftadd         x in [0, 2^24)   returns x mod q
 * kind 3: mont12           x in [0, q*2^12) returns x*2^-12 mod q
 * kind 4: mont16           x in [0, q*2^16) returns x*2^-16 mod q
 * kind 5: k2red            x in [0, 2^24)   returns 169*x mod q
 * Returns -1 if x is outside the domain or kind is unknown. */
int mlkem_dpi_reduce(int kind, int x);

/* Twiddle ROM value for canonical w under the given multiplier. */
int mlkem_dpi_twiddle_prescale(int kind, int w);
int mlkem_dpi_zeta(int i);  /* 17^BitRev7(i) mod q, i in [0, 128) */
int mlkem_dpi_gamma(int i); /* 17^(2*BitRev7(i)+1) mod q, i in [0, 128) */

/* zeta_rom = mlkem_dpi_twiddle_prescale(kind, zeta). */
void mlkem_dpi_ct_butterfly(int kind, int a, int b, int zeta_rom, int* a_out, int* b_out);
void mlkem_dpi_gs_butterfly(int kind, int a, int b, int zeta_rom, int* a_out, int* b_out);
void mlkem_dpi_basecase_multiply(int a0, int a1, int b0, int b1, int gamma, int* c0, int* c1);

void mlkem_dpi_ntt(const int* f, int* f_hat);
void mlkem_dpi_intt(const int* f_hat, int* f);
void mlkem_dpi_multiply_ntts(const int* f_hat, const int* g_hat, int* h_hat);

/* ------------------------------------------------------------------------
 * Hardware-structure model (include/mlkem_hw.h, docs/spec/arch.md)
 * ------------------------------------------------------------------------
 * algo: 0 BARRETT, 1 MONT12, 2 SHIFTADD, 3 K2RED  (arch.md order; NOT the
 *       mul_kind encoding above)
 * mode: 0 CT, 1 GS
 * Invalid algo / mode / out-of-domain inputs return -1 (or write -1 to the
 * outputs, or return -1 status for polynomial functions). */

/* Scalar reductions, x as in mlkem_dpi_reduce. -1 outside the domain. */
int mlkem_dpi_barrett_reduce(int x);   /* x in [0, 2^24),   x mod q        */
int mlkem_dpi_mont12_reduce(int x);    /* x in [0, q*2^12), x*2^-12 mod q  */
int mlkem_dpi_shiftadd_reduce(int x);  /* x in [0, 2^24),   x mod q        */
int mlkem_dpi_k2red_reduce(int x);     /* x in [0, 2^24),   169*x mod q    */
int mlkem_dpi_mod_half(int x);         /* x in [0, q),      x*2^-1 mod q   */

/* bfu(algo, mode, a, b, z), a, b, z in [0, q).
 * CT: x = a + mul(b,z), y = a - mul(b,z); GS: x = half(a+b), y = half(mul(b-a,z));
 * mul(b,z) = b*z*S mod q. */
void mlkem_dpi_bfu(int algo, int mode, int a, int b, int z, int* x, int* y);
/* S, S^-1, S^-2 of the multiplier of algo. */
int mlkem_dpi_algo_scale(int algo, int power); /* power: 1 -> S, -1 -> S^-1, -2 -> S^-2 */

/* ROM lookup. rom_kind: 0 zeta ROM (index 0..127), 1 gamma ROM (0..127),
 * 2 K2 constant (index 0). */
int mlkem_dpi_rom(int algo, int rom_kind, int index);

/* Transform schedule step (data independent). mode 0 = NTT (CT), 1 = INTT (GS).
 * step in [0, 896). Outputs layer, len, addr0, addr1, zeta_addr; the read bank
 * of the step is (in_bank ^ (layer & 1)), the write bank its complement.
 * Returns 0, or -1 if mode / step is out of range. */
int mlkem_dpi_hw_sched(int mode, int step, int* layer, int* len, int* addr0, int* addr1,
                       int* zeta_addr);

/* basemul micro-op program. Number of ops (5 or 7), -1 for invalid algo. */
int mlkem_dpi_basemul_nops(int algo);
/* Op idx: a_src/b_src/z_src: 0 ZERO, 1 A0, 2 A1, 3 B0, 4 B1, 5 R0, 6 R1, 7 GAMMA, 8 K2;
 * dst: 0 R0, 1 R1, 2 C0, 3 C1. Returns 0, or -1 if out of range. */
int mlkem_dpi_basemul_op(int algo, int idx, int* a_src, int* b_src, int* z_src, int* dst);
/* One coefficient pair through the micro-op program (gamma ROM address = pair). */
int mlkem_dpi_hw_basemul_pair(int algo, int a0, int a1, int b0, int b1, int pair, int* c0,
                              int* c1);

/* Polynomial level on the hardware schedule. Return 0, or -1 on invalid algo /
 * coefficient outside [0, q). Results equal mlkem_dpi_ntt / intt / multiply_ntts. */
int mlkem_dpi_hw_ntt(int algo, const int* f, int* f_hat);
int mlkem_dpi_hw_intt(int algo, const int* f_hat, int* f);
int mlkem_dpi_hw_basemul(int algo, const int* f_hat, const int* g_hat, int* h_hat);

#ifdef __cplusplus
}
#endif

#endif /* MLKEM_DPI_H */
