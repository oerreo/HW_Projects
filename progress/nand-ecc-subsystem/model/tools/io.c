#include "io.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>

char *io_read(const char *path, size_t *len)
{
  FILE *f = fopen(path, "rb");
  char *buf;
  long n;
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  n = ftell(f);
  fseek(f, 0, SEEK_SET);
  buf = malloc((size_t)n + 1);
  if (!buf || fread(buf, 1, (size_t)n, f) != (size_t)n) { free(buf); fclose(f); return NULL; }
  buf[n] = 0;
  fclose(f);
  if (len) *len = (size_t)n;
  return buf;
}

double io_now(void)
{
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec * 1e-9;
}

#define CFG_MAX 256
static char *ck[CFG_MAX], *cv[CFG_MAX];
static int cn;

int cfg_load_path(const char *path)
{
  char *t = io_read(path, NULL), *p, *line;
  if (!t) return -1;
  cn = 0;
  for (line = strtok_r(t, "\n", &p); line; line = strtok_r(NULL, "\n", &p)) {
    char *k = line, *v;
    while (*k == ' ' || *k == '\t') k++;
    if (!*k || *k == '#') continue;
    v = k;
    while (*v && *v != ' ' && *v != '\t') v++;
    if (*v) *v++ = 0;
    while (*v == ' ' || *v == '\t') v++;
    {
      char *e = v + strlen(v);
      while (e > v && (e[-1] == ' ' || e[-1] == '\t' || e[-1] == '\r')) *--e = 0;
    }
    if (cn < CFG_MAX) { ck[cn] = strdup(k); cv[cn] = strdup(v); cn++; }
  }
  free(t);
  return 0;
}

int cfg_load(void)
{
  const char *p = getenv("CFG");
  return cfg_load_path(p ? p : "run.cfg");
}

const char *cfg_s(const char *key, const char *def)
{
  int i;
  const char *e = getenv(key);
  if (e) return e;
  for (i = cn - 1; i >= 0; i--) if (!strcmp(ck[i], key)) return cv[i];
  return def;
}

long cfg_i(const char *key, long def)
{
  const char *s = cfg_s(key, NULL);
  return s ? strtol(s, NULL, 0) : def;
}

double cfg_d(const char *key, double def)
{
  const char *s = cfg_s(key, NULL);
  return s ? strtod(s, NULL) : def;
}

int cfg_list(const char *key, double *out, int max)
{
  const char *s = cfg_s(key, NULL);
  int n = 0;
  char *end;
  if (!s) return 0;
  while (*s && n < max) {
    while (*s == ' ' || *s == ',' || *s == '\t') s++;
    if (!*s) break;
    out[n] = strtod(s, &end);
    if (end == s) break;
    n++;
    s = end;
  }
  return n;
}

int io_code(code_t *c, const char *path)
{
  char *t = io_read(path, NULL);
  int rc, L = (int)strlen(path);
  if (!t) return -1;
  if (L > 6 && !strcmp(path + L - 6, ".alist")) rc = code_parse_alist(c, t);
  else rc = code_parse_qc(c, t);
  free(t);
  return rc;
}
