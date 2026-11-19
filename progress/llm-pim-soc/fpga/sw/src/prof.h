/*
 * Kernel probes. "Lap" scheme: each probe reads the time base once and charges the
 * time since the previous probe to one category, so the categories of one token
 * partition its time exactly (sum of categories == token time, nothing lost).
 *
 * F and Q: model/src computes them in one function each (lm_f_forward,
 * lm_q_forward) without a hook, so fq_prof.c restates both with probes between the
 * steps. The board program checks on every run that the restated version produces
 * the same logits bit for bit as the model/src function (self check).
 * H: the probes sit in the k_hook_t of lm_h_forward (model/src unchanged).
 */
#ifndef PROF_H
#define PROF_H
#include <stdint.h>
#include "llm.h"
#include "plat.h"

enum {
  PC_EMBED, PC_RMSNORM, PC_GQ, PC_GK, PC_GV, PC_GO, PC_GW1, PC_GW2, PC_GW3, PC_GCLS,
  PC_ROPE, PC_ACTQ, PC_ATTN, PC_SWIGLU, PC_ADD, PC_ARGMAX, PC_OTHER, PC_N
};
extern const char *const PC_NAME[PC_N];

typedef struct {
  uint64_t last;
  uint64_t t[PC_N];
  uint32_t n[PC_N];
} prof_t;

static inline void prof_lap(prof_t *p, int k) {
  uint64_t now = plat_now();
  p->t[k] += now - p->last;
  p->n[k]++;
  p->last = now;
}
void prof_clear(prof_t *p);

/* H hook: user = hprof_t */
#define HP_MAXMAT (7 * 32 + 1)
typedef struct {
  prof_t *p;
  int cur;
  int nmat;
  const void *mat[HP_MAXMAT];
  int8_t kind[HP_MAXMAT];
  int8_t kmap[32];      /* kid -> category (from k_name) */
} hprof_t;
int hprof_setup(hprof_t *h, prof_t *p, const lm_hw_t *w, const lm_cfg_t *c);
void hprof_hook(void *user, int phase, const kcall_t *c);

/* F and Q forward passes with probes; return the logits, *am = argmax */
const float *fq_f_forward(lm_fs_t *s, const lm_cfg_t *c, const lm_fw_t *w, int tok, int pos,
                          prof_t *p, int *am);
const float *fq_q_forward(lm_qs_t *qs, const lm_cfg_t *c, const lm_qw_t *w, int tok, int pos,
                          prof_t *p, int *am);
int argmax_f(const float *v, int n); /* first index of the maximum (as model/tools/io.c) */

#endif
