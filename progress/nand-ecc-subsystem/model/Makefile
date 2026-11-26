# C model build. Serial only (shared server): no -j.
.NOTPARALLEL:
MAKEFLAGS += -j1

CC      ?= gcc
CFLAGS  ?= -O2 -g -Wall -Wextra -Wno-unused-parameter -ffp-contract=off
CORE_STD = -std=c99 -pedantic
TOOL_STD = -std=gnu99
B        = build

CORE = plat rng code enc dec_ref dec_fix chan sense llr bch policy
CORE_O = $(addprefix $(B)/,$(addsuffix .o,$(CORE)))
HDRS = $(wildcard src/*.h) tools/io.h

all: $(B)/t $(B)/fer $(B)/xdump $(B)/rtab $(B)/prof

$(B):
	mkdir -p $(B)

$(B)/%.o: src/%.c $(HDRS) | $(B)
	$(CC) $(CORE_STD) $(CFLAGS) -c $< -o $@

$(B)/io.o: tools/io.c $(HDRS) | $(B)
	$(CC) $(TOOL_STD) $(CFLAGS) -c $< -o $@

$(B)/t: tests/t.c $(B)/io.o $(CORE_O)
	$(CC) $(TOOL_STD) $(CFLAGS) -o $@ tests/t.c $(B)/io.o $(CORE_O) -lm

$(B)/fer: tools/fer.c $(B)/io.o $(CORE_O)
	$(CC) $(TOOL_STD) $(CFLAGS) -o $@ tools/fer.c $(B)/io.o $(CORE_O) -lm

$(B)/xdump: tools/xdump.c $(B)/io.o $(CORE_O)
	$(CC) $(TOOL_STD) $(CFLAGS) -o $@ tools/xdump.c $(B)/io.o $(CORE_O) -lm

$(B)/rtab: tools/rtab.c $(B)/io.o $(CORE_O)
	$(CC) $(TOOL_STD) $(CFLAGS) -o $@ tools/rtab.c $(B)/io.o $(CORE_O) -lm

$(B)/prof: tools/prof.c $(B)/io.o $(CORE_O)
	$(CC) $(TOOL_STD) $(CFLAGS) -o $@ tools/prof.c $(B)/io.o $(CORE_O) -lm

# external code matrices (data/third_party, fetched by data/scripts/fetch.sh) and alist exports
ext:
	cd .. && python3 -I data/scripts/c2_alist.py && python3 -I model/tools/qc2alist.py

# unit tests, fer determinism (two identical short runs), fixed-point cross-check against the
# independent Python implementation (tools/fixref.py)
test: all
	CFG=test.cfg ./$(B)/t
	sh tools/det.sh
	sh tools/xcheck.sh

clean:
	rm -rf $(B)

.PHONY: all ext test clean
