/*
 * Host (PC, gcc) implementation of plat.h for the host test. Not part of the board
 * build. Images that the board finds at fixed DDR addresses are files here, listed
 * in the file named by the DDRMAP environment variable ("0xADDR path" per line).
 */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "out.h"
#include "plat.h"

#define NMAP 8
static struct {
  uint32_t addr;
  void *p;
  size_t n;
} map[NMAP];
static int nmap;
static void *arena;

static void *load(const char *path, size_t *n) {
  FILE *f = fopen(path, "rb");
  long len;
  void *p;
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  len = ftell(f);
  fseek(f, 0, SEEK_SET);
  p = malloc((size_t)len + 64);
  if (p && fread(p, 1, (size_t)len, f) != (size_t)len) {
    free(p);
    p = NULL;
  }
  fclose(f);
  *n = (size_t)len;
  return p;
}

void plat_init(void) {
  const char *mp = getenv("DDRMAP");
  FILE *f;
  char line[1024];
  if (!mp || !(f = fopen(mp, "r"))) return;
  while (nmap < NMAP && fgets(line, sizeof(line), f)) {
    unsigned long a;
    char path[1000];
    if (line[0] == '#' || sscanf(line, "%lx %999s", &a, path) != 2) continue;
    map[nmap].addr = (uint32_t)a;
    map[nmap].p = load(path, &map[nmap].n);
    if (map[nmap].p) nmap++;
  }
  fclose(f);
}

const char *plat_name(void) { return "host"; }

uint64_t plat_now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
}

uint64_t plat_tps(void) { return 1000000000u; }
uint32_t plat_cyc(void) { return (uint32_t)plat_now(); }
void plat_putc(int c) { putchar(c); }
void plat_cache_flush(void) {}

int plat_info(void) {
  o_key("PLAT");
  o_s("name", "host");
  o_s("timer", "clock_monotonic_ns");
  o_u("ddr_images", (uint64_t)nmap);
  o_end();
  return 0;
}

const void *plat_ddr(uint32_t addr, uint32_t len) {
  int i;
  for (i = 0; i < nmap; i++)
    if (map[i].addr == addr) return map[i].n >= len ? map[i].p : NULL;
  return NULL;
}

void *plat_arena(size_t need, size_t *cap) {
  free(arena);
  arena = malloc(need);
  *cap = arena ? need : 0;
  return arena;
}

uint32_t plat_prog_top(void) { return 0; }

void plat_exit(int rc) {
  fflush(stdout);
  exit(rc);
}
