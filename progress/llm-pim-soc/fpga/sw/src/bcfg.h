/*
 * Build-time options of the baseline program. Override with -D on the compiler
 * command line (XSCT: define-compiler-symbols, host test: CFLAGS).
 *
 * Which variants run (F, Q, H and the H number format) is fixed by the expected
 * value headers in ../expect/ (generated on the PC by tools/gen_expect.c from a
 * config file); VAR_MASK only skips some of them.
 */
#ifndef BCFG_H
#define BCFG_H

#ifndef RUN_M1
#define RUN_M1 1 /* stories260K from arrays compiled into the program */
#endif
#ifndef RUN_M2
#define RUN_M2 1 /* stories15M from images loaded into DDR over JTAG */
#endif

/* DDR memory map (Zybo Z7-20: 1 GiB at 0x00000000). The program image (code,
 * data, heap, stack) must stay below DDR_CK_ADDR; see fpga/README.md. */
#ifndef DDR_CK_ADDR
#define DDR_CK_ADDR 0x10000000u /* stories15M.bin, 60,816,028 B */
#endif
#ifndef DDR_TK_ADDR
#define DDR_TK_ADDR 0x14000000u /* tokenizer.bin, 433,869 B */
#endif
#ifndef ARENA_ADDR
#define ARENA_ADDR 0x18000000u  /* model memory block (quantized weights, state) */
#endif
#ifndef ARENA_CAP
#define ARENA_CAP 0x27F00000u   /* up to 0x3FF00000 */
#endif

/* variants of the expected header to run: bit i = variant i (0 F, 1 Q, 2 H) */
#ifndef VAR_MASK
#define VAR_MASK 0xFu
#endif
/* runs per variant: bit 0 E (end-to-end, no probes), bit 1 T (per token),
 * bit 2 P (per kernel probes) */
#ifndef RUN_MASK
#define RUN_MASK 0x7u
#endif
/* print every POS_STRIDE-th per-token time (0: none) */
#ifndef POS_STRIDE
#define POS_STRIDE 1
#endif
/* repetitions of the probe overhead measurements */
#ifndef OVH_N
#define OVH_N 2000
#endif
/* H RoPE table: 1 = replace the table built on this platform by the PC table of
 * the expected header when they differ (the hardware ROM uses the PC table). */
#ifndef ROPE_FROM_PC
#define ROPE_FROM_PC 1
#endif
/* optimization tag printed in the log (set by xsct_build.tcl, e.g. 2 or 3) */
#ifndef BUILD_OPT
#define BUILD_OPT -1
#endif

#define MAX_STEPS 512
#define MAX_PTOK 512

#endif
