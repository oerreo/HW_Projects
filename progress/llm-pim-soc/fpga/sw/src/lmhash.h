/*
 * Hashes shared by the board program and the PC generator of expected values.
 * FNV-1a 32-bit over the little-endian byte image (both targets are little-endian).
 */
#ifndef LMHASH_H
#define LMHASH_H
#include <stddef.h>
#include <stdint.h>
#include "llm.h"

#define H_INIT 0x811C9DC5u
uint32_t h_fnv(uint32_t h, const void *p, size_t n);
uint32_t h_i32(uint32_t h, int32_t v);
/* all quantized tensors in build order (layers, classifier, embedding table) */
uint32_t h_qweights(const lm_qw_t *w, const lm_cfg_t *c);
/* all quantized tensors, mantissas, exponents and rmsnorm gains (not the RoPE table) */
uint32_t h_hweights(const lm_hw_t *w, const lm_cfg_t *c);

#endif
