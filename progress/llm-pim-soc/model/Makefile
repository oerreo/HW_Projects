# Golden model build. Serial only (shared server): no -j.
.NOTPARALLEL:
MAKEFLAGS += -j1

CC      ?= gcc
CFLAGS  ?= -O2 -g -Wall -Wextra -Wno-unused-parameter -ffp-contract=off
CORE_STD = -std=c99 -pedantic
TOOL_STD = -std=gnu99
TP       = ../data/third_party/llama2c
B        = build

CORE = core tok fwd_f fwd_q hq fwd_h kern tabs bank
CORE_O = $(addprefix $(B)/,$(addsuffix .o,$(CORE)))
HDRS = src/llm.h src/kern.h tools/io.h

all: $(B)/run $(B)/t $(B)/rq

$(B):
	mkdir -p $(B)

$(B)/x1.c: | $(B)
	ln -sf ../$(TP)/run.c $@
$(B)/x2.c: | $(B)
	ln -sf ../$(TP)/runq.c $@

$(B)/%.o: src/%.c $(HDRS) | $(B)
	$(CC) $(CORE_STD) $(CFLAGS) -c $< -o $@

$(B)/io.o: tools/io.c $(HDRS) | $(B)
	$(CC) $(TOOL_STD) $(CFLAGS) -c $< -o $@

$(B)/run: tools/run.c $(B)/io.o $(CORE_O)
	$(CC) $(TOOL_STD) $(CFLAGS) -o $@ tools/run.c $(B)/io.o $(CORE_O) -lm

# reference wrappers include the unmodified third-party sources through symlinks
$(B)/ref.o: tests/ref.c tests/ref.h $(B)/x1.c
	$(CC) $(TOOL_STD) -O2 -ffp-contract=off -w -I$(B) -c tests/ref.c -o $@

$(B)/t: tests/t.c $(B)/ref.o $(B)/io.o $(CORE_O)
	$(CC) $(TOOL_STD) $(CFLAGS) -o $@ tests/t.c $(B)/ref.o $(B)/io.o $(CORE_O) -lm

$(B)/rq: tools/rq.c $(B)/x2.c $(B)/io.o $(CORE_O)
	$(CC) $(TOOL_STD) -O2 -ffp-contract=off -w -I$(B) -o $@ tools/rq.c $(B)/io.o $(CORE_O) -lm

# regenerate the constant LUT file (committed); not part of the normal build
tabs: | $(B)
	$(CC) -O2 -o $(B)/gentab tools/gentab.c -lm
	./$(B)/gentab > src/tabs.c

# integer-only proof for the H inference path
check-int: | $(B)
	sh tools/chk.sh

test: all check-int
	CFG=test.cfg ./$(B)/t

clean:
	rm -rf $(B)

.PHONY: all tabs check-int test clean
