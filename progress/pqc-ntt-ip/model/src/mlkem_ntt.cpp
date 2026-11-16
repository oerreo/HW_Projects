// ML-KEM NTT golden model implementation (FIPS 203 Algorithms 9-12).
#include "mlkem_ntt.h"

#include <stdexcept>

namespace mlkem {

uint32_t bitrev7(uint32_t i) {
  uint32_t r = 0;
  for (int b = 0; b < 7; ++b) r |= ((i >> b) & 1u) << (6 - b);
  return r;
}

namespace {

// 17^e mod q by repeated multiplication from a table of all 256 powers.
std::array<uint16_t, 256> make_powers() {
  std::array<uint16_t, 256> p{};
  uint32_t v = 1;
  for (unsigned e = 0; e < 256; ++e) {
    p[e] = uint16_t(v);
    v = (v * ZETA) % Q;
  }
  if (v != 1) throw std::logic_error("17^256 != 1 mod q");
  return p;
}

Table128 make_zetas() {
  const auto p = make_powers();
  Table128 t{};
  for (uint32_t i = 0; i < 128; ++i) t[i] = p[bitrev7(i)];
  return t;
}

Table128 make_gammas() {
  const auto p = make_powers();
  Table128 t{};
  for (uint32_t i = 0; i < 128; ++i) t[i] = p[(2 * bitrev7(i) + 1) % 256];
  return t;
}

void check_kind_for_basemul(MulKind k) {
  if (k != MulKind::Ref && k != MulKind::Barrett && k != MulKind::ShiftAdd)
    throw std::invalid_argument("basecase_multiply: MulKind needs pre-scaled operands");
}

uint16_t mul_plain(MulKind k, uint16_t a, uint16_t b) {
  switch (k) {
    case MulKind::Barrett: return mod_mul_barrett(a, b);
    case MulKind::ShiftAdd: return mod_mul_shiftadd(a, b);
    default: return mod_mul_ref(a, b);
  }
}

}  // namespace

const Table128& zeta_table() {
  static const Table128 t = make_zetas();
  return t;
}

const Table128& gamma_table() {
  static const Table128 t = make_gammas();
  return t;
}

const Table128& twiddle_rom(MulKind k) {
  static const auto roms = [] {
    std::array<Table128, NUM_MUL_KINDS> r{};
    for (int kk = 0; kk < NUM_MUL_KINDS; ++kk)
      for (int i = 0; i < 128; ++i)
        r[kk][i] = twiddle_prescale(MulKind(kk), zeta_table()[i]);
    return r;
  }();
  return roms.at(int(k));
}

uint16_t intt_scale_rom(MulKind k) { return twiddle_prescale(k, uint16_t(N128_INV)); }

BflyOut ct_butterfly(MulKind k, uint16_t a, uint16_t b, uint16_t w_rom) {
  const uint16_t t = mul_twiddle(k, b, w_rom);
  return {mod_add_hw(a, t), mod_sub_hw(a, t)};
}

BflyOut gs_butterfly(MulKind k, uint16_t a, uint16_t b, uint16_t w_rom) {
  const uint16_t s = mod_add_hw(a, b);
  const uint16_t d = mod_sub_hw(b, a);
  return {s, mul_twiddle(k, d, w_rom)};
}

Poly ntt(const Poly& f, MulKind k, const NttObserver* obs) {
  Poly r = f;
  const Table128& rom = twiddle_rom(k);
  int i = 1;
  int layer = 0;
  for (int len = 128; len >= 2; len /= 2, ++layer) {
    for (int start = 0; start < 256; start += 2 * len) {
      const int zi = i++;
      for (int j = start; j < start + len; ++j) {
        const BflyOut o = ct_butterfly(k, r[j], r[j + len], rom[zi]);
        if (obs && obs->trace)
          obs->trace->push_back({layer, len, zi, j, r[j], r[j + len], zeta_table()[zi], rom[zi],
                                 o.a, o.b});
        r[j] = o.a;
        r[j + len] = o.b;
      }
    }
    if (obs && obs->layer_out) obs->layer_out->push_back(r);
  }
  return r;
}

Poly intt(const Poly& f_hat, MulKind k, const NttObserver* obs) {
  Poly r = f_hat;
  const Table128& rom = twiddle_rom(k);
  int i = 127;
  int layer = 0;
  for (int len = 2; len <= 128; len *= 2, ++layer) {
    for (int start = 0; start < 256; start += 2 * len) {
      const int zi = i--;
      for (int j = start; j < start + len; ++j) {
        const BflyOut o = gs_butterfly(k, r[j], r[j + len], rom[zi]);
        if (obs && obs->trace)
          obs->trace->push_back({layer, len, zi, j, r[j], r[j + len], zeta_table()[zi], rom[zi],
                                 o.a, o.b});
        r[j] = o.a;
        r[j + len] = o.b;
      }
    }
    if (obs && obs->layer_out) obs->layer_out->push_back(r);
  }
  const uint16_t s = intt_scale_rom(k);
  for (auto& c : r) c = mul_twiddle(k, c, s);
  if (obs && obs->layer_out) obs->layer_out->push_back(r);
  return r;
}

BflyOut basecase_multiply(uint16_t a0, uint16_t a1, uint16_t b0, uint16_t b1, uint16_t gamma,
                          MulKind k) {
  check_kind_for_basemul(k);
  const uint16_t a1b1 = mul_plain(k, a1, b1);
  const uint16_t c0 = mod_add_hw(mul_plain(k, a0, b0), mul_plain(k, a1b1, gamma));
  const uint16_t c1 = mod_add_hw(mul_plain(k, a0, b1), mul_plain(k, a1, b0));
  return {c0, c1};
}

Poly multiply_ntts(const Poly& f_hat, const Poly& g_hat, MulKind k) {
  check_kind_for_basemul(k);
  Poly h{};
  const Table128& g = gamma_table();
  for (int i = 0; i < 128; ++i) {
    const BflyOut c =
        basecase_multiply(f_hat[2 * i], f_hat[2 * i + 1], g_hat[2 * i], g_hat[2 * i + 1], g[i], k);
    h[2 * i] = c.a;
    h[2 * i + 1] = c.b;
  }
  return h;
}

}  // namespace mlkem
