// ntt_ctrl: schedule controller of pqc-ntt-ip (L2). Pure control: FSM,
// counters, address generation, enables and selects. It holds no coefficient
// data. The data registers (basemul operands A0, A1, B0, B1 and temporaries
// R0, R1) and the data muxes live in the ntt_core datapath glue (L3), which
// decodes the selects below. Reason: ntt_core is the level that owns the
// datapath between its sub-modules (coef_ram x2, zeta_rom, bfu); keeping
// ntt_ctrl data-free makes it independent of the coefficient width and lets
// it be verified on schedule properties alone.
//
// Spec: docs/spec/arch.md ("decisions", "operating modes", "address and zeta
// order", "basemul sequence", "basemul datapath requirements", "bfu pipeline").
// Golden schedule: mlkem_dpi_hw_sched, mlkem_dpi_basemul_nops / _op.
//
// ============================================================================
// Operations (start_i accepted when busy_o = 0; ignored while busy_o = 1)
// ============================================================================
//   op_i        bank_i            effect                                result_bank_o
//   OP_LOAD     target bank       256 stream words -> bank[0..255]      bank_i
//   OP_NTT      input bank        7 CT layers, ping-pong                ~bank_i
//   OP_INTT     input bank        7 GS layers, ping-pong (1/2 per layer) ~bank_i
//   OP_BASEMUL  ignored           bank0 = a (x) b, b in bank1           0
//   OP_UNLOAD   source bank       bank[0..255] -> 256 stream words      bank_i
// busy_o is 1 from the cycle after start_i is accepted until the op is
// complete. done_o is a 1-cycle pulse in the first cycle with busy_o = 0
// again; all RAM writes of the op are committed by then (a read issued in the
// done_o cycle sees them) and start_i is accepted in that same cycle.
// result_bank_o is updated with done_o and holds until the next done_o.
// An illegal op_i encoding is not accepted (assertion L2_CTRL_OP).
//
// ============================================================================
// Pipeline stages and output timing
// ============================================================================
// Every RAM/ROM/bfu action of NTT, INTT and BASEMUL is generated in an issue
// cycle I and travels down fixed delay lines:
//   I                     RAM read (addresses, en)                 issue stage
//   I + RAM_LAT - ROM_LAT ROM read (rom_en_o, kind, addr)          D_ROM
//   I + RAM_LAT = E       bfu valid, mode, a/b/z selects,          D_EXEC
//                         rd_bank_o, opnd_ld_o
//   E + BFU_LATENCY = W   RAM write (we, addr), tmp_ld_o            D_WB = RAM_LAT + BFU_LATENCY
// so RAM read data, ROM data and bfu inputs meet in cycle E, and the bfu
// output of an input given in E is written in W.
//
//   output            cycle valid   meaning (ntt_core action)
//   ram_en_a_o[k]     I, W, LOAD/   port A of bank k accessed
//                     UNLOAD cycle
//   ram_we_a_o[k]     W, LOAD       port A of bank k writes (else reads)
//   ram_addr_a_o[k]   with en       port A address
//   ram_en_b_o[k],    I, W          port B of bank k (NTT/INTT read and write,
//   ram_we_b_o[k],                  basemul operand read)
//   ram_addr_b_o[k]
//   ram_wsrc_o        with we_a     port A write data: WSRC_BFU = bfu x_o,
//                                   WSRC_STREAM = s_data (LOAD). Port B write
//                                   data is always bfu y_o.
//   rom_en_o,         E - ROM_LAT   zeta_rom read (kind_i, addr_i, en_i)
//   rom_kind_o,
//   rom_addr_o
//   bfu_valid_o       E             bfu valid_i
//   bfu_mode_o        E             bfu mode_i (CT: NTT, BASEMUL; GS: INTT)
//   bfu_a_sel_o       E             bfu a_i = RAM: rdata_a of bank rd_bank_o |
//                                   ZERO | R0
//   bfu_b_sel_o       E             bfu b_i = RAM: rdata_b of bank rd_bank_o |
//                                   A0 | A1 | R0 | R1
//   bfu_z_sel_o       E             bfu z_i = ROM: zeta_rom data_o | B0 | B1
//   rd_bank_o         E, UNLOAD     bank whose read data feeds bfu RAM inputs;
//                                   during UNLOAD the bank of the out stream
//   opnd_ld_o         E             load A0 <= bank0 rdata_a, A1 <= bank0
//                                   rdata_b, B0 <= bank1 rdata_a,
//                                   B1 <= bank1 rdata_b
//   tmp_ld_o[j]       W             load Rj <= bfu x_o (j = 0, 1)
//   s_ready_o         LOAD          input stream ready; a handshake writes
//                                   s_data to bank bank_i port A in that cycle
//   m_valid_o         UNLOAD        output stream valid; m_data = rdata_a of
//                                   bank rd_bank_o (held by the RAM)
// Selects are don't-care while their valid/enable is 0 (they are driven to
// the reset value of the delay line, never X after reset).
//
// ============================================================================
// NTT / INTT schedule (one butterfly per cycle)
// ============================================================================
// Layer l = 0..6 reads bank rb = bank_i ^ l[0] (both ports) and writes the
// other bank; each layer issues 128 butterflies at consecutive cycles.
// Step s = 0..127 inside a layer, mask = len - 1:
//   addr0 = {s & ~mask, 0} | (s & mask)   (insert a 0 bit at position log2 len)
//   addr1 = addr0 | len
//   zeta  : NTT starts at 1 and increments at the end of each group of len
//           butterflies, INTT starts at 127 and decrements (FIPS 203 Alg. 9,
//           Alg. 10). len: NTT 128 .. 2 (mask >> 1 per layer), INTT 2 .. 128
//           (mask << 1 | 1 per layer).
// Layer boundary: the first read of layer l+1 is issued in the cycle after
// the last write of layer l (D_WB idle issue cycles). Since layer l+1 reads
// the bank layer l wrote, no read sees a stale word and no cycle reads and
// writes the same bank. The op ends D_WB cycles after the last issue.
//
// ============================================================================
// BASEMUL schedule (pairs sequential, no op overlap)
// ============================================================================
// Program (5 ops when S = 1, 7 ops otherwise) as in arch.md / golden
// basemul_program; all ops are CT, only bfu x_o is used.
// Ops are issued every SLOT = BFU_LATENCY + 1 cycles: the result of op k is
// loaded into R0/R1 (or written to bank0) in its W cycle, op k+1 executes in
// the next cycle. Pair i reads its operands in one cycle (bank0 A/B = 2i,
// 2i+1 -> A0, A1; bank1 A/B = 2i, 2i+1 -> B0, B1). The read of pair i+1 is
// issued in the last cycle before op 0 of pair i+1 (that is, in the cycle of
// the last op of pair i when SLOT = 1), so the operand registers change only
// after the last op of pair i has executed and the pair period is
// NOPS * SLOT cycles. C0 / C1 are written to bank0 port A at 2i / 2i+1.
// With RAM_LAT = 1, the read of pair i+1 never falls on the C0 / C1 write
// cycles of pair i (C1: one cycle later; C0: at least 2 * SLOT - 1 cycles
// earlier); assertion L2_CTRL_PORT checks every bank port each cycle.
//
// ============================================================================
// LOAD / UNLOAD
// ============================================================================
// LOAD: s_ready_o = 1 for the whole op; each handshake writes the word to the
// next address (0..255) in the same cycle. Done after 256 handshakes.
// UNLOAD: read-ahead through the RAM output register, which acts as a
// one-entry pipeline stage with enable (coef_ram "no change" read data):
//   issue a read of the next address when words remain and the stage is
//   empty or being emptied (m_valid_o = 0 or m_ready_i = 1);
//   m_valid_o = stage full. While m_valid_o = 1 and m_ready_i = 0 no read is
//   issued, the RAM holds rdata, so m_data stays stable (AXI4-Stream rule).
// Full throughput (1 word / cycle) with no skid buffer; the cost is a
// combinational path m_ready_i -> ram_en_a_o (a register slice can be added at
// L4 if timing needs it). Done in the cycle after the last handshake.
//
// Parameters: all timing is derived from RAM_LAT, ROM_LAT, BFU_LATENCY.
module ntt_ctrl
  import mlkem_pkg::*;
  import ntt_l2_pkg::*;
#(
  parameter algo_e ALGO        = ALGO_BARRETT, // selects the basemul program (5 / 7 ops)
  parameter int    BFU_LATENCY = 0,            // bfu LATENCY, 0..BFU_LATENCY_MAX
  parameter int    RAM_LAT     = 1,            // coef_ram read latency (only 1 supported)
  parameter int    ROM_LAT     = 1             // zeta_rom LATENCY, 0..RAM_LAT
) (
  input  logic                  clk,
  input  logic                  rst_n,          // async assert, sync deassert
  // command / status
  input  logic                  start_i,
  input  op_e                   op_i,
  input  logic                  bank_i,
  output logic                  busy_o,
  output logic                  done_o,
  output logic                  result_bank_o,
  // stream handshakes (data paths are in ntt_core)
  input  logic                  s_valid_i,
  output logic                  s_ready_o,
  output logic                  m_valid_o,
  input  logic                  m_ready_i,
  // coef_ram control, index = bank
  output logic [1:0]            ram_en_a_o,
  output logic [1:0]            ram_we_a_o,
  output logic [1:0][RAM_AW-1:0] ram_addr_a_o,
  output logic [1:0]            ram_en_b_o,
  output logic [1:0]            ram_we_b_o,
  output logic [1:0][RAM_AW-1:0] ram_addr_b_o,
  output wsrc_e                 ram_wsrc_o,
  // zeta_rom control
  output logic                  rom_en_o,
  output rom_kind_e             rom_kind_o,
  output logic [ROM_AW-1:0]     rom_addr_o,
  // bfu control and datapath selects
  output logic                  bfu_valid_o,
  output mode_e                 bfu_mode_o,
  output a_sel_e                bfu_a_sel_o,
  output b_sel_e                bfu_b_sel_o,
  output z_sel_e                bfu_z_sel_o,
  output logic                  rd_bank_o,
  output logic                  opnd_ld_o,
  output logic [1:0]            tmp_ld_o
);

  // --------------------------------------------------------------------------
  // Derived timing
  // --------------------------------------------------------------------------
  localparam int D_EXEC  = RAM_LAT;                 // issue -> bfu input
  localparam int D_ROM   = RAM_LAT - ROM_LAT;       // issue -> ROM read
  localparam int D_WB    = RAM_LAT + BFU_LATENCY;   // issue -> write back
  localparam int BM_NOPS = basemul_nops(ALGO);
  localparam int SLOT    = BFU_LATENCY + 1;         // basemul op spacing
  localparam int WAIT_W  = $clog2(D_WB + 1);
  localparam int SLOT_W  = (SLOT > 1) ? $clog2(SLOT) : 1;
  localparam int CNT_W   = $clog2(N_COEF + 1);      // 0..256
  localparam int STEP_W  = $clog2(N_PAIR);          // 7
  localparam int OPI_W   = 3;

  if (RAM_LAT != 1) begin : g_bad_ram_lat
    $error("ntt_ctrl: RAM_LAT=%0d not supported (1)", RAM_LAT);
  end
  if (ROM_LAT < 0 || ROM_LAT > RAM_LAT) begin : g_bad_rom_lat
    $error("ntt_ctrl: ROM_LAT=%0d not supported (0..RAM_LAT=%0d)", ROM_LAT, RAM_LAT);
  end
  if (BFU_LATENCY < 0 || BFU_LATENCY > BFU_LATENCY_MAX) begin : g_bad_bfu_lat
    $error("ntt_ctrl: BFU_LATENCY=%0d not supported (0..%0d)", BFU_LATENCY, BFU_LATENCY_MAX);
  end
  if (BM_NOPS > (1 << OPI_W)) begin : g_bad_nops
    $error("ntt_ctrl: basemul program longer than the op counter");
  end
  if (N_LAYER % 2 != 1) begin : g_bad_layers
    $error("ntt_ctrl: result bank rule assumes an odd number of layers");
  end

  // --------------------------------------------------------------------------
  // basemul program (arch.md "basemul sequence", golden basemul_program)
  // --------------------------------------------------------------------------
  typedef enum logic [1:0] { DST_R0 = 2'd0, DST_R1 = 2'd1, DST_C0 = 2'd2, DST_C1 = 2'd3 } dst_e;
  typedef enum logic [1:0] { ZS_B0 = 2'd0, ZS_B1 = 2'd1, ZS_GAMMA = 2'd2, ZS_K2 = 2'd3 } zsrc_e;

  typedef struct packed {
    a_sel_e a;
    b_sel_e b;
    zsrc_e  z;
    dst_e   dst;
  } bm_op_t;

  function automatic bm_op_t bm_op(input logic [OPI_W-1:0] idx);
    bm_op_t r;
    r = '{a: ASEL_ZERO, b: BSEL_A0, z: ZS_B0, dst: DST_R0};
    if (BM_NOPS == 5) begin
      // S = 1: t = a1 b1; p = t gamma; c0 = p + a0 b0; u = a0 b1; c1 = u + a1 b0
      unique case (idx)
        3'd0: r = '{a: ASEL_ZERO, b: BSEL_A1, z: ZS_B1,    dst: DST_R0};
        3'd1: r = '{a: ASEL_ZERO, b: BSEL_R0, z: ZS_GAMMA, dst: DST_R0};
        3'd2: r = '{a: ASEL_R0,   b: BSEL_A0, z: ZS_B0,    dst: DST_C0};
        3'd3: r = '{a: ASEL_ZERO, b: BSEL_A0, z: ZS_B1,    dst: DST_R0};
        3'd4: r = '{a: ASEL_R0,   b: BSEL_A1, z: ZS_B0,    dst: DST_C1};
        default: ;
      endcase
    end else begin
      // S != 1: t = a1 b1 S; p = t gamma2; v = a0 b0 S; c0 = p + v K2;
      //         u = a0 b1 S; w = u + a1 b0 S; c1 = w K2
      unique case (idx)
        3'd0: r = '{a: ASEL_ZERO, b: BSEL_A1, z: ZS_B1,    dst: DST_R0};
        3'd1: r = '{a: ASEL_ZERO, b: BSEL_R0, z: ZS_GAMMA, dst: DST_R0};
        3'd2: r = '{a: ASEL_ZERO, b: BSEL_A0, z: ZS_B0,    dst: DST_R1};
        3'd3: r = '{a: ASEL_R0,   b: BSEL_R1, z: ZS_K2,    dst: DST_C0};
        3'd4: r = '{a: ASEL_ZERO, b: BSEL_A0, z: ZS_B1,    dst: DST_R0};
        3'd5: r = '{a: ASEL_R0,   b: BSEL_A1, z: ZS_B0,    dst: DST_R0};
        3'd6: r = '{a: ASEL_ZERO, b: BSEL_R0, z: ZS_K2,    dst: DST_C1};
        default: ;
      endcase
    end
    return r;
  endfunction

  // --------------------------------------------------------------------------
  // Pipeline command records
  // --------------------------------------------------------------------------
  typedef struct packed {
    logic   bfu_v;      // bfu input valid
    logic   ld;         // operand register load (basemul pair read)
    mode_e  mode;
    a_sel_e a_sel;
    b_sel_e b_sel;
    z_sel_e z_sel;
    logic   rbank;      // bank of the RAM read data
  } exec_t;

  typedef struct packed {
    logic              v;
    rom_kind_e         kind;
    logic [ROM_AW-1:0] addr;
  } rom_cmd_t;

  typedef struct packed {
    logic              a_v;     // port A write of bfu x_o
    logic              b_v;     // port B write of bfu y_o
    logic              bank;
    logic [RAM_AW-1:0] addr0;   // port A address
    logic [RAM_AW-1:0] addr1;   // port B address
    logic [1:0]        tmp;     // R1 / R0 load
  } wb_t;

  // --------------------------------------------------------------------------
  // State
  // --------------------------------------------------------------------------
  typedef enum logic [2:0] {
    S_IDLE   = 3'd0,
    S_LOAD   = 3'd1,
    S_UNLOAD = 3'd2,
    S_XF     = 3'd3,    // NTT / INTT butterfly issue
    S_XGAP   = 3'd4,    // layer boundary wait
    S_BMRD   = 3'd5,    // basemul: operand read of pair 0
    S_BM     = 3'd6,    // basemul: op issue
    S_DRAIN  = 3'd7     // wait for the last write
  } state_e;

  state_e             state_q, state_d;
  op_e                op_q, op_d;
  logic               bank_q, bank_d;
  logic               result_bank_q, result_bank_d;
  logic               done_q, done_d;
  logic [CNT_W-1:0]   cnt_q, cnt_d;          // LOAD / UNLOAD word count
  logic [STEP_W-1:0]  step_q, step_d;        // butterfly in layer / basemul pair
  logic [2:0]         layer_q, layer_d;
  logic [STEP_W-1:0]  mask_q, mask_d;        // len - 1
  logic [ROM_AW-1:0]  zeta_q, zeta_d;
  logic [WAIT_W-1:0]  wait_q, wait_d;
  logic [OPI_W-1:0]   opi_q, opi_d;          // basemul op index
  logic [SLOT_W-1:0]  slot_q, slot_d;        // basemul cycle within an op slot
  logic               ovld_q, ovld_d;        // UNLOAD output stage full

  // issue-stage commands
  logic               iss_rd_v;              // RAM read, port A
  logic               iss_rd_b;              // RAM read also on port B
  logic               iss_rd_all;            // read both banks (basemul operands)
  logic               iss_rd_bank;
  logic [RAM_AW-1:0]  iss_addr0, iss_addr1;  // port A / B read address
  exec_t              iss_ex;
  rom_cmd_t           iss_rom;
  wb_t                iss_wb;
  // LOAD / UNLOAD
  logic               ld_we;                 // LOAD handshake write
  logic               ul_rd;                 // UNLOAD read issue

  // NTT / INTT address generation
  logic               is_intt;
  logic [RAM_AW-1:0]  len8;
  logic [RAM_AW-1:0]  xf_addr0, xf_addr1;
  logic               grp_end, layer_end;
  // basemul
  bm_op_t             bop;
  logic               bm_op_now, bm_rd_next, bm_last;
  logic [STEP_W-1:0]  bm_rd_pair;

  assign is_intt   = (op_q == OP_INTT);
  // len = mask + 1 (one-hot), without an adder
  assign len8      = {mask_q, 1'b1} ^ {1'b0, mask_q};
  assign xf_addr0  = {step_q & ~mask_q, 1'b0} | {1'b0, step_q & mask_q};
  assign xf_addr1  = xf_addr0 | len8;
  assign grp_end   = ((step_q & mask_q) == mask_q);
  assign layer_end = (step_q == STEP_W'(N_PAIR - 1));

  assign bop        = bm_op(opi_q);
  assign bm_op_now  = (slot_q == '0);
  assign bm_rd_next = (slot_q == SLOT_W'(SLOT - 1)) && (opi_q == OPI_W'(BM_NOPS - 1))
                      && (step_q != STEP_W'(N_PAIR - 1));
  assign bm_last    = bm_op_now && (opi_q == OPI_W'(BM_NOPS - 1))
                      && (step_q == STEP_W'(N_PAIR - 1));
  assign bm_rd_pair = (state_q == S_BMRD) ? step_q : step_q + 1'b1;

  assign ld_we = (state_q == S_LOAD) && s_valid_i;
  assign ul_rd = (state_q == S_UNLOAD) && (cnt_q != CNT_W'(N_COEF)) && (!ovld_q || m_ready_i);

  // --------------------------------------------------------------------------
  // Issue stage
  // --------------------------------------------------------------------------
  always_comb begin
    iss_rd_v    = 1'b0;
    iss_rd_b    = 1'b0;
    iss_rd_all  = 1'b0;
    iss_rd_bank = 1'b0;
    iss_addr0   = '0;
    iss_addr1   = '0;
    iss_ex      = '0;
    iss_rom     = '0;
    iss_wb      = '0;

    unique case (state_q)
      S_XF: begin
        iss_rd_v     = 1'b1;
        iss_rd_b     = 1'b1;
        iss_rd_bank  = bank_q ^ layer_q[0];
        iss_addr0    = xf_addr0;
        iss_addr1    = xf_addr1;
        iss_ex.bfu_v = 1'b1;
        iss_ex.mode  = is_intt ? MODE_GS : MODE_CT;
        iss_ex.a_sel = ASEL_RAM;
        iss_ex.b_sel = BSEL_RAM;
        iss_ex.z_sel = ZSEL_ROM;
        iss_ex.rbank = bank_q ^ layer_q[0];
        iss_rom.v    = 1'b1;
        iss_rom.kind = ROM_ZETA;
        iss_rom.addr = zeta_q;
        iss_wb.a_v   = 1'b1;
        iss_wb.b_v   = 1'b1;
        iss_wb.bank  = ~(bank_q ^ layer_q[0]);
        iss_wb.addr0 = xf_addr0;
        iss_wb.addr1 = xf_addr1;
      end
      S_BMRD, S_BM: begin
        // operand read: pair 0 in S_BMRD, pair + 1 before its op 0 in S_BM
        if (state_q == S_BMRD || bm_rd_next) begin
          iss_rd_v   = 1'b1;
          iss_rd_b   = 1'b1;
          iss_rd_all = 1'b1;
          iss_addr0  = {bm_rd_pair, 1'b0};
          iss_addr1  = {bm_rd_pair, 1'b1};
          iss_ex.ld  = 1'b1;
        end
        if (state_q == S_BM && bm_op_now) begin
          iss_ex.bfu_v = 1'b1;
          iss_ex.mode  = MODE_CT;
          iss_ex.a_sel = bop.a;
          iss_ex.b_sel = bop.b;
          unique case (bop.z)
            ZS_B0:    iss_ex.z_sel = ZSEL_B0;
            ZS_B1:    iss_ex.z_sel = ZSEL_B1;
            default:  iss_ex.z_sel = ZSEL_ROM;
          endcase
          iss_rom.v    = (bop.z == ZS_GAMMA) || (bop.z == ZS_K2);
          iss_rom.kind = (bop.z == ZS_K2) ? ROM_K2 : ROM_GAMMA;
          iss_rom.addr = (bop.z == ZS_K2) ? '0 : step_q;
          iss_wb.a_v   = (bop.dst == DST_C0) || (bop.dst == DST_C1);
          iss_wb.bank  = 1'b0;
          iss_wb.addr0 = {step_q, bop.dst == DST_C1};
          iss_wb.tmp   = {bop.dst == DST_R1, bop.dst == DST_R0};
        end
      end
      S_UNLOAD: begin
        iss_rd_v    = ul_rd;
        iss_rd_bank = bank_q;
        iss_addr0   = cnt_q[RAM_AW-1:0];
      end
      default: ;
    endcase
  end

  // --------------------------------------------------------------------------
  // Delay lines (control registers, reset)
  // --------------------------------------------------------------------------
  exec_t    ex_dl  [0:D_EXEC];
  rom_cmd_t rom_dl [0:D_ROM];
  wb_t      wb_dl  [0:D_WB];

  assign ex_dl[0]  = iss_ex;
  assign rom_dl[0] = iss_rom;
  assign wb_dl[0]  = iss_wb;

  for (genvar k = 1; k <= D_EXEC; k++) begin : g_ex_dl
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) ex_dl[k] <= '0;
      else        ex_dl[k] <= ex_dl[k-1];
    end
  end
  for (genvar k = 1; k <= D_ROM; k++) begin : g_rom_dl
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) rom_dl[k] <= '0;
      else        rom_dl[k] <= rom_dl[k-1];
    end
  end
  for (genvar k = 1; k <= D_WB; k++) begin : g_wb_dl
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) wb_dl[k] <= '0;
      else        wb_dl[k] <= wb_dl[k-1];
    end
  end

  exec_t    ex;
  rom_cmd_t rc;
  wb_t      wb;
  assign ex = ex_dl[D_EXEC];
  assign rc = rom_dl[D_ROM];
  assign wb = wb_dl[D_WB];

  // --------------------------------------------------------------------------
  // FSM and counters
  // --------------------------------------------------------------------------
  always_comb begin
    state_d       = state_q;
    op_d          = op_q;
    bank_d        = bank_q;
    result_bank_d = result_bank_q;
    done_d        = 1'b0;
    cnt_d         = cnt_q;
    step_d        = step_q;
    layer_d       = layer_q;
    mask_d        = mask_q;
    zeta_d        = zeta_q;
    wait_d        = wait_q;
    opi_d         = opi_q;
    slot_d        = slot_q;
    ovld_d        = ovld_q;

    unique case (state_q)
      S_IDLE: begin
        if (start_i && op_i inside {OP_LOAD, OP_NTT, OP_INTT, OP_BASEMUL, OP_UNLOAD}) begin
          op_d    = op_i;
          bank_d  = bank_i;
          cnt_d   = '0;
          step_d  = '0;
          layer_d = '0;
          opi_d   = '0;
          slot_d  = '0;
          ovld_d  = 1'b0;
          // NTT: len 128 first, zeta 1 up. INTT: len 2 first, zeta 127 down.
          mask_d  = (op_i == OP_INTT) ? STEP_W'(1) : STEP_W'(N_PAIR - 1);
          zeta_d  = (op_i == OP_INTT) ? ROM_AW'(ROM_DEPTH - 1) : ROM_AW'(1);
          unique case (op_i)
            OP_LOAD:    state_d = S_LOAD;
            OP_UNLOAD:  state_d = S_UNLOAD;
            OP_BASEMUL: state_d = S_BMRD;
            default:    state_d = S_XF;
          endcase
        end
      end

      S_LOAD: begin
        if (ld_we) begin
          cnt_d = cnt_q + 1'b1;
          if (cnt_q == CNT_W'(N_COEF - 1)) begin
            state_d       = S_IDLE;
            done_d        = 1'b1;
            result_bank_d = bank_q;
          end
        end
      end

      S_UNLOAD: begin
        if (ul_rd)          cnt_d  = cnt_q + 1'b1;
        if (ul_rd)          ovld_d = 1'b1;
        else if (m_ready_i) ovld_d = 1'b0;
        if (cnt_q == CNT_W'(N_COEF) && (!ovld_q || m_ready_i)) begin
          state_d       = S_IDLE;
          done_d        = 1'b1;
          result_bank_d = bank_q;
          ovld_d        = 1'b0;
        end
      end

      S_XF: begin
        step_d = step_q + 1'b1;
        if (grp_end) zeta_d = is_intt ? zeta_q - 1'b1 : zeta_q + 1'b1;
        if (layer_end) begin
          wait_d  = WAIT_W'(D_WB);
          layer_d = layer_q + 1'b1;
          mask_d  = is_intt ? {mask_q[STEP_W-2:0], 1'b1} : (mask_q >> 1);
          state_d = (layer_q == 3'(N_LAYER - 1)) ? S_DRAIN : S_XGAP;
        end
      end

      S_XGAP: begin
        wait_d = wait_q - 1'b1;
        if (wait_q == WAIT_W'(1)) state_d = S_XF;
      end

      S_BMRD: begin
        state_d = S_BM;
      end

      S_BM: begin
        slot_d = (slot_q == SLOT_W'(SLOT - 1)) ? '0 : slot_q + 1'b1;
        if (slot_q == SLOT_W'(SLOT - 1)) begin
          if (opi_q == OPI_W'(BM_NOPS - 1)) begin
            opi_d  = '0;
            step_d = step_q + 1'b1;
          end else begin
            opi_d = opi_q + 1'b1;
          end
        end
        if (bm_last) begin
          wait_d  = WAIT_W'(D_WB);
          state_d = S_DRAIN;
        end
      end

      S_DRAIN: begin
        wait_d = wait_q - 1'b1;
        if (wait_q == WAIT_W'(1)) begin
          state_d       = S_IDLE;
          done_d        = 1'b1;
          result_bank_d = (op_q == OP_BASEMUL) ? 1'b0 : ~bank_q;   // N_LAYER is odd
        end
      end

      default: state_d = S_IDLE;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q       <= S_IDLE;
      op_q          <= OP_LOAD;
      bank_q        <= 1'b0;
      result_bank_q <= 1'b0;
      done_q        <= 1'b0;
      cnt_q         <= '0;
      step_q        <= '0;
      layer_q       <= '0;
      mask_q        <= '0;
      zeta_q        <= '0;
      wait_q        <= '0;
      opi_q         <= '0;
      slot_q        <= '0;
      ovld_q        <= 1'b0;
    end else begin
      state_q       <= state_d;
      op_q          <= op_d;
      bank_q        <= bank_d;
      result_bank_q <= result_bank_d;
      done_q        <= done_d;
      cnt_q         <= cnt_d;
      step_q        <= step_d;
      layer_q       <= layer_d;
      mask_q        <= mask_d;
      zeta_q        <= zeta_d;
      wait_q        <= wait_d;
      opi_q         <= opi_d;
      slot_q        <= slot_d;
      ovld_q        <= ovld_d;
    end
  end

  // --------------------------------------------------------------------------
  // Outputs
  // --------------------------------------------------------------------------
  assign busy_o        = (state_q != S_IDLE);
  assign done_o        = done_q;
  assign result_bank_o = result_bank_q;
  assign s_ready_o     = (state_q == S_LOAD);
  assign m_valid_o     = ovld_q;
  assign ram_wsrc_o    = (state_q == S_LOAD) ? WSRC_STREAM : WSRC_BFU;

  logic [1:0] rd_k, rdb_k, wa_k, wb_k, ld_k;

  always_comb begin
    for (int k = 0; k < 2; k++) begin
      rd_k[k]  = iss_rd_v && (iss_rd_all || iss_rd_bank == 1'(k));
      rdb_k[k] = rd_k[k] && iss_rd_b;
      ld_k[k] = ld_we && (bank_q == 1'(k));
      wa_k[k] = wb.a_v && (wb.bank == 1'(k));
      wb_k[k] = wb.b_v && (wb.bank == 1'(k));

      ram_en_a_o[k]   = rd_k[k] | ld_k[k] | wa_k[k];
      ram_we_a_o[k]   = ld_k[k] | wa_k[k];
      ram_addr_a_o[k] = wa_k[k] ? wb.addr0 : ld_k[k] ? cnt_q[RAM_AW-1:0] : iss_addr0;
      ram_en_b_o[k]   = rdb_k[k] | wb_k[k];
      ram_we_b_o[k]   = wb_k[k];
      ram_addr_b_o[k] = wb_k[k] ? wb.addr1 : iss_addr1;
    end
  end

  assign rom_en_o    = rc.v;
  assign rom_kind_o  = rc.kind;
  assign rom_addr_o  = rc.addr;
  assign bfu_valid_o = ex.bfu_v;
  assign bfu_mode_o  = ex.mode;
  assign bfu_a_sel_o = ex.a_sel;
  assign bfu_b_sel_o = ex.b_sel;
  assign bfu_z_sel_o = ex.z_sel;
  assign rd_bank_o   = (state_q == S_UNLOAD) ? bank_q : ex.rbank;
  assign opnd_ld_o   = ex.ld;
  assign tmp_ld_o    = wb.tmp;

  // --------------------------------------------------------------------------
  // Simulation-only checks
  // --------------------------------------------------------------------------
`ifndef SYNTHESIS
  // One access per bank port per cycle (read, LOAD write, write back).
  always_comb begin
    if (rst_n === 1'b1) begin
      for (int k = 0; k < 2; k++) begin
        port_a_once : assert final (32'(rd_k[k]) + 32'(ld_k[k]) + 32'(wa_k[k]) <= 1)
          else $error("L2_CTRL_PORT ntt_ctrl: bank %0d port A rd=%b load=%b wb=%b in one cycle",
                      k, rd_k[k], ld_k[k], wa_k[k]);
        port_b_once : assert final (32'(rdb_k[k]) + 32'(wb_k[k]) <= 1)
          else $error("L2_CTRL_PORT ntt_ctrl: bank %0d port B rd=%b wb=%b in one cycle",
                      k, rdb_k[k], wb_k[k]);
      end
    end
  end

  always_comb begin
    if (rst_n === 1'b1 && start_i === 1'b1 && state_q == S_IDLE) begin
      op_legal : assert final (op_i inside {OP_LOAD, OP_NTT, OP_INTT, OP_BASEMUL, OP_UNLOAD})
        else $error("L2_CTRL_OP ntt_ctrl: illegal op_i=%0d ignored", op_i);
    end
  end
`endif

endmodule
