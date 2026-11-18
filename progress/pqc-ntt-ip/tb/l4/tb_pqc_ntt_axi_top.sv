// tb_pqc_ntt_axi_top: self-checking testbench of the L4 top pqc_ntt_axi_top.
//
// The DUT is driven only through its AXI4-Lite port by a BFM written here
// (tasks axi_write / axi_read), in the order of the PS driver
// fpga/sw/pqc_ntt.c: CTRL start LOAD, DIN x 256 (optionally STATUS in_ready
// polls before each word), CTRL start op, poll STATUS until done_sticky,
// CYCLES, ERR, CTRL start UNLOAD, DOUT x 256 (optionally out_valid polls).
// Expected results come from the external vector files and the golden model
// (DPI-C) in the same way as tb/l3/tb_ntt_core.sv, with the same golden
// cross-checks.
//
// Register map and behaviour are written here from docs/spec/l4_axi.md, not
// taken from the RTL.
//
// Layers of checking:
//  1. Polynomial items (one check = one polynomial):
//       ext_ntt / ext_intt / ext_bm   external vectors (+N_EXT_*, spread over the file)
//       rnd_*                         +N_RAND random polynomials (pairs) per op
//       dir_*                         +N_DIR directed polynomials per op (all 0,
//                                     all Q-1, impulses, ramps, ...)
//       bm_keep_b                     BASEMUL leaves bank1 (b) unchanged
//       pm_rt_fhat / pm_rt_prod       product, both operands in the coefficient
//                                     domain: LOAD0 f, NTT0, UNLOAD1 (f^),
//                                     LOAD0 g, NTT0, LOAD0 f^, BASEMUL, INTT0,
//                                     UNLOAD1 = f * g (arch.md "L3 results")
//       pm_nort                       product, one operand already NTT domain:
//                                     LOAD0 r, NTT0, LOAD0 a^, BASEMUL, INTT0,
//                                     UNLOAD1 = a * r (no round trip)
//       corner                        results of ops after error / collision /
//                                     reset scenarios
//       din_range                     words >= Q written to DIN come back as
//                                     their low 12 bits (+ERR_TEST)
//     Products use model/vectors polymul_f/g/h (+N_MPM) and random pairs
//     (+N_CHAIN); expected h is checked against an SV schoolbook product.
//  2. Scenario register checks (checker regs): reset values, VERSION, CONFIG,
//     STATUS at every done_sticky (busy 0, result_bank), ERR after every op,
//     every ERR bit provoked and cleared by W1C, undefined addresses, write
//     only registers, writes to read only registers, busy start, illegal op.
//  3. CYCLES (checker cycles): after every op CYCLES must equal the cycles
//     the TB measures on the ntt_core ports (start accepted -> done_o), and for
//     NTT / INTT / BASEMUL also the arch.md formula
//       NTT / INTT 897 + 7 (1 + L), BASEMUL 128 n (L + 1) + 3.
//  4. Cycle model (checker model): a reference model of the register file,
//     written from the spec, steps every cycle with the accesses the DUT
//     performed (a write / read is performed in the cycle before its B / R
//     response starts) and the ntt_core outputs of that cycle. It predicts
//     every read data word and the ntt_core command / stream handshakes
//     (start accepted, DIN handshake + data, DOUT pop) of every cycle. A
//     double pop, a lost word or a start the spec does not allow is a
//     mismatch even when the polynomial results happen to be right.
//  5. AXI protocol (checker axi): BVALID / RVALID never drop before READY and
//     BRESP / RDATA / RRESP stay stable meanwhile, no response without a
//     request (one response per request, in order), responses OKAY, no X on
//     the handshake outputs, every request answered at the end.
//  6. Collisions (checker coll): a CTRL write performed exactly in the done_o
//     cycle (without start: done_sticky stays 0; with start: accepted), and an
//     ERR W1C performed in the cycle the same ERR bit is set (bit stays set).
//     The model counts that the collision really happened.
//
// AXI stimulus: per test either fast (no delays, no polls) or slow: random
// AW / W order (same cycle, AW first, W first) and delays up to +MAXD,
// random BREADY / RREADY delays, STATUS polls before each DIN / DOUT, random
// WSTRB (ignored by the spec) and random DIN bits [31:12] (ignored). Every
// fourth slow test runs a noise thread in parallel that issues harmless reads
// (STATUS, CYCLES, VERSION, CONFIG, ERR, write only and undefined addresses)
// and writes (ERR with 0, read only and undefined addresses), so reads and
// writes overlap with the DIN / DOUT stream.
//
// Plusargs: +SEED=<n> (1) +MAXD=<n> (4) +N_EXT_NTT=<n> (32) +N_EXT_INTT=<n> (32)
//   +N_EXT_BM=<n> (32) +N_RAND=<n> (8) +N_DIR=<n> (24, max 24) +N_MPM=<n> (4)
//   +N_CHAIN=<n> (4) +EXT_DIR=<dir> +MVEC_DIR=<dir>
//   +ERR_TEST     only the register / error / collision / reset scenarios,
//                 including din_range: 2 words >= Q enter the core, so the
//                 ntt_core assertion L3_RANGE fires exactly 2 times.
//   +TRACE=<file> write every performed access (cycle, address, data) for the
//                 host register model replay (fpga/sw/test, t_replay).
`timescale 1ns / 1ps

module tb_pqc_ntt_axi_top;
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
  parameter int IMPL         = 0;
  parameter int FCLK_MHZ     = 100;

  localparam int  AW         = 12;
  localparam int  L          = PRE_REG + MUL_REG + RED_PIPE + OUT_REG;
  localparam int  NOPS       = (ALGO == int'(ALGO_BARRETT) || ALGO == int'(ALGO_SHIFTADD)) ? 5 : 7;
  localparam int  CYC_XF     = 897 + 7 * (1 + L);
  localparam int  CYC_BM     = 128 * NOPS * (L + 1) + 3;
  localparam int  NX_NTT     = 855;
  localparam int  NX_INTT    = 450;
  localparam int  NX_BM      = 2145;
  localparam int  NX_MPM     = 106;
  localparam int  N_DIR_MAX  = 24;
  localparam time T_CLK      = 10ns;
  localparam int  HS_TIMEOUT = 5000;    // cycles one BFM handshake may take
  localparam int  POLL_LIMIT = 20000;   // STATUS polls of one wait

  // Register map (docs/spec/l4_axi.md), independent of the RTL.
  localparam int A_CTRL    = 'h00;
  localparam int A_STATUS  = 'h04;
  localparam int A_DIN     = 'h08;
  localparam int A_DOUT    = 'h0C;
  localparam int A_CYCLES  = 'h10;
  localparam int A_VERSION = 'h14;
  localparam int A_ERR     = 'h18;
  localparam int A_CONFIG  = 'h1C;
  localparam logic [31:0] ST_BUSY   = 32'h01;
  localparam logic [31:0] ST_DONE   = 32'h02;
  localparam logic [31:0] ST_RBANK  = 32'h04;
  localparam logic [31:0] ST_INRDY  = 32'h08;
  localparam logic [31:0] ST_OUTVLD = 32'h10;
  localparam logic [31:0] E_START_BUSY = 32'h01;
  localparam logic [31:0] E_DIN        = 32'h02;
  localparam logic [31:0] E_DOUT       = 32'h04;
  localparam logic [31:0] E_BAD_OP     = 32'h08;
  localparam logic [31:0] E_DIN_RANGE  = 32'h10;
  localparam logic [31:0] E_ALL        = 32'h1F;
  localparam logic [31:0] VERSION_EXP  = {16'h4E54, 8'(L), 8'(ALGO)};
  localparam logic [31:0] CONFIG_EXP   = (32'(FCLK_MHZ) << 16) | (32'(OUT_REG) << 7) | (32'(RED_PIPE) << 5)
                                         | (32'(MUL_REG) << 4) | (32'(PRE_REG) << 3) | (32'(ROM_OUT_REG) << 2)
                                         | (32'(SHARE_ADDSUB) << 1) | 32'(IMPL);

  // --------------------------------------------------------------------------
  // DUT
  // --------------------------------------------------------------------------
  logic          clk = 1'b0;
  logic          rst_n = 1'b0;
  logic [AW-1:0] awaddr = '0;
  logic [2:0]    awprot = '0;
  logic          awvalid = 1'b0;
  logic          awready;
  logic [31:0]   wdata = '0;
  logic [3:0]    wstrb = '1;
  logic          wvalid = 1'b0;
  logic          wready;
  logic [1:0]    bresp;
  logic          bvalid;
  logic          bready = 1'b0;
  logic [AW-1:0] araddr = '0;
  logic [2:0]    arprot = '0;
  logic          arvalid = 1'b0;
  logic          arready;
  logic [31:0]   rdata;
  logic [1:0]    rresp;
  logic          rvalid;
  logic          rready = 1'b0;

  pqc_ntt_axi_top #(
    .ALGO(ALGO), .PRE_REG(PRE_REG), .MUL_REG(MUL_REG), .RED_PIPE(RED_PIPE), .OUT_REG(OUT_REG),
    .SHARE_ADDSUB(SHARE_ADDSUB), .ROM_OUT_REG(ROM_OUT_REG), .IMPL(IMPL), .FCLK_MHZ(FCLK_MHZ),
    .C_S_AXI_ADDR_WIDTH(AW)
  ) dut (
    .clk(clk), .rst_n(rst_n),
    .s_axi_awaddr_i(awaddr), .s_axi_awprot_i(awprot), .s_axi_awvalid_i(awvalid), .s_axi_awready_o(awready),
    .s_axi_wdata_i(wdata), .s_axi_wstrb_i(wstrb), .s_axi_wvalid_i(wvalid), .s_axi_wready_o(wready),
    .s_axi_bresp_o(bresp), .s_axi_bvalid_o(bvalid), .s_axi_bready_i(bready),
    .s_axi_araddr_i(araddr), .s_axi_arprot_i(arprot), .s_axi_arvalid_i(arvalid), .s_axi_arready_o(arready),
    .s_axi_rdata_o(rdata), .s_axi_rresp_o(rresp), .s_axi_rvalid_o(rvalid), .s_axi_rready_i(rready)
  );

  always #(T_CLK / 2) clk = ~clk;

  // --------------------------------------------------------------------------
  // Items and checkers
  // --------------------------------------------------------------------------
  typedef enum int {
    I_EXT_NTT, I_EXT_INTT, I_EXT_BM, I_BM_KEEP_B,
    I_RND_NTT, I_RND_INTT, I_RND_BM,
    I_DIR_NTT, I_DIR_INTT, I_DIR_BM,
    I_PM_RT_FHAT, I_PM_RT, I_PM_NORT,
    I_CORNER, I_RANGE,
    N_ITEM
  } item_e;

  localparam string ITEM_NAME [N_ITEM] = '{
    "ext_ntt", "ext_intt", "ext_bm", "bm_keep_b",
    "rnd_ntt", "rnd_intt", "rnd_bm",
    "dir_ntt", "dir_intt", "dir_bm",
    "pm_rt_fhat", "pm_rt_prod", "pm_nort_prod",
    "corner", "din_range"
  };

  tb_checker chk_item [N_ITEM];
  longint    coef_mm  [N_ITEM];
  bit        used     [N_ITEM];
  tb_checker chk_golden, chk_axi, chk_model, chk_regs, chk_cycles, chk_coll;

  typedef int poly_t [N_COEF];

  function automatic string op_name(int o);
    case (o)
      0: return "LOAD";
      1: return "NTT";
      2: return "INTT";
      3: return "BASEMUL";
      4: return "UNLOAD";
      default: return "?";
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

  longint cyc = 0;

  function automatic void ck(tb_checker c, bit ok, string msg);
    if (ok) c.pass();
    else c.fail($sformatf("cyc %0d: %s", cyc, msg));
  endfunction

  // --------------------------------------------------------------------------
  // Monitor: AXI protocol, performed accesses, register model (falling edge)
  // --------------------------------------------------------------------------
  // requests handshaken but not yet performed
  int unsigned aw_q [$];
  logic [31:0] w_q [$];
  int unsigned ar_q [$];
  // previous cycle (protocol stability)
  bit          p_valid = 0;
  logic        p_bvalid, p_bready, p_rvalid, p_rready;
  logic [1:0]  p_bresp, p_rresp;
  logic [31:0] p_rdata;

  // ntt_core port snapshot of one cycle
  typedef struct {
    logic        busy, done, rbank, s_ready, m_valid;
    logic [11:0] m_data;
    logic        start_acc;   // start_i = 1 while busy_o = 0
    int          op;
    logic        bank;
    logic        din_hs;      // s_valid_i && s_ready_o
    logic [11:0] s_data;
    logic        pop;         // m_valid_o && m_ready_i
  } probe_t;
  probe_t pp;

  // register model state (spec behaviour)
  bit          m_ds;
  logic [31:0] m_err;
  longint      m_cnt, m_cycles;

  // statistics
  longint n_aw_hs, n_w_hs, n_b_hs, n_ar_hs, n_r_hs, n_wr_perf, n_rd_perf;
  longint n_wr_bfm, n_rd_bfm;
  int     n_ctrl_at_done, n_start_at_done, n_errset_at_w1c;
  int     n_core_acc, n_core_done;
  longint core_acc_cyc;
  int     core_acc_op;
  longint meas_cycles;
  int     meas_op;
  int     n_drv_ops;
  int     n_pipe_pairs;
  int     n_r_overlap, n_b_overlap;   // request accepted while a response was stalled

  int tf = 0;   // trace file

  function automatic void model_reset();
    m_ds     = 0;
    m_err    = '0;
    m_cnt    = 0;
    m_cycles = 0;
  endfunction

  function automatic logic [31:0] model_read(int addr);
    case ((addr >> 2) & ((1 << (AW - 2)) - 1))
      A_STATUS  >> 2: return {27'd0, pp.m_valid, pp.s_ready, pp.rbank, m_ds, pp.busy};
      A_DOUT    >> 2: return pp.m_valid ? {20'd0, pp.m_data} : 32'd0;
      A_CYCLES  >> 2: return 32'(m_cycles);
      A_VERSION >> 2: return VERSION_EXP;
      A_ERR     >> 2: return m_err;
      A_CONFIG  >> 2: return CONFIG_EXP;
      default:        return 32'd0;
    endcase
  endfunction

  // One cycle k of the model: accesses performed in k, core ports of k (pp).
  function automatic void model_step(longint k, bit wr, int waddr, logic [31:0] wd,
                                     bit rd, int raddr, logic [31:0] rd_got);
    int          widx, ridx;
    bit          wr_ctrl, wr_din, wr_err, rd_dout, start, legal, acc, din_hs, pop, ok;
    logic [31:0] set, clr, exp;
    string       msg;
    widx    = (waddr >> 2) & ((1 << (AW - 2)) - 1);
    ridx    = (raddr >> 2) & ((1 << (AW - 2)) - 1);
    wr_ctrl = wr && widx == (A_CTRL >> 2);
    wr_din  = wr && widx == (A_DIN >> 2);
    wr_err  = wr && widx == (A_ERR >> 2);
    rd_dout = rd && ridx == (A_DOUT >> 2);
    start   = wd[0];
    legal   = wd[3:1] <= 3'd4;
    acc     = wr_ctrl && start && legal && !pp.busy;
    din_hs  = wr_din && pp.s_ready;
    pop     = rd_dout && pp.m_valid;

    // read data (state before the write of the same cycle)
    if (rd) begin
      exp = model_read(raddr);
      ck(chk_model, rd_got === exp,
         $sformatf("read 0x%03x performed in cycle %0d: got 0x%08x, model 0x%08x", raddr, k, rd_got, exp));
      if (tf != 0) $fdisplay(tf, "R %0d %03x %08x", k, raddr, rd_got);
    end
    if (wr && tf != 0) $fdisplay(tf, "W %0d %03x %08x", k, waddr, wd);

    // ntt_core command and stream handshakes of this cycle
    ok  = 1;
    msg = "";
    if (pp.start_acc !== acc) begin
      ok = 0;
      msg = {msg, $sformatf(" start accepted %b, model %b;", pp.start_acc, acc)};
    end else if (acc && (pp.op != int'(wd[3:1]) || pp.bank !== wd[4])) begin
      ok = 0;
      msg = {msg, $sformatf(" start op %0d bank %b, CTRL 0x%08x;", pp.op, pp.bank, wd)};
    end
    if (pp.din_hs !== din_hs) begin
      ok = 0;
      msg = {msg, $sformatf(" DIN handshake %b, model %b;", pp.din_hs, din_hs)};
    end else if (din_hs && pp.s_data !== wd[11:0]) begin
      ok = 0;
      msg = {msg, $sformatf(" DIN word %0d, written 0x%08x;", pp.s_data, wd)};
    end
    if (pp.pop !== pop) begin
      ok = 0;
      msg = {msg, $sformatf(" DOUT pop %b, model %b;", pp.pop, pop)};
    end
    if (ok) chk_model.pass();
    else chk_model.fail($sformatf("cyc %0d: cycle %0d core ports:%s", cyc, k, msg));

    // collisions
    if (wr_ctrl && pp.done) begin
      n_ctrl_at_done++;
      if (acc) n_start_at_done++;
    end
    set = '0;
    set |= (wr_ctrl && start && pp.busy) ? E_START_BUSY : '0;
    set |= (wr_din && !pp.s_ready)       ? E_DIN        : '0;
    set |= (rd_dout && !pp.m_valid)      ? E_DOUT       : '0;
    set |= (wr_ctrl && start && !legal)  ? E_BAD_OP     : '0;
    set |= (din_hs && wd[11:0] >= 12'(Q)) ? E_DIN_RANGE : '0;
    clr = wr_err ? (wd & E_ALL) : '0;
    if ((set & clr) != '0) n_errset_at_w1c++;

    // next state
    if (wr_ctrl && !(start && !legal)) m_ds = 0;      // CTRL write clears, wins over done
    else if (pp.done)                  m_ds = 1;
    m_err = (m_err & ~clr) | set;                      // set wins over W1C
    if (pp.done) m_cycles = m_cnt;
    if (acc)          m_cnt = 1;
    else if (pp.busy) m_cnt = m_cnt + 1;
  endfunction

  always @(negedge clk) begin
    if (rst_n !== 1'b1) begin
      model_reset();
      if (p_valid && tf != 0) $fdisplay(tf, "X %0d", cyc);
      p_valid = 0;
      aw_q.delete();
      w_q.delete();
      ar_q.delete();
    end else begin
      bit          b_start, r_start, wr, rd;
      int          waddr, raddr;
      logic [31:0] wd;
      cyc++;
      wr = 0; rd = 0; waddr = 0; raddr = 0; wd = '0;
      // responses starting now: accesses performed in cycle cyc - 1
      b_start = (bvalid === 1'b1) && (!p_valid || p_bvalid !== 1'b1 || p_bready === 1'b1);
      r_start = (rvalid === 1'b1) && (!p_valid || p_rvalid !== 1'b1 || p_rready === 1'b1);
      if (b_start) begin
        if (aw_q.size() == 0 || w_q.size() == 0)
          chk_axi.fail($sformatf("cyc %0d: B response without a pending write (AW %0d, W %0d)", cyc, aw_q.size(), w_q.size()));
        else begin
          waddr = int'(aw_q.pop_front());
          wd    = w_q.pop_front();
          wr    = 1;
          n_wr_perf++;
          chk_axi.pass();
        end
      end
      if (r_start) begin
        if (ar_q.size() == 0)
          chk_axi.fail($sformatf("cyc %0d: R response without a pending read", cyc));
        else begin
          raddr = int'(ar_q.pop_front());
          rd    = 1;
          n_rd_perf++;
          chk_axi.pass();
        end
      end
      if (p_valid) model_step(cyc - 1, wr, waddr, wd, rd, raddr, rdata);
      else if (wr || rd) chk_model.fail($sformatf("cyc %0d: access performed in the reset release cycle", cyc));

      // protocol: valid held until ready, payload stable
      if (p_valid && p_bvalid === 1'b1 && p_bready !== 1'b1)
        ck(chk_axi, bvalid === 1'b1 && bresp === p_bresp,
           $sformatf("BVALID %b / BRESP %b changed before BREADY (was 1 / %b)", bvalid, bresp, p_bresp));
      if (p_valid && p_rvalid === 1'b1 && p_rready !== 1'b1)
        ck(chk_axi, rvalid === 1'b1 && rdata === p_rdata && rresp === p_rresp,
           $sformatf("RVALID %b / RDATA 0x%08x changed before RREADY (was 1 / 0x%08x)", rvalid, rdata, p_rdata));
      if ($isunknown({awready, wready, bvalid, arready, rvalid}))
        chk_axi.fail($sformatf("cyc %0d: X on AXI handshake outputs", cyc));
      if (bvalid === 1'b1 && bresp !== 2'b00) chk_axi.fail($sformatf("cyc %0d: BRESP %b", cyc, bresp));
      if (rvalid === 1'b1 && (rresp !== 2'b00 || $isunknown(rdata)))
        chk_axi.fail($sformatf("cyc %0d: RRESP %b RDATA %h", cyc, rresp, rdata));

      // handshakes of this cycle (complete at the next rising edge)
      if (awvalid && awready === 1'b1) begin aw_q.push_back(int'(awaddr)); n_aw_hs++; end
      if (wvalid && wready === 1'b1)   begin w_q.push_back(wdata); n_w_hs++; end
      if (arvalid && arready === 1'b1) begin ar_q.push_back(int'(araddr)); n_ar_hs++; end
      if (arvalid && arready === 1'b1 && rvalid === 1'b1 && !rready) n_r_overlap++;
      if (awvalid && awready === 1'b1 && bvalid === 1'b1 && !bready) n_b_overlap++;
      if (bvalid === 1'b1 && bready) n_b_hs++;
      if (rvalid === 1'b1 && rready) n_r_hs++;

      // ntt_core ports of this cycle
      pp.busy      = dut.u_core.busy_o;
      pp.done      = dut.u_core.done_o;
      pp.rbank     = dut.u_core.result_bank_o;
      pp.s_ready   = dut.u_core.s_ready_o;
      pp.m_valid   = dut.u_core.m_valid_o;
      pp.m_data    = dut.u_core.m_data_o;
      pp.start_acc = dut.u_core.start_i && !dut.u_core.busy_o;
      pp.op        = int'(dut.u_core.op_i);
      pp.bank      = dut.u_core.bank_i;
      pp.din_hs    = dut.u_core.s_valid_i && dut.u_core.s_ready_o;
      pp.s_data    = dut.u_core.s_data_i;
      pp.pop       = dut.u_core.m_valid_o && dut.u_core.m_ready_i;
      if ($isunknown({pp.busy, pp.done, pp.rbank, pp.s_ready, pp.m_valid, pp.start_acc, pp.din_hs, pp.pop}))
        chk_model.fail($sformatf("cyc %0d: X on ntt_core command / stream ports", cyc));
      // CYCLES measured on the core ports (done before a start of the same cycle)
      if (pp.done === 1'b1) begin
        meas_cycles = cyc - core_acc_cyc;
        meas_op     = core_acc_op;
        n_core_done++;
      end
      if (pp.start_acc === 1'b1) begin
        core_acc_cyc = cyc;
        core_acc_op  = pp.op;
        n_core_acc++;
      end

      p_bvalid = bvalid; p_bready = bready; p_bresp = bresp;
      p_rvalid = rvalid; p_rready = rready; p_rresp = rresp; p_rdata = rdata;
      p_valid  = 1;
    end
  end

  // --------------------------------------------------------------------------
  // AXI4-Lite BFM (posedge non-blocking drive, negedge sampling)
  // --------------------------------------------------------------------------
  // Request phases are serialized per channel (wsem: AW + W, rsem: AR); the
  // response phases (B, R) are taken in request order by tickets. A thread
  // that has finished its request phase releases the channel, so another
  // thread can put the next request while the previous response is still
  // stalled (outstanding requests, as a real interconnect may do).
  semaphore wsem = new(1);
  semaphore rsem = new(1);
  int       w_tk = 0, w_srv = 0, r_tk = 0, r_srv = 0;
  int       maxd_cfg = 4;    // +MAXD
  int       bfm_maxd = 0;    // current request delay bound (0 = fast)

  function automatic int rnd_upto(int n);
    return (n <= 0) ? 0 : $urandom_range(n);
  endfunction

  task automatic aw_phase(int addr, int dly);
    int n = 0;
    @(posedge clk);
    repeat (dly) @(posedge clk);
    awaddr  <= AW'(addr);
    awprot  <= 3'($urandom_range(7));
    awvalid <= 1'b1;
    do begin
      @(negedge clk);
      if (++n > HS_TIMEOUT) $fatal(1, "L4_TB: AWREADY timeout (addr 0x%03x)", addr);
    end while (awready !== 1'b1);
    @(posedge clk);
    awvalid <= 1'b0;
    awaddr  <= AW'($urandom);
  endtask

  task automatic w_phase(logic [31:0] data, int dly);
    int n = 0;
    @(posedge clk);
    repeat (dly) @(posedge clk);
    wdata  <= data;
    wstrb  <= (bfm_maxd == 0) ? 4'hF : 4'($urandom_range(15));   // ignored by the spec
    wvalid <= 1'b1;
    do begin
      @(negedge clk);
      if (++n > HS_TIMEOUT) $fatal(1, "L4_TB: WREADY timeout");
    end while (wready !== 1'b1);
    @(posedge clk);
    wvalid <= 1'b0;
    wdata  <= $urandom;
  endtask

  // B of ticket tk: waits for its turn, BREADY after dly cycles.
  task automatic b_phase(int tk, int dly);
    int n = 0;
    wait (w_srv == tk);
    repeat (dly) @(posedge clk);
    bready <= 1'b1;
    do begin
      @(negedge clk);
      if (++n > HS_TIMEOUT) $fatal(1, "L4_TB: BVALID timeout");
    end while (bvalid !== 1'b1);
    @(posedge clk);
    bready <= 1'b0;
    n_wr_bfm++;
    w_srv++;
  endtask

  task automatic r_phase(int tk, int dly, int addr, output logic [31:0] data);
    int n = 0;
    wait (r_srv == tk);
    repeat (dly) @(posedge clk);
    rready <= 1'b1;
    do begin
      @(negedge clk);
      if (++n > HS_TIMEOUT) $fatal(1, "L4_TB: RVALID timeout (addr 0x%03x)", addr);
    end while (rvalid !== 1'b1);
    data = rdata;
    @(posedge clk);
    rready <= 1'b0;
    n_rd_bfm++;
    r_srv++;
  endtask

  // dly_aw / dly_w < 0: random by bfm_maxd (order same cycle / AW first / W first)
  task automatic axi_write(int addr, logic [31:0] data, int dly_aw = -1, int dly_w = -1);
    int db, tk;
    wsem.get(1);
    tk = w_tk++;
    if (dly_aw < 0 || dly_w < 0) begin
      int d = rnd_upto(bfm_maxd);
      if (bfm_maxd == 0) begin dly_aw = 0; dly_w = 0; end
      else case ($urandom_range(2))
        0: begin dly_aw = d; dly_w = d; end
        1: begin dly_aw = d; dly_w = d + 1 + rnd_upto(bfm_maxd); end
        default: begin dly_w = d; dly_aw = d + 1 + rnd_upto(bfm_maxd); end
      endcase
    end
    db = rnd_upto(bfm_maxd == 0 ? 0 : bfm_maxd + 3);
    fork
      aw_phase(addr, dly_aw);
      w_phase(data, dly_w);
    join
    wsem.put(1);
    b_phase(tk, db);
  endtask

  // tk_o: ticket (request order) of this read.
  task automatic axi_read_tk(int addr, output logic [31:0] data, output int tk_o, input int dly_ar = -1);
    int n = 0, dr, tk;
    rsem.get(1);
    tk = r_tk++;
    tk_o = tk;
    if (dly_ar < 0) dly_ar = rnd_upto(bfm_maxd);
    dr = rnd_upto(bfm_maxd == 0 ? 0 : bfm_maxd + 3);
    @(posedge clk);
    repeat (dly_ar) @(posedge clk);
    araddr  <= AW'(addr);
    arprot  <= 3'($urandom_range(7));
    arvalid <= 1'b1;
    do begin
      @(negedge clk);
      if (++n > HS_TIMEOUT) $fatal(1, "L4_TB: ARREADY timeout (addr 0x%03x)", addr);
    end while (arready !== 1'b1);
    @(posedge clk);
    arvalid <= 1'b0;
    araddr  <= AW'($urandom);
    rsem.put(1);
    r_phase(tk, dr, addr, data);
  endtask

  task automatic axi_read(int addr, output logic [31:0] data, input int dly_ar = -1);
    int tk;
    axi_read_tk(addr, data, tk, dly_ar);
  endtask

  // Write / read whose AW + W (AR) are valid in cycle te - 1, so that the
  // access is performed in cycle te (axil_slave: buffer filled at the edge,
  // performed in the next cycle). The caller makes sure the channel is idle.
  task automatic axi_write_at(int addr, logic [31:0] data, longint te);
    int tk;
    wsem.get(1);
    tk = w_tk++;
    if (cyc > te - 2) $fatal(1, "L4_TB: write target cycle %0d too close (now %0d)", te, cyc);
    wait (cyc == te - 2);
    fork
      aw_phase(addr, 0);
      w_phase(data, 0);
    join
    wsem.put(1);
    b_phase(tk, 0);
  endtask

  task automatic axi_read_at(int addr, output logic [31:0] data, input longint te);
    if (cyc > te - 2) $fatal(1, "L4_TB: read target cycle %0d too close (now %0d)", te, cyc);
    wait (cyc == te - 2);
    axi_read(addr, data, 0);
  endtask

  // --------------------------------------------------------------------------
  // Noise thread: harmless accesses in parallel with the main flow
  // --------------------------------------------------------------------------
  bit noise_on = 0, noise_busy = 0;

  task automatic noise_thread();
    logic [31:0] d;
    noise_busy = 1;
    fork
      while (noise_on) begin
        int a;
        case ($urandom_range(9))
          0: a = A_STATUS;   1: a = A_CYCLES;  2: a = A_VERSION; 3: a = A_CONFIG;
          4: a = A_ERR;      5: a = A_CTRL;    6: a = A_DIN;     7: a = 'h20;
          8: a = 'h400 + 4 * $urandom_range(200);
          default: a = 'hFFC;
        endcase
        axi_read(a, d);
        repeat ($urandom_range(6)) @(posedge clk);
      end
      while (noise_on) begin
        int          a;
        logic [31:0] v = $urandom;
        case ($urandom_range(7))
          0: begin a = A_ERR; v = 0; end          // W1C of nothing
          1: a = A_STATUS;   2: a = A_CYCLES;  3: a = A_VERSION;
          4: a = A_CONFIG;   5: a = A_DOUT;    6: a = 'h24;
          default: a = 'h800 + 4 * $urandom_range(100);
        endcase
        axi_write(a, v);
        repeat ($urandom_range(10)) @(posedge clk);
      end
    join
    noise_busy = 0;
  endtask

  task automatic noise_start();
    noise_on = 1;
    fork noise_thread(); join_none
    wait (noise_busy);
  endtask

  task automatic noise_stop();
    noise_on = 0;
    wait (!noise_busy);
  endtask

  // --------------------------------------------------------------------------
  // Driver layer (fpga/sw/pqc_ntt.c order)
  // --------------------------------------------------------------------------
  bit          poll_mode = 0;      // poll in_ready / out_valid before DIN / DOUT
  bit          din_junk  = 0;      // random DIN bits [31:12]
  logic [31:0] exp_err   = '0;     // ERR expected at the end of the next op
  longint      cyc_min [5], cyc_max [5];
  int          n_op [5];

  function automatic logic [31:0] ctrl_word(int op, int bank, bit start = 1);
    return {27'd0, 1'(bank), 3'(op), start};
  endfunction

  task automatic drv_start(int op, int bank);
    axi_write(A_CTRL, ctrl_word(op, bank));
    n_drv_ops++;
  endtask

  task automatic wait_status(logic [31:0] mask, output logic [31:0] s);
    int n = 0;
    do begin
      axi_read(A_STATUS, s);
      if (++n > POLL_LIMIT) $fatal(1, "L4_TB: STATUS & 0x%02x never set (last 0x%08x)", mask, s);
    end while ((s & mask) == '0);
  endtask

  function automatic int exp_rbank(int op, int bank);
    if (op == int'(OP_NTT) || op == int'(OP_INTT)) return 1 - bank;
    if (op == int'(OP_BASEMUL)) return 0;
    return bank;
  endfunction

  // End of every op: done_sticky, STATUS, CYCLES, ERR.
  task automatic drv_finish(int op, int bank);
    logic [31:0] s, c, e, s_exp;
    wait_status(ST_DONE, s);
    s_exp = ST_DONE | (exp_rbank(op, bank) ? ST_RBANK : '0);
    ck(chk_regs, s === s_exp, $sformatf("%s bank %0d: STATUS at done_sticky 0x%08x, expected 0x%08x",
                                        op_name(op), bank, s, s_exp));
    axi_read(A_CYCLES, c);
    ck(chk_cycles, meas_op == op && c == 32'(meas_cycles),
       $sformatf("%s: CYCLES %0d, measured on the core %0d (op %s)", op_name(op), c, meas_cycles, op_name(meas_op)));
    if (op == int'(OP_NTT) || op == int'(OP_INTT))
      ck(chk_cycles, c == CYC_XF, $sformatf("%s: CYCLES %0d, formula %0d", op_name(op), c, CYC_XF));
    else if (op == int'(OP_BASEMUL))
      ck(chk_cycles, c == CYC_BM, $sformatf("BASEMUL: CYCLES %0d, formula %0d", c, CYC_BM));
    if (n_op[op] == 0 || c < cyc_min[op]) cyc_min[op] = c;
    if (n_op[op] == 0 || c > cyc_max[op]) cyc_max[op] = c;
    n_op[op]++;
    axi_read(A_ERR, e);
    ck(chk_regs, e === exp_err, $sformatf("%s: ERR 0x%08x after the op, expected 0x%08x", op_name(op), e, exp_err));
  endtask

  task automatic drv_run(int op, int bank);
    drv_start(op, bank);
    drv_finish(op, bank);
  endtask

  // Slow tests: about one word in four is sent as a pipelined pair (the
  // second request is put while the first response is still outstanding).
  function automatic bit pipe_pair(int i);
    return bfm_maxd > 0 && i + 1 < N_COEF && $urandom_range(3) == 0;
  endfunction

  task automatic drv_load(int bank, poly_t d);
    logic [31:0] s;
    drv_start(int'(OP_LOAD), bank);
    for (int i = 0; i < N_COEF; i++) begin
      logic [31:0] w0 = {din_junk ? 20'($urandom) : 20'd0, 12'(d[i])};
      if (poll_mode) wait_status(ST_INRDY, s);
      if (pipe_pair(i)) begin
        logic [31:0] w1 = {din_junk ? 20'($urandom) : 20'd0, 12'(d[i + 1])};
        bit d0 = 0, d1 = 0;
        int t0 = w_tk;
        fork begin axi_write(A_DIN, w0); d0 = 1; end join_none
        wait (w_tk > t0);                        // first request owns the earlier ticket
        fork begin axi_write(A_DIN, w1); d1 = 1; end join_none
        wait (d0 && d1);
        n_pipe_pairs++;
        i++;
      end else begin
        axi_write(A_DIN, w0);
      end
    end
    drv_finish(int'(OP_LOAD), bank);
  endtask

  task automatic drv_unload(int bank, output poly_t got);
    logic [31:0] s, v;
    drv_start(int'(OP_UNLOAD), bank);
    for (int i = 0; i < N_COEF; i++) begin
      if (poll_mode) wait_status(ST_OUTVLD, s);
      if (pipe_pair(i)) begin
        logic [31:0] v1;
        bit d0 = 0, d1 = 0;
        int t0 = r_tk;
        fork begin axi_read(A_DOUT, v); d0 = 1; end join_none
        wait (r_tk > t0);
        fork begin axi_read(A_DOUT, v1); d1 = 1; end join_none
        wait (d0 && d1);
        ck(chk_regs, v[31:12] == '0 && v1[31:12] == '0, $sformatf("DOUT words %0d, %0d = 0x%08x 0x%08x, bits [31:12] not 0", i, i + 1, v, v1));
        got[i]     = int'(v[11:0]);
        got[i + 1] = int'(v1[11:0]);
        n_pipe_pairs++;
        i++;
      end else begin
        axi_read(A_DOUT, v);
        ck(chk_regs, v[31:12] == '0, $sformatf("DOUT word %0d = 0x%08x, bits [31:12] not 0", i, v));
        got[i] = int'(v[11:0]);
      end
    end
    drv_finish(int'(OP_UNLOAD), bank);
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

  function automatic void check_poly(item_e it, poly_t got, poly_t e, string what);
    int nbad = 0, i0 = -1;
    used[it] = 1;
    for (int i = 0; i < N_COEF; i++)
      if (got[i] != e[i]) begin
        nbad++;
        if (i0 < 0) i0 = i;
      end
    coef_mm[it] += nbad;
    if (nbad == 0) chk_item[it].pass();
    else chk_item[it].fail($sformatf("%s: %0d of %0d coefficients differ, first [%0d] got %0d expected %0d",
                                     what, nbad, N_COEF, i0, got[i0], e[i0]));
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

  function automatic void get_poly(file_e fid, int idx, string fname, output poly_t p);
    for (int i = 0; i < N_COEF; i++) begin
      logic [COEF_W-1:0] v = fget(fid, idx * N_COEF + i);
      if ($isunknown(v) || v >= COEF_W'(Q))
        $fatal(1, "%s: polynomial %0d coefficient %0d = %h (missing line or out of range)", fname, idx, i, v);
      p[i] = int'(v);
    end
  endfunction

  function automatic int pick(int i, int n, int total);
    return (n >= total) ? i : int'((longint'(i) * total) / n);
  endfunction

  // Directed polynomials (same set as tb_ntt_core).
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
        12: f[i] = (i == 200) ? Q - 1 : 1;
        13: f[i] = (i % 2 == 0) ? 0 : Q - 1;
        14: f[i] = (i % 2 == 0) ? Q - 1 : 0;
        15: f[i] = (i % 2 == 0) ? 1 : 0;
        16: f[i] = i;
        17: f[i] = (Q - 1) - i;
        18: f[i] = (i * 13) % Q;
        19: f[i] = (i % 2 == 0) ? (Q - 1) / 2 : (Q + 1) / 2;
        20: f[i] = (i < 128) ? Q - 1 : 0;
        21: f[i] = (i % 4 < 2) ? Q - 1 : 1;
        22: f[i] = (Q - 1) - (i * 97) % Q;
        default: f[i] = (i == 2 || i == 3) ? Q - 1 : 0;
      endcase
    end
  endfunction

  function automatic void rnd_poly(output poly_t f);
    foreach (f[i]) f[i] = $urandom_range(Q - 1);
  endfunction

  // --------------------------------------------------------------------------
  // Tests
  // --------------------------------------------------------------------------
  int test_no = 0;

  function automatic bit rbit();
    return bit'($urandom_range(1));
  endfunction

  // Even tests fast (no delays, no polls), odd tests slow with random AXI
  // timing; every fourth slow test with the noise thread.
  task automatic begin_test(int force_mode = -1);
    bit slow = (force_mode >= 0) ? bit'(force_mode) : bit'(test_no & 1);
    bfm_maxd  = slow ? maxd_cfg : 0;
    poll_mode = slow;
    din_junk  = slow ? rbit() : 0;
    if (slow && force_mode < 0 && (test_no % 4) == 3) noise_start();
  endtask

  task automatic end_test();
    if (noise_on) noise_stop();
    test_no++;
  endtask

  // LOAD b f; op b; UNLOAD ~b == e
  task automatic t_xf(op_e op, poly_t f, poly_t e, item_e it, string what);
    poly_t got;
    int    b = test_no & 1;
    begin_test();
    drv_load(b, f);
    drv_run(int'(op), b);
    drv_unload(1 - b, got);
    check_poly(it, got, e, what);
    end_test();
  endtask

  // LOAD 0 a / LOAD 1 bb (random order); BASEMUL (random bank bit, ignored);
  // UNLOAD 0 == e; optionally UNLOAD 1 == bb
  task automatic t_bm(poly_t a, poly_t bb, poly_t e, item_e it, bit keep_b, string what);
    poly_t got;
    begin_test();
    if (rbit()) begin
      drv_load(0, a);
      drv_load(1, bb);
    end else begin
      drv_load(1, bb);
      drv_load(0, a);
    end
    drv_run(int'(OP_BASEMUL), rbit());
    drv_unload(0, got);
    check_poly(it, got, e, what);
    if (keep_b) begin
      drv_unload(1, got);
      check_poly(I_BM_KEEP_B, got, bb, {what, " bank1 after BASEMUL"});
    end
    end_test();
  endtask

  // Product, both operands in the coefficient domain (host round trip).
  task automatic t_pm_rt(poly_t f, poly_t g, poly_t h, string what);
    poly_t fh, gh, hh, hw, got;
    exp_ntt(f, fh, what);
    exp_ntt(g, gh, what);
    exp_bm(fh, gh, hh, what);
    exp_intt(hh, hw, what);
    gx(poly_eq(hw, h), $sformatf("%s: hw chain intt(basemul(ntt f, ntt g)) != expected product", what));
    begin_test();
    drv_load(0, f);
    drv_run(int'(OP_NTT), 0);
    drv_unload(1, got);
    check_poly(I_PM_RT_FHAT, got, fh, {what, " f^"});
    drv_load(0, g);
    drv_run(int'(OP_NTT), 0);
    drv_load(0, got);                           // the words just unloaded
    drv_run(int'(OP_BASEMUL), 0);
    drv_run(int'(OP_INTT), 0);
    drv_unload(1, got);
    check_poly(I_PM_RT, got, h, {what, " f * g"});
    end_test();
  endtask

  // Product, a given in the NTT domain (a^): no round trip.
  task automatic t_pm_nort(poly_t a, poly_t r, poly_t h, string what);
    poly_t ah, rh, hh, hw, got;
    mlkem_dpi_ntt(a, ah);
    exp_ntt(r, rh, what);
    exp_bm(ah, rh, hh, what);
    exp_intt(hh, hw, what);
    gx(poly_eq(hw, h), $sformatf("%s: hw chain intt(basemul(a^, ntt r)) != expected product", what));
    begin_test();
    drv_load(0, r);
    drv_run(int'(OP_NTT), 0);                   // r^ in bank1
    drv_load(0, ah);
    drv_run(int'(OP_BASEMUL), 0);               // a^ r^ in bank0
    drv_run(int'(OP_INTT), 0);                  // a r in bank1
    drv_unload(1, got);
    check_poly(I_PM_NORT, got, h, {what, " a * r"});
    end_test();
  endtask

  // Reset values, VERSION, CONFIG (also after a reset in the middle).
  task automatic t_regs(string when);
    logic [31:0] v;
    axi_read(A_STATUS, v);
    ck(chk_regs, v === 32'd0, $sformatf("%s: STATUS 0x%08x, expected 0", when, v));
    axi_read(A_CYCLES, v);
    ck(chk_regs, v === 32'd0, $sformatf("%s: CYCLES 0x%08x, expected 0", when, v));
    axi_read(A_ERR, v);
    ck(chk_regs, v === 32'd0, $sformatf("%s: ERR 0x%08x, expected 0", when, v));
    axi_read(A_VERSION, v);
    ck(chk_regs, v === VERSION_EXP, $sformatf("%s: VERSION 0x%08x, expected 0x%08x", when, v, VERSION_EXP));
    axi_read(A_CONFIG, v);
    ck(chk_regs, v === CONFIG_EXP, $sformatf("%s: CONFIG 0x%08x, expected 0x%08x", when, v, CONFIG_EXP));
    axi_read(A_CTRL, v);
    ck(chk_regs, v === 32'd0, $sformatf("%s: CTRL (write only) read 0x%08x", when, v));
    axi_read(A_DIN, v);
    ck(chk_regs, v === 32'd0, $sformatf("%s: DIN (write only) read 0x%08x", when, v));
  endtask

  // Undefined addresses and wrong-direction accesses (idle and during ops).
  task automatic t_addr();
    logic [31:0] v, ver, cfg, cyc_v, st;
    poly_t f, e, got;
    int undef [6] = '{'h20, 'h24, 'h3C, 'h100, 'h804, 'hFFC};
    begin_test(1);
    axi_read(A_CYCLES, cyc_v);
    foreach (undef[i]) begin
      axi_read(undef[i], v);
      ck(chk_regs, v === 32'd0, $sformatf("undefined 0x%03x read 0x%08x", undef[i], v));
      axi_write(undef[i], 32'h0000_0003);       // would be "start NTT" at CTRL
      axi_write(undef[i], 32'hFFFF_FFFF);
    end
    // read only registers ignore writes (DOUT: no pop, checked by the model)
    axi_write(A_STATUS, 32'hFFFF_FFFF);
    axi_write(A_CYCLES, 32'hFFFF_FFFF);
    axi_write(A_VERSION, 32'h0);
    axi_write(A_CONFIG, 32'h0);
    axi_write(A_DOUT, 32'hFFFF_FFFF);
    axi_read(A_STATUS, st);
    ck(chk_regs, (st & ST_BUSY) == 0, $sformatf("undefined / read only writes started an op: STATUS 0x%08x", st));
    axi_read(A_VERSION, ver);
    axi_read(A_CONFIG, cfg);
    axi_read(A_CYCLES, v);
    ck(chk_regs, ver === VERSION_EXP && cfg === CONFIG_EXP && v === cyc_v,
       $sformatf("read only registers changed by writes: VERSION 0x%08x CONFIG 0x%08x CYCLES %0d (was %0d)", ver, cfg, v, cyc_v));
    axi_read(A_ERR, v);
    ck(chk_regs, v === 32'd0, $sformatf("ERR 0x%08x after undefined / read only accesses", v));
    // the same during an UNLOAD: reads of undefined / write only addresses
    // must not pop, writes to DOUT / undefined addresses must not pop either
    rnd_poly(f);
    drv_load(1, f);
    drv_start(int'(OP_UNLOAD), 1);
    for (int i = 0; i < N_COEF; i++) begin
      if (i % 32 == 5) begin
        axi_read('h20, v);
        axi_read(A_CTRL, v);
        axi_read(A_DIN, v);
        axi_write(A_DOUT, 32'h0);
        axi_write('hFFC, 32'h0);
      end
      wait_status(ST_OUTVLD, st);
      axi_read(A_DOUT, v);
      got[i] = int'(v[11:0]);
    end
    drv_finish(int'(OP_UNLOAD), 1);
    check_poly(I_CORNER, got, f, "UNLOAD with undefined / write only reads interleaved");
    end_test();
  endtask

  // ERR bits, W1C, error during ops; with_range adds din_range (L3_RANGE x 2).
  task automatic t_err(bit with_range);
    logic [31:0] v, st;
    poly_t f, e, got;
    begin_test(0);

    // ---- din_notready: idle DIN writes are dropped (also >= Q: no din_range)
    axi_write(A_DIN, 32'd5);
    axi_write(A_DIN, 32'h0000_0FFF);
    axi_read(A_ERR, v);
    ck(chk_regs, v === E_DIN, $sformatf("din_notready (idle): ERR 0x%08x", v));
    axi_write(A_ERR, E_ALL & ~E_DIN);           // W1C of other bits: no change
    axi_read(A_ERR, v);
    ck(chk_regs, v === E_DIN, $sformatf("W1C of other bits changed ERR: 0x%08x", v));
    axi_write(A_ERR, E_DIN);
    axi_read(A_ERR, v);
    ck(chk_regs, v === 32'd0, $sformatf("W1C din_notready: ERR 0x%08x", v));
    // the dropped words did not enter: a LOAD / UNLOAD returns exactly f
    rnd_poly(f);
    drv_load(0, f);
    drv_unload(0, got);
    check_poly(I_CORNER, got, f, "LOAD after dropped DIN writes");

    // ---- dout_notvalid: idle DOUT read returns 0, no pop
    axi_read(A_DOUT, v);
    ck(chk_regs, v === 32'd0, $sformatf("DOUT read while idle returned 0x%08x", v));
    axi_read(A_ERR, v);
    ck(chk_regs, v === E_DOUT, $sformatf("dout_notvalid (idle): ERR 0x%08x", v));
    axi_write(A_ERR, E_DOUT);

    // ---- start_busy during LOAD (LOAD continues) and DOUT read during LOAD
    rnd_poly(f);
    drv_start(int'(OP_LOAD), 1);
    for (int i = 0; i < N_COEF; i++) begin
      if (i == 10) begin
        axi_write(A_CTRL, ctrl_word(int'(OP_NTT), 0));
        axi_read(A_ERR, v);
        ck(chk_regs, v === E_START_BUSY, $sformatf("start_busy (LOAD): ERR 0x%08x", v));
        axi_read(A_STATUS, st);
        ck(chk_regs, st === (ST_BUSY | ST_INRDY), $sformatf("STATUS during LOAD after a busy start: 0x%08x", st));
        axi_read(A_DOUT, v);
        ck(chk_regs, v === 32'd0, $sformatf("DOUT read during LOAD returned 0x%08x", v));
      end
      axi_write(A_DIN, {20'd0, 12'(f[i])});
    end
    exp_err = E_START_BUSY | E_DOUT;
    drv_finish(int'(OP_LOAD), 1);
    axi_write(A_ERR, E_START_BUSY | E_DOUT);
    exp_err = '0;

    // ---- start_busy, DIN and DOUT during NTT: the NTT result is unchanged
    exp_ntt(f, e, "err: ntt");
    drv_start(int'(OP_NTT), 1);
    axi_write(A_CTRL, ctrl_word(int'(OP_INTT), 0));
    axi_write(A_DIN, 32'd7);
    axi_read(A_DOUT, v);
    ck(chk_regs, v === 32'd0, $sformatf("DOUT read during NTT returned 0x%08x", v));
    axi_write(A_CTRL, ctrl_word(5, 1));          // illegal op while busy: bits 0 and 3
    exp_err = E_START_BUSY | E_DIN | E_DOUT | E_BAD_OP;
    drv_finish(int'(OP_NTT), 1);                 // also checks CYCLES = formula
    axi_write(A_ERR, E_ALL);
    exp_err = '0;
    axi_read(A_ERR, v);
    ck(chk_regs, v === 32'd0, $sformatf("W1C all: ERR 0x%08x", v));
    drv_unload(0, got);
    check_poly(I_CORNER, got, e, "NTT with start / DIN / DOUT / illegal op while busy");

    // ---- bad_op while idle: no op, busy and done_sticky unchanged
    axi_read(A_STATUS, st);
    ck(chk_regs, st === ST_DONE, $sformatf("STATUS 0x%08x before the illegal op test, expected done_sticky only", st));
    for (int op = 5; op <= 7; op++) begin
      axi_write(A_CTRL, ctrl_word(op, op & 1));
      axi_read(A_STATUS, st);
      ck(chk_regs, st === ST_DONE, $sformatf("illegal op %0d changed STATUS: 0x%08x", op, st));
      axi_read(A_ERR, v);
      ck(chk_regs, v === E_BAD_OP, $sformatf("illegal op %0d: ERR 0x%08x", op, v));
      axi_write(A_ERR, E_BAD_OP);
    end
    // CTRL write without start (op field illegal): no error, clears done_sticky
    axi_write(A_CTRL, ctrl_word(7, 0, 0));
    axi_read(A_STATUS, st);
    axi_read(A_ERR, v);
    ck(chk_regs, st === 32'd0 && v === 32'd0,
       $sformatf("CTRL write without start: STATUS 0x%08x (done_sticky must clear) ERR 0x%08x", st, v));

    // ---- din_range: words >= Q enter unchanged (low 12 bits), bits [31:12] ignored
    if (with_range) begin
      rnd_poly(f);
      f[3]   = Q;          // written as 0x00000D01
      f[100] = 4095;       // 0x...FFF
      drv_start(int'(OP_LOAD), 1);
      for (int i = 0; i < N_COEF; i++) begin
        logic [31:0] w = {20'd0, 12'(f[i])};
        if (i == 100) w = 32'hFFFF_FFFF;
        if (i == 200) w = {20'hABCDE, 12'(f[i])};  // in range after masking
        axi_write(A_DIN, w);
      end
      exp_err = E_DIN_RANGE;
      drv_finish(int'(OP_LOAD), 1);
      axi_write(A_ERR, E_DIN_RANGE);
      exp_err = '0;
      drv_unload(1, got);
      check_poly(I_RANGE, got, f, "words >= Q come back as their low 12 bits");
      $display("ERR_TEST: 2 DIN words >= Q accepted (L3_RANGE must fire 2 times)");
    end

    // ---- normal operation afterwards
    end_test();
    rnd_poly(f);
    exp_intt(f, e, "err: intt after");
    t_xf(OP_INTT, f, e, I_CORNER, "INTT after the error scenarios");
  endtask

  // Collisions with the done_o cycle and with an ERR set.
  task automatic t_coll();
    logic [31:0] v, st;
    poly_t f, e, got;
    int n0, s0, w0;
    begin_test(0);
    // (a) CTRL write without start in the NTT done cycle: done_sticky stays 0
    rnd_poly(f);
    exp_ntt(f, e, "coll a");
    drv_load(0, f);
    n0 = n_ctrl_at_done;
    s0 = n_start_at_done;
    drv_start(int'(OP_NTT), 0);
    axi_write_at(A_CTRL, ctrl_word(int'(OP_LOAD), 0, 0), core_acc_cyc + CYC_XF);
    ck(chk_coll, n_ctrl_at_done == n0 + 1 && n_start_at_done == s0,
       $sformatf("CTRL write not performed in the done cycle (hits %0d -> %0d)", n0, n_ctrl_at_done));
    axi_read(A_STATUS, st);
    ck(chk_coll, st === ST_RBANK, $sformatf("CTRL write in the done cycle: STATUS 0x%08x, expected 0x%08x (clear wins)", st, ST_RBANK));
    axi_read(A_CYCLES, v);
    ck(chk_cycles, v == CYC_XF && meas_cycles == CYC_XF, $sformatf("NTT CYCLES %0d with CTRL write in the done cycle", v));
    axi_read(A_ERR, v);
    ck(chk_regs, v === 32'd0, $sformatf("ERR 0x%08x", v));
    drv_unload(1, got);
    check_poly(I_CORNER, got, e, "NTT, CTRL write in its done cycle");

    // (b) start INTT written in the NTT done cycle: accepted (busy = 0 there)
    rnd_poly(f);
    drv_load(0, f);
    n0 = n_ctrl_at_done;
    s0 = n_start_at_done;
    drv_start(int'(OP_NTT), 0);
    axi_write_at(A_CTRL, ctrl_word(int'(OP_INTT), 1), core_acc_cyc + CYC_XF);
    n_drv_ops++;
    ck(chk_coll, n_ctrl_at_done == n0 + 1 && n_start_at_done == s0 + 1,
       $sformatf("start not accepted in the done cycle (hits %0d -> %0d, accepted %0d -> %0d)",
                 n0, n_ctrl_at_done, s0, n_start_at_done));
    // while the INTT runs, CYCLES holds the NTT (previous op) value
    axi_read(A_CYCLES, v);
    axi_read(A_STATUS, st);
    ck(chk_coll, v == CYC_XF && (st & ST_BUSY) != 0,
       $sformatf("during the INTT started in the NTT done cycle: CYCLES %0d (NTT %0d expected), STATUS 0x%08x", v, CYC_XF, st));
    drv_finish(int'(OP_INTT), 1);                // ERR 0: no start_busy
    drv_unload(0, got);
    check_poly(I_CORNER, got, f, "NTT then INTT started in the NTT done cycle (round trip)");

    // (c) ERR W1C performed in the cycle a DOUT read sets the same bit: set wins
    w0 = n_errset_at_w1c;
    axi_write(A_DIN, 32'd1);                     // ERR = din_notready
    begin
      longint te = cyc + 20;
      fork
        axi_write_at(A_ERR, E_DOUT | E_DIN, te);
        axi_read_at(A_DOUT, v, te);
      join
    end
    ck(chk_coll, n_errset_at_w1c == w0 + 1, "ERR W1C not performed in the cycle of the DOUT error");
    axi_read(A_ERR, v);
    ck(chk_coll, v === E_DOUT, $sformatf("W1C and set of dout_notvalid in one cycle: ERR 0x%08x, expected 0x%08x", v, E_DOUT));
    axi_write(A_ERR, E_ALL);
    end_test();
  endtask

  // Reset in the middle: every register back to its reset value.
  task automatic t_reset();
    logic [31:0] v;
    poly_t f, e, got;
    begin_test(0);
    rnd_poly(f);
    drv_load(0, f);
    drv_run(int'(OP_NTT), 0);                    // result bank 1, done_sticky, CYCLES
    axi_write(A_DIN, 32'd1);                     // ERR
    axi_read(A_STATUS, v);
    ck(chk_regs, v === (ST_DONE | ST_RBANK), $sformatf("STATUS 0x%08x before reset", v));
    @(negedge clk);
    rst_n <= 1'b0;
    repeat (3) @(negedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);
    t_regs("after reset");
    end_test();
    rnd_poly(f);
    exp_ntt(f, e, "after reset");
    t_xf(OP_NTT, f, e, I_CORNER, "NTT after reset");
  endtask

  // --------------------------------------------------------------------------
  // Main
  // --------------------------------------------------------------------------
  initial begin
    int unsigned seed;
    int          n_ext_ntt, n_ext_intt, n_ext_bm, n_rand, n_dir, n_mpm, n_chain;
    bit          err_test, ok;
    string       ext_dir, mvec_dir, trace_file, an;
    poly_t       f, g, e, e2, h;
    tb_checker   rep [$];

    seed       = tb_seed_from_plusarg();
    n_ext_ntt  = 32;
    n_ext_intt = 32;
    n_ext_bm   = 32;
    n_rand     = 8;
    n_dir      = N_DIR_MAX;
    n_mpm      = 4;
    n_chain    = 4;
    ext_dir    = "../../data/vectors/ext";
    mvec_dir   = "../../model/vectors";
    void'($value$plusargs("MAXD=%d", maxd_cfg));
    void'($value$plusargs("N_EXT_NTT=%d", n_ext_ntt));
    void'($value$plusargs("N_EXT_INTT=%d", n_ext_intt));
    void'($value$plusargs("N_EXT_BM=%d", n_ext_bm));
    void'($value$plusargs("N_RAND=%d", n_rand));
    void'($value$plusargs("N_DIR=%d", n_dir));
    void'($value$plusargs("N_MPM=%d", n_mpm));
    void'($value$plusargs("N_CHAIN=%d", n_chain));
    void'($value$plusargs("EXT_DIR=%s", ext_dir));
    void'($value$plusargs("MVEC_DIR=%s", mvec_dir));
    err_test = $test$plusargs("ERR_TEST");
    if (n_ext_ntt > NX_NTT)   n_ext_ntt  = NX_NTT;
    if (n_ext_intt > NX_INTT) n_ext_intt = NX_INTT;
    if (n_ext_bm > NX_BM)     n_ext_bm   = NX_BM;
    if (n_mpm > NX_MPM)       n_mpm      = NX_MPM;
    if (n_dir > N_DIR_MAX)    n_dir      = N_DIR_MAX;
    if ($value$plusargs("TRACE=%s", trace_file)) begin
      tf = $fopen(trace_file, "w");
      if (tf == 0) $fatal(1, "cannot open trace file %s", trace_file);
      $fdisplay(tf, "H %0d %0d %08x %08x", ALGO, L, VERSION_EXP, CONFIG_EXP);
    end
    an = algo_name(ALGO);
    $display("TB_CONFIG: tb_pqc_ntt_axi_top ALGO=%0d(%s) PRE_REG=%0d MUL_REG=%0d RED_PIPE=%0d OUT_REG=%0d SHARE_ADDSUB=%0d ROM_OUT_REG=%0d IMPL=%0d FCLK_MHZ=%0d L=%0d NOPS=%0d SEED=%0d MAXD=%0d N_EXT_NTT=%0d N_EXT_INTT=%0d N_EXT_BM=%0d N_RAND=%0d N_DIR=%0d N_MPM=%0d N_CHAIN=%0d ERR_TEST=%0d TRACE=%0d",
             ALGO, an, PRE_REG, MUL_REG, RED_PIPE, OUT_REG, SHARE_ADDSUB, ROM_OUT_REG, IMPL, FCLK_MHZ, L, NOPS,
             seed, maxd_cfg, n_ext_ntt, n_ext_intt, n_ext_bm, n_rand, n_dir, n_mpm, n_chain, err_test, tf != 0);

    foreach (chk_item[i]) begin
      chk_item[i] = new(ITEM_NAME[i]);
      coef_mm[i]  = 0;
      used[i]     = 0;
    end
    chk_golden = new("golden");
    chk_axi    = new("axi");
    chk_model  = new("model");
    chk_regs   = new("regs");
    chk_cycles = new("cycles");
    chk_coll   = new("coll");
    foreach (n_op[i]) begin n_op[i] = 0; cyc_min[i] = 0; cyc_max[i] = 0; end
    model_reset();

    gx(mlkem_dpi_basemul_nops(ALGO) == NOPS, "basemul op count of the golden model != TB NOPS");
    gx(dut.u_core.u_bfu.LATENCY == L, $sformatf("bfu LATENCY %0d != TB L %0d", dut.u_core.u_bfu.LATENCY, L));

    if (!err_test) begin
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

    repeat (3) @(posedge clk);
    // AXI outputs during reset
    ck(chk_regs, awready !== 1'bx && bvalid === 1'b0 && rvalid === 1'b0,
       $sformatf("AXI outputs in reset: BVALID %b RVALID %b", bvalid, rvalid));
    @(negedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);

    // ---- register map, addresses, errors, collisions, reset ----
    begin_test(0);
    t_regs("reset");
    end_test();
    t_addr();
    t_err(err_test);
    t_coll();
    t_reset();
    $display("PROGRESS: register scenarios done, ops %0d, cycle %0d", n_drv_ops, cyc);

    if (!err_test) begin
      // ---- directed ----
      for (int c = 0; c < n_dir; c++) begin
        dir_poly(c, f);
        exp_ntt(f, e, $sformatf("dir %0d", c));
        t_xf(OP_NTT, f, e, I_DIR_NTT, $sformatf("dir ntt %0d", c));
        exp_intt(f, e, $sformatf("dir %0d", c));
        t_xf(OP_INTT, f, e, I_DIR_INTT, $sformatf("dir intt %0d", c));
        dir_poly(n_dir - 1 - c, g);
        exp_bm(f, g, e, $sformatf("dir %0d x %0d", c, n_dir - 1 - c));
        t_bm(f, g, e, I_DIR_BM, c % 4 == 0, $sformatf("dir bm %0d", c));
      end
      $display("PROGRESS: directed done, ops %0d, cycle %0d", n_drv_ops, cyc);

      // ---- external vectors ----
      for (int i = 0; i < n_ext_ntt; i++) begin
        automatic int k = pick(i, n_ext_ntt, NX_NTT);
        get_poly(F_NTT_IN, k, "ntt_in.hex", f);
        get_poly(F_NTT_OUT, k, "ntt_out.hex", e);
        exp_ntt(f, e2, $sformatf("ext ntt %0d", k));
        gx(poly_eq(e, e2), $sformatf("ext ntt %0d: file output != hw_ntt", k));
        t_xf(OP_NTT, f, e, I_EXT_NTT, $sformatf("ext ntt %0d", k));
      end
      for (int i = 0; i < n_ext_intt; i++) begin
        automatic int k = pick(i, n_ext_intt, NX_INTT);
        get_poly(F_INTT_IN, k, "intt_in.hex", f);
        get_poly(F_INTT_OUT, k, "intt_out.hex", e);
        exp_intt(f, e2, $sformatf("ext intt %0d", k));
        gx(poly_eq(e, e2), $sformatf("ext intt %0d: file output != hw_intt", k));
        t_xf(OP_INTT, f, e, I_EXT_INTT, $sformatf("ext intt %0d", k));
      end
      for (int i = 0; i < n_ext_bm; i++) begin
        automatic int k = pick(i, n_ext_bm, NX_BM);
        get_poly(F_BM_A, k, "basemul_a.hex", f);
        get_poly(F_BM_B, k, "basemul_b.hex", g);
        get_poly(F_BM_OUT, k, "basemul_out.hex", e);
        exp_bm(f, g, e2, $sformatf("ext bm %0d", k));
        gx(poly_eq(e, e2), $sformatf("ext bm %0d: file output != hw_basemul", k));
        t_bm(f, g, e, I_EXT_BM, i % 8 == 7, $sformatf("ext bm %0d", k));
      end
      $display("PROGRESS: external done, ops %0d, cycle %0d", n_drv_ops, cyc);

      // ---- random ----
      for (int i = 0; i < n_rand; i++) begin
        rnd_poly(f);
        exp_ntt(f, e, $sformatf("rnd ntt %0d", i));
        t_xf(OP_NTT, f, e, I_RND_NTT, $sformatf("rnd ntt %0d", i));
        rnd_poly(f);
        exp_intt(f, e, $sformatf("rnd intt %0d", i));
        t_xf(OP_INTT, f, e, I_RND_INTT, $sformatf("rnd intt %0d", i));
        rnd_poly(f);
        rnd_poly(g);
        exp_bm(f, g, e, $sformatf("rnd bm %0d", i));
        t_bm(f, g, e, I_RND_BM, 0, $sformatf("rnd bm %0d", i));
      end
      $display("PROGRESS: random done, ops %0d, cycle %0d", n_drv_ops, cyc);

      // ---- polynomial products, both orders ----
      for (int i = 0; i < n_mpm; i++) begin
        poly_t hs;
        get_poly(F_PM_F, i, "polymul_f.hex", f);
        get_poly(F_PM_G, i, "polymul_g.hex", g);
        get_poly(F_PM_H, i, "polymul_h.hex", h);
        schoolbook(f, g, hs);
        gx(poly_eq(h, hs), $sformatf("model polymul %0d: file h != SV schoolbook", i));
        t_pm_rt(f, g, h, $sformatf("model polymul %0d", i));
        t_pm_nort(f, g, h, $sformatf("model polymul %0d", i));
      end
      for (int i = 0; i < n_chain; i++) begin
        rnd_poly(f);
        rnd_poly(g);
        schoolbook(f, g, h);
        t_pm_rt(f, g, h, $sformatf("random product %0d", i));
        t_pm_nort(f, g, h, $sformatf("random product %0d", i));
      end
    end

    repeat (5) @(posedge clk);
    @(negedge clk);
    @(negedge clk);

    // every request answered, nothing left over
    ck(chk_axi, aw_q.size() == 0 && w_q.size() == 0 && ar_q.size() == 0,
       $sformatf("requests not performed at the end: AW %0d W %0d AR %0d", aw_q.size(), w_q.size(), ar_q.size()));
    ck(chk_axi, n_aw_hs == n_wr_bfm && n_w_hs == n_wr_bfm && n_b_hs == n_wr_bfm && n_wr_perf == n_wr_bfm,
       $sformatf("writes: BFM %0d, AW %0d, W %0d, performed %0d, B %0d", n_wr_bfm, n_aw_hs, n_w_hs, n_wr_perf, n_b_hs));
    ck(chk_axi, n_ar_hs == n_rd_bfm && n_r_hs == n_rd_bfm && n_rd_perf == n_rd_bfm,
       $sformatf("reads: BFM %0d, AR %0d, performed %0d, R %0d", n_rd_bfm, n_ar_hs, n_rd_perf, n_r_hs));
    if (!err_test)
      ck(chk_axi, n_r_overlap > 0 && n_b_overlap > 0,
         $sformatf("no request accepted during a stalled response (AR %0d, AW %0d): overlap not exercised", n_r_overlap, n_b_overlap));
    ck(chk_regs, n_core_acc == n_drv_ops && n_core_done == n_drv_ops,
       $sformatf("ops started by the TB %0d, accepted by the core %0d, done %0d", n_drv_ops, n_core_acc, n_core_done));

    $display("OPS: ops=%0d tests=%0d cycles=%0d writes=%0d reads=%0d collisions ctrl@done=%0d start@done=%0d w1c@set=%0d",
             n_drv_ops, test_no, cyc, n_wr_bfm, n_rd_bfm, n_ctrl_at_done, n_start_at_done, n_errset_at_w1c);
    $display("OVERLAP: pipelined DIN/DOUT pairs=%0d, AR accepted during an R stall=%0d, AW accepted during a B stall=%0d",
             n_pipe_pairs, n_r_overlap, n_b_overlap);
    for (int o = 0; o < 5; o++)
      $display("CYCLES: algo=%s L=%0d op=%s n=%0d min=%0d max=%0d formula=%0d",
               an, L, op_name(o), n_op[o], cyc_min[o], cyc_max[o],
               (o == 1 || o == 2) ? CYC_XF : (o == 3) ? CYC_BM : -1);
    for (int i = 0; i < N_ITEM; i++)
      if (used[i])
        $display("ITEM: %s polys=%0d poly_mismatch=%0d coef_mismatch=%0d",
                 ITEM_NAME[i], chk_item[i].n_checks, chk_item[i].n_mismatch, coef_mm[i]);
    for (int i = 0; i < N_ITEM; i++) if (used[i]) rep.push_back(chk_item[i]);
    rep.push_back(chk_golden);
    rep.push_back(chk_axi);
    rep.push_back(chk_model);
    rep.push_back(chk_regs);
    rep.push_back(chk_cycles);
    rep.push_back(chk_coll);
    if (tf != 0) $fclose(tf);
    ok = tb_final_report(rep);
    $finish;
  end

endmodule
