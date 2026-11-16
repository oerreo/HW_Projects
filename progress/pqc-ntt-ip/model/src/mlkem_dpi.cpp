// C linkage wrapper of the golden model (see mlkem_dpi.h).
#include "mlkem_dpi.h"

#include "mlkem_hw.h"
#include "mlkem_ntt.h"

using namespace mlkem;

namespace {

bool valid_kind(int k) { return k >= 0 && k < NUM_MUL_KINDS; }

Poly to_poly(const int* p) {
  Poly r{};
  for (unsigned i = 0; i < N; ++i) r[i] = uint16_t(p[i]);
  return r;
}

void from_poly(const Poly& p, int* out) {
  for (unsigned i = 0; i < N; ++i) out[i] = p[i];
}

bool canon(int v) { return v >= 0 && v < int(Q); }

bool canon_poly(const int* p) {
  for (unsigned i = 0; i < N; ++i)
    if (!canon(p[i])) return false;
  return true;
}

bool in24(int x) { return x >= 0 && x < (1 << 24); }

}  // namespace

extern "C" {

int mlkem_dpi_mod_add(int a, int b) { return mod_add_hw(uint16_t(a), uint16_t(b)); }
int mlkem_dpi_mod_sub(int a, int b) { return mod_sub_hw(uint16_t(a), uint16_t(b)); }
int mlkem_dpi_mod_mul(int a, int b) { return mod_mul_ref(uint16_t(a), uint16_t(b)); }

int mlkem_dpi_reduce(int kind, int x) {
  if (x < 0) return -1;
  const uint32_t ux = uint32_t(x);
  switch (MulKind(kind)) {
    case MulKind::Ref: return mod_reduce_ref(ux);
    case MulKind::Barrett: return ux < (1u << 24) ? barrett_reduce(ux) : -1;
    case MulKind::ShiftAdd: return ux < (1u << 24) ? shiftadd_reduce(ux) : -1;
    case MulKind::Mont12: return ux < Q * (1u << 12) ? mont12_reduce(ux) : -1;
    case MulKind::Mont16: return ux < Q * (1u << 16) ? mont16_reduce(ux) : -1;
    case MulKind::K2Red: return ux < (1u << 24) ? k2red_reduce(ux) : -1;
  }
  return -1;
}

int mlkem_dpi_twiddle_prescale(int kind, int w) {
  return valid_kind(kind) ? twiddle_prescale(MulKind(kind), uint16_t(w)) : -1;
}

int mlkem_dpi_zeta(int i) { return (i >= 0 && i < 128) ? zeta_table()[i] : -1; }
int mlkem_dpi_gamma(int i) { return (i >= 0 && i < 128) ? gamma_table()[i] : -1; }

void mlkem_dpi_ct_butterfly(int kind, int a, int b, int zeta_rom, int* a_out, int* b_out) {
  const BflyOut o = ct_butterfly(MulKind(kind), uint16_t(a), uint16_t(b), uint16_t(zeta_rom));
  *a_out = o.a;
  *b_out = o.b;
}

void mlkem_dpi_gs_butterfly(int kind, int a, int b, int zeta_rom, int* a_out, int* b_out) {
  const BflyOut o = gs_butterfly(MulKind(kind), uint16_t(a), uint16_t(b), uint16_t(zeta_rom));
  *a_out = o.a;
  *b_out = o.b;
}

void mlkem_dpi_basecase_multiply(int a0, int a1, int b0, int b1, int gamma, int* c0, int* c1) {
  const BflyOut o = basecase_multiply(uint16_t(a0), uint16_t(a1), uint16_t(b0), uint16_t(b1),
                                      uint16_t(gamma));
  *c0 = o.a;
  *c1 = o.b;
}

void mlkem_dpi_ntt(const int* f, int* f_hat) { from_poly(ntt(to_poly(f)), f_hat); }
void mlkem_dpi_intt(const int* f_hat, int* f) { from_poly(intt(to_poly(f_hat)), f); }
void mlkem_dpi_multiply_ntts(const int* f_hat, const int* g_hat, int* h_hat) {
  from_poly(multiply_ntts(to_poly(f_hat), to_poly(g_hat)), h_hat);
}

// ---------------------------------------------------------------------------
// Hardware-structure model
// ---------------------------------------------------------------------------
int mlkem_dpi_barrett_reduce(int x) { return in24(x) ? barrett_reduce(uint32_t(x)) : -1; }
int mlkem_dpi_mont12_reduce(int x) {
  return (x >= 0 && uint32_t(x) < Q * (1u << 12)) ? mont12_reduce(uint32_t(x)) : -1;
}
int mlkem_dpi_shiftadd_reduce(int x) { return in24(x) ? shiftadd_reduce(uint32_t(x)) : -1; }
int mlkem_dpi_k2red_reduce(int x) { return in24(x) ? k2red_reduce(uint32_t(x)) : -1; }
int mlkem_dpi_mod_half(int x) { return canon(x) ? mod_half(uint16_t(x)) : -1; }

void mlkem_dpi_bfu(int algo, int mode, int a, int b, int z, int* x, int* y) {
  if (!hw::algo_valid(algo) || (mode != 0 && mode != 1) || !canon(a) || !canon(b) || !canon(z)) {
    *x = -1;
    *y = -1;
    return;
  }
  const hw::BfuOut o =
      hw::bfu(hw::Algo(algo), hw::Mode(mode), uint16_t(a), uint16_t(b), uint16_t(z));
  *x = o.x;
  *y = o.y;
}

int mlkem_dpi_algo_scale(int algo, int power) {
  if (!hw::algo_valid(algo)) return -1;
  switch (power) {
    case 1: return hw::algo_scale(hw::Algo(algo));
    case -1: return hw::algo_scale_inv(hw::Algo(algo));
    case -2: return hw::algo_scale_inv2(hw::Algo(algo));
  }
  return -1;
}

int mlkem_dpi_rom(int algo, int rom_kind, int index) {
  if (!hw::algo_valid(algo) || rom_kind < 0 || rom_kind > 2) return -1;
  return hw::rom_read(hw::Algo(algo), hw::RomKind(rom_kind), index);
}

int mlkem_dpi_hw_sched(int mode, int step, int* layer, int* len, int* addr0, int* addr1,
                       int* zeta_addr) {
  if ((mode != 0 && mode != 1) || step < 0 || step >= hw::SCHED_STEPS) return -1;
  const hw::SchedStep& s = hw::transform_schedule(hw::Mode(mode))[size_t(step)];
  *layer = s.layer;
  *len = s.len;
  *addr0 = s.addr0;
  *addr1 = s.addr1;
  *zeta_addr = s.zeta_addr;
  return 0;
}

int mlkem_dpi_basemul_nops(int algo) {
  return hw::algo_valid(algo) ? int(hw::basemul_program(hw::Algo(algo)).size()) : -1;
}

int mlkem_dpi_basemul_op(int algo, int idx, int* a_src, int* b_src, int* z_src, int* dst) {
  if (!hw::algo_valid(algo)) return -1;
  const auto& prog = hw::basemul_program(hw::Algo(algo));
  if (idx < 0 || size_t(idx) >= prog.size()) return -1;
  *a_src = int(prog[size_t(idx)].a);
  *b_src = int(prog[size_t(idx)].b);
  *z_src = int(prog[size_t(idx)].z);
  *dst = int(prog[size_t(idx)].dst);
  return 0;
}

int mlkem_dpi_hw_basemul_pair(int algo, int a0, int a1, int b0, int b1, int pair, int* c0,
                              int* c1) {
  if (!hw::algo_valid(algo) || !canon(a0) || !canon(a1) || !canon(b0) || !canon(b1) ||
      pair < 0 || pair >= 128)
    return -1;
  const hw::Pair p = hw::hw_basemul_pair(hw::Algo(algo), uint16_t(a0), uint16_t(a1),
                                         uint16_t(b0), uint16_t(b1), pair);
  *c0 = p.c0;
  *c1 = p.c1;
  return 0;
}

int mlkem_dpi_hw_ntt(int algo, const int* f, int* f_hat) {
  if (!hw::algo_valid(algo) || !canon_poly(f)) return -1;
  from_poly(hw::hw_ntt_poly(hw::Algo(algo), to_poly(f)), f_hat);
  return 0;
}

int mlkem_dpi_hw_intt(int algo, const int* f_hat, int* f) {
  if (!hw::algo_valid(algo) || !canon_poly(f_hat)) return -1;
  from_poly(hw::hw_intt_poly(hw::Algo(algo), to_poly(f_hat)), f);
  return 0;
}

int mlkem_dpi_hw_basemul(int algo, const int* f_hat, const int* g_hat, int* h_hat) {
  if (!hw::algo_valid(algo) || !canon_poly(f_hat) || !canon_poly(g_hat)) return -1;
  from_poly(hw::hw_basemul_poly(hw::Algo(algo), to_poly(f_hat), to_poly(g_hat)), h_hat);
  return 0;
}

}  // extern "C"
