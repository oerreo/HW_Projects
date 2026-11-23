/*
 * Executor of the system program (system.md 2.2): receives every kernel call of
 * lm_h_forward_x and runs it on the ARM (k_exec) or on an IP through a driver, following the
 * offload mask, the guard conditions, deferred execution with barriers, the cache rules and
 * the per-call time split (2.6). Run K compares every IP result with k_exec on shadow buffers.
 */
#ifndef SX_H
#define SX_H
#include <stdint.h>
#include "ipregs.h"
#include "llm.h"
#include "scfg.h"

/* KSPLIT / KCMP categories: the KERN categories of fpga/sw/src/prof.h with actq split into
   head (mask bit Qh) and attention output (Qa); KERN actq = actq_h + actq_a */
enum {
  SK_EMBED, SK_RMSNORM, SK_GQ, SK_GK, SK_GV, SK_GO, SK_GW1, SK_GW2, SK_GW3, SK_GCLS, SK_ROPE,
  SK_ACTQH, SK_ACTQA, SK_ATTN, SK_SWIGLU, SK_ADD, SK_ARGMAX, SK_OTHER, SK_N
};
extern const char *const SK_NAME[SK_N];

/* run kinds */
enum { RK_E = 0, RK_T = 1, RK_P = 2, RK_K = 3, RK_W = 4, RK_N };
extern const char *const RK_NAME[RK_N];

/* detected build (ID slots, system.md 2.3 step 2) */
typedef struct {
  uint32_t id[SLOT_N], cfg[SLOT_N], cfg2[SLOT_N], cfg3[SLOT_N];
  int has[SLOT_N], dead[SLOT_N];
  char build; /* 'A' (ga + at + ve), 'P' (pi + at + ve), '-' other */
  int ga_p, ga_nmax;
  int pi_nb, pi_lb, pi_nmax, pi_depth, pi_cmdd;
  int at_hpar, at_kvsrc, at_kl, at_tmax, at_hsmax, at_nkv, at_nl, at_kw, at_vw;
  int ve_nmax, ve_idxw;
  int fclk_mhz;
} sys_t;
int sys_detect(sys_t *y); /* prints the SYS line; returns the number of IPs found */

/* one weight matrix (system.md 2.3 steps 3, 4) */
typedef struct {
  const int8_t *w;    /* lm_hm_t.q: identifies the matrix of a K_GEMV call */
  int sk, rows, n, ok;
  uint8_t *rrec;      /* row records (arch.md 2.2) */
  uint32_t rbytes;
  long base;          /* PIM bank word base, -1 if none */
} smat_t;
#define SX_MAXMAT (7 * 32 + 1)
#define SX_MAXH 64
#define SX_MAXB 8

/* time split per category (ticks of plat_now; pl from CYCLES) */
typedef struct {
  long ip, arm, fb, ops;
  int64_t t_arm, t_pl, t_mv, t_call;
  uint64_t cyc, rd, wr;
} sk_t;
/* run K compare per category */
typedef struct {
  long calls, mis, first_pos, first_call, first_idx;
  int32_t exp, got;
} kc_t;
/* one IP op: driver time stamps (system.md 2.6) and counters */
typedef struct {
  uint64_t t0, t1, t3, t4, tinv;
  uint32_t cyc, rd, wr;
} dres_t;

typedef struct sx {
  sys_t *sys;
  /* model */
  const lm_cfg_t *c;
  const lm_hw_t *w;
  lm_hs_t *s;
  int D, H, hs, nh, nkv, kvmul, kb, vb, ek, ev, L, seq, V;
  smat_t mat[SX_MAXMAT];
  int nmat;
  uint8_t *qrec;  /* q records, nh x qb (attn.md 2) */
  uint32_t qb;
  int32_t *pbuf;  /* run K p buffer, nh x 8 ceil(seq / 2) B */
  uint8_t *shadow;/* run K shadow outputs */
  size_t shn;
  uint32_t avail; /* mask bits the build can serve for this model */
  uint32_t rrec_bytes;
  long bank_words;
  /* run */
  const char *mname, *vname;
  uint32_t mask, opt;
  int kind, meas, kmode, need_hash, pos;
  long ncall[SK_N];
  uint32_t xgen;
  /* deferred ATTN (DEFER_AT) */
  int at_n, at_h0, at_l, at_T, at_next;
  kcall_t at_c[SX_MAXH];
  uint8_t qsave[SX_MAXH][2 * K_HSMAX]; /* q of each deferred head (redo, run K) */
  int kvw_l, kvw_pos;
  /* deferred PIM (PIM_BATCH) */
  int pi_n;
  kcall_t pi_c[SX_MAXB];
  const smat_t *pi_m[SX_MAXB];
  uint32_t pi_xpa, pi_xgen;
  int pi_xok;
  int fused; /* gemv_acc argmax_en done for this forward */
  /* results of the run */
  sk_t sk[SK_N];
  kc_t kc[SK_N];
  long fb, iperr, iperr_lines, kmis, nops;
  /* driver register shadows (offsets 0x40..0x7C) */
  uint32_t shv[SLOT_N][16];
  uint32_t shok[SLOT_N];
  /* host fault injection (SX_FAULT_INJ) */
  int fault;
  long fault_n;
} sx_t;

/* dimensions and matrix table of a model (before the sizing pass), then the pointers of the
   filled model */
void sx_dims(sx_t *x, sys_t *y, const lm_cfg_t *c, const lm_hfmt_t *f);
void sx_model(sx_t *x, const lm_hw_t *w, lm_hs_t *s);
/* memory of the executor in the model arena (sizing pass when a->base == NULL) */
void sx_layout(sx_t *x, lm_arena_t *a);
/* row records, PIM bank load, availability; prints INIT/AVAIL lines; 0 = ok */
int sx_init(sx_t *x);
void sx_run_begin(sx_t *x, uint32_t mask, uint32_t opt, int kind);
/* executor entry (k_exec_fn) */
int sx_exec(void *user, const kcall_t *c);
/* run P hook helper: if a deferred batch must run before c (c cannot join it), returns the
   KERN category (prof.h PC_*) of the batch, else -1. The hook laps, calls sx_barrier, laps. */
int sx_need_barrier(sx_t *x, const kcall_t *c);
void sx_barrier(sx_t *x);
/* BRAM KV warm start: KVW of positions 0 .. upto - 1 of every layer */
int sx_kv_sync(sx_t *x, int upto);
/* PL time of CYCLES in ticks */
int64_t sx_cyc_ticks(const sx_t *x, uint64_t cyc);

/* drivers (drv_*.c) */
void dw(sx_t *x, int slot, uint32_t off, uint32_t v);
void dw_reset(sx_t *x, int slot);
int drv_go(sx_t *x, int slot, uint32_t op, uint64_t est_cyc, dres_t *r);
int ga_gemv(sx_t *x, const kcall_t *c, const smat_t *m, int am_en, dres_t *r);
int pi_push(sx_t *x, uint32_t op, int n, int rows, int32_t xm, long base, uint32_t addr, int we,
            int xe, int fo);
int pi_run(sx_t *x, uint64_t est_cyc, dres_t *r);
int pi_ldw_all(sx_t *x, uint64_t *cyc, uint32_t st[3]);
int at_kvw(sx_t *x, int l, int pos, dres_t *r);
int at_attn(sx_t *x, int l, int T, int h0, int nhd, dres_t *r);
int ve_call(sx_t *x, const kcall_t *c, dres_t *r);
/* driver return codes */
#define DRV_OK 0
#define DRV_RESP 1    /* RD_RESP/WR_RESP: data written, run FAIL */
#define DRV_ERR 2     /* BAD_* or similar: op did not run, redo on the ARM */
#define DRV_TIMEOUT 3 /* IP disabled, redo on the ARM */
#define DRV_FULL 4

/* fault ids (host test, SX_FAULT_INJ): system.md 3.1 (1)..(10) + register order */
enum {
  FX_NONE = 0, FX_NOFLUSH = 1, FX_NOINVAL = 2, FX_QREC = 3, FX_KVBASE = 4, FX_BANK = 5,
  FX_WRGB = 6, FX_BARRIER = 7, FX_GUARD = 10, FX_REGORDER = 11
};
#if SX_FAULT_INJ
#define FAULT(x, id) ((x)->fault == (id))
#else
#define FAULT(x, id) 0
#endif

#endif
