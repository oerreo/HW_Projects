/*
 * BPE tokenizer for the llama2.c tokenizer file format (max_len, then per token:
 * float score, int len, bytes). Behaviour follows the reference encoder: optional
 * BOS, a dummy-prefix space for non-empty text, UTF-8 code points with byte
 * fallback (+3), then greedy merging of the highest-scoring adjacent pair.
 */
#include <ctype.h>
#include <string.h>
#include "llm.h"

static int rd32(const unsigned char *p) {
  int32_t v;
  memcpy(&v, p, 4);
  return v;
}

int lm_tok_init(lm_tok_t *t, const void *img, size_t len, int vocab, lm_arena_t *a) {
  const unsigned char *p = (const unsigned char *)img, *end = p + len;
  size_t total = 0;
  const unsigned char *q;
  char *strs;
  int i, gap;
  if (len < 4) return -1;
  /* sizing scan */
  q = p + 4;
  for (i = 0; i < vocab; i++) {
    int l;
    if (q + 8 > end) return -2;
    l = rd32(q + 4);
    if (l < 0 || q + 8 + l > end) return -2;
    total += (size_t)l + 1;
    q += 8 + l;
  }
  t->n = vocab;
  t->maxlen = rd32(p);
  t->vocab = lm_take(a, sizeof(char *) * vocab);
  t->score = lm_take(a, sizeof(float) * vocab);
  t->sorted = lm_take(a, sizeof(int) * vocab);
  t->buf = lm_take(a, (size_t)t->maxlen * 2 + 3);
  strs = lm_take(a, total);
  if (!a->base) return 0;
  if (a->fail) return -3;
  for (i = 0; i < 256; i++) {
    t->bytes[2 * i] = (unsigned char)i;
    t->bytes[2 * i + 1] = 0;
  }
  q = p + 4;
  for (i = 0; i < vocab; i++) {
    int l = rd32(q + 4);
    memcpy(&t->score[i], q, 4);
    memcpy(strs, q + 8, (size_t)l);
    strs[l] = 0;
    t->vocab[i] = strs;
    strs += l + 1;
    q += 8 + l;
    t->sorted[i] = i;
  }
  /* shell sort of ids by string */
  for (gap = vocab / 2; gap > 0; gap /= 2) {
    for (i = gap; i < vocab; i++) {
      int v = t->sorted[i], j = i;
      while (j >= gap && strcmp(t->vocab[t->sorted[j - gap]], t->vocab[v]) > 0) {
        t->sorted[j] = t->sorted[j - gap];
        j -= gap;
      }
      t->sorted[j] = v;
    }
  }
  return 0;
}

static int lookup(const lm_tok_t *t, const char *s) {
  int lo = 0, hi = t->n - 1;
  while (lo <= hi) {
    int mid = (lo + hi) / 2, c = strcmp(t->vocab[t->sorted[mid]], s);
    if (c == 0) return t->sorted[mid];
    if (c < 0) lo = mid + 1;
    else hi = mid - 1;
  }
  return -1;
}

void lm_tok_encode(lm_tok_t *t, const char *text, int bos, int eos, int *tokens, int *n) {
  char *buf = t->buf;
  size_t blen = 0;
  const char *c;
  *n = 0;
  if (bos) tokens[(*n)++] = 1;
  if (text[0] != '\0') tokens[(*n)++] = lookup(t, " ");
  for (c = text; *c != '\0'; c++) {
    int id;
    if ((*c & 0xC0) != 0x80) blen = 0;
    buf[blen++] = *c;
    buf[blen] = '\0';
    if ((*(c + 1) & 0xC0) == 0x80 && blen < 4) continue;
    id = lookup(t, buf);
    if (id != -1) {
      tokens[(*n)++] = id;
    } else {
      size_t i;
      for (i = 0; i < blen; i++) tokens[(*n)++] = (unsigned char)buf[i] + 3;
    }
    blen = 0;
  }
  for (;;) {
    float best = -1e10f;
    int best_id = -1, best_i = -1, i;
    for (i = 0; i < *n - 1; i++) {
      size_t la = strlen(t->vocab[tokens[i]]);
      int id;
      memcpy(buf, t->vocab[tokens[i]], la);
      strcpy(buf + la, t->vocab[tokens[i + 1]]);
      id = lookup(t, buf);
      if (id != -1 && t->score[id] > best) {
        best = t->score[id];
        best_id = id;
        best_i = i;
      }
    }
    if (best_i == -1) break;
    tokens[best_i] = best_id;
    for (i = best_i + 1; i < *n - 1; i++) tokens[i] = tokens[i + 1];
    (*n)--;
  }
  if (eos) tokens[(*n)++] = 2;
}

static int hexv(char ch) {
  if (ch >= '0' && ch <= '9') return ch - '0';
  if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
  if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
  return -1;
}

const char *lm_tok_decode(const lm_tok_t *t, int prev, int tok) {
  const char *piece = t->vocab[tok];
  if (prev == 1 && piece[0] == ' ') piece++;
  if (piece[0] == '<' && piece[1] == '0' && piece[2] == 'x') {
    int h0 = hexv(piece[3]);
    if (h0 >= 0) {
      int h1 = hexv(piece[4]), v = h1 >= 0 ? h0 * 16 + h1 : h0;
      return (const char *)t->bytes + v * 2;
    }
  }
  return piece;
}

int lm_tok_printable(const char *piece) {
  if (piece == NULL || piece[0] == '\0') return 0;
  if (piece[1] == '\0') {
    unsigned char b = (unsigned char)piece[0];
    if (!(isprint(b) || isspace(b))) return 0;
  }
  return 1;
}
