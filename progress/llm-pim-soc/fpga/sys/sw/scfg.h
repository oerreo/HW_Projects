/*
 * Build-time options of the system program (system.md 2.8). Board: -D on the compiler command
 * line. Host test: the same macros, and the host HAL may override the run list through the
 * environment (hal_env, see sbench.c) so that one host binary runs many combinations.
 */
#ifndef SCFG_H
#define SCFG_H

#ifndef SYS_RUN_M1
#define SYS_RUN_M1 1 /* stories260K (embedded arrays) */
#endif
#ifndef SYS_RUN_M2
#define SYS_RUN_M2 1 /* stories15M (DDR images) */
#endif

/* offload masks (system.md 2.2 mask bits) and call options (opt bits), run in this order;
   each entry is mask | opt << 8 */
#define MB_G 0x01u   /* K_GEMV q k v o w1 w3 w2 */
#define MB_C 0x02u   /* K_GEMV cls */
#define MB_A 0x04u   /* K_ATTN2 */
#define MB_R 0x08u   /* K_RMSNORM */
#define MB_S 0x10u   /* K_SWIGLU */
#define MB_QH 0x20u  /* K_ACTQ n = hs (K, V cache, q head) */
#define MB_QA 0x40u  /* K_ACTQ n = D (attention output) */
#define MB_M 0x80u   /* K_ARGMAX */
#define MB_ALL 0xFFu
#define OPT_DEFER_AT 0x01u   /* one ATTN op per layer (deferred heads) */
#define OPT_PIM_BATCH 0x02u  /* MACABs with the same x in one RUN */
#define OPT_WRGB_SKIP 0x04u  /* skip WRGB when (x, generation) is unchanged */
#define OPT_FUSE_AM 0x08u    /* build A: classifier + argmax in gemv_acc */
#define OPT_COH_STRICT 0x10u /* flush IP output ranges before the start (debug) */
#define OPT_DEFAULT (OPT_DEFER_AT | OPT_WRGB_SKIP | OPT_FUSE_AM)
#define MO(m, o) ((m) | ((o) << 8))

#ifndef SYS_MASK_LIST
/* system.md 4.1 */
#define SYS_MASK_LIST                                                                          \
  MO(0, OPT_DEFAULT), MO(MB_G, OPT_DEFAULT), MO(MB_C, OPT_DEFAULT),                            \
      MO(MB_C | MB_M, OPT_DEFAULT), MO(MB_G | MB_C, OPT_DEFAULT), MO(MB_A, OPT_DEFAULT),        \
      MO(MB_R, OPT_DEFAULT), MO(MB_S, OPT_DEFAULT), MO(MB_QH, OPT_DEFAULT),                     \
      MO(MB_QA, OPT_DEFAULT), MO(MB_M, OPT_DEFAULT),                                            \
      MO(MB_R | MB_S | MB_QH | MB_QA | MB_M, OPT_DEFAULT), MO(MB_G | MB_C | MB_A, OPT_DEFAULT),  \
      MO(MB_ALL, OPT_DEFAULT), MO(MB_ALL & ~MB_QH, OPT_DEFAULT),                               \
      MO(MB_ALL, OPT_DEFAULT & ~OPT_DEFER_AT), MO(MB_ALL, OPT_DEFAULT | OPT_PIM_BATCH),         \
      MO(MB_ALL, OPT_DEFAULT & ~OPT_WRGB_SKIP)
#endif

/* runs per mask: bit 0 E (end-to-end), 1 T (per token + hash), 2 P (probes + split),
   3 K (kernel shadow compare) */
#ifndef SYS_RUN_MASK
#define SYS_RUN_MASK 0xFu
#endif
/* positions per run (0 = all positions of the expected header) */
#ifndef SYS_STEPS
#define SYS_STEPS 0
#endif
/* actual PL clock (Vivado report) in Hz; the IP CONFIG FCLK_MHZ is printed next to it */
#ifndef SYS_FCLK_HZ
#define SYS_FCLK_HZ 100000000u
#endif
/* minimum polling limit (system.md 2.4: max(10 ms, 100 x expected PL time)) */
#ifndef SYS_POLL_MIN_US
#define SYS_POLL_MIN_US 10000u
#endif
#ifndef SYS_ROPE_FROM_PC
#define SYS_ROPE_FROM_PC 1
#endif
/* fault injection hooks (host test only; 0 on the board) */
#ifndef SX_FAULT_INJ
#define SX_FAULT_INJ 0
#endif
#ifndef BUILD_OPT
#define BUILD_OPT -1
#endif

#define SYS_MAX_STEPS 512
#define SYS_MAX_PTOK 512
#define SYS_MAX_RUNS 64

#endif
