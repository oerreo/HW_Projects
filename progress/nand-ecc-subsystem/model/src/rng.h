/* xoshiro128** (Blackman and Vigna, public domain reference xoshiro128starstar.c) and seeding.
 * docs/spec/numeric.md 2. Integer only; identical on every platform. */
#ifndef RNG_H
#define RNG_H
#include <stdint.h>

typedef struct { uint32_t s[4]; } rng_t;

static inline uint32_t rng_rotl(uint32_t x, int k) { return (x << k) | (x >> (32 - k)); }

/* one 32-bit output (reference algorithm, line for line) */
static inline uint32_t rng_next(rng_t *r)
{
  uint32_t *s = r->s;
  const uint32_t result = rng_rotl(s[1] * 5u, 7) * 9u;
  const uint32_t t = s[1] << 9;
  s[2] ^= s[0];
  s[3] ^= s[1];
  s[1] ^= s[2];
  s[0] ^= s[3];
  s[2] ^= t;
  s[3] = rng_rotl(s[3], 11);
  return result;
}

uint64_t splitmix64(uint64_t *x);
/* state from (seed, stream): four 32-bit words from splitmix64 started at seed ^ (stream * golden)
 * (stream = frame index or lane). An all-zero state is replaced by a fixed nonzero word. */
void rng_seed(rng_t *r, uint64_t seed, uint64_t stream);
/* uniform double in (0, 1): (53-bit integer from two outputs + 0.5) / 2^53 */
double rng_u01(rng_t *r);
/* standard normal by Box-Muller (double, PC verification channel only: AWGN, reference sampler) */
double rng_gauss(rng_t *r);

#endif
