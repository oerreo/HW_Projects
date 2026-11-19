/*
 * Log line writer. One record per line: "KEY name=value name=value ...\r\n".
 * Values never contain spaces. Integers are decimal, hashes 0x-prefixed hex.
 * No printf: the bare-metal xil_printf has no 64-bit or float conversions.
 */
#ifndef OUT_H
#define OUT_H
#include <stdint.h>

void o_key(const char *key);
void o_s(const char *name, const char *v);     /* string, spaces become '_' */
void o_u(const char *name, uint64_t v);
void o_i(const char *name, int64_t v);
void o_x(const char *name, uint32_t v);
/* v / den with 3 decimals, e.g. o_q3("ms", ticks * 1000, tps) */
void o_q3(const char *name, uint64_t v, uint64_t den);
void o_end(void);
void o_raw(const char *s);

#endif
