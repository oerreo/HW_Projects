/* PC-side helpers: whole-file read, "key value" config, monotonic clock, code loading. */
#ifndef IO_H
#define IO_H
#include <stdio.h>
#include "../src/code.h"

char *io_read(const char *path, size_t *len);   /* malloc'd, NUL-terminated, NULL on error */
double io_now(void);

/* config: "key value..." lines, '#' comments. Path from env CFG (default ./run.cfg).
 * An environment variable with the same key name overrides the file. */
int cfg_load(void);
int cfg_load_path(const char *path);
const char *cfg_s(const char *key, const char *def);
long cfg_i(const char *key, long def);
double cfg_d(const char *key, double def);
/* split a value into whitespace/comma separated doubles; returns count */
int cfg_list(const char *key, double *out, int max);

/* code file: "*.alist" -> alist parser, otherwise QC table */
int io_code(code_t *c, const char *path);

#endif
