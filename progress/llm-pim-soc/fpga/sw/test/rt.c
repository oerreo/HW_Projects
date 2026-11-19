/* bin2c round trip: writes the compiled-in arrays back to build/rt_ck.bin, rt_tk.bin */
#include <stdint.h>
#include <stdio.h>

extern const unsigned char m1_ck[], m1_tk[];
extern const uint32_t m1_ck_len, m1_tk_len;

static int put(const char *path, const unsigned char *p, uint32_t n) {
  FILE *f = fopen(path, "wb");
  if (!f) return 1;
  if (fwrite(p, 1, n, f) != n) {
    fclose(f);
    return 1;
  }
  return fclose(f) != 0;
}

int main(void) {
  return put("build/rt_ck.bin", m1_ck, m1_ck_len) | put("build/rt_tk.bin", m1_tk, m1_tk_len);
}
