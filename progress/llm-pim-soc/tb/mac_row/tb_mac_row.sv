// tb_mac_row: mac_row (AW = BW = 8) against the golden row sums.
//
//   records : every row of the K_GEMV records of +VEC/gemv.bin (make vec in model/):
//             a = weight row W[r], b = x, expected kd_rec_gemv_acc(r) = k_dot8 of the row
//             (stage A1; the value k_gemv_row multiplies by wm). +MAXREC=<n> limits the
//             number of records (0: all).
//   directed: n = N_MAX all 127 x 127, all -128 x 127, n = N_MAX - 1 all -128 x -128 (the
//             largest sums that fit ACC_W), n = 1, LANES - 1, LANES, LANES + 1
//   random  : +NRND rows (default 20000), n in 1..N_MAX (classes: short, full length,
//             uniform), bytes uniform / extremes / small; expected kd_dot8(a, b, n)
//   +OVF    : one more row n = N_MAX all -128 x -128 (sum 2^24 = ACC_W 25 overflow). The
//             row is not compared; the run expects exactly one L1_RANGE message.
// Beats carry LANES elements (row tail padded with zeros); valid_i has random gaps inside
// and between rows. Inputs change at posedge, acc_o is checked at negedge exactly
// LATENCY cycles after the last beat.
// Plusargs: +SEED +VEC=<dir> +MAXREC +NRND +OVF
`timescale 1ns / 1ps
module tb_mac_row;
  import tb_util_pkg::*;
  import kdpi_pkg::*;

  parameter int LANES    = 8;
  parameter int ACC_W    = 25;
  parameter int N_MAX    = 1024;
  parameter int DOT_PIPE = 2;
  localparam int LAT = DOT_PIPE + 1;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic                    valid_i = 1'b0, first_i = 1'b0, last_i = 1'b0, acc_valid_o;
  logic [LANES*8-1:0]      a_i = '0, b_i = '0;
  logic signed [ACC_W-1:0] acc_o;

  mac_row #(.LANES(LANES), .AW(8), .BW(8), .ACC_W(ACC_W), .N_MAX(N_MAX), .DOT_PIPE(DOT_PIPE)) dut (
    .clk(clk), .rst_n(rst_n), .valid_i(valid_i), .first_i(first_i), .last_i(last_i),
    .a_i(a_i), .b_i(b_i), .acc_o(acc_o), .acc_valid_o(acc_valid_o));

  tb_checker c_rec = new("records"), c_dir = new("directed"), c_rnd = new("random"),
             c_lat = new("latency");

  typedef struct { longint e; longint at; int cls; bit skip; int n; } item_t;
  item_t q[$];
  longint nidx = 0;
  int n_skip = 0;

  always @(negedge clk) begin
    nidx++;
    if (rst_n && acc_valid_o === 1'b1) begin
      if (q.size() == 0) c_lat.fail($sformatf("acc_valid_o without row at negedge %0d", nidx));
      else begin
        automatic item_t it = q.pop_front();
        automatic tb_checker c = (it.cls == 0) ? c_rec : (it.cls == 1 ? c_dir : c_rnd);
        if (it.at != nidx) c_lat.fail($sformatf("row n %0d out at %0d exp %0d", it.n, nidx, it.at));
        else c_lat.pass();
        if (it.skip) n_skip++;
        else if (longint'(acc_o) !== it.e)
          c.fail($sformatf("row n %0d got %0d exp %0d", it.n, acc_o, it.e));
        else c.pass();
      end
    end else if (rst_n && acc_valid_o !== 1'b0) c_lat.fail($sformatf("acc_valid_o = %b", acc_valid_o));
    else if (rst_n && q.size() > 0 && q[0].at < nidx) c_lat.fail($sformatf("missing row due at %0d", q[0].at));
  end

  task automatic gap();
    while ($urandom_range(4) == 0) begin
      @(posedge clk);
      valid_i <= 1'b0;
      first_i <= $urandom();
      last_i  <= $urandom();
      a_i     <= {LANES{$urandom()}};
      b_i     <= {LANES{$urandom()}};
    end
  endtask

  task automatic send_row(byte a[], byte b[], int n, longint e, int cls, bit skip);
    int nb = (n + LANES - 1) / LANES;
    item_t it;
    for (int j = 0; j < nb; j++) begin
      logic [LANES*8-1:0] av = '0, bv = '0;
      for (int l = 0; l < LANES; l++)
        if (j * LANES + l < n) begin
          av[l*8 +: 8] = a[j * LANES + l];
          bv[l*8 +: 8] = b[j * LANES + l];
        end
      gap();
      @(posedge clk);
      valid_i <= 1'b1;
      first_i <= (j == 0);
      last_i  <= (j == nb - 1);
      a_i     <= av;
      b_i     <= bv;
    end
    it.e = e; it.cls = cls; it.skip = skip; it.n = n;
    it.at = nidx + 1 + LAT;
    q.push_back(it);
  endtask

  function automatic byte rbyte(int cls);
    case (cls)
      0: return byte'($urandom());
      1: return ($urandom_range(1)) ? 8'sd127 : -8'sd127;
      2: return byte'(int'($urandom_range(6)) - 3);
      default: return byte'($urandom());
    endcase
  endfunction

  int n_rnd = 20000, maxrec = 0, ovf = 0, nrec = 0, nrows = 0;
  string vdir = "";
  int unsigned seed;

  task automatic dir_row(int n, byte va, byte vb);
    byte a[] = new[n], b[] = new[n];
    foreach (a[i]) begin a[i] = va; b[i] = vb; end
    send_row(a, b, n, longint'(kd_dot8(a, b, n)), 1, 1'b0);
  endtask

  initial begin
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("VEC=%s", vdir));
    void'($value$plusargs("MAXREC=%d", maxrec));
    void'($value$plusargs("NRND=%d", n_rnd));
    void'($value$plusargs("OVF=%d", ovf));
    $display("tb_mac_row: LANES=%0d ACC_W=%0d N_MAX=%0d DOT_PIPE=%0d LATENCY=%0d seed=%0d VEC=%s MAXREC=%0d NRND=%0d OVF=%0d",
             LANES, ACC_W, N_MAX, DOT_PIPE, dut.LATENCY, seed, vdir, maxrec, n_rnd, ovf);
    if (dut.LATENCY != LAT) c_lat.fail("LATENCY localparam != DOT_PIPE + 1");
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);

    // ---- directed ----
    dir_row(N_MAX, 127, 127);
    dir_row(N_MAX, -128, 127);
    dir_row(N_MAX, 127, -128);
    dir_row(N_MAX - 1, -128, -128);
    dir_row(1, -128, -128);
    dir_row(LANES - 1, -128, 127);
    dir_row(LANES, 127, 127);
    dir_row(LANES + 1, -128, -128);

    // ---- records ----
    if (vdir != "") begin
      if (kd_rec_open({vdir, "/gemv.bin"}) != 0) c_rec.fail({"cannot open ", vdir, "/gemv.bin"});
      else
        while ((maxrec == 0 || nrec < maxrec) && kd_rec_next() == K_GEMV) begin
          automatic int rows = kd_rec_prm(0), n = kd_rec_prm(1);
          automatic byte xb[] = new[n], wb[] = new[n];
          void'(kd_rec_bytes(2, 0, xb, n));
          for (int r = 0; r < rows; r++) begin
            void'(kd_rec_bytes(0, r * n, wb, n));
            send_row(wb, xb, n, longint'(kd_rec_gemv_acc(r)), 0, 1'b0);
          end
          nrec++;
          nrows += rows;
        end
      void'(kd_rec_close());
      $display("records: %0d K_GEMV records, %0d rows", nrec, nrows);
      if (nrec == 0) c_rec.fail("no K_GEMV record read");
    end

    // ---- random ----
    for (int i = 0; i < n_rnd; i++) begin
      automatic int k = $urandom_range(9);
      automatic int n = (k < 4) ? $urandom_range(2 * LANES, 1) : (k < 6 ? N_MAX - $urandom_range(LANES) : $urandom_range(N_MAX, 1));
      automatic int ca = $urandom_range(2), cb = $urandom_range(2);
      automatic byte a[] = new[n], b[] = new[n];
      foreach (a[j]) begin a[j] = rbyte(ca); b[j] = rbyte(cb); end
      send_row(a, b, n, longint'(kd_dot8(a, b, n)), 2, 1'b0);
    end

    // ---- overflow (negative) ----
    if (ovf != 0) begin
      automatic byte a[] = new[N_MAX];
      foreach (a[i]) a[i] = -128;
      send_row(a, a, N_MAX, 0, 1, 1'b1);
    end

    @(posedge clk);
    valid_i <= 1'b0;
    repeat (LAT + 3) @(posedge clk);
    if (q.size() != 0) c_lat.fail($sformatf("%0d rows missing at the end", q.size()));
    if (n_skip != (ovf != 0)) c_lat.fail("overflow row not seen");
    if (vdir != "") void'(tb_final_report('{c_rec, c_dir, c_rnd, c_lat}));
    else            void'(tb_final_report('{c_dir, c_rnd, c_lat}));
    $finish;
  end
endmodule
