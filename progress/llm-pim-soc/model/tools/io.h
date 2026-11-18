/* PC-side helpers: files, config, variant bundle, dump and profile hooks. */
#ifndef IO_H
#define IO_H
#include <stdio.h>
#include "../src/llm.h"

void *io_read(const char *path, size_t *len); /* malloc'd, NUL-terminated */
double io_now(void);                          /* monotonic seconds */

/* config file: "key value" lines, '#' comments; path from env CFG or ./run.cfg */
int cfg_load(void);
const char *cfg_s(const char *key, const char *def);
long cfg_i(const char *key, long def);

/* prompts: one per line, a line "<EMPTY>" is the empty prompt */
int io_prompts(const char *path, char ***out);

/* H format candidates and variant names */
int fmt_lookup(const char *name, lm_hfmt_t *f);
extern const char *FMT_NAMES[];

#define MAXV 12
enum { VK_F, VK_Q, VK_H };
typedef struct {
  char name[16];
  int kind;
  lm_fs_t fs;
  lm_qw_t qw;
  lm_qs_t qs;
  lm_hfmt_t hf;
  lm_hw_t hw;
  lm_hs_t hs;
} variant_t;
typedef struct {
  lm_cfg_t c;
  lm_fw_t fw;
  lm_tok_t tok;
  void *ck, *tk, *mem;
  size_t ckn, tkn, memn;
  int nv;
  variant_t v[MAXV];
} bundle_t;
/* vars: comma separated, e.g. "F,Qr,Qg,HA" */
int bundle_load(bundle_t *b, const char *ck, const char *tk, const char *vars);
/* logits as float (H: int / 2^16); returns argmax, -1 on error */
int bundle_step(bundle_t *b, int vi, int tok, int pos, float *logits, const k_hook_t *hk);

/* hooks */
typedef struct {
  FILE *f;
  int cap, active;
  int count[K_NKERN];
  long recs;
} dump_t;
void dump_hook(void *user, int phase, const kcall_t *c);
typedef struct {
  double t0, t[K_NKERN];
  long calls[K_NKERN];
  double macs[K_NKERN], elems[K_NKERN];
} prof_t;
void prof_hook(void *user, int phase, const kcall_t *c);
typedef struct {
  dump_t *d;
  prof_t *p;
} both_t;
void both_hook(void *user, int phase, const kcall_t *c);

/* dump record reader: fills c with malloc'd buffers; inputs and recorded outputs */
int dump_read(FILE *f, kcall_t *c, void *recorded_out[KB_MAX]);
void dump_free(kcall_t *c, void *recorded_out[KB_MAX]);

#endif
