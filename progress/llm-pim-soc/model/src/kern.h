/*
 * Integer kernels of the H (hardware) variant.
 *
 * Every function here is the bit-exact definition of one hardware kernel. A kernel
 * reads only its input buffers and writes only its output buffers (no global state,
 * no float, no libm). Each kernel can also be invoked through a generic call
 * descriptor (kcall_t) so that a hook can dump its inputs and outputs and a test
 * can replay the dump through k_exec().
 *
 * Number formats
 *   fixed point "Qf": int32 v, real value = v * 2^-f
 *   scale kscl_t {m, e}: real value of a quantized element q is q * m * 2^-e,
 *     m is an unsigned mantissa (< 2^17), e a signed exponent. m = 0 means all-zero.
 *   rounding: rshr(x, s) = floor((x + 2^(s-1)) / 2^s) for s > 0 (round half up),
 *     x * 2^-s (saturating) for s < 0. Right shifts of negative values are arithmetic.
 */
#ifndef KERN_H
#define KERN_H
#include <stdint.h>

typedef struct { int32_t m, e; } kscl_t;

/* activation scale modes */
#define ACT_POW2 0 /* m = 1, scale is a power of two (shift only) */
#define ACT_MANT 1 /* m is a 17-bit mantissa, one reciprocal per vector */

/* fixed fraction bits used by the H forward pass */
#define K_FX 16 /* residual stream, gemv outputs, logits, attention output */
#define K_FS 16 /* attention scores */

/* limits that keep every accumulator inside its type (checked in k_exec) */
#define K_NMAX 16384 /* longest gemv row: 16384*127*127*65535 < 2^61 */
#define K_HSMAX 128  /* head size */
#define K_TMAX 4096  /* attention length */

/* rsqrt seed table: 48 entries, index = top 6 bits of the normalized input */
#define K_RSQ_N 48
extern const uint32_t k_rsq_lut[K_RSQ_N];
/* exp2(-f) tables, f in [0,1), 2^b + 1 entries, Q16, for b = 4..8 */
const uint32_t *k_exp_lut(int b);
/* sigmoid tables over [0,16), 2^b + 1 entries, Q16, for b = 4..8 */
const uint32_t *k_sig_lut(int b);

/* ---- kernels ---- */
void k_embed(const int8_t *q, const uint16_t *m, int n, int gs, int we, int fo, int32_t *y);
void k_gemv(const int8_t *W, const uint16_t *wm, int we, int rows, int n, int gs,
            const int8_t *x, kscl_t xs, int fo, int32_t *y);
void k_actq(const int32_t *v, int n, int f, int mode, int qmax, void *q, kscl_t *s);
void k_rmsnorm(const int32_t *x, int n, int fx, const int16_t *g, int ge, int32_t epsc,
               int fy, int mode, int8_t *q, kscl_t *s);
void k_rope(const int32_t *v, int n, int hs, const int16_t *cs, int32_t *o);
void k_attn(int T, int hs, int esz, const void *q, kscl_t qs, const void *K, const kscl_t *ks,
            const void *V, const kscl_t *vs, int eb, const uint32_t *elut, int32_t *p, int32_t *o);
void k_swiglu(const int32_t *h1, const int32_t *h3, int n, int sb, const uint32_t *slut,
              int mode, int8_t *q, kscl_t *s);
void k_add(const int32_t *a, const int32_t *b, int n, int32_t *o);
int k_argmax(const int32_t *v, int n);
void k_topk(const int32_t *v, int n, int k, int32_t *idx, int32_t *val);

/* scalar helpers (exported for unit tests) */
uint32_t k_rsqrt(uint64_t u, int *re);         /* 1/sqrt(u) ~= rm * 2^-re */
uint32_t k_exp2neg(uint32_t u, int eb, const uint32_t *lut); /* 2^(-u/65536), Q16 */
uint32_t k_sigmoid(int32_t a, int sb, const uint32_t *lut);  /* a in Q16, result Q16 */
int64_t k_rshr(int64_t x, int s);

/* ---- generic call descriptor ---- */
enum {
  K_EMBED = 1, K_GEMV, K_RMSNORM, K_ACTQ, K_ROPE, K_ATTN, K_SWIGLU, K_ADD, K_ARGMAX, K_TOPK,
  K_NKERN
};
#define KP_MAX 12
#define KB_MAX 8
typedef struct {
  void *p;       /* buffer */
  int32_t esz;   /* element size in bytes */
  int32_t n;     /* element count */
  int32_t out;   /* 0 input, 1 output */
} kbuf_t;
typedef struct {
  int32_t kid, np, nb;
  int32_t prm[KP_MAX];
  kbuf_t b[KB_MAX];
} kcall_t;

/*
 * Descriptor layout per kernel (prm = integer parameters, b = buffers in order)
 *  K_EMBED   prm n gs we fo                 b q:i8[n] m:u16[n/gs] | y:i32[n]
 *  K_GEMV    prm rows n gs we xm xe fo      b W:i8[rows*n] m:u16[rows*n/gs] x:i8[n] | y:i32[rows]
 *  K_RMSNORM prm n fx ge epsc fy mode       b x:i32[n] g:i16[n] | q:i8[n] s:i32[2]
 *  K_ACTQ    prm n f mode qmax              b v:i32[n] | q:i8 or i16[n] s:i32[2]
 *  K_ROPE    prm n hs                       b v:i32[n] cs:i16[hs] | o:i32[n]
 *  K_ATTN    prm T hs esz qm qe eb          b q[hs] K[T*hs] ks:i32[2T] V[T*hs] vs:i32[2T] lut:u32 | p:i32[T] o:i32[hs]
 *  K_SWIGLU  prm n sb mode                  b h1:i32[n] h3:i32[n] lut:u32 | q:i8[n] s:i32[2]
 *  K_ADD     prm n                          b a:i32[n] b:i32[n] | o:i32[n]
 *  K_ARGMAX  prm n                          b v:i32[n] | idx:i32[1]
 *  K_TOPK    prm n k                        b v:i32[n] | idx:i32[k] val:i32[k]
 * Output buffers never alias input buffers.
 */
int k_exec(const kcall_t *c); /* 0 ok, negative on bad descriptor or range violation */
const char *k_name(int kid);

/* hook called before (phase 0) and after (phase 1) every kernel call */
typedef void (*k_hook_fn)(void *user, int phase, const kcall_t *c);
typedef struct { k_hook_fn fn; void *user; } k_hook_t;

#endif
