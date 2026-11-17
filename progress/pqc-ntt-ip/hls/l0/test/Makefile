# C-level exhaustive test of the Catapult HLS sources against the golden model.
#
#   make test      build and run (prints per-item counts and OVERALL: PASS/FAIL)
#   make build     build only
#   make clean
#
# ac_int.h comes from the Catapult installation: source scripts/env.sh hls
# first (sets MGC_HOME), or pass AC_INC=<dir containing ac_int.h>.
# The binary and log go to hls/l0/run/ctest/ (not committed).

CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -Wno-unknown-pragmas
# Catapult's g++ (on PATH after env.sh hls) is newer than the system libstdc++.
LDFLAGS  ?= -static-libstdc++ -static-libgcc
# MGC_HOME may be a non-exported shell variable; fall back to the catapult
# executable on PATH (<MGC_HOME>/bin/catapult).
CAT_HOME := $(or $(MGC_HOME),$(shell p=$$(command -v catapult) && dirname "$$(dirname "$$p")"))
AC_INC   ?= $(CAT_HOME)/shared/include

HLS_DIR  := ..
MODEL_INC := ../../../model/include
BUILD    ?= ../run/ctest

SRCS := test_hls_c.cpp $(wildcard $(HLS_DIR)/src/*.cpp)
HDRS := $(wildcard $(HLS_DIR)/include/*.h) $(MODEL_INC)/mlkem_modarith.h $(MODEL_INC)/mlkem_params.h
BIN  := $(BUILD)/test_hls_c

.PHONY: test build clean check-ac

test: $(BIN)
	$(BIN) | tee $(BUILD)/test_hls_c.log
	@grep -q '^OVERALL: PASS' $(BUILD)/test_hls_c.log

build: $(BIN)

check-ac:
	@test -f $(AC_INC)/ac_int.h || { echo "ac_int.h not found in AC_INC='$(AC_INC)' (source scripts/env.sh hls)"; exit 2; }

$(BIN): $(SRCS) $(HDRS) Makefile | check-ac
	mkdir -p $(BUILD)
	$(CXX) $(CXXFLAGS) -I$(HLS_DIR)/include -I$(MODEL_INC) -isystem $(AC_INC) $(SRCS) $(LDFLAGS) -o $@

clean:
	rm -rf $(BUILD)
