// tb_attn_vacc: attn_vacc (pass P3) against the golden stage trace of k_attn2_st (DPI, through
// tb/common/attn_tb_pkg.sv): p[t] per position (exact LAT_P after its first beat), the aligned
// weight w[t] (stage 4, white-box), every accumulator acc[i] after the last beat (white-box),
// and o[i] read through o_rd_i in random order with random gaps (exact LAT_O).
// The head constants R, emin, G come from the golden trace (emin = G = 0 when no vs.m != 0, as
// the golden). Cases: attention records of +VEC (K12V8, HB, HD) and +SYN synthetic calls
// (gen_syn modes 0..5). V beats have random gaps (+GAP); e / vm / ve of non-first beats and
// lanes >= hs are random (must be ignored / never read).
// Plusargs: +SEED +VEC=<dir>[,<dir>...] +MAXREC +SYN +GAP.
`timescale 1ns / 1ps
module tb_attn_vacc;
  import tb_util_pkg::*;
  import kdpi_pkg::*;
  import attn_tb_pkg::*;
  import llm_pkg::*;

  parameter int VL     = 8;
  parameter int HS_MAX = 64;
  parameter int T_MAX  = 512;
  parameter int ACC_W  = 60;
  localparam int NG    = (HS_MAX + VL - 1) / VL;
  localparam int GB_W  = (NG > 1) ? $clog2(NG) : 1;
  localparam int HS_W  = $clog2(HS_MAX + 1);
  localparam int LAT_P = 2, LAT_MAC = 6, LAT_O = 2;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [32:0]           r_i = '0;
  logic signed [E_W-1:0] emin_i = '0, b_ve_i = '0;
  logic [4:0]            g_i = '0;
  logic                  clr_i = 1'b0, b_valid_i = 1'b0, b_first_i = 1'b0, p_valid_o, o_rd_i = 1'b0, o_valid_o;
  logic [GB_W-1:0]       b_g_i = '0;
  logic [VL*16-1:0]      b_v_i = '0;
  logic [16:0]           b_e_i = '0;
  logic [AM_W-1:0]       b_vm_i = '0;
  logic [31:0]           p_o;
  logic [HS_W-1:0]       o_idx_i = '0;
  logic signed [31:0]    o_o;

  attn_vacc #(.VL(VL), .HS_MAX(HS_MAX), .T_MAX(T_MAX), .ACC_W(ACC_W)) dut (.*);

  tb_checker c_p = new("p"), c_w = new("w"), c_acc = new("acc"), c_o = new("o"),
             c_lat = new("latency"), c_rec = new("record");

  typedef struct { longint v; longint at; int idx; } exp_t;
  exp_t qp[$], qw[$], qo[$];
  longint cyc = 0;
  att_case cur;
  int gap = 20;
  longint n_cases = 0, n_pos = 0;

  always @(posedge clk) cyc <= cyc + 1;

  // p, w (stage 4 of the first beat) and o checks
  always @(negedge clk) begin
    if (rst_n) begin
      if (p_valid_o === 1'b1) begin
        if (qp.size() == 0) c_lat.fail($sformatf("p_valid_o without position at %0d", cyc));
        else begin
          automatic exp_t x = qp.pop_front();
          if (x.at != cyc) c_lat.fail($sformatf("%s t %0d: p at %0d exp %0d", cur.desc(), x.idx, cyc, x.at));
          else c_lat.pass();
          if (longint'(p_o) !== x.v) c_p.fail($sformatf("%s t %0d: p %0d exp %0d", cur.desc(), x.idx, p_o, x.v));
          else c_p.pass();
        end
      end else if (qp.size() > 0 && qp[0].at < cyc) begin
        c_lat.fail($sformatf("%s t %0d: missing p", cur.desc(), qp[0].idx));
        void'(qp.pop_front());
      end
      if (dut.v4 === 1'b1 && dut.b4.first === 1'b1) begin
        if (qw.size() == 0) c_w.fail("w without position");
        else begin
          automatic exp_t x = qw.pop_front();
          if (longint'(dut.w4) !== x.v) c_w.fail($sformatf("%s t %0d: w %0d exp %0d", cur.desc(), x.idx, dut.w4, x.v));
          else c_w.pass();
        end
      end
      if (o_valid_o === 1'b1) begin
        if (qo.size() == 0) c_lat.fail($sformatf("o_valid_o without read at %0d", cyc));
        else begin
          automatic exp_t x = qo.pop_front();
          if (x.at != cyc) c_lat.fail($sformatf("%s o %0d at %0d exp %0d", cur.desc(), x.idx, cyc, x.at));
          else c_lat.pass();
          if (longint'(o_o) !== x.v) c_o.fail($sformatf("%s: o[%0d] %0d exp %0d", cur.desc(), x.idx, o_o, x.v));
          else c_o.pass();
        end
      end
    end
  end

  function automatic logic [VL*16-1:0] rnd_beat();
    logic [VL*16-1:0] v;
    for (int l = 0; l < VL; l++) v[l*16 +: 16] = $urandom();
    return v;
  endfunction

  task automatic run_case(att_case c);
    int nb = (c.hs + VL - 1) / VL;
    int idx[$];
    cur = c;
    n_cases++;
    @(posedge clk);
    clr_i  <= 1'b1;
    r_i    <= 33'(c.R);
    emin_i <= E_W'(c.emin);
    g_i    <= 5'(c.G);
    @(posedge clk);
    clr_i <= 1'b0;
    for (int t = 0; t < c.T; t++) begin
      for (int g = 0; g < nb; g++) begin
        logic [VL*16-1:0] v = rnd_beat();
        while ($urandom_range(99) < gap) begin
          b_valid_i <= 1'b0;
          b_first_i <= $urandom();
          b_v_i <= rnd_beat(); b_e_i <= $urandom(); b_vm_i <= $urandom(); b_ve_i <= $urandom();
          b_g_i <= $urandom();
          @(posedge clk);
        end
        for (int l = 0; l < VL; l++) if (g * VL + l < c.hs) v[l*16 +: 16] = 16'(c.V[t * c.hs + g * VL + l]);
        b_valid_i <= 1'b1;
        b_first_i <= g == 0;
        b_g_i     <= GB_W'(g);
        b_v_i     <= v;
        if (g == 0) begin
          automatic exp_t x;
          b_e_i  <= 17'(c.e[t]);
          b_vm_i <= AM_W'(c.vsm[t]);
          b_ve_i <= E_W'(c.vse[t]);
          x.v = c.p[t]; x.idx = t; x.at = cyc + 1 + LAT_P;
          qp.push_back(x);
          x.v = c.w[t];
          qw.push_back(x);
        end else begin
          b_e_i <= $urandom(); b_vm_i <= $urandom(); b_ve_i <= $urandom();
        end
        @(posedge clk);
      end
    end
    b_valid_i <= 1'b0;
    repeat (LAT_MAC + 1) @(posedge clk);
    for (int i = 0; i < c.hs; i++)
      if (longint'(dut.acc_q[i / VL][i % VL]) !== c.acc[i])
        c_acc.fail($sformatf("%s: acc[%0d] %0d exp %0d", c.desc(), i, dut.acc_q[i / VL][i % VL], c.acc[i]));
      else c_acc.pass();
    // o reads in random order
    for (int i = 0; i < c.hs; i++) idx.push_back(i);
    idx.shuffle();
    foreach (idx[k]) begin
      automatic exp_t x;
      while ($urandom_range(99) < gap) begin
        o_rd_i  <= 1'b0;
        o_idx_i <= $urandom();
        @(posedge clk);
      end
      o_rd_i  <= 1'b1;
      o_idx_i <= HS_W'(idx[k]);
      x.v = c.o[idx[k]]; x.idx = idx[k]; x.at = cyc + 1 + LAT_O;
      qo.push_back(x);
      @(posedge clk);
    end
    o_rd_i <= 1'b0;
    repeat (LAT_O + 2) @(posedge clk);
    n_pos += c.T;
  endtask

  initial begin
    automatic int unsigned seed;
    automatic int maxrec = 1 << 30, nsyn = 0, nrec_all = 0;
    automatic string vec = "";
    automatic string dirs[$];
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("MAXREC=%d", maxrec));
    void'($value$plusargs("SYN=%d", nsyn));
    void'($value$plusargs("GAP=%d", gap));
    void'($value$plusargs("VEC=%s", vec));
    $display("tb_attn_vacc: VL %0d HS_MAX %0d T_MAX %0d ACC_W %0d seed %0d", VL, HS_MAX, T_MAX, ACC_W, seed);
    while (vec != "") begin
      automatic int k = 0;
      while (k < vec.len() && vec[k] != ",") k++;
      dirs.push_back(vec.substr(0, k - 1));
      vec = (k < vec.len()) ? vec.substr(k + 1, vec.len() - 1) : "";
    end
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    foreach (dirs[d]) begin
      automatic int nrec = 0;
      if (kd_rec_open({dirs[d], "/attn2.bin"}) != 0 && kd_rec_open({dirs[d], "/attn.bin"}) != 0)
        $fatal(1, "tb_attn_vacc: no attention record file in %s", dirs[d]);
      while (nrec < maxrec && kd_rec_next() > 0) begin
        automatic att_case c = new();
        automatic int rc = c.load_rec();
        if (rc != 0) begin
          c_rec.fail($sformatf("%s record %0d: load %0d", dirs[d], kd_rec_index(), rc));
          continue;
        end
        c_rec.pass();
        if (c.hs > HS_MAX || c.T > T_MAX) continue;
        run_case(c);
        nrec++;
      end
      void'(kd_rec_close());
      $display("tb_attn_vacc: %s: %0d records", dirs[d], nrec);
      nrec_all += nrec;
    end
    for (int i = 0; i < nsyn; i++) begin
      automatic att_case c = new();
      c.gen_syn(i % 6, T_MAX < 64 ? T_MAX : 64, HS_MAX);
      run_case(c);
    end
    repeat (4) @(posedge clk);
    $display("tb_attn_vacc: %0d cases (%0d records), %0d positions", n_cases, nrec_all, n_pos);
    begin
      automatic tb_checker_q l = '{c_p, c_w, c_acc, c_o, c_lat};
      if (dirs.size() > 0) l.push_back(c_rec);
      void'(tb_final_report(l));
    end
    $finish;
  end

endmodule
