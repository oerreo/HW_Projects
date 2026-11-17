// tb_ntt_ctrl: self-checking testbench for the L2 schedule controller ntt_ctrl.
//
// The DUT is ntt_ctrl with ALGO, BFU_LATENCY and ROM_LAT from the TB
// parameters (RAM_LAT = 1). Around it the TB builds a behavioral datapath
// that does what the ntt_core glue will do with the ntt_ctrl outputs (header
// table of rtl/l2/ntt_ctrl.sv):
//   - two behavioral banks, 256 x 12b, 2 ports, read latency 1, "no change"
//     read data (coef_ram contract), port A write data = stream or bfu x,
//     port B write data = bfu y;
//   - ROM = golden mlkem_dpi_rom, latency ROM_LAT;
//   - operand registers A0, A1, B0, B1 (opnd_ld_o), temporaries R0, R1
//     (tmp_ld_o), bfu input muxes (a/b/z selects, rd_bank_o);
//   - bfu = golden mlkem_dpi_bfu with a fixed delay of BFU_LATENCY cycles.
// So NTT, INTT and BASEMUL really run, and the final bank contents are
// compared with the golden mlkem_dpi_hw_ntt / hw_intt / hw_basemul results.
//
// Per-cycle scoreboard (falling edge), all ops:
//   sched     NTT/INTT: every butterfly in golden order (mlkem_dpi_hw_sched):
//             read bank = bank_i ^ layer[0], port A addr0, port B addr1 (one
//             bank, both ports), zeta ROM address, mode, a/b/z = RAM/RAM/ROM,
//             rd_bank_o, write bank = the other bank with addr0 / addr1,
//             wsrc = BFU. Counts 896 / 896 / 896 per op.
//   bm_prog   BASEMUL: operand read of pair p (bank0/1 ports A/B = 2p, 2p+1),
//             each op's (a src, b src, z src incl. ROM kind and gamma
//             address = p, destination R0/R1/C0/C1) against
//             mlkem_dpi_basemul_op(ALGO, k) in program order, op count
//             128 x mlkem_dpi_basemul_nops.
//   timing    (1) bfu valid exactly RAM_LAT after the read issue of the same
//             butterfly / op, ROM read exactly ROM_LAT before the bfu valid
//             that uses it, operand load exactly RAM_LAT after the pair read;
//             (2) write / temp load exactly BFU_LATENCY after the bfu valid;
//             (4) first read of layer l+1 = last write of layer l + 1, done_o
//             = last write + 1 (no slack, no shortfall), basemul ops do not
//             overlap (next bfu valid after the previous W cycle), bfu idle
//             gap at an op boundary >= BFU_LATENCY.
//   hazard    (3) a read never targets a (bank, address) with a pending
//             write, no cycle reads and writes the same bank in NTT/INTT, the
//             write bank of a butterfly differs from its read bank, every
//             address of the write bank is written exactly once per layer;
//             basemul operand registers are not reloaded before all ops of
//             the pair executed.
//   stream    LOAD: writes only at handshakes, addresses 0..255 in order to
//             the selected bank, wsrc = STREAM, 256 words, s_ready_o only
//             during LOAD. UNLOAD: reads 0..255 in order from the selected
//             bank, output words in order and equal to the bank, m_valid_o /
//             data stable while m_ready_i = 0, exactly 256 words.
//   data      at done_o: compared banks equal the golden expectation (LOAD
//             data, hw_ntt, hw_intt, hw_basemul, unchanged banks).
//   ctrl      outputs never X after reset, no activity while idle, busy_o /
//             done_o / result_bank_o protocol.
//   bfu_in    every bfu input is known and in [0, Q) when bfu_valid_o is 1.
//
// Stimulus: per case c (6 boundary polynomials of the golden model, then
// random), with bank b = c & 1:
//   LOAD b <- f; NTT b; UNLOAD ~b; INTT ~b; NTT b; INTT ~b; UNLOAD b;
//   LOAD 0 <- a; LOAD 1 <- g; BASEMUL; UNLOAD 0; (every 3rd case) UNLOAD 1.
// Case 0 runs without stalls (no valid gaps, m_ready_i = 1) and gives the
// stall-free cycle counts. From case 1 on: LOAD valid gaps GAP_PCT %, UNLOAD
// m_ready_i low RDY_PCT %, and each op is started either "early" (start_i
// held high while the previous op is busy, so it is accepted in the done_o
// cycle) or after 0..3 idle cycles.
//
// Plusargs: +SEED=<n> (1) +N_CASES=<n> (36) +GAP_PCT=<n> (30) +RDY_PCT=<n> (30)
`timescale 1ns / 1ps

module tb_ntt_ctrl;
  import mlkem_pkg::*;
  import ntt_l2_pkg::*;
  import mlkem_dpi_pkg::*;
  import tb_util_pkg::*;

  parameter int ALGO        = 0;
  parameter int BFU_LATENCY = 0;
  parameter int ROM_LAT     = 1;

  parameter  int  RAM_LAT  = 1;       // only 1 is supported by ntt_ctrl (elaboration check)
  localparam int  L        = BFU_LATENCY;
  localparam int  N_STEPS  = N_LAYER * N_PAIR;    // 896
  localparam int  N_BOUND  = 6;
  localparam time T_CLK    = 10ns;
  localparam int  WATCHDOG = 50000;

  // --------------------------------------------------------------------------
  // DUT
  // --------------------------------------------------------------------------
  logic                   clk = 1'b0;
  logic                   rst_n = 1'b0;
  logic                   start_i = 1'b0;
  op_e                    op_i = OP_LOAD;
  logic                   bank_i = 1'b0;
  logic                   busy_o, done_o, result_bank_o;
  logic                   s_valid_i = 1'b0;
  logic                   s_ready_o;
  logic                   m_valid_o;
  logic                   m_ready_i = 1'b0;
  logic [1:0]             ram_en_a_o, ram_we_a_o, ram_en_b_o, ram_we_b_o;
  logic [1:0][RAM_AW-1:0] ram_addr_a_o, ram_addr_b_o;
  wsrc_e                  ram_wsrc_o;
  logic                   rom_en_o;
  rom_kind_e              rom_kind_o;
  logic [ROM_AW-1:0]      rom_addr_o;
  logic                   bfu_valid_o;
  mode_e                  bfu_mode_o;
  a_sel_e                 bfu_a_sel_o;
  b_sel_e                 bfu_b_sel_o;
  z_sel_e                 bfu_z_sel_o;
  logic                   rd_bank_o, opnd_ld_o;
  logic [1:0]             tmp_ld_o;

  ntt_ctrl #(
    .ALGO(algo_e'(ALGO)), .BFU_LATENCY(BFU_LATENCY), .RAM_LAT(RAM_LAT), .ROM_LAT(ROM_LAT)
  ) dut (.*);

  always #(T_CLK / 2) clk = ~clk;

  // --------------------------------------------------------------------------
  // Behavioral datapath (reference for the ntt_core glue)
  // --------------------------------------------------------------------------
  logic [COEF_W-1:0] s_data = '0;
  logic [COEF_W-1:0] mem [2][N_COEF];
  logic [COEF_W-1:0] rda [2];
  logic [COEF_W-1:0] rdb [2];
  logic [COEF_W-1:0] bx, by;           // behavioral bfu outputs (cycle W)
  logic              bv;               // behavioral bfu valid_o

  for (genvar k = 0; k < 2; k++) begin : g_bank
    logic [COEF_W-1:0] wd_a;
    assign wd_a = (ram_wsrc_o == WSRC_STREAM) ? s_data : bx;
    always @(posedge clk) begin
      if (ram_en_a_o[k]) begin
        if (ram_we_a_o[k]) mem[k][ram_addr_a_o[k]] <= wd_a;
        else               rda[k] <= mem[k][ram_addr_a_o[k]];
      end
    end
    always @(posedge clk) begin
      if (ram_en_b_o[k]) begin
        if (ram_we_b_o[k]) mem[k][ram_addr_b_o[k]] <= by;
        else               rdb[k] <= mem[k][ram_addr_b_o[k]];
      end
    end
  end

  logic [COEF_W-1:0] rom_c, rom_q, rom_d;
  always_comb begin
    rom_c = 'x;
    if (rom_en_o === 1'b1 && int'(rom_kind_o) != 3)
      rom_c = COEF_W'(mlkem_dpi_rom(ALGO, int'(rom_kind_o),
                                    (rom_kind_o == ROM_K2) ? 0 : int'(rom_addr_o)));
  end
  always @(posedge clk) if (rom_en_o) rom_q <= rom_c;
  assign rom_d = (ROM_LAT == 1) ? rom_q : rom_c;

  logic [COEF_W-1:0] A0, A1, B0, B1, R0, R1;
  always @(posedge clk) begin
    if (opnd_ld_o) begin
      A0 <= rda[0];
      A1 <= rdb[0];
      B0 <= rda[1];
      B1 <= rdb[1];
    end
    if (tmp_ld_o[0]) R0 <= bx;
    if (tmp_ld_o[1]) R1 <= bx;
  end

  logic [COEF_W-1:0] fa, fb, fz;
  always_comb begin
    case (bfu_a_sel_o)
      ASEL_RAM:  fa = rda[rd_bank_o];
      ASEL_ZERO: fa = '0;
      ASEL_R0:   fa = R0;
      default:   fa = 'x;
    endcase
    case (bfu_b_sel_o)
      BSEL_RAM: fb = rdb[rd_bank_o];
      BSEL_A0:  fb = A0;
      BSEL_A1:  fb = A1;
      BSEL_R0:  fb = R0;
      BSEL_R1:  fb = R1;
      default:  fb = 'x;
    endcase
    case (bfu_z_sel_o)
      ZSEL_ROM: fz = rom_d;
      ZSEL_B0:  fz = B0;
      ZSEL_B1:  fz = B1;
      default:  fz = 'x;
    endcase
  end

  int bx0, by0;
  bit bv0, fin_ok;
  always_comb begin
    bv0    = (bfu_valid_o === 1'b1);
    fin_ok = !$isunknown({fa, fb, fz}) && fa < COEF_W'(Q) && fb < COEF_W'(Q) && fz < COEF_W'(Q);
    bx0    = -1;
    by0    = -1;
    if (bv0 && fin_ok) mlkem_dpi_bfu(ALGO, int'(bfu_mode_o), int'(fa), int'(fb), int'(fz), bx0, by0);
  end

  bit pv [0:BFU_LATENCY_MAX];
  int px [0:BFU_LATENCY_MAX];
  int py [0:BFU_LATENCY_MAX];
  always @(posedge clk) begin
    for (int i = BFU_LATENCY_MAX; i >= 2; i--) begin
      pv[i] <= pv[i-1];
      px[i] <= px[i-1];
      py[i] <= py[i-1];
    end
    pv[1] <= bv0;
    px[1] <= bx0;
    py[1] <= by0;
  end
  int bxi, byi;
  assign bv  = (L == 0) ? bv0 : pv[L];
  assign bxi = (L == 0) ? bx0 : px[L];
  assign byi = (L == 0) ? by0 : py[L];
  assign bx  = (bxi >= 0) ? COEF_W'(bxi) : 'x;
  assign by  = (byi >= 0) ? COEF_W'(byi) : 'x;

  logic [COEF_W-1:0] m_data;
  assign m_data = rda[rd_bank_o];

  // --------------------------------------------------------------------------
  // Checkers and golden tables
  // --------------------------------------------------------------------------
  tb_checker chk_sched, chk_bm, chk_timing, chk_hazard, chk_stream, chk_data, chk_ctrl, chk_bfu_in;

  int sch_layer [2][N_STEPS];
  int sch_a0    [2][N_STEPS];
  int sch_a1    [2][N_STEPS];
  int sch_z     [2][N_STEPS];
  int nops;

  typedef struct {
    op_e op;
    bit  bank;
    int  res_bank;
    bit  chk_bank [2];
    int  exp  [2][N_COEF];
    int  data [N_COEF];      // LOAD input / UNLOAD expected output
    int  idx;                // issue number
  } opx_t;

  opx_t   exp_q [$];
  int     n_issued, n_accepted, n_done;
  int     gap_pct_cur, rdy_pct_cur;
  int     src_q [$];

  // --------------------------------------------------------------------------
  // Scoreboard state of the running op
  // --------------------------------------------------------------------------
  longint cyc;
  bit     active;
  opx_t   cur;
  longint t_start;
  int     n_rd, n_ex, n_wr;
  longint rd_cyc [N_STEPS];
  longint ex_cyc [N_STEPS];
  int     rd_obs_bank [N_STEPS];
  int     pending [2][N_COEF];
  int     wr_cnt [N_LAYER][2][N_COEF];
  longint first_rd [N_LAYER];
  longint last_wr [N_LAYER];
  int     rom_at [longint];
  // basemul
  int     bm_rd, bm_ld_next, regs_pair;
  longint bm_rd_cyc [N_PAIR];
  int     op_cnt [N_PAIR];
  typedef struct { longint c; int pair; int op; int dst; } wbx_t;
  wbx_t   wb_q [$];
  longint last_ex, last_w;
  // streams
  int     n_hs, n_ul_rd;
  longint last_hs;
  bit     m_hold;
  logic [COEF_W-1:0] m_hold_data;
  // op boundary
  longint last_bfu_cyc;
  int     min_gap;
  // cycle statistics: index op_e
  longint cyc_nostall [5];
  longint cyc_min [5], cyc_max [5];
  int     n_op_kind [5];

  function automatic string op_name(op_e o);
    case (o)
      OP_LOAD:    return "LOAD";
      OP_NTT:     return "NTT";
      OP_INTT:    return "INTT";
      OP_BASEMUL: return "BASEMUL";
      OP_UNLOAD:  return "UNLOAD";
      default:    return "?";
    endcase
  endfunction

  function automatic string algo_name(int a);
    case (a)
      0: return "barrett";
      1: return "mont12";
      2: return "shiftadd";
      3: return "k2red";
      default: return "?";
    endcase
  endfunction

  function automatic void ck(tb_checker c, bit ok, string msg);
    if (ok) c.pass();
    else c.fail($sformatf("cyc %0d %s: %s", cyc, op_name(cur.op), msg));
  endfunction

  // ---- event view of the current cycle ----
  bit rdA [2], rdB [2], wrA [2], wrB [2];
  int n_rd_ev, n_wr_ev;

  function automatic void collect_events();
    n_rd_ev = 0;
    n_wr_ev = 0;
    for (int k = 0; k < 2; k++) begin
      rdA[k] = ram_en_a_o[k] && !ram_we_a_o[k];
      rdB[k] = ram_en_b_o[k] && !ram_we_b_o[k];
      wrA[k] = ram_en_a_o[k] && ram_we_a_o[k];
      wrB[k] = ram_en_b_o[k] && ram_we_b_o[k];
      n_rd_ev += rdA[k] + rdB[k];
      n_wr_ev += wrA[k] + wrB[k];
    end
  endfunction

  function automatic void note_bfu();
    if (n_ex == 0 && last_bfu_cyc >= 0) begin
      int gap = int'(cyc - last_bfu_cyc - 1);
      if (gap < min_gap) min_gap = gap;
      ck(chk_timing, gap >= L, $sformatf("op boundary bfu idle gap %0d < BFU_LATENCY %0d", gap, L));
    end
    last_bfu_cyc = cyc;
    ck(chk_bfu_in, fin_ok, $sformatf("bfu input unknown / out of range a=%h b=%h z=%h", fa, fb, fz));
  endfunction

  // ROM read recorded at cycle c is used by the bfu valid at c + ROM_LAT.
  function automatic int take_rom(output int kind, output int addr);
    longint c = cyc - ROM_LAT;
    if (!rom_at.exists(c)) return 0;
    kind = rom_at[c] / 256;
    addr = rom_at[c] % 256;
    rom_at.delete(c);
    return 1;
  endfunction

  function automatic void rom_leftover();
    longint c = cyc - ROM_LAT;
    if (rom_at.exists(c)) begin
      ck(chk_timing, 0, $sformatf("ROM read at cycle %0d not used by a bfu valid %0d cycles later", c, ROM_LAT));
      rom_at.delete(c);
    end
  endfunction

  // ---- NTT / INTT ----
  function automatic void cycle_xf();
    int m = (cur.op == OP_INTT) ? 1 : 0;
    int step, rb, wb, lay, k, a;
    // reads
    if (n_rd_ev > 0) begin
      if (n_rd >= N_STEPS) ck(chk_sched, 0, "read after the last butterfly");
      else begin
        step = n_rd;
        lay  = sch_layer[m][step];
        rb   = cur.bank ^ (lay & 1);
        ck(chk_sched, n_rd_ev == 2 && rdA[rb] && rdB[rb]
                      && ram_addr_a_o[rb] == RAM_AW'(sch_a0[m][step])
                      && ram_addr_b_o[rb] == RAM_AW'(sch_a1[m][step]),
           $sformatf("step %0d read: expected bank %0d A=%0d B=%0d, got rdA=%b%b rdB=%b%b addrA=%0d/%0d addrB=%0d/%0d",
                     step, rb, sch_a0[m][step], sch_a1[m][step], rdA[1], rdA[0], rdB[1], rdB[0],
                     ram_addr_a_o[1], ram_addr_a_o[0], ram_addr_b_o[1], ram_addr_b_o[0]));
        // observed read bank (port A) for the hazard checks
        k = rdA[1] ? 1 : 0;
        rd_obs_bank[step] = k;
        foreach (rdA[kk]) begin
          if (rdA[kk]) ck(chk_hazard, pending[kk][ram_addr_a_o[kk]] == 0,
                          $sformatf("read of bank %0d addr %0d with a pending write", kk, ram_addr_a_o[kk]));
          if (rdB[kk]) ck(chk_hazard, pending[kk][ram_addr_b_o[kk]] == 0,
                          $sformatf("read of bank %0d addr %0d with a pending write", kk, ram_addr_b_o[kk]));
        end
        pending[rb ^ 1][sch_a0[m][step]]++;
        pending[rb ^ 1][sch_a1[m][step]]++;
        rd_cyc[step] = cyc;
        if (step % N_PAIR == 0) first_rd[lay] = cyc;
        n_rd++;
      end
    end
    if (rom_en_o) rom_at[cyc] = int'(rom_kind_o) * 256 + int'(rom_addr_o);
    // exec
    if (bfu_valid_o) begin
      if (n_ex >= n_rd) ck(chk_sched, 0, "bfu valid without a read");
      else begin
        int kind, addr, got;
        step = n_ex;
        lay  = sch_layer[m][step];
        rb   = cur.bank ^ (lay & 1);
        ck(chk_timing, cyc == rd_cyc[step] + RAM_LAT,
           $sformatf("step %0d bfu valid at %0d, read at %0d (RAM_LAT %0d)", step, cyc, rd_cyc[step], RAM_LAT));
        ck(chk_sched, bfu_mode_o == mode_e'(m) && bfu_a_sel_o == ASEL_RAM && bfu_b_sel_o == BSEL_RAM
                      && bfu_z_sel_o == ZSEL_ROM && rd_bank_o == 1'(rb),
           $sformatf("step %0d exec fields mode=%0d a=%0d b=%0d z=%0d rd_bank=%0d (exp mode %0d bank %0d)",
                     step, bfu_mode_o, bfu_a_sel_o, bfu_b_sel_o, bfu_z_sel_o, rd_bank_o, m, rb));
        got = take_rom(kind, addr);
        ck(chk_sched, got && kind == int'(ROM_ZETA) && addr == sch_z[m][step],
           $sformatf("step %0d zeta ROM read %0d cycles before: present %0d kind %0d addr %0d, expected zeta %0d",
                     step, ROM_LAT, got, kind, addr, sch_z[m][step]));
        note_bfu();
        ex_cyc[step] = cyc;
        n_ex++;
      end
    end else if (n_ex < n_rd && rd_cyc[n_ex] + RAM_LAT == cyc) begin
      ck(chk_timing, 0, $sformatf("step %0d: no bfu valid RAM_LAT after its read", n_ex));
      n_ex++;
    end
    rom_leftover();
    ck(chk_ctrl, !opnd_ld_o && tmp_ld_o == 2'b00 && !s_ready_o && !m_valid_o,
       "opnd_ld / tmp_ld / s_ready / m_valid active");
    // writes
    if (n_wr < n_ex && ex_cyc[n_wr] + L == cyc) begin
      step = n_wr;
      lay  = sch_layer[m][step];
      rb   = cur.bank ^ (lay & 1);
      wb   = rb ^ 1;
      ck(chk_sched, n_wr_ev == 2 && wrA[wb] && wrB[wb] && ram_wsrc_o == WSRC_BFU
                    && ram_addr_a_o[wb] == RAM_AW'(sch_a0[m][step])
                    && ram_addr_b_o[wb] == RAM_AW'(sch_a1[m][step]),
         $sformatf("step %0d write: expected bank %0d A=%0d B=%0d, got wrA=%b%b wrB=%b%b addrA=%0d/%0d addrB=%0d/%0d wsrc=%0d",
                   step, wb, sch_a0[m][step], sch_a1[m][step], wrA[1], wrA[0], wrB[1], wrB[0],
                   ram_addr_a_o[1], ram_addr_a_o[0], ram_addr_b_o[1], ram_addr_b_o[0], ram_wsrc_o));
      ck(chk_timing, bv, $sformatf("step %0d write while the bfu output is not valid", step));
      for (int kk = 0; kk < 2; kk++) begin
        if (wrA[kk]) begin
          a = ram_addr_a_o[kk];
          ck(chk_hazard, kk != rd_obs_bank[step], $sformatf("step %0d writes its read bank %0d", step, kk));
          if (pending[kk][a] > 0) pending[kk][a]--;
          wr_cnt[lay][kk][a]++;
        end
        if (wrB[kk]) begin
          a = ram_addr_b_o[kk];
          ck(chk_hazard, kk != rd_obs_bank[step], $sformatf("step %0d writes its read bank %0d", step, kk));
          if (pending[kk][a] > 0) pending[kk][a]--;
          wr_cnt[lay][kk][a]++;
        end
      end
      last_wr[lay] = cyc;
      n_wr++;
    end else if (n_wr_ev > 0) begin
      ck(chk_sched, 0, $sformatf("unexpected write (wrA=%b%b wrB=%b%b)", wrA[1], wrA[0], wrB[1], wrB[0]));
    end
    for (int kk = 0; kk < 2; kk++)
      if ((rdA[kk] || rdB[kk]) && (wrA[kk] || wrB[kk]))
        ck(chk_hazard, 0, $sformatf("bank %0d read and written in the same cycle", kk));
  endfunction

  function automatic void finish_xf();
    ck(chk_sched, n_rd == N_STEPS && n_ex == N_STEPS && n_wr == N_STEPS,
       $sformatf("counts rd %0d ex %0d wr %0d, expected %0d", n_rd, n_ex, n_wr, N_STEPS));
    for (int l = 0; l + 1 < N_LAYER; l++)
      ck(chk_timing, first_rd[l + 1] == last_wr[l] + 1,
         $sformatf("layer %0d first read at %0d, layer %0d last write at %0d (must be +1)",
                   l + 1, first_rd[l + 1], l, last_wr[l]));
    ck(chk_timing, cyc == last_wr[N_LAYER - 1] + 1,
       $sformatf("done_o at %0d, last write at %0d (must be +1)", cyc, last_wr[N_LAYER - 1]));
    for (int l = 0; l < N_LAYER; l++) begin
      int wbk = (cur.bank ^ (l & 1)) ^ 1;
      int bad = 0;
      for (int a = 0; a < N_COEF; a++)
        if (wr_cnt[l][wbk][a] != 1 || wr_cnt[l][wbk ^ 1][a] != 0) bad++;
      ck(chk_hazard, bad == 0, $sformatf("layer %0d: %0d addresses not written exactly once in bank %0d", l, bad, wbk));
    end
  endfunction

  // ---- BASEMUL ----
  function automatic int a_code(a_sel_e s);
    case (s) ASEL_ZERO: return 0; ASEL_R0: return 5; default: return -1; endcase
  endfunction
  function automatic int b_code(b_sel_e s);
    case (s) BSEL_A0: return 1; BSEL_A1: return 2; BSEL_R0: return 5; BSEL_R1: return 6;
      default: return -1; endcase
  endfunction

  function automatic void cycle_bm();
    bit exp_ld;
    int p;
    // operand reads
    if (n_rd_ev > 0) begin
      p = bm_rd;
      ck(chk_bm, p < N_PAIR && n_rd_ev == 4 && rdA[0] && rdB[0] && rdA[1] && rdB[1]
                 && ram_addr_a_o[0] == RAM_AW'(2 * p) && ram_addr_b_o[0] == RAM_AW'(2 * p + 1)
                 && ram_addr_a_o[1] == RAM_AW'(2 * p) && ram_addr_b_o[1] == RAM_AW'(2 * p + 1),
         $sformatf("pair %0d operand read: rdA=%b%b rdB=%b%b addrA=%0d/%0d addrB=%0d/%0d",
                   p, rdA[1], rdA[0], rdB[1], rdB[0], ram_addr_a_o[1], ram_addr_a_o[0],
                   ram_addr_b_o[1], ram_addr_b_o[0]));
      if (p < N_PAIR) bm_rd_cyc[p] = cyc;
      bm_rd++;
    end
    if (rom_en_o) rom_at[cyc] = int'(rom_kind_o) * 256 + int'(rom_addr_o);
    // exec stage: operand load and op
    exp_ld = (bm_ld_next < bm_rd && bm_ld_next < N_PAIR && bm_rd_cyc[bm_ld_next] + RAM_LAT == cyc);
    ck(chk_timing, opnd_ld_o == exp_ld,
       $sformatf("opnd_ld_o=%b, expected %b (RAM_LAT after the pair read)", opnd_ld_o, exp_ld));
    if (bfu_valid_o) begin
      int ga, gb, gz, gd, k, da, db, dz, kind, addr;
      p = regs_pair;
      if (p < 0) ck(chk_bm, 0, "bfu valid before the first operand load");
      else begin
        k = op_cnt[p];
        if (k >= nops) ck(chk_bm, 0, $sformatf("pair %0d: op %0d beyond the program (%0d ops)", p, k, nops));
        else begin
          void'(mlkem_dpi_basemul_op(ALGO, k, ga, gb, gz, gd));
          da = a_code(bfu_a_sel_o);
          db = b_code(bfu_b_sel_o);
          case (bfu_z_sel_o)
            ZSEL_B0: dz = 3;
            ZSEL_B1: dz = 4;
            ZSEL_ROM: begin
              dz = -1;
              if (take_rom(kind, addr)) begin
                if (kind == int'(ROM_GAMMA) && addr == p) dz = 7;
                else if (kind == int'(ROM_K2)) dz = 8;
                else dz = -2 - kind * 1000 - addr;
              end
            end
            default: dz = -1;
          endcase
          ck(chk_bm, bfu_mode_o == MODE_CT && da == ga && db == gb && dz == gz,
             $sformatf("pair %0d op %0d: src (a,b,z) = (%0d,%0d,%0d), golden (%0d,%0d,%0d), mode %0d",
                       p, k, da, db, dz, ga, gb, gz, bfu_mode_o));
          if (last_ex >= 0)
            ck(chk_timing, cyc > last_ex + L,
               $sformatf("op overlap: bfu valid at %0d, previous at %0d, BFU_LATENCY %0d", cyc, last_ex, L));
          wb_q.push_back('{c: cyc + L, pair: p, op: k, dst: gd});
          op_cnt[p]++;
        end
      end
      note_bfu();
      last_ex = cyc;
      n_ex++;
    end
    rom_leftover();
    if (exp_ld) begin
      if (regs_pair >= 0)
        ck(chk_hazard, op_cnt[regs_pair] == nops,
           $sformatf("operands of pair %0d replaced after %0d of %0d ops", regs_pair, op_cnt[regs_pair], nops));
      regs_pair = bm_ld_next;
      bm_ld_next++;
    end
    ck(chk_ctrl, !s_ready_o && !m_valid_o, "s_ready / m_valid active");
    // write back
    if (wb_q.size() > 0 && wb_q[0].c == cyc) begin
      wbx_t e = wb_q.pop_front();
      int   dd = -1;
      int   nw = n_wr_ev + tmp_ld_o[0] + tmp_ld_o[1];
      if (nw == 1) begin
        if (tmp_ld_o == 2'b01) dd = 0;
        else if (tmp_ld_o == 2'b10) dd = 1;
        else if (wrA[0] && ram_wsrc_o == WSRC_BFU && ram_addr_a_o[0] == RAM_AW'(2 * e.pair)) dd = 2;
        else if (wrA[0] && ram_wsrc_o == WSRC_BFU && ram_addr_a_o[0] == RAM_AW'(2 * e.pair + 1)) dd = 3;
      end
      ck(chk_bm, dd == e.dst,
         $sformatf("pair %0d op %0d: destination %0d (tmp_ld=%b wrA=%b%b wrB=%b%b addrA0=%0d), golden %0d",
                   e.pair, e.op, dd, tmp_ld_o, wrA[1], wrA[0], wrB[1], wrB[0], ram_addr_a_o[0], e.dst));
      ck(chk_timing, bv, $sformatf("pair %0d op %0d: write back while the bfu output is not valid", e.pair, e.op));
      last_w = cyc;
      n_wr++;
    end else if (n_wr_ev > 0 || tmp_ld_o != 2'b00) begin
      ck(chk_bm, 0, $sformatf("unexpected write back (tmp_ld=%b wrA=%b%b wrB=%b%b)",
                               tmp_ld_o, wrA[1], wrA[0], wrB[1], wrB[0]));
    end
  endfunction

  function automatic void finish_bm();
    int bad = 0;
    for (int p = 0; p < N_PAIR; p++) if (op_cnt[p] != nops) bad++;
    ck(chk_bm, bm_rd == N_PAIR && bad == 0 && wb_q.size() == 0 && n_wr == N_PAIR * nops,
       $sformatf("pairs read %0d, pairs with wrong op count %0d, write backs %0d, pending %0d",
                 bm_rd, bad, n_wr, wb_q.size()));
    ck(chk_timing, cyc == last_w + 1, $sformatf("done_o at %0d, last write back at %0d (must be +1)", cyc, last_w));
  endfunction

  // ---- LOAD / UNLOAD ----
  function automatic void cycle_load();
    bit hs = s_valid_i && s_ready_o;
    ck(chk_stream, s_ready_o == busy_o, $sformatf("s_ready_o=%b busy_o=%b", s_ready_o, busy_o));
    if (hs) begin
      ck(chk_stream, n_hs < N_COEF && n_wr_ev == 1 && wrA[cur.bank] && ram_wsrc_o == WSRC_STREAM
                     && ram_addr_a_o[cur.bank] == RAM_AW'(n_hs),
         $sformatf("word %0d: write wrA=%b%b wrB=%b%b addrA=%0d wsrc=%0d, expected bank %0d addr %0d",
                   n_hs, wrA[1], wrA[0], wrB[1], wrB[0], ram_addr_a_o[cur.bank], ram_wsrc_o, cur.bank, n_hs));
      if (n_hs < N_COEF)
        ck(chk_stream, s_data == COEF_W'(cur.data[n_hs]), $sformatf("TB source order: word %0d", n_hs));
      n_hs++;
      last_hs = cyc;
    end else begin
      ck(chk_stream, n_wr_ev == 0, "write without a stream handshake");
    end
    ck(chk_ctrl, n_rd_ev == 0 && !bfu_valid_o && !rom_en_o && !opnd_ld_o && tmp_ld_o == 2'b00 && !m_valid_o,
       "datapath activity during LOAD");
  endfunction

  function automatic void cycle_unload();
    bit hs = m_valid_o && m_ready_i;
    if (n_rd_ev > 0) begin
      ck(chk_stream, n_rd_ev == 1 && rdA[cur.bank] && ram_addr_a_o[cur.bank] == RAM_AW'(n_ul_rd)
                     && n_ul_rd < N_COEF,
         $sformatf("read %0d: rdA=%b%b rdB=%b%b addrA=%0d, expected bank %0d addr %0d",
                   n_ul_rd, rdA[1], rdA[0], rdB[1], rdB[0], ram_addr_a_o[cur.bank], cur.bank, n_ul_rd));
      n_ul_rd++;
    end
    if (m_hold)
      ck(chk_stream, m_valid_o && m_data === m_hold_data,
         $sformatf("output changed under backpressure: m_valid=%b data=%h held %h", m_valid_o, m_data, m_hold_data));
    if (m_valid_o) ck(chk_stream, rd_bank_o == cur.bank, "rd_bank_o != UNLOAD bank");
    if (hs) begin
      ck(chk_stream, n_hs < N_COEF && m_data === COEF_W'(cur.data[n_hs]),
         $sformatf("word %0d: got %h expected %h", n_hs, m_data, (n_hs < N_COEF) ? cur.data[n_hs] : -1));
      n_hs++;
      last_hs = cyc;
    end
    m_hold      = m_valid_o && !m_ready_i;
    m_hold_data = m_data;
    ck(chk_ctrl, n_wr_ev == 0 && !bfu_valid_o && !rom_en_o && !opnd_ld_o && tmp_ld_o == 2'b00 && !s_ready_o,
       "datapath activity during UNLOAD");
  endfunction

  function automatic void finish_stream();
    if (cur.op == OP_UNLOAD)
      ck(chk_stream, n_hs == N_COEF && n_ul_rd == N_COEF,
         $sformatf("UNLOAD words %0d reads %0d, expected %0d", n_hs, n_ul_rd, N_COEF));
    else
      ck(chk_stream, n_hs == N_COEF, $sformatf("LOAD words %0d, expected %0d", n_hs, N_COEF));
    ck(chk_timing, cyc == last_hs + 1, $sformatf("done_o at %0d, last handshake at %0d (must be +1)", cyc, last_hs));
  endfunction

  // ---- op start / done ----
  function automatic void start_op();
    if (exp_q.size() == 0) begin
      chk_ctrl.fail($sformatf("cyc %0d: start accepted with no expectation", cyc));
      cur.op = op_i;
    end else cur = exp_q.pop_front();
    ck(chk_ctrl, cur.op == op_i && (cur.op == OP_BASEMUL || cur.bank == bank_i),
       $sformatf("accepted op %0d bank %0d, TB issued op %0d bank %0d", op_i, bank_i, cur.op, cur.bank));
    active  = 1;
    t_start = cyc;
    n_rd = 0; n_ex = 0; n_wr = 0;
    foreach (pending[k, a]) pending[k][a] = 0;
    foreach (wr_cnt[l, k, a]) wr_cnt[l][k][a] = 0;
    foreach (first_rd[l]) begin first_rd[l] = -1; last_wr[l] = -1; end
    rom_at.delete();
    bm_rd = 0; bm_ld_next = 0; regs_pair = -1;
    foreach (op_cnt[p]) op_cnt[p] = 0;
    wb_q.delete();
    last_ex = -1; last_w = -1;
    n_hs = 0; n_ul_rd = 0; last_hs = -1; m_hold = 0;
    n_accepted++;
  endfunction

  function automatic void finish_op();
    longint nc = cyc - t_start;
    int     ok_cnt;
    case (cur.op)
      OP_NTT, OP_INTT: finish_xf();
      OP_BASEMUL:      finish_bm();
      default:         finish_stream();
    endcase
    ck(chk_timing, rom_at.size() == 0, $sformatf("%0d ROM reads never used", rom_at.size()));
    ck(chk_ctrl, int'(result_bank_o) == cur.res_bank,
       $sformatf("result_bank_o %0d, expected %0d", result_bank_o, cur.res_bank));
    for (int k = 0; k < 2; k++) begin
      if (!cur.chk_bank[k]) continue;
      ok_cnt = 0;
      for (int a = 0; a < N_COEF; a++) if (mem[k][a] === COEF_W'(cur.exp[k][a])) ok_cnt++;
      ck(chk_data, ok_cnt == N_COEF,
         $sformatf("op #%0d bank %0d: %0d of %0d coefficients differ from the golden result (e.g. [0] %h vs %h)",
                   cur.idx, k, N_COEF - ok_cnt, N_COEF, mem[k][0], cur.exp[k][0]));
    end
    if (n_op_kind[cur.op] == 0 || nc < cyc_min[cur.op]) cyc_min[cur.op] = nc;
    if (n_op_kind[cur.op] == 0 || nc > cyc_max[cur.op]) cyc_max[cur.op] = nc;
    if (cyc_nostall[cur.op] < 0) cyc_nostall[cur.op] = nc;
    n_op_kind[cur.op]++;
    active = 0;
    n_done++;
  endfunction

  function automatic void cycle_idle();
    ck(chk_ctrl, n_rd_ev == 0 && n_wr_ev == 0 && !bfu_valid_o && !rom_en_o && !opnd_ld_o
                 && tmp_ld_o == 2'b00 && !s_ready_o && !m_valid_o && !busy_o,
       "activity while idle");
  endfunction

  longint watchdog_cyc;

  always @(negedge clk) begin
    if (rst_n) begin
      bit accept, done_now;
      cyc++;
      ck(chk_ctrl, !$isunknown({busy_o, done_o, result_bank_o, s_ready_o, m_valid_o, ram_en_a_o,
                                ram_we_a_o, ram_addr_a_o, ram_en_b_o, ram_we_b_o, ram_addr_b_o,
                                ram_wsrc_o, rom_en_o, rom_kind_o, rom_addr_o, bfu_valid_o,
                                bfu_mode_o, bfu_a_sel_o, bfu_b_sel_o, bfu_z_sel_o, rd_bank_o,
                                opnd_ld_o, tmp_ld_o}), "X on a DUT output");
      collect_events();
      done_now = (done_o === 1'b1);
      if (active) begin
        ck(chk_ctrl, busy_o == !done_now, $sformatf("busy_o=%b done_o=%b while the op runs", busy_o, done_o));
        case (cur.op)
          OP_NTT, OP_INTT: cycle_xf();
          OP_BASEMUL:      cycle_bm();
          OP_LOAD:         cycle_load();
          default:         cycle_unload();
        endcase
        if (done_now) finish_op();
        else if (cyc - t_start > WATCHDOG) $fatal(1, "watchdog: op %s did not finish", op_name(cur.op));
      end else begin
        ck(chk_ctrl, !done_now, "done_o without a running op");
        cycle_idle();
      end
      accept = (start_i === 1'b1) && (busy_o === 1'b0);
      if (accept) start_op();
    end
  end

  // --------------------------------------------------------------------------
  // Stimulus
  // --------------------------------------------------------------------------
  int gold [2][N_COEF];
  bit gold_known [2];

  task automatic src_driver();
    forever begin
      @(posedge clk);
      if (s_valid_i && s_ready_o) void'(src_q.pop_front());
      if (!(s_valid_i && !s_ready_o)) begin     // AXI4-Stream: hold an unaccepted word
        if (src_q.size() > 0 && $urandom_range(99) >= gap_pct_cur) begin
          s_valid_i <= 1'b1;
          s_data    <= COEF_W'(src_q[0]);
        end else begin
          s_valid_i <= 1'b0;
          s_data    <= COEF_W'($urandom_range(2 ** COEF_W - 1));
        end
      end
    end
  endtask

  task automatic sink_driver();
    forever begin
      @(posedge clk);
      m_ready_i <= ($urandom_range(99) >= rdy_pct_cur);
    end
  endtask

  // Build the expectation of op, update the golden bank model, start the op.
  task automatic issue(op_e op, bit bank, int data [N_COEF], bit early);
    opx_t x;
    int   tmp [N_COEF];
    int   rc;
    x.op = op;
    x.bank = bank;
    x.idx = n_issued;
    x.chk_bank = '{0, 0};
    case (op)
      OP_LOAD: begin
        x.data = data;
        gold[bank] = data;
        gold_known[bank] = 1;
        x.res_bank = bank;
        foreach (data[i]) src_q.push_back(data[i]);
      end
      OP_NTT, OP_INTT: begin
        if (!gold_known[bank]) $fatal(1, "TB sequence: transform of an unknown bank");
        if (op == OP_NTT) rc = mlkem_dpi_hw_ntt(ALGO, gold[bank], tmp);
        else              rc = mlkem_dpi_hw_intt(ALGO, gold[bank], tmp);
        if (rc != 0) $fatal(1, "DPI hw transform returned %0d", rc);
        gold[bank ^ 1] = tmp;
        gold_known[bank ^ 1] = 1;
        gold_known[bank] = 0;            // holds an intermediate layer
        x.res_bank = bank ^ 1;
      end
      OP_BASEMUL: begin
        if (!gold_known[0] || !gold_known[1]) $fatal(1, "TB sequence: basemul of an unknown bank");
        rc = mlkem_dpi_hw_basemul(ALGO, gold[0], gold[1], tmp);
        if (rc != 0) $fatal(1, "DPI hw_basemul returned %0d", rc);
        gold[0] = tmp;
        x.res_bank = 0;
      end
      default: begin                     // UNLOAD
        if (!gold_known[bank]) $fatal(1, "TB sequence: unload of an unknown bank");
        x.data = gold[bank];
        x.res_bank = bank;
      end
    endcase
    for (int k = 0; k < 2; k++) begin
      x.chk_bank[k] = gold_known[k];
      x.exp[k] = gold[k];
    end
    exp_q.push_back(x);
    n_issued++;

    if (!early) begin
      wait (n_done == n_issued - 1);
      repeat ($urandom_range(3)) @(posedge clk);
    end
    @(posedge clk);
    start_i <= 1'b1;
    op_i    <= op;
    bank_i  <= bank;
    wait (n_accepted == n_issued);
    @(posedge clk);
    start_i <= 1'b0;
    op_i    <= op_e'($urandom_range(4));
    bank_i  <= $urandom_range(1);
  endtask

  function automatic void case_poly(int c, output int f [N_COEF]);
    for (int i = 0; i < N_COEF; i++) begin
      case (c)
        0: f[i] = 0;
        1: f[i] = Q - 1;
        2: f[i] = (i == 0) ? 1 : 0;
        3: f[i] = (i == N_COEF - 1) ? 1 : 0;
        4: f[i] = (i == 128) ? Q - 1 : 0;
        5: f[i] = 1;
        default: f[i] = $urandom_range(Q - 1);
      endcase
    end
  endfunction

  initial begin
    int unsigned seed;
    int          n_cases, gap_pct, rdy_pct, rc, ly, ln, b;
    int          f [N_COEF];
    int          a [N_COEF];
    int          g [N_COEF];
    int          none [N_COEF];
    bit          ok;
    string       an;

    seed    = tb_seed_from_plusarg();
    n_cases = 36;
    gap_pct = 30;
    rdy_pct = 30;
    void'($value$plusargs("N_CASES=%d", n_cases));
    void'($value$plusargs("GAP_PCT=%d", gap_pct));
    void'($value$plusargs("RDY_PCT=%d", rdy_pct));
    an = algo_name(ALGO);
    chk_sched  = new("sched");
    chk_bm     = new("bm_prog");
    chk_timing = new("timing");
    chk_hazard = new("hazard");
    chk_stream = new("stream");
    chk_data   = new("data");
    chk_ctrl   = new("ctrl");
    chk_bfu_in = new("bfu_in");
    cyc = 0; active = 0; n_issued = 0; n_accepted = 0; n_done = 0;
    last_bfu_cyc = -1; min_gap = 1 << 30;
    foreach (cyc_nostall[i]) begin cyc_nostall[i] = -1; n_op_kind[i] = 0; end
    foreach (none[i]) none[i] = 0;
    gold_known = '{0, 0};
    $display("TB_CONFIG: tb_ntt_ctrl ALGO=%0d(%s) BFU_LATENCY=%0d RAM_LAT=%0d ROM_LAT=%0d SEED=%0d N_CASES=%0d GAP_PCT=%0d RDY_PCT=%0d",
             ALGO, an, L, RAM_LAT, ROM_LAT, seed, n_cases, gap_pct, rdy_pct);

    // golden schedule tables and program length
    for (int m = 0; m < 2; m++)
      for (int s = 0; s < N_STEPS; s++) begin
        rc = mlkem_dpi_hw_sched(m, s, ly, ln, sch_a0[m][s], sch_a1[m][s], sch_z[m][s]);
        sch_layer[m][s] = ly;
        if (rc != 0 || ly != s / N_PAIR) $fatal(1, "hw_sched(%0d, %0d) rc %0d layer %0d", m, s, rc, ly);
      end
    nops = mlkem_dpi_basemul_nops(ALGO);
    if (nops == basemul_nops(algo_e'(ALGO))) chk_bm.pass();
    else chk_bm.fail($sformatf("golden nops %0d, ntt_l2_pkg::basemul_nops %0d", nops, basemul_nops(algo_e'(ALGO))));

    gap_pct_cur = 0;
    rdy_pct_cur = 0;
    fork
      src_driver();
      sink_driver();
    join_none

    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    for (int c = 0; c < n_cases; c++) begin
      bit e;
      if (c == 1) begin
        gap_pct_cur = gap_pct;
        rdy_pct_cur = rdy_pct;
      end
      b = c & 1;
      case_poly(c, f);
      case_poly(N_BOUND + 1000 + c, a);           // random
      if (c < N_BOUND) case_poly((c + 1) % N_BOUND, g);
      else             case_poly(N_BOUND + 2000 + c, g);
      e = (c != 0) && $urandom_range(1);
      issue(OP_LOAD,    b,     f,    e);
      issue(OP_NTT,     b,     none, (c != 0) && $urandom_range(1));
      issue(OP_UNLOAD,  b ^ 1, none, (c != 0) && $urandom_range(1));
      issue(OP_INTT,    b ^ 1, none, (c != 0) && $urandom_range(1));
      issue(OP_NTT,     b,     none, (c != 0));    // INTT -> NTT back to back
      issue(OP_INTT,    b ^ 1, none, (c != 0));    // NTT -> INTT back to back
      issue(OP_UNLOAD,  b,     none, (c != 0) && $urandom_range(1));
      // basemul: boundary polynomial in a for the boundary cases
      issue(OP_LOAD,    0,     (c < N_BOUND) ? f : a, (c != 0) && $urandom_range(1));
      issue(OP_LOAD,    1,     g,    (c != 0) && $urandom_range(1));
      issue(OP_BASEMUL, 0,     none, (c != 0) && $urandom_range(1));
      issue(OP_UNLOAD,  0,     none, (c != 0) && $urandom_range(1));
      if (c % 3 == 0) issue(OP_UNLOAD, 1, none, (c != 0) && $urandom_range(1));
      if (c % 6 == 5) $display("PROGRESS: case %0d done, ops %0d, cycle %0d", c, n_issued, cyc);
    end
    wait (n_done == n_issued);
    repeat (5) @(posedge clk);
    @(negedge clk);

    $display("OPS: issued=%0d done=%0d cycles=%0d", n_issued, n_done, cyc);
    for (int o = 0; o < 5; o++)
      $display("CYCLES: algo=%s BFU_LATENCY=%0d ROM_LAT=%0d op=%s n=%0d nostall=%0d min=%0d max=%0d",
               an, L, ROM_LAT, op_name(op_e'(o)), n_op_kind[o], cyc_nostall[o], cyc_min[o], cyc_max[o]);
    $display("GAP: minimum bfu idle cycles at an op boundary = %0d (BFU_LATENCY %0d)", min_gap, L);
    if (n_done != n_issued) chk_ctrl.fail("not all ops finished");
    ok = tb_final_report('{chk_sched, chk_bm, chk_timing, chk_hazard, chk_stream, chk_data, chk_ctrl, chk_bfu_in});
    $finish;
  end

endmodule
