/*
 * bound: exhaustive range check of the golden k_rsqrt over every normalized input
 * mn in [2^30, 2^32) (k_rsqrt's result depends only on mn: re = 31 + t/2 carries the shift).
 * Prints the minimum and maximum rm; rsqrt_nr keeps rm in 17 bits (rm < 2^17 required).
 * No arguments. Build: gcc -O2 -Imodel/src tb/rsqrt_nr/bound.c model/src/kern.c model/src/tabs.c
 */
#include <stdio.h>
#include <stdint.h>
#include "kern.h"

int main(void) {
  uint64_t mn, n = 0;
  uint32_t lo = 0xFFFFFFFFu, hi = 0;
  int re;
  for (mn = (uint64_t)1 << 30; mn < ((uint64_t)1 << 32); mn++) {
    uint32_t rm = k_rsqrt(mn, &re);
    if (rm < lo) lo = rm;
    if (rm > hi) hi = rm;
    n++;
  }
  printf("rsqrt bound: %llu inputs, rm min %u max %u (2^17 = 131072): %s\n", (unsigned long long)n, lo, hi,
         hi < 131072u ? "fits 17 bits" : "DOES NOT FIT");
  return hi < 131072u ? 0 : 1;
}
