// Catapult HLS source for the L0 modular reduction and multiplication blocks
// of the ML-KEM (FIPS 203) NTT datapath, q = 3329.
//
// Every function here is a 1:1 transcription of the golden model function of
// the same name without the _hls suffix (model/include/mlkem_modarith.h):
// same algorithm, same intermediate steps, and every intermediate is held in
// an ac_int of the width declared in the golden model comment ("[msb:0]" is
// ac_int<msb+1, false>, "s<N>" is ac_int<N, true>). Where the golden model
// writes a truncation as a mask, the code here assigns to the narrower ac_int
// (ac_int assignment truncates modulo 2^W, which is the same operation).
// Intermediates the golden model keeps in a wider C integer without a declared
// width are given the smallest width that holds their full value, noted at
// the line.
//
// Input domains and outputs (same as the golden model and the hand RTL):
//   barrett_reduce_hls   x in [0, 2^24)      x mod q
//   mont12_reduce_hls    x in [0, q*2^12)    x * 2^-12 mod q
//   shiftadd_reduce_hls  x in [0, 2^24)      x mod q
//   k2red_reduce_hls     x in [0, 2^24)      169 * x mod q
//   mod_mul_<algo>_hls   a, b in [0, q)      reduce_<algo>(a * b)
// The scale factor S (2^-12, 169) is not removed, as in the hand RTL.
//
// No pragmas and no interface or timing constraints are in this file. The
// top-level functions are in hls/l0/src/<block>.cpp; clock, latency and
// library are set in hls/l0/tcl/.
#ifndef MLKEM_RED_HLS_H
#define MLKEM_RED_HLS_H

#include <ac_int.h>

namespace mlkem_hls {

typedef ac_int<12, false> coef_t;  // canonical coefficient, [0, q)
typedef ac_int<24, false> prod_t;  // product of two coefficients

// ---------------------------------------------------------------------------
// Barrett reduction, k = 24, m = floor(2^24 / q) = 5039 (golden barrett_reduce)
// ---------------------------------------------------------------------------
inline coef_t barrett_reduce_hls(prod_t x) {
  const ac_int<13, false> m = 5039;
  const ac_int<12, false> q = 3329;
  const ac_int<37, false> xm = x * m;                    // [36:0] 24b x 13b const
  const ac_int<13, false> qhat = xm.slc<13>(24);         // [12:0] xm >> 24, max 5038
  const ac_int<14, false> qq_lo = qhat * q;              // [13:0] (qhat * q) mod 2^14
  const ac_int<14, false> r = x - qq_lo;                 // [13:0] (x - qq_lo) mod 2^14, [0, 2q)
  const ac_int<14, true> d = r - q;                      // s14
  coef_t res;
  if (d < 0) {
    res = r.slc<12>(0);
  } else {
    res = d.slc<12>(0);
  }
  return res;
}

// ---------------------------------------------------------------------------
// Montgomery reduction, R = 2^12 (golden mont12_reduce)
// q' = -q^-1 mod 2^12 = 3327; q^-1 mod 2^12 = 769 = 2^9 + 2^8 + 1.
// ---------------------------------------------------------------------------
inline coef_t mont12_reduce_hls(prod_t x) {
  const ac_int<12, false> q = 3329;
  const ac_int<12, false> xl = x.slc<12>(0);             // [11:0]
  // Golden: xl * 769 as a 3-input shift-add in a uint32 (no declared width).
  // Held here in 22 bits, the width of its maximum 4095 * 769 = 3149055.
  const ac_int<22, false> xlw = xl;
  const ac_int<22, false> xl_qinv = xlw + (xlw << 8) + (xlw << 9);
  const ac_int<12, false> t = -xl_qinv;                  // [11:0] (0 - xl_qinv) mod 2^12
  const ac_int<24, false> tq = t * q;                    // [23:0] 12b x 12b const
  const ac_int<25, false> s = x + tq;                    // [24:0], low 12 bits are 0
  const ac_int<13, false> u = s.slc<13>(12);             // [12:0] s >> 12, [0, 2q)
  const ac_int<14, true> d = u - q;                      // s14
  coef_t res;
  if (d < 0) {
    res = u.slc<12>(0);
  } else {
    res = d.slc<12>(0);
  }
  return res;
}

// ---------------------------------------------------------------------------
// q-specific shift-add folding, 2^12 = 2^9 + 2^8 - 1 (mod q)
// (golden shiftadd_fold / shiftadd_reduce)
// ---------------------------------------------------------------------------
// One fold maps y = h * 2^12 + l to (h << 9) + (h << 8) - h + l. The golden
// model computes it in a uint32 and asserts that the result fits OW bits; it
// is computed here modulo 2^OW, which is exact for the same reason.
template <int IW, int OW>
inline ac_int<OW, false> shiftadd_fold_hls(ac_int<IW, false> y) {
  const ac_int<IW - 12, false> h = y.template slc<IW - 12>(12);
  const ac_int<12, false> l = y.template slc<12>(0);
  const ac_int<OW, false> hw = h;                        // widen before the shifts
  const ac_int<OW, false> res = (hw << 9) + (hw << 8) - hw + l;
  return res;
}

inline coef_t shiftadd_reduce_hls(prod_t x) {
  const ac_int<15, false> q = 3329;
  const ac_int<15, false> q2 = 2 * 3329;
  const ac_int<22, false> y1 = shiftadd_fold_hls<24, 22>(x);   // [21:0], h is 12b
  const ac_int<20, false> y2 = shiftadd_fold_hls<22, 20>(y1);  // [19:0], h is 10b
  const ac_int<17, false> y3 = shiftadd_fold_hls<20, 17>(y2);  // [16:0], h is 8b
  const ac_int<15, false> y4 = shiftadd_fold_hls<17, 15>(y3);  // [14:0], h is 5b
  const ac_int<14, false> y5 = shiftadd_fold_hls<15, 14>(y4);  // [13:0], h is 3b, < 3q
  const ac_int<15, true> d1 = y5 - q;                          // s15
  const ac_int<15, true> d2 = y5 - q2;                         // s15
  coef_t res;
  if (d2 >= 0) {
    res = d2.slc<12>(0);
  } else if (d1 >= 0) {
    res = d1.slc<12>(0);
  } else {
    res = y5.slc<12>(0);
  }
  return res;
}

// ---------------------------------------------------------------------------
// K2-RED, q = k * 2^m + 1 with k = 13, m = 8 (golden k2red_reduce)
// k * c is (c << 3) + (c << 2) + c.
// ---------------------------------------------------------------------------
inline coef_t k2red_reduce_hls(prod_t x) {
  const ac_int<12, false> q = 3329;
  const ac_int<8, false> c0 = x.slc<8>(0);               // [7:0]
  const ac_int<16, false> c1 = x.slc<16>(8);             // [15:0]
  // Golden: 13 * c0 in a uint32. Held in 12 bits (max 13 * 255 = 3315).
  const ac_int<12, false> c0w = c0;
  const ac_int<17, true> r1 = (c0w << 3) + (c0w << 2) + c0w - c1;  // s17, [-65535, 3315]
  const ac_int<8, false> r1_0 = r1.slc<8>(0);            // [7:0]
  const ac_int<9, true> r1_1 = r1.slc<9>(8);             // s9, r1 >> 8 (arithmetic), [-256, 12]
  // Golden: 13 * r1_0 in a uint32. Held in 12 bits (max 3315).
  const ac_int<12, false> r10w = r1_0;
  const ac_int<13, true> r2 = (r10w << 3) + (r10w << 2) + r10w - r1_1;  // s13, [-12, 3571]
  coef_t res;
  if (r2 < 0) {
    const ac_int<13, true> p = r2 + q;                   // [0, q) when r2 < 0
    res = p.slc<12>(0);
  } else {
    const ac_int<13, true> d = r2 - q;                   // s13
    if (d < 0) {
      res = r2.slc<12>(0);
    } else {
      res = d.slc<12>(0);
    }
  }
  return res;
}

// ---------------------------------------------------------------------------
// Modular multiplication: one 12b x 12b multiplier + reduction
// (golden mul12x12 / mod_mul_<algo>)
// ---------------------------------------------------------------------------
inline prod_t mul12x12_hls(coef_t a, coef_t b) {
  const prod_t p = a * b;                                // [23:0]
  return p;
}

inline coef_t mod_mul_barrett_hls(coef_t a, coef_t b) {
  return barrett_reduce_hls(mul12x12_hls(a, b));
}
inline coef_t mod_mul_mont12_hls(coef_t a, coef_t b) {
  return mont12_reduce_hls(mul12x12_hls(a, b));
}
inline coef_t mod_mul_shiftadd_hls(coef_t a, coef_t b) {
  return shiftadd_reduce_hls(mul12x12_hls(a, b));
}
inline coef_t mod_mul_k2red_hls(coef_t a, coef_t b) {
  return k2red_reduce_hls(mul12x12_hls(a, b));
}

}  // namespace mlkem_hls

#endif  // MLKEM_RED_HLS_H
