// Trace dump for the NTT schedule viewer (docs/viewer).
//
// Uses only the public API of the golden model (model/include). Nothing in
// model/ is modified. For each viewer input set and each ALGO it writes:
//   <out>/trace_{ntt,intt,basemul}_<input>_<algo>.txt
//       bfu / micro-op trace in the model's own format (hw::dump_bfu_trace,
//       hw::dump_basemul_trace), so the random input can be diffed against
//       model/vectors/hw_*_trace_<algo>.txt.
//   <out>/aux.json
//       ROM contents and scale constants, basemul programs, the bfu internal
//       values of every call (bfu_mul / mod_add_hw / mod_sub_hw as used by
//       hw::bfu), the input polynomials, the reference outputs (ntt, intt,
//       multiply_ntts) and the expected bank state after every layer.
//
// usage: dump_viewer_trace --vec DIR --out DIR --random-case C --simple-tr-case C
//                          --simple-mul-a-case C --simple-mul-b-case C
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

#include "mlkem_hw.h"
#include "mlkem_modarith.h"
#include "mlkem_ntt.h"

using namespace mlkem;
using namespace mlkem::hw;

namespace {

Poly read_case(const std::string& path, int c) {
  FILE* f = std::fopen(path.c_str(), "r");
  if (!f) throw std::runtime_error("cannot open " + path);
  Poly p{};
  char line[64];
  int ln = 0;
  int got = 0;
  while (std::fgets(line, sizeof line, f)) {
    if (ln >= c * 256 && ln < c * 256 + 256) {
      unsigned v = 0;
      if (std::sscanf(line, "%x", &v) != 1 || v >= Q) throw std::runtime_error("bad line in " + path);
      p[ln - c * 256] = uint16_t(v);
      ++got;
    }
    ++ln;
  }
  std::fclose(f);
  if (got != 256) throw std::runtime_error("case out of range in " + path);
  return p;
}

void json_arr(FILE* f, const uint16_t* v, size_t n) {
  std::fputc('[', f);
  for (size_t i = 0; i < n; ++i) std::fprintf(f, "%s%u", i ? "," : "", unsigned(v[i]));
  std::fputc(']', f);
}
void json_poly(FILE* f, const Poly& p) { json_arr(f, p.data(), p.size()); }
void json_vec(FILE* f, const std::vector<uint16_t>& v) { json_arr(f, v.data(), v.size()); }

void require(bool c, const char* what) {
  if (!c) {
    std::fprintf(stderr, "internal check failed: %s\n", what);
    std::exit(1);
  }
}

FILE* open_w(const std::string& p) {
  FILE* f = std::fopen(p.c_str(), "w");
  if (!f) {
    std::fprintf(stderr, "cannot write %s\n", p.c_str());
    std::exit(1);
  }
  return f;
}

struct InputSet {
  std::string name;
  Poly f;      // NTT and INTT input (bank 0)
  Poly ma, mb; // basemul a (bank 0), b (bank 1)
};

// Expected bank state after every layer, from the reference transforms.
// NTT: hw layer L == reference layer L.
// INTT: hw layer L == reference layer L * 2^-(L+1) (GS halves per layer).
std::vector<Poly> expected_layers(Mode mode, const Poly& in) {
  std::vector<Poly> layers;
  NttObserver obs{nullptr, &layers};
  if (mode == Mode::CT) {
    ntt(in, MulKind::Ref, &obs);
    return layers;
  }
  intt(in, MulKind::Ref, &obs);
  layers.resize(7);  // drop the final *3303 entry
  uint16_t h = 1;
  for (int L = 0; L < 7; ++L) {
    h = mod_mul_ref(h, uint16_t(Q_INV2));
    for (auto& c : layers[L]) c = mod_mul_ref(c, h);
  }
  return layers;
}

}  // namespace

int main(int argc, char** argv) {
  std::string vec, out;
  int rc = -1, stc = -1, sac = -1, sbc = -1;
  for (int i = 1; i + 1 < argc; i += 2) {
    const std::string k = argv[i];
    const char* v = argv[i + 1];
    if (k == "--vec") vec = v;
    else if (k == "--out") out = v;
    else if (k == "--random-case") rc = std::atoi(v);
    else if (k == "--simple-tr-case") stc = std::atoi(v);
    else if (k == "--simple-mul-a-case") sac = std::atoi(v);
    else if (k == "--simple-mul-b-case") sbc = std::atoi(v);
    else {
      std::fprintf(stderr, "unknown option %s\n", k.c_str());
      return 2;
    }
  }
  if (vec.empty() || out.empty() || rc < 0 || stc < 0 || sac < 0 || sbc < 0) {
    std::fprintf(stderr,
                 "usage: %s --vec DIR --out DIR --random-case C --simple-tr-case C "
                 "--simple-mul-a-case C --simple-mul-b-case C\n",
                 argv[0]);
    return 2;
  }

  std::vector<InputSet> inputs;
  inputs.push_back({"random", read_case(vec + "/ntt_in.hex", rc), read_case(vec + "/mul_a.hex", rc),
                    read_case(vec + "/mul_b.hex", rc)});
  inputs.push_back({"simple", read_case(vec + "/ntt_in.hex", stc),
                    read_case(vec + "/ntt_in.hex", sac), read_case(vec + "/ntt_in.hex", sbc)});
  // intt_in.hex holds the same polynomial as ntt_in.hex for every case.
  require(read_case(vec + "/intt_in.hex", rc) == inputs[0].f, "intt_in == ntt_in");

  FILE* j = open_w(out + "/aux.json");
  std::fprintf(j, "{\n\"q\":%u,\n\"zeta_table\":", unsigned(Q));
  json_arr(j, zeta_table().data(), 128);
  std::fprintf(j, ",\n\"gamma_table\":");
  json_arr(j, gamma_table().data(), 128);
  std::fprintf(j, ",\n\"bitrev7\":[");
  for (uint32_t i = 0; i < 128; ++i) std::fprintf(j, "%s%u", i ? "," : "", bitrev7(i));
  std::fprintf(j, "],\n\"algos\":[\n");
  for (int ai = 0; ai < NUM_ALGOS; ++ai) {
    const Algo al = ALL_ALGOS[ai];
    std::fprintf(j, "%s{\"name\":\"%s\",\"S\":%u,\"S_inv\":%u,\"S_inv2\":%u,\"K2\":%u,\"zeta_rom\":",
                 ai ? ",\n" : "", algo_name(al), algo_scale(al), algo_scale_inv(al),
                 algo_scale_inv2(al), k2_const(al));
    json_arr(j, zeta_rom(al).data(), 128);
    std::fprintf(j, ",\"gamma_rom\":");
    json_arr(j, gamma_rom(al).data(), 128);
    std::fprintf(j, ",\"program\":[");
    const auto& pr = basemul_program(al);
    for (size_t k = 0; k < pr.size(); ++k)
      std::fprintf(j, "%s[\"%s\",\"%s\",\"%s\",\"%s\"]", k ? "," : "", src_name(pr[k].a),
                   src_name(pr[k].b), src_name(pr[k].z), dst_name(pr[k].dst));
    std::fprintf(j, "]}");
  }
  std::fprintf(j, "\n],\n\"inputs\":{\n");

  for (size_t ii = 0; ii < inputs.size(); ++ii) {
    const InputSet& in = inputs[ii];
    std::fprintf(j, "%s\"%s\":{\"f\":", ii ? ",\n" : "", in.name.c_str());
    json_poly(j, in.f);
    std::fprintf(j, ",\"mul_a\":");
    json_poly(j, in.ma);
    std::fprintf(j, ",\"mul_b\":");
    json_poly(j, in.mb);
    const Poly ref_ntt = ntt(in.f), ref_intt = intt(in.f), ref_mul = multiply_ntts(in.ma, in.mb);
    std::fprintf(j, ",\n \"ref_ntt\":");
    json_poly(j, ref_ntt);
    std::fprintf(j, ",\n \"ref_intt\":");
    json_poly(j, ref_intt);
    std::fprintf(j, ",\n \"ref_basemul\":");
    json_poly(j, ref_mul);
    for (int m = 0; m < 2; ++m) {
      const auto lay = expected_layers(m ? Mode::GS : Mode::CT, in.f);
      std::fprintf(j, ",\n \"layers_%s\":[", m ? "intt" : "ntt");
      for (size_t L = 0; L < lay.size(); ++L) {
        if (L) std::fputc(',', j);
        json_poly(j, lay[L]);
      }
      std::fputc(']', j);
    }
    std::fprintf(j, ",\n \"internals\":{");
    for (int ai = 0; ai < NUM_ALGOS; ++ai) {
      const Algo al = ALL_ALGOS[ai];
      const std::string an = algo_name(al);
      // NTT and INTT.
      std::vector<uint16_t> t_ntt, s_intt, d_intt, m_intt, t_mul;
      for (int m = 0; m < 2; ++m) {
        std::vector<BfuTraceRec> tr;
        const Poly res = m ? hw_intt_poly(al, in.f, &tr) : hw_ntt_poly(al, in.f, &tr);
        require(res == (m ? ref_intt : ref_ntt), "hw transform == reference");
        require(tr.size() == size_t(SCHED_STEPS), "transform trace length");
        FILE* f = open_w(out + "/trace_" + (m ? "intt_" : "ntt_") + in.name + "_" + an + ".txt");
        dump_bfu_trace(f, tr);
        std::fclose(f);
        for (const auto& r : tr) {
          if (m == 0) {
            // CT internals exactly as in hw::bfu: t = mul(b, z), x = add(a, t), y = sub(a, t).
            const uint16_t t = bfu_mul(al, r.b, r.z);
            require(mod_add_hw(r.a, t) == r.x && mod_sub_hw(r.a, t) == r.y, "CT internals");
            t_ntt.push_back(t);
          } else {
            // GS: s = add(a, b), d = sub(b, a), x = half(s), mm = mul(d, z), y = half(mm).
            const uint16_t s = mod_add_hw(r.a, r.b), d = mod_sub_hw(r.b, r.a);
            const uint16_t mm = bfu_mul(al, d, r.z);
            require(mod_half(s) == r.x && mod_half(mm) == r.y, "GS internals");
            s_intt.push_back(s);
            d_intt.push_back(d);
            m_intt.push_back(mm);
          }
        }
      }
      // basemul.
      std::vector<BasemulTraceRec> bt;
      const Poly res = hw_basemul_poly(al, in.ma, in.mb, &bt);
      require(res == ref_mul, "hw basemul == reference");
      FILE* f = open_w(out + "/trace_basemul_" + in.name + "_" + an + ".txt");
      dump_basemul_trace(f, bt);
      std::fclose(f);
      for (const auto& r : bt) {
        const uint16_t t = bfu_mul(al, r.b, r.z);
        require(mod_add_hw(r.a, t) == r.x, "basemul internals");
        t_mul.push_back(t);
      }
      std::fprintf(j, "%s\n  \"%s\":{\"ntt_t\":", ai ? "," : "", an.c_str());
      json_vec(j, t_ntt);
      std::fprintf(j, ",\"intt_s\":");
      json_vec(j, s_intt);
      std::fprintf(j, ",\"intt_d\":");
      json_vec(j, d_intt);
      std::fprintf(j, ",\"intt_m\":");
      json_vec(j, m_intt);
      std::fprintf(j, ",\"basemul_t\":");
      json_vec(j, t_mul);
      std::fprintf(j, "}");
    }
    std::fprintf(j, "}}");
  }
  std::fprintf(j, "\n}\n}\n");
  std::fclose(j);
  std::printf("dump_viewer_trace: wrote %s (random case %d, simple cases %d / %d,%d)\n",
              out.c_str(), rc, stc, sac, sbc);
  return 0;
}
