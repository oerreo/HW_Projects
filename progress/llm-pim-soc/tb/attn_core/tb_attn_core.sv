// tb_attn_core: attn_core (one head) against the golden k_attn2_st (DPI, tb/common/attn_tb_pkg.sv).
//
// Black-box: the output stream must be p[0..T-1] (if p_en; last on p[T-1], is_o 0) then
// o[0..hs-1] (last on o[hs-1], is_o 1), equal to the golden outputs; done_o once per call.
// White-box stage trace (k_attn_st_t): every score s[t] (attn_score output), mx, e[t] (p buffer
// writes in P2), sum (at DIV), R, G, emin (in P3), w[t] (attn_vacc stage 4), every acc[i] (when
// O starts).
// Cases: every attention record of +VEC directories (K12V8 260K / 15M, HB, HD; T 1..512, hs 8
// and 48) and +SYN synthetic calls (gen_syn modes 0..5: random, equal scores, saturation and
// clamp, all vs.m = 0, extreme exponents, T and hs at the limit; hs not a multiple of 8).
// p_en is random (+PEN percent of calls with p output, default 80).
// Environment: q stream, KV source and output consumer are TB models:
//   +STALL=0  q and KV beats every cycle, request accepted at once, out_ready = 1. Then every
//             call's cycle count C (start cycle to done cycle) must equal
//             C = (T + 1) ceil(hs/8) + T + T ceil(hs/8) + hs + C0 (C0 = +C0, measured constant)
//   +STALL=1  random gaps on q / KV beats (+GAP percent), random request accept delay, random
//             out_ready (+PY percent ready); +OBLK=1 adds long out_ready = 0 blocks: the output
//             credit limit must be reached (P3 first beat held by the credit) at least once.
// Lanes >= hs, scales of K beats other than the last of a position and all scales of V beats
// are random. Negative: +NEG=1 start while busy (L2_START).
// Plusargs: +SEED +VEC=<dir,...> +MAXREC +SYN +STALL +GAP +PY +OBLK +PEN +C0 +NEG.
`timescale 1ns / 1ps
module tb_attn_core;
  import tb_util_pkg::*;
  import kdpi_pkg::*;
  import attn_tb_pkg::*;
  import llm_pkg::*;

  parameter int KL        = 8;
  parameter int VL        = KL;
  parameter int HS_MAX    = 64;
  parameter int TMAX      = 512;
  parameter int DOT_PIPE  = 2;
  parameter int SH_PIPE   = 1;
  parameter int RS_PIPE   = 1;
  parameter int LUT_PIPE  = 2;
  parameter int OUT_DEPTH = 16;
  localparam int HS_W = $clog2(HS_MAX + 1);
  localparam int TW   = $clog2(TMAX + 1);

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic                  start_i = 1'b0, p_en_i = 1'b0, busy_o, done_o;
  logic [TW-1:0]         t_i = '0;
  logic [HS_W-1:0]       hs_i = '0;
  logic [4:0]            kb_i = '0;
  logic [AM_W-1:0]       qm_i = '0, kv_km_i = '0, kv_vm_i = '0;
  logic signed [E_W-1:0] qe_i = '0, kv_ke_i = '0, kv_ve_i = '0;
  logic                  q_valid_i = 1'b0, q_ready_o;
  logic [KL*16-1:0]      q_data_i = '0, kv_data_i = '0;
  logic                  kvreq_valid_o, kvreq_ready_i = 1'b0, kvreq_pass_o;
  logic                  kv_valid_i = 1'b0, kv_ready_o, kv_stall_o;
  logic                  out_valid_o, out_ready_i = 1'b0, out_last_o, out_is_o_o;
  logic [31:0]           out_data_o;

  attn_core #(.KL(KL), .VL(VL), .HS_MAX(HS_MAX), .TMAX(TMAX), .DOT_PIPE(DOT_PIPE),
              .SH_PIPE(SH_PIPE), .RS_PIPE(RS_PIPE), .LUT_PIPE(LUT_PIPE),
              .OUT_DEPTH(OUT_DEPTH)) dut (.*);

  tb_checker c_out = new("out"), c_flag = new("out_flags"), c_done = new("done"),
             c_s = new("tr_score"), c_e = new("tr_e"), c_sc = new("tr_scalars"),
             c_w = new("tr_w"), c_acc = new("tr_acc"), c_cyc = new("cycles"),
             c_rec = new("record"), c_cov = new("coverage");

  longint cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  att_case cur;
  bit      cur_pen;
  // C0 = 54 + pipeline depths: P1 drain DOT+SH+5, P2 drain + DIV RS+LUT+3 + (Q_W 33 + 2),
  // P3 drain LAT_MAC + 1 = 7, O drain LAT_O + 2 = 4 (attn.md); +C0=<n> overrides
  int      stall = 0, gap = 20, py = 70, oblk = 0, pen_pct = 80, neg = 0;
  int      c0 = 54 + DOT_PIPE + SH_PIPE + RS_PIPE + LUT_PIPE;
  longint  n_cases = 0, n_pos = 0, n_credit_hold = 0, n_out_blk = 0;
  longint  t_start, t_done;
  int      oi, si, ei, wi;   // expected indices: output element, score, e, w
  bit      in_call = 0;

  // handshake flags sampled at negedge (inputs driven at posedge)
  bit q_taken, kv_taken, req_taken, req_pass_s;
  always @(negedge clk) begin
    q_taken   = q_valid_i && q_ready_o;
    kv_taken  = kv_valid_i && kv_ready_o;
    req_taken = kvreq_valid_o && kvreq_ready_i;
    if (req_taken) req_pass_s = kvreq_pass_o;
  end

  // ---------------- q driver ----------------
  task automatic drive_q(att_case c);
    int nb = (c.hs + KL - 1) / KL;
    for (int g = 0; g < nb; g++) begin
      logic [KL*16-1:0] v;
      for (int l = 0; l < KL; l++)
        v[l*16 +: 16] = (g * KL + l < c.hs) ? 16'(c.q[g * KL + l]) : 16'($urandom());
      while (stall && $urandom_range(99) < gap) begin
        q_valid_i <= 1'b0;
        q_data_i  <= {KL{16'($urandom())}};
        @(posedge clk);
      end
      q_valid_i <= 1'b1;
      q_data_i  <= v;
      // q_taken: handshake of the cycle just ended (sampled at its negedge)
      @(posedge clk);
      while (!q_taken) @(posedge clk);
    end
    q_valid_i <= 1'b0;
  endtask

  // ---------------- KV source model ----------------
  task automatic kv_pass(att_case c, int pass);
    int nb = (c.hs + KL - 1) / KL;
    for (int t = 0; t < c.T; t++)
      for (int g = 0; g < nb; g++) begin
        logic [KL*16-1:0] v;
        for (int l = 0; l < KL; l++) begin
          int i = g * KL + l;
          v[l*16 +: 16] = (i < c.hs) ? 16'(pass == 0 ? c.K[t * c.hs + i] : c.V[t * c.hs + i]) : 16'($urandom());
        end
        while (stall && $urandom_range(99) < gap) begin
          kv_valid_i <= 1'b0;
          kv_data_i  <= {KL{16'($urandom())}};
          kv_km_i <= $urandom(); kv_ke_i <= $urandom(); kv_vm_i <= $urandom(); kv_ve_i <= $urandom();
          @(posedge clk);
        end
        kv_valid_i <= 1'b1;
        kv_data_i  <= v;
        if (pass == 0 && g == nb - 1) begin
          kv_km_i <= AM_W'(c.ksm[t]); kv_ke_i <= E_W'(c.kse[t]);
          kv_vm_i <= AM_W'(c.vsm[t]); kv_ve_i <= E_W'(c.vse[t]);
        end else begin
          kv_km_i <= $urandom(); kv_ke_i <= $urandom(); kv_vm_i <= $urandom(); kv_ve_i <= $urandom();
        end
        @(posedge clk);
        while (!kv_taken) @(posedge clk);
      end
    kv_valid_i <= 1'b0;
  endtask

  task automatic kv_source(att_case c);
    for (int k = 0; k < 2; k++) begin
      if (stall) begin
        // wait for a request, accept it after a random delay
        while (kvreq_valid_o !== 1'b1) @(posedge clk);
        repeat ($urandom_range(3) == 0 ? $urandom_range(6) : 0) @(posedge clk);
        kvreq_ready_i <= 1'b1;
        @(posedge clk);
        kvreq_ready_i <= 1'b0;
      end else begin
        kvreq_ready_i <= 1'b1;
        do @(posedge clk); while (!req_taken);
      end
      if (req_pass_s != 1'(k)) c_flag.fail($sformatf("%s: request %0d has pass %0d", c.desc(), k, req_pass_s));
      else c_flag.pass();
      kv_pass(c, k);
    end
  endtask

  // ---------------- output consumer ----------------
  always @(posedge clk) begin
    if (!stall) out_ready_i <= 1'b1;
    else if (oblk && n_out_blk > 0) begin
      out_ready_i <= 1'b0;
      n_out_blk--;
    end else begin
      out_ready_i <= $urandom_range(99) < py;
      if (oblk && $urandom_range(299) == 0) n_out_blk = $urandom_range(80, 20);
    end
  end

  always @(negedge clk) begin
    if (rst_n && out_valid_o === 1'b1 && out_ready_i === 1'b1) begin
      automatic int np = cur_pen ? cur.T : 0;
      automatic int exp_v, exp_last, exp_iso;
      if (!in_call || oi >= np + cur.hs) c_out.fail($sformatf("extra output %0d at %0d", out_data_o, cyc));
      else begin
        if (oi < np) begin
          exp_v = cur.p[oi]; exp_last = oi == np - 1; exp_iso = 0;
        end else begin
          exp_v = cur.o[oi - np]; exp_last = oi - np == cur.hs - 1; exp_iso = 1;
        end
        if (int'(out_data_o) !== exp_v)
          c_out.fail($sformatf("%s: element %0d (%s %0d): %0d exp %0d", cur.desc(), oi,
                               exp_iso ? "o" : "p", exp_iso ? oi - np : oi, int'(out_data_o), exp_v));
        else c_out.pass();
        if (out_last_o !== 1'(exp_last) || out_is_o_o !== 1'(exp_iso))
          c_flag.fail($sformatf("%s: element %0d last %b is_o %b", cur.desc(), oi, out_last_o, out_is_o_o));
        else c_flag.pass();
        oi++;
      end
    end
  end

  // ---------------- white-box stage trace ----------------
  bit sc_r = 0, sc_g = 0, sc_acc = 0;
  always @(negedge clk) begin
    if (rst_n && in_call) begin
      automatic int st = int'(dut.st_q);
      if (dut.s_valid === 1'b1) begin
        if (si >= cur.T) c_s.fail("extra score");
        else if (dut.s_val !== cur.s[si]) c_s.fail($sformatf("%s: s[%0d] %0d exp %0d", cur.desc(), si, dut.s_val, cur.s[si]));
        else c_s.pass();
        si++;
      end
      if (dut.e_valid === 1'b1) begin
        if (ei >= cur.T) c_e.fail("extra e");
        else if (int'(dut.e_val) !== cur.e[ei]) c_e.fail($sformatf("%s: e[%0d] %0d exp %0d", cur.desc(), ei, dut.e_val, cur.e[ei]));
        else c_e.pass();
        ei++;
      end
      if (st == 6) begin  // S_DIV
        if (dut.mx !== cur.mx || longint'(dut.sum_q) !== cur.sum)
          c_sc.fail($sformatf("%s: mx %0d sum %0d exp %0d %0d", cur.desc(), dut.mx, dut.sum_q, cur.mx, cur.sum));
        else c_sc.pass();
      end
      if (st == 8 && !sc_r) begin  // first S_P3 cycle
        sc_r = 1;
        if (longint'(dut.r_q) !== cur.R || int'(dut.g_q) !== cur.G || int'(dut.emin_q) !== cur.emin)
          c_sc.fail($sformatf("%s: R %0d G %0d emin %0d exp %0d %0d %0d", cur.desc(), dut.r_q, dut.g_q,
                              dut.emin_q, cur.R, cur.G, cur.emin));
        else c_sc.pass();
      end
      if (dut.u_vacc.v4 === 1'b1 && dut.u_vacc.b4.first === 1'b1) begin
        if (wi >= cur.T) c_w.fail("extra w");
        else if (longint'(dut.u_vacc.w4) !== cur.w[wi])
          c_w.fail($sformatf("%s: w[%0d] %0d exp %0d", cur.desc(), wi, dut.u_vacc.w4, cur.w[wi]));
        else c_w.pass();
        wi++;
      end
      if (st == 10 && !sc_acc) begin  // first S_OD cycle
        sc_acc = 1;
        for (int i = 0; i < cur.hs; i++)
          if (longint'(dut.u_vacc.acc_q[i / KL][i % KL]) !== cur.acc[i])
            c_acc.fail($sformatf("%s: acc[%0d] %0d exp %0d", cur.desc(), i, dut.u_vacc.acc_q[i / KL][i % KL], cur.acc[i]));
          else c_acc.pass();
      end
      if (st == 8 && kv_valid_i === 1'b1 && kv_ready_o === 1'b0) n_credit_hold++;
    end
  end

  // ---------------- one call ----------------
  task automatic run_case(att_case c);
    int nb = (c.hs + KL - 1) / KL;
    cur = c;
    cur_pen = $urandom_range(99) < pen_pct;
    oi = 0; si = 0; ei = 0; wi = 0; sc_r = 0; sc_acc = 0;
    n_cases++;
    // start (busy_o is 0 here: previous call done)
    start_i <= 1'b1;
    t_i     <= TW'(c.T);
    hs_i    <= HS_W'(c.hs);
    kb_i    <= 5'(c.kb);
    qm_i    <= AM_W'(c.qm);
    qe_i    <= E_W'(c.qe);
    p_en_i  <= cur_pen;
    t_start = cyc + 1;
    in_call = 1;
    @(posedge clk);
    start_i <= 1'b0;
    t_i <= $urandom(); hs_i <= $urandom(); kb_i <= $urandom(); qm_i <= $urandom(); qe_i <= $urandom();
    p_en_i <= $urandom();
    fork
      drive_q(c);
      kv_source(c);
      begin
        while (done_o !== 1'b1) @(negedge clk);
        t_done = cyc;
      end
    join
    // done seen at negedge of t_done; checks
    if (oi != (cur_pen ? c.T : 0) + c.hs) c_out.fail($sformatf("%s: %0d outputs", c.desc(), oi));
    if (si != c.T || ei != c.T || wi != c.T)
      c_s.fail($sformatf("%s: counts s %0d e %0d w %0d", c.desc(), si, ei, wi));
    c_done.pass();
    if (!stall) begin
      longint C = t_done - t_start;
      longint F = longint'(c.T + 1) * nb + c.T + longint'(c.T) * nb + c.hs;
      if (C - F != c0) c_cyc.fail($sformatf("%s: C %0d = F %0d + %0d, expected + %0d", c.desc(), C, F, C - F, c0));
      else c_cyc.pass();
    end
    n_pos += c.T;
    in_call = 0;
    // next start: in the done cycle's successor or after a gap
    @(posedge clk);
    if (stall) repeat ($urandom_range(2)) @(posedge clk);
  endtask

  initial begin
    automatic int unsigned seed;
    automatic int maxrec = 1 << 30, nsyn = 0, nrec_all = 0;
    automatic string vec = "";
    automatic string dirs[$];
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("MAXREC=%d", maxrec));
    void'($value$plusargs("SYN=%d", nsyn));
    void'($value$plusargs("STALL=%d", stall));
    void'($value$plusargs("GAP=%d", gap));
    void'($value$plusargs("PY=%d", py));
    void'($value$plusargs("OBLK=%d", oblk));
    void'($value$plusargs("PEN=%d", pen_pct));
    void'($value$plusargs("C0=%d", c0));
    void'($value$plusargs("NEG=%d", neg));
    void'($value$plusargs("VEC=%s", vec));
    $display("tb_attn_core: KL %0d HS_MAX %0d TMAX %0d PIPE %0d/%0d/%0d/%0d OUT_DEPTH %0d seed %0d stall %0d",
             KL, HS_MAX, TMAX, DOT_PIPE, SH_PIPE, RS_PIPE, LUT_PIPE, OUT_DEPTH, seed, stall);
    while (vec != "") begin
      automatic int k = 0;
      while (k < vec.len() && vec[k] != ",") k++;
      dirs.push_back(vec.substr(0, k - 1));
      vec = (k < vec.len()) ? vec.substr(k + 1, vec.len() - 1) : "";
    end
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    @(posedge clk);
    if (neg == 1) begin
      automatic att_case c = new();
      c.gen_syn(0, 8, HS_MAX < 8 ? HS_MAX : 8);
      fork
        run_case(c);
        begin
          repeat (5) @(posedge clk);
          start_i <= 1'b1;  // while busy: L2_START, ignored
          @(posedge clk);
          start_i <= 1'b0;
        end
      join
    end
    foreach (dirs[d]) begin
      automatic int nrec = 0;
      if (kd_rec_open({dirs[d], "/attn2.bin"}) != 0 && kd_rec_open({dirs[d], "/attn.bin"}) != 0)
        $fatal(1, "tb_attn_core: no attention record file in %s", dirs[d]);
      while (nrec < maxrec && kd_rec_next() > 0) begin
        automatic att_case c = new();
        automatic int rc = c.load_rec();
        if (rc != 0) begin
          c_rec.fail($sformatf("%s record %0d: load %0d", dirs[d], kd_rec_index(), rc));
          continue;
        end
        c_rec.pass();
        if (c.hs > HS_MAX || c.T > TMAX) continue;
        run_case(c);
        nrec++;
      end
      void'(kd_rec_close());
      $display("tb_attn_core: %s: %0d records", dirs[d], nrec);
      nrec_all += nrec;
    end
    for (int i = 0; i < nsyn; i++) begin
      automatic att_case c = new();
      c.gen_syn(i % 6, TMAX < 96 ? TMAX : 96, HS_MAX);
      run_case(c);
    end
    repeat (4) @(posedge clk);
    $display("tb_attn_core: %0d calls (%0d records), %0d positions, credit holds %0d cycles",
             n_cases, nrec_all, n_pos, n_credit_hold);
    if (oblk) begin
      if (n_credit_hold > 0) c_cov.pass();
      else c_cov.fail("output credit limit never reached");
    end
    begin
      automatic tb_checker_q l = '{c_out, c_flag, c_done, c_s, c_e, c_sc, c_w, c_acc};
      if (!stall) l.push_back(c_cyc);
      if (dirs.size() > 0) l.push_back(c_rec);
      if (oblk) l.push_back(c_cov);
      void'(tb_final_report(l));
    end
    $finish;
  end

endmodule
