// Named boundary-case polynomials shared by tests and the vector generator.
#ifndef MLKEM_CASES_H
#define MLKEM_CASES_H

#include <string>
#include <utility>
#include <vector>

#include "mlkem_ntt.h"

namespace mlkem {

inline std::vector<std::pair<std::string, Poly>> boundary_polys() {
  std::vector<std::pair<std::string, Poly>> v;
  Poly p{};
  v.emplace_back("all_zero", p);
  p.fill(uint16_t(Q - 1));
  v.emplace_back("all_qm1", p);
  p.fill(0);
  p[0] = 1;
  v.emplace_back("impulse_1_at_0", p);
  p.fill(0);
  p[255] = 1;
  v.emplace_back("impulse_1_at_255", p);
  p.fill(0);
  p[128] = uint16_t(Q - 1);
  v.emplace_back("impulse_qm1_at_128", p);
  p.fill(1);
  v.emplace_back("all_one", p);
  return v;
}

}  // namespace mlkem

#endif  // MLKEM_CASES_H
