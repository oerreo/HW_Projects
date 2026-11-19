#include <string.h>
#include "prof.h"

const char *const PC_NAME[PC_N] = {
    "embed",   "rmsnorm", "gemv_q", "gemv_k", "gemv_v", "gemv_o", "gemv_w1", "gemv_w2", "gemv_w3",
    "gemv_cls", "rope",   "actq",   "attn",   "swiglu", "add",    "argmax",  "other"};

void prof_clear(prof_t *p) { memset(p, 0, sizeof(*p)); }

static int name_cat(const char *s) {
  if (!strncmp(s, "attn", 4)) return PC_ATTN; /* attn, attn2 */
  if (!strcmp(s, "embed")) return PC_EMBED;
  if (!strcmp(s, "gemv")) return PC_GQ;      /* resolved per matrix */
  if (!strcmp(s, "rmsnorm")) return PC_RMSNORM;
  if (!strcmp(s, "actq")) return PC_ACTQ;
  if (!strcmp(s, "rope")) return PC_ROPE;
  if (!strcmp(s, "swiglu")) return PC_SWIGLU;
  if (!strcmp(s, "add")) return PC_ADD;
  if (!strcmp(s, "argmax")) return PC_ARGMAX;
  return PC_OTHER;
}

int hprof_setup(hprof_t *h, prof_t *p, const lm_hw_t *w, const lm_cfg_t *c) {
  int l, k;
  memset(h, 0, sizeof(*h));
  h->p = p;
  if (7 * c->n_layers + 1 > HP_MAXMAT) return -1;
  for (k = 0; k < 32; k++) h->kmap[k] = (int8_t)(k > 0 && k < K_NKERN ? name_cat(k_name(k)) : PC_OTHER);
  for (l = 0; l < c->n_layers; l++) {
    const void *m[7];
    const int8_t kd[7] = {PC_GQ, PC_GK, PC_GV, PC_GO, PC_GW1, PC_GW2, PC_GW3};
    m[0] = w->wq[l].q; m[1] = w->wk[l].q; m[2] = w->wv[l].q; m[3] = w->wo[l].q;
    m[4] = w->w1[l].q; m[5] = w->w2[l].q; m[6] = w->w3[l].q;
    for (k = 0; k < 7; k++) {
      h->mat[h->nmat] = m[k];
      h->kind[h->nmat++] = kd[k];
    }
  }
  h->mat[h->nmat] = w->cls.q;
  h->kind[h->nmat++] = PC_GCLS;
  return 0;
}

/* phase 0: classify (charged to "other"), then lap "other";
 * phase 1: lap the kernel category first */
void hprof_hook(void *user, int phase, const kcall_t *c) {
  hprof_t *h = (hprof_t *)user;
  if (phase == 0) {
    int cat = (c->kid > 0 && c->kid < 32) ? h->kmap[c->kid] : PC_OTHER;
    if (cat == PC_GQ) {
      int i;
      cat = PC_OTHER; /* unknown matrix */
      for (i = 0; i < h->nmat; i++)
        if (h->mat[i] == c->b[0].p) {
          cat = h->kind[i];
          break;
        }
    }
    h->cur = cat;
    prof_lap(h->p, PC_OTHER);
  } else {
    prof_lap(h->p, h->cur);
  }
}

int argmax_f(const float *v, int n) {
  int i, am = 0;
  for (i = 1; i < n; i++)
    if (v[i] > v[am]) am = i;
  return am;
}
