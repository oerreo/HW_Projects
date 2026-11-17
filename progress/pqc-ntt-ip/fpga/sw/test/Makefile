# Host test of the PS software (driver, test program, vectors, log format)
# against the register-level model reg_model.c. Shared server: -j2 at most.
#
#   make test        build and run everything (run.sh), exit 0 only if all pass
#   make bins        only build the two host binaries
#   make vectors-h   regenerate ../vectors.h from data/vectors/ext and the
#                    golden model generator (model/ `make vectors`, output in
#                    ../build/model_vec; model/ sources are not modified)
#   make clean
#
# Outputs go to build/ (this directory) and ../build/ only.

PROJ     := ../../..
MODEL    := $(PROJ)/model
SW       := ..
BUILD    := build

CC       ?= gcc
CXX      ?= g++
# Sanitizers when the toolchain has their runtime (not on every server).
SAN_PROBE := $(shell echo 'int main(void){return 0;}' | $(CC) -x c - -fsanitize=address,undefined -o /dev/null > /dev/null 2>&1 && echo yes)
SAN      ?= $(if $(SAN_PROBE),-fsanitize=address$(comma)undefined -fno-omit-frame-pointer,)
comma    := ,
CFLAGS   := -std=c99 -O1 -g -Wall -Wextra -Werror -DPQC_HOST_TEST $(SAN)
CXXFLAGS := -std=c++17 -O2 -g -Wall -Wextra
CPPFLAGS := -I$(SW) -I. -I$(MODEL)/include
LDFLAGS  := $(SAN)

MODEL_SRC := $(MODEL)/src/mlkem_ntt.cpp $(MODEL)/src/mlkem_schoolbook.cpp $(MODEL)/src/mlkem_dpi.cpp
MODEL_OBJ := $(BUILD)/mlkem_ntt.o $(BUILD)/mlkem_schoolbook.o $(BUILD)/mlkem_dpi.o
SW_HDR    := $(wildcard $(SW)/*.h) reg_model.h
DRV_OBJ   := $(BUILD)/pqc_ntt.o $(BUILD)/reg_model.o

# vectors.h generation (golden model generator settings)
VEC_SEED  ?= 17
VEC_COUNT ?= 16
VEC_NRED  ?= 1000
VEC_ARGS  ?=

.PHONY: all bins test vectors-h clean

all: bins

bins: $(BUILD)/t_main $(BUILD)/t_drv

$(BUILD):
	mkdir -p $@ $@/logs

$(BUILD)/%.o: $(MODEL)/src/%.cpp $(wildcard $(MODEL)/include/*.h) | $(BUILD)
	$(CXX) $(CXXFLAGS) -I$(MODEL)/include -c $< -o $@

$(BUILD)/pqc_ntt.o: $(SW)/pqc_ntt.c $(SW_HDR) | $(BUILD)
	$(CC) $(CFLAGS) $(CPPFLAGS) -c $< -o $@

$(BUILD)/reg_model.o: reg_model.c $(SW_HDR) | $(BUILD)
	$(CC) $(CFLAGS) $(CPPFLAGS) -c $< -o $@

$(BUILD)/main.o: $(SW)/main.c $(SW_HDR) | $(BUILD)
	$(CC) $(CFLAGS) $(CPPFLAGS) -c $< -o $@

$(BUILD)/test_driver.o: test_driver.c $(SW_HDR) | $(BUILD)
	$(CC) $(CFLAGS) $(CPPFLAGS) -c $< -o $@

$(BUILD)/t_main: $(BUILD)/main.o $(DRV_OBJ) $(MODEL_OBJ)
	$(CXX) $(LDFLAGS) $^ -o $@

$(BUILD)/t_drv: $(BUILD)/test_driver.o $(DRV_OBJ) $(MODEL_OBJ)
	$(CXX) $(LDFLAGS) $^ -o $@

test: bins
	sh ./run.sh

# Settings are passed to model/ make through the environment (its variables
# use ?=), keeping the command line free of names.
vectors-h:
	mkdir -p $(SW)/build/model_vec
	SEED=$(VEC_SEED) COUNT=$(VEC_COUNT) NRED=$(VEC_NRED) VEC_DIR=../fpga/sw/build/model_vec \
	    $(MAKE) -C $(MODEL) vectors
	python3 -I $(SW)/tools/gen_vectors_h.py $(VEC_ARGS)

clean:
	rm -rf $(BUILD)
