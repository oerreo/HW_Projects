/* Thin platform layer: the only place the library allocates memory.
 * PC: malloc/free. ARM bare-metal: build with -DPLAT_ARENA and call plat_arena() once with a static
 * block; plat_free is then a no-op (allocations live until the next plat_arena call).
 * The library (src/) does no file I/O; text inputs (code tables, parameter tables) are passed in as
 * NUL-terminated strings. */
#ifndef PLAT_H
#define PLAT_H
#include <stddef.h>
#include <stdint.h>

void *plat_alloc(size_t n);   /* zero-filled, NULL on failure */
void plat_free(void *p);
#ifdef PLAT_ARENA
void plat_arena(void *mem, size_t n);
#endif

#endif
