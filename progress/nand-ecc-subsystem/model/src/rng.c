#include "rng.h"
#include <math.h>

uint64_t splitmix64(uint64_t *x)
{
  uint64_t z = (*x += 0x9E3779B97F4A7C15ull);
  z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
  z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
  return z ^ (z >> 31);
}

void rng_seed(rng_t *r, uint64_t seed, uint64_t stream)
{
  uint64_t x = seed ^ (stream * 0xD1B54A32D192ED03ull);
  uint64_t a = splitmix64(&x), b = splitmix64(&x);
  r->s[0] = (uint32_t)a;
  r->s[1] = (uint32_t)(a >> 32);
  r->s[2] = (uint32_t)b;
  r->s[3] = (uint32_t)(b >> 32);
  if (!(r->s[0] | r->s[1] | r->s[2] | r->s[3])) r->s[0] = 0x9E3779B9u;
}

double rng_u01(rng_t *r)
{
  uint64_t hi = rng_next(r) >> 6;  /* 26 bits */
  uint64_t lo = rng_next(r) >> 5;  /* 27 bits */
  return ((double)((hi << 27) | lo) + 0.5) * (1.0 / 9007199254740992.0);
}

double rng_gauss(rng_t *r)
{
  double u1 = rng_u01(r), u2 = rng_u01(r);
  return sqrt(-2.0 * log(u1)) * cos(6.283185307179586 * u2);
}
