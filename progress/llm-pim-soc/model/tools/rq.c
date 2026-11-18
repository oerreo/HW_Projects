/*
 * Checks the suspected group-boundary problem of the public int8 implementation
 * (llama2.c runq.c with export.py --version 2) by execution.
 *  1. Writes a version-2 (Q8_0) checkpoint from the float checkpoint, following the
 *     export.py rules: group size 64 halved until it divides dim, groups taken over
 *     the flattened tensor, scale = max|w| / 127 in float32, round half to even.
 *  2. Matmul-level: runq matmul on w2 of layer 0 against float, and the same call
 *     after changing the input elements beyond the last full group.
 *  3. Model-level: runq forward vs our F forward (bit-exact to run.c) along F's
 *     greedy sequence on the prompt set; our Qg variant for comparison.
 * x2.c is a build symlink to data/third_party/llama2c/runq.c (unmodified, MIT).
 * keys: ck tk pf q80 steps out
 */
#define TESTING
#include "x2.c"
#include "io.h"

static FILE *OUT;
#define P(...)                          \
  do {                                  \
    printf(__VA_ARGS__);                \
    if (OUT) fprintf(OUT, __VA_ARGS__); \
  } while (0)

static void wq80(FILE *f, const float *w, long numel, int gs) {
  long g, i, ng = numel / gs;
  int8_t *q = malloc((size_t)numel);
  float *s = malloc(sizeof(float) * ng);
  for (g = 0; g < ng; g++) {
    float mx = 0.0f, sc;
    for (i = 0; i < gs; i++)
      if (fabsf(w[g * gs + i]) > mx) mx = fabsf(w[g * gs + i]);
    sc = mx / 127.0f;
    s[g] = sc;
    for (i = 0; i < gs; i++) q[g * gs + i] = (int8_t)rintf(w[g * gs + i] / sc);
  }
  fwrite(q, 1, (size_t)numel, f);
  fwrite(s, sizeof(float), (size_t)ng, f);
  free(q);
  free(s);
}

static int export_v2(const lm_cfg_t *c, const lm_fw_t *w, const char *path, int *gsout) {
  FILE *f = fopen(path, "wb");
  int gs = 64, L = c->n_layers, D = c->dim, H = c->hidden_dim, l;
  int kv = D * c->n_kv_heads / c->n_heads;
  uint32_t magic = 0x616b3432;
  int32_t ver = 2, hdr[7];
  uint8_t shared = 1;
  long pad;
  if (!f || !w->shared) return -1;
  while (D % gs) gs /= 2;
  *gsout = gs;
  hdr[0] = D; hdr[1] = H; hdr[2] = L; hdr[3] = c->n_heads; hdr[4] = c->n_kv_heads;
  hdr[5] = c->vocab_size; hdr[6] = c->seq_len;
  fwrite(&magic, 4, 1, f);
  fwrite(&ver, 4, 1, f);
  fwrite(hdr, 4, 7, f);
  fwrite(&shared, 1, 1, f);
  fwrite(&gs, 4, 1, f);
  pad = 256 - ftell(f);
  while (pad-- > 0) fputc(0, f);
  fwrite(w->rms_att, sizeof(float), (size_t)L * D, f);
  fwrite(w->rms_ffn, sizeof(float), (size_t)L * D, f);
  fwrite(w->rms_final, sizeof(float), (size_t)D, f);
  /* export.py asserts numel % group_size == 0 for every tensor */
  if (((long)c->vocab_size * D) % gs || ((long)D * kv) % gs || ((long)D * H) % gs) return -2;
  wq80(f, w->emb, (long)c->vocab_size * D, gs);
  for (l = 0; l < L; l++) wq80(f, w->wq + (size_t)l * D * D, (long)D * D, gs);
  for (l = 0; l < L; l++) wq80(f, w->wk + (size_t)l * D * kv, (long)D * kv, gs);
  for (l = 0; l < L; l++) wq80(f, w->wv + (size_t)l * D * kv, (long)D * kv, gs);
  for (l = 0; l < L; l++) wq80(f, w->wo + (size_t)l * D * D, (long)D * D, gs);
  for (l = 0; l < L; l++) wq80(f, w->w1 + (size_t)l * D * H, (long)D * H, gs);
  for (l = 0; l < L; l++) wq80(f, w->w2 + (size_t)l * D * H, (long)D * H, gs);
  for (l = 0; l < L; l++) wq80(f, w->w3 + (size_t)l * D * H, (long)D * H, gs);
  fclose(f);
  return 0;
}

int main(void) {
  bundle_t b;
  Transformer t;
  char **pr;
  int np, gs, i, k, V, steps;
  uint64_t rng = 20261118u;
  if (cfg_load()) fprintf(stderr, "no config\n");
  if (cfg_s("out", NULL)) OUT = fopen(cfg_s("out", NULL), "w");
  if (bundle_load(&b, cfg_s("ck", ""), cfg_s("tk", ""), "F,Qg")) return 1;
  V = b.c.vocab_size;
  steps = (int)cfg_i("steps", 256);
  if (steps > b.c.seq_len) steps = b.c.seq_len;
  if (export_v2(&b.c, &b.fw, cfg_s("q80", "q80.bin"), &gs)) { fprintf(stderr, "export failed\n"); return 1; }
  build_transformer(&t, (char *)cfg_s("q80", "q80.bin"));
  P("# runq check: dim %d hidden %d GS %d (runq global), hidden %% GS = %d\n", b.c.dim,
    b.c.hidden_dim, GS, b.c.hidden_dim % GS);

  /* ---- matmul level on w2 of layer 0: n = hidden_dim, d = dim ---- */
  {
    int n = b.c.hidden_dim, d = b.c.dim, ngs = n / GS, r;
    float *x = malloc(sizeof(float) * n), *yr = malloc(sizeof(float) * d), *yf = malloc(sizeof(float) * d);
    float *y2 = malloc(sizeof(float) * d);
    QuantizedTensor qx;
    double emax = 0, ymax = 0;
    int changed = 0;
    qx.q = calloc((size_t)n, 1);
    qx.s = calloc((size_t)(n / GS + 1), sizeof(float));
    for (i = 0; i < n; i++) {
      rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
      x[i] = (float)((double)(rng >> 11) / 9007199254740992.0 * 2.0 - 1.0);
    }
    quantize(&qx, x, n);
    matmul(yr, &qx, t.weights.w2, n, d);
    for (r = 0; r < d; r++) {
      double v = 0;
      for (k = 0; k < n; k++) v += (double)b.fw.w2[(size_t)r * n + k] * x[k];
      yf[r] = (float)v;
      if (fabs(v) > ymax) ymax = fabs(v);
      if (fabs(v - yr[r]) > emax) emax = fabs(v - yr[r]);
    }
    P("w2 matmul: inputs used by the group loop %d of %d; max|y| %.4f, max abs err runq vs float %.4f\n",
      ngs * GS, n, ymax, emax);
    for (i = ngs * GS; i < n; i++) x[i] = 100.0f * (i % 2 ? 1 : -1);
    quantize(&qx, x, n);
    matmul(y2, &qx, t.weights.w2, n, d);
    for (r = 0; r < d; r++) changed += y2[r] != yr[r];
    P("w2 matmul: after setting x[%d..%d] to +-100, outputs changed: %d of %d\n", ngs * GS, n - 1,
      changed, d);
    /* row/group alignment of the scale index (in + j) / GS */
    {
      int misaligned = 0;
      for (r = 0; r < d; r++)
        for (k = 0; k + GS <= n; k += GS) misaligned += ((long)r * n + k) % GS != 0;
      P("w2 scale index: %d of %d (row, group) steps start inside a flattened group\n", misaligned,
        d * ngs);
    }
    free(x); free(yr); free(yf); free(y2); free(qx.q); free(qx.s);
  }

  /* ---- model level ---- */
  {
    float *lf = malloc(sizeof(float) * V), *lq = malloc(sizeof(float) * V);
    int *tok = malloc(sizeof(int) * 65536);
    double emr = 0, ssr = 0, emq = 0, ssq = 0, nn = 0;
    long top_r = 0, top_q = 0, npos = 0, divr = 0, divq = 0, ndr = 0, ndq = 0;
    np = io_prompts(cfg_s("pf", ""), &pr);
    for (i = 0; i < np; i++) {
      int nt, pos, cur, dr = -1, dq = -1;
      lm_tok_encode(&b.tok, pr[i], 1, 0, tok, &nt);
      cur = tok[0];
      for (pos = 0; pos < steps; pos++) {
        int af = bundle_step(&b, 0, cur, pos, lf, NULL), aq, ar = 0, next;
        const float *lr = forward(&t, cur, pos);
        aq = bundle_step(&b, 1, cur, pos, lq, NULL);
        for (k = 1; k < V; k++)
          if (lr[k] > lr[ar]) ar = k;
        for (k = 0; k < V; k++) {
          double d1 = fabs((double)lr[k] - lf[k]), d2 = fabs((double)lq[k] - lf[k]);
          if (d1 > emr) emr = d1;
          if (d2 > emq) emq = d2;
          ssr += d1 * d1;
          ssq += d2 * d2;
        }
        nn += V;
        top_r += ar == af;
        top_q += aq == af;
        npos++;
        next = pos < nt - 1 ? tok[pos + 1] : af;
        if (pos >= nt - 1) {
          if (dr < 0 && ar != next) dr = pos - (nt - 1);
          if (dq < 0 && aq != next) dq = pos - (nt - 1);
        }
        if (next == 1) break;
        cur = next;
      }
      if (dr >= 0) { divr += dr; ndr++; }
      if (dq >= 0) { divq += dq; ndq++; }
    }
    P("model: prompts %d positions %ld\n", np, npos);
    P("runq  vs F: logits max abs %.4f rms %.4f top1 %.2f%% diverged %ld/%d mean div pos %.1f\n", emr,
      sqrt(ssr / nn), 100.0 * top_r / npos, ndr, np, ndr ? (double)divr / ndr : -1.0);
    P("ours Qg vs F: logits max abs %.4f rms %.4f top1 %.2f%% diverged %ld/%d mean div pos %.1f\n",
      emq, sqrt(ssq / nn), 100.0 * top_q / npos, ndq, np, ndq ? (double)divq / ndq : -1.0);
  }
  if (OUT) fclose(OUT);
  return 0;
}
