# Build the ACVP harness against the pq-crystals/kyber ref sources.
# Shared server: run with -j2 at most. Objects go to $(BUILD), never into the
# downloaded source tree.
#   make -C data/harness          build all three parameter sets
#   make -C data/harness run      run ACVP + dump raw intermediates
#   make -C data/harness golden   build golden_check against model/ (read only)
#   make -C data/harness clean

DATA     := $(abspath ..)
KYBER    ?= $(DATA)/third_party/kyber-3edd5af59919/ref
BUILD    ?= $(DATA)/build
MODEL    ?= $(abspath $(DATA)/../model)
CC       := gcc
CXX      := g++
CXXFLAGS := -std=c++17 -O2 -Wall -Wextra -Wpedantic
CFLAGS   := -std=gnu99 -O2 -Wall -Wextra -Wpedantic
KSRC     := kem.c indcpa.c polyvec.c poly.c ntt.c cbd.c reduce.c verify.c \
            fips202.c symmetric-shake.c randombytes.c

ns_2 := pqcrystals_kyber512_ref_
ns_3 := pqcrystals_kyber768_ref_
ns_4 := pqcrystals_kyber1024_ref_
wrap = -Wl,--wrap=$(ns_$(1))poly_ntt -Wl,--wrap=$(ns_$(1))poly_invntt_tomont \
       -Wl,--wrap=$(ns_$(1))poly_basemul_montgomery

.PHONY: all run golden clean
all: $(BUILD)/acvp_harness_512 $(BUILD)/acvp_harness_768 $(BUILD)/acvp_harness_1024

define harness_rule
$(BUILD)/acvp_harness_$(2): acvp_harness.c $(addprefix $(KYBER)/,$(KSRC))
	mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -DKYBER_K=$(1) -I$(KYBER) acvp_harness.c \
	  $(addprefix $(KYBER)/,$(KSRC)) $(call wrap,$(1)) -o $$@
endef
$(eval $(call harness_rule,2,512))
$(eval $(call harness_rule,3,768))
$(eval $(call harness_rule,4,1024))

run: all
	for p in 512 768 1024; do \
	  $(BUILD)/acvp_harness_$$p $(BUILD)/acvp_cases_$$p.txt $(BUILD)/raw_dump_$$p.txt \
	    > $(BUILD)/acvp_result_$$p.log || exit 1; \
	  grep -E '^(KIND|SUMMARY)' $(BUILD)/acvp_result_$$p.log; \
	done

# Golden model sources are compiled from model/ in place; nothing is written there.
golden: $(BUILD)/golden_check
$(BUILD)/golden_check: golden_check.cpp $(MODEL)/src/mlkem_ntt.cpp $(MODEL)/src/mlkem_schoolbook.cpp \
                       $(wildcard $(MODEL)/include/*.h)
	mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) -I$(MODEL)/include golden_check.cpp $(MODEL)/src/mlkem_ntt.cpp \
	  $(MODEL)/src/mlkem_schoolbook.cpp -o $@

clean:
	rm -f $(BUILD)/acvp_harness_* $(BUILD)/raw_dump_* $(BUILD)/acvp_result_* $(BUILD)/golden_check
