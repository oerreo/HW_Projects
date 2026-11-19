// tb_gemv_scale: gemv_scale against the golden k_gemv_out (stage A2).
//
//   records: every row of the K_GEMV records of +VEC/gemv.bin (and +VEC2/gemv.bin):
//            acc = kd_rec_gemv_acc(r) (stage A1 trace), wm = m[r], xm, sh = we + xe - fo;
//            expected = the recorded y[r] of the dump. The golden chain is checked too:
//            kd_gemv_out(kd_rec_gemv_s(r), xm, sh) == y[r] and S == acc * wm ("trace").
//   random : +N inputs (default 1,000,000): acc over the ACC_W range (full, small,
//            extremes), wm and xm over their whole ranges (incl. 0 and the maximum), sh
//            mostly -70..70 plus the whole SH_W range; expected kd_gemv_out(acc * wm, xm,
//            sh).
// valid_i has random gaps; outputs are checked at negedge exactly LATENCY cycles later.
// Plusargs: +SEED +VEC=<dir> +VEC2=<dir> +MAXREC=<n per file, 0 all> +N
`timescale 1ns / 1ps
module tb_gemv_scale;
  import tb_util_pkg::*;
  import kdpi_pkg::*;
  import llm_pkg::*;

  parameter int ACC_W = 25;
  parameter int PIPE  = 3;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic                    valid_i = 1'b0, valid_o;
  logic signed [ACC_W-1:0] acc_i = '0;
  logic [WM_W-1:0]         wm_i = '0;
  logic [AM_W-1:0]         xm_i = '0;
  logic signed [SH_W-1:0]  sh_i = '0;
  logic signed [31:0]      y_o;

  gemv_scale #(.ACC_W(ACC_W), .PIPE(PIPE)) dut (
    .clk(clk), .rst_n(rst_n), .valid_i(valid_i), .acc_i(acc_i), .wm_i(wm_i), .xm_i(xm_i),
    .sh_i(sh_i), .valid_o(valid_o), .y_o(y_o));

  tb_checker c_rec = new("records"), c_trace = new("trace"), c_rnd = new("random"),
             c_lat = new("latency");

  typedef struct { int e; longint at; bit rnd; longint acc; int wm, xm, sh; } item_t;
  item_t q[$];
  longint nidx = 0;

  always @(negedge clk) begin
    nidx++;
    if (rst_n && valid_o === 1'b1) begin
      if (q.size() == 0) c_lat.fail($sformatf("valid_o without input at negedge %0d", nidx));
      else begin
        automatic item_t it = q.pop_front();
        automatic tb_checker c = it.rnd ? c_rnd : c_rec;
        if (it.at != nidx) c_lat.fail($sformatf("out at %0d exp %0d", nidx, it.at));
        else c_lat.pass();
        if (y_o !== it.e)
          c.fail($sformatf("acc %0d wm %0d xm %0d sh %0d got %0d exp %0d", it.acc, it.wm, it.xm, it.sh, y_o, it.e));
        else c.pass();
      end
    end else if (rst_n && valid_o !== 1'b0) c_lat.fail($sformatf("valid_o = %b", valid_o));
    else if (rst_n && q.size() > 0 && q[0].at < nidx) c_lat.fail($sformatf("missing output due at %0d", q[0].at));
  end

  task automatic put(longint acc, int wm, int xm, int sh, int e, bit rnd);
    item_t it;
    while ($urandom_range(3) == 0) begin
      @(posedge clk);
      valid_i <= 1'b0;
      acc_i   <= ACC_W'($urandom());
      wm_i    <= WM_W'($urandom());
    end
    @(posedge clk);
    valid_i <= 1'b1;
    acc_i   <= ACC_W'(acc);
    wm_i    <= WM_W'(wm);
    xm_i    <= AM_W'(xm);
    sh_i    <= SH_W'(sh);
    it.e = e; it.rnd = rnd; it.acc = acc; it.wm = wm; it.xm = xm; it.sh = sh;
    it.at = nidx + 1 + PIPE;
    q.push_back(it);
  endtask

  localparam longint AMAX = (64'sd1 <<< (ACC_W - 1)) - 1;
  localparam longint AMIN = -(64'sd1 <<< (ACC_W - 1));

  int nrec = 0, nrows = 0, maxrec = 0, n_rnd = 1000000;

  task automatic run_file(string dir);
    int k = 0;
    if (kd_rec_open({dir, "/gemv.bin"}) != 0) begin
      c_rec.fail({"cannot open ", dir, "/gemv.bin"});
      return;
    end
    while ((maxrec == 0 || k < maxrec) && kd_rec_next() == K_GEMV) begin
      int rows = kd_rec_prm(0), n = kd_rec_prm(1), gs = kd_rec_prm(2), xm = kd_rec_prm(4);
      int sh = kd_rec_prm(3) + kd_rec_prm(5) - kd_rec_prm(6);
      if (gs != n || xm < 0 || xm >= (1 << AM_W) || sh < -(1 << (SH_W - 1)) || sh >= (1 << (SH_W - 1))) begin
        c_rec.fail($sformatf("record %0d outside the gemv_scale ports (gs %0d n %0d xm %0d sh %0d)",
                             kd_rec_index(), gs, n, xm, sh));
        continue;
      end
      for (int r = 0; r < rows; r++) begin
        int acc = kd_rec_gemv_acc(r), wm = kd_rec_getu(1, r), y = kd_rec_get(3, r);
        longint s = kd_rec_gemv_s(r);
        if (kd_gemv_out(s, xm, sh) !== y || s !== longint'(acc) * wm)
          c_trace.fail($sformatf("rec %0d row %0d: gemv_out(S) %0d y %0d S %0d acc*wm %0d",
                                 kd_rec_index(), r, kd_gemv_out(s, xm, sh), y, s, longint'(acc) * wm));
        else c_trace.pass();
        if (acc > AMAX || acc < AMIN) c_rec.fail($sformatf("acc %0d outside ACC_W", acc));
        else put(acc, wm, xm, sh, y, 1'b0);
      end
      k++;
      nrec++;
      nrows += rows;
    end
    void'(kd_rec_close());
  endtask

  int unsigned seed;
  string vdir = "", vdir2 = "";

  initial begin
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("VEC=%s", vdir));
    void'($value$plusargs("VEC2=%s", vdir2));
    void'($value$plusargs("MAXREC=%d", maxrec));
    void'($value$plusargs("N=%d", n_rnd));
    $display("tb_gemv_scale: ACC_W=%0d PIPE=%0d LATENCY=%0d seed=%0d VEC=%s VEC2=%s MAXREC=%0d N=%0d",
             ACC_W, PIPE, dut.LATENCY, seed, vdir, vdir2, maxrec, n_rnd);
    if (dut.LATENCY != PIPE) c_lat.fail("LATENCY localparam != PIPE");
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);

    if (vdir != "") run_file(vdir);
    if (vdir2 != "") run_file(vdir2);
    $display("records: %0d K_GEMV records, %0d rows", nrec, nrows);

    // directed corners: extremes of every operand and shifts around the saturation edges
    begin
      automatic longint av[] = '{AMAX, AMIN, 0, 1, -1, AMAX - 1, AMIN + 1};
      automatic int wv[] = '{0, 1, 65535, 32768};
      automatic int xv[] = '{0, 1, (1 << AM_W) - 1, 65536};
      automatic int sv[] = '{-512, -70, -10, -1, 0, 1, 10, 20, 25, 26, 32, 40, 57, 58, 59, 61, 62, 63, 64, 511};
      foreach (av[a]) foreach (wv[w]) foreach (xv[x]) foreach (sv[s])
        put(av[a], wv[w], xv[x], sv[s], kd_gemv_out(av[a] * wv[w], xv[x], sv[s]), 1'b1);
    end

    for (int i = 0; i < n_rnd; i++) begin
      automatic int k = $urandom_range(9);
      automatic longint acc;
      automatic int wm = (k == 0) ? (($urandom_range(1)) ? 65535 : 0) : $urandom_range(65535);
      automatic int xm = (k == 1) ? (($urandom_range(1)) ? (1 << AM_W) - 1 : 0) : $urandom_range((1 << AM_W) - 1);
      automatic int sh = ($urandom_range(4) != 0) ? int'($urandom_range(140)) - 70 : int'($urandom_range(1023)) - 512;
      case ($urandom_range(5))
        0, 1, 2: acc = longint'(ACC_W'($urandom())) <<< (64 - ACC_W) >>> (64 - ACC_W);
        3:       acc = longint'(int'($urandom_range(2000))) - 1000;
        4:       acc = $urandom_range(1) ? AMAX - $urandom_range(3) : AMIN + $urandom_range(3);
        default: acc = longint'($signed(ACC_W'($urandom()))) >>> $urandom_range(ACC_W - 1);
      endcase
      put(acc, wm, xm, sh, kd_gemv_out(acc * wm, xm, sh), 1'b1);
    end

    @(posedge clk);
    valid_i <= 1'b0;
    repeat (PIPE + 3) @(posedge clk);
    if (q.size() != 0) c_lat.fail($sformatf("%0d outputs missing at the end", q.size()));
    if (vdir != "") void'(tb_final_report('{c_rec, c_trace, c_rnd, c_lat}));
    else            void'(tb_final_report('{c_rnd, c_lat}));
    $finish;
  end
endmodule
