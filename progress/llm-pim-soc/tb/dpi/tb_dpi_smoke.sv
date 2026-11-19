// tb_dpi_smoke: Questa DPI-C smoke test of the golden wrapper tb/dpi/kdpi.c.
//
// Reads the per-kernel record files of model/build/vec/<m1|m2>/ (vt job split, make vec)
// through DPI and checks that what the DPI functions return equals the records:
//   replay   every record replayed through k_exec (DPI) reproduces its recorded outputs
//   gemv     K_GEMV row y == kd_gemv_out(kd_rec_gemv_s(r), xm, we + xe - fo)   (A2)
//   dot8     kd_rec_gemv_acc(r) == kd_dot8(row bytes, x bytes) and S == acc * wm (A1)
//   rrec     row record beats: header = wm, weight bytes = W, padding 0      (arch.md 2.2)
//   bimg     bank image of the first K_GEMV record (NB 4 x LB 16): tag and lanes per row
//            (arch.md 3.1, D6), and equal to the vt bimg hex file (+PIM_DIR)
//   rfile    row records of the first K_GEMV record == the vt rrec.bin file loaded into the
//            AXI memory model with load_bin, and == the same beats written via the backdoor
//            from DPI (the DPI route of loading the memory model)
//   scalar   kd_rshr, kd_sat32, kd_gemv_out, kd_rsqrt, kd_exp2neg, kd_sigmoid on fixed
//            inputs == the values printed by the native C build of model/src (same functions)
// Plusargs: +VEC=<dir> (default ../../model/build/vec/m1), +MAXREC=<n> records per kernel
// file (0: all), +PIM_DIR=<dir> (bank image hex files; only for 260K), +RFILE (rrec.bin check).
`timescale 1ns / 1ps
module tb_dpi_smoke;
  import tb_util_pkg::*;
  import kdpi_pkg::*;

  tb_checker c_replay = new("replay"), c_gemv = new("gemv"), c_dot = new("dot8"),
             c_rrec = new("rrec"), c_bimg = new("bimg"), c_rfile = new("rfile"),
             c_scalar = new("scalar");

  // memory model with idle AXI inputs (backdoor and file loading only)
  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;
  logic [5:0] mid;
  logic [63:0] mrd;
  logic [1:0] mresp, mbresp;
  logic mrl, mrv, mbv, mar, maw, mw;
  axi_mem_slave #(.NAME("dpi")) u_mem (
    .clk(clk), .rst_n(rst_n),
    .awid_i('0), .awaddr_i('0), .awlen_i('0), .awsize_i(3'd3), .awburst_i(2'b01), .awvalid_i(1'b0),
    .awready_o(maw), .wdata_i('0), .wstrb_i('0), .wlast_i(1'b0), .wvalid_i(1'b0), .wready_o(mw),
    .bid_o(), .bresp_o(mbresp), .bvalid_o(mbv), .bready_i(1'b0),
    .arid_i('0), .araddr_i('0), .arlen_i('0), .arsize_i(3'd3), .arburst_i(2'b01), .arvalid_i(1'b0),
    .arready_o(mar), .rid_o(mid), .rdata_o(mrd), .rresp_o(mresp), .rlast_o(mrl), .rvalid_o(mrv),
    .rready_i(1'b0));

  string vdir = "../../model/build/vec/m1", pim_dir = "";
  int maxrec = 0;
  bit rfile = 1'b0, first_gemv = 1'b1;

  task automatic chk_scalar(string what, longint got, longint exp);
    if (got !== exp) c_scalar.fail($sformatf("%s got %0d exp %0d", what, got, exp));
    else c_scalar.pass();
  endtask

  task automatic scalar_tests();
    int re, r;
    chk_scalar("rshr(5,1)", kd_rshr(5, 1), 3);
    chk_scalar("rshr(-5,1)", kd_rshr(-5, 1), -2);
    chk_scalar("rshr(7,0)", kd_rshr(7, 0), 7);
    chk_scalar("rshr(3,-2)", kd_rshr(3, -2), 12);
    chk_scalar("rshr(2^62,-2)", kd_rshr(64'sh4000_0000_0000_0000, -2), 64'sh7FFF_FFFF_FFFF_FFFF);
    chk_scalar("rshr(-2^62,-2)", kd_rshr(-64'sh4000_0000_0000_0000, -2), -64'sh7FFF_FFFF_FFFF_FFFF);
    chk_scalar("rshr(-1,70)", kd_rshr(-1, 70), 0);
    chk_scalar("rshr(123456789012,13)", kd_rshr(64'sd123456789012, 13), 15070409);
    chk_scalar("rshr(-123456789012,13)", kd_rshr(-64'sd123456789012, 13), -15070409);
    chk_scalar("sat32(2^31)", kd_sat32(64'sd2147483648), 2147483647);
    chk_scalar("sat32(-2^31-5)", kd_sat32(-64'sd2147483653), -64'sd2147483648);
    chk_scalar("gemv_out", kd_gemv_out(-64'sd5646622266, 65669, 32), -86335);
    r = kd_rsqrt(4, re);
    chk_scalar("rsqrt(4).rm", r, 65535);
    chk_scalar("rsqrt(4).re", re, 17);
    r = kd_rsqrt(64'sd17083805843, re);
    chk_scalar("rsqrt(big).rm", r, 32859);
    chk_scalar("rsqrt(big).re", re, 32);
    chk_scalar("exp2neg(0)", kd_exp2neg(0, 8), 65536);
    chk_scalar("exp2neg(1.0)", kd_exp2neg(65536, 8), 32768);
    chk_scalar("exp2neg(100000)", kd_exp2neg(100000, 8), 22759);
    chk_scalar("exp2neg(40.0)", kd_exp2neg(40 << 16, 8), 0);
    chk_scalar("sigmoid(0)", kd_sigmoid(0, 8), 32768);
    chk_scalar("sigmoid(-70000)", kd_sigmoid(-70000, 8), 16763);
    chk_scalar("sigmoid(2000000)", kd_sigmoid(2000000, 8), 65536);
  endtask

  // K_GEMV record: prm rows n gs we xm xe fo; b W:i8 m:u16 x:i8 | y:i32
  task automatic gemv_checks();
    int rows = kd_rec_prm(0), n = kd_rec_prm(1), gs = kd_rec_prm(2);
    int sh = kd_rec_prm(3) + kd_rec_prm(5) - kd_rec_prm(6), xm = kd_rec_prm(4);
    int nbeat = kd_rec_rrec_nbeat(), nw = (n + 15) / 16;
    byte xb[], wb[];
    if (gs != n) begin
      c_gemv.fail($sformatf("record %0d has gs %0d != n %0d (K12V8 is row-wise)", kd_rec_index(), gs, n));
      return;
    end
    xb = new[n];
    wb = new[n];
    foreach (xb[i]) xb[i] = byte'(kd_rec_get(2, i));
    for (int r = 0; r < rows; r++) begin
      longint s = kd_rec_gemv_s(r);
      int acc = kd_rec_gemv_acc(r), wm = kd_rec_getu(1, r), y = kd_rec_get(3, r), d;
      if (kd_gemv_out(s, xm, sh) !== y)
        c_gemv.fail($sformatf("rec %0d row %0d y %0d gemv_out %0d", kd_rec_index(), r, y, kd_gemv_out(s, xm, sh)));
      else c_gemv.pass();
      foreach (wb[i]) wb[i] = byte'(kd_rec_get(0, r * n + i));
      d = kd_dot8(wb, xb, n);
      if (d !== acc || s !== longint'(acc) * wm)
        c_dot.fail($sformatf("rec %0d row %0d acc %0d dot8 %0d S %0d acc*wm %0d", kd_rec_index(), r, acc, d, s, longint'(acc) * wm));
      else c_dot.pass();
      for (int j = 0; j < nbeat; j++) begin
        logic [63:0] bt = kd_rec_rrec_beat(r, j), e;
        if (j == 0) e = {48'h0, wm[15:0]};
        else for (int k = 0; k < 8; k++) begin
          int col = (j - 1) * 8 + k;
          e[8*k +: 8] = col < n ? wb[col] : 8'h00;
        end
        if (bt !== e) c_rrec.fail($sformatf("rec %0d row %0d beat %0d got %h exp %h", kd_rec_index(), r, j, bt, e));
        else c_rrec.pass();
      end
    end
    if (first_gemv) begin
      first_gemv = 1'b0;
      bimg_checks(rows, n, nw);
      if (rfile) rfile_checks(rows, n, nbeat);
    end
  endtask

  // bank image of the current record at base 0, NB 4 x LB 16
  task automatic bimg_checks(int rows, int n, int nw);
    int words = kd_rec_bimg(4), fd[4];
    if (words != ((rows + 3) / 4) * nw) begin
      c_bimg.fail($sformatf("words per bank %0d exp %0d", words, ((rows + 3) / 4) * nw));
      return;
    end
    for (int r = 0; r < rows; r++)
      for (int w = 0; w < nw; w++) begin
        int k = r % 4, a = (r / 4) * nw + w;
        logic [127:0] lanes = {kd_bimg_hi(k, a), kd_bimg_lo(k, a)}, e;
        int tag = kd_bimg_tag(k, a);
        for (int l = 0; l < 16; l++) begin
          int col = w * 16 + l;
          e[8*l +: 8] = col < n ? 8'(kd_rec_get(0, r * n + col)) : 8'h00;
        end
        if (lanes !== e || tag != (w == 0 ? kd_rec_getu(1, r) : 0))
          c_bimg.fail($sformatf("row %0d word %0d bank %0d addr %0d lanes %h exp %h tag %0d", r, w, k, a, lanes, e, tag));
        else c_bimg.pass();
      end
    if (pim_dir != "") begin  // vt bimg file: first matrix (wq0) at base 0
      for (int k = 0; k < 4; k++) begin
        fd[k] = $fopen($sformatf("%s/bank%0d.hex", pim_dir, k), "r");
        if (fd[k] == 0) begin
          c_bimg.fail($sformatf("cannot open bank%0d.hex in %s", k, pim_dir));
          return;
        end
        for (int a = 0; a < words; a++) begin
          logic [143:0] fw;
          void'($fscanf(fd[k], "%h\n", fw));
          if (fw !== {16'(kd_bimg_tag(k, a)), kd_bimg_hi(k, a), kd_bimg_lo(k, a)})
            c_bimg.fail($sformatf("bank%0d.hex word %0d %h differs from DPI", k, a, fw));
          else c_bimg.pass();
        end
        $fclose(fd[k]);
      end
    end
  endtask

  // vt rrec.bin (matrices in order, wq0 first) loaded with load_bin vs DPI beats, and the
  // DPI beats written through the backdoor
  task automatic rfile_checks(int rows, int n, int nbeat);
    longint nb = u_mem.load_bin({vdir, "/rrec.bin"}, 64'h0);
    longint unsigned dbase = 64'h1000_0000;
    if (nb < longint'(rows) * nbeat * 8) begin
      c_rfile.fail($sformatf("rrec.bin has %0d bytes, need %0d", nb, rows * nbeat * 8));
      return;
    end
    for (int r = 0; r < rows; r++)
      for (int j = 0; j < nbeat; j++)
        u_mem.bd_write64(dbase + 8 * (r * nbeat + j), kd_rec_rrec_beat(r, j));
    for (int r = 0; r < rows; r++)
      for (int j = 0; j < nbeat; j++) begin
        logic [63:0] f = u_mem.bd_read64(8 * (r * nbeat + j)), d = u_mem.bd_read64(dbase + 8 * (r * nbeat + j));
        if (f !== kd_rec_rrec_beat(r, j) || d !== f)
          c_rfile.fail($sformatf("row %0d beat %0d file %h dpi %h", r, j, f, d));
        else c_rfile.pass();
      end
  endtask

  initial begin
    static string kn[9] = '{"embed", "gemv", "rmsnorm", "actq", "rope", "attn2", "swiglu", "add", "argmax"};
    static int total = 0;
    void'($value$plusargs("VEC=%s", vdir));
    void'($value$plusargs("MAXREC=%d", maxrec));
    void'($value$plusargs("PIM_DIR=%s", pim_dir));
    rfile = $test$plusargs("RFILE");
    $display("tb_dpi_smoke: VEC %s MAXREC %0d PIM_DIR %s RFILE %0d", vdir, maxrec, pim_dir, rfile);
    repeat (2) @(posedge clk);
    rst_n <= 1'b1;
    @(posedge clk);
    scalar_tests();
    foreach (kn[f]) begin
      int nrec, kid;
      nrec = 0;
      kid = 0;
      if (kd_rec_open({vdir, "/", kn[f], ".bin"}) != 0) begin
        c_replay.fail($sformatf("no record file %s/%s.bin (run make vec in model/)", vdir, kn[f]));
        continue;
      end
      while ((maxrec == 0 || nrec < maxrec) && (kid = kd_rec_next()) > 0) begin
        int rp;
        rp = kd_rec_replay();
        if (rp != 0) c_replay.fail($sformatf("%s record %0d replay differs in %0d elements", kn[f], nrec, rp));
        else c_replay.pass();
        if (kid == K_GEMV) gemv_checks();
        nrec++;
      end
      if (kid < 0) c_replay.fail($sformatf("%s: record format error after %0d records", kn[f], nrec));
      void'(kd_rec_close());
      $display("tb_dpi_smoke: %s records %0d", kn[f], nrec);
      total += nrec;
    end
    $display("tb_dpi_smoke: records %0d", total);
    begin
      tb_checker_q q;
      q = '{c_replay, c_gemv, c_dot, c_rrec, c_bimg, c_scalar};
      if (rfile) q.push_back(c_rfile);
      void'(tb_final_report(q));
    end
    $finish;
  end
endmodule
