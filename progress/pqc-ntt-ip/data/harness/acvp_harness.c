/*
 * ACVP ML-KEM harness for the pq-crystals/kyber reference implementation.
 *
 * Build once per parameter set with -DKYBER_K={2,3,4} and link with
 *   -Wl,--wrap=<ns>poly_ntt -Wl,--wrap=<ns>poly_invntt_tomont
 *   -Wl,--wrap=<ns>poly_basemul_montgomery
 * so that every call made by polyvec.c / indcpa.c goes through the __wrap_
 * functions below. No upstream source file is modified.
 *
 * Usage: acvp_harness_<ps> <cases.txt> <raw_dump.txt>
 *   cases.txt  from data/scripts/acvp_to_cases.py
 *   raw_dump   one line per observed call, raw int16 values of the ref
 *              implementation (no conversion is done here):
 *     ntt     <ps> <tcId> <ctx> <seq> <in[256]> <out[256]>
 *     invntt  <ps> <tcId> <ctx> <seq> <in[256]> <out[256]>
 *     basemul <ps> <tcId> <ctx> <seq> <a[256]> <b[256]> <out[256]>
 * Prints one RESULT line per case and a SUMMARY line; exit code 0 only if all
 * cases pass and all call counts match the expected structure.
 */
#define _POSIX_C_SOURCE 200809L /* getline, strtok_r */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fips202.h"
#include "kem.h"
#include "params.h"
#include "poly.h"

#define CAT_(a, b) a##b
#define CAT(a, b) CAT_(a, b)
/* poly_ntt etc. are macros from poly.h that expand to the namespaced name. */
#define WRAP(s) CAT(__wrap_, s)
#define REAL(s) CAT(__real_, s)

#if KYBER_K == 2
#define PS_NAME "512"
#elif KYBER_K == 3
#define PS_NAME "768"
#else
#define PS_NAME "1024"
#endif

void REAL(poly_ntt)(poly *r);
void REAL(poly_invntt_tomont)(poly *r);
void REAL(poly_basemul_montgomery)(poly *r, const poly *a, const poly *b);
void WRAP(poly_ntt)(poly *r);
void WRAP(poly_invntt_tomont)(poly *r);
void WRAP(poly_basemul_montgomery)(poly *r, const poly *a, const poly *b);

static FILE *g_dump = NULL;
static const char *g_tc = "none";
static const char *g_ctx = "none";
static int g_seq = 0;
static int g_n_ntt = 0, g_n_invntt = 0, g_n_basemul = 0;

static void dump_poly(const poly *p) {
  for (int i = 0; i < KYBER_N; ++i) fprintf(g_dump, " %d", p->coeffs[i]);
}

static void dump_head(const char *op) {
  fprintf(g_dump, "%s %s %s %s %d", op, PS_NAME, g_tc, g_ctx, g_seq++);
}

void WRAP(poly_ntt)(poly *r) {
  poly in = *r;
  REAL(poly_ntt)(r);
  ++g_n_ntt;
  if (g_dump) {
    dump_head("ntt");
    dump_poly(&in);
    dump_poly(r);
    fputc('\n', g_dump);
  }
}

void WRAP(poly_invntt_tomont)(poly *r) {
  poly in = *r;
  REAL(poly_invntt_tomont)(r);
  ++g_n_invntt;
  if (g_dump) {
    dump_head("invntt");
    dump_poly(&in);
    dump_poly(r);
    fputc('\n', g_dump);
  }
}

void WRAP(poly_basemul_montgomery)(poly *r, const poly *a, const poly *b) {
  /* r may alias neither a nor b in upstream callers, but copy to be safe. */
  poly ac = *a, bc = *b;
  REAL(poly_basemul_montgomery)(r, &ac, &bc);
  ++g_n_basemul;
  if (g_dump) {
    dump_head("basemul");
    dump_poly(&ac);
    dump_poly(&bc);
    dump_poly(r);
    fputc('\n', g_dump);
  }
}

/* ------------------------------------------------------------------------ */

static int hex2bin(const char *hex, uint8_t *out, size_t outlen) {
  size_t n = strlen(hex);
  if (n != 2 * outlen) return -1;
  for (size_t i = 0; i < outlen; ++i) {
    unsigned v;
    if (sscanf(hex + 2 * i, "%2x", &v) != 1) return -1;
    out[i] = (uint8_t)v;
  }
  return 0;
}

static char *next_tok(char **save) { return strtok_r(NULL, " \t\r\n", save); }

/* FIPS 203 section 7.2 modulus check: every 12-bit field of ek[0:384k] < q. */
static int ek_check(const uint8_t *ek) {
  for (int i = 0; i < KYBER_POLYVECBYTES / 3; ++i) {
    unsigned a = ek[3 * i] | ((unsigned)(ek[3 * i + 1] & 0x0F) << 8);
    unsigned b = (ek[3 * i + 1] >> 4) | ((unsigned)ek[3 * i + 2] << 4);
    if (a >= KYBER_Q || b >= KYBER_Q) return 0;
  }
  return 1;
}

/* FIPS 203 section 7.3 hash check: H(dk[384k : 768k+32]) == dk[768k+32 : 768k+64]. */
static int dk_check(const uint8_t *dk) {
  uint8_t h[32];
  sha3_256(h, dk + KYBER_INDCPA_SECRETKEYBYTES, KYBER_PUBLICKEYBYTES);
  return memcmp(h, dk + KYBER_INDCPA_SECRETKEYBYTES + KYBER_PUBLICKEYBYTES, 32) == 0;
}

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s <cases.txt> <raw_dump.txt>\n", argv[0]);
    return 2;
  }
  FILE *in = fopen(argv[1], "r");
  if (!in) { perror(argv[1]); return 2; }
  g_dump = fopen(argv[2], "w");
  if (!g_dump) { perror(argv[2]); return 2; }

  static uint8_t pk[KYBER_PUBLICKEYBYTES], sk[KYBER_SECRETKEYBYTES];
  static uint8_t pk_e[KYBER_PUBLICKEYBYTES], sk_e[KYBER_SECRETKEYBYTES];
  static uint8_t ct[KYBER_CIPHERTEXTBYTES], ct_e[KYBER_CIPHERTEXTBYTES];
  uint8_t coins[2 * KYBER_SYMBYTES], ss[KYBER_SSBYTES], ss_e[KYBER_SSBYTES];

  int n_case = 0, n_fail = 0, n_count_err = 0;
  int per_kind_total[5] = {0}, per_kind_fail[5] = {0};
  const char *kinds[5] = {"keygen", "encap", "decap", "ekcheck", "dkcheck"};
  const int K = KYBER_K;

  char *line = NULL;
  size_t cap = 0;
  while (getline(&line, &cap, in) > 0) {
    char *save = NULL;
    char *kind = strtok_r(line, " \t\r\n", &save);
    if (!kind) continue;
    char *tc = next_tok(&save);
    int ok = 0, ki = -1, bad_input = 0;
    int exp_ntt = 0, exp_inv = 0, exp_bm = 0;
    g_tc = tc;
    g_ctx = kind;
    g_seq = 0;
    g_n_ntt = g_n_invntt = g_n_basemul = 0;

    if (strcmp(kind, "keygen") == 0) {
      ki = 0;
      char *d = next_tok(&save), *z = next_tok(&save);
      char *ek = next_tok(&save), *dk = next_tok(&save);
      bad_input |= hex2bin(d, coins, 32) | hex2bin(z, coins + 32, 32);
      bad_input |= hex2bin(ek, pk_e, sizeof pk_e) | hex2bin(dk, sk_e, sizeof sk_e);
      crypto_kem_keypair_derand(pk, sk, coins);
      ok = !bad_input && memcmp(pk, pk_e, sizeof pk) == 0 && memcmp(sk, sk_e, sizeof sk) == 0;
      exp_ntt = 2 * K; exp_bm = K * K; exp_inv = 0;
    } else if (strcmp(kind, "encap") == 0) {
      ki = 1;
      char *ek = next_tok(&save), *m = next_tok(&save);
      char *c = next_tok(&save), *k = next_tok(&save);
      bad_input |= hex2bin(ek, pk, sizeof pk) | hex2bin(m, coins, 32);
      bad_input |= hex2bin(c, ct_e, sizeof ct_e) | hex2bin(k, ss_e, sizeof ss_e);
      crypto_kem_enc_derand(ct, ss, pk, coins);
      ok = !bad_input && memcmp(ct, ct_e, sizeof ct) == 0 && memcmp(ss, ss_e, sizeof ss) == 0;
      exp_ntt = K; exp_bm = K * K + K; exp_inv = K + 1;
    } else if (strcmp(kind, "decap") == 0) {
      ki = 2;
      char *dk = next_tok(&save), *c = next_tok(&save), *k = next_tok(&save);
      bad_input |= hex2bin(dk, sk, sizeof sk) | hex2bin(c, ct, sizeof ct);
      bad_input |= hex2bin(k, ss_e, sizeof ss_e);
      crypto_kem_dec(ss, ct, sk);
      ok = !bad_input && memcmp(ss, ss_e, sizeof ss) == 0;
      /* indcpa_dec (K ntt, K basemul, 1 invntt) + re-encryption */
      exp_ntt = 2 * K; exp_bm = K + K * K + K; exp_inv = 1 + K + 1;
    } else if (strcmp(kind, "ekcheck") == 0) {
      ki = 3;
      char *ek = next_tok(&save), *e = next_tok(&save);
      int len_ok = strlen(ek) == 2 * sizeof pk;
      int got = len_ok && hex2bin(ek, pk, sizeof pk) == 0 && ek_check(pk);
      ok = got == atoi(e);
    } else if (strcmp(kind, "dkcheck") == 0) {
      ki = 4;
      char *dk = next_tok(&save), *e = next_tok(&save);
      int len_ok = strlen(dk) == 2 * sizeof sk;
      int got = len_ok && hex2bin(dk, sk, sizeof sk) == 0 && dk_check(sk);
      ok = got == atoi(e);
    } else {
      fprintf(stderr, "unknown case kind %s\n", kind);
      return 2;
    }

    int count_ok = g_n_ntt == exp_ntt && g_n_invntt == exp_inv && g_n_basemul == exp_bm;
    if (!count_ok) ++n_count_err;
    ++n_case;
    ++per_kind_total[ki];
    if (!ok) { ++n_fail; ++per_kind_fail[ki]; }
    printf("RESULT ML-KEM-%s %s tcId=%s %s calls(ntt=%d invntt=%d basemul=%d)%s\n", PS_NAME,
           kind, tc, ok ? "PASS" : "FAIL", g_n_ntt, g_n_invntt, g_n_basemul,
           count_ok ? "" : " CALLCOUNT_MISMATCH");
  }
  free(line);
  fclose(in);
  fclose(g_dump);

  for (int i = 0; i < 5; ++i)
    printf("KIND ML-KEM-%s %-8s total=%d fail=%d\n", PS_NAME, kinds[i], per_kind_total[i],
           per_kind_fail[i]);
  printf("SUMMARY ML-KEM-%s cases=%d fail=%d callcount_mismatch=%d %s\n", PS_NAME, n_case,
         n_fail, n_count_err, (n_fail == 0 && n_count_err == 0) ? "PASS" : "FAIL");
  return (n_fail == 0 && n_count_err == 0) ? 0 : 1;
}
