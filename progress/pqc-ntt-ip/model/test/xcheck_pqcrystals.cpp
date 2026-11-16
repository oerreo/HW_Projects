// Cross check against the pq-crystals/kyber reference implementation
// (third_party/pq-crystals-kyber, CC0, built with -DKYBER_K=3).
//
// Representation conversion:
//   * ref zetas[i] = zeta_i * 2^16 mod q, signed centered  so zeta_i = zetas[i] * 2^-16
//   * ref ntt(f)     = NTT(f) mod q, signed, not reduced    so compare mod q
//   * ref invntt(F)  = 2^16 * NTT^-1(F) mod q ("tomont")    so multiply by 2^-16
//   * ref basemul    = 2^-16 * BaseCaseMultiply              so multiply by 2^16
// The upstream headers are not included because they #define ntt, zetas, etc.
// as macros; the namespaced symbols are declared directly instead.
#include <cstdint>

#include "mlkem_cases.h"
#include "mlkem_ntt.h"
#include "mlkem_rng.h"
#include "report.h"

extern "C" {
extern const int16_t pqcrystals_kyber768_ref_zetas[128];
void pqcrystals_kyber768_ref_ntt(int16_t r[256]);
void pqcrystals_kyber768_ref_invntt(int16_t r[256]);
void pqcrystals_kyber768_ref_basemul(int16_t r[2], const int16_t a[2], const int16_t b[2],
                                     int16_t zeta);
}

using namespace mlkem;

namespace {

constexpr int NUM_RANDOM_XCHECK = 1000;

uint16_t canon(int64_t v) {
  int64_t r = v % int64_t(Q);
  if (r < 0) r += Q;
  return uint16_t(r);
}

uint16_t scale(int64_t v, uint32_t c) { return uint16_t(uint64_t(canon(v)) * c % Q); }

}  // namespace

void run_pqcrystals_xcheck(Report& rep, uint64_t seed) {
  Rng rng(seed ^ 0xC0FFEEull);

  auto& z = rep.add("xcheck", "zeta_table vs pq-crystals zetas*2^-16");
  for (int i = 0; i < 128; ++i) {
    const uint16_t e = scale(pqcrystals_kyber768_ref_zetas[i], MONT16_RINV);
    Report::expect(z, zeta_table()[i] == e, "zeta", i, zeta_table()[i], e);
  }

  std::vector<Poly> set;
  for (auto& bc : boundary_polys()) set.push_back(bc.second);
  for (int i = 0; i < NUM_RANDOM_XCHECK; ++i) set.push_back(rng.poly());

  auto& fw = rep.add("xcheck", "ntt vs pq-crystals ntt, 1000+6 polys");
  auto& iv = rep.add("xcheck", "intt vs pq-crystals invntt*2^-16, 1000+6");
  auto& bm = rep.add("xcheck", "multiply_ntts vs pq-crystals basemul*2^16");
  for (size_t n = 0; n < set.size(); ++n) {
    const Poly& f = set[n];
    int16_t r[256];

    for (int i = 0; i < 256; ++i) r[i] = int16_t(f[i]);
    pqcrystals_kyber768_ref_ntt(r);
    const Poly fh = ntt(f);
    bool ok = true;
    for (int i = 0; i < 256; ++i) ok = ok && canon(r[i]) == fh[i];
    Report::expect(fw, ok, "ntt", long(n));

    for (int i = 0; i < 256; ++i) r[i] = int16_t(f[i]);
    pqcrystals_kyber768_ref_invntt(r);
    const Poly fi = intt(f);
    ok = true;
    for (int i = 0; i < 256; ++i) ok = ok && scale(r[i], MONT16_RINV) == fi[i];
    Report::expect(iv, ok, "intt", long(n));

    // poly_basemul_montgomery from upstream poly.c, re-expressed here.
    const Poly& g = set[(n + 1) % set.size()];
    const Poly h = multiply_ntts(f, g);
    ok = true;
    for (int i = 0; i < 64; ++i) {
      const int16_t zt = pqcrystals_kyber768_ref_zetas[64 + i];
      for (int half = 0; half < 2; ++half) {
        const int base = 4 * i + 2 * half;
        const int16_t a[2] = {int16_t(f[base]), int16_t(f[base + 1])};
        const int16_t b[2] = {int16_t(g[base]), int16_t(g[base + 1])};
        int16_t c[2];
        pqcrystals_kyber768_ref_basemul(c, a, b, half == 0 ? zt : int16_t(-zt));
        ok = ok && scale(c[0], MONT16_R_MOD_Q) == h[base] &&
             scale(c[1], MONT16_R_MOD_Q) == h[base + 1];
      }
    }
    Report::expect(bm, ok, "basemul", long(n));
  }
}
