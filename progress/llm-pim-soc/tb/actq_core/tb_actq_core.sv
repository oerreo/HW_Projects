// tb_actq_core: actq_core against the golden k_actq_st (DPI-C, tb/common/vec_tb_pkg.sv).
// Calls:
//   +VEC1 / +VEC2  every K_ACTQ record of the two models (model/build/vec/m1, m2 actq.bin; qmax 127
//                  and 2047); each record is first replayed through k_exec and compared with its
//                  recorded outputs.
//   +NSYN          synthetic calls: n random 1..N_MAX (and the edges 1, N_MAX), qmax 127 / 2047 /
//                  32767, f random, input modes (all zero, one nonzero, -2^31, 2^31 - 1, amax 1, all
//                  |v| equal, full magnitude, random magnitudes)
// Checks per call: every q (in order, count n), m_o and e_o at done == golden s.m, s.e, stage trace
// amax (SET0), L = bitlen(amax) and e (SET1), num = k_rshr(amax, -e) (SET1), M (after the first
// division), R (after the second) == golden k_aq_t; done_o one cycle after the last q handshake;
// busy_o. +CYC=1 (no gaps, no stalls): start-to-done cycles == 2n + 59 (amax != 0) or 2n + 6.
// Stimulus: input gaps (+GAP percent), q_ready stalls (+QSTALL percent), +QBLK=1 long q_ready = 0
// blocks (30..400 cycles) that must fill the output FIFO and stop the reads by the credit
// (coverage). The next call starts in the done cycle of the previous one with probability 1/2
// (+B2B). Watchdog TB_TIMEOUT.
`timescale 1ns / 1ps
module tb_actq_core;
  import tb_util_pkg::*;
  import kdpi_pkg::*;
  import vec_tb_pkg::*;
  import llm_pkg::*;

  parameter int N_MAX   = 1024;
  parameter int Q_DEPTH = 8;
  localparam int NW = $clog2(N_MAX + 1);

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic                   start_i = 1'b0, v_valid_i = 1'b0, v_ready_o, q_valid_o, q_ready_i = 1'b1;
  logic                   scl_valid_o, busy_o, done_o;
  logic [NW-1:0]          n_i = '0;
  logic signed [E_W-1:0]  f_i = '0;
  logic [15:0]            qmax_i = '0, q_o;
  logic [31:0]            v_i = '0;
  logic [AM_W-1:0]        m_o;
  logic signed [SH_W-1:0] e_o;

  actq_core #(.N_MAX(N_MAX), .Q_DEPTH(Q_DEPTH)) dut (
    .clk, .rst_n, .start_i, .n_i, .f_i, .qmax_i, .v_valid_i, .v_ready_o, .v_i, .q_valid_o, .q_ready_i,
    .q_o, .m_o, .e_o, .scl_valid_o, .busy_o, .done_o);

  tb_checker c_q = new("q"), c_s = new("scale"), c_st = new("stage"), c_hs = new("handshake"),
             c_cyc = new("cycles"), c_rec = new("record"), c_cov = new("coverage");

  // ---------------- monitor ----------------
  vcase cq[$];                 // calls started, not yet done
  int   oq = 0;                // q index of the front call
  longint cyc = 0, t_start[$], t_last = -10, n_calls = 0, n_full = 0, n_credit = 0, n_b2b = 0;
  bit   chk_cyc = 0;
  bit   st_set1 = 0, st_divr = 0, st_quant = 0;
  always @(negedge clk) begin
    cyc++;
    if (rst_n) begin
      // accepted start
      if (start_i === 1'b1 && (int'(dut.st_q) == 0 || done_o === 1'b1)) t_start.push_back(cyc);
      if (q_valid_o === 1'b1 && q_ready_i === 1'b1) begin
        if (cq.size() == 0) c_hs.fail("q without a call");
        else begin
          automatic vcase c = cq[0];
          if (oq >= c.n) c_hs.fail($sformatf("%s: more than n q", c.desc()));
          else if ($signed(q_o) !== c.q[oq])
            c_q.fail($sformatf("%s: q[%0d] %0d golden %0d (v %0d)", c.desc(), oq, $signed(q_o), c.q[oq], c.in0[oq]));
          else c_q.pass();
          oq++;
          if (oq == c.n) t_last = cyc;
        end
      end
      if (done_o === 1'b1) begin
        if (cq.size() == 0 || oq != cq[0].n || t_last != cyc - 1) c_hs.fail("done_o not in the cycle after the last q");
        else begin
          automatic vcase c = cq.pop_front();
          automatic longint ts = t_start.pop_front();
          c_hs.pass();
          if (int'(m_o) !== c.sm || int'(e_o) !== c.se)
            c_s.fail($sformatf("%s: m %0d e %0d golden %0d %0d", c.desc(), m_o, e_o, c.sm, c.se));
          else c_s.pass();
          if (chk_cyc) begin
            automatic longint ex = c.amax != 0 ? 2 * c.n + 59 : 2 * c.n + 6;
            if (cyc - ts !== ex) c_cyc.fail($sformatf("%s: %0d cycles, formula %0d", c.desc(), cyc - ts, ex));
            else c_cyc.pass();
          end
          n_calls++;
        end
        oq = 0;
        st_set1 = 0; st_divr = 0; st_quant = 0;
      end
      // stage trace of the front call
      if (cq.size() > 0) begin
        automatic vcase c = cq[0];
        if (int'(dut.st_q) == 3 && !st_set1) begin   // SET1: amax, L, e, num
          automatic int L = bitlen(c.amax);
          st_set1 = 1;
          if (longint'(dut.amax_q) !== c.amax || int'(dut.L) !== L || int'(dut.e_q) !== int'(c.e) ||
              longint'(dut.num) !== kd_rshr(c.amax, -int'(c.e)))
            c_st.fail($sformatf("%s: amax %0d/%0d L %0d/%0d e %0d/%0d num %0d/%0d", c.desc(), dut.amax_q,
                                c.amax, dut.L, L, dut.e_q, c.e, dut.num, kd_rshr(c.amax, -int'(c.e))));
          else c_st.pass();
        end
        if (int'(dut.st_q) == 5 && !st_divr) begin   // DIVR: M
          st_divr = 1;
          if (longint'(dut.m_q) !== c.M) c_st.fail($sformatf("%s: M %0d golden %0d", c.desc(), dut.m_q, c.M));
          else c_st.pass();
        end
        if (int'(dut.st_q) == 6 && !st_quant) begin  // QUANT: R (or amax == 0: amax, M, R 0)
          st_quant = 1;
          if (c.amax == 0) begin
            if (dut.amax_q !== 0 || dut.m_q !== 0 || dut.r_q !== 0) c_st.fail($sformatf("%s: amax 0 path", c.desc()));
            else c_st.pass();
          end else if (longint'(dut.r_q) !== c.R) c_st.fail($sformatf("%s: R %0d golden %0d", c.desc(), dut.r_q, c.R));
          else c_st.pass();
        end
      end
      if (busy_o !== (int'(dut.st_q) != 0)) c_hs.fail("busy_o");
      else c_hs.pass();
      if (cq.size() > 0 && oq == cq[0].n && t_last == cyc - 1 && done_o !== 1'b1) c_hs.fail("no done_o after the last q");
      // coverage of the output limits
      if (int'(dut.f_level) == Q_DEPTH) n_full++;
      if (int'(dut.st_q) == 6 && dut.rcnt_q != dut.n_q && !dut.credit) n_credit++;
    end
  end

  // q_ready: random stalls and long blocks
  int qstall = 0, qblk = 0, gap = 0, b2b = 1;
  bit blk_on = 0;
  always @(posedge clk) q_ready_i <= !blk_on && ($urandom_range(99) >= qstall);
  initial begin
    wait (rst_n === 1'b1);
    forever begin
      @(posedge clk);
      if (qblk && int'(dut.st_q) == 6 && $urandom_range(15) == 0) begin
        blk_on = 1;
        repeat ($urandom_range(400, 30)) @(posedge clk);
        blk_on = 0;
        repeat ($urandom_range(300, 50)) @(posedge clk);
      end
    end
  end

  // ---------------- driver ----------------
  task automatic do_call(vcase c);
    bit back = b2b && cq.size() > 0 && $urandom_range(1);
    if (back) begin
      // the negedge of the last q handshake of the running call (after the monitor), then its
      // done cycle; if that moment has passed already, an ordinary start
      forever begin
        @(negedge clk);
        #1;
        if (cq.size() == 0 || (oq == cq[0].n && t_last < cyc)) begin back = 0; break; end
        if (oq == cq[0].n && t_last == cyc) break;
      end
      @(posedge clk);
      if (back) n_b2b++;
    end
    if (!back) while (busy_o !== 1'b0 || cq.size() > 0) @(posedge clk);
    start_i <= 1'b1;
    n_i     <= NW'(c.n);
    f_i     <= E_W'(c.f());
    qmax_i  <= 16'(c.qmax());
    cq.push_back(c);
    @(posedge clk);
    start_i <= 1'b0;
    n_i <= '0; qmax_i <= '0; f_i <= '0;
    for (int i = 0; i < c.n; ) begin
      if ($urandom_range(99) < gap) begin
        v_valid_i <= 1'b0;
        v_i <= $urandom();
        @(posedge clk);
        continue;
      end
      v_valid_i <= 1'b1;
      v_i       <= c.in0[i];
      @(negedge clk);
      if (v_ready_o === 1'b1) i++;
      @(posedge clk);
    end
    v_valid_i <= 1'b0;
  endtask

  initial begin
    automatic int unsigned seed;
    automatic string vec1 = "", vec2 = "";
    automatic int nsyn = 0, nrec = 0, maxrec = 1 << 30;
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("VEC1=%s", vec1));
    void'($value$plusargs("VEC2=%s", vec2));
    void'($value$plusargs("NSYN=%d", nsyn));
    void'($value$plusargs("MAXREC=%d", maxrec));
    void'($value$plusargs("GAP=%d", gap));
    void'($value$plusargs("QSTALL=%d", qstall));
    void'($value$plusargs("QBLK=%d", qblk));
    void'($value$plusargs("B2B=%d", b2b));
    void'($value$plusargs("CYC=%d", chk_cyc));
    $display("tb_actq_core: N_MAX %0d Q_DEPTH %0d seed %0d NSYN %0d GAP %0d QSTALL %0d QBLK %0d CYC %0d",
             N_MAX, Q_DEPTH, seed, nsyn, gap, qstall, qblk, chk_cyc);
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    @(posedge clk);
    for (int k = 0; k < 2; k++) begin
      automatic string v = k == 0 ? vec1 : vec2;
      automatic int nr = 0;
      if (v == "") continue;
      if (kd_rec_open({v, "/actq.bin"}) != 0) $fatal(1, "tb_actq_core: no record file in %s", v);
      while (kd_rec_next() > 0 && nr < maxrec) begin
        automatic vcase c = new();
        automatic int rc = c.load_rec();
        if (rc != 0 || c.n > N_MAX) begin c_rec.fail($sformatf("%s record %0d: load %0d", v, kd_rec_index(), rc)); continue; end
        c_rec.pass();
        c.tag = $sformatf("m%0d rec %0d", k + 1, c.rec);
        do_call(c);
        nr++;
      end
      void'(kd_rec_close());
      nrec += nr;
    end
    for (int i = 0; i < nsyn; i++) begin
      automatic vcase c = new();
      automatic int n = i == 0 ? 1 : i == 1 ? N_MAX : i % 10 == 9 ? $urandom_range(N_MAX, 2) : $urandom_range(3) == 0 ? $urandom_range(16, 1) : $urandom_range(N_MAX, 1);
      c.gen_syn(K_ACTQ, n, i < 20 ? i % 10 : $urandom_range(9));
      do_call(c);
    end
    while (cq.size() > 0) @(posedge clk);
    repeat (10) @(posedge clk);
    $display("tb_actq_core: %0d records, %0d synthetic, %0d calls done, %0d back-to-back; FIFO full %0d, credit stop %0d cycles",
             nrec, nsyn, n_calls, n_b2b, n_full, n_credit);
    if (n_calls != nrec + nsyn) c_hs.fail($sformatf("%0d calls done of %0d", n_calls, nrec + nsyn));
    begin
      automatic tb_checker_q l = '{c_q, c_s, c_st, c_hs};
      if (nrec > 0) l.push_back(c_rec);
      if (chk_cyc) l.push_back(c_cyc);
      if (qblk) begin
        if (n_full > 0 && n_credit > 0) c_cov.pass();
        else c_cov.fail($sformatf("limits not reached: FIFO full %0d credit stop %0d", n_full, n_credit));
        l.push_back(c_cov);
      end
      void'(tb_final_report(l));
    end
    $finish;
  end

  initial begin
    static longint unsigned lim = 64'd100_000_000;
    void'($value$plusargs("TIMEOUT=%d", lim));
    repeat (lim) @(posedge clk);
    $fatal(1, "TB_TIMEOUT tb_actq_core");
  end

endmodule
