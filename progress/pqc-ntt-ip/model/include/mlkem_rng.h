// Deterministic, platform-independent PRNG for tests and vector generation.
// splitmix64 + rejection sampling, so vectors depend only on the seed
// (no dependence on std::uniform_int_distribution implementation).
#ifndef MLKEM_RNG_H
#define MLKEM_RNG_H

#include <cstdint>

#include "mlkem_ntt.h"

namespace mlkem {

class Rng {
 public:
  explicit Rng(uint64_t seed) : s_(seed) {}
  uint64_t next() {
    uint64_t z = (s_ += 0x9E3779B97F4A7C15ull);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    return z ^ (z >> 31);
  }
  // Uniform in [0, bound), bound >= 1.
  uint64_t below(uint64_t bound) {
    uint64_t mask = 1;
    while (mask < bound - 1) mask = (mask << 1) | 1;
    if (bound == 1) return 0;
    for (;;) {
      const uint64_t v = next() & mask;
      if (v < bound) return v;
    }
  }
  uint16_t coeff() { return uint16_t(below(Q)); }
  Poly poly() {
    Poly p{};
    for (auto& c : p) c = coeff();
    return p;
  }

 private:
  uint64_t s_;
};

}  // namespace mlkem

#endif  // MLKEM_RNG_H
