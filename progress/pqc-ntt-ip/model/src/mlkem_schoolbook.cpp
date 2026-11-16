// Negacyclic schoolbook multiplication in Z_q[X]/(X^256 + 1).
// Deliberately independent of the NTT code and of the reduction models:
// it uses only int64 accumulation and one '%' per output coefficient.
#include "mlkem_ntt.h"

namespace mlkem {

Poly poly_mul_schoolbook(const Poly& f, const Poly& g) {
  std::array<int64_t, N> acc{};
  for (unsigned i = 0; i < N; ++i) {
    for (unsigned j = 0; j < N; ++j) {
      const int64_t p = int64_t(f[i]) * int64_t(g[j]);
      if (i + j < N)
        acc[i + j] += p;
      else
        acc[i + j - N] -= p;  // X^256 = -1
    }
  }
  Poly h{};
  for (unsigned i = 0; i < N; ++i) {
    int64_t v = acc[i] % int64_t(Q);
    if (v < 0) v += Q;
    h[i] = uint16_t(v);
  }
  return h;
}

}  // namespace mlkem
