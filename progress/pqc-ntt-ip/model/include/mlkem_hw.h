// Hardware-structure golden model of pqc-ntt-ip v1 (docs/spec/arch.md).
//
// This layer models the fixed architecture bit-accurately:
//   * bfu: one unified butterfly (CT / GS with built-in halving), parameterized
//     by the reduction algorithm ALGO. Built only from mul12x12, the reduction
//     functions, mod_add_hw, mod_sub_hw and mod_half (1:1 with the RTL).
//   * per-ALGO ROMs: zeta ROM (pre-scaled by S^-1), gamma ROM (S^-2 when
//     S != 1) and the constant K2 = S^-2.
//   * hardware-schedule NTT / INTT on two ping-pong banks, using only the bfu
//     and the ROMs (no final 1/128 pass: GS halves both outputs per layer).
//   * basemul as a micro-op program of bfu CT operations (x output only).
// The canonical functions in mlkem_ntt.h are the oracle for all of these.
#ifndef MLKEM_HW_H
#define MLKEM_HW_H

#include <cstdint>
#include <cstdio>
#include <vector>

#include "mlkem_modarith.h"
#include "mlkem_ntt.h"
#include "mlkem_params.h"

namespace mlkem {
namespace hw {

// ---------------------------------------------------------------------------
// ALGO and mode encodings (also used by the DPI-C wrapper and the RTL)
// ---------------------------------------------------------------------------
// Note: this encoding is the arch.md order and differs from MulKind.
enum class Algo : int { Barrett = 0, Mont12 = 1, ShiftAdd = 2, K2Red = 3 };
constexpr int NUM_ALGOS = 4;
constexpr Algo ALL_ALGOS[NUM_ALGOS] = {Algo::Barrett, Algo::Mont12, Algo::ShiftAdd, Algo::K2Red};
inline bool algo_valid(int a) { return a >= 0 && a < NUM_ALGOS; }
const char* algo_name(Algo a);

enum class Mode : int { CT = 0, GS = 1 };

// Multiplier scale S: mul(b, z) = b * z * S mod q.
//   BARRETT, SHIFTADD: 1   MONT12: 2^-12   K2RED: 169
uint16_t algo_scale(Algo a);      // S mod q
uint16_t algo_scale_inv(Algo a);  // S^-1 mod q
uint16_t algo_scale_inv2(Algo a); // S^-2 mod q
inline bool algo_unit_scale(Algo a) { return a == Algo::Barrett || a == Algo::ShiftAdd; }

// ---------------------------------------------------------------------------
// bfu
// ---------------------------------------------------------------------------
// bfu_mul: in b, z in [0, q). out b * z * S mod q in [0, q).
// One 12b x 12b multiplier (mul12x12) followed by the ALGO reduction.
uint16_t bfu_mul(Algo algo, uint16_t b, uint16_t z);

// bfu: in a, b, z in [0, q). out x, y in [0, q).
//   CT: x = a + mul(b, z)            y = a - mul(b, z)
//   GS: x = half(a + b)              y = half(mul(b - a, z))
// GS uses (b - a) as in FIPS 203 Algorithm 10 line 10, see the comment in
// README for the difference from the arch.md text "(a - b)" (mlkem_hw_impl.h, bfu).
struct BfuOut {
  uint16_t x;
  uint16_t y;
};
BfuOut bfu(Algo algo, Mode mode, uint16_t a, uint16_t b, uint16_t z);

// ---------------------------------------------------------------------------
// ROMs
// ---------------------------------------------------------------------------
//   zeta_rom(a)[i]  = zeta_i * S^-1 mod q          (i = 0..127, ROM address = zeta index)
//   gamma_rom(a)[i] = gamma_i              if S = 1
//                     gamma_i * S^-2 mod q if S != 1 (i = 0..127, address = pair index)
//   k2_const(a)     = S^-2 mod q (1 when S = 1, not used by the S = 1 program)
enum class RomKind : int { Zeta = 0, Gamma = 1, K2 = 2 };
const Table128& zeta_rom(Algo a);
const Table128& gamma_rom(Algo a);
uint16_t k2_const(Algo a);
// Generic lookup. K2 has the single index 0. Returns -1 when out of range.
int rom_read(Algo a, RomKind kind, int index);
// $readmemh dump: one 3-digit hex value per line (128 lines, 1 line for K2).
void dump_rom_hex(std::FILE* f, Algo a, RomKind kind);

// ---------------------------------------------------------------------------
// NTT / INTT schedule and ping-pong memory
// ---------------------------------------------------------------------------
// Two banks of 256 x 12b. NTT and INTT read every address of the source bank
// once per layer and write every address of the other bank once per layer;
// source and destination swap after each layer. After 7 layers the result is
// in bank (in_bank ^ 1).
struct Banks {
  Poly bank[2];
};

// One step of the address schedule (data independent). 7 * 128 steps.
//   NTT : FIPS 203 Alg. 9 order, len = 128 .. 2, zeta address 1 .. 127 increasing
//   INTT: FIPS 203 Alg. 10 order, len = 2 .. 128, zeta address 127 .. 1 decreasing
struct SchedStep {
  int layer;      // 0..6 in execution order
  int step;       // 0..127 within the layer
  int len;        // butterfly distance
  int addr0;      // read/write address of the "a" operand (j)
  int addr1;      // read/write address of the "b" operand (j + len)
  int zeta_addr;  // zeta ROM address
  Mode mode;      // CT for NTT, GS for INTT
};
constexpr int SCHED_STEPS = 7 * 128;
const std::vector<SchedStep>& transform_schedule(Mode mode);

// One bfu call of a transform as executed on the banks.
struct BfuTraceRec {
  SchedStep s;
  int rd_bank, wr_bank;
  uint16_t a, b, z;  // bfu inputs (z is the ROM value)
  uint16_t x, y;     // bfu outputs; x -> wr_bank[addr0], y -> wr_bank[addr1]
};

// Run the transform on m, starting from bank in_bank. Returns the result bank.
// Throws std::logic_error if a layer does not write every address exactly once.
int hw_ntt(Algo algo, Banks& m, int in_bank, std::vector<BfuTraceRec>* trace = nullptr);
int hw_intt(Algo algo, Banks& m, int in_bank, std::vector<BfuTraceRec>* trace = nullptr);
// Convenience: load f in bank 0, run, return the result bank (bank 1).
Poly hw_ntt_poly(Algo algo, const Poly& f, std::vector<BfuTraceRec>* trace = nullptr);
Poly hw_intt_poly(Algo algo, const Poly& f_hat, std::vector<BfuTraceRec>* trace = nullptr);
// One line per bfu call (see the header line written by the function).
void dump_bfu_trace(std::FILE* f, const std::vector<BfuTraceRec>& tr);

// ---------------------------------------------------------------------------
// basemul micro-op program
// ---------------------------------------------------------------------------
// Per coefficient pair i the controller latches a0 = bank0[2i], a1 = bank0[2i+1],
// b0 = bank1[2i], b1 = bank1[2i+1] into operand registers, then issues the
// program. Each op is bfu(CT, a, b, z).x. Destinations R0/R1 are temporary
// registers; C0/C1 write bank0[2i] / bank0[2i+1]. Operands are latched, so
// writing C0 before the last read of a0 is not a hazard.
enum class Src : int { Zero = 0, A0, A1, B0, B1, R0, R1, RomGamma, RomK2 };
enum class Dst : int { R0 = 0, R1, C0, C1 };
const char* src_name(Src s);
const char* dst_name(Dst d);

struct MicroOp {
  Src a, b, z;
  Dst dst;
};
// 5 ops when S = 1, 7 ops when S != 1.
const std::vector<MicroOp>& basemul_program(Algo algo);

struct BasemulTraceRec {
  int pair;  // 0..127 (also the gamma ROM address)
  int op;    // index in the program
  MicroOp u;
  uint16_t a, b, z;  // values fed to the bfu
  uint16_t x;        // bfu x output written to u.dst
};

struct Pair {
  uint16_t c0, c1;
};
// One coefficient pair (gamma ROM address = pair).
Pair hw_basemul_pair(Algo algo, uint16_t a0, uint16_t a1, uint16_t b0, uint16_t b1, int pair,
                     std::vector<BasemulTraceRec>* trace = nullptr);
// a in bank 0, b in bank 1, result in bank 0. Returns the result bank (0).
int hw_basemul(Algo algo, Banks& m, std::vector<BasemulTraceRec>* trace = nullptr);
Poly hw_basemul_poly(Algo algo, const Poly& a, const Poly& b,
                     std::vector<BasemulTraceRec>* trace = nullptr);
void dump_basemul_trace(std::FILE* f, const std::vector<BasemulTraceRec>& tr);

}  // namespace hw
}  // namespace mlkem

#include "mlkem_hw_impl.h"

#endif  // MLKEM_HW_H
