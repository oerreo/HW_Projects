# ML-KEM golden model. Shared server: use at most -j2.
#   make test       build with width assertions and run the self test
#   make test-hw    only the hardware-structure items of the self test
#   make vectors    build the generator and write vectors to $(VEC_DIR)
#   make lib        build the C linkage (DPI-C) shared library
#   make clean

CXX      ?= g++
CC       ?= gcc
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -Wpedantic
CFLAGS   ?= -std=c99 -O2 -Wall
CPPFLAGS += -Iinclude

BUILD    := build
SEED     ?= 1
COUNT    ?= 100
NRED     ?= 100000
VEC_DIR  ?= vectors
TEST_SEED ?= 1
# External vectors (read only). A missing directory makes the hw-ext items FAIL.
EXT_DIR  ?= ../data/vectors/ext

HDRS     := $(wildcard include/*.h)
MODEL_SRC := src/mlkem_ntt.cpp src/mlkem_schoolbook.cpp src/mlkem_dpi.cpp
TEST_SRC  := test/test_main.cpp test/xcheck_pqcrystals.cpp test/test_hw.cpp
KYBER_DIR := third_party/pq-crystals-kyber
KYBER_OBJ := $(BUILD)/kyber_ntt.o $(BUILD)/kyber_reduce.o

.PHONY: all test test-hw vectors lib clean

all: $(BUILD)/test_mlkem $(BUILD)/gen_vectors $(BUILD)/libmlkem_dpi.so

$(BUILD):
	mkdir -p $@

$(BUILD)/kyber_%.o: $(KYBER_DIR)/%.c $(wildcard $(KYBER_DIR)/*.h) | $(BUILD)
	$(CC) $(CFLAGS) -DKYBER_K=3 -c $< -o $@

# The test binary is built with -DMLKEM_CHECK_WIDTHS (run-time width asserts).
$(BUILD)/test_mlkem: $(MODEL_SRC) $(TEST_SRC) $(HDRS) test/report.h $(KYBER_OBJ) | $(BUILD)
	$(CXX) $(CXXFLAGS) $(CPPFLAGS) -DMLKEM_CHECK_WIDTHS $(MODEL_SRC) $(TEST_SRC) $(KYBER_OBJ) -o $@

$(BUILD)/gen_vectors: $(MODEL_SRC) tools/gen_vectors.cpp $(HDRS) | $(BUILD)
	$(CXX) $(CXXFLAGS) $(CPPFLAGS) $(MODEL_SRC) tools/gen_vectors.cpp -o $@

$(BUILD)/libmlkem_dpi.so: $(MODEL_SRC) $(HDRS) | $(BUILD)
	$(CXX) $(CXXFLAGS) $(CPPFLAGS) -fPIC -shared $(MODEL_SRC) -o $@

lib: $(BUILD)/libmlkem_dpi.so

test: $(BUILD)/test_mlkem
	./$(BUILD)/test_mlkem --seed $(TEST_SEED) --fips-table third_party/fips203/appendix_a.txt \
	    --ext-dir $(EXT_DIR)

# Hardware-structure items only (quick).
test-hw: $(BUILD)/test_mlkem
	./$(BUILD)/test_mlkem --seed $(TEST_SEED) --ext-dir $(EXT_DIR) --only-hw

vectors: $(BUILD)/gen_vectors
	mkdir -p $(VEC_DIR)
	./$(BUILD)/gen_vectors --seed $(SEED) --count $(COUNT) --nred $(NRED) --out $(VEC_DIR)

clean:
	rm -rf $(BUILD) $(VEC_DIR)
