# Host checks of the bandwidth program (fpga/bw/sw). Shared server: serial, no -j.
#
#   make test    xilsyntax + host builds + run.sh (last line: HOSTTEST RESULT: PASS|FAIL)
#   make stub    tclsh stub check of the Vivado / XSCT scripts (STUBCHECK RESULT: ...)
#   make clean
#
# xilsyntax: bw_hal_xil.c and bw_main.c against stub BSP headers (-fsyntax-only, no ARM
# compiler here). t / t32: bw_main.c + bw_hal_host.c (software model of the IP register
# interface from docs/spec/bwtest.md, NOT the RTL), quick sweep, 64-bit and -m32 (ARM-like
# 32-bit pointers and longs).
.NOTPARALLEL:
MAKEFLAGS += -j1
SW   := ../sw
B    := build
CC   ?= gcc
FLG  := -std=c99 -pedantic -O2 -Wall -Wextra -Werror
HOST := -DBW_QUICK=1 -DPOLL_MAX=1000u -I$(SW)
SRC  := $(SW)/bw_main.c bw_hal_host.c
DEP  := $(SRC) $(wildcard $(SW)/*.h)

.PHONY: all test stub clean
all: test

$(B):
	mkdir -p $@

$(B)/xilsyntax.ok: $(SW)/bw_hal_xil.c $(SW)/bw_main.c $(wildcard $(SW)/*.h) $(wildcard xilstub/*.h) | $(B)
	$(CC) $(FLG) -fsyntax-only -Ixilstub -I$(SW) $(SW)/bw_hal_xil.c
	$(CC) $(FLG) -fsyntax-only -I$(SW) $(SW)/bw_main.c
	touch $@

$(B)/t: $(DEP) | $(B)
	$(CC) $(FLG) $(HOST) -o $@ $(SRC)

$(B)/t32: $(DEP) | $(B)
	$(CC) $(FLG) -m32 $(HOST) -o $@ $(SRC)

test: $(B)/xilsyntax.ok $(B)/t $(B)/t32
	sh ./run.sh

stub:
	tclsh stub_check.tcl

clean:
	rm -rf $(B)
