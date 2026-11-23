/*
 * Host C models of the four IPs (S5-1, system.md 3.1). Written from the IP spec documents
 * (docs/spec/gemv_acc.md, pim.md, attn.md, vec.md): register maps, descriptor checks, ERR
 * (W1C), STATUS, command FIFO (PIM). An op completes inside the CTRL write. Results are
 * computed with the golden functions of model/src from the buffers at the addresses the
 * registers name (row records, bank image, q records, KV layout), so a wrong layout or address
 * in the driver gives a wrong result. CYCLES follows the closed forms of the documents (memory
 * model latency 1, no stall); where a document has no closed form the value is an estimate
 * (see each model). These are not RTL and not board numbers.
 */
#ifndef IPM_H
#define IPM_H
#include <stddef.h>
#include <stdint.h>

/* DDR of the cache model (hal_cache.c). mem_rd/mem_wr return a pointer into the DDR image or
   NULL (bus error: address outside the modelled DDR); they also run the IP-side coherence
   checks (the IP reads a byte the CPU has written but not flushed; the IP writes into a line
   that holds unflushed CPU data). */
const uint8_t *mem_rd(uint32_t pa, uint32_t n);
uint8_t *mem_wr(uint32_t pa, uint32_t n);
/* the DDR image without coherence checks (testbench reads only), NULL outside */
const uint8_t *mem_peek(uint32_t pa, uint32_t n);

/* injected IP fault for the op starting now on this slot: 0 none, 1 RD_RESP, 2 never ends */
int ipm_fault(int slot);

typedef struct {
  uint32_t (*rd)(uint32_t off);
  void (*wr)(uint32_t off, uint32_t v);
  int (*init)(void);
} ipm_t;
extern const ipm_t IPM_GA, IPM_PI, IPM_AT, IPM_VE;

/* modelled build: SX_BUILD A (default) or P or 0 (no IP); single overrides SX_VE_NMAX,
   SX_AT_HSMAX for the guard tests */
typedef struct {
  int fclk;
  int ga_p, ga_nmax;
  int pi_nb, pi_depth, pi_cmdd, pi_nmax;
  int at_hpar, at_kvsrc, at_hsmax, at_tmax, at_nkv, at_nl, at_kw, at_vw;
  int ve_nmax, ve_idxw;
} ipcfg_t;
extern ipcfg_t IPC;

/* scratch memory of the models, grows as needed (index = independent buffer) */
void *ipm_scr(int i, size_t n);
/* AXI burst split of n beats from addr: at most 16 beats and no 4 KiB crossing */
int ipm_nburst(uint32_t addr, uint32_t beats, uint32_t *last);

#endif
