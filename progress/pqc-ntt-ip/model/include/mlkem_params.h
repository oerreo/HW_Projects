// ML-KEM (FIPS 203) polynomial ring parameters.
#ifndef MLKEM_PARAMS_H
#define MLKEM_PARAMS_H

#include <cstdint>

namespace mlkem {

constexpr uint32_t Q = 3329;          // modulus, 12 bits
constexpr unsigned N = 256;           // polynomial degree bound
constexpr uint32_t ZETA = 17;         // primitive 256-th root of unity mod q
constexpr uint32_t N128_INV = 3303;   // 128^-1 mod q (Algorithm 10, line 14)
constexpr unsigned COEFF_BITS = 12;
constexpr unsigned NTT_LAYERS = 7;

static_assert((128u * N128_INV) % Q == 1, "128^-1 mod q");

}  // namespace mlkem

#endif  // MLKEM_PARAMS_H
