# Host build and test of the ARM baseline program (fpga/sw). Shared server:
# serial only, no -j.
#
#   make data    only the embedded 260K arrays (../gen/m1_data.c, not committed);
#                this is all a board user needs before xsct_build.tcl
#   make gen     data + the expected-value headers (../expect/exp_m*.h, committed)
#                from the PC golden driver; only after model/src changes
#   make bins    host builds of the board program
#   make test    gen-check + bins + run.sh (last line: HOSTTEST RESULT: PASS|FAIL)
#   make clean
#
# The variant list and H format of the expected values: ../tools/m1.cfg, m2.cfg
# (key vars). Settings reach the generator through CFG files, not arguments.
.NOTPARALLEL:
MAKEFLAGS += -j1

PROJ   := ../../..
MSRC   := $(PROJ)/model/src
MTOOL  := $(PROJ)/model/tools
MODELS := $(PROJ)/data/third_party/models
SW     := ..
B      := build

CC     ?= gcc
# -ffp-contract=off and no fast-math: the F variant is bit-identical to the
# reference only under these flags (model/README.md); the board build uses them too
BASE   := -O2 -ffp-contract=off
WARN   := -Wall -Wextra -Wno-unused-parameter
CORE   := core tok fwd_f fwd_q hq fwd_h kern tabs
SRC    := main bench prof fq_prof out lmhash exp plat_host
SRCDEP := $(wildcard $(SW)/src/*.h) $(wildcard $(SW)/expect/*.h) $(MSRC)/llm.h $(MSRC)/kern.h
INC    := -I$(SW)/src -I$(SW)/expect -I$(MSRC)
# 32-bit build: SSE math so that float is IEEE single as on the ARM VFP (x87 would
# keep excess precision)
M32    := -m32 -msse2 -mfpmath=sse

M1IN   := $(MODELS)/stories260K.bin:m1_ck $(MODELS)/tok512.bin:m1_tk

# objects of one flavour: $(call objs,dir)
objs = $(addprefix $(1)/m_,$(addsuffix .o,$(CORE))) $(addprefix $(1)/s_,$(addsuffix .o,$(SRC)))

.PHONY: all data gen bins test clean
all: bins

$(B) $(B)/o64 $(B)/o32 $(B)/oc $(B)/od $(B)/su $(B)/expc $(B)/logs:
	mkdir -p $@

# ---------------- generated inputs ----------------
$(B)/gen: $(SW)/tools/gen_expect.c $(SW)/src/lmhash.c $(MTOOL)/io.c $(addprefix $(MSRC)/,$(addsuffix .c,$(CORE))) $(SRCDEP) | $(B)
	$(CC) -std=gnu99 $(BASE) -w -I$(SW)/src -I$(MTOOL) -I$(MSRC) -o $@ $(SW)/tools/gen_expect.c \
	    $(SW)/src/lmhash.c $(MTOOL)/io.c $(addprefix $(MSRC)/,$(addsuffix .c,$(CORE))) -lm

$(SW)/gen/m1_data.c: $(SW)/tools/bin2c.py $(MODELS)/stories260K.bin $(MODELS)/tok512.bin
	mkdir -p $(SW)/gen
	BIN2C_OUT=$@ BIN2C_IN="$(M1IN)" python3 -I $(SW)/tools/bin2c.py

data: $(SW)/gen/m1_data.c

gen: $(B)/gen $(SW)/gen/m1_data.c
	CFG=$(SW)/tools/m1.cfg ./$(B)/gen
	CFG=$(SW)/tools/m2.cfg ./$(B)/gen

# ---------------- host builds of the board program ----------------
# t: 64-bit, both models. t32: -m32. tc: corrupted expected values. td: data
# image tests (15M only, no generation runs). su: -m32 with -fstack-usage.
define flavour
$(B)/$(1)/m_%.o: $(MSRC)/%.c $(SRCDEP) | $(B)/$(1)
	$(CC) -std=c99 -pedantic $(BASE) $(WARN) $(2) -c $$< -o $$@
$(B)/$(1)/s_%.o: $(SW)/src/%.c $(SRCDEP) $(3) | $(B)/$(1)
	$(CC) -std=c99 -pedantic $(BASE) $(WARN) -Werror $(2) $(4) $(INC) -c $$< -o $$@
endef
$(eval $(call flavour,o64,,,))
$(eval $(call flavour,o32,$(M32),,))
$(eval $(call flavour,oc,,$(B)/expc/exp_m1.h $(B)/expc/exp_m2.h,-I$(B)/expc))
$(eval $(call flavour,od,,,-DRUN_M1=0 -DRUN_MASK=1))
$(eval $(call flavour,su,$(M32) -fstack-usage,,))

$(B)/o64/s_m1d.o $(B)/o32/s_m1d.o $(B)/oc/s_m1d.o $(B)/su/s_m1d.o: $(SW)/gen/m1_data.c
$(B)/o64/s_m1d.o: | $(B)/o64
	$(CC) -O0 -c $(SW)/gen/m1_data.c -o $@
$(B)/o32/s_m1d.o: | $(B)/o32
	$(CC) -O0 $(M32) -c $(SW)/gen/m1_data.c -o $@
$(B)/oc/s_m1d.o: | $(B)/oc
	$(CC) -O0 -c $(SW)/gen/m1_data.c -o $@
$(B)/su/s_m1d.o: | $(B)/su
	$(CC) -O0 $(M32) -c $(SW)/gen/m1_data.c -o $@

# corrupted expected values (negative test): same generator, corrupt 1
$(B)/expc/exp_m1.h: $(B)/gen $(SW)/tools/m1.cfg | $(B)/expc
	CFG=$(SW)/tools/m1.cfg corrupt=1 out=$@ ./$(B)/gen
$(B)/expc/exp_m2.h: $(B)/gen $(SW)/tools/m2.cfg | $(B)/expc
	CFG=$(SW)/tools/m2.cfg corrupt=1 out=$@ ./$(B)/gen

$(B)/t: $(call objs,$(B)/o64) $(B)/o64/s_m1d.o
	$(CC) -o $@ $^ -lm
$(B)/t32: $(call objs,$(B)/o32) $(B)/o32/s_m1d.o
	$(CC) $(M32) -o $@ $^ -lm
$(B)/tc: $(call objs,$(B)/oc) $(B)/oc/s_m1d.o
	$(CC) -o $@ $^ -lm
$(B)/td: $(call objs,$(B)/od)
	$(CC) -o $@ $^ -lm
$(B)/tsu: $(call objs,$(B)/su) $(B)/su/s_m1d.o
	$(CC) $(M32) -o $@ $^ -lm

# bin2c round trip in C: the arrays written back to files
$(B)/rt: rt.c $(B)/o64/s_m1d.o
	$(CC) -std=c99 -O0 -Wall -o $@ rt.c $(B)/o64/s_m1d.o

# syntax check of the Xilinx platform file against stub BSP headers (no ARM
# compiler here; inline asm is not assembled by -fsyntax-only)
$(B)/xilsyntax.ok: $(SW)/src/plat_xil.c $(SRCDEP) $(wildcard xilstub/*.h) | $(B)
	$(CC) -std=c99 -pedantic -Wall -Wextra -Werror -fsyntax-only -Ixilstub -I$(SW)/src $(SW)/src/plat_xil.c
	touch $@

bins: $(B)/t $(B)/t32 $(B)/tc $(B)/td $(B)/tsu $(B)/rt $(B)/xilsyntax.ok

test: $(B)/gen bins | $(B)/logs
	sh ./run.sh

clean:
	rm -rf $(B)
