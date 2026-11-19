#include "out.h"
#include "plat.h"

void o_raw(const char *s) {
  while (*s) plat_putc(*s++);
}

static void put_u(uint64_t v) {
  char b[24];
  int n = 0;
  do {
    b[n++] = (char)('0' + (int)(v % 10u));
    v /= 10u;
  } while (v);
  while (n) plat_putc(b[--n]);
}

static void put_name(const char *name) {
  plat_putc(' ');
  o_raw(name);
  plat_putc('=');
}

void o_key(const char *key) { o_raw(key); }

void o_s(const char *name, const char *v) {
  put_name(name);
  if (!v || !*v) {
    plat_putc('-');
    return;
  }
  for (; *v; v++) plat_putc((*v == ' ' || *v == '\t' || *v == '\r' || *v == '\n') ? '_' : *v);
}

void o_u(const char *name, uint64_t v) {
  put_name(name);
  put_u(v);
}

void o_i(const char *name, int64_t v) {
  put_name(name);
  if (v < 0) {
    plat_putc('-');
    put_u((uint64_t)(-(v + 1)) + 1u);
  } else {
    put_u((uint64_t)v);
  }
}

void o_x(const char *name, uint32_t v) {
  static const char hx[] = "0123456789abcdef";
  int i;
  put_name(name);
  plat_putc('0');
  plat_putc('x');
  for (i = 28; i >= 0; i -= 4) plat_putc(hx[(v >> i) & 15u]);
}

void o_q3(const char *name, uint64_t v, uint64_t den) {
  uint64_t ip, fp;
  put_name(name);
  if (den == 0) {
    plat_putc('-');
    return;
  }
  ip = v / den;
  fp = ((v % den) * 1000u + den / 2u) / den; /* (v % den) < den, den < 2^54 assumed */
  if (fp >= 1000u) {
    ip++;
    fp -= 1000u;
  }
  put_u(ip);
  plat_putc('.');
  plat_putc((char)('0' + (int)(fp / 100u)));
  plat_putc((char)('0' + (int)(fp / 10u % 10u)));
  plat_putc((char)('0' + (int)(fp % 10u)));
}

void o_end(void) {
  plat_putc('\r');
  plat_putc('\n');
}
