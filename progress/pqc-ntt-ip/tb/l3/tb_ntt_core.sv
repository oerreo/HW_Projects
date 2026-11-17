// tb_ntt_core: self-checking testbench for the L3 core ntt_core.
//
// The DUT is ntt_core with ALGO, PRE_REG, MUL_REG, RED_PIPE, OUT_REG,
// SHARE_ADDSUB and ROM_OUT_REG from the TB parameters. The TB only uses the
// local interface (command, status, input / output streams). Every result is
// read back through OP_UNLOAD and compared polynomial by polynomial.
//
// Test items (one checker each, one check = one polynomial; a polynomial is
// a mismatch if any coefficient differs):
//   ext_ntt   data/vectors/ext ntt_in / ntt_out (855, or +N_EXT_NTT spread
//             over the file): LOAD b; NTT b; UNLOAD ~b.
//   ext_intt  intt_in / intt_out (450): LOAD b; INTT b; UNLOAD ~b.
//   ext_bm    basemul_a / _b / _out (2145): LOAD 0 a; LOAD 1 b (order random);
//             BASEMUL; UNLOAD 0. Every 8th pair also UNLOAD 1 (b unchanged,
//             item bm_keep_b).
//   rnd_*     N_RAND random polynomials (pairs) per op, full range [0, Q),
//             expected = mlkem_dpi_hw_ntt / hw_intt / hw_basemul.
//   dir_*     directed polynomials (all 0, all Q-1, all 1, impulses 1 and Q-1
//             at several positions, single Q-1, alternating, ramps, values
//             around Q/2), NTT and INTT of each, BASEMUL of pairs.
//   rt_ct_gs  LOAD b f; NTT b; INTT ~b (started early: accepted in the NTT
//             done cycle, so the bfu goes CT -> GS back to back); UNLOAD b = f.
//   rt_gs_ct  the same with INTT first, then NTT.
//   pm_fhat / pm_ghat / pm_prod
//             polynomial product f * g mod (X^256 + 1) with the current op
//             set (see "product chain" below). pm_fhat / pm_ghat check the
//             unloaded NTT results, pm_prod the final product. Pairs: the
//             golden-model vector files polymul_f / _g / _h (model/vectors,
//             +N_MPM, h verified by schoolbook in the model) and N_CHAIN
//             random pairs.
// Golden cross-checks (item golden): every expectation from one source is
// compared with the others before it is used:
//   ext files == mlkem_dpi_hw_* (ALGO) == reference mlkem_dpi_ntt / intt /
//   multiply_ntts; random: hw_* == reference; product: file h (if any) ==
//   reference intt(multiply_ntts(ntt f, ntt g)) == SV schoolbook written here
//   (int arithmetic and %, independent of the model) == hw chain.
//
// Product chain. NTT and INTT use both banks (ping-pong, result in the
// other bank, the input bank holds a dead intermediate layer), and BASEMUL
// needs a in bank0 and b in bank1. Two NTT-domain operands can therefore
// never be produced in the core one after the other: the second NTT
// overwrites the first result. With the v1 op set the product needs one
// UNLOAD / LOAD round trip through the host:
//   LOAD 0 f; NTT 0 (f^ in bank1); UNLOAD 1 (f^ out, checked);
//   LOAD 0 g; NTT 0 (g^ in bank1); LOAD 0 f^ (the words just unloaded);
//   BASEMUL (h^ in bank0); INTT 0 (h in bank1, BASEMUL -> INTT back to
//   back); UNLOAD 1 = f * g.
//
// Stream and protocol checks (item stream, ctrl, cycles):
//   LOAD: words accepted in order, exactly 256, s_ready_o only during LOAD.
//   UNLOAD: exactly 256 words, m_valid_o only during UNLOAD, m_valid_o and
//   m_data_o held while m_ready_i = 0 (AXI4-Stream rule).
//   busy_o / done_o protocol, result_bank_o at done_o (bank_i for LOAD /
//   UNLOAD, ~bank_i for NTT / INTT, 0 for BASEMUL), no X on outputs.
//   Cycles from start acceptance to done_o (ntt_ctrl P3-2 measurement):
//     NTT / INTT 897 + 7 (1 + L), BASEMUL 128 n (L + 1) + 3 (n = 5 for S = 1,
//     7 otherwise), LOAD 257 + idle cycles (s_ready_o = 1, s_valid_i = 0),
//     UNLOAD 258 + stall cycles (m_valid_o = 1, m_ready_i = 0);
//     L = PRE_REG + MUL_REG + RED_PIPE + OUT_REG computed here.
// Stimulus: the directed item runs without stalls (stall-free LOAD / UNLOAD
// counts); all other items alternate per test between no stalls and valid
// gaps GAP_PCT % / ready low RDY_PCT %. Ops after the first of a test are
// started "early" (start_i held while busy, accepted in the done_o cycle)
// with probability 1/2, round trips and product chains always back to back.
// The DUT assertions (L1_RANGE, L1_SHARE, L2_RAM_*, L2_CTRL_*, L2_ROM_KIND,
// L3_RANGE, L3_WB) must stay silent; sim/run.sh fails a run on any Error.
//
// Plusargs: +SEED=<n> (1) +GAP_PCT=<n> (30) +RDY_PCT=<n> (30)
//   +N_EXT_NTT=<n> (855) +N_EXT_INTT=<n> (450) +N_EXT_BM=<n> (2145)
//   +N_RAND=<n> (1000) +N_RT=<n> (32) +N_CHAIN=<n> (32) +N_MPM=<n> (106)
//   +EXT_DIR=<dir> (../../data/vectors/ext) +MVEC_DIR=<dir> (../../model/vectors)
//   +OOR_TEST: after one clean LOAD / UNLOAD, load OOR_N = 3 words >= Q
//              (L3_RANGE must fire 3 times); no other items.
`timescale 1ns / 1ps

module tb_ntt_core;
  import mlkem_pkg::*;
  import ntt_l2_pkg::*;
  import mlkem_dpi_pkg::*;
  import tb_util_pkg::*;

  parameter int ALGO         = 0;
  parameter int PRE_REG      = 0;
  parameter int MUL_REG      = 0;
  parameter int RED_PIPE     = 0;
  parameter int OUT_REG      = 0;
  parameter int SHARE_ADDSUB = 0;
  parameter int ROM_OUT_REG  = 1;

  localparam int  L          = PRE_REG + MUL_REG + RED_PIPE + OUT_REG;
  localparam int  NOPS       = (ALGO == int'(ALGO_BARRETT) || ALGO == int'(ALGO_SHIFTADD)) ? 5 : 7;
  localparam int  CYC_XF     = 897 + 7 * (1 + L);
  localparam int  CYC_BM     = 128 * NOPS * (L + 1) + 3;
  localparam int  CYC_LOAD   = 257;
  localparam int  CYC_UNLOAD = 258;
  localparam int  NX_NTT     = 855;
  localparam int  NX_INTT    = 450;
  localparam int  NX_BM      = 2145;
  localparam int  NX_MPM     = 106;
  localparam int  OOR_N      = 3;
  localparam time T_CLK      = 10ns;
  localparam int  WATCHDOG   = 20000;

  // --------------------------------------------------------------------------
  // DUT
  // --------------------------------------------------------------------------
  logic              clk = 1'b0;
  logic              rst_n = 1'b0;
  logic              start_i = 1'b0;
  op_e               op_i = OP_LOAD;
  logic              bank_i = 1'b0;
  logic              busy_o, done_o, result_bank_o;
  logic              s_valid_i = 1'b0;
  logic              s_ready_o;
  logic [COEF_W-1:0] s_data_i = '0;
  logic              m_valid_o;
  logic              m_ready_i = 1'b0;
  logic [COEF_W-1:0] m_data_o;

  ntt_core #(
    .ALGO(algo_e'(ALGO)), .PRE_REG(PRE_REG), .MUL_REG(MUL_REG), .RED_PIPE(RED_PIPE),
    .OUT_REG(OUT_REG), .SHARE_ADDSUB(SHARE_ADDSUB), .ROM_OUT_REG(ROM_OUT_REG)
  ) dut (.*);

  always #(T_CLK / 2) clk = ~clk;

  // --------------------------------------------------------------------------
  // Items and checkers
  // --------------------------------------------------------------------------
  typedef enum int {
    I_EXT_NTT, I_EXT_INTT, I_EXT_BM, I_BM_KEEP_B,
    I_RND_NTT, I_RND_INTT, I_RND_BM,
    I_DIR_NTT, I_DIR_INTT, I_DIR_BM,
    I_RT_CT_GS, I_RT_GS_CT,
    I_PM_FHAT, I_PM_GHAT, I_PM_PROD,
    I_NONE,
    N_ITEM
  } item_e;

  localparam string ITEM_NAME [N_ITEM] = '{
    "ext_ntt", "ext_intt", "ext_bm", "bm_keep_b",
    "rnd_ntt", "rnd_intt", "rnd_bm",
    "dir_ntt", "dir_intt", "dir_bm",
    "rt_ct_gs", "rt_gs_ct",
    "pm_fhat", "pm_ghat", "pm_prod",
    "none"
  };

  tb_checker chk_item [N_ITEM];
  longint    coef_mm  [N_ITEM];
  tb_checker chk_golden, chk_stream, chk_ctrl, chk_cycles, chk_gap;

  // bfu input probe (inside the DUT): idle cycles between two bfu inputs of
  // different mode (op boundary). arch.md: the core waits at least LATENCY
  // cycles at every op boundary (needed by SHARE_ADDSUB = 1, CT -> GS).
  longint bfu_last_cyc = -1;
  int     bfu_last_mode = -1;
  int     gap_min [2] = '{1 << 30, 1 << 30};   // [0] CT -> GS, [1] GS -> CT
  int     n_switch [2] = '{0, 0};

  typedef int poly_t [N_COEF];

  class op_rec;
    op_e    op;
    bit     bank;
    int     res_bank;
    item_e  item;          // UNLOAD: item of the comparison
    bit     chk;           // UNLOAD: compare with exp
    poly_t  data;          // LOAD: words to send
    poly_t  exp;           // UNLOAD: expected words
    poly_t  got;           // UNLOAD: received words
    int     n_hs;
    int     n_idle;        // LOAD idle / UNLOAD stall cycles
    longint t_acc;
    longint ncyc;
    bit     done;
  endclass

  op_rec  exp_q [$];
  op_rec  cur;
  int     n_issued, n_accepted, n_done;
  int     src_q [$];
  int     gap_pct_cur, rdy_pct_cur;
  longint cyc;
  bit     m_hold;
  logic [COEF_W-1:0] m_hold_data;

  // cycle statistics, index op_e
  longint cyc_min [5], cyc_max [5], cyc_nostall [5];
  int     n_op [5], n_op_nostall [5];

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
    else c.fail($sformatf("cyc %0d: %s", cyc, msg));
  endfunction

  // --------------------------------------------------------------------------
  // Monitor (falling edge)
  // --------------------------------------------------------------------------
  function automatic void finish_op(op_rec r);
    longint exp_cyc;
    int     nbad;
    r.ncyc = cyc - r.t_acc;
    ck(chk_ctrl, int'(result_bank_o) == r.res_bank,
       $sformatf("%s bank %0d: result_bank_o %0d, expected %0d", op_name(r.op), r.bank, result_bank_o, r.res_bank));
    case (r.op)
      OP_LOAD:    exp_cyc = CYC_LOAD + r.n_idle;
      OP_UNLOAD:  exp_cyc = CYC_UNLOAD + r.n_idle;
      OP_BASEMUL: exp_cyc = CYC_BM;
      default:    exp_cyc = CYC_XF;
    endcase
    ck(chk_cycles, r.ncyc == exp_cyc,
       $sformatf("%s: %0d cycles from start to done, expected %0d (idle/stall %0d)",
                 op_name(r.op), r.ncyc, exp_cyc, r.n_idle));
    if (n_op[r.op] == 0 || r.ncyc < cyc_min[r.op]) cyc_min[r.op] = r.ncyc;
    if (n_op[r.op] == 0 || r.ncyc > cyc_max[r.op]) cyc_max[r.op] = r.ncyc;
    n_op[r.op]++;
    if (r.n_idle == 0) begin
      if (n_op_nostall[r.op] == 0) cyc_nostall[r.op] = r.ncyc;
      else if (cyc_nostall[r.op] != r.ncyc) chk_cycles.fail($sformatf("%s stall-free cycles %0d != earlier %0d",
                                                                     op_name(r.op), r.ncyc, cyc_nostall[r.op]));
      n_op_nostall[r.op]++;
    end
    if (r.op == OP_LOAD || r.op == OP_UNLOAD)
      ck(chk_stream, r.n_hs == N_COEF, $sformatf("%s: %0d words, expected %0d", op_name(r.op), r.n_hs, N_COEF));
    if (r.op == OP_UNLOAD && r.chk) begin
      nbad = 0;
      for (int i = 0; i < N_COEF; i++) if (r.got[i] != r.exp[i]) nbad++;
      coef_mm[r.item] += nbad;
      if (nbad == 0) chk_item[r.item].pass();
      else begin
        int i0 = 0;
        while (r.got[i0] == r.exp[i0]) i0++;
        chk_item[r.item].fail($sformatf("op #%0d UNLOAD bank %0d: %0d of %0d coefficients differ, first [%0d] got %0d expected %0d",
                                        n_done, r.bank, nbad, N_COEF, i0, r.got[i0], r.exp[i0]));
      end
    end
    r.done = 1;
    n_done++;
  endfunction

  always @(negedge clk) begin
    if (rst_n) begin
      bit done_now, hs;
      cyc++;
      ck(chk_ctrl, !$isunknown({busy_o, done_o, result_bank_o, s_ready_o, m_valid_o}), "X on a status output");
      if (m_valid_o === 1'b1) ck(chk_stream, !$isunknown(m_data_o), "m_data_o X while m_valid_o = 1");
      done_now = (done_o === 1'b1);
      if (dut.u_bfu.valid_i === 1'b1) begin
        automatic int m = int'(dut.u_bfu.mode_i);
        if (bfu_last_mode >= 0 && m != bfu_last_mode) begin
          automatic int gap = int'(cyc - bfu_last_cyc - 1);
          automatic int k   = (bfu_last_mode == int'(MODE_CT)) ? 0 : 1;
          n_switch[k]++;
          if (gap < gap_min[k]) gap_min[k] = gap;
          ck(chk_gap, gap >= L, $sformatf("bfu mode %0d -> %0d after %0d idle cycles < LATENCY %0d",
                                          bfu_last_mode, m, gap, L));
        end
        bfu_last_cyc  = cyc;
        bfu_last_mode = m;
      end
      if (cur != null) begin
        ck(chk_ctrl, busy_o == !done_now, $sformatf("busy_o=%b done_o=%b while %s runs", busy_o, done_o, op_name(cur.op)));
        if (cyc - cur.t_acc > WATCHDOG) $fatal(1, "watchdog: %s did not finish", op_name(cur.op));
        case (cur.op)
          OP_LOAD: begin
            hs = s_valid_i && s_ready_o;
            ck(chk_stream, s_ready_o == busy_o && !m_valid_o,
               $sformatf("LOAD: s_ready_o=%b busy_o=%b m_valid_o=%b", s_ready_o, busy_o, m_valid_o));
            if (hs) begin
              if (cur.n_hs < N_COEF)
                ck(chk_stream, s_data_i == COEF_W'(cur.data[cur.n_hs]), $sformatf("TB source order, word %0d", cur.n_hs));
              cur.n_hs++;
            end else if (s_ready_o) cur.n_idle++;
          end
          OP_UNLOAD: begin
            hs = m_valid_o && m_ready_i;
            ck(chk_stream, !s_ready_o, "UNLOAD: s_ready_o = 1");
            if (m_hold)
              ck(chk_stream, m_valid_o && m_data_o === m_hold_data,
                 $sformatf("UNLOAD word %0d changed under backpressure: m_valid_o=%b data=%0d held %0d",
                           cur.n_hs, m_valid_o, m_data_o, m_hold_data));
            if (hs) begin
              if (cur.n_hs < N_COEF) cur.got[cur.n_hs] = int'(m_data_o);
              else chk_stream.fail($sformatf("cyc %0d: UNLOAD word beyond %0d", cyc, N_COEF));
              cur.n_hs++;
            end
            if (m_valid_o && !m_ready_i) cur.n_idle++;
            m_hold      = m_valid_o && !m_ready_i;
            m_hold_data = m_data_o;
          end
          default: begin
            ck(chk_stream, !s_ready_o && !m_valid_o,
               $sformatf("%s: s_ready_o=%b m_valid_o=%b", op_name(cur.op), s_ready_o, m_valid_o));
          end
        endcase
        if (done_now) begin
          finish_op(cur);
          cur = null;
        end
      end else begin
        ck(chk_ctrl, !done_now && !busy_o && !s_ready_o && !m_valid_o,
           $sformatf("idle: done_o=%b busy_o=%b s_ready_o=%b m_valid_o=%b", done_o, busy_o, s_ready_o, m_valid_o));
      end
      if (start_i === 1'b1 && busy_o === 1'b0) begin
        if (exp_q.size() == 0) $fatal(1, "start accepted with no expectation");
        cur = exp_q.pop_front();
        ck(chk_ctrl, cur.op == op_i && (cur.op == OP_BASEMUL || cur.bank == bank_i),
           $sformatf("accepted op %0d bank %0d, TB issued %s bank %0d", op_i, bank_i, op_name(cur.op), cur.bank));
        cur.t_acc = cyc;
        m_hold    = 0;
        n_accepted++;
      end
    end
  end

  // --------------------------------------------------------------------------
  // Stream drivers
  // --------------------------------------------------------------------------
  task automatic src_driver();
    forever begin
      @(posedge clk);
      if (s_valid_i && s_ready_o) void'(src_q.pop_front());
      if (!(s_valid_i && !s_ready_o)) begin     // AXI4-Stream: hold an unaccepted word
        if (src_q.size() > 0 && $urandom_range(99) >= gap_pct_cur) begin
          s_valid_i <= 1'b1;
          s_data_i  <= COEF_W'(src_q[0]);
        end else begin
          s_valid_i <= 1'b0;
          s_data_i  <= COEF_W'($urandom_range(2 ** COEF_W - 1));
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

  // --------------------------------------------------------------------------
  // Op issue
  // --------------------------------------------------------------------------
  task automatic issue(op_rec r, bit early);
    r.done   = 0;
    r.n_hs   = 0;
    r.n_idle = 0;
    exp_q.push_back(r);
    n_issued++;
    if (r.op == OP_LOAD) foreach (r.data[i]) src_q.push_back(r.data[i]);
    if (!early) begin
      wait (n_done == n_issued - 1);
      repeat ($urandom_range(3)) @(posedge clk);
    end
    @(posedge clk);
    start_i <= 1'b1;
    op_i    <= r.op;
    bank_i  <= r.bank;
    wait (n_accepted == n_issued);
    @(posedge clk);
    start_i <= 1'b0;
    op_i    <= op_e'($urandom_range(7));
    bank_i  <= $urandom_range(1);
  endtask

  task automatic do_load(bit bank, poly_t d, bit early);
    op_rec r = new();
    r.op = OP_LOAD; r.bank = bank; r.res_bank = bank; r.data = d; r.item = I_NONE;
    issue(r, early);
  endtask

  task automatic do_xf(op_e op, bit bank, bit early);
    op_rec r = new();
    r.op = op; r.bank = bank; r.res_bank = (op == OP_BASEMUL) ? 0 : int'(!bank); r.item = I_NONE;
    issue(r, early);
  endtask

  task automatic do_unload(bit bank, poly_t e, item_e it, bit early, output op_rec r);
    r = new();
    r.op = OP_UNLOAD; r.bank = bank; r.res_bank = bank; r.exp = e; r.item = it; r.chk = 1;
    issue(r, early);
  endtask

  task automatic wait_rec(op_rec r);
    wait (r.done);
  endtask

  // --------------------------------------------------------------------------
  // Golden helpers
  // --------------------------------------------------------------------------
  function automatic void gx(bit ok, string msg);
    if (ok) chk_golden.pass();
    else chk_golden.fail(msg);
  endfunction

  function automatic bit poly_eq(poly_t a, poly_t b);
    foreach (a[i]) if (a[i] != b[i]) return 0;
    return 1;
  endfunction

  // Independent negacyclic schoolbook product (int arithmetic and %).
  function automatic void schoolbook(poly_t f, poly_t g, output poly_t h);
    longint acc [2 * N_COEF];
    foreach (acc[k]) acc[k] = 0;
    for (int i = 0; i < N_COEF; i++)
      for (int j = 0; j < N_COEF; j++)
        acc[i + j] += longint'(f[i]) * longint'(g[j]);
    for (int k = 0; k < N_COEF; k++) begin
      longint v = (acc[k] - acc[k + N_COEF]) % Q;
      if (v < 0) v += Q;
      h[k] = int'(v);
    end
  endfunction

  function automatic void exp_ntt(poly_t f, output poly_t e, input string what);
    poly_t r;
    int rc = mlkem_dpi_hw_ntt(ALGO, f, e);
    mlkem_dpi_ntt(f, r);
    gx(rc == 0 && poly_eq(e, r), $sformatf("%s: hw_ntt (rc %0d) != reference ntt", what, rc));
  endfunction

  function automatic void exp_intt(poly_t f, output poly_t e, input string what);
    poly_t r;
    int rc = mlkem_dpi_hw_intt(ALGO, f, e);
    mlkem_dpi_intt(f, r);
    gx(rc == 0 && poly_eq(e, r), $sformatf("%s: hw_intt (rc %0d) != reference intt", what, rc));
  endfunction

  function automatic void exp_bm(poly_t a, poly_t b, output poly_t e, input string what);
    poly_t r;
    int rc = mlkem_dpi_hw_basemul(ALGO, a, b, e);
    mlkem_dpi_multiply_ntts(a, b, r);
    gx(rc == 0 && poly_eq(e, r), $sformatf("%s: hw_basemul (rc %0d) != reference multiply_ntts", what, rc));
  endfunction

  // --------------------------------------------------------------------------
  // Vector files
  // --------------------------------------------------------------------------
  logic [COEF_W-1:0] x_ntt_in   [NX_NTT * N_COEF];
  logic [COEF_W-1:0] x_ntt_out  [NX_NTT * N_COEF];
  logic [COEF_W-1:0] x_intt_in  [NX_INTT * N_COEF];
  logic [COEF_W-1:0] x_intt_out [NX_INTT * N_COEF];
  logic [COEF_W-1:0] x_bm_a     [NX_BM * N_COEF];
  logic [COEF_W-1:0] x_bm_b     [NX_BM * N_COEF];
  logic [COEF_W-1:0] x_bm_out   [NX_BM * N_COEF];
  logic [COEF_W-1:0] m_pm_f     [NX_MPM * N_COEF];
  logic [COEF_W-1:0] m_pm_g     [NX_MPM * N_COEF];
  logic [COEF_W-1:0] m_pm_h     [NX_MPM * N_COEF];

  typedef enum int {
    F_NTT_IN, F_NTT_OUT, F_INTT_IN, F_INTT_OUT, F_BM_A, F_BM_B, F_BM_OUT, F_PM_F, F_PM_G, F_PM_H
  } file_e;

  function automatic logic [COEF_W-1:0] fget(file_e fid, int k);
    case (fid)
      F_NTT_IN:   return x_ntt_in[k];
      F_NTT_OUT:  return x_ntt_out[k];
      F_INTT_IN:  return x_intt_in[k];
      F_INTT_OUT: return x_intt_out[k];
      F_BM_A:     return x_bm_a[k];
      F_BM_B:     return x_bm_b[k];
      F_BM_OUT:   return x_bm_out[k];
      F_PM_F:     return m_pm_f[k];
      F_PM_G:     return m_pm_g[k];
      default:    return m_pm_h[k];
    endcase
  endfunction

  // Polynomial idx of a vector file; fatal on X or out-of-range words.
  function automatic void get_poly(file_e fid, int idx, string fname, output poly_t p);
    for (int i = 0; i < N_COEF; i++) begin
      logic [COEF_W-1:0] v = fget(fid, idx * N_COEF + i);
      if ($isunknown(v) || v >= COEF_W'(Q))
        $fatal(1, "%s: polynomial %0d coefficient %0d = %h (missing line or out of range)", fname, idx, i, v);
      p[i] = int'(v);
    end
  endfunction

  // n polynomials spread over a file of total ones.
  function automatic int pick(int i, int n, int total);
    return (n >= total) ? i : int'((longint'(i) * total) / n);
  endfunction

  // --------------------------------------------------------------------------
  // Directed polynomials
  // --------------------------------------------------------------------------
  localparam int N_DIR = 24;

  function automatic void dir_poly(int c, output poly_t f);
    for (int i = 0; i < N_COEF; i++) begin
      case (c)
        0:  f[i] = 0;
        1:  f[i] = Q - 1;
        2:  f[i] = 1;
        3:  f[i] = (i == 0)   ? 1 : 0;
        4:  f[i] = (i == 1)   ? 1 : 0;
        5:  f[i] = (i == 127) ? 1 : 0;
        6:  f[i] = (i == 128) ? 1 : 0;
        7:  f[i] = (i == 255) ? 1 : 0;
        8:  f[i] = (i == 0)   ? Q - 1 : 0;
        9:  f[i] = (i == 64)  ? Q - 1 : 0;
        10: f[i] = (i == 129) ? Q - 1 : 0;
        11: f[i] = (i == 255) ? Q - 1 : 0;
        12: f[i] = (i == 200) ? Q - 1 : 1;              // single Q-1 among ones
        13: f[i] = (i % 2 == 0) ? 0 : Q - 1;            // alternating 0 / Q-1
        14: f[i] = (i % 2 == 0) ? Q - 1 : 0;
        15: f[i] = (i % 2 == 0) ? 1 : 0;
        16: f[i] = i;                                   // ramp
        17: f[i] = (Q - 1) - i;
        18: f[i] = (i * 13) % Q;
        19: f[i] = (i % 2 == 0) ? (Q - 1) / 2 : (Q + 1) / 2;
        20: f[i] = (i < 128) ? Q - 1 : 0;               // half blocks
        21: f[i] = (i % 4 < 2) ? Q - 1 : 1;
        22: f[i] = (Q - 1) - (i * 97) % Q;
        default: f[i] = (i == 2 || i == 3) ? Q - 1 : 0; // two adjacent Q-1
      endcase
    end
  endfunction

  function automatic void rnd_poly(output poly_t f);
    foreach (f[i]) f[i] = $urandom_range(Q - 1);
  endfunction

  // --------------------------------------------------------------------------
  // Tests
  // --------------------------------------------------------------------------
  int test_no;
  int gap_pct, rdy_pct;

  // Stall setting of a test: even tests stall-free, odd tests with stalls.
  task automatic set_stall(bit stall);
    gap_pct_cur = stall ? gap_pct : 0;
    rdy_pct_cur = stall ? rdy_pct : 0;
  endtask

  function automatic bit rbit();
    return bit'($urandom_range(1));
  endfunction

  // LOAD b f; op b; UNLOAD ~b == e
  task automatic t_xf(op_e op, poly_t f, poly_t e, item_e it);
    op_rec u;
    bit    b = bit'(test_no & 1);
    do_load(b, f, 0);
    do_xf(op, b, rbit());
    do_unload(!b, e, it, rbit(), u);
    test_no++;
  endtask

  // LOAD 0 a / LOAD 1 bb (random order); BASEMUL; UNLOAD 0 == e; optionally UNLOAD 1 == bb
  task automatic t_bm(poly_t a, poly_t bb, poly_t e, item_e it, bit keep_b);
    op_rec u;
    if (rbit()) begin
      do_load(0, a, 0);
      do_load(1, bb, rbit());
    end else begin
      do_load(1, bb, 0);
      do_load(0, a, rbit());
    end
    do_xf(OP_BASEMUL, 0, rbit());
    do_unload(0, e, it, rbit(), u);
    if (keep_b) do_unload(1, bb, I_BM_KEEP_B, rbit(), u);
    test_no++;
  endtask

  // Round trip: LOAD b f; first b; second ~b (early, back to back); UNLOAD b == f
  task automatic t_rt(op_e first, poly_t f);
    op_rec u;
    bit    b = bit'(test_no & 1);
    do_load(b, f, 0);
    do_xf(first, b, rbit());
    do_xf((first == OP_NTT) ? OP_INTT : OP_NTT, !b, 1);
    do_unload(b, f, (first == OP_NTT) ? I_RT_CT_GS : I_RT_GS_CT, rbit(), u);
    test_no++;
  endtask

  // Polynomial product chain (header), h = expected f * g.
  task automatic t_pm(poly_t f, poly_t g, poly_t h, string what);
    poly_t fh, gh, hh, hw;
    op_rec uf, ug, up;
    // golden chain on the hardware model: must equal h
    exp_ntt(f, fh, what);
    exp_ntt(g, gh, what);
    exp_bm(fh, gh, hh, what);
    exp_intt(hh, hw, what);
    gx(poly_eq(hw, h), $sformatf("%s: hw chain intt(basemul(ntt f, ntt g)) != expected product", what));
    do_load(0, f, 0);
    do_xf(OP_NTT, 0, 1);
    do_unload(1, fh, I_PM_FHAT, 1, uf);
    do_load(0, g, 1);
    do_xf(OP_NTT, 0, 1);
    // g^ stays in bank1; it is checked through the product and, every other
    // chain, read out before BASEMUL (UNLOAD does not change the bank)
    if (test_no % 2 == 0) do_unload(1, gh, I_PM_GHAT, 1, ug);
    wait_rec(uf);
    do_load(0, uf.got, 1);                       // round trip: the words just unloaded
    do_xf(OP_BASEMUL, 0, 1);
    do_xf(OP_INTT, 0, 1);                        // BASEMUL (CT) -> INTT (GS) back to back
    do_unload(1, h, I_PM_PROD, 1, up);
    test_no++;
  endtask

  // Out-of-range input words (L3_RANGE).
  task automatic t_oor();
    poly_t f;
    op_rec u;
    rnd_poly(f);
    do_load(0, f, 0);
    do_unload(0, f, I_DIR_NTT, 0, u);            // clean round trip through bank0
    f[0]   = Q;
    f[100] = 2 ** COEF_W - 1;
    f[255] = Q + 1;
    do_load(1, f, 0);
    wait (n_done == n_issued);
    $display("OOR_TEST: loaded %0d words >= Q (L3_RANGE must fire %0d times)", OOR_N, OOR_N);
  endtask

  // --------------------------------------------------------------------------
  // Main
  // --------------------------------------------------------------------------
  initial begin
    int unsigned seed;
    int          n_ext_ntt, n_ext_intt, n_ext_bm, n_rand, n_rt, n_chain, n_mpm;
    bit          oor_test, ok;
    string       ext_dir, mvec_dir, an;
    poly_t       f, g, e, e2;
    tb_checker   rep [$];
    bit          used [N_ITEM];

    seed       = tb_seed_from_plusarg();
    gap_pct    = 30;
    rdy_pct    = 30;
    n_ext_ntt  = NX_NTT;
    n_ext_intt = NX_INTT;
    n_ext_bm   = NX_BM;
    n_rand     = 1000;
    n_rt       = 32;
    n_chain    = 32;
    n_mpm      = NX_MPM;
    ext_dir    = "../../data/vectors/ext";
    mvec_dir   = "../../model/vectors";
    void'($value$plusargs("GAP_PCT=%d", gap_pct));
    void'($value$plusargs("RDY_PCT=%d", rdy_pct));
    void'($value$plusargs("N_EXT_NTT=%d", n_ext_ntt));
    void'($value$plusargs("N_EXT_INTT=%d", n_ext_intt));
    void'($value$plusargs("N_EXT_BM=%d", n_ext_bm));
    void'($value$plusargs("N_RAND=%d", n_rand));
    void'($value$plusargs("N_RT=%d", n_rt));
    void'($value$plusargs("N_CHAIN=%d", n_chain));
    void'($value$plusargs("N_MPM=%d", n_mpm));
    void'($value$plusargs("EXT_DIR=%s", ext_dir));
    void'($value$plusargs("MVEC_DIR=%s", mvec_dir));
    oor_test = $test$plusargs("OOR_TEST");
    if (n_ext_ntt > NX_NTT)   n_ext_ntt  = NX_NTT;
    if (n_ext_intt > NX_INTT) n_ext_intt = NX_INTT;
    if (n_ext_bm > NX_BM)     n_ext_bm   = NX_BM;
    if (n_mpm > NX_MPM)       n_mpm      = NX_MPM;
    an = algo_name(ALGO);
    $display("TB_CONFIG: tb_ntt_core ALGO=%0d(%s) PRE_REG=%0d MUL_REG=%0d RED_PIPE=%0d OUT_REG=%0d SHARE_ADDSUB=%0d ROM_OUT_REG=%0d L=%0d NOPS=%0d SEED=%0d GAP_PCT=%0d RDY_PCT=%0d N_EXT_NTT=%0d N_EXT_INTT=%0d N_EXT_BM=%0d N_RAND=%0d N_RT=%0d N_CHAIN=%0d N_MPM=%0d OOR_TEST=%0d",
             ALGO, an, PRE_REG, MUL_REG, RED_PIPE, OUT_REG, SHARE_ADDSUB, ROM_OUT_REG, L, NOPS, seed,
             gap_pct, rdy_pct, n_ext_ntt, n_ext_intt, n_ext_bm, n_rand, n_rt, n_chain, n_mpm, oor_test);

    foreach (chk_item[i]) begin
      chk_item[i] = new(ITEM_NAME[i]);
      coef_mm[i]  = 0;
      used[i]     = 0;
    end
    chk_golden = new("golden");
    chk_stream = new("stream");
    chk_ctrl   = new("ctrl");
    chk_cycles = new("cycles");
    chk_gap    = new("op_gap");
    foreach (n_op[i]) begin n_op[i] = 0; n_op_nostall[i] = 0; cyc_nostall[i] = -1; end
    cyc = 0; n_issued = 0; n_accepted = 0; n_done = 0; test_no = 0; cur = null; m_hold = 0;

    // golden program length and DUT latency vs the TB expressions
    gx(mlkem_dpi_basemul_nops(ALGO) == NOPS, "basemul op count of the golden model != TB NOPS");
    gx(dut.u_bfu.LATENCY == L, $sformatf("bfu LATENCY %0d != TB L %0d", dut.u_bfu.LATENCY, L));

    if (!oor_test) begin
      if (n_ext_ntt > 0) begin
        $readmemh({ext_dir, "/ntt_in.hex"}, x_ntt_in);
        $readmemh({ext_dir, "/ntt_out.hex"}, x_ntt_out);
      end
      if (n_ext_intt > 0) begin
        $readmemh({ext_dir, "/intt_in.hex"}, x_intt_in);
        $readmemh({ext_dir, "/intt_out.hex"}, x_intt_out);
      end
      if (n_ext_bm > 0) begin
        $readmemh({ext_dir, "/basemul_a.hex"}, x_bm_a);
        $readmemh({ext_dir, "/basemul_b.hex"}, x_bm_b);
        $readmemh({ext_dir, "/basemul_out.hex"}, x_bm_out);
      end
      if (n_mpm > 0) begin
        $readmemh({mvec_dir, "/polymul_f.hex"}, m_pm_f);
        $readmemh({mvec_dir, "/polymul_g.hex"}, m_pm_g);
        $readmemh({mvec_dir, "/polymul_h.hex"}, m_pm_h);
      end
    end

    set_stall(0);
    fork
      src_driver();
      sink_driver();
    join_none

    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(posedge clk);

    if (oor_test) begin
      t_oor();
      used[I_DIR_NTT] = 1;
    end else begin
      // ---- directed, stall-free ----
      set_stall(0);
      for (int c = 0; c < N_DIR; c++) begin
        dir_poly(c, f);
        exp_ntt(f, e, $sformatf("dir %0d", c));
        t_xf(OP_NTT, f, e, I_DIR_NTT);
        exp_intt(f, e, $sformatf("dir %0d", c));
        t_xf(OP_INTT, f, e, I_DIR_INTT);
      end
      for (int c = 0; c < N_DIR; c++) begin
        for (int k = 0; k < 3; k++) begin
          automatic int d = (k == 0) ? c : (k == 1) ? (c + 1) % N_DIR : N_DIR - 1 - c;
          dir_poly(c, f);
          dir_poly(d, g);
          exp_bm(f, g, e, $sformatf("dir %0d x %0d", c, d));
          t_bm(f, g, e, I_DIR_BM, k == 0);
        end
      end
      used[I_DIR_NTT] = 1; used[I_DIR_INTT] = 1; used[I_DIR_BM] = 1; used[I_BM_KEEP_B] = 1;
      $display("PROGRESS: directed done, ops %0d, cycle %0d", n_issued, cyc);

      // ---- external vectors ----
      for (int i = 0; i < n_ext_ntt; i++) begin
        automatic int k = pick(i, n_ext_ntt, NX_NTT);
        get_poly(F_NTT_IN, k, "ntt_in.hex", f);
        get_poly(F_NTT_OUT, k, "ntt_out.hex", e);
        exp_ntt(f, e2, $sformatf("ext ntt %0d", k));
        gx(poly_eq(e, e2), $sformatf("ext ntt %0d: file output != hw_ntt", k));
        set_stall(i & 1);
        t_xf(OP_NTT, f, e, I_EXT_NTT);
      end
      for (int i = 0; i < n_ext_intt; i++) begin
        automatic int k = pick(i, n_ext_intt, NX_INTT);
        get_poly(F_INTT_IN, k, "intt_in.hex", f);
        get_poly(F_INTT_OUT, k, "intt_out.hex", e);
        exp_intt(f, e2, $sformatf("ext intt %0d", k));
        gx(poly_eq(e, e2), $sformatf("ext intt %0d: file output != hw_intt", k));
        set_stall(i & 1);
        t_xf(OP_INTT, f, e, I_EXT_INTT);
      end
      for (int i = 0; i < n_ext_bm; i++) begin
        automatic int k = pick(i, n_ext_bm, NX_BM);
        get_poly(F_BM_A, k, "basemul_a.hex", f);
        get_poly(F_BM_B, k, "basemul_b.hex", g);
        get_poly(F_BM_OUT, k, "basemul_out.hex", e);
        exp_bm(f, g, e2, $sformatf("ext bm %0d", k));
        gx(poly_eq(e, e2), $sformatf("ext bm %0d: file output != hw_basemul", k));
        set_stall(i & 1);
        t_bm(f, g, e, I_EXT_BM, i % 8 == 7);
      end
      if (n_ext_ntt > 0)  used[I_EXT_NTT] = 1;
      if (n_ext_intt > 0) used[I_EXT_INTT] = 1;
      if (n_ext_bm > 0)   used[I_EXT_BM] = 1;
      $display("PROGRESS: external done, ops %0d, cycle %0d", n_issued, cyc);

      // ---- golden random ----
      for (int i = 0; i < n_rand; i++) begin
        set_stall(i & 1);
        rnd_poly(f);
        exp_ntt(f, e, $sformatf("rnd ntt %0d", i));
        t_xf(OP_NTT, f, e, I_RND_NTT);
        rnd_poly(f);
        exp_intt(f, e, $sformatf("rnd intt %0d", i));
        t_xf(OP_INTT, f, e, I_RND_INTT);
        rnd_poly(f);
        rnd_poly(g);
        exp_bm(f, g, e, $sformatf("rnd bm %0d", i));
        t_bm(f, g, e, I_RND_BM, 0);
      end
      if (n_rand > 0) begin used[I_RND_NTT] = 1; used[I_RND_INTT] = 1; used[I_RND_BM] = 1; end
      $display("PROGRESS: random done, ops %0d, cycle %0d", n_issued, cyc);

      // ---- round trips (random and directed) ----
      for (int i = 0; i < n_rt; i++) begin
        set_stall(i & 1);
        if (i < N_DIR) dir_poly(i, f); else rnd_poly(f);
        t_rt(OP_NTT, f);
        if (i < N_DIR) dir_poly(N_DIR - 1 - i, f); else rnd_poly(f);
        t_rt(OP_INTT, f);
      end
      if (n_rt > 0) begin used[I_RT_CT_GS] = 1; used[I_RT_GS_CT] = 1; end

      // ---- polynomial products ----
      for (int i = 0; i < n_mpm; i++) begin
        poly_t h, hs;
        get_poly(F_PM_F, i, "polymul_f.hex", f);
        get_poly(F_PM_G, i, "polymul_g.hex", g);
        get_poly(F_PM_H, i, "polymul_h.hex", h);
        schoolbook(f, g, hs);
        gx(poly_eq(h, hs), $sformatf("model polymul %0d: file h != SV schoolbook", i));
        set_stall(i & 1);
        t_pm(f, g, h, $sformatf("model polymul %0d", i));
      end
      for (int i = 0; i < n_chain; i++) begin
        poly_t h, fh, gh, hh, hr;
        rnd_poly(f);
        rnd_poly(g);
        schoolbook(f, g, h);
        mlkem_dpi_ntt(f, fh);
        mlkem_dpi_ntt(g, gh);
        mlkem_dpi_multiply_ntts(fh, gh, hh);
        mlkem_dpi_intt(hh, hr);
        gx(poly_eq(h, hr), $sformatf("random product %0d: schoolbook != reference intt(multiply_ntts)", i));
        set_stall(i & 1);
        t_pm(f, g, h, $sformatf("random product %0d", i));
      end
      if (n_mpm + n_chain > 0) begin used[I_PM_FHAT] = 1; used[I_PM_GHAT] = 1; used[I_PM_PROD] = 1; end
    end

    wait (n_done == n_issued);
    repeat (5) @(posedge clk);
    @(negedge clk);

    $display("OPS: issued=%0d done=%0d tests=%0d cycles=%0d", n_issued, n_done, test_no, cyc);
    for (int o = 0; o < 5; o++)
      $display("CYCLES: algo=%s L=%0d ROM_OUT_REG=%0d SHARE_ADDSUB=%0d op=%s n=%0d nostall_n=%0d nostall=%0d min=%0d max=%0d",
               an, L, ROM_OUT_REG, SHARE_ADDSUB, op_name(op_e'(o)), n_op[o], n_op_nostall[o], cyc_nostall[o],
               cyc_min[o], cyc_max[o]);
    $display("GAP: bfu mode switches CT->GS n=%0d min idle=%0d, GS->CT n=%0d min idle=%0d (LATENCY %0d)",
             n_switch[0], gap_min[0], n_switch[1], gap_min[1], L);
    $display("CYCLES_EXPECTED: NTT/INTT %0d BASEMUL %0d LOAD %0d UNLOAD %0d (stall-free)",
             CYC_XF, CYC_BM, CYC_LOAD, CYC_UNLOAD);
    for (int i = 0; i < N_ITEM; i++)
      if (used[i])
        $display("ITEM: %s polys=%0d poly_mismatch=%0d coef_mismatch=%0d",
                 ITEM_NAME[i], chk_item[i].n_checks, chk_item[i].n_mismatch, coef_mm[i]);
    if (n_done != n_issued) chk_ctrl.fail("not all ops finished");
    for (int i = 0; i < N_ITEM; i++) if (used[i]) rep.push_back(chk_item[i]);
    rep.push_back(chk_golden);
    rep.push_back(chk_stream);
    rep.push_back(chk_ctrl);
    rep.push_back(chk_cycles);
    if (!oor_test) rep.push_back(chk_gap);
    ok = tb_final_report(rep);
    $finish;
  end

endmodule
