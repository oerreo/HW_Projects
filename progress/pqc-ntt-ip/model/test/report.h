// Check counters for the self test.
#ifndef MLKEM_TEST_REPORT_H
#define MLKEM_TEST_REPORT_H

#include <cstdint>
#include <cstdio>
#include <string>
#include <deque>

struct CheckItem {
  std::string group;
  std::string name;
  uint64_t checks = 0;
  uint64_t mismatches = 0;
  bool run = true;
  std::string note;
};

class Report {
 public:
  CheckItem& add(const std::string& group, const std::string& name) {
    items_.push_back({group, name, 0, 0, true, ""});
    return items_.back();
  }
  void not_run(const std::string& group, const std::string& name, const std::string& why) {
    items_.push_back({group, name, 0, 0, false, why});
  }
  // Records one comparison; prints the first few mismatches of an item.
  static void expect(CheckItem& it, bool ok, const char* fmt_detail = nullptr, long long x = 0,
                     long long got = 0, long long exp = 0) {
    ++it.checks;
    if (!ok) {
      if (it.mismatches < 5 && fmt_detail)
        std::printf("  MISMATCH [%s/%s] %s x=%lld got=%lld exp=%lld\n", it.group.c_str(),
                    it.name.c_str(), fmt_detail, x, got, exp);
      ++it.mismatches;
    }
  }
  bool print_summary() const {
    std::printf("\n%-10s %-44s %14s %10s  %s\n", "group", "item", "checks", "mismatch", "result");
    bool pass = true;
    for (const auto& it : items_) {
      if (!it.run) {
        std::printf("%-10s %-44s %14s %10s  NOT RUN (%s)\n", it.group.c_str(), it.name.c_str(),
                    "-", "-", it.note.c_str());
        continue;
      }
      const bool ok = it.mismatches == 0 && it.checks > 0;
      pass = pass && ok;
      std::printf("%-10s %-44s %14llu %10llu  %s\n", it.group.c_str(), it.name.c_str(),
                  (unsigned long long)it.checks, (unsigned long long)it.mismatches,
                  ok ? "ok" : "FAIL");
    }
    std::printf("\nOVERALL: %s\n", pass ? "PASS" : "FAIL");
    return pass;
  }

 private:
  std::deque<CheckItem> items_;  // deque: references from add() stay valid
};

void run_pqcrystals_xcheck(Report& rep, uint64_t seed);
void run_hw_tests(Report& rep, uint64_t seed, const std::string& ext_dir);

#endif  // MLKEM_TEST_REPORT_H
