# Host build and test of the system program (fpga/sys/sw) against the C register models of
# the IPs and the cache model (hal_host.c, ipm_*.c). Shared server: serial only, no -j.
#
#   make bins    t (64-bit), t32 (-m32), both with fault injection hooks, and the
#                -fsyntax-only checks of the board files against stub BSP headers
#   make test    bins + run.sh (last line: SYSHOST RESULT: PASS|FAIL)
#   make clean
#
# Needs fpga/sw/gen/m1_data.c (make -C ../../sw/test data) and the expected-value headers
# fpga/sw/expect/exp_m*.h (committed). Run settings reach the programs through the
# environment (SX_*), never through arguments.
.NOTPARALLEL:
MAKEFLAGS += -j1

PROJ   := ../../..
MSRC   := $(PROJ)/model/src
BSW    := ../../sw
SW     := ../sw
B      := build

CC     ?= gcc
BASE   := -O2 -ffp-contract=off
WARN   := -Wall -Wextra -Wno-unused-parameter
STRICT := -std=c99 -pedantic $(WARN) -Werror
CORE   := core tok fwd_f fwd_q hq fwd_h kern tabs bank
BSRC   := out lmhash exp plat_host prof
SSRC   := sys_main sbench sx_exec sysmem drv_com drv_ga drv_pi drv_at drv_ve
TSRC   := hal_host ipm_ga ipm_pi ipm_at ipm_ve
INC    := -I$(SW) -I. -I$(BSW)/src -I$(BSW)/expect -I$(MSRC)
HOST   := -DHAL_HOST -DSX_FAULT_INJ=1
M32    := -m32 -msse2 -mfpmath=sse
DEP    := $(wildcard $(SW)/*.h) $(wildcard *.h) $(wildcard $(BSW)/src/*.h) $(wildcard $(BSW)/expect/*.h) \
          $(MSRC)/llm.h $(MSRC)/kern.h
M1DATA := $(BSW)/gen/m1_data.c

objs = $(addprefix $(1)/m_,$(addsuffix .o,$(CORE))) $(addprefix $(1)/b_,$(addsuffix .o,$(BSRC))) \
       $(addprefix $(1)/s_,$(addsuffix .o,$(SSRC))) $(addprefix $(1)/t_,$(addsuffix .o,$(TSRC))) \
       $(1)/d_m1.o

.PHONY: all bins test clean
all: bins

$(B) $(B)/o64 $(B)/o32 $(B)/logs:
	mkdir -p $@

define flavour
$(B)/$(1)/m_%.o: $(MSRC)/%.c $(DEP) | $(B)/$(1)
	$(CC) -std=c99 -pedantic $(BASE) $(WARN) $(2) -c $$< -o $$@
$(B)/$(1)/b_%.o: $(BSW)/src/%.c $(DEP) | $(B)/$(1)
	$(CC) $(STRICT) $(BASE) $(2) $(INC) -c $$< -o $$@
$(B)/$(1)/s_%.o: $(SW)/%.c $(DEP) | $(B)/$(1)
	$(CC) $(STRICT) $(BASE) $(2) $(HOST) $(INC) -c $$< -o $$@
$(B)/$(1)/t_%.o: %.c $(DEP) | $(B)/$(1)
	$(CC) $(STRICT) $(BASE) $(2) $(HOST) $(INC) -c $$< -o $$@
$(B)/$(1)/d_m1.o: $(M1DATA) | $(B)/$(1)
	$(CC) -O0 $(2) -c $$< -o $$@
endef
$(eval $(call flavour,o64,))
$(eval $(call flavour,o32,$(M32)))

$(B)/t: $(call objs,$(B)/o64)
	$(CC) -o $@ $^ -lm
$(B)/t32: $(call objs,$(B)/o32)
	$(CC) $(M32) -o $@ $^ -lm

# board files: hal_xil.c, fpga/sw/src/plat_xil.c and every system source in the board
# configuration (no HAL_HOST, no fault hooks) against the stub BSP headers; no ARM compiler
# here, inline assembly is not assembled by -fsyntax-only
XSRC := $(SW)/hal_xil.c $(BSW)/src/plat_xil.c $(addprefix $(SW)/,$(addsuffix .c,$(SSRC)))
$(B)/xilsyntax.ok: $(XSRC) $(DEP) $(wildcard xilstub/*.h) | $(B)
	for f in $(XSRC); do $(CC) $(STRICT) -fsyntax-only -Ixilstub $(INC) $$f || exit 1; done
	touch $@

bins: $(B)/t $(B)/t32 $(B)/xilsyntax.ok

test: bins | $(B)/logs
	sh ./run.sh

clean:
	rm -rf $(B)
