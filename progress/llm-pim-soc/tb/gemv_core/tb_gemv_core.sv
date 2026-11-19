// tb_gemv_core: gemv_core against the K_GEMV records of the golden model.
//
// One call per record of +VEC/gemv.bin (make vec in model/): cfg from the record
// (rows n gs we xm xe fo), x stream = the record's x (lanes >= n of the last beat are
// random garbage: the core must mask them), w stream = the row records of the record
// built by the golden packer rrec_pack (kd_rec_rrec_row, arch.md 2.2), expected y = the
// recorded y of the dump. +SYN=<k> adds k synthetic calls (n over 1..NMAX incl. 1, 7, 8,
// 9, NMAX-1, NMAX; rows 1..48; random W incl. -128, x in -127..127, random wm, xm, we, xe,
// fo; garbage in header bits 63:16 and in the padding of weights and x) against
// kd_gemv1 = k_gemv_out(k_gemv_row(...)).
//
// +STALL=0: every beat is presented as soon as possible and y_ready_i stays high; then
//   the cycle count of every call (start_i cycle to done_o cycle) must equal
//   ceil(n/8) + rows * (1 + ceil(n/8)) + L_PIPE, L_PIPE = 4 + DOT_PIPE + SCALE_PIPE
//   (arch.md 2.4 without L_dram). The sum over the records of a token (+RPT records per
//   token position) minus L_PIPE per record must equal +TOK (arch.md 2.4 table).
// +STALL=1: random gaps on the x and w streams, random y_ready_i (+PY percent ready,
//   default 70), random idle cycles between calls; no cycle check.
// +YBLK=1: also blocks of 50..400 cycles with y_ready_i low; the run must reach the
//   header credit limit (y FIFO full of reserved rows) at least once.
// +NEG=1: one extra start_i pulse in the middle of a call (expects one L2_START).
// Watchdog: 2,000 cycles without any handshake or done while busy ends the run as FAIL.
// Inputs change at posedge (non-blocking), outputs are checked at negedge.
// Plusargs: +SEED +VEC +MAXREC +SYN +STALL +PY +YBLK +TOK +RPT +NEG
`timescale 1ns / 1ps
module tb_gemv_core;
  import tb_util_pkg::*;
  import kdpi_pkg::*;
  import llm_pkg::*;

  parameter int LANES      = 8;
  parameter int NMAX       = 1024;
  parameter int DOT_PIPE   = 2;
  parameter int SCALE_PIPE = 3;
  parameter int Y_DEPTH    = 16;
  localparam int ROWS_W = 16;
  localparam int NW     = $clog2(NMAX + 1);
  localparam int L_PIPE = 4 + DOT_PIPE + SCALE_PIPE;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic                  start_i = 1'b0, busy_o, done_o;
  logic [ROWS_W-1:0]     rows_i = '0;
  logic [NW-1:0]         n_i = '0;
  logic signed [E_W-1:0] we_i = '0, xe_i = '0, fo_i = '0;
  logic [AM_W-1:0]       xm_i = '0;
  logic                  x_valid_i = 1'b0, x_ready_o, w_valid_i = 1'b0, w_ready_o;
  logic [63:0]           x_data_i = '0, w_data_i = '0;
  logic                  y_valid_o, y_ready_i = 1'b0;
  logic [31:0]           y_data_o;

  gemv_core #(.LANES(LANES), .NMAX(NMAX), .ROWS_W(ROWS_W), .DOT_PIPE(DOT_PIPE),
              .SCALE_PIPE(SCALE_PIPE), .Y_DEPTH(Y_DEPTH)) dut (
    .clk(clk), .rst_n(rst_n), .start_i(start_i), .rows_i(rows_i), .n_i(n_i), .we_i(we_i),
    .xe_i(xe_i), .fo_i(fo_i), .xm_i(xm_i), .busy_o(busy_o), .done_o(done_o),
    .x_valid_i(x_valid_i), .x_ready_o(x_ready_o), .x_data_i(x_data_i),
    .w_valid_i(w_valid_i), .w_ready_o(w_ready_o), .w_data_i(w_data_i),
    .y_valid_o(y_valid_o), .y_ready_i(y_ready_i), .y_data_o(y_data_o));

  tb_checker c_rec = new("records_y"), c_syn = new("synthetic_y"), c_cyc = new("cycles"),
             c_ctl = new("control");

  // ---- expected y and the monitor ----
  int    yq[$];
  bit    cur_syn;
  string cur_tag;
  int    yidx;
  longint nidx = 0, done_at = -1;
  int    n_done = 0, n_ystall = 0, n_wstall = 0;
  longint last_prog = 0;
  localparam longint WDOG = 2000;

  always @(negedge clk) begin
    nidx++;
    if (rst_n) begin
      if (y_valid_o === 1'b1 && y_ready_i === 1'b1) begin
        automatic tb_checker c = cur_syn ? c_syn : c_rec;
        if (yq.size() == 0) c_ctl.fail($sformatf("%s: y %0d without expected value", cur_tag, $signed(y_data_o)));
        else begin
          automatic int e = yq.pop_front();
          if ($signed(y_data_o) !== e)
            c.fail($sformatf("%s row %0d: y got %0d exp %0d", cur_tag, yidx, $signed(y_data_o), e));
          else c.pass();
          yidx++;
        end
      end
      if (y_valid_o === 1'b1 && y_ready_i !== 1'b1) n_ystall++;
      if (w_valid_i === 1'b1 && w_ready_o !== 1'b1 && x_ready_o !== 1'b1) n_wstall++;
      if (done_o === 1'b1) begin
        n_done++;
        done_at = nidx;
      end
      if ($isunknown({y_valid_o, done_o, busy_o, x_ready_o, w_ready_o}))
        c_ctl.fail($sformatf("X on a control output at negedge %0d", nidx));
      // watchdog: no handshake and no done for WDOG cycles while a call is open
      if ((x_valid_i && x_ready_o) || (w_valid_i && w_ready_o) || (y_valid_o && y_ready_i) ||
          done_o || !busy_o)
        last_prog = nidx;
      else if (nidx - last_prog > WDOG) begin
        c_ctl.fail($sformatf("%s: no progress for %0d cycles (x_ready %b w_ready %b y_valid %b)",
                             cur_tag, WDOG, x_ready_o, w_ready_o, y_valid_o));
        void'(tb_final_report('{c_rec, c_syn, c_cyc, c_ctl}));
        $finish;
      end
    end
  end

  // ---- drivers (posedge, non-blocking; handshake seen at the negedge before) ----
  int stall = 0, py = 70;

  task automatic drive_x(logic [63:0] beats[$]);
    int i = 0;
    while (i < beats.size()) begin
      bit acc;
      if (stall && $urandom_range(3) == 0) begin
        x_valid_i <= 1'b0;
        x_data_i  <= {$urandom(), $urandom()};
        @(posedge clk);
        continue;
      end
      x_valid_i <= 1'b1;
      x_data_i  <= beats[i];
      @(negedge clk);
      acc = x_ready_o === 1'b1;
      @(posedge clk);
      if (acc) i++;
    end
    x_valid_i <= 1'b0;
  endtask

  // row records: from the current record (golden packer) or from syn_w (synthetic)
  logic [63:0] syn_w[$];
  task automatic drive_w(int rows, int nbeat, bit syn);
    longint bt[] = new[nbeat];
    for (int r = 0; r < rows; r++) begin
      int j = 0;
      if (syn) for (int k = 0; k < nbeat; k++) bt[k] = syn_w[r * nbeat + k];
      else if (kd_rec_rrec_row(r, bt) != nbeat) c_ctl.fail("kd_rec_rrec_row failed");
      while (j < nbeat) begin
        bit acc;
        if (stall && $urandom_range(4) == 0) begin
          w_valid_i <= 1'b0;
          w_data_i  <= {$urandom(), $urandom()};
          @(posedge clk);
          continue;
        end
        w_valid_i <= 1'b1;
        w_data_i  <= bt[j];
        @(negedge clk);
        acc = w_ready_o === 1'b1;
        @(posedge clk);
        if (acc) j++;
      end
    end
    w_valid_i <= 1'b0;
  endtask

  // y_ready_i: random (+STALL, +PY percent) and, with +YBLK=1, blocks of 50..400 cycles
  // with y_ready_i low (on average one per 1,000 cycles) so that the y FIFO fills and the
  // header credit limits the w stream
  bit yr_run = 1'b0;
  int yblk = 0, blk_left = 0;
  longint n_cred_full = 0;
  always @(posedge clk) begin
    if (yblk && blk_left == 0 && $urandom_range(999) == 0) blk_left = $urandom_range(400, 50);
    if (blk_left > 0) begin
      blk_left--;
      y_ready_i <= 1'b0;
    end else y_ready_i <= yr_run && (!stall || $urandom_range(99) < py);
  end
  // header held back by the credit (FIFO full of reserved rows)
  always @(negedge clk)
    if (rst_n && w_valid_i && !w_ready_o && dut.bidx_q == '0 && dut.cred_q >= Y_DEPTH) n_cred_full++;

  // ---- one call ----
  int neg = 0, neg_done = 0;
  longint cyc_sum = 0;

  task automatic do_call(int rows, int n, int we, int xm, int xe, int fo, logic [63:0] xbeats[$],
                         bit syn, string tag, output longint cyc);
    int nb = (n + 7) / 8;
    longint t0;
    cur_syn = syn;
    cur_tag = tag;
    yidx    = 0;
    if (stall) repeat ($urandom_range(3)) @(posedge clk);
    // start (cycle t0 = the negedge index of the cycle start_i is high)
    start_i <= 1'b1;
    rows_i  <= ROWS_W'(rows);
    n_i     <= NW'(n);
    we_i    <= E_W'(we);
    xe_i    <= E_W'(xe);
    fo_i    <= E_W'(fo);
    xm_i    <= AM_W'(xm);
    t0 = nidx + 1;
    done_at = -1;
    fork
      begin
        @(posedge clk);
        start_i <= 1'b0;
        rows_i  <= ROWS_W'($urandom());   // cfg inputs are only sampled with start_i
        n_i     <= NW'($urandom());
        xm_i    <= AM_W'($urandom());
        if (neg == 1 && neg_done == 0) begin
          neg_done = 1;
          repeat (nb + 3) @(posedge clk);
          start_i <= 1'b1;                // ignored: busy (L2_START)
          @(posedge clk);
          start_i <= 1'b0;
        end
      end
      drive_x(xbeats);
      drive_w(rows, 1 + nb, syn);
    join
    while (done_at < 0) @(negedge clk);
    if (yq.size() != 0) c_ctl.fail($sformatf("%s: %0d y values missing at done", tag, yq.size()));
    else c_ctl.pass();
    cyc = done_at - t0;
    if (!stall) begin
      longint e = longint'(nb) + longint'(rows) * (1 + nb) + L_PIPE;
      if (cyc != e) c_cyc.fail($sformatf("%s rows %0d n %0d: %0d cycles, formula %0d", tag, rows, n, cyc, e));
      else c_cyc.pass();
    end
    @(posedge clk);
  endtask

  int unsigned seed;
  string vdir = "";
  int maxrec = 0, nsyn = 0, rpt = 0, nrec = 0, nrows = 0;
  longint tok = 0, cyc_max = 0;

  initial begin
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("VEC=%s", vdir));
    void'($value$plusargs("MAXREC=%d", maxrec));
    void'($value$plusargs("SYN=%d", nsyn));
    void'($value$plusargs("STALL=%d", stall));
    void'($value$plusargs("PY=%d", py));
    void'($value$plusargs("TOK=%d", tok));
    void'($value$plusargs("RPT=%d", rpt));
    void'($value$plusargs("NEG=%d", neg));
    void'($value$plusargs("YBLK=%d", yblk));
    $display("tb_gemv_core: DOT_PIPE=%0d SCALE_PIPE=%0d Y_DEPTH=%0d L_PIPE=%0d (dut %0d) seed=%0d VEC=%s MAXREC=%0d SYN=%0d STALL=%0d PY=%0d NEG=%0d",
             DOT_PIPE, SCALE_PIPE, Y_DEPTH, L_PIPE, dut.L_PIPE, seed, vdir, maxrec, nsyn, stall, py, neg);
    if (dut.L_PIPE != L_PIPE) c_cyc.fail($sformatf("dut L_PIPE %0d != %0d", dut.L_PIPE, L_PIPE));
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);
    yr_run = 1'b1;

    // ---- records ----
    if (vdir != "") begin
      if (kd_rec_open({vdir, "/gemv.bin"}) != 0) c_rec.fail({"cannot open ", vdir, "/gemv.bin"});
      else
        while ((maxrec == 0 || nrec < maxrec) && kd_rec_next() == K_GEMV) begin
          automatic int rows = kd_rec_prm(0), n = kd_rec_prm(1), gs = kd_rec_prm(2);
          automatic int we = kd_rec_prm(3), xm = kd_rec_prm(4), xe = kd_rec_prm(5), fo = kd_rec_prm(6);
          automatic int nb = (n + 7) / 8;
          automatic byte xb[] = new[n];
          automatic logic [63:0] xbeats[$];
          automatic longint cyc;
          if (gs != n || n < 1 || n > NMAX || rows < 1 || rows >= (1 << ROWS_W) || xm < 0 ||
              xm >= (1 << AM_W) || we < -128 || we > 127 || xe < -128 || xe > 127 || fo < -128 || fo > 127) begin
            c_rec.fail($sformatf("record %0d outside the gemv_core cfg range", kd_rec_index()));
            nrec++;
            continue;
          end
          void'(kd_rec_bytes(2, 0, xb, n));
          for (int j = 0; j < nb; j++) begin
            automatic logic [63:0] b = {$urandom(), $urandom()};    // garbage in the padding lanes
            for (int l = 0; l < 8; l++) if (j * 8 + l < n) b[l*8 +: 8] = xb[j * 8 + l];
            xbeats.push_back(b);
          end
          for (int r = 0; r < rows; r++) yq.push_back(kd_rec_get(3, r));
          do_call(rows, n, we, xm, xe, fo, xbeats, 1'b0, $sformatf("rec %0d", kd_rec_index()), cyc);
          cyc_sum += cyc - L_PIPE;
          if (cyc > cyc_max) cyc_max = cyc;
          nrec++;
          nrows += rows;
        end
      void'(kd_rec_close());
      $display("records: %0d K_GEMV records, %0d rows", nrec, nrows);
      if (nrec == 0) c_rec.fail("no K_GEMV record read");
      if (!stall && rpt > 0) begin
        $display("cycles: sum over records of (C - L_PIPE) = %0d, per token %0d (%0d records/token), arch.md 2.4: %0d",
                 cyc_sum, cyc_sum / (nrec / rpt), rpt, tok);
        if (nrec % rpt != 0 || cyc_sum != tok * (nrec / rpt))
          c_cyc.fail($sformatf("token cycles %0d x %0d tokens != %0d", tok, nrec / rpt, cyc_sum));
        else c_cyc.pass();
      end
    end

    // ---- synthetic ----
    for (int s = 0; s < nsyn; s++) begin
      automatic int k = $urandom_range(9);
      automatic int nl[] = '{1, 7, 8, 9, NMAX - 1, NMAX};
      automatic int n = (s < nl.size()) ? nl[s] : (k < 3 ? $urandom_range(24, 1) : $urandom_range(NMAX, 1));
      automatic int rows = (k == 0) ? 1 : (k == 1 ? 2 : $urandom_range(48, 1));
      automatic int nb = (n + 7) / 8;
      automatic int xm = (k == 2) ? (1 << AM_W) - 1 : $urandom_range((1 << AM_W) - 1);
      automatic int we = (k == 3) ? int'($urandom_range(255)) - 128 : $urandom_range(30, 18);
      automatic int xe = (k == 4) ? int'($urandom_range(255)) - 128 : $urandom_range(30, 15);
      automatic int fo = (k == 5) ? int'($urandom_range(255)) - 128 : 16;
      automatic byte xb[] = new[n], wb[] = new[n];
      automatic logic [63:0] xbeats[$];
      automatic longint cyc;
      foreach (xb[i]) xb[i] = byte'(int'($urandom_range(254)) - 127);
      for (int j = 0; j < nb; j++) begin
        automatic logic [63:0] b = {$urandom(), $urandom()};
        for (int l = 0; l < 8; l++) if (j * 8 + l < n) b[l*8 +: 8] = xb[j * 8 + l];
        xbeats.push_back(b);
      end
      syn_w.delete();
      for (int r = 0; r < rows; r++) begin
        automatic int wm = ($urandom_range(9) == 0) ? 65535 : $urandom_range(65535);
        foreach (wb[i]) wb[i] = byte'($urandom());
        syn_w.push_back({$urandom(), 16'($urandom()), 16'(wm)});   // header, garbage above wm
        for (int j = 0; j < nb; j++) begin
          automatic logic [63:0] b = {$urandom(), $urandom()};                // garbage in the padding
          for (int l = 0; l < 8; l++) if (j * 8 + l < n) b[l*8 +: 8] = wb[j * 8 + l];
          syn_w.push_back(b);
        end
        yq.push_back(kd_gemv1(wb, xb, n, wm, xm, we + xe - fo));
      end
      do_call(rows, n, we, xm, xe, fo, xbeats, 1'b1, $sformatf("syn %0d", s), cyc);
    end

    repeat (5) @(posedge clk);
    $display("calls done %0d, cycles with y stalled %0d, cycles with w waiting %0d, longest call %0d cycles",
             n_done, n_ystall, n_wstall, cyc_max);
    if (n_done != nrec + nsyn) c_ctl.fail($sformatf("done pulses %0d != calls %0d", n_done, nrec + nsyn));
    $display("cycles with a row header held back by the credit: %0d", n_cred_full);
    if (stall && n_ystall == 0) c_ctl.fail("stall run without y stall");
    if (yblk && n_cred_full == 0) c_ctl.fail("YBLK run never reached the credit limit");
    if (neg == 1 && neg_done == 0) c_ctl.fail("negative case not injected");
    begin
      automatic tb_checker_q chks;
      if (vdir != "") chks.push_back(c_rec);
      if (nsyn > 0) chks.push_back(c_syn);
      if (!stall) chks.push_back(c_cyc);
      chks.push_back(c_ctl);
      void'(tb_final_report(chks));
    end
    $finish;
  end
endmodule
