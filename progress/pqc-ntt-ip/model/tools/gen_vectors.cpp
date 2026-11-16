// Test vector generator for RTL / HLS verification.
//
// Usage: gen_vectors [--seed S] [--count N] [--nred M] [--out DIR]
//   --seed   PRNG seed (default 1)
//   --count  number of random polynomials / polynomial pairs (default 100);
//            6 boundary cases are always prepended
//   --nred   number of random scalar vectors per reduction / butterfly file
//            (default 100000); boundary operands are always prepended
//   --out    output directory (default vectors), must exist
//
// Scalar files (*.txt): one vector per line, whitespace-separated hex fields,
//   "//" comment header naming the fields. Readable with $fscanf("%h %h ...").
// Polynomial files (*.hex): one 12-bit coefficient per line, 3 hex digits,
//   $readmemh compatible. Case c occupies lines [c*256, c*256+255]
//   (layer dumps: [(c*L + l)*256, ...] with L layers per case).
// Hardware-structure files (include/mlkem_hw.h), <algo> in barrett, mont12,
//   shiftadd, k2red:
//   rom_zeta_<algo>.hex, rom_gamma_<algo>.hex (128 lines), rom_k2_<algo>.hex (1 line)
//   bfu_<algo>.txt          mode a b z x y (scalar, edges then random)
//   mod_half.txt            x h, all x in [0, q)
//   hw_ntt_trace_<algo>.txt, hw_intt_trace_<algo>.txt, hw_basemul_trace_<algo>.txt
//                           per bfu call trace of the trace case (see manifest)
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "mlkem_cases.h"
#include "mlkem_hw.h"
#include "mlkem_modarith.h"
#include "mlkem_ntt.h"
#include "mlkem_rng.h"

using namespace mlkem;

namespace {

struct Args {
  uint64_t seed = 1;
  int count = 100;
  int nred = 100000;
  std::string out = "vectors";
};

FILE* open_out(const Args& a, const std::string& name) {
  const std::string path = a.out + "/" + name;
  FILE* f = std::fopen(path.c_str(), "w");
  if (!f) {
    std::fprintf(stderr, "cannot open %s\n", path.c_str());
    std::exit(1);
  }
  return f;
}

void write_poly(FILE* f, const Poly& p) {
  for (uint16_t c : p) std::fprintf(f, "%03x\n", c);
}

// FNV-1a, used to derive a per-file stream from the seed (portable, unlike std::hash).
uint64_t fnv1a(const char* s) {
  uint64_t h = 0xCBF29CE484222325ull;
  for (; *s; ++s) h = (h ^ uint8_t(*s)) * 0x100000001B3ull;
  return h;
}

// Reduction vectors: x, expected. Boundary values first, then uniform random
// over the full input domain of the variant.
void gen_reduce(const Args& a, const char* name, uint64_t domain, const char* func,
                uint16_t (*fn)(uint32_t), uint64_t (*expect)(uint64_t)) {
  FILE* f = open_out(a, std::string("reduce_") + name + ".txt");
  std::fprintf(f, "// %s: x (hex), expected (hex). domain x in [0, 0x%" PRIx64 "). %s\n", name,
               domain, func);
  std::fprintf(f, "// seed=%" PRIu64 " random=%d\n", a.seed, a.nred);
  std::vector<uint64_t> xs = {0, 1, Q - 1, Q, Q + 1, 2 * Q - 1, 2 * Q, uint64_t(Q - 1) * (Q - 1),
                              uint64_t(Q) * Q - 1, 4095, 4096, domain - 2, domain - 1};
  Rng rng(a.seed ^ fnv1a(name));
  for (int i = 0; i < a.nred; ++i) xs.push_back(rng.below(domain));
  for (uint64_t x : xs) {
    if (x >= domain) continue;
    const uint16_t r = fn(uint32_t(x));
    if (r != expect(x)) {
      std::fprintf(stderr, "internal mismatch %s x=%" PRIu64 "\n", name, x);
      std::exit(1);
    }
    std::fprintf(f, "%07" PRIx64 " %03x\n", x, r);
  }
  std::fclose(f);
}

uint64_t exp_mod(uint64_t x) { return x % Q; }
uint64_t exp_m12(uint64_t x) { return x % Q * MONT12_RINV % Q; }
uint64_t exp_m16(uint64_t x) { return x % Q * MONT16_RINV % Q; }
uint64_t exp_k2(uint64_t x) { return x % Q * K2RED_FACTOR % Q; }

void gen_scalar(const Args& a) {
  gen_reduce(a, "barrett", 1ull << 24, "out = x mod q", barrett_reduce, exp_mod);
  gen_reduce(a, "shiftadd", 1ull << 24, "out = x mod q", shiftadd_reduce, exp_mod);
  gen_reduce(a, "mont12", uint64_t(Q) << 12, "out = x * 2^-12 mod q", mont12_reduce, exp_m12);
  gen_reduce(a, "mont16", uint64_t(Q) << 16, "out = x * 2^-16 mod q", mont16_reduce, exp_m16);
  gen_reduce(a, "k2red", 1ull << 24, "out = 169 * x mod q", k2red_reduce, exp_k2);

  Rng rng(a.seed ^ 0xA5A5ull);
  std::vector<std::pair<uint16_t, uint16_t>> ops;
  const uint16_t edge[] = {0, 1, 2, uint16_t(Q / 2), uint16_t(Q - 2), uint16_t(Q - 1)};
  for (uint16_t x : edge)
    for (uint16_t y : edge) ops.emplace_back(x, y);
  for (int i = 0; i < a.nred; ++i) ops.emplace_back(rng.coeff(), rng.coeff());

  FILE* f = open_out(a, "modarith.txt");
  std::fprintf(f, "// a b (a+b)%%q (a-b)%%q (a*b)%%q, all hex, operands in [0,q)\n");
  for (auto& o : ops)
    std::fprintf(f, "%03x %03x %03x %03x %03x\n", o.first, o.second, mod_add_ref(o.first, o.second),
                 mod_sub_ref(o.first, o.second), mod_mul_ref(o.first, o.second));
  std::fclose(f);

  // Butterflies: zeta index cycles through all 128 entries. Outputs are
  // canonical and independent of the multiplier; ROM values are in the
  // twiddle_rom_*.hex files.
  FILE* fc = open_out(a, "bfly_ct.txt");
  FILE* fg = open_out(a, "bfly_gs.txt");
  std::fprintf(fc, "// CT: a b zeta_idx zeta a_out=a+zeta*b b_out=a-zeta*b (mod q), hex\n");
  std::fprintf(fg, "// GS: a b zeta_idx zeta a_out=a+b b_out=zeta*(b-a) (mod q), hex\n");
  for (size_t i = 0; i < ops.size(); ++i) {
    const int zi = int(i % 128);
    const uint16_t z = zeta_table()[zi];
    const BflyOut c = ct_butterfly(MulKind::Ref, ops[i].first, ops[i].second, z);
    const BflyOut g = gs_butterfly(MulKind::Ref, ops[i].first, ops[i].second, z);
    std::fprintf(fc, "%03x %03x %02x %03x %03x %03x\n", ops[i].first, ops[i].second, zi, z, c.a,
                 c.b);
    std::fprintf(fg, "%03x %03x %02x %03x %03x %03x\n", ops[i].first, ops[i].second, zi, z, g.a,
                 g.b);
  }
  std::fclose(fc);
  std::fclose(fg);

  FILE* fb = open_out(a, "basemul.txt");
  std::fprintf(fb, "// BaseCaseMultiply: a0 a1 b0 b1 gamma_idx gamma c0 c1, hex\n");
  for (size_t i = 0; i + 1 < ops.size(); i += 2) {
    const int gi = int((i / 2) % 128);
    const uint16_t gm = gamma_table()[gi];
    const BflyOut c =
        basecase_multiply(ops[i].first, ops[i].second, ops[i + 1].first, ops[i + 1].second, gm);
    std::fprintf(fb, "%03x %03x %03x %03x %02x %03x %03x %03x\n", ops[i].first, ops[i].second,
                 ops[i + 1].first, ops[i + 1].second, gi, gm, c.a, c.b);
  }
  std::fclose(fb);

  // Tables (ROM init files).
  FILE* fz = open_out(a, "zeta_table.hex");
  FILE* fgm = open_out(a, "gamma_table.hex");
  for (int i = 0; i < 128; ++i) {
    std::fprintf(fz, "%03x\n", zeta_table()[i]);
    std::fprintf(fgm, "%03x\n", gamma_table()[i]);
  }
  std::fclose(fz);
  std::fclose(fgm);
  for (int k = 0; k < NUM_MUL_KINDS; ++k) {
    FILE* fr = open_out(a, std::string("twiddle_rom_") + mul_kind_name(MulKind(k)) + ".hex");
    for (int i = 0; i < 128; ++i) std::fprintf(fr, "%03x\n", twiddle_rom(MulKind(k))[i]);
    std::fprintf(fr, "%03x\n", intt_scale_rom(MulKind(k)));  // entry 128: INTT 128^-1 scale
    std::fclose(fr);
  }
}

// Hardware-structure scalar files: ROMs, mod_half, bfu.
void gen_hw_scalar(const Args& a) {
  FILE* fh = open_out(a, "mod_half.txt");
  std::fprintf(fh, "// mod_half: x h, h = x * 2^-1 mod q, all x in [0, q), hex\n");
  for (uint32_t x = 0; x < Q; ++x) std::fprintf(fh, "%03x %03x\n", x, mod_half(uint16_t(x)));
  std::fclose(fh);

  const uint16_t edge[] = {0, 1, uint16_t(Q - 1), uint16_t((Q - 1) / 2), uint16_t((Q + 1) / 2)};
  for (hw::Algo al : hw::ALL_ALGOS) {
    const std::string n = hw::algo_name(al);
    const struct {
      const char* prefix;
      hw::RomKind kind;
    } roms[] = {{"rom_zeta_", hw::RomKind::Zeta},
                {"rom_gamma_", hw::RomKind::Gamma},
                {"rom_k2_", hw::RomKind::K2}};
    for (const auto& r : roms) {
      FILE* f = open_out(a, r.prefix + n + ".hex");
      hw::dump_rom_hex(f, al, r.kind);
      std::fclose(f);
    }

    FILE* f = open_out(a, "bfu_" + n + ".txt");
    std::fprintf(f,
                 "// bfu %s: mode(0=CT,1=GS) a b z x y, hex. mul(b,z) = b*z*S mod q, S = %u. "
                 "CT: x=a+mul(b,z) y=a-mul(b,z); GS: x=half(a+b) y=half(mul(b-a,z))\n",
                 n.c_str(), hw::algo_scale(al));
    std::fprintf(f, "// seed=%" PRIu64 " random=%d per mode; edges first, random z and ROM z alternate\n",
                 a.seed, a.nred);
    auto line = [&](int mode, uint16_t x0, uint16_t x1, uint16_t z) {
      const hw::BfuOut o = hw::bfu(al, hw::Mode(mode), x0, x1, z);
      std::fprintf(f, "%d %03x %03x %03x %03x %03x\n", mode, x0, x1, z, o.x, o.y);
    };
    for (int mode = 0; mode < 2; ++mode)
      for (uint16_t x0 : edge)
        for (uint16_t x1 : edge)
          for (uint16_t z : edge) line(mode, x0, x1, z);
    Rng rng(a.seed ^ fnv1a(("bfu_" + n).c_str()));
    for (int mode = 0; mode < 2; ++mode)
      for (int i = 0; i < a.nred; ++i) {
        const uint16_t x0 = rng.coeff(), x1 = rng.coeff();
        uint16_t z = rng.coeff();
        if (i & 1) {
          const int k = int(rng.below(257));
          z = k < 128 ? hw::zeta_rom(al)[k] : k < 256 ? hw::gamma_rom(al)[k - 128] : hw::k2_const(al);
        }
        line(mode, x0, x1, z);
      }
    std::fclose(f);
  }
}

void write_trace(FILE* f, const std::vector<ButterflyRecord>& tr) {
  std::fprintf(f, "// layer len zeta_idx j0 j1 a_in b_in zeta w_rom a_out b_out (decimal idx, hex data)\n");
  for (const auto& r : tr)
    std::fprintf(f, "%d %d %d %d %d %03x %03x %03x %03x %03x %03x\n", r.layer, r.len, r.zeta_idx,
                 r.j0, r.j0 + r.len, r.a_in, r.b_in, r.zeta, r.w_rom, r.a_out, r.b_out);
}

void gen_poly(const Args& a) {
  Rng rng(a.seed ^ 0x9017ull);
  const auto bc = boundary_polys();
  std::vector<std::string> names;
  std::vector<Poly> fs, gs;
  for (size_t i = 0; i < bc.size(); ++i) {
    names.push_back(bc[i].first);
    fs.push_back(bc[i].second);
    gs.push_back(bc[(i + 1) % bc.size()].second);  // pair with the next boundary case
  }
  for (int i = 0; i < a.count; ++i) {
    names.push_back("random_" + std::to_string(i));
    fs.push_back(rng.poly());
    gs.push_back(rng.poly());
  }

  FILE* ni = open_out(a, "ntt_in.hex");
  FILE* no = open_out(a, "ntt_out.hex");
  FILE* nl = open_out(a, "ntt_layers.hex");
  FILE* ii = open_out(a, "intt_in.hex");
  FILE* io = open_out(a, "intt_out.hex");
  FILE* il = open_out(a, "intt_layers.hex");
  FILE* ma = open_out(a, "mul_a.hex");
  FILE* mb = open_out(a, "mul_b.hex");
  FILE* mo = open_out(a, "mul_out.hex");
  FILE* pf = open_out(a, "polymul_f.hex");
  FILE* pg = open_out(a, "polymul_g.hex");
  FILE* ph = open_out(a, "polymul_h.hex");
  for (size_t c = 0; c < fs.size(); ++c) {
    std::vector<Poly> layers;
    NttObserver obs{nullptr, &layers};
    // NTT: input in coefficient domain.
    const Poly fh = ntt(fs[c], MulKind::Ref, &obs);
    write_poly(ni, fs[c]);
    write_poly(no, fh);
    for (auto& l : layers) write_poly(nl, l);
    // INTT: input is an arbitrary element of T_q (fs[c] reused as NTT domain data).
    layers.clear();
    const Poly fi = intt(fs[c], MulKind::Ref, &obs);
    write_poly(ii, fs[c]);
    write_poly(io, fi);
    for (auto& l : layers) write_poly(il, l);
    // MultiplyNTTs on NTT-domain operands.
    write_poly(ma, fs[c]);
    write_poly(mb, gs[c]);
    write_poly(mo, multiply_ntts(fs[c], gs[c]));
    // Full chain: coefficient-domain product, checked against schoolbook.
    const Poly h = intt(multiply_ntts(ntt(fs[c]), ntt(gs[c])));
    if (h != poly_mul_schoolbook(fs[c], gs[c])) {
      std::fprintf(stderr, "internal mismatch polymul case %zu\n", c);
      std::exit(1);
    }
    write_poly(pf, fs[c]);
    write_poly(pg, gs[c]);
    write_poly(ph, h);
  }
  for (FILE* f : {ni, no, nl, ii, io, il, ma, mb, mo, pf, pg, ph}) std::fclose(f);

  // Butterfly-level trace of the first random case (or the last boundary case).
  const size_t tc = bc.size() < fs.size() ? bc.size() : fs.size() - 1;
  std::vector<ButterflyRecord> tr;
  NttObserver obs{&tr, nullptr};
  ntt(fs[tc], MulKind::Ref, &obs);
  FILE* tn = open_out(a, "ntt_trace.txt");
  std::fprintf(tn, "// NTT butterfly trace of case %zu (%s), ROM values for MulKind ref\n", tc,
               names[tc].c_str());
  write_trace(tn, tr);
  std::fclose(tn);
  tr.clear();
  intt(fs[tc], MulKind::Ref, &obs);
  FILE* ti = open_out(a, "intt_trace.txt");
  std::fprintf(ti, "// INTT butterfly trace of case %zu (%s), final *3303 scaling not included\n",
               tc, names[tc].c_str());
  write_trace(ti, tr);
  std::fclose(ti);

  // Hardware-schedule traces of the same case for every ALGO.
  for (hw::Algo al : hw::ALL_ALGOS) {
    const std::string n = hw::algo_name(al);
    std::vector<hw::BfuTraceRec> ht;
    hw::hw_ntt_poly(al, fs[tc], &ht);
    FILE* f = open_out(a, "hw_ntt_trace_" + n + ".txt");
    std::fprintf(f, "// hw NTT (%s) bfu trace of case %zu (%s), input in bank 0, result in bank 1\n",
                 n.c_str(), tc, names[tc].c_str());
    hw::dump_bfu_trace(f, ht);
    std::fclose(f);
    ht.clear();
    hw::hw_intt_poly(al, fs[tc], &ht);
    f = open_out(a, "hw_intt_trace_" + n + ".txt");
    std::fprintf(f,
                 "// hw INTT (%s) bfu trace of case %zu (%s), input in bank 0, result in bank 1, "
                 "no separate scaling (GS halves both outputs)\n",
                 n.c_str(), tc, names[tc].c_str());
    hw::dump_bfu_trace(f, ht);
    std::fclose(f);
    std::vector<hw::BasemulTraceRec> bt;
    hw::hw_basemul_poly(al, fs[tc], gs[tc], &bt);
    f = open_out(a, "hw_basemul_trace_" + n + ".txt");
    std::fprintf(f,
                 "// hw basemul (%s, %zu ops/pair) trace of case %zu (%s): a = mul_a, b = mul_b of "
                 "that case, a in bank 0, b in bank 1, result in bank 0\n",
                 n.c_str(), hw::basemul_program(al).size(), tc, names[tc].c_str());
    hw::dump_basemul_trace(f, bt);
    std::fclose(f);
  }

  FILE* m = open_out(a, "manifest.txt");
  std::fprintf(m, "seed %" PRIu64 "\ncount %d\nnred %d\ncases %zu\n", a.seed, a.count, a.nred,
               fs.size());
  std::fprintf(m, "ntt_layers_per_case 7\nintt_layers_per_case 8 (7 GS layers + 3303 scaling)\n");
  std::fprintf(m, "trace_case %zu\n", tc);
  for (size_t c = 0; c < names.size(); ++c) std::fprintf(m, "case %zu %s\n", c, names[c].c_str());
  std::fclose(m);
}

}  // namespace

int main(int argc, char** argv) {
  Args a;
  for (int i = 1; i < argc; ++i) {
    if (!std::strcmp(argv[i], "--seed") && i + 1 < argc)
      a.seed = std::strtoull(argv[++i], nullptr, 0);
    else if (!std::strcmp(argv[i], "--count") && i + 1 < argc)
      a.count = std::atoi(argv[++i]);
    else if (!std::strcmp(argv[i], "--nred") && i + 1 < argc)
      a.nred = std::atoi(argv[++i]);
    else if (!std::strcmp(argv[i], "--out") && i + 1 < argc)
      a.out = argv[++i];
    else {
      std::fprintf(stderr, "usage: %s [--seed S] [--count N] [--nred M] [--out DIR]\n", argv[0]);
      return 2;
    }
  }
  if (a.count < 0 || a.nred < 0) {
    std::fprintf(stderr, "count and nred must be >= 0\n");
    return 2;
  }
  gen_scalar(a);
  gen_hw_scalar(a);
  gen_poly(a);
  std::printf("vectors written to %s (seed=%" PRIu64 ", count=%d, nred=%d)\n", a.out.c_str(),
              a.seed, a.count, a.nred);
  return 0;
}
