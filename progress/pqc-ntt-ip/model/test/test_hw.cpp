// Self test of the hardware-structure model (include/mlkem_hw.h).
//
// Oracles: plain modular arithmetic for mod_half / bfu / ROMs, and the
// canonical FIPS 203 functions ntt / intt / multiply_ntts (MulKind::Ref) for
// the transforms. External vectors (data/vectors/ext) are compared against
// their own expected outputs, independent of the model.
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

#include "mlkem_cases.h"
#include "mlkem_dpi.h"
#include "mlkem_hw.h"
#include "mlkem_ntt.h"
#include "mlkem_rng.h"
#include "report.h"

using namespace mlkem;
using namespace mlkem::hw;

namespace {

constexpr int NUM_BFU_RANDOM = 1000000;  // per (algo, mode) and per z class
constexpr int NUM_HW_POLY = 2000;        // random polynomials / pairs per algo
constexpr int NUM_HW_TRACE = 20;
constexpr int NUM_HW_DPI = 300;

const uint16_t EDGE[] = {0, 1, uint16_t(Q - 1), uint16_t((Q - 1) / 2), uint16_t((Q + 1) / 2)};

std::string tag(Algo a, const char* s) { return std::string(s) + " " + algo_name(a); }

uint32_t mm(uint32_t a, uint32_t b) { return uint32_t(uint64_t(a % Q) * (b % Q) % Q); }

// Oracle of the bfu: plain '%' and the multiplicative scale S.
BfuOut bfu_oracle(Algo algo, Mode mode, uint32_t a, uint32_t b, uint32_t z) {
  const uint32_t s = algo_scale(algo);
  if (mode == Mode::CT) {
    const uint32_t t = mm(mm(b, z), s);
    return {uint16_t((a + t) % Q), uint16_t((a + Q - t) % Q)};
  }
  const uint32_t x = mm(a + b, Q_INV2);
  const uint32_t y = mm(mm(mm(b + Q - a, z), s), Q_INV2);
  return {uint16_t(x), uint16_t(y)};
}

// ---------------------------------------------------------------------------
void test_mod_half(Report& rep) {
  auto& it = rep.add("hw", "mod_half, all x in [0,q)");
  for (uint32_t x = 0; x < Q; ++x) {
    const uint16_t h = mod_half(uint16_t(x));
    const uint32_t e = x * Q_INV2 % Q;
    Report::expect(it, h == e && h < Q && (2u * h) % Q == x, "half", x, h, e);
  }
}

void test_roms(Report& rep) {
  auto& it = rep.add("hw", "ROM zeta*S^-1, gamma*S^-2, K2, x 4 algo");
  // Constants derived independently of algo_scale().
  Report::expect(it, algo_scale_inv(Algo::Barrett) == 1 && algo_scale_inv(Algo::ShiftAdd) == 1,
                 "S^-1 unit");
  Report::expect(it, algo_scale_inv(Algo::Mont12) == 4096 % Q, "mont12 S^-1 = 2^12", 0,
                 algo_scale_inv(Algo::Mont12), 4096 % Q);
  Report::expect(it, algo_scale_inv(Algo::K2Red) == (1u << 16) % Q, "k2red S^-1 = 2^16", 0,
                 algo_scale_inv(Algo::K2Red), (1u << 16) % Q);
  for (Algo a : ALL_ALGOS) {
    const uint32_t s = algo_scale(a);
    Report::expect(it, mm(s, algo_scale_inv(a)) == 1, "S*S^-1");
    Report::expect(it, mm(mm(k2_const(a), s), s) == 1, "K2*S^2", int(a), k2_const(a), 0);
    Report::expect(it, rom_read(a, RomKind::K2, 0) == k2_const(a), "rom_read k2");
    Report::expect(it, rom_read(a, RomKind::K2, 1) == -1 && rom_read(a, RomKind::Zeta, 128) == -1,
                   "rom_read range");
    for (int i = 0; i < 128; ++i) {
      const uint32_t z = zeta_table()[i], g = gamma_table()[i];
      Report::expect(it, mm(zeta_rom(a)[i], s) == z, "zeta*S", i, zeta_rom(a)[i], z);
      Report::expect(it, bfu_mul(a, 1, zeta_rom(a)[i]) == z, "mul(1,zeta rom)", i);
      const uint32_t ge = algo_unit_scale(a) ? g : mm(g, k2_const(a));
      Report::expect(it, gamma_rom(a)[i] == ge, "gamma rom", i, gamma_rom(a)[i], ge);
      Report::expect(it, mm(mm(gamma_rom(a)[i], s), s) == g, "gamma rom * S^2", i);
      Report::expect(it,
                     rom_read(a, RomKind::Zeta, i) == zeta_rom(a)[i] &&
                         rom_read(a, RomKind::Gamma, i) == gamma_rom(a)[i],
                     "rom_read");
    }
  }
  // Cross check with the existing twiddle ROM model (independent code path).
  const MulKind mk[NUM_ALGOS] = {MulKind::Barrett, MulKind::Mont12, MulKind::ShiftAdd,
                                 MulKind::K2Red};
  for (int a = 0; a < NUM_ALGOS; ++a)
    for (int i = 0; i < 128; ++i)
      Report::expect(it, zeta_rom(Algo(a))[i] == twiddle_rom(mk[a])[i], "vs twiddle_rom", i);
}

// bfu: boundary combinations, every ROM value, 1M random z, 1M random with ROM z.
void test_bfu(Report& rep, uint64_t seed) {
  for (Algo algo : ALL_ALGOS) {
    for (Mode mode : {Mode::CT, Mode::GS}) {
      auto& it = rep.add("hw", tag(algo, mode == Mode::CT ? "bfu CT" : "bfu GS") +
                                   ", edges+ROM z+2x1M rnd");
      auto check = [&](uint16_t a, uint16_t b, uint16_t z) {
        const BfuOut o = bfu(algo, mode, a, b, z);
        const BfuOut e = bfu_oracle(algo, mode, a, b, z);
        Report::expect(it, o.x == e.x && o.y == e.y, "bfu", (long long)a << 24 | b << 12 | z,
                       o.x * 4096 + o.y, e.x * 4096 + e.y);
      };
      std::vector<uint16_t> rom_vals;
      for (int i = 0; i < 128; ++i) rom_vals.push_back(zeta_rom(algo)[i]);
      for (int i = 0; i < 128; ++i) rom_vals.push_back(gamma_rom(algo)[i]);
      rom_vals.push_back(k2_const(algo));
      for (uint16_t a : EDGE)
        for (uint16_t b : EDGE) {
          for (uint16_t z : EDGE) check(a, b, z);
          for (uint16_t z : rom_vals) check(a, b, z);
        }
      Rng rng(seed ^ 0xBF00ull ^ (uint64_t(algo) << 8) ^ uint64_t(mode));
      for (int n = 0; n < NUM_BFU_RANDOM; ++n) check(rng.coeff(), rng.coeff(), rng.coeff());
      for (int n = 0; n < NUM_BFU_RANDOM; ++n) {
        const uint16_t a = rng.coeff(), b = rng.coeff();
        const int zi = n % 128;
        check(a, b, rom_vals[size_t(n % int(rom_vals.size()))]);
        // With the zeta ROM the bfu equals the canonical FIPS butterfly
        // (halved for GS).
        const BfuOut o = bfu(algo, mode, a, b, zeta_rom(algo)[zi]);
        const BflyOut c = mode == Mode::CT ? ct_butterfly(MulKind::Ref, a, b, zeta_table()[zi])
                                           : gs_butterfly(MulKind::Ref, a, b, zeta_table()[zi]);
        const uint16_t ex = mode == Mode::CT ? c.a : mod_half_ref(c.a);
        const uint16_t ey = mode == Mode::CT ? c.b : mod_half_ref(c.b);
        Report::expect(it, o.x == ex && o.y == ey, "bfu vs FIPS butterfly", n, o.x * 4096 + o.y,
                       ex * 4096 + ey);
      }
    }
  }
}

// ---------------------------------------------------------------------------
std::vector<Poly> poly_set(Rng& rng, int n_random) {
  std::vector<Poly> v;
  for (auto& bc : boundary_polys()) v.push_back(bc.second);
  for (int i = 0; i < n_random; ++i) v.push_back(rng.poly());
  return v;
}

void test_hw_transforms(Report& rep, uint64_t seed) {
  Rng rng(seed ^ 0x4E77ull);
  const std::vector<Poly> set = poly_set(rng, NUM_HW_POLY);
  for (Algo algo : ALL_ALGOS) {
    auto& f = rep.add("hw", tag(algo, "hw_ntt") + " == ntt, 2000+6 polys");
    auto& i = rep.add("hw", tag(algo, "hw_intt") + " == intt, 2000+6 polys");
    for (const Poly& p : set) {
      Report::expect(f, hw_ntt_poly(algo, p) == ntt(p), "hw ntt");
      Report::expect(i, hw_intt_poly(algo, p) == intt(p), "hw intt");
    }
  }
}

void test_hw_basemul(Report& rep, uint64_t seed) {
  Rng rng(seed ^ 0xBA5Eull);
  std::vector<std::pair<Poly, Poly>> cases;
  const auto bc = boundary_polys();
  for (auto& x : bc)
    for (auto& y : bc) cases.emplace_back(x.second, y.second);
  for (int n = 0; n < NUM_HW_POLY; ++n) cases.emplace_back(rng.poly(), rng.poly());
  for (Algo algo : ALL_ALGOS) {
    auto& it = rep.add("hw", tag(algo, "hw_basemul") + " == multiply_ntts, 2036");
    const size_t nops = basemul_program(algo).size();
    Report::expect(it, nops == (algo_unit_scale(algo) ? 5u : 7u), "op count", int(algo),
                   (long long)nops);
    for (auto& c : cases)
      Report::expect(it, hw_basemul_poly(algo, c.first, c.second) ==
                             multiply_ntts(c.first, c.second),
                     "hw basemul");
  }
}

// Ping-pong banks, schedule order and trace replay.
void test_hw_trace(Report& rep, uint64_t seed) {
  Rng rng(seed ^ 0x7ACEull);
  auto& it = rep.add("hw", "hw ntt/intt trace: schedule, ping-pong, replay");
  for (Algo algo : ALL_ALGOS) {
    for (int n = 0; n < NUM_HW_TRACE; ++n) {
      const Poly f = rng.poly();
      for (int dir = 0; dir < 2; ++dir) {
        const int in_bank = n & 1;
        Banks m{};
        m.bank[in_bank] = f;
        m.bank[in_bank ^ 1] = rng.poly();  // stale contents of the other bank
        std::vector<BfuTraceRec> tr;
        const int rb = dir == 0 ? hw_ntt(algo, m, in_bank, &tr) : hw_intt(algo, m, in_bank, &tr);
        Report::expect(it, rb == (in_bank ^ 1), "result bank", n, rb, in_bank ^ 1);
        Report::expect(it, tr.size() == size_t(SCHED_STEPS), "trace size");
        // Canonical model trace and per-layer states as reference.
        std::vector<ButterflyRecord> ref_tr;
        std::vector<Poly> ref_layers;
        NttObserver obs{&ref_tr, &ref_layers};
        const Poly out = dir == 0 ? ntt(f, MulKind::Ref, &obs) : intt(f, MulKind::Ref, &obs);
        Report::expect(it, m.bank[rb] == out, "result");
        Banks r{};
        r.bank[in_bank] = f;
        uint32_t scale = 1;  // INTT: layer L state = canonical layer L * 2^-(L+1)
        for (int L = 0; L < 7; ++L) {
          const int rd = in_bank ^ (L & 1), wr = rd ^ 1;
          scale = mm(scale, Q_INV2);
          for (int b = 0; b < 128; ++b) {
            const BfuTraceRec& x = tr[size_t(L * 128 + b)];
            const ButterflyRecord& y = ref_tr[size_t(L * 128 + b)];
            bool ok = x.s.layer == L && x.s.step == b && x.rd_bank == rd && x.wr_bank == wr &&
                      x.s.addr0 == y.j0 && x.s.addr1 == y.j0 + y.len && x.s.len == y.len &&
                      x.s.zeta_addr == y.zeta_idx &&
                      x.s.mode == (dir == 0 ? Mode::CT : Mode::GS) &&
                      x.z == zeta_rom(algo)[size_t(x.s.zeta_addr)];
            ok = ok && r.bank[rd][x.s.addr0] == x.a && r.bank[rd][x.s.addr1] == x.b;
            const BfuOut o = bfu(algo, x.s.mode, x.a, x.b, x.z);
            ok = ok && o.x == x.x && o.y == x.y;
            Report::expect(it, ok, "record", L * 128 + b);
            r.bank[wr][x.s.addr0] = x.x;
            r.bank[wr][x.s.addr1] = x.y;
          }
          Poly e = ref_layers[size_t(L)];
          if (dir == 1)
            for (auto& c : e) c = uint16_t(mm(c, scale));
          Report::expect(it, r.bank[wr] == e, "layer state", L);
        }
        // The data-independent schedule equals the executed one.
        const auto& sched = transform_schedule(dir == 0 ? Mode::CT : Mode::GS);
        bool same = true;
        for (size_t k = 0; k < tr.size(); ++k)
          same = same && sched[k].addr0 == tr[k].s.addr0 && sched[k].addr1 == tr[k].s.addr1 &&
                 sched[k].zeta_addr == tr[k].s.zeta_addr && sched[k].layer == tr[k].s.layer;
        Report::expect(it, same, "schedule");
      }
    }
  }
}

void test_basemul_trace(Report& rep, uint64_t seed) {
  Rng rng(seed ^ 0x7B5Eull);
  auto& it = rep.add("hw", "hw basemul trace: program, sources, replay");
  for (Algo algo : ALL_ALGOS) {
    const auto& prog = basemul_program(algo);
    for (int n = 0; n < NUM_HW_TRACE; ++n) {
      const Poly a = rng.poly(), b = rng.poly();
      std::vector<BasemulTraceRec> tr;
      const Poly c = hw_basemul_poly(algo, a, b, &tr);
      Report::expect(it, tr.size() == 128 * prog.size(), "trace size");
      for (int p = 0; p < 128; ++p) {
        uint16_t reg[2] = {0, 0};
        for (size_t k = 0; k < prog.size(); ++k) {
          const BasemulTraceRec& x = tr[size_t(p) * prog.size() + k];
          auto val = [&](Src s) -> uint16_t {
            switch (s) {
              case Src::Zero: return 0;
              case Src::A0: return a[2 * p];
              case Src::A1: return a[2 * p + 1];
              case Src::B0: return b[2 * p];
              case Src::B1: return b[2 * p + 1];
              case Src::R0: return reg[0];
              case Src::R1: return reg[1];
              case Src::RomGamma: return gamma_rom(algo)[size_t(p)];
              case Src::RomK2: return k2_const(algo);
            }
            return 0xFFFF;
          };
          bool ok = x.pair == p && x.op == int(k) && x.u.a == prog[k].a && x.u.b == prog[k].b &&
                    x.u.z == prog[k].z && x.u.dst == prog[k].dst && x.a == val(x.u.a) &&
                    x.b == val(x.u.b) && x.z == val(x.u.z) &&
                    x.x == bfu(algo, Mode::CT, x.a, x.b, x.z).x;
          if (x.u.dst == Dst::R0) reg[0] = x.x;
          if (x.u.dst == Dst::R1) reg[1] = x.x;
          if (x.u.dst == Dst::C0) ok = ok && c[2 * p] == x.x;
          if (x.u.dst == Dst::C1) ok = ok && c[2 * p + 1] == x.x;
          Report::expect(it, ok, "record", p * 16 + int(k));
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// External vectors (data/vectors/ext, read only)
// ---------------------------------------------------------------------------
bool load_hex_polys(const std::string& path, std::vector<Poly>& out) {
  std::ifstream in(path);
  if (!in) return false;
  std::vector<uint16_t> v;
  std::string line;
  while (std::getline(in, line)) {
    if (line.empty()) continue;
    const unsigned long x = std::stoul(line, nullptr, 16);
    if (x >= Q) return false;
    v.push_back(uint16_t(x));
  }
  if (v.size() % N != 0) return false;
  out.resize(v.size() / N);
  for (size_t i = 0; i < v.size(); ++i) out[i / N][i % N] = v[i];
  return true;
}

void test_ext(Report& rep, const std::string& dir) {
  struct Spec {
    const char* name;
    const char* in1;
    const char* in2;
    const char* out;
    size_t count;
  };
  const Spec specs[] = {{"ntt", "ntt_in.hex", nullptr, "ntt_out.hex", 855},
                        {"intt", "intt_in.hex", nullptr, "intt_out.hex", 450},
                        {"basemul", "basemul_a.hex", "basemul_b.hex", "basemul_out.hex", 2145}};
  for (const Spec& s : specs) {
    auto& it = rep.add("hw-ext", std::string("hw_") + s.name + " x 4 algo == ext " + s.out);
    std::vector<Poly> a, b, o;
    const bool ok = load_hex_polys(dir + "/" + s.in1, a) &&
                    (!s.in2 || load_hex_polys(dir + "/" + s.in2, b)) &&
                    load_hex_polys(dir + "/" + s.out, o);
    if (!ok || a.size() != s.count || o.size() != s.count || (s.in2 && b.size() != s.count)) {
      std::printf("  ext vectors missing or wrong size in %s (%s)\n", dir.c_str(), s.name);
      Report::expect(it, false, "ext file");  // a missing file is a failure, not a skip
      continue;
    }
    for (Algo algo : ALL_ALGOS)
      for (size_t k = 0; k < s.count; ++k) {
        Poly r;
        if (s.in2)
          r = hw_basemul_poly(algo, a[k], b[k]);
        else if (std::string(s.name) == "ntt")
          r = hw_ntt_poly(algo, a[k]);
        else
          r = hw_intt_poly(algo, a[k]);
        Report::expect(it, r == o[k], s.name, (long long)k);
      }
  }
}

// ---------------------------------------------------------------------------
void test_hw_dpi(Report& rep, uint64_t seed) {
  Rng rng(seed ^ 0xD9D9ull);
  auto& it = rep.add("hw", "hw dpi wrapper == C++ API");
  for (int n = 0; n < NUM_HW_DPI; ++n) {
    const Poly f = rng.poly(), g = rng.poly();
    int fi[256], gi[256], o[256];
    for (int i = 0; i < 256; ++i) {
      fi[i] = f[i];
      gi[i] = g[i];
    }
    const int a = f[0], b = f[1], z = f[2], zi = n % 128;
    const int x24 = int(rng.below(1u << 24)), xm = int(rng.below(uint64_t(Q) << 12));
    bool ok = mlkem_dpi_barrett_reduce(x24) == barrett_reduce(uint32_t(x24)) &&
              mlkem_dpi_shiftadd_reduce(x24) == shiftadd_reduce(uint32_t(x24)) &&
              mlkem_dpi_k2red_reduce(x24) == k2red_reduce(uint32_t(x24)) &&
              mlkem_dpi_mont12_reduce(xm) == mont12_reduce(uint32_t(xm)) &&
              mlkem_dpi_mod_half(a) == mod_half(uint16_t(a));
    // Domain rejection.
    ok = ok && mlkem_dpi_barrett_reduce(1 << 24) == -1 && mlkem_dpi_shiftadd_reduce(-1) == -1 &&
         mlkem_dpi_k2red_reduce(1 << 24) == -1 && mlkem_dpi_mont12_reduce(int(Q) << 12) == -1 &&
         mlkem_dpi_mod_half(int(Q)) == -1 && mlkem_dpi_rom(4, 0, 0) == -1 &&
         mlkem_dpi_rom(0, 3, 0) == -1 && mlkem_dpi_basemul_nops(-1) == -1 &&
         mlkem_dpi_hw_ntt(4, fi, o) == -1;
    int x, y;
    mlkem_dpi_bfu(0, 2, a, b, z, &x, &y);
    ok = ok && x == -1 && y == -1;
    for (Algo al : ALL_ALGOS) {
      const int ai = int(al);
      for (int md = 0; md < 2; ++md) {
        mlkem_dpi_bfu(ai, md, a, b, z, &x, &y);
        const BfuOut e = bfu(al, Mode(md), uint16_t(a), uint16_t(b), uint16_t(z));
        ok = ok && x == e.x && y == e.y;
      }
      ok = ok && mlkem_dpi_rom(ai, 0, zi) == zeta_rom(al)[zi] &&
           mlkem_dpi_rom(ai, 1, zi) == gamma_rom(al)[zi] && mlkem_dpi_rom(ai, 2, 0) == k2_const(al);
      ok = ok && mlkem_dpi_algo_scale(ai, 1) == algo_scale(al) &&
           mlkem_dpi_algo_scale(ai, -1) == algo_scale_inv(al) &&
           mlkem_dpi_algo_scale(ai, -2) == algo_scale_inv2(al);
      const auto& prog = basemul_program(al);
      ok = ok && mlkem_dpi_basemul_nops(ai) == int(prog.size());
      for (size_t k = 0; k < prog.size(); ++k) {
        int sa, sb, sz, d;
        ok = ok && mlkem_dpi_basemul_op(ai, int(k), &sa, &sb, &sz, &d) == 0 &&
             sa == int(prog[k].a) && sb == int(prog[k].b) && sz == int(prog[k].z) &&
             d == int(prog[k].dst);
      }
      int c0, c1;
      ok = ok && mlkem_dpi_hw_basemul_pair(ai, f[0], f[1], g[0], g[1], zi, &c0, &c1) == 0;
      const BflyOut bm = basecase_multiply(f[0], f[1], g[0], g[1], gamma_table()[zi]);
      ok = ok && c0 == bm.a && c1 == bm.b;
      if (n < 50) {  // polynomial level, fewer iterations
        ok = ok && mlkem_dpi_hw_ntt(ai, fi, o) == 0;
        Poly e = ntt(f);
        for (int i = 0; i < 256; ++i) ok = ok && o[i] == e[i];
        ok = ok && mlkem_dpi_hw_intt(ai, fi, o) == 0;
        e = intt(f);
        for (int i = 0; i < 256; ++i) ok = ok && o[i] == e[i];
        ok = ok && mlkem_dpi_hw_basemul(ai, fi, gi, o) == 0;
        e = multiply_ntts(f, g);
        for (int i = 0; i < 256; ++i) ok = ok && o[i] == e[i];
      }
    }
    for (int md = 0; md < 2; ++md) {
      const int step = int(rng.below(SCHED_STEPS));
      int l, len, a0, a1, za;
      const SchedStep& s = transform_schedule(Mode(md))[size_t(step)];
      ok = ok && mlkem_dpi_hw_sched(md, step, &l, &len, &a0, &a1, &za) == 0 && l == s.layer &&
           len == s.len && a0 == s.addr0 && a1 == s.addr1 && za == s.zeta_addr;
      ok = ok && mlkem_dpi_hw_sched(md, SCHED_STEPS, &l, &len, &a0, &a1, &za) == -1;
    }
    Report::expect(it, ok, "hw dpi", n);
  }
}

}  // namespace

void run_hw_tests(Report& rep, uint64_t seed, const std::string& ext_dir) {
  std::printf("[hw 1/6] mod_half, ROMs\n");
  test_mod_half(rep);
  test_roms(rep);
  std::printf("[hw 2/6] bfu\n");
  test_bfu(rep, seed);
  std::printf("[hw 3/6] hardware-schedule ntt/intt\n");
  test_hw_transforms(rep, seed);
  test_hw_trace(rep, seed);
  std::printf("[hw 4/6] basemul micro-op program\n");
  test_hw_basemul(rep, seed);
  test_basemul_trace(rep, seed);
  std::printf("[hw 5/6] external vectors (%s)\n", ext_dir.c_str());
  test_ext(rep, ext_dir);
  std::printf("[hw 6/6] hw dpi wrapper\n");
  test_hw_dpi(rep, seed);
}
