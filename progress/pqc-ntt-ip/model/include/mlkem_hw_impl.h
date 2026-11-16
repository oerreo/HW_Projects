// Inline definitions of include/mlkem_hw.h (docs/spec/arch.md).
// Header-only so that every translation unit that includes mlkem_hw.h (for
// example src/mlkem_dpi.cpp compiled by the simulator) links without an
// extra source file. Include mlkem_hw.h, not this file.
#ifndef MLKEM_HW_IMPL_H
#define MLKEM_HW_IMPL_H

#include <array>
#include <stdexcept>

namespace mlkem {
namespace hw {

inline const char* algo_name(Algo a) {
  switch (a) {
    case Algo::Barrett: return "barrett";
    case Algo::Mont12: return "mont12";
    case Algo::ShiftAdd: return "shiftadd";
    case Algo::K2Red: return "k2red";
  }
  return "?";
}

// ---------------------------------------------------------------------------
// Scale constants (constant generation, plain modular arithmetic)
// ---------------------------------------------------------------------------
inline uint16_t algo_scale(Algo a) {
  switch (a) {
    case Algo::Mont12: return uint16_t(MONT12_RINV);       // 2^-12 mod q
    case Algo::K2Red: return uint16_t(K2RED_FACTOR);       // 169
    default: return 1;
  }
}

inline uint16_t algo_scale_inv(Algo a) { return uint16_t(inv_mod(algo_scale(a))); }

inline uint16_t algo_scale_inv2(Algo a) { return mod_mul_ref(algo_scale_inv(a), algo_scale_inv(a)); }

// ---------------------------------------------------------------------------
// bfu
// ---------------------------------------------------------------------------
inline uint16_t bfu_mul(Algo algo, uint16_t b, uint16_t z) {
  const uint32_t p = mul12x12(b, z);  // [23:0], < q^2
  switch (algo) {
    case Algo::Barrett: return barrett_reduce(p);
    case Algo::Mont12: return mont12_reduce(p);
    case Algo::ShiftAdd: return shiftadd_reduce(p);
    case Algo::K2Red: return k2red_reduce(p);
  }
  throw std::invalid_argument("bfu_mul: unknown algo");
}

// Shared datapath: 1 multiplier + reduction, 1 mod_add, 1 mod_sub, 2 mod_half.
//   CT: t = mul(b, z); x = add(a, t);       y = sub(a, t)
//   GS: s = add(a, b); d = sub(b, a);       x = half(s); y = half(mul(d, z))
// GS subtracts b - a (FIPS 203 Alg. 10 line 10: f[j+len] = zeta*(f[j+len] - t)).
// arch.md writes "(a - b)*z/2"; with a - b the single S^-1-scaled zeta ROM gives
// the negated odd output in every layer and the INTT is wrong (mutation M6 in
// the README shows this). Keeping a - b would need a negated INTT zeta ROM, or
// the controller swapping the two read ports in GS mode.
inline BfuOut bfu(Algo algo, Mode mode, uint16_t a, uint16_t b, uint16_t z) {
  if (mode == Mode::CT) {
    const uint16_t t = bfu_mul(algo, b, z);
    return {mod_add_hw(a, t), mod_sub_hw(a, t)};
  }
  const uint16_t s = mod_add_hw(a, b);
  const uint16_t d = mod_sub_hw(b, a);  // GS_SUB_ORDER
  return {mod_half(s), mod_half(bfu_mul(algo, d, z))};
}

// ---------------------------------------------------------------------------
// ROMs
// ---------------------------------------------------------------------------
namespace detail {

struct AlgoRoms {
  Table128 zeta;
  Table128 gamma;
  uint16_t k2;
};

inline AlgoRoms make_roms(Algo a) {
  AlgoRoms r{};
  const uint16_t sinv = algo_scale_inv(a);
  const uint16_t sinv2 = algo_scale_inv2(a);
  for (int i = 0; i < 128; ++i) {
    r.zeta[i] = mod_mul_ref(zeta_table()[i], sinv);   // ZETA_ROM_SCALE
    r.gamma[i] = algo_unit_scale(a) ? gamma_table()[i]
                                    : mod_mul_ref(gamma_table()[i], sinv2);  // GAMMA_ROM_SCALE
  }
  r.k2 = sinv2;  // K2_CONST
  return r;
}

inline const AlgoRoms& roms(Algo a) {
  static const auto all = [] {
    std::array<AlgoRoms, NUM_ALGOS> t{};
    for (int i = 0; i < NUM_ALGOS; ++i) t[i] = make_roms(Algo(i));
    return t;
  }();
  return all.at(size_t(a));
}

}  // namespace detail

inline const Table128& zeta_rom(Algo a) { return detail::roms(a).zeta; }
inline const Table128& gamma_rom(Algo a) { return detail::roms(a).gamma; }
inline uint16_t k2_const(Algo a) { return detail::roms(a).k2; }

inline int rom_read(Algo a, RomKind kind, int index) {
  if (!algo_valid(int(a))) return -1;
  switch (kind) {
    case RomKind::Zeta: return (index >= 0 && index < 128) ? zeta_rom(a)[index] : -1;
    case RomKind::Gamma: return (index >= 0 && index < 128) ? gamma_rom(a)[index] : -1;
    case RomKind::K2: return index == 0 ? k2_const(a) : -1;
  }
  return -1;
}

inline void dump_rom_hex(std::FILE* f, Algo a, RomKind kind) {
  const int n = kind == RomKind::K2 ? 1 : 128;
  for (int i = 0; i < n; ++i) std::fprintf(f, "%03x\n", rom_read(a, kind, i));
}

// ---------------------------------------------------------------------------
// Transform schedule and ping-pong execution
// ---------------------------------------------------------------------------
namespace detail {

inline std::vector<SchedStep> make_schedule(Mode mode) {
  std::vector<SchedStep> v;
  v.reserve(SCHED_STEPS);
  if (mode == Mode::CT) {
    int k = 1;  // Alg. 9: i <- 1, increasing
    int layer = 0;
    for (int len = 128; len >= 2; len /= 2, ++layer) {
      int step = 0;
      for (int start = 0; start < 256; start += 2 * len) {
        const int z = k++;  // NTT_ZETA_STEP
        for (int j = start; j < start + len; ++j)
          v.push_back({layer, step++, len, j, j + len, z, Mode::CT});
      }
    }
  } else {
    int k = 127;  // Alg. 10: i <- 127, decreasing
    int layer = 0;
    for (int len = 2; len <= 128; len *= 2, ++layer) {
      int step = 0;
      for (int start = 0; start < 256; start += 2 * len) {
        const int z = k--;  // INTT_ZETA_STEP
        for (int j = start; j < start + len; ++j)
          v.push_back({layer, step++, len, j, j + len, z, Mode::GS});
      }
    }
  }
  if (v.size() != size_t(SCHED_STEPS)) throw std::logic_error("schedule size");
  return v;
}

inline int run_transform(Algo algo, Mode mode, Banks& m, int in_bank, std::vector<BfuTraceRec>* trace) {
  if (in_bank != 0 && in_bank != 1) throw std::invalid_argument("in_bank");
  const std::vector<SchedStep>& sched = transform_schedule(mode);
  const Table128& rom = zeta_rom(algo);
  int src = in_bank;
  size_t n = 0;
  for (int layer = 0; layer < 7; ++layer) {
    const int dst = src ^ 1;
    std::array<uint8_t, N> written{};
    for (int b = 0; b < 128; ++b, ++n) {
      const SchedStep& s = sched[n];
      const uint16_t a = m.bank[src][s.addr0];
      const uint16_t bb = m.bank[src][s.addr1];
      const uint16_t z = rom[s.zeta_addr];
      const BfuOut o = bfu(algo, s.mode, a, bb, z);
      m.bank[dst][s.addr0] = o.x;
      m.bank[dst][s.addr1] = o.y;
      ++written[s.addr0];
      ++written[s.addr1];
      if (trace) trace->push_back({s, src, dst, a, bb, z, o.x, o.y});
    }
    for (unsigned i = 0; i < N; ++i)
      if (written[i] != 1) throw std::logic_error("layer does not write every address once");
    src = dst;  // PINGPONG_SWAP
  }
  return src;
}

}  // namespace detail

inline const std::vector<SchedStep>& transform_schedule(Mode mode) {
  static const std::vector<SchedStep> ct = detail::make_schedule(Mode::CT);
  static const std::vector<SchedStep> gs = detail::make_schedule(Mode::GS);
  return mode == Mode::CT ? ct : gs;
}

inline int hw_ntt(Algo algo, Banks& m, int in_bank, std::vector<BfuTraceRec>* trace) {
  return detail::run_transform(algo, Mode::CT, m, in_bank, trace);
}

inline int hw_intt(Algo algo, Banks& m, int in_bank, std::vector<BfuTraceRec>* trace) {
  return detail::run_transform(algo, Mode::GS, m, in_bank, trace);
}

inline Poly hw_ntt_poly(Algo algo, const Poly& f, std::vector<BfuTraceRec>* trace) {
  Banks m{};
  m.bank[0] = f;
  return m.bank[hw_ntt(algo, m, 0, trace)];
}

inline Poly hw_intt_poly(Algo algo, const Poly& f_hat, std::vector<BfuTraceRec>* trace) {
  Banks m{};
  m.bank[0] = f_hat;
  return m.bank[hw_intt(algo, m, 0, trace)];
}

inline void dump_bfu_trace(std::FILE* f, const std::vector<BfuTraceRec>& tr) {
  std::fprintf(f,
               "// layer step len rd_bank wr_bank addr0 addr1 zeta_addr mode(0=CT,1=GS) "
               "a b z x y (decimal control, hex data); x -> wr_bank[addr0], y -> wr_bank[addr1]\n");
  for (const auto& r : tr)
    std::fprintf(f, "%d %d %d %d %d %d %d %d %d %03x %03x %03x %03x %03x\n", r.s.layer, r.s.step,
                 r.s.len, r.rd_bank, r.wr_bank, r.s.addr0, r.s.addr1, r.s.zeta_addr, int(r.s.mode),
                 r.a, r.b, r.z, r.x, r.y);
}

// ---------------------------------------------------------------------------
// basemul micro-op program
// ---------------------------------------------------------------------------
inline const char* src_name(Src s) {
  switch (s) {
    case Src::Zero: return "ZERO";
    case Src::A0: return "A0";
    case Src::A1: return "A1";
    case Src::B0: return "B0";
    case Src::B1: return "B1";
    case Src::R0: return "R0";
    case Src::R1: return "R1";
    case Src::RomGamma: return "GAMMA";
    case Src::RomK2: return "K2";
  }
  return "?";
}

inline const char* dst_name(Dst d) {
  switch (d) {
    case Dst::R0: return "R0";
    case Dst::R1: return "R1";
    case Dst::C0: return "C0";
    case Dst::C1: return "C1";
  }
  return "?";
}

namespace detail {

// S = 1 (BARRETT, SHIFTADD): arch.md sequence, one temporary register.
inline const std::vector<MicroOp> PROG_S1 = {
    {Src::Zero, Src::A1, Src::B1, Dst::R0},        // t  = a1*b1
    {Src::Zero, Src::R0, Src::RomGamma, Dst::R0},  // p  = t*gamma
    {Src::R0, Src::A0, Src::B0, Dst::C0},          // c0 = p + a0*b0
    {Src::Zero, Src::A0, Src::B1, Dst::R0},        // u  = a0*b1
    {Src::R0, Src::A1, Src::B0, Dst::C1},          // c1 = u + a1*b0
};

// S != 1 (MONT12, K2RED): arch.md sequence, two temporary registers.
// gamma ROM holds gamma*S^-2, K2 = S^-2.
inline const std::vector<MicroOp> PROG_SX = {
    {Src::Zero, Src::A1, Src::B1, Dst::R0},        // t  = a1*b1*S
    {Src::Zero, Src::R0, Src::RomGamma, Dst::R0},  // p  = t*gamma*S^-2*S = a1*b1*gamma
    {Src::Zero, Src::A0, Src::B0, Dst::R1},        // v  = a0*b0*S
    {Src::R0, Src::R1, Src::RomK2, Dst::C0},       // c0 = p + v*S^-2*S = p + a0*b0
    {Src::Zero, Src::A0, Src::B1, Dst::R0},        // u  = a0*b1*S
    {Src::R0, Src::A1, Src::B0, Dst::R0},          // w  = (a0*b1 + a1*b0)*S
    {Src::Zero, Src::R0, Src::RomK2, Dst::C1},     // c1 = w*S^-2*S = a0*b1 + a1*b0
};

}  // namespace detail

inline const std::vector<MicroOp>& basemul_program(Algo algo) {
  return algo_unit_scale(algo) ? detail::PROG_S1 : detail::PROG_SX;
}

inline Pair hw_basemul_pair(Algo algo, uint16_t a0, uint16_t a1, uint16_t b0, uint16_t b1, int pair,
                     std::vector<BasemulTraceRec>* trace) {
  if (pair < 0 || pair >= 128) throw std::invalid_argument("pair");
  uint16_t r[2] = {0, 0};
  uint16_t c[2] = {0, 0};
  int c_writes[2] = {0, 0};
  auto read = [&](Src s) -> uint16_t {
    switch (s) {
      case Src::Zero: return 0;
      case Src::A0: return a0;
      case Src::A1: return a1;
      case Src::B0: return b0;
      case Src::B1: return b1;
      case Src::R0: return r[0];
      case Src::R1: return r[1];
      case Src::RomGamma: return gamma_rom(algo)[pair];
      case Src::RomK2: return k2_const(algo);
    }
    throw std::logic_error("src");
  };
  const std::vector<MicroOp>& prog = basemul_program(algo);
  for (size_t i = 0; i < prog.size(); ++i) {
    const MicroOp& u = prog[i];
    const uint16_t a = read(u.a), b = read(u.b), z = read(u.z);
    const uint16_t x = bfu(algo, Mode::CT, a, b, z).x;
    switch (u.dst) {
      case Dst::R0: r[0] = x; break;
      case Dst::R1: r[1] = x; break;
      case Dst::C0: c[0] = x; ++c_writes[0]; break;
      case Dst::C1: c[1] = x; ++c_writes[1]; break;
    }
    if (trace) trace->push_back({pair, int(i), u, a, b, z, x});
  }
  if (c_writes[0] != 1 || c_writes[1] != 1)
    throw std::logic_error("basemul program must write C0 and C1 exactly once");
  return {c[0], c[1]};
}

inline int hw_basemul(Algo algo, Banks& m, std::vector<BasemulTraceRec>* trace) {
  for (int i = 0; i < 128; ++i) {
    // Operand latch: one read cycle on each bank (two read ports per bank).
    const uint16_t a0 = m.bank[0][2 * i], a1 = m.bank[0][2 * i + 1];
    const uint16_t b0 = m.bank[1][2 * i], b1 = m.bank[1][2 * i + 1];
    const Pair p = hw_basemul_pair(algo, a0, a1, b0, b1, i, trace);
    m.bank[0][2 * i] = p.c0;
    m.bank[0][2 * i + 1] = p.c1;
  }
  return 0;
}

inline Poly hw_basemul_poly(Algo algo, const Poly& a, const Poly& b,
                     std::vector<BasemulTraceRec>* trace) {
  Banks m{};
  m.bank[0] = a;
  m.bank[1] = b;
  return m.bank[hw_basemul(algo, m, trace)];
}

inline void dump_basemul_trace(std::FILE* f, const std::vector<BasemulTraceRec>& tr) {
  std::fprintf(f,
               "// pair op a_src b_src z_src dst a b z x (decimal pair/op, hex data); "
               "every op is bfu CT, x output only; C0 -> bank0[2*pair], C1 -> bank0[2*pair+1]; "
               "GAMMA = gamma ROM[pair]\n");
  for (const auto& r : tr)
    std::fprintf(f, "%d %d %s %s %s %s %03x %03x %03x %03x\n", r.pair, r.op, src_name(r.u.a),
                 src_name(r.u.b), src_name(r.u.z), dst_name(r.u.dst), r.a, r.b, r.z, r.x);
}

}  // namespace hw
}  // namespace mlkem

#endif  // MLKEM_HW_IMPL_H
