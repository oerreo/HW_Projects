/*
 * Register offsets and bit fields of the four kernel IPs as seen through the L4 control
 * crossbar (system.md 1.4: one 4 KiB slot per IP kind). The source of every value is the IP
 * spec document named next to each block (docs/spec/gemv_acc.md 2, pim.md 2-3, attn.md 3,
 * vec.md 3). Nothing here is taken from the RTL.
 */
#ifndef IPREGS_H
#define IPREGS_H

/* ---- L4 address map (system.md 1.4) ---- */
#define SYS_BASE 0x43C00000u
#define SYS_SLOT_SZ 0x1000u
#define SYS_NSLOT 16
enum { SLOT_GA = 0, SLOT_PI = 1, SLOT_AT = 2, SLOT_VE = 3, SLOT_N = 4 };

/* ---- common frame (arch.md 7.2, the same in all four documents) ---- */
#define R_ID 0x00u
#define R_CONFIG 0x04u
#define R_CTRL 0x08u
#define R_STATUS 0x0Cu
#define R_ERR 0x10u
#define R_CYCLES 0x14u
#define R_RD_STALL 0x18u
#define R_WR_STALL 0x1Cu
#define R_OPS 0x20u
#define ST_BUSY 0x1u
#define ST_DONE 0x2u
#define ST_ERR 0x4u
#define CTRL_GO(op) ((((uint32_t)(op)) << 4) | 1u)

/* ---- gemv_acc_top (gemv_acc.md 2) ---- */
#define GA_ID 0x47410001u
#define GA_W_ADDR 0x40u
#define GA_X_ADDR 0x44u
#define GA_Y_ADDR 0x48u
#define GA_ROWS 0x4Cu
#define GA_N 0x50u
#define GA_XM 0x54u
#define GA_EXP 0x58u   /* [7:0] we, [15:8] xe, [23:16] fo, signed 8 bit each */
#define GA_FLAGS 0x5Cu /* bit0 argmax_en, bit1 y_en */
#define GA_AM_IDX 0x60u
#define GA_AM_VAL 0x64u
#define GA_OP_GEMV 1u
#define GA_F_ARGMAX 0x1u
#define GA_F_YEN 0x2u
/* ERR bits: 0 START_BUSY, 1 BAD_OP, 2 BAD_DESC, 3 MISALIGN, 4 RD_RESP, 5 WR_RESP */
#define GA_CFG_FCLK(c) ((c) & 0xFFu)
#define GA_CFG_P(c) (((c) >> 8) & 0xFu)
#define GA_CFG_NMAX(c) ((c) >> 16)

/* ---- pim_top (pim.md 2, 3) ---- */
#define PI_ID 0x50490001u
#define PI_CONFIG2 0x24u /* [15:0] DEPTH, [31:16] CMD_DEPTH */
#define PI_CMD0 0x40u    /* [3:0] op, [15:4] n, [31:16] rows */
#define PI_CMD1 0x44u    /* [16:0] xm, [31:17] base */
#define PI_CMD2 0x48u    /* DDR address */
#define PI_CMD3 0x4Cu    /* [7:0] we, [15:8] xe, [23:16] fo */
#define PI_CMD_PUSH 0x50u
#define PI_ST_WRGB 0x60u
#define PI_ST_MAC 0x64u
#define PI_ST_RDMAC 0x68u
#define PI_N_LDW 0x6Cu
#define PI_N_WRGB 0x70u
#define PI_N_MACAB 0x74u
#define PI_C_LDW 1u
#define PI_C_WRGB 2u
#define PI_C_MACAB 3u
#define PI_OP_RUN 1u
#define PI_OP_FLUSH 2u
#define PI_ST_PUSHBUSY 0x8u
#define PI_ST_LEVEL(s) (((s) >> 8) & 0xFFFFu)
/* ERR bits: 0 START_BUSY, 1 BAD_OP, 2 BAD_CMD, 3 BAD_DESC, 4 MISALIGN, 5 RD_RESP, 6 WR_RESP,
   7 FIFO_OVF, 8 PUSH_BUSY */
#define PI_CFG_NB(c) (((c) >> 8) & 0xFu)
#define PI_CFG_LB(c) (1u << (((c) >> 12) & 0xFu))
#define PI_CFG_NMAX(c) ((c) >> 16)
#define PI_CFG2_DEPTH(c) ((c) & 0xFFFFu)
#define PI_CFG2_CMDD(c) ((c) >> 16)

/* ---- attn_top (attn.md 3) ---- */
#define AT_ID 0x41540001u
#define AT_CONFIG2 0x24u /* [7:0] HS_MAX, [15:8] NKV, [23:16] NL (KV_SRC 1: [31:8] = 0) */
#define AT_CONFIG3 0x28u /* [7:0] KW, [15:8] VW, [31:16] TMAX (KV_SRC 1: 0) */
#define AT_Q_ADDR 0x40u
#define AT_O_ADDR 0x44u
#define AT_P_ADDR 0x48u
#define AT_K_ADDR 0x4Cu
#define AT_V_ADDR 0x50u
#define AT_KS_ADDR 0x54u
#define AT_VS_ADDR 0x58u
#define AT_T 0x5Cu     /* [15:0] */
#define AT_HS 0x60u    /* [7:0] */
#define AT_FMT 0x64u   /* [4:0] kb, [12:8] vb, [16] p_en */
#define AT_HEAD 0x68u  /* [7:0] HEAD0, [15:8] NHEAD, [23:16] KVMUL */
#define AT_LAYER 0x6Cu /* [7:0] */
#define AT_SEQ 0x70u   /* [15:0] */
#define AT_POS 0x74u   /* [15:0] */
#define AT_KVH 0x78u   /* [7:0] KVH0, [15:8] NKVH */
#define AT_OP_ATTN 1u
#define AT_OP_KVW 2u
#define AT_CFG_HPAR(c) (((c) >> 8) & 0x7u)
#define AT_CFG_KVSRC(c) (((c) >> 11) & 0x1u)
#define AT_CFG_KL(c) (1u << (((c) >> 12) & 0xFu))
#define AT_CFG_TMAX(c) ((c) >> 16)

/* ---- vec_top (vec.md 3) ---- */
#define VE_ID 0x56450001u
#define VE_AM_IDX 0x24u
#define VE_AM_VAL 0x28u
#define VE_IN0 0x40u
#define VE_IN1 0x44u
#define VE_OUT 0x48u
#define VE_SCL 0x4Cu
#define VE_N 0x50u
#define VE_FMT 0x54u  /* [15:0] qmax, [16] mode (1 = MANT), [27:24] sb; reset 0x0801007F */
#define VE_EXP 0x58u  /* [7:0] f (ACTQ f, RMSNORM fy), [15:8] ge */
#define VE_EPSC 0x5Cu
#define VE_OP_RMS 1u
#define VE_OP_SWI 2u
#define VE_OP_ACTQ 3u
#define VE_OP_AMAX 4u
#define VE_CFG_IDXW(c) (((c) >> 8) & 0xFFu)
#define VE_CFG_NMAX(c) ((c) >> 16)

/* ERR bit names shared by the log (index = bit) */
#define ERR_RD_RESP_GA 0x10u
#define ERR_WR_RESP_GA 0x20u

#endif
