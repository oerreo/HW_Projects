// ML-KEM (FIPS 203) NTT golden model: Algorithms 9, 10, 11, 12.
//
// All coefficients are canonical unsigned in [0, q).
// The twiddle multiplier is selectable (MulKind) so that every reduction
// candidate can be run through the full transform. Outputs are identical for
// every MulKind; only the twiddle ROM contents differ.
#ifndef MLKEM_NTT_H
#define MLKEM_NTT_H

#include <array>
#include <cstdint>
#include <vector>

#include "mlkem_modarith.h"
#include "mlkem_params.h"

namespace mlkem {

using Poly = std::array<uint16_t, N>;
using Table128 = std::array<uint16_t, 128>;

// 7-bit bit reversal.
uint32_t bitrev7(uint32_t i);

// zeta_table()[i]  = 17^BitRev7(i) mod q, i = 0..127 (FIPS 203 Appendix A, first table).
// gamma_table()[i] = 17^(2*BitRev7(i)+1) mod q, i = 0..127 (Appendix A, second table).
// Generated from powers of 17 at first use, not hard coded.
const Table128& zeta_table();
const Table128& gamma_table();

// twiddle_rom(k)[i] = twiddle_prescale(k, zeta_table()[i]).
const Table128& twiddle_rom(MulKind k);
// Value used for the final 128^-1 scaling in the INTT under multiplier k.
uint16_t intt_scale_rom(MulKind k);

// ---------------------------------------------------------------------------
// Butterflies
// ---------------------------------------------------------------------------
// CT (forward, Algorithm 9 lines 8-10):
//   t = zeta*b; a_out = a + t; b_out = a - t        (mod q)
// GS (inverse, Algorithm 10 lines 8-10):
//   a_out = a + b; b_out = zeta*(b - a)             (mod q)
// in: a, b in [0, q), w_rom = twiddle_prescale(k, zeta). out: [0, q).
struct BflyOut {
  uint16_t a;
  uint16_t b;
};
BflyOut ct_butterfly(MulKind k, uint16_t a, uint16_t b, uint16_t w_rom);
BflyOut gs_butterfly(MulKind k, uint16_t a, uint16_t b, uint16_t w_rom);

// One butterfly as executed inside a transform (for dumps).
struct ButterflyRecord {
  int layer;        // 0..6 in execution order
  int len;          // butterfly distance
  int zeta_idx;     // i in zeta^BitRev7(i)
  int j0;           // index of the "a" operand, "b" is j0 + len
  uint16_t a_in, b_in;
  uint16_t zeta;    // canonical zeta^BitRev7(zeta_idx)
  uint16_t w_rom;   // ROM value under the chosen MulKind
  uint16_t a_out, b_out;
};

// Optional observation hooks. trace receives every butterfly in execution
// order (7 * 128 records). layer_out receives the full array after each layer
// (7 entries for ntt, 8 for intt: 7 layers then the 128^-1 scaling).
struct NttObserver {
  std::vector<ButterflyRecord>* trace = nullptr;
  std::vector<Poly>* layer_out = nullptr;
};

// Algorithm 9.  in: f (coefficients). out: f_hat (NTT representation).
Poly ntt(const Poly& f, MulKind k = MulKind::Ref, const NttObserver* obs = nullptr);
// Algorithm 10. in: f_hat. out: f, including the final * 3303.
Poly intt(const Poly& f_hat, MulKind k = MulKind::Ref, const NttObserver* obs = nullptr);

// Algorithm 12. c0 = a0*b0 + a1*b1*gamma, c1 = a0*b1 + a1*b0 (mod q).
// k must be Ref, Barrett or ShiftAdd (operands are not twiddles, so no
// ROM pre-scaling is available for Montgomery / K2-RED; see README).
BflyOut basecase_multiply(uint16_t a0, uint16_t a1, uint16_t b0, uint16_t b1, uint16_t gamma,
                          MulKind k = MulKind::Ref);
// Algorithm 11.
Poly multiply_ntts(const Poly& f_hat, const Poly& g_hat, MulKind k = MulKind::Ref);

// Negacyclic schoolbook product f*g mod (X^256 + 1, q). Independent of the
// NTT code and of the reduction models (plain int64 and '%').
Poly poly_mul_schoolbook(const Poly& f, const Poly& g);

}  // namespace mlkem

#endif  // MLKEM_NTT_H
