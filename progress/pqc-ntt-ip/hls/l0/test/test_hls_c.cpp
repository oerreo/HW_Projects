// C-level exhaustive test of the Catapult HLS sources (hls/l0/src, include).
//
// Compiles the eight top-level functions with their default names (HLS_TOP
// not defined) and compares them, over the whole input domain, with the
// golden model (model/include/mlkem_modarith.h, read only):
//   mod_red_<algo>_hls(x)       vs <algo>_reduce(x)          and (x * S) % q
//   mod_mul_<algo>_hls(a, b)    vs mod_mul_<algo>(a, b)      and (a * b * S) % q
// Domains: x in [0, 2^24) (BARRETT, SHIFTADD, K2RED), [0, q * 2^12) (MONT12);
// a, b in [0, q) x [0, q). S = 1, 2^-12 = 2704, 1, 169.
//
// Prints one line per item with the check and mismatch counts, then
// "OVERALL: PASS" only if every item ran its full count with 0 mismatches.
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include "mlkem_modarith.h"
#include "mlkem_red_hls.h"

using mlkem_hls::coef_t;
using mlkem_hls::prod_t;

void mod_red_barrett_hls(prod_t x, coef_t &r);
void mod_red_mont12_hls(prod_t x, coef_t &r);
void mod_red_shiftadd_hls(prod_t x, coef_t &r);
void mod_red_k2red_hls(prod_t x, coef_t &r);
void mod_mul_barrett_hls(coef_t a, coef_t b, coef_t &p);
void mod_mul_mont12_hls(coef_t a, coef_t b, coef_t &p);
void mod_mul_shiftadd_hls(coef_t a, coef_t b, coef_t &p);
void mod_mul_k2red_hls(coef_t a, coef_t b, coef_t &p);

namespace {

constexpr uint64_t Q = mlkem::Q;

struct Item {
  std::string name;
  uint64_t expected_checks;
  uint64_t checks = 0;
  uint64_t mismatches = 0;
};

struct Algo {
  const char *name;
  uint64_t scale;                       // S mod q
  uint64_t dom_hi;                      // mod_red input domain [0, dom_hi)
  uint16_t (*golden_red)(uint32_t);
  uint16_t (*golden_mul)(uint16_t, uint16_t);
  void (*hls_red)(prod_t, coef_t &);
  void (*hls_mul)(coef_t, coef_t, coef_t &);
};

void report_mismatch(Item &it, const char *what, uint64_t in0, uint64_t in1, unsigned got,
                     unsigned exp) {
  ++it.mismatches;
  if (it.mismatches <= 10)
    std::printf("  MISMATCH %s %s in=(%llu, %llu) got=%u expected=%u\n", it.name.c_str(), what,
                static_cast<unsigned long long>(in0), static_cast<unsigned long long>(in1), got,
                exp);
}

void run_red(const Algo &al, Item &it) {
  for (uint64_t x = 0; x < al.dom_hi; ++x) {
    coef_t r;
    al.hls_red(prod_t(x), r);
    const unsigned got = r.to_uint();
    const unsigned exp = al.golden_red(static_cast<uint32_t>(x));
    const unsigned ref = static_cast<unsigned>((x * al.scale) % Q);
    ++it.checks;
    if (got != exp) report_mismatch(it, "vs golden", x, 0, got, exp);
    else if (got != ref) report_mismatch(it, "vs (x*S)%q", x, 0, got, ref);
  }
}

void run_mul(const Algo &al, Item &it) {
  for (uint64_t a = 0; a < Q; ++a) {
    for (uint64_t b = 0; b < Q; ++b) {
      coef_t p;
      al.hls_mul(coef_t(a), coef_t(b), p);
      const unsigned got = p.to_uint();
      const unsigned exp = al.golden_mul(static_cast<uint16_t>(a), static_cast<uint16_t>(b));
      const unsigned ref = static_cast<unsigned>((a * b % Q) * al.scale % Q);
      ++it.checks;
      if (got != exp) report_mismatch(it, "vs golden", a, b, got, exp);
      else if (got != ref) report_mismatch(it, "vs (a*b*S)%q", a, b, got, ref);
    }
  }
}

}  // namespace

int main() {
  const uint64_t dom24 = uint64_t(1) << 24;
  const uint64_t dom_mont = Q << 12;
  const uint64_t s_mont = mlkem::inv_mod(mlkem::MONT12_R_MOD_Q);  // 2^-12 mod q
  const std::vector<Algo> algos = {
      {"barrett", 1, dom24, mlkem::barrett_reduce, mlkem::mod_mul_barrett, mod_red_barrett_hls,
       mod_mul_barrett_hls},
      {"mont12", s_mont, dom_mont, mlkem::mont12_reduce, mlkem::mod_mul_mont12,
       mod_red_mont12_hls, mod_mul_mont12_hls},
      {"shiftadd", 1, dom24, mlkem::shiftadd_reduce, mlkem::mod_mul_shiftadd,
       mod_red_shiftadd_hls, mod_mul_shiftadd_hls},
      {"k2red", mlkem::K2RED_FACTOR, dom24, mlkem::k2red_reduce, mlkem::mod_mul_k2red,
       mod_red_k2red_hls, mod_mul_k2red_hls},
  };

  std::printf("TEST_CONFIG: test_hls_c exhaustive, q=%llu, S(mont12)=%llu\n",
              static_cast<unsigned long long>(Q), static_cast<unsigned long long>(s_mont));
  std::vector<Item> items;
  for (const Algo &al : algos) {
    Item red{std::string("mod_red_") + al.name, al.dom_hi};
    run_red(al, red);
    items.push_back(red);
    Item mul{std::string("mod_mul_") + al.name, Q * Q};
    run_mul(al, mul);
    items.push_back(mul);
  }

  bool ok = true;
  for (const Item &it : items) {
    const bool pass = it.mismatches == 0 && it.checks == it.expected_checks;
    ok = ok && pass;
    std::printf("ITEM %-18s checks=%llu (expected %llu) mismatches=%llu %s\n", it.name.c_str(),
                static_cast<unsigned long long>(it.checks),
                static_cast<unsigned long long>(it.expected_checks),
                static_cast<unsigned long long>(it.mismatches), pass ? "PASS" : "FAIL");
  }
  std::printf("OVERALL: %s\n", ok ? "PASS" : "FAIL");
  return ok ? 0 : 1;
}
