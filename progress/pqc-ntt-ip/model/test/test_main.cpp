// Self test of the ML-KEM golden model.
// Usage: test_mlkem [--seed S] [--fips-table PATH] [--ext-dir PATH] [--no-xcheck] [--only-hw]
//   --ext-dir  data/vectors/ext of the project (read only), default ../data/vectors/ext
//   --only-hw  run only the hardware-structure items (quick mutation runs)
// Prints per-item check and mismatch counts and an overall PASS / FAIL.
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "mlkem_cases.h"
#include "mlkem_dpi.h"
#include "mlkem_modarith.h"
#include "mlkem_ntt.h"
#include "mlkem_rng.h"
#include "report.h"

using namespace mlkem;

namespace {

constexpr int NUM_RANDOM_ROUNDTRIP = 10000;
constexpr int NUM_RANDOM_POLYMUL = 1000;
constexpr int NUM_RANDOM_KIND_NTT = 1000;
constexpr int NUM_RANDOM_DIRECT = 1000;
constexpr int NUM_RANDOM_BFLY = 1000000;
constexpr int NUM_RANDOM_DPI = 1000;

const MulKind ALL_KINDS[] = {MulKind::Ref,    MulKind::Barrett, MulKind::ShiftAdd,
                             MulKind::Mont12, MulKind::Mont16,  MulKind::K2Red};

uint64_t mulmod64(uint64_t a, uint64_t b) { return (a % Q) * (b % Q) % Q; }

// ---------------------------------------------------------------------------
// 1. Reductions
// ---------------------------------------------------------------------------
void test_add_sub_exhaustive(Report& rep) {
  auto& add = rep.add("modarith", "mod_add_hw, all a,b in [0,q)");
  auto& sub = rep.add("modarith", "mod_sub_hw, all a,b in [0,q)");
  for (uint32_t a = 0; a < Q; ++a)
    for (uint32_t b = 0; b < Q; ++b) {
      const uint16_t ra = mod_add_hw(uint16_t(a), uint16_t(b));
      Report::expect(add, ra == (a + b) % Q, "add", a * 4096 + b, ra, (a + b) % Q);
      const uint16_t rs = mod_sub_hw(uint16_t(a), uint16_t(b));
      Report::expect(sub, rs == (a + Q - b) % Q, "sub", a * 4096 + b, rs, (a + Q - b) % Q);
    }
}

void test_mul_pairs_exhaustive(Report& rep) {
  auto& bar = rep.add("modmul", "barrett(a*b) == a*b mod q, q^2 pairs");
  auto& sha = rep.add("modmul", "shiftadd(a*b) == a*b mod q, q^2 pairs");
  auto& m12 = rep.add("modmul", "mont12(a*b) == a*b*2^-12 mod q, q^2 pairs");
  auto& m16 = rep.add("modmul", "mont16(a*b) == a*b*2^-16 mod q, q^2 pairs");
  auto& k2 = rep.add("modmul", "k2red(a*b) == 169*a*b mod q, q^2 pairs");
  auto& m12s = rep.add("modmul", "mont12(a*pre(b)) == a*b mod q, q^2 pairs");
  auto& m16s = rep.add("modmul", "mont16(a*pre(b)) == a*b mod q, q^2 pairs");
  auto& k2s = rep.add("modmul", "k2red(a*pre(b)) == a*b mod q, q^2 pairs");
  for (uint32_t a = 0; a < Q; ++a) {
    for (uint32_t b = 0; b < Q; ++b) {
      const uint32_t p = a * b;
      const uint16_t exp = uint16_t(p % Q);
      const long long tag = (long long)a * 4096 + b;
      uint16_t r = mod_mul_barrett(uint16_t(a), uint16_t(b));
      Report::expect(bar, r == exp, "barrett", tag, r, exp);
      r = mod_mul_shiftadd(uint16_t(a), uint16_t(b));
      Report::expect(sha, r == exp, "shiftadd", tag, r, exp);
      const uint16_t e12 = uint16_t(mulmod64(p, MONT12_RINV));
      r = mod_mul_mont12(uint16_t(a), uint16_t(b));
      Report::expect(m12, r == e12, "mont12", tag, r, e12);
      const uint16_t e16 = uint16_t(mulmod64(p, MONT16_RINV));
      r = mod_mul_mont16(uint16_t(a), uint16_t(b));
      Report::expect(m16, r == e16, "mont16", tag, r, e16);
      const uint16_t ek = uint16_t(mulmod64(p, K2RED_FACTOR));
      r = mod_mul_k2red(uint16_t(a), uint16_t(b));
      Report::expect(k2, r == ek, "k2red", tag, r, ek);
      // Pre-scaled operand, as used with the twiddle ROM.
      r = mul_twiddle(MulKind::Mont12, uint16_t(a), twiddle_prescale(MulKind::Mont12, uint16_t(b)));
      Report::expect(m12s, r == exp, "mont12 pre", tag, r, exp);
      r = mul_twiddle(MulKind::Mont16, uint16_t(a), twiddle_prescale(MulKind::Mont16, uint16_t(b)));
      Report::expect(m16s, r == exp, "mont16 pre", tag, r, exp);
      r = mul_twiddle(MulKind::K2Red, uint16_t(a), twiddle_prescale(MulKind::K2Red, uint16_t(b)));
      Report::expect(k2s, r == exp, "k2red pre", tag, r, exp);
    }
  }
}

void test_reduce_domains(Report& rep) {
  {
    auto& it = rep.add("domain", "barrett_reduce, all x in [0,2^24)");
    for (uint32_t x = 0; x < (1u << 24); ++x) {
      const uint16_t r = barrett_reduce(x);
      Report::expect(it, r == x % Q, "barrett", x, r, x % Q);
    }
  }
  {
    auto& it = rep.add("domain", "shiftadd_reduce, all x in [0,2^24)");
    for (uint32_t x = 0; x < (1u << 24); ++x) {
      const uint16_t r = shiftadd_reduce(x);
      Report::expect(it, r == x % Q, "shiftadd", x, r, x % Q);
    }
  }
  {
    auto& it = rep.add("domain", "k2red_reduce, all x in [0,2^24)");
    for (uint32_t x = 0; x < (1u << 24); ++x) {
      const uint16_t r = k2red_reduce(x);
      const uint16_t e = uint16_t(mulmod64(x, K2RED_FACTOR));
      Report::expect(it, r == e, "k2red", x, r, e);
    }
  }
  {
    auto& it = rep.add("domain", "mont12_reduce, all x in [0,q*2^12)");
    for (uint32_t x = 0; x < Q * (1u << 12); ++x) {
      const uint16_t r = mont12_reduce(x);
      const uint16_t e = uint16_t(mulmod64(x, MONT12_RINV));
      Report::expect(it, r == e, "mont12", x, r, e);
    }
  }
  {
    auto& it = rep.add("domain", "mont16_reduce, all x in [0,q*2^16)");
    for (uint32_t x = 0; x < Q * (1u << 16); ++x) {
      const uint16_t r = mont16_reduce(x);
      const uint16_t e = uint16_t(mulmod64(x, MONT16_RINV));
      Report::expect(it, r == e, "mont16", x, r, e);
    }
  }
}

// ---------------------------------------------------------------------------
// 2. Tables
// ---------------------------------------------------------------------------
bool load_fips_table(const std::string& path, std::vector<long>& zeta, std::vector<long>& gamma) {
  std::ifstream in(path);
  if (!in) return false;
  std::string line;
  while (std::getline(in, line)) {
    if (line.empty() || line[0] == '#') continue;
    std::istringstream ss(line);
    std::string key;
    ss >> key;
    std::vector<long>* dst = key == "zeta" ? &zeta : key == "gamma" ? &gamma : nullptr;
    if (!dst) continue;
    long v;
    while (ss >> v) dst->push_back(v);
  }
  return zeta.size() == 128 && gamma.size() == 128;
}

void test_tables(Report& rep, const std::string& fips_path) {
  auto& prop = rep.add("tables", "zeta/gamma algebraic properties");
  Report::expect(prop, pow_mod(ZETA, 128) == Q - 1, "17^128 == -1");
  Report::expect(prop, pow_mod(ZETA, 256) == 1, "17^256 == 1");
  Report::expect(prop, (128u * N128_INV) % Q == 1, "128*3303 == 1");
  for (int i = 0; i < 128; ++i) {
    Report::expect(prop, zeta_table()[i] == pow_mod(ZETA, bitrev7(i)), "zeta pow", i,
                   zeta_table()[i], pow_mod(ZETA, bitrev7(i)));
    Report::expect(prop, gamma_table()[i] == pow_mod(ZETA, 2 * bitrev7(i) + 1), "gamma pow", i,
                   gamma_table()[i], pow_mod(ZETA, 2 * bitrev7(i) + 1));
    for (int kk = 0; kk < NUM_MUL_KINDS; ++kk) {
      const uint16_t w = twiddle_rom(MulKind(kk))[i];
      const uint16_t back = mul_twiddle(MulKind(kk), 1, w);
      Report::expect(prop, back == zeta_table()[i], "rom 1*w", i, back, zeta_table()[i]);
    }
  }

  std::vector<long> fz, fg;
  if (!load_fips_table(fips_path, fz, fg)) {
    rep.not_run("tables", "zeta/gamma vs FIPS 203 Appendix A", "table file not readable");
    return;
  }
  auto& z = rep.add("tables", "zeta_table vs FIPS 203 Appendix A");
  auto& g = rep.add("tables", "gamma_table vs FIPS 203 Appendix A");
  for (int i = 0; i < 128; ++i) {
    Report::expect(z, zeta_table()[i] == fz[i], "zeta", i, zeta_table()[i], fz[i]);
    const long gm = ((fg[i] % long(Q)) + long(Q)) % long(Q);
    Report::expect(g, gamma_table()[i] == gm, "gamma", i, gamma_table()[i], gm);
  }
}

// ---------------------------------------------------------------------------
// 3. Butterflies
// ---------------------------------------------------------------------------
void test_butterflies(Report& rep, uint64_t seed) {
  Rng rng(seed ^ 0xB0F1ull);
  auto& ct = rep.add("bfly", "ct_butterfly all MulKind vs formula");
  auto& gs = rep.add("bfly", "gs_butterfly all MulKind vs formula");
  for (int n = 0; n < NUM_RANDOM_BFLY; ++n) {
    // Mix boundary operands into the random stream.
    uint16_t a = rng.coeff(), b = rng.coeff();
    if (n % 16 == 0) a = uint16_t(Q - 1);
    if (n % 16 == 1) b = uint16_t(Q - 1);
    if (n % 16 == 2) a = 0;
    if (n % 16 == 3) b = 0;
    const int zi = n % 128;
    const uint32_t z = zeta_table()[zi];
    const uint32_t t = b * z % Q;
    const uint16_t ct_a = uint16_t((a + t) % Q), ct_b = uint16_t((a + Q - t) % Q);
    const uint16_t gs_a = uint16_t((a + b) % Q), gs_b = uint16_t((b + Q - a) % Q * z % Q);
    for (MulKind k : ALL_KINDS) {
      const BflyOut o1 = ct_butterfly(k, a, b, twiddle_rom(k)[zi]);
      Report::expect(ct, o1.a == ct_a && o1.b == ct_b, "ct", n, o1.a * 4096 + o1.b,
                     ct_a * 4096 + ct_b);
      const BflyOut o2 = gs_butterfly(k, a, b, twiddle_rom(k)[zi]);
      Report::expect(gs, o2.a == gs_a && o2.b == gs_b, "gs", n, o2.a * 4096 + o2.b,
                     gs_a * 4096 + gs_b);
    }
  }
}

// ---------------------------------------------------------------------------
// 4. Polynomial level
// ---------------------------------------------------------------------------
std::vector<Poly> poly_set(Rng& rng, int n_random) {
  std::vector<Poly> v;
  for (auto& bc : boundary_polys()) v.push_back(bc.second);
  for (int i = 0; i < n_random; ++i) v.push_back(rng.poly());
  return v;
}

void test_roundtrip(Report& rep, uint64_t seed) {
  Rng rng(seed ^ 0x7123ull);
  auto& it = rep.add("poly", "intt(ntt(f)) == f, 10000 random + 6 boundary");
  auto& it2 = rep.add("poly", "ntt(intt(F)) == F, 10000 random + 6 boundary");
  for (const Poly& f : poly_set(rng, NUM_RANDOM_ROUNDTRIP)) {
    Report::expect(it, intt(ntt(f)) == f, "roundtrip");
    Report::expect(it2, ntt(intt(f)) == f, "roundtrip2");
  }
}

// Definition (4.12)/(4.13): NTT(f)[2i] + NTT(f)[2i+1] X = f mod (X^2 - gamma_i),
// evaluated directly with X^2 = gamma_i.
void test_ntt_definition(Report& rep, uint64_t seed) {
  Rng rng(seed ^ 0xDEF1ull);
  auto& it = rep.add("poly", "ntt(f) == f mod (X^2-gamma_i), direct eval");
  for (const Poly& f : poly_set(rng, NUM_RANDOM_DIRECT)) {
    const Poly fh = ntt(f);
    bool ok = true;
    for (int i = 0; i < 128; ++i) {
      const uint64_t g = gamma_table()[i];
      uint64_t e0 = 0, e1 = 0, gp = 1;
      for (int j = 0; j < 128; ++j) {
        e0 = (e0 + f[2 * j] * gp) % Q;
        e1 = (e1 + f[2 * j + 1] * gp) % Q;
        gp = gp * g % Q;
      }
      ok = ok && fh[2 * i] == e0 && fh[2 * i + 1] == e1;
    }
    Report::expect(it, ok, "direct");
  }
}

void test_polymul(Report& rep, uint64_t seed) {
  Rng rng(seed ^ 0x5C00ull);
  auto& it = rep.add("poly", "intt(mul(ntt f, ntt g)) == schoolbook, 1000+36");
  const auto bc = boundary_polys();
  std::vector<std::pair<Poly, Poly>> cases;
  for (auto& x : bc)
    for (auto& y : bc) cases.emplace_back(x.second, y.second);
  for (int i = 0; i < NUM_RANDOM_POLYMUL; ++i) cases.emplace_back(rng.poly(), rng.poly());
  // Sanity of the schoolbook itself: X^255 * X = -1.
  {
    Poly a{}, b{}, e{};
    a[255] = 1;
    b[1] = 1;
    e[0] = uint16_t(Q - 1);
    Report::expect(it, poly_mul_schoolbook(a, b) == e, "schoolbook X^256 = -1");
  }
  for (auto& c : cases) {
    const Poly h = intt(multiply_ntts(ntt(c.first), ntt(c.second)));
    Report::expect(it, h == poly_mul_schoolbook(c.first, c.second), "polymul");
  }
}

void test_kinds_poly(Report& rep, uint64_t seed) {
  Rng rng(seed ^ 0x4B1Dull);
  const std::vector<Poly> set = poly_set(rng, NUM_RANDOM_KIND_NTT);
  for (MulKind k : ALL_KINDS) {
    if (k == MulKind::Ref) continue;
    auto& it = rep.add("kinds", std::string("ntt/intt with ") + mul_kind_name(k) + " == ref");
    for (const Poly& f : set) {
      Report::expect(it, ntt(f, k) == ntt(f), "ntt kind");
      Report::expect(it, intt(f, k) == intt(f), "intt kind");
    }
  }
  for (MulKind k : {MulKind::Barrett, MulKind::ShiftAdd}) {
    auto& it = rep.add("kinds", std::string("multiply_ntts with ") + mul_kind_name(k) + " == ref");
    for (size_t i = 0; i + 1 < set.size(); ++i)
      Report::expect(it, multiply_ntts(set[i], set[i + 1], k) == multiply_ntts(set[i], set[i + 1]),
                     "mul kind");
  }
}

void test_trace(Report& rep, uint64_t seed) {
  Rng rng(seed ^ 0x77ull);
  auto& it = rep.add("trace", "butterfly trace / layer dump consistency");
  for (int n = 0; n < 20; ++n) {
    const Poly f = rng.poly();
    for (int dir = 0; dir < 2; ++dir) {
      std::vector<ButterflyRecord> tr;
      std::vector<Poly> layers;
      NttObserver obs{&tr, &layers};
      const Poly out = dir == 0 ? ntt(f, MulKind::Mont12, &obs) : intt(f, MulKind::Mont12, &obs);
      Report::expect(it, tr.size() == 7 * 128, "trace size");
      Report::expect(it, layers.size() == (dir == 0 ? 7u : 8u), "layer count");
      Report::expect(it, layers.back() == out, "last layer == output");
      // Replaying the trace records on f reproduces each layer state.
      Poly r = f;
      size_t rec = 0;
      for (int L = 0; L < 7; ++L) {
        for (int b = 0; b < 128; ++b, ++rec) {
          const ButterflyRecord& x = tr[rec];
          const bool in_ok = x.layer == L && r[x.j0] == x.a_in && r[x.j0 + x.len] == x.b_in;
          const BflyOut o = dir == 0 ? ct_butterfly(MulKind::Ref, x.a_in, x.b_in, x.zeta)
                                     : gs_butterfly(MulKind::Ref, x.a_in, x.b_in, x.zeta);
          Report::expect(it, in_ok && o.a == x.a_out && o.b == x.b_out, "record");
          r[x.j0] = x.a_out;
          r[x.j0 + x.len] = x.b_out;
        }
        Report::expect(it, r == layers[L], "layer state");
      }
    }
  }
}

void test_dpi(Report& rep, uint64_t seed) {
  Rng rng(seed ^ 0xD9Cull);
  auto& it = rep.add("dpi", "C linkage wrapper == C++ API");
  for (int n = 0; n < NUM_RANDOM_DPI; ++n) {
    const Poly f = rng.poly(), g = rng.poly();
    int fi[256], gi[256], o[256];
    for (int i = 0; i < 256; ++i) {
      fi[i] = f[i];
      gi[i] = g[i];
    }
    mlkem_dpi_ntt(fi, o);
    Poly e = ntt(f);
    bool ok = true;
    for (int i = 0; i < 256; ++i) ok = ok && o[i] == e[i];
    mlkem_dpi_intt(fi, o);
    e = intt(f);
    for (int i = 0; i < 256; ++i) ok = ok && o[i] == e[i];
    mlkem_dpi_multiply_ntts(fi, gi, o);
    e = multiply_ntts(f, g);
    for (int i = 0; i < 256; ++i) ok = ok && o[i] == e[i];
    Report::expect(it, ok, "dpi poly");

    const int a = f[0], b = f[1], zi = n % 128;
    ok = mlkem_dpi_mod_add(a, b) == (a + b) % int(Q) &&
         mlkem_dpi_mod_sub(a, b) == (a - b + int(Q)) % int(Q) &&
         mlkem_dpi_mod_mul(a, b) == a * b % int(Q) && mlkem_dpi_zeta(zi) == zeta_table()[zi] &&
         mlkem_dpi_gamma(zi) == gamma_table()[zi];
    for (int k = 0; k < NUM_MUL_KINDS; ++k) {
      const int x = a * b;
      int exp = x % int(Q);
      if (k == 3) exp = int(mulmod64(x, MONT12_RINV));
      if (k == 4) exp = int(mulmod64(x, MONT16_RINV));
      if (k == 5) exp = int(mulmod64(x, K2RED_FACTOR));
      ok = ok && mlkem_dpi_reduce(k, x) == exp;
      int oa, ob;
      const int w = mlkem_dpi_twiddle_prescale(k, zeta_table()[zi]);
      mlkem_dpi_ct_butterfly(k, a, b, w, &oa, &ob);
      const BflyOut c = ct_butterfly(MulKind::Ref, uint16_t(a), uint16_t(b), zeta_table()[zi]);
      ok = ok && oa == c.a && ob == c.b;
      mlkem_dpi_gs_butterfly(k, a, b, w, &oa, &ob);
      const BflyOut d = gs_butterfly(MulKind::Ref, uint16_t(a), uint16_t(b), zeta_table()[zi]);
      ok = ok && oa == d.a && ob == d.b;
    }
    int c0, c1;
    mlkem_dpi_basecase_multiply(f[0], f[1], g[0], g[1], gamma_table()[zi], &c0, &c1);
    const BflyOut bm = basecase_multiply(f[0], f[1], g[0], g[1], gamma_table()[zi]);
    ok = ok && c0 == bm.a && c1 == bm.b;
    // Out-of-domain inputs are rejected.
    ok = ok && mlkem_dpi_reduce(1, 1 << 24) == -1 && mlkem_dpi_reduce(3, int(Q) << 12) == -1 &&
         mlkem_dpi_reduce(9, 0) == -1;
    Report::expect(it, ok, "dpi scalar");
  }
}

}  // namespace

int main(int argc, char** argv) {
  uint64_t seed = 1;
  std::string fips_path = "third_party/fips203/appendix_a.txt";
  std::string ext_dir = "../data/vectors/ext";
  bool xcheck = true;
  bool only_hw = false;
  for (int i = 1; i < argc; ++i) {
    if (!std::strcmp(argv[i], "--seed") && i + 1 < argc)
      seed = std::strtoull(argv[++i], nullptr, 0);
    else if (!std::strcmp(argv[i], "--fips-table") && i + 1 < argc)
      fips_path = argv[++i];
    else if (!std::strcmp(argv[i], "--ext-dir") && i + 1 < argc)
      ext_dir = argv[++i];
    else if (!std::strcmp(argv[i], "--no-xcheck"))
      xcheck = false;
    else if (!std::strcmp(argv[i], "--only-hw"))
      only_hw = true;
    else {
      std::fprintf(stderr,
                   "usage: %s [--seed S] [--fips-table PATH] [--ext-dir PATH] [--no-xcheck] "
                   "[--only-hw]\n",
                   argv[0]);
      return 2;
    }
  }
  std::printf("ML-KEM golden model self test, seed=%" PRIu64 "\n", seed);
#ifdef MLKEM_CHECK_WIDTHS
  std::printf("intermediate width assertions: enabled\n");
#else
  std::printf("intermediate width assertions: disabled\n");
#endif

  Report rep;
  if (only_hw) {
    run_hw_tests(rep, seed, ext_dir);
#ifdef MLKEM_CHECK_WIDTHS
    auto& w = rep.add("widths", "declared intermediate widths never exceeded");
    w.checks = g_width_checks;
    w.mismatches = g_width_violations;
#endif
    return rep.print_summary() ? 0 : 1;
  }
  std::printf("[1/9] mod add/sub exhaustive\n");
  test_add_sub_exhaustive(rep);
  std::printf("[2/9] mod mul q^2 pairs exhaustive\n");
  test_mul_pairs_exhaustive(rep);
  std::printf("[3/9] reduction input domains exhaustive\n");
  test_reduce_domains(rep);
  std::printf("[4/9] tables\n");
  test_tables(rep, fips_path);
  std::printf("[5/9] butterflies\n");
  test_butterflies(rep, seed);
  std::printf("[6/9] ntt/intt roundtrip and definition\n");
  test_roundtrip(rep, seed);
  test_ntt_definition(rep, seed);
  std::printf("[7/9] polynomial multiplication vs schoolbook\n");
  test_polymul(rep, seed);
  std::printf("[8/9] MulKind variants, trace, dpi wrapper\n");
  test_kinds_poly(rep, seed);
  test_trace(rep, seed);
  test_dpi(rep, seed);
  std::printf("[9/9] external cross check (pq-crystals/kyber ref)\n");
  if (xcheck)
    run_pqcrystals_xcheck(rep, seed);
  else
    rep.not_run("xcheck", "pq-crystals/kyber ref", "--no-xcheck");
  std::printf("[10] hardware-structure model (bfu, ROMs, hw schedule, basemul program)\n");
  run_hw_tests(rep, seed, ext_dir);

#ifdef MLKEM_CHECK_WIDTHS
  {
    auto& w = rep.add("widths", "declared intermediate widths never exceeded");
    w.checks = g_width_checks;
    w.mismatches = g_width_violations;
  }
#endif
  return rep.print_summary() ? 0 : 1;
}
