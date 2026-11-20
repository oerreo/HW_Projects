// tb_vec_csr: vec_csr (rtl/l3/vec_csr.sv) alone against a register-file model written from
// docs/spec/vec.md (3 register map, 4.1 CTRL and call timing, 4.2 descriptor check).
//
// Model: descriptor registers (reset values, field bits only); a CTRL write in cycle s while idle
// (no check, no op, or the done cycle) with op 1..4 is accepted: the descriptor is latched (outputs
// from s + 1), STATUS.busy = 1 from s + 1, the verdict in v = s + 1 (CHK_CYC 1) either starts the
// op (start_o in v, busy_o from v + 1 to the done_i cycle) or sets BAD_DESC / MISALIGN. The verdict
// is computed reason by reason with 64-bit TB arithmetic (N x 4, x 2, x qb as products).
// Every cycle (negedge): rd_data_o of the presented read address (any address, every cycle),
// start_o, busy_o, STATUS / ERR / counters through reads, the latched outputs op_o, in0_o, in1_o,
// out_o, scl_o, n_o, qmax_o, f_o, ge_o, epsc_o from s + 1 until the next accepted call, and the
// internal state (err, done, busy, check, CYCLES, RD_STALL, WR_STALL, OPS, ARGMAX registers).
// Stimulus:
//   directed: a legal descriptor of every op (pass); every BAD_DESC reason alone with its first
//     illegal and last legal value (N 0 / 1 / N_MAX / N_MAX + 1, ARGMAX 2^IDX_W / + 1, N with high
//     bits (no aliasing), mode, every qmax neighbour, sb, epsc sign), every byte range ending
//     exactly at 2^32 (pass) and 8 bytes beyond (fail), fields an op does not use (no error),
//     every MISALIGN alone and on unused addresses (no error), BAD_DESC with MISALIGN, BAD_OP
//     (0, 5..15), START_BUSY in the verdict cycle and during the op (also with a bad op), CTRL in
//     the done cycle (start 1: accepted, start 0: done_sticky cleared), descriptor writes in the
//     verdict cycle (the latched value decides), ERR W1C in the cycle of a set of the same bit.
//   random (+N_CYC cycles): write strobes (descriptor fields from a legal template, the edge
//     values of the current registers, or random; CTRL with start 0/1 and op 0..15; ERR W1C),
//     a read address every cycle, events (done_i while the op runs, +PDONE percent; ARGMAX result
//     with done_i of an ARGMAX call; rd_err, wr_err, rd_stall, wr_stall, +PEV percent).
// Coverage (required): pass per op, each reason alone (except the SCL range: only possible with
// MISALIGN), each 2^32 edge accepted and rejected,
// every MISALIGN, the collision cases, every ERR bit.
`timescale 1ns / 1ps
module tb_vec_csr;
  import tb_util_pkg::*;
  import llm_pkg::*;

  parameter int N_MAX = 1024;
  parameter int IDX_W = 16;
  localparam int NV_W = IDX_W + 1;
  localparam int ADDR_W = 12;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic              wr_en_i = 0, rd_en_i = 0, done_i = 0, am_valid_i = 0;
  logic              rd_err_i = 0, wr_err_i = 0, rd_stall_i = 0, wr_stall_i = 0;
  logic [ADDR_W-1:0] wr_addr_i = '0, rd_addr_i = '0;
  logic [31:0]       wr_data_i = '0, rd_data_o, am_val_i = '0;
  logic [IDX_W-1:0]  am_idx_i = '0;
  logic              start_o, busy_o;
  logic [1:0]        op_o;
  logic [31:0]       in0_o, in1_o, out_o, scl_o, epsc_o;
  logic [NV_W-1:0]   n_o;
  logic [15:0]       qmax_o;
  logic signed [E_W-1:0] f_o, ge_o;

  vec_csr #(.ADDR_W(ADDR_W), .N_MAX(N_MAX), .IDX_W(IDX_W)) dut (
    .clk, .rst_n, .wr_en_i, .wr_addr_i, .wr_data_i, .rd_en_i, .rd_addr_i, .rd_data_o, .start_o,
    .busy_o, .done_i, .op_o, .in0_o, .in1_o, .out_o, .scl_o, .n_o, .qmax_o, .f_o, .ge_o, .epsc_o,
    .am_valid_i, .am_idx_i, .am_val_i, .rd_err_i, .wr_err_i, .rd_stall_i, .wr_stall_i);

  tb_checker c_rd = new("read"), c_ctl = new("control"), c_lat = new("latched"),
             c_st = new("state"), c_cov = new("coverage");

  localparam int A_CTRL = 'h08, A_ERR = 'h10, A_IN0 = 'h40, A_IN1 = 'h44, A_OUT = 'h48,
                 A_SCL = 'h4C, A_N = 'h50, A_FMT = 'h54, A_EXP = 'h58, A_EPSC = 'h5C;

  // ---------------- model ----------------
  typedef struct {
    longint unsigned in0, in1, out, scl, n, epsc;
    int qmax, mode, sb, f, ge;
  } desc_t;
  desc_t r, l;                     // registers, latched
  int    m_err = 0, m_done = 0, m_busy = 0, m_chk = 0, m_op = 0, m_rop = 0, m_lat = 0;
  longint unsigned m_cyc = 0, m_rdst = 0, m_wrst = 0, m_ops = 0, m_ami = 0, m_amv = 0;

  // reasons (bit set = violated): 0 N, 1 mode, 2 qmax, 3 sb, 4 epsc, 5 IN0 range, 6 IN1 range,
  // 7 OUT range, 8 SCL range; misalign: 16 IN0, 17 IN1, 18 OUT, 19 SCL
  function automatic int reasons(desc_t d, int op);
    longint unsigned lim = 64'h1_0000_0000;
    int rs = 0;
    bit uses1 = op == 1 || op == 2, usesc = op != 4;
    longint unsigned qb = (op == 3 && d.qmax != 127) ? 2 : 1;
    if (d.n == 0 || (op == 4 ? d.n > (64'd1 << IDX_W) : d.n > N_MAX)) rs |= 1 << 0;
    if (op != 4 && d.mode != 1) rs |= 1 << 1;
    if (op == 3 && !(d.qmax == 127 || d.qmax == 2047 || d.qmax == 32767)) rs |= 1 << 2;
    if (op == 2 && d.sb != 8) rs |= 1 << 3;
    if (op == 1 && d.epsc >= 64'h8000_0000) rs |= 1 << 4;
    if (d.in0 + 4 * d.n > lim) rs |= 1 << 5;
    if (uses1 && d.in1 + (op == 1 ? 2 : 4) * d.n > lim) rs |= 1 << 6;
    if (d.out + (op == 4 ? 4 : qb * d.n) > lim) rs |= 1 << 7;
    if (usesc && d.scl + 8 > lim) rs |= 1 << 8;
    if (d.in0 % 8) rs |= 1 << 16;
    if (uses1 && d.in1 % 8) rs |= 1 << 17;
    if (d.out % 8) rs |= 1 << 18;
    if (usesc && d.scl % 8) rs |= 1 << 19;
    return rs;
  endfunction

  function automatic logic [31:0] model_read(int a);
    if ((a >> 8) != 0) return 0;
    case (a & 'hFC)
      'h00: return 32'h5645_0001;
      'h04: return {16'(N_MAX), 8'(IDX_W), 8'd100};
      'h0C: return {29'd0, m_err != 0, 1'(m_done), 1'(m_busy || m_chk != 0)};
      'h10: return 32'(m_err);
      'h14: return 32'(m_cyc);
      'h18: return 32'(m_rdst);
      'h1C: return 32'(m_wrst);
      'h20: return 32'(m_ops);
      'h24: return 32'(m_ami);
      'h28: return 32'(m_amv);
      A_IN0: return 32'(r.in0); A_IN1: return 32'(r.in1); A_OUT: return 32'(r.out);
      A_SCL: return 32'(r.scl); A_N: return 32'(r.n); A_EPSC: return 32'(r.epsc);
      A_FMT: return {4'd0, 4'(r.sb), 7'd0, 1'(r.mode), 16'(r.qmax)};
      A_EXP: return {16'd0, 8'(r.ge), 8'(r.f)};
      default: return 0;
    endcase
  endfunction

  // coverage
  int cov_pass[5], cov_reason[32], cov_edge_ok[16], cov_edge_bad[16];
  int cov_sb_verdict = 0, cov_sb_op = 0, cov_done_acc = 0, cov_done_clr = 0, cov_wr_verdict = 0,
      cov_w1c_set = 0, cov_err[6];
  int last_rs = 0;
  bit last_v = 0;

  always @(negedge clk) begin
    if (rst_n) begin
      automatic int wa = int'(wr_addr_i), w = wa & 'hFC;
      automatic bit wr_hit = wr_en_i && (wa >> 8) == 0;
      automatic bit idle = (!m_busy && m_chk == 0) || done_i;
      automatic bit verdict = m_chk == 1, was_busy = m_busy || m_chk != 0;
      automatic int op = int'(wr_data_i[7:4]), set = 0, rs = 0;
      automatic bit sreq = wr_hit && w == A_CTRL && wr_data_i[0], op_ok = op >= 1 && op <= 4;
      automatic bit acc = sreq && idle && op_ok, st;
      // read (every cycle, any address)
      if (rd_data_o !== model_read(int'(rd_addr_i)))
        c_rd.fail($sformatf("read 0x%0h: 0x%08h model 0x%08h", rd_addr_i, rd_data_o, model_read(int'(rd_addr_i))));
      else c_rd.pass();
      // internal state
      if (int'(dut.err_q) !== m_err || int'(dut.done_q) !== m_done || int'(dut.busy_q) !== m_busy ||
          int'(dut.chk_q) !== m_chk || longint'(dut.cyc_q) !== m_cyc || longint'(dut.ops_q) !== m_ops ||
          longint'(dut.rdst_q) !== m_rdst || longint'(dut.wrst_q) !== m_wrst)
        c_st.fail($sformatf("state err %0h/%0h done %0d/%0d busy %0d/%0d chk %0d/%0d cyc %0d/%0d", dut.err_q,
                            m_err, dut.done_q, m_done, dut.busy_q, m_busy, dut.chk_q, m_chk, dut.cyc_q, m_cyc));
      else c_st.pass();
      if (busy_o !== 1'(m_busy)) c_ctl.fail($sformatf("busy_o %b model %0d", busy_o, m_busy));
      else c_ctl.pass();
      // latched outputs (from s + 1)
      if (m_lat) begin
        if (int'(op_o) !== m_op - 1 || in0_o !== 32'(l.in0) || in1_o !== 32'(l.in1) ||
            out_o !== 32'(l.out) || scl_o !== 32'(l.scl) || n_o !== NV_W'(l.n) ||
            int'(qmax_o) !== l.qmax || f_o !== E_W'(l.f) || ge_o !== E_W'(l.ge) || epsc_o !== 32'(l.epsc))
          c_lat.fail($sformatf("latched outputs differ (op %0d/%0d n %0d/%0d)", op_o, m_op - 1, n_o, l.n));
        else c_lat.pass();
      end
      if (verdict) rs = reasons(l, m_op);
      st = verdict && rs == 0;
      if (start_o !== st) c_ctl.fail($sformatf("start_o %b model %b (op %0d reasons 0x%0h)", start_o, st, m_op, rs));
      else c_ctl.pass();
      if (verdict) begin
        if (rs == 0) cov_pass[m_op]++;
        for (int b = 0; b < 32; b++) if (rs == (1 << b)) cov_reason[b]++;
        last_rs = rs;
        last_v = 1;
        if (wr_hit && w >= A_IN0 && w <= A_EPSC) cov_wr_verdict++;
        if (sreq) cov_sb_verdict++;
      end
      if (sreq && m_busy && !done_i) cov_sb_op++;
      if (done_i && wr_hit && w == A_CTRL) begin if (wr_data_i[0] && op_ok) cov_done_acc++; else if (!wr_data_i[0]) cov_done_clr++; end
      if (sreq && !idle) set |= 1;
      if (sreq && !op_ok) set |= 2;
      if (verdict && (rs & 'hFFFF) != 0) set |= 4;
      if (verdict && (rs >> 16) != 0) set |= 8;
      if (rd_err_i) set |= 16;
      if (wr_err_i) set |= 32;
      if (wr_hit && w == A_ERR && (int'(wr_data_i[5:0]) & set) != 0) cov_w1c_set++;
      for (int b = 0; b < 6; b++) if (set & (1 << b)) cov_err[b]++;
      if (done_i && !m_busy) c_ctl.fail("TB: done_i while not busy");
      // update
      if (done_i && m_rop == 4 && am_valid_i) begin m_ami = am_idx_i; m_amv = am_val_i; end
      if (acc) begin m_chk = 1; l = r; m_op = op; m_lat = 1; end
      else if (m_chk) m_chk = 0;
      if (st) begin m_busy = 1; m_rop = m_op; end
      else if (done_i) m_busy = 0;
      if (wr_hit && w == A_CTRL && idle && !(wr_data_i[0] && !op_ok)) m_done = 0;
      else if (done_i) m_done = 1;
      m_err = (m_err & ~((wr_hit && w == A_ERR) ? int'(wr_data_i[5:0]) : 0)) | set;
      if (acc) begin m_cyc = 0; m_rdst = 0; m_wrst = 0; end
      else if (was_busy) begin
        m_cyc = (m_cyc + 1) & 32'hFFFF_FFFF;
        if (rd_stall_i) m_rdst++;
        if (wr_stall_i) m_wrst++;
      end
      if (done_i) m_ops++;
      if (wr_hit)
        case (w)
          A_IN0: r.in0 = wr_data_i; A_IN1: r.in1 = wr_data_i; A_OUT: r.out = wr_data_i;
          A_SCL: r.scl = wr_data_i; A_N: r.n = wr_data_i; A_EPSC: r.epsc = wr_data_i;
          A_FMT: begin r.qmax = wr_data_i[15:0]; r.mode = wr_data_i[16]; r.sb = wr_data_i[27:24]; end
          A_EXP: begin r.f = wr_data_i[7:0]; r.ge = wr_data_i[15:8]; end
          default: ;
        endcase
    end
  end

  // ---------------- stimulus helpers ----------------
  int pdone = 5, pev = 20;
  bit rnd_ev = 0;
  // one cycle: optional write, random read address, events
  task automatic cyc1(bit we = 0, int a = 0, logic [31:0] d = 0, bit dn = 0);
    wr_en_i   <= we;
    wr_addr_i <= ADDR_W'(a);
    wr_data_i <= we ? d : $urandom();
    rd_en_i   <= $urandom_range(1);
    rd_addr_i <= ADDR_W'($urandom_range(3) == 0 ? $urandom() : ($urandom_range(31) << 2) | $urandom_range(3));
    done_i    <= dn;
    am_valid_i <= dn && dut.op_q == 2'd3;
    am_idx_i  <= IDX_W'($urandom());
    am_val_i  <= $urandom();
    rd_err_i  <= rnd_ev && $urandom_range(99) < pev / 4;
    wr_err_i  <= rnd_ev && $urandom_range(99) < pev / 4;
    rd_stall_i <= rnd_ev && $urandom_range(99) < pev;
    wr_stall_i <= rnd_ev && $urandom_range(99) < pev;
    @(posedge clk);
  endtask
  task automatic wr(int a, logic [31:0] d);
    cyc1(1, a, d);
  endtask
  task automatic set_desc(desc_t d);
    wr(A_IN0, d.in0); wr(A_IN1, d.in1); wr(A_OUT, d.out); wr(A_SCL, d.scl); wr(A_N, d.n);
    wr(A_FMT, {4'd0, 4'(d.sb), 7'd0, 1'(d.mode), 16'(d.qmax)}); wr(A_EXP, {16'd0, 8'(d.ge), 8'(d.f)});
    wr(A_EPSC, d.epsc);
  endtask
  // CTRL op, then the verdict cycle; a started op ends after a few cycles (done_i)
  task automatic call(int op, int sb_at = -1);
    wr(A_CTRL, (op << 4) | 1);
    if (sb_at == 0) wr(A_CTRL, (op << 4) | 1); else cyc1();     // verdict cycle
    if (busy_o === 1'b1 || start_o === 1'b1) begin
      repeat ($urandom_range(4)) cyc1();
      if (sb_at == 1) wr(A_CTRL, 32'h01);                          // during the op, bad op 0
      cyc1(0, 0, 0, 1);
    end
    cyc1();
  endtask
  function automatic desc_t legal(int op, longint unsigned n);
    desc_t d;
    d.n = n; d.in0 = 64'h1000_0000; d.in1 = 64'h2000_0000; d.out = 64'h3000_0000; d.scl = 64'h3800_0000;
    d.qmax = op == 3 ? 2047 : 127; d.mode = 1; d.sb = 8; d.f = 16; d.ge = 10; d.epsc = 1000;
    return d;
  endfunction
  task automatic try(desc_t d, int op, int expect_rs);
    set_desc(d);
    call(op);
    if (last_rs !== expect_rs) c_cov.fail($sformatf("directed op %0d: reasons 0x%0h expected 0x%0h", op, last_rs, expect_rs));
    else c_cov.pass();
  endtask

  task automatic directed();
    desc_t d;
    longint unsigned lim = 64'h1_0000_0000, nm = N_MAX - (N_MAX % 8);
    for (int op = 1; op <= 4; op++) try(legal(op, 8), op, 0);
    // N
    for (int op = 1; op <= 4; op++) begin
      try(legal(op, 0), op, 1);
      try(legal(op, 1), op, 0);
      try(legal(op, op == 4 ? (64'd1 << IDX_W) : N_MAX), op, 0);
      try(legal(op, op == 4 ? (64'd1 << IDX_W) + 1 : N_MAX + 1), op, 1);
      try(legal(op, 64'h8000_0008), op, 1 | (1 << 5) | (op == 1 || op == 2 ? 1 << 6 : 0) | (op == 3 ? 1 << 7 : 0));
    end
    // mode, qmax, sb, epsc (and the fields an op ignores)
    for (int op = 1; op <= 4; op++) begin d = legal(op, 8); d.mode = 0; try(d, op, op == 4 ? 0 : 2); end
    begin
      int qs[$] = '{0, 126, 127, 128, 2046, 2047, 2048, 32766, 32767, 32768, 65535};
      foreach (qs[k]) begin
        d = legal(3, 8); d.qmax = qs[k];
        try(d, 3, (qs[k] == 127 || qs[k] == 2047 || qs[k] == 32767) ? 0 : 4);
        d = legal(1, 8); d.qmax = qs[k]; try(d, 1, 0);
      end
    end
    for (int sb = 0; sb < 16; sb += 1) begin d = legal(2, 8); d.sb = sb; try(d, 2, sb == 8 ? 0 : 8); end
    d = legal(1, 8); d.sb = 0; try(d, 1, 0);
    d = legal(1, 8); d.epsc = 64'h7FFF_FFFF; try(d, 1, 0);
    d = legal(1, 8); d.epsc = 64'h8000_0000; try(d, 1, 16);
    d = legal(3, 8); d.epsc = 64'hFFFF_FFFF; try(d, 3, 0);
    // ranges: exactly 2^32 and 8 bytes beyond
    for (int op = 1; op <= 4; op++) begin
      longint unsigned n = nm, qb = (op == 3) ? 2 : 1;   // legal(3) has qmax 2047
      d = legal(op, n); d.in0 = lim - 4 * n; try(d, op, 0); cov_edge_ok[0]++;
      d.in0 += 8; try(d, op, 1 << 5); cov_edge_bad[0]++;
      if (op <= 2) begin
        d = legal(op, n); d.in1 = lim - (op == 1 ? 2 : 4) * n; try(d, op, 0); cov_edge_ok[1]++;
        d.in1 += 8; try(d, op, 1 << 6); cov_edge_bad[1]++;
      end
      d = legal(op, n); d.out = lim - (op == 4 ? 8 : qb * n); try(d, op, 0); cov_edge_ok[2]++;
      if (op != 4) begin d.out += 8; try(d, op, 1 << 7); cov_edge_bad[2]++; end
      else begin d.out = lim - 4; try(d, op, 1 << 18); d.out = lim - 2; try(d, op, (1 << 7) | (1 << 18)); cov_edge_bad[2]++; end
      if (op != 4) begin
        d = legal(op, n); d.scl = lim - 8; try(d, op, 0); cov_edge_ok[3]++;
        d.scl = lim - 4; try(d, op, (1 << 8) | (1 << 19)); cov_edge_bad[3]++;
      end
    end
    d = legal(3, 8); d.qmax = 127; d.out = lim - 8; try(d, 3, 0);          // int8: N bytes
    d = legal(3, 9); d.qmax = 127; d.out = lim - 8; try(d, 3, 1 << 7);
    // misalign alone, and on unused addresses
    for (int op = 1; op <= 4; op++) begin
      d = legal(op, 8); d.in0 += 4; try(d, op, 1 << 16);
      d = legal(op, 8); d.in1 += 2; try(d, op, (op <= 2) ? 1 << 17 : 0);
      d = legal(op, 8); d.out += 1; try(d, op, 1 << 18);
      d = legal(op, 8); d.scl += 4; try(d, op, (op != 4) ? 1 << 19 : 0);
    end
    d = legal(3, 0); d.in0 += 4; try(d, 3, 1 | (1 << 16));                // BAD_DESC + MISALIGN
    // BAD_OP
    for (int op = 0; op < 16; op++) if (op == 0 || op > 4) begin wr(A_CTRL, (op << 4) | 1); cyc1(); end
    // START_BUSY in the verdict cycle and during the op (with op 0)
    set_desc(legal(3, 8));
    call(3, 0);
    call(3, 1);
    // CTRL in the done cycle: start 1 (accepted) and start 0 (done_sticky cleared)
    set_desc(legal(4, 8));
    wr(A_CTRL, 32'h41); cyc1(); cyc1(); cyc1(1, A_CTRL, 32'h41, 1); cyc1(); cyc1(0, 0, 0, 1); cyc1();
    wr(A_CTRL, 32'h41); cyc1(); cyc1(1, A_CTRL, 32'h40, 1); cyc1();
    // descriptor write in the verdict cycle (latched value decides): N 0 written at v
    set_desc(legal(3, 8));
    wr(A_CTRL, 32'h31); wr(A_N, 0); cyc1(0, 0, 0, 1); cyc1();
    // the same for every address register: an out-of-range / misaligned value written at v
    begin
      automatic int as[4] = '{A_IN0, A_IN1, A_OUT, A_SCL};
      foreach (as[k]) begin
        set_desc(legal(1, 8));
        wr(A_CTRL, 32'h11); wr(as[k], 32'hFFFF_FFFC);
        if (last_rs !== 0) c_cov.fail($sformatf("verdict-cycle write 0x%0h changed the verdict", as[k]));
        else c_cov.pass();
        cyc1(0, 0, 0, 1); cyc1();
      end
    end
    // W1C in the cycle of a set of the same bit (BAD_OP set while clearing it)
    wr(A_CTRL, 32'h01); wr(A_ERR, 32'h3F); cyc1();
    rnd_ev = 1;
    repeat (50) cyc1();
    rnd_ev = 0;
    wr(A_ERR, 32'h3F); cyc1();
  endtask

  // random value for a register write
  function automatic logic [31:0] rnd_val(int a);
    longint unsigned lim = 64'h1_0000_0000, n = r.n;
    case ($urandom_range(3))
      0: return $urandom();
      default:
        case (a)
          A_N: return $urandom_range(1) ? $urandom_range(N_MAX + 1) : $urandom_range(1 << IDX_W, (1 << IDX_W) - 1) + $urandom_range(2);
          A_FMT: return {4'd0, 4'($urandom_range(3) ? 8 : $urandom_range(15)), 7'd0, 1'($urandom_range(7) != 0),
                         16'($urandom_range(3) == 0 ? $urandom() : (int'($urandom_range(2) == 0 ? 127 : $urandom_range(1) ? 2047 : 32767)))};
          A_EPSC: return $urandom_range(3) ? $urandom_range(1 << 20) : $urandom();
          A_EXP: return $urandom();
          A_IN0: return 32'(lim - 4 * n + 8 * ($urandom_range(2)) - 8 + ($urandom_range(7) == 0 ? 4 : 0));
          A_IN1: return 32'(lim - ($urandom_range(1) ? 2 : 4) * n + 8 * $urandom_range(2) - 8);
          A_OUT: return 32'(lim - ($urandom_range(1) ? 1 : 2) * n + 8 * $urandom_range(2) - 8 - ($urandom_range(5) == 0 ? 4 : 0));
          A_SCL: return 32'(lim - 8 * $urandom_range(2) + ($urandom_range(7) == 0 ? 4 : 0));
          default: return $urandom();
        endcase
    endcase
  endfunction

  initial begin
    automatic int unsigned seed;
    automatic longint ncyc = 300000;
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("N_CYC=%d", ncyc));
    void'($value$plusargs("PDONE=%d", pdone));
    void'($value$plusargs("PEV=%d", pev));
    $display("tb_vec_csr: N_MAX %0d IDX_W %0d seed %0d N_CYC %0d", N_MAX, IDX_W, seed, ncyc);
    r.in0 = 0; r.in1 = 0; r.out = 0; r.scl = 0; r.n = 0; r.epsc = 0; r.qmax = 127; r.mode = 1; r.sb = 8;
    r.f = 0; r.ge = 0;
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    @(posedge clk);
    directed();
    rnd_ev = 1;
    for (longint i = 0; i < ncyc; i++) begin
      automatic int regs[$] = '{A_IN0, A_IN1, A_OUT, A_SCL, A_N, A_FMT, A_EXP, A_EPSC};
      automatic bit dn = m_busy && $urandom_range(99) < pdone;
      case ($urandom_range(9))
        0, 1: begin
          automatic int a = regs[$urandom_range(regs.size() - 1)];
          cyc1(1, a | $urandom_range(3), rnd_val(a), dn);
        end
        2: cyc1(1, A_CTRL, {24'd0, 4'($urandom_range(3) == 0 ? $urandom_range(15) : $urandom_range(4, 1)),
                            3'd0, 1'($urandom_range(5) != 0)}, dn);
        3: cyc1(1, $urandom_range(1) ? A_ERR : ($urandom_range(255) << 2), $urandom(), dn);
        4: cyc1(1, $urandom(), $urandom(), dn);
        default: cyc1(0, 0, 0, dn);
      endcase
    end
    rnd_ev = 0;
    repeat (5) cyc1(0, 0, 0, m_busy);
    // coverage
    $display("tb_vec_csr: passes per op %0d %0d %0d %0d; START_BUSY in verdict %0d / op %0d; done-cycle CTRL accept %0d clear %0d; verdict writes %0d; W1C vs set %0d",
             cov_pass[1], cov_pass[2], cov_pass[3], cov_pass[4], cov_sb_verdict, cov_sb_op, cov_done_acc,
             cov_done_clr, cov_wr_verdict, cov_w1c_set);
    begin
      automatic string miss = "";
      for (int op = 1; op <= 4; op++) if (cov_pass[op] == 0) miss = {miss, $sformatf(" pass%0d", op)};
      begin
        // SCL range (8) cannot fail alone: an aligned SCL ends at 2^32 at most (directed: with MISALIGN)
        automatic int rb[$] = '{0, 1, 2, 3, 4, 5, 6, 7, 16, 17, 18, 19};
        foreach (rb[k]) if (cov_reason[rb[k]] == 0) miss = {miss, $sformatf(" reason%0d", rb[k])};
      end
      for (int k = 0; k < 4; k++) if (cov_edge_ok[k] == 0 || cov_edge_bad[k] == 0) miss = {miss, $sformatf(" edge%0d", k)};
      for (int b = 0; b < 6; b++) if (cov_err[b] == 0) miss = {miss, $sformatf(" err%0d", b)};
      if (cov_sb_verdict == 0 || cov_sb_op == 0 || cov_done_acc == 0 || cov_done_clr == 0 || cov_wr_verdict == 0 || cov_w1c_set == 0)
        miss = {miss, " collisions"};
      if (miss != "") c_cov.fail({"coverage missing:", miss}); else c_cov.pass();
    end
    void'(tb_final_report('{c_rd, c_ctl, c_lat, c_st, c_cov}));
    $finish;
  end

  initial begin
    static longint unsigned lim = 64'd50_000_000;
    void'($value$plusargs("TIMEOUT=%d", lim));
    repeat (lim) @(posedge clk);
    $fatal(1, "TB_TIMEOUT tb_vec_csr");
  end

endmodule
