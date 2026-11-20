// tb_exp_unit: exp_unit against the golden k_attn_exp(s, mx, 8, k_exp_lut(8)) (DPI kd_attn_exp).
// Vectors:
//   records: every (s[t], mx) pair of the stage traces of the attention records in +VEC
//            (k_attn2_st through kd_att_from_rec / kd_att_run; the trace e[t] must also equal
//            kd_attn_exp, which ties the stage function to the record)
//   directed: d = s - mx = 0, -1, -2, around the exponent steps (multiples of 2^16 / 47274),
//            at and beyond the clamp -2^30 (+-1, +-2), extreme 32-bit pairs, s > mx, and the
//            window d ~ -2.97706e9 where an unclamped -w would wrap past 2^32 into I < 32
//   random : +N pairs (mix of uniform 32-bit pairs, small negative d, d near the clamp, s > mx)
// valid_i has random gaps; output checked at negedge with the exact LATENCY.
// Plusargs: +SEED=<n> +N=<n> +VEC=<dir> (records of <dir>/attn2.bin or attn.bin) +MAXREC=<n>.
`timescale 1ns / 1ps
module tb_exp_unit;
  import tb_util_pkg::*;
  import kdpi_pkg::*;

  parameter int RS_PIPE  = 1;
  parameter int LUT_PIPE = 2;
  localparam int LAT = 1 + RS_PIPE + LUT_PIPE;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic               valid_i = 1'b0, valid_o;
  logic signed [31:0] s_i = '0, mx_i = '0;
  logic [16:0]        e_o;

  exp_unit #(.RS_PIPE(RS_PIPE), .LUT_PIPE(LUT_PIPE)) dut (
    .clk, .rst_n, .valid_i, .s_i, .mx_i, .valid_o, .e_o);

  tb_checker c_rec = new("records"), c_dir = new("directed"), c_rnd = new("random"),
             c_lat = new("latency"), c_tr = new("trace_e");

  typedef struct { int s, mx, e; longint at; int kind; } item_t;
  item_t q[$];
  longint nidx = 0;

  task automatic put(int s, int mx, int kind);
    item_t it;
    while ($urandom_range(9) == 0) begin
      @(posedge clk);
      valid_i <= 1'b0;
      s_i     <= $urandom();
      mx_i    <= $urandom();
    end
    @(posedge clk);
    valid_i <= 1'b1;
    s_i     <= s;
    mx_i    <= mx;
    it.s = s; it.mx = mx; it.e = kd_attn_exp(s, mx); it.kind = kind; it.at = nidx + 1 + LAT;
    q.push_back(it);
  endtask

  always @(negedge clk) begin
    nidx++;
    if (rst_n && valid_o === 1'b1) begin
      if (q.size() == 0) c_lat.fail($sformatf("valid_o without input at %0d", nidx));
      else begin
        automatic item_t it = q.pop_front();
        automatic tb_checker c = it.kind == 0 ? c_rec : (it.kind == 1 ? c_dir : c_rnd);
        if (it.at != nidx) c_lat.fail($sformatf("s %0d mx %0d out at %0d exp %0d", it.s, it.mx, nidx, it.at));
        else c_lat.pass();
        if (int'(e_o) !== it.e) c.fail($sformatf("s %0d mx %0d got %0d exp %0d", it.s, it.mx, e_o, it.e));
        else c.pass();
      end
    end else if (rst_n && valid_o !== 1'b0) c_lat.fail($sformatf("valid_o = %b", valid_o));
    else if (rst_n && q.size() > 0 && q[0].at < nidx)
      c_lat.fail($sformatf("missing output for s %0d mx %0d", q[0].s, q[0].mx));
  end

  initial begin
    automatic int unsigned seed;
    automatic int n = 100000, maxrec = 1 << 30, nrec = 0;
    automatic string vec = "";
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("N=%d", n));
    void'($value$plusargs("MAXREC=%d", maxrec));
    void'($value$plusargs("VEC=%s", vec));
    $display("tb_exp_unit: LAT %0d seed %0d N %0d VEC %s", LAT, seed, n, vec);
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;

    // ---- records ----
    if (vec != "") begin
      automatic string f = {vec, "/attn2.bin"};
      if (kd_rec_open(f) != 0) begin
        f = {vec, "/attn.bin"};
        if (kd_rec_open(f) != 0) $fatal(1, "tb_exp_unit: no attention record file in %s", vec);
      end
      while (nrec < maxrec && kd_rec_next() > 0) begin
        automatic int rc = kd_att_from_rec(), T;
        if (rc != 0) begin
          c_tr.fail($sformatf("record %0d: kd_att_from_rec %0d", kd_rec_index(), rc));
          continue;
        end
        void'(kd_att_run());
        T = int'(kd_att_get(AG_T, 0));
        for (int t = 0; t < T; t++) begin
          automatic int s = int'(kd_att_get(AG_S, t)), mx = int'(kd_att_get(AG_MX, 0));
          if (int'(kd_att_get(AG_E, t)) !== kd_attn_exp(s, mx))
            c_tr.fail($sformatf("record %0d t %0d trace e %0d != kd_attn_exp", kd_rec_index(), t,
                                kd_att_get(AG_E, t)));
          else c_tr.pass();
          put(s, mx, 0);
        end
        nrec++;
      end
      void'(kd_rec_close());
      $display("tb_exp_unit: %0d records", nrec);
    end else c_tr.pass();

    // ---- directed ----
    begin
      automatic int ds[$] = '{0, -1, -2, -3, -1386, -1387, -1388, -22713, -22714, -22715, -45426,
                    -(1 << 20), -(1 << 24), -(1 << 30) + 2, -(1 << 30) + 1, -(1 << 30),
                    -(1 << 30) - 1, -(1 << 30) - 2, -(1 << 31) + 1};
      automatic int mxs[$] = '{0, 1, -1, 32'h7FFF_FFFF, 32'h8000_0000 + 32'h4000_0000, 65536, -65536};
      foreach (ds[i]) foreach (mxs[j]) begin
        automatic longint s = longint'(mxs[j]) + longint'(ds[i]);
        if (s >= -(64'sd1 <<< 31) && s < (64'sd1 <<< 31)) put(int'(s), mxs[j], 1);
      end
      for (int k = 0; k < 600; k++) begin
        // every 32nd step of the exponent near k * 2^16 / 47274 (around integer I boundaries)
        automatic int d = -int'((longint'(k) * 65536 * 32768 + 23637) / 47274) - 1 + $urandom_range(2);
        put(d, 0, 1);
      end
      // -w just above 2^32: (uint32) -w wraps into [0, 2^21) unless d is clamped at -2^30
      // (d = s - mx in [-2977061000, -2977058500], mx = 2^31 - 1; the wrap starts at -2977059025)
      for (longint dd = 2977058500; dd <= 2977061000; dd++) put(int'(64'sd2147483647 - dd), 32'h7FFF_FFFF, 1);
      put(32'h8000_0000, 32'h7FFF_FFFF, 1);
      put(32'h7FFF_FFFF, 32'h8000_0000, 1);  // s > mx (d = 2^32 - 1)
      put(5, 0, 1);
      put(1, 0, 1);
    end

    // ---- random ----
    for (int i = 0; i < n; i++) begin
      automatic int k = $urandom_range(99);
      automatic int mx = $urandom(), s;
      if (k < 30) s = $urandom();
      else if (k < 70) s = int'(longint'(mx) - longint'($urandom_range(1 << $urandom_range(30))));
      else if (k < 90) s = int'(longint'(mx) - (64'sd1 <<< 30) + longint'($urandom_range(8)) - 4);
      else s = int'(longint'(mx) + longint'($urandom_range(1 << $urandom_range(30))));
      put(s, mx, 2);
    end
    @(posedge clk);
    valid_i <= 1'b0;
    repeat (LAT + 3) @(posedge clk);
    begin
      automatic tb_checker_q l = '{c_dir, c_lat, c_tr};
      if (vec != "") l.push_back(c_rec);
      if (n > 0) l.push_back(c_rnd);
      void'(tb_final_report(l));
    end
    $finish;
  end

endmodule
