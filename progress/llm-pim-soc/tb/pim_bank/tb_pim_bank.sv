// tb_pim_bank: one PIM bank (rtl/l1/pim_bank.sv) alone.
// Golden (none of it from the RTL):
//   image : kd_rec_bimg (bimg_pack of model/src/bank.c) of each K_GEMV record of +VEC, nb = NB_IMG
//           banks, base 0; the TB writes bank b's words at base + a (random base) through we_i.
//   rows  : row r = i NB_IMG + b of the record: acc = kd_rec_gemv_acc(r) (k_dot8 of W[r] and x),
//           wm = the record's mantissa m[r] (kd_rec_getu(1, r)).
//   synthetic (+SYN=k): random rows (n 1..NMAX, garbage in lanes >= n and in the tags of non-first
//           words, x = 0 beyond n like pim_gb), acc = kd_dot8 of the first n lanes, wm = TB value.
// Checks: RAM contents after the writes (backdoor) == image, every word outside the written range
// == its random prefill; every res_valid_o exactly LATENCY cycles after the read of the row's last
// word, in row order, with acc / wm; no res_valid_o otherwise. Random gaps between word reads (+GAP).
// x_i is driven one cycle after the read (the pim_gb latency).
// Plusargs: +SEED +VEC +MAXREC +SYN +GAP
`timescale 1ns / 1ps
module tb_pim_bank #(
  parameter int DEPTH    = 4096,
  parameter int DOT_PIPE = 2
);
  import tb_util_pkg::*;
  import kdpi_pkg::*;
  import llm_pkg::*;

  localparam int LB = 16, NMAX = 1024, NB_IMG = 4, AA = $clog2(DEPTH), ACC_W = 25, WW = 8 * LB + 16;
  localparam int LATENCY = 3 + DOT_PIPE;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic              we = 0, re = 0, first = 0, last = 0;
  logic [AA-1:0]     waddr = 0, raddr = 0;
  logic [WW-1:0]     wdata = 0;
  logic [8*LB-1:0]   xin = 0;
  logic              rv;
  logic signed [ACC_W-1:0] racc;
  logic [15:0]       rwm;

  pim_bank #(.LB(LB), .DEPTH(DEPTH), .NMAX(NMAX), .DOT_PIPE(DOT_PIPE)) dut (
    .clk, .rst_n, .we_i(we), .waddr_i(waddr), .wdata_i(wdata),
    .re_i(re), .raddr_i(raddr), .first_i(first), .last_i(last), .x_i(xin),
    .res_valid_o(rv), .res_acc_o(racc), .res_wm_o(rwm));

  tb_checker c_mem = new("bank_memory"), c_res = new("row_result"), c_lat = new("latency");

  // expected results
  typedef struct { longint t; int acc; int wm; string tag; } exp_t;
  exp_t eq[$];
  longint cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  always @(negedge clk) if (rst_n) begin
    if (rv === 1'b1) begin
      if (eq.size() == 0) c_res.fail($sformatf("unexpected res_valid_o (acc %0d wm %h)", racc, rwm));
      else begin
        automatic exp_t e = eq.pop_front();
        if (cyc != e.t) c_lat.fail($sformatf("%s: result in cycle %0d, expected %0d", e.tag, cyc, e.t));
        else c_lat.pass();
        if (racc !== ACC_W'(e.acc) || rwm !== 16'(e.wm))
          c_res.fail($sformatf("%s: acc %0d wm %h, expected %0d %h", e.tag, racc, rwm, e.acc, 16'(e.wm)));
        else c_res.pass();
      end
    end else if (rv !== 1'b0) c_res.fail("X on res_valid_o");
  end

  int gap = 0;

  // ---- RAM helpers ----
  logic [WW-1:0] pre [DEPTH];

  task automatic prefill();
    for (int a = 0; a < DEPTH; a++) begin
      pre[a] = {$urandom, $urandom, $urandom, $urandom, $urandom};
      dut.u_ram.mem[a] = pre[a];
    end
  endtask

  task automatic write_words(int base, logic [WW-1:0] img[$]);
    int ord[] = new[img.size()];
    foreach (ord[i]) ord[i] = i;
    ord.shuffle();               // any order (LDW writes in row order; the bank does not care)
    foreach (ord[k]) begin
      while ($urandom_range(99) < gap) begin
        @(posedge clk);
        we <= 1'b0;
        waddr <= AA'($urandom);
        wdata <= {$urandom, $urandom, $urandom, $urandom, $urandom};
      end
      @(posedge clk);
      we    <= 1'b1;
      waddr <= AA'(base + ord[k]);
      wdata <= img[ord[k]];
    end
    @(posedge clk);
    we <= 1'b0;
    @(negedge clk);
  endtask

  task automatic check_mem(int base, logic [WW-1:0] img[$], string tag);
    int bad = 0;
    for (int a = 0; a < DEPTH; a++) begin
      logic [WW-1:0] e = (a >= base && a < base + img.size()) ? img[a - base] : pre[a];
      if (dut.u_ram.mem[a] !== e) begin
        bad++;
        if (bad <= 3) c_mem.fail($sformatf("%s: word %0d = %h, expected %h", tag, a, dut.u_ram.mem[a], e));
      end
    end
    if (bad == 0) c_mem.pass();
    // the written image becomes the prefill reference for the next check
    foreach (img[i]) pre[base + i] = img[i];
  endtask

  // one row: nw words at addr, x words xw; expected acc / wm
  task automatic mac_row(int addr, int nw, logic [127:0] xw[$], int acc, int wm, string tag);
    for (int w = 0; w < nw; w++) begin
      while ($urandom_range(99) < gap) begin
        @(posedge clk);
        re <= 1'b0; first <= $urandom; last <= $urandom; raddr <= AA'($urandom);
      end
      @(posedge clk);
      re    <= 1'b1;
      raddr <= AA'(addr + w);
      first <= w == 0;
      last  <= w == nw - 1;
      if (w == nw - 1) eq.push_back('{cyc + 1 + LATENCY, acc, wm, tag});   // read happens in cycle cyc + 1
      begin
        automatic logic [127:0] xv = xw[w];   // captured now (the loop goes on before the fork runs)
        fork
          begin
            @(posedge clk);
            xin <= xv;    // x of this read, one cycle later
          end
        join_none
      end
    end
    @(posedge clk);
    re <= 1'b0;
  endtask

  // ---- records ----
  task automatic run_records(string vdir, int maxrec);
    int nrec = 0;
    if (kd_rec_open({vdir, "/gemv.bin"}) != 0) begin c_res.fail("cannot open gemv.bin"); return; end
    while ((maxrec == 0 || nrec < maxrec) && kd_rec_next() == K_GEMV) begin
      int rows = kd_rec_prm(0), n = kd_rec_prm(1), nw = (n + LB - 1) / LB;
      int used = kd_rec_bimg(NB_IMG);
      logic [127:0] xw[$];
      byte xb[] = new[n];
      if (used < 0) begin c_res.fail("record not row-wise"); nrec++; continue; end
      void'(kd_rec_bytes(2, 0, xb, n));
      for (int w = 0; w < nw; w++) begin
        logic [127:0] v = '0;
        for (int l = 0; l < LB; l++) if (16 * w + l < n) v[8*l +: 8] = xb[16 * w + l];
        xw.push_back(v);
      end
      for (int b = 0; b < NB_IMG; b++) begin
        logic [WW-1:0] img[$];
        int base = $urandom_range(DEPTH - used);
        for (int a = 0; a < used; a++)
          img.push_back({16'(kd_bimg_tag(b, a)), 64'(kd_bimg_hi(b, a)), 64'(kd_bimg_lo(b, a))});
        write_words(base, img);
        check_mem(base, img, $sformatf("rec %0d bank %0d", kd_rec_index(), b));
        for (int i = 0; i * NB_IMG + b < rows; i++) begin
          int r = i * NB_IMG + b;
          mac_row(base + i * nw, nw, xw, kd_rec_gemv_acc(r), kd_rec_getu(1, r),
                  $sformatf("rec %0d row %0d", kd_rec_index(), r));
        end
      end
      nrec++;
    end
    void'(kd_rec_close());
    $display("records: %0d K_GEMV records x %0d banks", nrec, NB_IMG);
    if (nrec == 0) c_res.fail("no record");
  endtask

  // ---- synthetic rows ----
  int ncorner[] = '{1, 16, 17, NMAX};
  task automatic run_syn(int nsyn);
    for (int s = 0; s < nsyn; s++) begin
      int n = (s < ncorner.size()) ? ncorner[s] : ($urandom_range(2) == 0 ? $urandom_range(40, 1) : $urandom_range(NMAX, 1));
      int nw = (n + LB - 1) / LB, rows = $urandom_range(8, 1), base;
      int kind = $urandom_range(9);
      byte xb[] = new[n];
      logic [127:0] xw[$];
      logic [WW-1:0] img[$];
      int accs[$], wms[$];
      foreach (xb[i]) xb[i] = (kind == 0) ? -127 : byte'(int'($urandom_range(254)) - 127);
      for (int w = 0; w < nw; w++) begin
        logic [127:0] v = '0;
        for (int l = 0; l < LB; l++) if (16 * w + l < n) v[8*l +: 8] = xb[16 * w + l];
        xw.push_back(v);
      end
      for (int r = 0; r < rows; r++) begin
        byte wb[] = new[n];
        int wm = $urandom_range(65535);
        foreach (wb[i]) wb[i] = (kind == 0) ? -128 : (kind == 1 ? 127 : byte'($urandom));
        for (int w = 0; w < nw; w++) begin
          logic [WW-1:0] v;
          v = {16'($urandom), $urandom, $urandom, $urandom, $urandom};   // garbage lanes / tag
          if (w == 0) v[WW-1 -: 16] = 16'(wm);
          for (int l = 0; l < LB; l++) if (16 * w + l < n) v[8*l +: 8] = wb[16 * w + l];
          img.push_back(v);
        end
        accs.push_back(kd_dot8(wb, xb, n));
        wms.push_back(wm);
      end
      base = $urandom_range(DEPTH - rows * nw);
      write_words(base, img);
      check_mem(base, img, $sformatf("syn %0d", s));
      for (int r = 0; r < rows; r++)
        mac_row(base + r * nw, nw, xw, accs[r], wms[r], $sformatf("syn %0d row %0d n %0d", s, r, n));
    end
  endtask

  int unsigned seed;
  string vdir = "";
  int maxrec = 0, nsyn = 0;

  initial begin
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("VEC=%s", vdir));
    void'($value$plusargs("MAXREC=%d", maxrec));
    void'($value$plusargs("SYN=%d", nsyn));
    void'($value$plusargs("GAP=%d", gap));
    $display("tb_pim_bank: DEPTH %0d DOT_PIPE %0d LATENCY %0d SEED %0d VEC %s MAXREC %0d SYN %0d GAP %0d",
             DEPTH, DOT_PIPE, LATENCY, seed, vdir, maxrec, nsyn, gap);
    prefill();
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);
    if (vdir != "") run_records(vdir, maxrec);
    if (nsyn > 0) run_syn(nsyn);
    repeat (LATENCY + 5) @(posedge clk);
    if (eq.size() != 0) c_res.fail($sformatf("%0d results missing", eq.size()));
    void'(tb_final_report('{c_mem, c_res, c_lat}));
    $finish;
  end

  initial begin
    #2s;
    $error("TB_TIMEOUT global");
    $finish;
  end
endmodule
