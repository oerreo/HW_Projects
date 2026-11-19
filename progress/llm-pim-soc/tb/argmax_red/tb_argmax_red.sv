// tb_argmax_red: argmax_red against the golden k_argmax (DPI kd_argmax) and the K_ARGMAX
// records of the dumps.
//
// Streams (one element per valid_i cycle, random gaps with +GAP percent idle cycles; while
// valid_i = 0, v_i / first_i / last_i carry random junk):
//   +VEC=<dir>  every K_ARGMAX record of <dir>/argmax.bin: the record's v as the stream,
//               expected index = the recorded idx (also checked against kd_argmax)
//   +N_RND=<k>  k random streams: n = 1, 2, 3, 2^IDX_W (largest legal), then random lengths;
//               values: full int32 range, a small range (-3..3: many ties), all equal,
//               INT32_MIN / INT32_MAX mixes, increasing, decreasing, ties placed at the first
//               and the last element. Expected index = kd_argmax (golden), expected max = v[idx].
//   Every 4th stream starts in the done_o cycle of the previous one (first_i right after
//   last_i); +RESTART=1 adds unfinished streams cut by a new first_i (the reduction restarts).
// Checks (negedge): done_o exactly in the cycle after each last element and never otherwise,
// idx_o / max_o at done_o and unchanged until the next valid_i.
// +NEG=1: one element without first_i outside a stream (expects one L0_SEQ);
// +NEG=2: a stream of 2^IDX_W + 1 elements (expects one L0_RANGE, no index check for it).
// Plusargs: +SEED +VEC +N_RND +GAP +RESTART +NEG
`timescale 1ns / 1ps
module tb_argmax_red;
  import tb_util_pkg::*;
  import kdpi_pkg::*;

  parameter int IDX_W = 16;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic               valid_i = 1'b0, first_i = 1'b0, last_i = 1'b0, done_o;
  logic signed [31:0] v_i = '0, max_o;
  logic [IDX_W-1:0]   idx_o;

  argmax_red #(.IDX_W(IDX_W)) dut (.clk, .rst_n, .valid_i, .first_i, .last_i, .v_i, .done_o,
                                   .idx_o, .max_o);

  tb_checker c_rec = new("records_idx"), c_rnd = new("random_idx"), c_ctl = new("control"),
             c_gold = new("record_vs_golden");

  // ---- expected results (one per complete stream, in order) ----
  typedef struct { int idx; int mx; bit rec; bit chk; string tag; } exp_t;
  exp_t eq[$];
  bit   hold = 1'b0;
  exp_t hexp;
  logic last_seen = 1'b0;   // previous cycle had valid_i && last_i
  longint n_done = 0, n_streams = 0, n_hold = 0;

  always @(negedge clk) if (rst_n) begin
    if ($isunknown(done_o)) c_ctl.fail("X on done_o");
    if (done_o !== last_seen)
      c_ctl.fail($sformatf("done_o=%b, last element in the previous cycle %b", done_o, last_seen));
    else if (done_o) c_ctl.pass();
    if (hold && !done_o) begin
      if (hexp.chk && (int'(idx_o) !== hexp.idx || max_o !== hexp.mx))
        c_ctl.fail($sformatf("%s: idx_o/max_o %0d/%0d changed after done (held %0d/%0d)", hexp.tag,
                             idx_o, max_o, hexp.idx, hexp.mx));
      else n_hold++;
    end
    if (done_o === 1'b1) begin
      n_done++;
      if (eq.size() == 0) c_ctl.fail("done_o without a pending stream");
      else begin
        hexp = eq.pop_front();
        hold = 1'b1;
        if (hexp.chk) begin
          automatic tb_checker c = hexp.rec ? c_rec : c_rnd;
          if (int'(idx_o) !== hexp.idx || max_o !== hexp.mx)
            c.fail($sformatf("%s: idx %0d max %0d, expected idx %0d max %0d", hexp.tag, idx_o,
                             max_o, hexp.idx, hexp.mx));
          else c.pass();
        end
      end
    end
    if (valid_i === 1'b1) hold = 1'b0;   // outputs may change at the next posedge
    last_seen = valid_i && last_i;
  end

  // ---- driver ----
  int gap = 20;

  task automatic idle_cycle();
    valid_i <= 1'b0;
    first_i <= 1'($urandom);
    last_i  <= 1'($urandom);
    v_i     <= $urandom;
    @(posedge clk);
  endtask

  // drives v[0..cut-1] (cut < size: unfinished stream, no last_i)
  task automatic drive(int v[$], int cut);
    for (int k = 0; k < cut; k++) begin
      while (gap > 0 && $urandom_range(99) < gap) idle_cycle();
      valid_i <= 1'b1;
      first_i <= (k == 0);
      last_i  <= (k == v.size() - 1);
      v_i     <= v[k];
      @(posedge clk);
    end
  endtask

  task automatic run_stream(int v[$], bit rec, int rec_idx, string tag, bit b2b, bit chk = 1'b1);
    exp_t e;
    int vv[] = new[v.size()];
    foreach (v[i]) vv[i] = v[i];
    e.idx = kd_argmax(vv, v.size());
    e.mx  = v[e.idx];
    e.rec = rec;
    e.chk = chk;
    e.tag = tag;
    if (rec) begin
      if (rec_idx !== e.idx) c_gold.fail($sformatf("%s: record idx %0d, kd_argmax %0d", tag, rec_idx, e.idx));
      else c_gold.pass();
      e.idx = rec_idx;
      e.mx  = v[rec_idx];
    end
    eq.push_back(e);
    if (!b2b) repeat ($urandom_range(3)) idle_cycle();
    drive(v, v.size());
    n_streams++;
  endtask

  function automatic void gen(int kind, int n, ref int v[$]);
    v.delete();
    for (int i = 0; i < n; i++)
      case (kind)
        0: v.push_back($urandom);
        1: v.push_back(int'($urandom_range(6)) - 3);
        2: v.push_back(32'h1234_5678);
        3: v.push_back($urandom_range(1) ? 32'h7FFF_FFFF : 32'h8000_0000);
        4: v.push_back(i - 100000);
        5: v.push_back(100000 - i);
        6: v.push_back((i == 0 || i == n - 1) ? 32'h7FFF_FFF0 : int'($urandom_range(1000)));
        7: v.push_back($urandom_range(1) ? 32'h8000_0000 : 32'h8000_0001);
        default: v.push_back(int'($urandom_range(1)) - 1);
      endcase
  endfunction

  int unsigned seed;
  string vdir = "";
  int n_rnd = 0, restart = 0, neg = 0, nrec = 0;

  initial begin
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("VEC=%s", vdir));
    void'($value$plusargs("N_RND=%d", n_rnd));
    void'($value$plusargs("GAP=%d", gap));
    void'($value$plusargs("RESTART=%d", restart));
    void'($value$plusargs("NEG=%d", neg));
    $display("tb_argmax_red: IDX_W=%0d seed=%0d VEC=%s N_RND=%0d GAP=%0d RESTART=%0d NEG=%0d",
             IDX_W, seed, vdir, n_rnd, gap, restart, neg);
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);

    if (neg == 1) begin   // element without first_i outside a stream
      valid_i <= 1'b1; first_i <= 1'b0; last_i <= 1'b0; v_i <= 5;
      @(posedge clk);
      // the rejected element opens nothing; a normal stream follows
    end

    if (vdir != "") begin
      if (kd_rec_open({vdir, "/argmax.bin"}) != 0) c_rec.fail({"cannot open ", vdir, "/argmax.bin"});
      else
        while (kd_rec_next() == K_ARGMAX) begin
          automatic int n = kd_rec_prm(0);
          automatic int v[$];
          if (n < 1 || n > (1 << IDX_W)) begin
            c_rec.fail($sformatf("record %0d: n %0d outside 1..2^IDX_W", kd_rec_index(), n));
            continue;
          end
          for (int i = 0; i < n; i++) v.push_back(kd_rec_get(0, i));
          run_stream(v, 1'b1, kd_rec_get(1, 0), $sformatf("rec %0d", kd_rec_index()), (nrec % 4) == 3);
          nrec++;
        end
      void'(kd_rec_close());
      $display("records: %0d K_ARGMAX records", nrec);
      if (nrec == 0) c_rec.fail("no K_ARGMAX record read");
    end

    for (int s = 0; s < n_rnd; s++) begin
      automatic int nl[] = '{1, 2, 3, 1 << IDX_W};
      automatic int kind = $urandom_range(8);
      automatic int n = (s < nl.size() && nl[s] <= (1 << IDX_W)) ? nl[s] :
                        ($urandom_range(9) == 0 ? $urandom_range(1 << IDX_W, 1) :
                         $urandom_range((1 << IDX_W) < 300 ? (1 << IDX_W) : 300, 1));
      automatic int v[$];
      gen(kind, n, v);
      if (restart && $urandom_range(4) == 0 && n > 1) begin   // unfinished stream first
        automatic int w[$];
        gen($urandom_range(8), n, w);
        drive(w, $urandom_range(n - 1, 1));
      end
      run_stream(v, 1'b0, 0, $sformatf("rnd %0d kind %0d n %0d", s, kind, n), (s % 4) == 3);
    end

    if (neg == 2) begin   // one element too many
      automatic int v[$];
      gen(0, (1 << IDX_W) + 1, v);
      run_stream(v, 1'b0, 0, "neg2", 1'b0, 1'b0);
    end

    repeat (4) idle_cycle();
    $display("streams %0d, done pulses %0d, hold checks %0d", n_streams, n_done, n_hold);
    if (n_done != n_streams) c_ctl.fail($sformatf("done pulses %0d != streams %0d", n_done, n_streams));
    begin
      automatic tb_checker_q chks;
      if (vdir != "") begin chks.push_back(c_rec); chks.push_back(c_gold); end
      if (n_rnd > 0) chks.push_back(c_rnd);
      chks.push_back(c_ctl);
      void'(tb_final_report(chks));
    end
    $finish;
  end
endmodule
