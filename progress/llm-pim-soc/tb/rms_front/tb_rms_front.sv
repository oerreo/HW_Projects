// tb_rms_front: rms_front + its buffer (ram_sdp) + actq_core (f = fy, qmax 127) against the golden
// k_rmsnorm_st (DPI-C, tb/common/vec_tb_pkg.sv). The two modules start in the same cycle (as in
// vec_core); actq_core takes the y stream in LOAD.
// Calls: +VEC1 / +VEC2 every K_RMSNORM record of the two models (replayed through k_exec first),
// +NSYN synthetic calls (n 1..N_MAX, x all zero, one nonzero, -2^31, 2^31 - 1, small amax (k = 0),
// large (k up to 17), g = -32768 / 32767, ge / epsc / fy random).
// Checks per call: stage trace of rms_front (amax at K, k, ss when P2 ends, u, rm and re after
// rsqrt_nr, sh), every y (in order) == golden y; every q and the scale {m, e} == golden (this runs
// the shared actq_core on the rmsnorm y: the arch.md 5.1 claim "same aq_setup / aq_one, only the
// exponent offset differs" is checked by execution); actq stage M, R, e; done of both.
// +CYC=1 (no gaps, no stalls): start-to-done of actq_core == 4n + C (printed, formula checked).
// Stimulus: element gaps (+GAP), q_ready stalls (+QSTALL), +QBLK long q_ready blocks.
`timescale 1ns / 1ps
module tb_rms_front;
  import tb_util_pkg::*;
  import kdpi_pkg::*;
  import vec_tb_pkg::*;
  import llm_pkg::*;

  parameter int N_MAX = 1024;
  localparam int NW = $clog2(N_MAX + 1);
  localparam int AW = $clog2(N_MAX);

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic                   start_i = 1'b0, e_valid_i = 1'b0, e_ready_o, q_ready_i = 1'b1;
  logic [NW-1:0]          n_i = '0;
  logic signed [E_W-1:0]  ge_i = '0, fy_i = '0;
  logic [31:0]            epsc_i = '0, e_i = '0;
  logic                   b_we, b_re, y_valid, r_busy, r_done;
  logic [AW-1:0]          b_waddr, b_raddr;
  logic [31:0]            b_wdata, b_rdata, y;
  logic                   q_valid, scl_valid, a_busy, a_done;
  logic [15:0]            q;
  logic [AM_W-1:0]        m;
  logic signed [SH_W-1:0] e;

  rms_front #(.N_MAX(N_MAX)) dut (
    .clk, .rst_n, .start_i, .n_i, .ge_i, .epsc_i, .fy_i, .e_valid_i, .e_ready_o, .e_i,
    .b_we_o(b_we), .b_waddr_o(b_waddr), .b_wdata_o(b_wdata), .b_re_o(b_re), .b_raddr_o(b_raddr),
    .b_rdata_i(b_rdata), .y_valid_o(y_valid), .y_o(y), .busy_o(r_busy), .done_o(r_done));
  ram_sdp #(.W(32), .DEPTH(N_MAX), .RD_LAT(1)) u_buf (
    .clk, .rst_n, .we_i(b_we), .waddr_i(b_waddr), .wdata_i(b_wdata), .re_i(b_re), .raddr_i(b_raddr),
    .rdata_o(b_rdata));
  actq_core #(.N_MAX(N_MAX)) u_aq (
    .clk, .rst_n, .start_i, .n_i, .f_i(fy_i), .qmax_i(16'd127), .v_valid_i(y_valid), .v_ready_o(),
    .v_i(y), .q_valid_o(q_valid), .q_ready_i, .q_o(q), .m_o(m), .e_o(e), .scl_valid_o(scl_valid),
    .busy_o(a_busy), .done_o(a_done));

  tb_checker c_y = new("y"), c_q = new("q"), c_s = new("scale"), c_st = new("stage"),
             c_hs = new("handshake"), c_cyc = new("cycles"), c_rec = new("record"),
             c_cov = new("coverage");

  // ---------------- monitor ----------------
  vcase   cur;
  int     oy = 0, oq = 0;
  longint cyc = 0, t_s = 0, t_rdone = -1, n_calls = 0, n_full = 0, cmin = 1 << 30, cmax = 0;
  bit     chk_cyc = 0, f_k = 0, f_u = 0, f_rsq = 0, f_sh = 0, f_m = 0, f_r = 0;
  always @(negedge clk) begin
    cyc++;
    if (rst_n && cur != null) begin
      automatic vcase c = cur;
      if (y_valid === 1'b1) begin
        if (oy >= c.n) c_y.fail("y beyond n");
        else if ($signed(y) !== c.y[oy]) c_y.fail($sformatf("%s: y[%0d] %0d golden %0d", c.desc(), oy, $signed(y), c.y[oy]));
        else c_y.pass();
        oy++;
      end
      if (q_valid === 1'b1 && q_ready_i === 1'b1) begin
        if (oq >= c.n) c_q.fail("q beyond n");
        else if ($signed(q) !== c.q[oq]) c_q.fail($sformatf("%s: q[%0d] %0d golden %0d", c.desc(), oq, $signed(q), c.q[oq]));
        else c_q.pass();
        oq++;
      end
      // rms_front stage trace (state numbers of rms_front.st_t)
      if (int'(dut.st_q) == 3 && !f_k) begin        // P2: amax, k
        f_k = 1;
        if (longint'(dut.amax_q) !== c.amax || int'(dut.k_q) !== c.k)
          c_st.fail($sformatf("%s: amax %0d/%0d k %0d/%0d", c.desc(), dut.amax_q, c.amax, dut.k_q, c.k));
        else c_st.pass();
      end
      if (int'(dut.st_q) == 5 && !f_u) begin        // U: ss
        f_u = 1;
        if (longint'(dut.ss_q) !== c.ss) c_st.fail($sformatf("%s: ss %0d golden %0d", c.desc(), dut.ss_q, c.ss));
        else c_st.pass();
      end
      if (int'(dut.st_q) == 6 && !f_rsq) begin      // RSQ: u
        f_rsq = 1;
        if (longint'(dut.u_q) !== c.u) c_st.fail($sformatf("%s: u %0d golden %0d", c.desc(), dut.u_q, c.u));
        else c_st.pass();
      end
      if (int'(dut.st_q) == 8 && !f_sh) begin       // SH: rm, re
        f_sh = 1;
        if (longint'(dut.rm) !== c.rm || longint'(dut.re) !== c.re)
          c_st.fail($sformatf("%s: rm %0d/%0d re %0d/%0d", c.desc(), dut.rm, c.rm, dut.re, c.re));
        else c_st.pass();
      end
      if (int'(dut.st_q) == 9 && f_sh == 1) begin   // P4: sh
        f_sh = 0;
        if (longint'(dut.sh_q) !== c.sh) c_st.fail($sformatf("%s: sh %0d golden %0d", c.desc(), dut.sh_q, c.sh));
        else c_st.pass();
      end
      if (int'(u_aq.st_q) == 5 && !f_m) begin       // actq DIVR: M
        f_m = 1;
        if (longint'(u_aq.m_q) !== c.M) c_st.fail($sformatf("%s: M %0d golden %0d", c.desc(), u_aq.m_q, c.M));
        else c_st.pass();
      end
      if (int'(u_aq.st_q) == 6 && !f_r) begin       // actq QUANT: R, e
        f_r = 1;
        if (c.ymax != 0 && (longint'(u_aq.r_q) !== c.R || longint'(u_aq.e_q) !== c.e))
          c_st.fail($sformatf("%s: R %0d/%0d e %0d/%0d", c.desc(), u_aq.r_q, c.R, u_aq.e_q, c.e));
        else c_st.pass();
      end
      if (r_done === 1'b1) begin
        t_rdone = cyc;
        if (oy != c.n) c_hs.fail($sformatf("%s: rms_front done after %0d y", c.desc(), oy));
        else c_hs.pass();
      end
      if (a_done === 1'b1) begin
        if (oq != c.n || t_rdone < 0) c_hs.fail($sformatf("%s: actq done after %0d q (front done %0d)", c.desc(), oq, t_rdone));
        else c_hs.pass();
        if (int'(m) !== c.sm || int'(e) !== c.se)
          c_s.fail($sformatf("%s: m %0d e %0d golden %0d %0d", c.desc(), m, e, c.sm, c.se));
        else c_s.pass();
        if (cyc - t_s < cmin) cmin = cyc - t_s;
        if (cyc - t_s > cmax) cmax = cyc - t_s;
        if (chk_cyc) begin
          // 4n + C: P1 n, P2 n, P4 n, actq QUANT n (formula docs/spec/vec.md, rms_front + actq)
          automatic longint ex = 4 * c.n + (c.ymax != 0 ? 87 : 34);
          if (cyc - t_s !== ex) c_cyc.fail($sformatf("%s: %0d cycles, formula %0d", c.desc(), cyc - t_s, ex));
          else c_cyc.pass();
        end
        n_calls++;
        cur = null;
      end
      if (int'(u_aq.f_level) == 8) n_full++;
    end
  end

  int qstall = 0, qblk = 0, gap = 0;
  bit blk_on = 0;
  always @(posedge clk) q_ready_i <= !blk_on && ($urandom_range(99) >= qstall);
  initial begin
    wait (rst_n === 1'b1);
    forever begin
      @(posedge clk);
      if (qblk && int'(u_aq.st_q) == 6 && $urandom_range(15) == 0) begin
        blk_on = 1;
        repeat ($urandom_range(300, 20)) @(posedge clk);
        blk_on = 0;
        repeat ($urandom_range(200, 30)) @(posedge clk);
      end
    end
  end

  // ---------------- driver ----------------
  task automatic do_call(vcase c);
    while (cur != null || r_busy !== 1'b0 || a_busy !== 1'b0) @(posedge clk);
    start_i <= 1'b1;
    n_i     <= NW'(c.n);
    ge_i    <= E_W'(c.p0);
    epsc_i  <= c.p1;
    fy_i    <= E_W'(c.p2);
    cur = c; oy = 0; oq = 0; t_rdone = -1;
    f_k = 0; f_u = 0; f_rsq = 0; f_sh = 0; f_m = 0; f_r = 0;
    @(negedge clk);
    t_s = cyc;
    @(posedge clk);
    start_i <= 1'b0;
    for (int i = 0; i < 2 * c.n; ) begin
      if ($urandom_range(99) < gap) begin
        e_valid_i <= 1'b0;
        e_i <= $urandom();
        @(posedge clk);
        continue;
      end
      e_valid_i <= 1'b1;
      e_i       <= i < c.n ? c.in0[i] : c.in1[i - c.n];
      @(negedge clk);
      if (e_ready_o === 1'b1) i++;
      @(posedge clk);
    end
    e_valid_i <= 1'b0;
  endtask

  initial begin
    automatic int unsigned seed;
    automatic string vec1 = "", vec2 = "";
    automatic int nsyn = 0, nrec = 0;
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("VEC1=%s", vec1));
    void'($value$plusargs("VEC2=%s", vec2));
    void'($value$plusargs("NSYN=%d", nsyn));
    void'($value$plusargs("GAP=%d", gap));
    void'($value$plusargs("QSTALL=%d", qstall));
    void'($value$plusargs("QBLK=%d", qblk));
    void'($value$plusargs("CYC=%d", chk_cyc));
    $display("tb_rms_front: N_MAX %0d seed %0d NSYN %0d GAP %0d QSTALL %0d QBLK %0d CYC %0d", N_MAX, seed,
             nsyn, gap, qstall, qblk, chk_cyc);
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    @(posedge clk);
    for (int k = 0; k < 2; k++) begin
      automatic string v = k == 0 ? vec1 : vec2;
      if (v == "") continue;
      if (kd_rec_open({v, "/rmsnorm.bin"}) != 0) $fatal(1, "tb_rms_front: no record file in %s", v);
      while (kd_rec_next() > 0) begin
        automatic vcase c = new();
        automatic int rc = c.load_rec();
        if (rc != 0 || c.n > N_MAX) begin c_rec.fail($sformatf("%s record %0d: load %0d", v, kd_rec_index(), rc)); continue; end
        c_rec.pass();
        c.tag = $sformatf("m%0d rec %0d", k + 1, c.rec);
        do_call(c);
        nrec++;
      end
      void'(kd_rec_close());
    end
    for (int i = 0; i < nsyn; i++) begin
      automatic vcase c = new();
      automatic int n = i == 0 ? 1 : i == 1 ? N_MAX : $urandom_range(3) == 0 ? $urandom_range(16, 1) : $urandom_range(N_MAX, 1);
      c.gen_syn(K_RMSNORM, n, i < 18 ? i % 9 : $urandom_range(8));
      do_call(c);
    end
    while (cur != null) @(posedge clk);
    repeat (10) @(posedge clk);
    $display("tb_rms_front: %0d records, %0d synthetic, %0d calls; start-to-done %0d..%0d cycles; q FIFO full %0d cycles",
             nrec, nsyn, n_calls, cmin, cmax, n_full);
    if (n_calls != nrec + nsyn) c_hs.fail($sformatf("%0d calls done of %0d", n_calls, nrec + nsyn));
    begin
      automatic tb_checker_q l = '{c_y, c_q, c_s, c_st, c_hs};
      if (nrec > 0) l.push_back(c_rec);
      if (chk_cyc) l.push_back(c_cyc);
      if (qblk) begin
        if (n_full > 0) c_cov.pass(); else c_cov.fail("q FIFO never full");
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
    $fatal(1, "TB_TIMEOUT tb_rms_front");
  end

endmodule
