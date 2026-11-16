// Check the C++ golden model (model/, read only) against the external
// polynomial vectors in data/vectors/ext.
//
// Build (from data/harness, objects go to data/build):
//   make golden
// Run:
//   ../build/golden_check ../vectors/ext
//
// For every MulKind the model supports, compares
//   mlkem::ntt(ntt_in[i])                         vs ntt_out[i]
//   mlkem::intt(intt_in[i])                       vs intt_out[i]
//   mlkem::multiply_ntts(basemul_a[i], basemul_b[i]) vs basemul_out[i]
// and prints compared/mismatch counts, then OVERALL PASS/FAIL.
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

#include "mlkem_ntt.h"

using mlkem::MulKind;
using mlkem::Poly;

namespace {

std::vector<Poly> read_hex(const std::string& path) {
  std::ifstream in(path);
  if (!in) {
    std::fprintf(stderr, "cannot open %s\n", path.c_str());
    std::exit(2);
  }
  std::vector<Poly> polys;
  std::string line;
  Poly p{};
  unsigned k = 0;
  while (std::getline(in, line)) {
    const unsigned long v = std::stoul(line, nullptr, 16);
    if (line.size() != 3 || v >= mlkem::Q) {
      std::fprintf(stderr, "%s: bad line '%s'\n", path.c_str(), line.c_str());
      std::exit(2);
    }
    p[k++] = static_cast<uint16_t>(v);
    if (k == mlkem::N) {
      polys.push_back(p);
      k = 0;
    }
  }
  if (k != 0) {
    std::fprintf(stderr, "%s: trailing partial polynomial\n", path.c_str());
    std::exit(2);
  }
  return polys;
}

struct Count {
  long polys = 0, bad_polys = 0, bad_coefs = 0;
};

void compare(Count& c, const Poly& got, const Poly& exp, const char* what, size_t idx) {
  ++c.polys;
  long bad = 0;
  for (unsigned j = 0; j < mlkem::N; ++j) {
    if (got[j] != exp[j]) {
      if (c.bad_coefs + bad == 0)
        std::printf("  first mismatch %s poly=%zu coef=%u model=%u ext=%u\n", what, idx, j,
                    got[j], exp[j]);
      ++bad;
    }
  }
  if (bad) {
    ++c.bad_polys;
    c.bad_coefs += bad;
  }
}

void report(const char* op, MulKind k, const Count& c, long& total_bad) {
  std::printf("%-8s kind=%-9s polys=%ld coefs=%ld mismatch_polys=%ld mismatch_coefs=%ld\n", op,
              mlkem::mul_kind_name(k), c.polys, c.polys * long(mlkem::N), c.bad_polys,
              c.bad_coefs);
  total_bad += c.bad_polys;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: %s <vector_dir>\n", argv[0]);
    return 2;
  }
  const std::string d = std::string(argv[1]) + "/";
  const auto ntt_in = read_hex(d + "ntt_in.hex"), ntt_out = read_hex(d + "ntt_out.hex");
  const auto intt_in = read_hex(d + "intt_in.hex"), intt_out = read_hex(d + "intt_out.hex");
  const auto bm_a = read_hex(d + "basemul_a.hex"), bm_b = read_hex(d + "basemul_b.hex");
  const auto bm_out = read_hex(d + "basemul_out.hex");
  if (ntt_in.size() != ntt_out.size() || intt_in.size() != intt_out.size() ||
      bm_a.size() != bm_out.size() || bm_b.size() != bm_out.size()) {
    std::fprintf(stderr, "input/output polynomial count mismatch\n");
    return 2;
  }

  long total_bad = 0;
  const MulKind all[] = {MulKind::Ref,   MulKind::Barrett, MulKind::ShiftAdd,
                         MulKind::Mont12, MulKind::Mont16, MulKind::K2Red};
  for (MulKind k : all) {
    Count c;
    for (size_t i = 0; i < ntt_in.size(); ++i) compare(c, mlkem::ntt(ntt_in[i], k), ntt_out[i], "ntt", i);
    report("ntt", k, c, total_bad);
  }
  for (MulKind k : all) {
    Count c;
    for (size_t i = 0; i < intt_in.size(); ++i)
      compare(c, mlkem::intt(intt_in[i], k), intt_out[i], "intt", i);
    report("intt", k, c, total_bad);
  }
  // multiply_ntts supports Ref, Barrett and ShiftAdd only (model/README.md).
  for (MulKind k : {MulKind::Ref, MulKind::Barrett, MulKind::ShiftAdd}) {
    Count c;
    for (size_t i = 0; i < bm_a.size(); ++i)
      compare(c, mlkem::multiply_ntts(bm_a[i], bm_b[i], k), bm_out[i], "basemul", i);
    report("basemul", k, c, total_bad);
  }
  std::printf("OVERALL %s\n", total_bad == 0 ? "PASS" : "FAIL");
  return total_bad == 0 ? 0 : 1;
}
