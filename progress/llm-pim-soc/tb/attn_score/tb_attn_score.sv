// tb_attn_score: attn_score (pass P1) against the golden stage trace of k_attn2_st (DPI, through
// tb/common/attn_tb_pkg.sv): per position s[t] (and the vm / ve passed with it), at the end mx,
// and if some vs.m != 0: emin, mmax, have (have = 0 otherwise).
// Cases: every attention record of the +VEC directories (K_ATTN2 K12V8 and K_ATTN HB / HD), and
// +SYN synthetic calls (gen_syn modes 0..5, hs 1..HS_MAX including non-multiples of KL).
// Stimulus per case: clr_i, q groups (lanes >= hs are random), then T x ceil(hs/KL) K beats
// with random gaps (+GAP percent); lanes >= hs of the last beat and the scale inputs of every
// beat but the last of a position carry random values (must be ignored).
// Timing: s of position t must appear exactly LATENCY cycles after its last beat.
// Plusargs: +SEED +VEC=<dir>[,<dir>...] +MAXREC=<n per dir> +SYN=<n> +GAP=<percent>.
`timescale 1ns / 1ps
module tb_attn_score;
  import tb_util_pkg::*;
  import kdpi_pkg::*;
  import attn_tb_pkg::*;
  import llm_pkg::*;

  parameter int KL       = 8;
  parameter int HS_MAX   = 64;
  parameter int DOT_PIPE = 2;
  parameter int SH_PIPE  = 1;
  localparam int NG   = (HS_MAX + KL - 1) / KL;
  localparam int GB_W = (NG > 1) ? $clog2(NG) : 1;
  localparam int HS_W = $clog2(HS_MAX + 1);
  localparam int LAT  = DOT_PIPE + 3 + SH_PIPE;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [HS_W-1:0]        hs_i = '0;
  logic [3:0]             d0_i = '0;
  logic [AM_W-1:0]        qm_i = '0, km_i = '0, vm_i = '0, s_vm_o, mmax_o;
  logic signed [E_W-1:0]  qe_i = '0, ke_i = '0, ve_i = '0, s_ve_o, emin_o;
  logic                   clr_i = 1'b0, q_we_i = 1'b0, k_valid_i = 1'b0, s_valid_o, have_o;
  logic [GB_W-1:0]        q_idx_i = '0;
  logic [KL*16-1:0]       q_data_i = '0, k_data_i = '0;
  logic signed [31:0]     s_o, mx_o;

  attn_score #(.KL(KL), .HS_MAX(HS_MAX), .DOT_PIPE(DOT_PIPE), .SH_PIPE(SH_PIPE)) dut (.*);

  tb_checker c_s = new("score"), c_vs = new("score_vs"), c_lat = new("latency"),
             c_st = new("stats"), c_rec = new("record");

  typedef struct { int s, vm, ve; longint at; int t; } exp_t;
  exp_t q[$];
  longint cyc = 0;   // cycle index seen at negedge
  att_case cur;
  int gap = 20;
  longint n_cases = 0, n_pos = 0;

  always @(posedge clk) cyc <= cyc + 1;

  always @(negedge clk) begin
    if (rst_n && s_valid_o === 1'b1) begin
      if (q.size() == 0) c_lat.fail($sformatf("s_valid_o without position at %0d", cyc));
      else begin
        automatic exp_t x = q.pop_front();
        if (x.at != cyc) c_lat.fail($sformatf("%s t %0d: s at %0d exp %0d", cur.desc(), x.t, cyc, x.at));
        else c_lat.pass();
        if (s_o !== x.s) c_s.fail($sformatf("%s t %0d: s %0d exp %0d", cur.desc(), x.t, s_o, x.s));
        else c_s.pass();
        if (int'(s_vm_o) !== x.vm || int'(s_ve_o) !== x.ve)
          c_vs.fail($sformatf("%s t %0d: vm/ve %0d/%0d exp %0d/%0d", cur.desc(), x.t, s_vm_o, s_ve_o, x.vm, x.ve));
        else c_vs.pass();
      end
    end else if (rst_n && s_valid_o !== 1'b0) c_lat.fail($sformatf("s_valid_o = %b", s_valid_o));
    else if (rst_n && q.size() > 0 && q[0].at < cyc) begin
      c_lat.fail($sformatf("%s t %0d: missing s (due %0d)", cur.desc(), q[0].t, q[0].at));
      void'(q.pop_front());
    end
  end

  function automatic logic [KL*16-1:0] rnd_beat();
    logic [KL*16-1:0] v;
    for (int l = 0; l < KL; l++) v[l*16 +: 16] = $urandom();
    return v;
  endfunction

  task automatic run_case(att_case c);
    int nb = (c.hs + KL - 1) / KL;
    cur = c;
    n_cases++;
    @(posedge clk);
    clr_i <= 1'b1;
    hs_i  <= HS_W'(c.hs);
    d0_i  <= 4'(c.d0);
    qm_i  <= AM_W'(c.qm);
    qe_i  <= E_W'(c.qe);
    @(posedge clk);
    clr_i <= 1'b0;
    for (int g = 0; g < nb; g++) begin
      logic [KL*16-1:0] v = rnd_beat();
      for (int l = 0; l < KL; l++) if (g * KL + l < c.hs) v[l*16 +: 16] = 16'(c.q[g * KL + l]);
      q_we_i   <= 1'b1;
      q_idx_i  <= GB_W'(g);
      q_data_i <= v;
      @(posedge clk);
    end
    q_we_i <= 1'b0;
    for (int t = 0; t < c.T; t++) begin
      for (int g = 0; g < nb; g++) begin
        logic [KL*16-1:0] v = rnd_beat();
        while ($urandom_range(99) < gap) begin
          k_valid_i <= 1'b0;
          k_data_i  <= rnd_beat();
          km_i <= $urandom(); ke_i <= $urandom(); vm_i <= $urandom(); ve_i <= $urandom();
          @(posedge clk);
        end
        for (int l = 0; l < KL; l++) if (g * KL + l < c.hs) v[l*16 +: 16] = 16'(c.K[t * c.hs + g * KL + l]);
        k_valid_i <= 1'b1;
        k_data_i  <= v;
        if (g == nb - 1) begin
          automatic exp_t x;
          km_i <= AM_W'(c.ksm[t]); ke_i <= E_W'(c.kse[t]);
          vm_i <= AM_W'(c.vsm[t]); ve_i <= E_W'(c.vse[t]);
          x.s = c.s[t]; x.vm = c.vsm[t]; x.ve = c.vse[t]; x.t = t;
          x.at = cyc + 1 + LAT;  // beat in cycle cyc+1 (cyc updates after this posedge)
          q.push_back(x);
        end else begin
          km_i <= $urandom(); ke_i <= $urandom(); vm_i <= $urandom(); ve_i <= $urandom();
        end
        @(posedge clk);
      end
    end
    k_valid_i <= 1'b0;
    repeat (LAT + 2) @(posedge clk);
    n_pos += c.T;
    if (mx_o !== c.mx) c_st.fail($sformatf("%s: mx %0d exp %0d", c.desc(), mx_o, c.mx));
    else c_st.pass();
    if (int'(have_o) !== c.have) c_st.fail($sformatf("%s: have %0d exp %0d", c.desc(), have_o, c.have));
    else c_st.pass();
    if (c.have) begin
      if (int'(emin_o) !== c.emin || int'(mmax_o) !== c.mmax)
        c_st.fail($sformatf("%s: emin/mmax %0d/%0d exp %0d/%0d", c.desc(), emin_o, mmax_o, c.emin, c.mmax));
      else c_st.pass();
    end
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
    $display("tb_attn_score: KL %0d HS_MAX %0d DOT_PIPE %0d SH_PIPE %0d LAT %0d seed %0d", KL, HS_MAX,
             DOT_PIPE, SH_PIPE, LAT, seed);
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
        $fatal(1, "tb_attn_score: no attention record file in %s", dirs[d]);
      while (nrec < maxrec && kd_rec_next() > 0) begin
        automatic att_case c = new();
        automatic int rc = c.load_rec();
        if (rc != 0) begin
          c_rec.fail($sformatf("%s record %0d: load %0d", dirs[d], kd_rec_index(), rc));
          continue;
        end
        c_rec.pass();
        if (c.hs > HS_MAX) continue;
        run_case(c);
        nrec++;
      end
      void'(kd_rec_close());
      $display("tb_attn_score: %s: %0d records", dirs[d], nrec);
      nrec_all += nrec;
    end
    for (int i = 0; i < nsyn; i++) begin
      automatic att_case c = new();
      c.gen_syn(i % 6, 64, HS_MAX);
      run_case(c);
    end
    repeat (4) @(posedge clk);
    $display("tb_attn_score: %0d cases (%0d records), %0d positions", n_cases, nrec_all, n_pos);
    begin
      automatic tb_checker_q l = '{c_s, c_vs, c_lat, c_st};
      if (dirs.size() > 0) l.push_back(c_rec);
      void'(tb_final_report(l));
    end
    $finish;
  end

endmodule
