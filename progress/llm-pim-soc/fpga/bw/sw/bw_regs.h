/*
 * bw_regs.h: register map of the HP bandwidth measurement IP (rtl/l3/bw_top.sv).
 * Source of truth: docs/spec/bwtest.md. Byte offsets from BW_BASEADDR.
 */
#ifndef BW_REGS_H
#define BW_REGS_H

#ifndef BW_BASEADDR
#define BW_BASEADDR 0x43C00000u /* create_project.tcl BW_BASEADDR */
#endif

#define BW_ID        0x00u /* R   0x42570001 */
#define BW_CONFIG    0x04u /* R   [7:0] FCLK_MHZ [11:8] P [19:12] OUTS [28:20] MAX_BURST */
#define BW_CTRL      0x08u /* W   bit0 start, [5:4] op */
#define BW_STATUS    0x0Cu /* R   bit0 busy, bit1 done_sticky, bit2 err_any */
#define BW_ERR       0x10u /* R/W1C */
#define BW_CYCLES    0x14u /* R   cycles of the last op */
#define BW_RD_STALL  0x18u /* R   = port 0 RD_STALL */
#define BW_WR_STALL  0x1Cu /* R   = port 0 WR_STALL */
#define BW_OPS       0x20u /* R   completed ops */
#define BW_LEN       0x40u /* RW  bytes per port */
#define BW_BURST     0x44u /* RW  beats per burst 1..MAX_BURST */
#define BW_OUTS      0x48u /* RW  outstanding bursts 1..OUTS */
#define BW_PORTS     0x4Cu /* RW  port enable mask */
#define BW_SEED_LO   0x50u
#define BW_SEED_HI   0x54u
#define BW_RD_ADDR(p) (0x60u + 4u * (unsigned)(p))
#define BW_WR_ADDR(p) (0x68u + 4u * (unsigned)(p))
/* per-port results */
#define BW_RES(p, i)  (0x80u + 0x20u * (unsigned)(p) + 4u * (unsigned)(i))
#define BW_R_XOR_LO 0
#define BW_R_XOR_HI 1
#define BW_R_SUM_LO 2
#define BW_R_SUM_HI 3
#define BW_R_RD_CYC 4
#define BW_R_WR_CYC 5
#define BW_R_RD_STALL 6
#define BW_R_WR_STALL 7
#define BW_RD_BEATS(p) (0xC0u + 8u * (unsigned)(p))
#define BW_WR_BEATS(p) (0xC4u + 8u * (unsigned)(p))

#define BW_ID_VALUE 0x42570001u
#define BW_OP_RD 1u
#define BW_OP_WR 2u
#define BW_OP_RW 3u
#define BW_CTRL_START(op) ((((op) & 3u) << 4) | 1u)

#define BW_ST_BUSY 0x1u
#define BW_ST_DONE 0x2u
#define BW_ST_ERR  0x4u

#define BW_E_START_BUSY 0x01u
#define BW_E_BAD_OP     0x02u
#define BW_E_BAD_DESC   0x04u
#define BW_E_RD_RESP    0x08u
#define BW_E_WR_RESP    0x10u
#define BW_E_ENG_CMD    0x20u

#define BW_CFG_FCLK(c)  ((c) & 0xFFu)
#define BW_CFG_P(c)     (((c) >> 8) & 0xFu)
#define BW_CFG_OUTS(c)  (((c) >> 12) & 0xFFu)
#define BW_CFG_MAXB(c)  (((c) >> 20) & 0x1FFu)

/* write pattern: beat k of port p = {SEED_HI ^ p, SEED_LO} + k * BW_PAT_INC (mod 2^64) */
#define BW_PAT_INC 0x9E3779B97F4A7C15ull

/* DDR buffers of the PS program (physical = HP address). Inside the HP DDR segment checked by
 * create_project.tcl (0x10000000 .. 0x20000000). 32 MiB apart, BW_MAXLEN usable each. */
#define BW_BUF_RD(p) (0x10000000u + 0x02000000u * (unsigned)(p))
#define BW_BUF_WR(p) (0x14000000u + 0x02000000u * (unsigned)(p))
#define BW_MAXLEN    (8u * 1024u * 1024u + 4096u)

#endif
