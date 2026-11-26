#include "plat.h"
#include <string.h>

#ifdef PLAT_ARENA
static unsigned char *ar_base;
static size_t ar_size, ar_used;
void plat_arena(void *mem, size_t n) { ar_base = mem; ar_size = n; ar_used = 0; }
void *plat_alloc(size_t n)
{
  size_t a = (ar_used + 15u) & ~(size_t)15u;
  if (!ar_base || a + n > ar_size) return NULL;
  ar_used = a + n;
  memset(ar_base + a, 0, n);
  return ar_base + a;
}
void plat_free(void *p) { (void)p; }
#else
#include <stdlib.h>
void *plat_alloc(size_t n) { return calloc(1, n ? n : 1); }
void plat_free(void *p) { free(p); }
#endif
