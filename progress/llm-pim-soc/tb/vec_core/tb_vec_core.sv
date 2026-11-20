// tb_vec_core: vec_core (rms_front, swi_front, actq_core, argmax_red, shared buffer, unpacker)
// against the golden model (DPI-C, tb/common/vec_tb_pkg.sv) through its beat stream interface.
// The TB plays the read engine: for every call it sends the beats of the call's commands in the
// golden buffer layout (int32 arrays two per beat, the RMSNORM g int16 four per beat, the bytes of
// a last beat beyond the array random), d_last on the last beat of each command.
// Calls: +VEC1 / +VEC2 every K_RMSNORM, K_SWIGLU, K_ACTQ and K_ARGMAX record of the two models
// (+MAXREC per kernel), interleaved in the order of the records' manifest is not needed: the
// kernels are taken round-robin (rmsnorm, actq, swiglu, actq, argmax ...) so that consecutive calls
// change the op; +NSYN synthetic calls of a random op (n 1..N_MAX, ARGMAX up to +AMAXN, ties).
// Checks: every q (in order) and the scale {m, e} at done, ARGMAX index and value, done once per
// call, busy_o; +CYC=1 (no gaps, no stalls): start-to-done == the op formula (docs/spec/vec.md 6):
// RMSNORM 4n + 87 (ymax 0: 4n + 34), SWIGLU 3n + 67 (3n + 14), ACTQ 2n + 59 (2n + 6), ARGMAX n + 1.
// Stimulus: beat gaps (+GAP), q_ready stalls (+QSTALL), +QBLK long q_ready blocks (q FIFO full
// required), start in the done cycle of the previous call (+B2B). Watchdog TB_TIMEOUT.
`timescale 1ns / 1ps
module tb_vec_core;
  import tb_util_pkg::*;
  import kdpi_pkg::*;
  import vec_tb_pkg::*;
  import llm_pkg::*;

  parameter int N_MAX   = 1024;
  parameter int IDX_W   = 16;
  parameter int Q_DEPTH = 8;
  localparam int NV_W = IDX_W + 1;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic                   start_i = 1'b0, d_valid_i = 1'b0, d_ready_o, d_last_i = 1'b0;
  logic [1:0]             op_i = '0;
  logic [NV_W-1:0]        n_i = '0;
  logic signed [E_W-1:0]  f_i = '0, ge_i = '0;
  logic [15:0]            qmax_i = '0;
  logic [31:0]            epsc_i = '0;
  logic [63:0]            d_data_i = '0;
  logic                   q_valid_o, q_ready_i = 1'b1, scl_valid_o, busy_o, done_o;
  logic [15:0]            q_o;
  logic [AM_W-1:0]        m_o;
  logic signed [SH_W-1:0] e_o;
  logic [IDX_W-1:0]       am_idx_o;
  logic signed [31:0]     am_max_o;

  vec_core #(.N_MAX(N_MAX), .IDX_W(IDX_W), .Q_DEPTH(Q_DEPTH)) dut (
    .clk, .rst_n, .start_i, .op_i, .n_i, .f_i, .qmax_i, .ge_i, .epsc_i, .d_valid_i, .d_ready_o,
    .d_data_i, .d_last_i, .q_valid_o, .q_ready_i, .q_o, .m_o, .e_o, .scl_valid_o, .am_idx_o,
    .am_max_o, .busy_o, .done_o);

  tb_checker c_q = new("q"), c_s = new("scale"), c_am = new("argmax"), c_hs = new("handshake"),
             c_cyc = new("cycles"), c_rec = new("record"), c_cov = new("coverage");

  function automatic int opof(vcase c);
    return c.kid == K_RMSNORM ? 0 : c.kid == K_SWIGLU ? 1 : c.kid == K_ACTQ ? 2 : 3;
  endfunction

  // ---------------- monitor ----------------
  vcase   cq[$];
  longint ts[$];
  int     oq = 0;
  longint cyc = 0, t_last = -10, n_calls = 0, n_full = 0, n_b2b = 0;
  longint ncall_op[4] = '{0, 0, 0, 0};
  bit     chk_cyc = 0;
  always @(negedge clk) begin
    cyc++;
    if (rst_n) begin
      automatic bit acc = start_i === 1'b1 && (busy_o === 1'b0 || done_o === 1'b1);
      automatic int nopen = cq.size() - acc;   // calls started before this cycle, not yet done
      if (busy_o !== (nopen > 0)) c_hs.fail($sformatf("busy_o %b with %0d calls open", busy_o, nopen));
      else c_hs.pass();
      if (acc) ts.push_back(cyc);
      if (q_valid_o === 1'b1 && q_ready_i === 1'b1) begin
        if (cq.size() == 0 || opof(cq[0]) == 3 || oq >= cq[0].n) c_hs.fail("unexpected q");
        else begin
          if ($signed(q_o) !== cq[0].q[oq])
            c_q.fail($sformatf("%s: q[%0d] %0d golden %0d", cq[0].desc(), oq, $signed(q_o), cq[0].q[oq]));
          else c_q.pass();
          oq++;
          if (oq == cq[0].n) t_last = cyc;
        end
      end
      if (done_o === 1'b1) begin
        if (cq.size() == 0) c_hs.fail("done without a call");
        else begin
          automatic vcase c = cq.pop_front();
          automatic longint t0 = ts.pop_front(), ex;
          automatic int op = opof(c);
          if (op != 3) begin
            if (oq != c.n || t_last != cyc - 1) c_hs.fail($sformatf("%s: done after %0d q", c.desc(), oq));
            else c_hs.pass();
            if (int'(m_o) !== c.sm || int'(e_o) !== c.se || scl_valid_o !== 1'b1)
              c_s.fail($sformatf("%s: m %0d e %0d golden %0d %0d", c.desc(), m_o, e_o, c.sm, c.se));
            else c_s.pass();
          end else begin
            if (int'(am_idx_o) !== c.idx || am_max_o !== c.in0[c.idx])
              c_am.fail($sformatf("%s: idx %0d max %0d golden %0d %0d", c.desc(), am_idx_o, am_max_o, c.idx, c.in0[c.idx]));
            else c_am.pass();
          end
          case (op)
            0: ex = 4 * c.n + (c.ymax != 0 ? 87 : 34);
            1: ex = 3 * c.n + (c.amax != 0 ? 67 : 14);
            2: ex = 2 * c.n + (c.amax != 0 ? 59 : 6);
            default: ex = c.n + 1;
          endcase
          if (chk_cyc) begin
            if (cyc - t0 !== ex) c_cyc.fail($sformatf("%s: %0d cycles, formula %0d", c.desc(), cyc - t0, ex));
            else c_cyc.pass();
          end
          ncall_op[op]++;
          n_calls++;
        end
        oq = 0;
      end
      if (int'(dut.u_aq.f_level) == Q_DEPTH) n_full++;
    end
  end

  int qstall = 0, qblk = 0, gap = 0, b2b = 1;
  bit blk_on = 0;
  always @(posedge clk) q_ready_i <= !blk_on && ($urandom_range(99) >= qstall);
  initial begin
    wait (rst_n === 1'b1);
    forever begin
      @(posedge clk);
      if (qblk && q_valid_o === 1'b1 && $urandom_range(15) == 0) begin
        blk_on = 1;
        repeat ($urandom_range(300, 20)) @(posedge clk);
        blk_on = 0;
        repeat ($urandom_range(200, 30)) @(posedge clk);
      end
    end
  end

  // ---------------- driver ----------------
  // beats of one array: esz 4 (two per beat) or 2 (four per beat), random bytes after the end
  task automatic send(int a[], int esz);
    int n = a.size(), per = 8 / esz, nb = (n + per - 1) / per;
    for (int b = 0; b < nb; ) begin
      logic [63:0] w = {$urandom(), $urandom()};
      for (int l = 0; l < per && b * per + l < n; l++)
        if (esz == 4) w[32 * l +: 32] = a[b * per + l];
        else w[16 * l +: 16] = 16'(a[b * per + l]);
      if ($urandom_range(99) < gap) begin
        d_valid_i <= 1'b0;
        d_data_i  <= {$urandom(), $urandom()};
        @(posedge clk);
        continue;
      end
      d_valid_i <= 1'b1;
      d_data_i  <= w;
      d_last_i  <= b == nb - 1;
      @(negedge clk);
      if (d_ready_o === 1'b1) b++;
      @(posedge clk);
    end
    d_valid_i <= 1'b0;
    d_last_i  <= 1'b0;
  endtask

  task automatic do_call(vcase c);
    bit back = b2b && cq.size() > 0 && opof(cq[0]) != 3 && $urandom_range(1);
    int op = opof(c);
    if (back) begin
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
    op_i    <= 2'(op);
    n_i     <= NV_W'(c.n);
    f_i     <= E_W'(op == 0 ? c.p2 : c.p0);
    qmax_i  <= 16'(op == 2 ? c.p1 : 0);
    ge_i    <= E_W'(op == 0 ? c.p0 : 0);
    epsc_i  <= op == 0 ? c.p1 : 0;
    cq.push_back(c);
    @(posedge clk);
    start_i <= 1'b0;
    op_i <= 2'($urandom()); n_i <= '0;
    send(c.in0, 4);
    if (op == 0) send(c.in1, 2);
    if (op == 1) send(c.in1, 4);
  endtask

  initial begin
    automatic int unsigned seed;
    automatic string vec1 = "", vec2 = "";
    automatic int nsyn = 0, nrec = 0, maxrec = 1 << 30, amaxn = 4096;
    automatic string kn[4] = '{"rmsnorm", "swiglu", "actq", "argmax"};
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("VEC1=%s", vec1));
    void'($value$plusargs("VEC2=%s", vec2));
    void'($value$plusargs("NSYN=%d", nsyn));
    void'($value$plusargs("MAXREC=%d", maxrec));
    void'($value$plusargs("AMAXN=%d", amaxn));
    void'($value$plusargs("GAP=%d", gap));
    void'($value$plusargs("QSTALL=%d", qstall));
    void'($value$plusargs("QBLK=%d", qblk));
    void'($value$plusargs("B2B=%d", b2b));
    void'($value$plusargs("CYC=%d", chk_cyc));
    $display("tb_vec_core: N_MAX %0d IDX_W %0d seed %0d NSYN %0d GAP %0d QSTALL %0d QBLK %0d CYC %0d",
             N_MAX, IDX_W, seed, nsyn, gap, qstall, qblk, chk_cyc);
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    @(posedge clk);
    for (int m = 0; m < 2; m++) begin
      automatic string v = m == 0 ? vec1 : vec2;
      automatic vcase lists[4][$];
      if (v == "") continue;
      // load every record of the four kernels (up to MAXREC each), then interleave them
      for (int k = 0; k < 4; k++) begin
        if (kd_rec_open({v, "/", kn[k], ".bin"}) != 0) $fatal(1, "tb_vec_core: no %s records in %s", kn[k], v);
        while (lists[k].size() < maxrec && kd_rec_next() > 0) begin
          automatic vcase c = new();
          automatic int rc = c.load_rec();
          if (rc != 0 || (k < 3 && c.n > N_MAX) || c.n > (1 << IDX_W)) begin
            c_rec.fail($sformatf("%s %s record %0d: load %0d", v, kn[k], kd_rec_index(), rc));
            continue;
          end
          c_rec.pass();
          c.tag = $sformatf("m%0d %s %0d", m + 1, kn[k], c.rec);
          lists[k].push_back(c);
        end
        void'(kd_rec_close());
      end
      while (lists[0].size() + lists[1].size() + lists[2].size() + lists[3].size() > 0) begin
        automatic int order[5] = '{0, 2, 1, 2, 3};
        foreach (order[j])
          if (lists[order[j]].size() > 0) begin
            do_call(lists[order[j]].pop_front());
            nrec++;
          end
      end
    end
    for (int i = 0; i < nsyn; i++) begin
      automatic vcase c = new();
      automatic int op = i < 8 ? i / 2 : $urandom_range(3);
      automatic int kids[4] = '{K_RMSNORM, K_SWIGLU, K_ACTQ, K_ARGMAX};
      automatic int nm = op == 3 ? amaxn : N_MAX;
      automatic int n = i < 8 ? (i % 2 == 0 ? 1 : nm) : $urandom_range(3) == 0 ? $urandom_range(16, 1) : $urandom_range(nm, 1);
      c.gen_syn(kids[op], n, $urandom_range(7));
      do_call(c);
    end
    while (cq.size() > 0) @(posedge clk);
    repeat (10) @(posedge clk);
    $display("tb_vec_core: %0d records, %0d synthetic, %0d calls (rms %0d swi %0d actq %0d argmax %0d), %0d back-to-back, q FIFO full %0d cycles",
             nrec, nsyn, n_calls, ncall_op[0], ncall_op[1], ncall_op[2], ncall_op[3], n_b2b, n_full);
    if (n_calls != nrec + nsyn) c_hs.fail($sformatf("%0d calls done of %0d", n_calls, nrec + nsyn));
    begin
      automatic tb_checker_q l = '{c_q, c_s, c_am, c_hs};
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
    static longint unsigned lim = 64'd200_000_000;
    void'($value$plusargs("TIMEOUT=%d", lim));
    repeat (lim) @(posedge clk);
    $fatal(1, "TB_TIMEOUT tb_vec_core");
  end

endmodule
