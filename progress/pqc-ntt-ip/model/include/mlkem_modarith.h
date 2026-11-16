// ML-KEM (FIPS 203) modular arithmetic golden model, q = 3329.
//
// Representation: canonical unsigned, every coefficient in [0, q) (12 bits).
//
// Two layers:
//   1. Reference functions (*_ref): plain C++ '%', used as the oracle.
//   2. Bit-accurate hardware candidate models. Every intermediate value is
//      held in a fixed-width integer and annotated with its bit width
//      ("[msb:0]" for unsigned, "s<N>" for N-bit two's complement signed).
//      Truncations that hardware would perform are written explicitly as masks.
//
// Width assertions: when compiled with -DMLKEM_CHECK_WIDTHS, every annotated
// intermediate is checked against its declared width at run time and any
// overflow increments mlkem::g_width_violations. The test build enables this.
#ifndef MLKEM_MODARITH_H
#define MLKEM_MODARITH_H

#include <cstdint>

#include "mlkem_params.h"

namespace mlkem {

// Arithmetic right shift is relied on for signed models (bit select in HW).
static_assert((-1 >> 1) == -1, "arithmetic right shift required");

// ---------------------------------------------------------------------------
// Width assertion helpers
// ---------------------------------------------------------------------------
inline uint64_t g_width_violations = 0;
inline uint64_t g_width_checks = 0;

#ifdef MLKEM_CHECK_WIDTHS
inline void check_uw(uint64_t v, unsigned bits) {
  ++g_width_checks;
  if (bits < 64 && (v >> bits) != 0) ++g_width_violations;
}
inline void check_sw(int64_t v, unsigned bits) {
  ++g_width_checks;
  const int64_t lo = -(int64_t(1) << (bits - 1));
  const int64_t hi = (int64_t(1) << (bits - 1)) - 1;
  if (v < lo || v > hi) ++g_width_violations;
}
#define MLKEM_UW(v, bits) ::mlkem::check_uw(uint64_t(v), (bits))
#define MLKEM_SW(v, bits) ::mlkem::check_sw(int64_t(v), (bits))
#else
#define MLKEM_UW(v, bits) ((void)0)
#define MLKEM_SW(v, bits) ((void)0)
#endif

// ---------------------------------------------------------------------------
// Compile-time helpers (constant generation only, not hardware models)
// ---------------------------------------------------------------------------
constexpr uint32_t pow_mod(uint32_t base, uint32_t exp) {
  uint64_t r = 1, b = base % Q;
  while (exp) {
    if (exp & 1) r = r * b % Q;
    b = b * b % Q;
    exp >>= 1;
  }
  return uint32_t(r);
}
constexpr uint32_t inv_mod(uint32_t a) { return pow_mod(a, Q - 2); }  // q prime

// -q^-1 mod 2^k, by Newton iteration on 2-adic inverse.
constexpr uint32_t neg_qinv_mod_2k(unsigned k) {
  uint64_t inv = 1;
  for (int i = 0; i < 6; ++i) inv = inv * (2 - uint64_t(Q) * inv);
  const uint64_t mask = (uint64_t(1) << k) - 1;
  return uint32_t((0 - inv) & mask);
}

// ---------------------------------------------------------------------------
// Reference (oracle)
// ---------------------------------------------------------------------------
// in: a, b in [0, q). out: [0, q).
inline uint16_t mod_add_ref(uint16_t a, uint16_t b) { return uint16_t((uint32_t(a) + b) % Q); }
inline uint16_t mod_sub_ref(uint16_t a, uint16_t b) { return uint16_t((uint32_t(a) + Q - b) % Q); }
inline uint16_t mod_mul_ref(uint16_t a, uint16_t b) { return uint16_t((uint32_t(a) * b) % Q); }
// in: any x. out: x mod q in [0, q).
inline uint16_t mod_reduce_ref(uint64_t x) { return uint16_t(x % Q); }

// ---------------------------------------------------------------------------
// Modular add / sub (hardware form)
// ---------------------------------------------------------------------------
// mod_add_hw: in a, b in [0, q). out [0, q).
// 1 adder (13b) + 1 subtractor (14b, sign = select) + 12b mux.
inline uint16_t mod_add_hw(uint16_t a, uint16_t b) {
  const uint16_t s = uint16_t(a + b);         // [12:0], max 2q-2 = 6656
  MLKEM_UW(s, 13);
  const int16_t d = int16_t(int16_t(s) - int16_t(Q));  // s14, [-3329, 3327]
  MLKEM_SW(d, 14);
  return d < 0 ? s : uint16_t(d);
}

// mod_sub_hw: in a, b in [0, q). out (a - b) mod q in [0, q).
// 1 subtractor (13b signed) + 1 adder (12b) + 12b mux.
inline uint16_t mod_sub_hw(uint16_t a, uint16_t b) {
  const int16_t d = int16_t(int16_t(a) - int16_t(b));  // s13, [-3328, 3328]
  MLKEM_SW(d, 13);
  const uint16_t c = uint16_t(d + int16_t(Q));          // [12:0], used when d < 0
  MLKEM_UW(c, 13);
  return d < 0 ? c : uint16_t(d);
}

// ---------------------------------------------------------------------------
// Modular halving (hardware form), used on both GS outputs of the bfu
// ---------------------------------------------------------------------------
// mod_half_ref: in x in [0, q). out x * 2^-1 mod q in [0, q) (oracle).
constexpr uint32_t Q_INV2 = (Q + 1) / 2;  // 2^-1 mod q = 1665
static_assert((2 * Q_INV2) % Q == 1, "2^-1 mod q");
inline uint16_t mod_half_ref(uint16_t x) { return uint16_t((uint32_t(x) * Q_INV2) % Q); }

// mod_half_hw: in x in [0, q). out h with 2h = x (mod q), h in [0, q).
// h = (x >> 1) + (x[0] ? (q + 1) / 2 : 0). x odd: 2h = x - 1 + q + 1 = x + q.
// Max at x = q - 2 = 3327: 1663 + 1665 = 3328 < q, so no carry and no
// correction. 1 adder (12b) + 12b mux on the constant.
inline uint16_t mod_half(uint16_t x) {
  MLKEM_UW(x, 12);
  const uint16_t sh = uint16_t(x >> 1);                         // [10:0]
  MLKEM_UW(sh, 11);
  const uint16_t h = uint16_t(sh + ((x & 1u) ? Q_INV2 : 0u));   // [11:0], value in [0, q)
  MLKEM_UW(h, 12);
  return h;
}

// ---------------------------------------------------------------------------
// Barrett reduction, k = 24
// ---------------------------------------------------------------------------
// m = floor(2^24 / q) = 5039 (13b). For x < 2^24 the quotient estimate
// qhat = floor(x * m / 2^24) satisfies floor(x/q) - 1 <= qhat <= floor(x/q),
// so r = x - qhat*q is in [0, 2q) and one conditional subtraction finishes.
// Because r < 2^14 is known, x - qhat*q is computed on the low 14 bits only.
constexpr unsigned BARRETT_K = 24;
constexpr uint32_t BARRETT_M = (uint32_t(1) << BARRETT_K) / Q;  // 5039
static_assert(BARRETT_M == 5039, "Barrett constant");

// barrett_reduce: in x in [0, 2^24) (covers any product of two 12b values).
//                 out x mod q in [0, q).
inline uint16_t barrett_reduce(uint32_t x) {
  MLKEM_UW(x, 24);
  const uint64_t xm = uint64_t(x) * BARRETT_M;       // [36:0] 24b x 13b const
  MLKEM_UW(xm, 37);
  const uint32_t qhat = uint32_t(xm >> BARRETT_K);    // [12:0], max 5038
  MLKEM_UW(qhat, 13);
  const uint32_t qq_lo = (qhat * Q) & 0x3FFFu;        // [13:0] low bits of 13b x 12b const
  const uint16_t r = uint16_t((x - qq_lo) & 0x3FFFu); // [13:0], value in [0, 2q)
  MLKEM_UW(r, 14);
  const int16_t d = int16_t(int16_t(r) - int16_t(Q));  // s14
  MLKEM_SW(d, 14);
  return d < 0 ? r : uint16_t(d);
}

// ---------------------------------------------------------------------------
// Montgomery reduction, R = 2^12 (primary) and R = 2^16 (pq-crystals style)
// ---------------------------------------------------------------------------
// Choice of R: R = 2^12 is the smallest power of two above q, so
//   * t = (x mod R) * q' mod R is a 12b value (12b x 12b-const, low half only),
//   * t * q is 12b x 12b-const, the sum x + t*q is 25b,
//   * and the input domain [0, q*R) still contains every product a*b < q^2.
// R = 2^16 buys nothing for canonical unsigned operands (it exists in
// pq-crystals for int16 signed lazy reduction) and widens t to 16b and the
// sum to 29b. Both are modeled; R = 2^12 is the hardware candidate.
// Note: q' = -q^-1 mod 2^k equals 3327 for both k = 12 and k = 16.
// Mod 2^12, q^-1 = 769 = 2^9 + 2^8 + 1, so t = -(xl + (xl<<8) + (xl<<9)) mod 2^12
// is a 3-input adder on 12 bits (no multiplier).
constexpr uint32_t MONT12_QPRIME = neg_qinv_mod_2k(12);         // 3327
constexpr uint32_t MONT16_QPRIME = neg_qinv_mod_2k(16);         // 3327
constexpr uint32_t MONT12_R_MOD_Q = (uint32_t(1) << 12) % Q;    // 767
constexpr uint32_t MONT16_R_MOD_Q = (uint32_t(1) << 16) % Q;    // 2285
constexpr uint32_t MONT12_RINV = inv_mod(MONT12_R_MOD_Q);
constexpr uint32_t MONT16_RINV = inv_mod(MONT16_R_MOD_Q);
static_assert(MONT12_QPRIME == 3327 && MONT16_QPRIME == 3327, "q'");
static_assert((uint64_t(Q) * MONT12_QPRIME + 1) % 4096 == 0, "q' mod 2^12");
static_assert((uint64_t(Q) * MONT16_QPRIME + 1) % 65536 == 0, "q' mod 2^16");

// mont12_reduce: in x in [0, q*2^12) = [0, 13635584) (24b).
//                out x * 2^-12 mod q in [0, q).
inline uint16_t mont12_reduce(uint32_t x) {
  MLKEM_UW(x, 24);
  const uint16_t xl = uint16_t(x & 0xFFFu);                       // [11:0]
  const uint32_t xl_qinv = uint32_t(xl) + (uint32_t(xl) << 8) + (uint32_t(xl) << 9);  // xl*769
  const uint16_t t = uint16_t((0u - xl_qinv) & 0xFFFu);           // [11:0] = xl*q' mod 2^12
  MLKEM_UW(t, 12);
  const uint32_t tq = uint32_t(t) * Q;                            // [23:0] 12b x 12b const
  MLKEM_UW(tq, 24);
  const uint32_t s = x + tq;                                      // [24:0], low 12 bits are 0
  MLKEM_UW(s, 25);
  const uint16_t u = uint16_t(s >> 12);                           // [12:0], value in [0, 2q)
  MLKEM_UW(u, 13);
  const int16_t d = int16_t(int16_t(u) - int16_t(Q));             // s14
  MLKEM_SW(d, 14);
  return d < 0 ? u : uint16_t(d);
}

// mont16_reduce: in x in [0, q*2^16) = [0, 218169344) (28b).
//                out x * 2^-16 mod q in [0, q).
inline uint16_t mont16_reduce(uint32_t x) {
  MLKEM_UW(x, 28);
  const uint16_t xl = uint16_t(x & 0xFFFFu);                      // [15:0]
  const uint16_t t = uint16_t((uint32_t(xl) * MONT16_QPRIME) & 0xFFFFu);  // [15:0]
  MLKEM_UW(t, 16);
  const uint32_t tq = uint32_t(t) * Q;                            // [27:0] 16b x 12b const
  MLKEM_UW(tq, 28);
  const uint32_t s = x + tq;                                      // [28:0], low 16 bits are 0
  MLKEM_UW(s, 29);
  const uint16_t u = uint16_t(s >> 16);                           // [12:0], value in [0, 2q)
  MLKEM_UW(u, 13);
  const int16_t d = int16_t(int16_t(u) - int16_t(Q));
  MLKEM_SW(d, 14);
  return d < 0 ? u : uint16_t(d);
}

// ---------------------------------------------------------------------------
// q-specific shift-add reduction: 2^12 = 2^9 + 2^8 - 1 (mod q)
// ---------------------------------------------------------------------------
// One fold maps x = h*2^12 + l to h*767 + l with h*767 = (h<<9) + (h<<8) - h.
// The fold is a 3-input add/sub (two adder levels), no multiplier.
// Folds needed for a 24b input (analytic upper bounds, checked by asserts):
//   y1 <= 3144960 (22b), y2 <= 592384 (20b), y3 <= 114543 (17b),
//   y4 <= 24804 (15b),   y5 <= 8697 (14b) < 3q,
// then a 3-way select between y5, y5 - q, y5 - 2q.
// Measured maxima (exhaustive): over all x < 2^24, y1..y5 = 3144960, 591617,
// 113776, 24037, 7392 (y5 > 2q, so the y5 - 2q branch is needed). Over products
// a*b with a, b < q only: 2073979, 389625, 74659, 17134, 6396 (y5 < 2q, so a
// multiplier-only datapath could drop the 2q branch).
inline uint32_t shiftadd_fold(uint32_t x) {
  const uint32_t h = x >> 12;
  const uint32_t l = x & 0xFFFu;
  return (h << 9) + (h << 8) - h + l;
}

// shiftadd_reduce: in x in [0, 2^24). out x mod q in [0, q).
inline uint16_t shiftadd_reduce(uint32_t x) {
  MLKEM_UW(x, 24);
  const uint32_t y1 = shiftadd_fold(x);   // [21:0], h is 12b
  MLKEM_UW(y1, 22);
  const uint32_t y2 = shiftadd_fold(y1);  // [19:0], h is 10b
  MLKEM_UW(y2, 20);
  const uint32_t y3 = shiftadd_fold(y2);  // [16:0], h is 8b
  MLKEM_UW(y3, 17);
  const uint32_t y4 = shiftadd_fold(y3);  // [14:0], h is 5b
  MLKEM_UW(y4, 15);
  const uint16_t y5 = uint16_t(shiftadd_fold(y4));  // [13:0], h is 3b, value < 3q
  MLKEM_UW(y5, 14);
  const int16_t d1 = int16_t(int16_t(y5) - int16_t(Q));      // s15
  const int16_t d2 = int16_t(int16_t(y5) - int16_t(2 * Q));  // s15
  MLKEM_SW(d1, 15);
  MLKEM_SW(d2, 15);
  if (d2 >= 0) return uint16_t(d2);
  if (d1 >= 0) return uint16_t(d1);
  return y5;
}

// ---------------------------------------------------------------------------
// K-RED family (Longa and Naehrig 2016), q = k*2^m + 1 with k = 13, m = 8
// ---------------------------------------------------------------------------
// K-RED(C) = k*(C mod 2^m) - (C >> m) is congruent to k*C mod q, because
// k*2^m = -1 (mod q). K2-RED applies it twice and is congruent to k^2*C = 169*C.
// A single K-RED on a 24b product still leaves a 17b value, so K2-RED is the
// useful form. The factor 169 is removed by pre-scaling one operand
// (twiddle) by 169^-1 mod q, see mod_mul_k2red().
constexpr uint32_t KRED_K = 13;
constexpr unsigned KRED_M = 8;
constexpr uint32_t K2RED_FACTOR = KRED_K * KRED_K;               // 169
constexpr uint32_t K2RED_FACTOR_INV = inv_mod(K2RED_FACTOR);     // 169^-1 mod q
static_assert(KRED_K * (1u << KRED_M) + 1 == Q, "q = k*2^m + 1");

// k2red_reduce: in x in [0, 2^24). out 169*x mod q in [0, q).
// k*c is (c<<3) + (c<<2) + c.
inline uint16_t k2red_reduce(uint32_t x) {
  MLKEM_UW(x, 24);
  const uint32_t c0 = x & 0xFFu;                                   // [7:0]
  const uint32_t c1 = x >> 8;                                      // [15:0]
  const int32_t r1 = int32_t((c0 << 3) + (c0 << 2) + c0) - int32_t(c1);  // s17, [-65535, 3315]
  MLKEM_SW(r1, 17);
  const uint32_t r1_0 = uint32_t(r1) & 0xFFu;                      // [7:0]
  const int32_t r1_1 = r1 >> 8;                                    // s9, [-256, 12]
  MLKEM_SW(r1_1, 9);
  const int32_t r2 = int32_t((r1_0 << 3) + (r1_0 << 2) + r1_0) - r1_1;  // s13, [-12, 3571]
  MLKEM_SW(r2, 13);
  // Final correction: one of {r2 + q, r2, r2 - q} is in [0, q).
  if (r2 < 0) return uint16_t(r2 + int32_t(Q));
  const int32_t d = r2 - int32_t(Q);                               // s13
  MLKEM_SW(d, 13);
  return d < 0 ? uint16_t(r2) : uint16_t(d);
}

// ---------------------------------------------------------------------------
// Modular multiplication built on each reduction
// ---------------------------------------------------------------------------
// All take a in [0, q) and an operand in [0, q); the product (24b) is
// computed by one 12b x 12b multiplier.
//   mod_mul_barrett(a, b)          = a*b mod q
//   mod_mul_shiftadd(a, b)         = a*b mod q
//   mod_mul_mont12(a, bm)          = a*bm*2^-12 mod q   (bm = b*2^12 mod q gives a*b)
//   mod_mul_mont16(a, bm)          = a*bm*2^-16 mod q
//   mod_mul_k2red(a, bk)           = 169*a*bk mod q     (bk = b*169^-1 mod q gives a*b)
inline uint32_t mul12x12(uint16_t a, uint16_t b) {
  const uint32_t p = uint32_t(a) * b;  // [23:0]
  MLKEM_UW(p, 24);
  return p;
}
inline uint16_t mod_mul_barrett(uint16_t a, uint16_t b) { return barrett_reduce(mul12x12(a, b)); }
inline uint16_t mod_mul_shiftadd(uint16_t a, uint16_t b) { return shiftadd_reduce(mul12x12(a, b)); }
inline uint16_t mod_mul_mont12(uint16_t a, uint16_t b) { return mont12_reduce(mul12x12(a, b)); }
inline uint16_t mod_mul_mont16(uint16_t a, uint16_t b) { return mont16_reduce(mul12x12(a, b)); }
inline uint16_t mod_mul_k2red(uint16_t a, uint16_t b) { return k2red_reduce(mul12x12(a, b)); }

// ---------------------------------------------------------------------------
// Datapath multiplier selection for the NTT model
// ---------------------------------------------------------------------------
// The multiplier in a butterfly always has one constant operand (twiddle).
// For Montgomery and K2-RED the twiddle ROM stores a pre-scaled value so that
// the butterfly output stays canonical and identical to the reference.
enum class MulKind : int { Ref = 0, Barrett, ShiftAdd, Mont12, Mont16, K2Red };
constexpr int NUM_MUL_KINDS = 6;

inline const char* mul_kind_name(MulKind k) {
  switch (k) {
    case MulKind::Ref: return "ref";
    case MulKind::Barrett: return "barrett";
    case MulKind::ShiftAdd: return "shiftadd";
    case MulKind::Mont12: return "mont12";
    case MulKind::Mont16: return "mont16";
    case MulKind::K2Red: return "k2red";
  }
  return "?";
}

// Value stored in the twiddle ROM for constant w under a given multiplier.
inline uint16_t twiddle_prescale(MulKind k, uint16_t w) {
  switch (k) {
    case MulKind::Mont12: return mod_mul_ref(w, uint16_t(MONT12_R_MOD_Q));
    case MulKind::Mont16: return mod_mul_ref(w, uint16_t(MONT16_R_MOD_Q));
    case MulKind::K2Red: return mod_mul_ref(w, uint16_t(K2RED_FACTOR_INV));
    default: return w;
  }
}

// a * w mod q where w_rom = twiddle_prescale(k, w).
inline uint16_t mul_twiddle(MulKind k, uint16_t a, uint16_t w_rom) {
  switch (k) {
    case MulKind::Ref: return mod_mul_ref(a, w_rom);
    case MulKind::Barrett: return mod_mul_barrett(a, w_rom);
    case MulKind::ShiftAdd: return mod_mul_shiftadd(a, w_rom);
    case MulKind::Mont12: return mod_mul_mont12(a, w_rom);
    case MulKind::Mont16: return mod_mul_mont16(a, w_rom);
    case MulKind::K2Red: return mod_mul_k2red(a, w_rom);
  }
  return 0;
}

}  // namespace mlkem

#endif  // MLKEM_MODARITH_H
