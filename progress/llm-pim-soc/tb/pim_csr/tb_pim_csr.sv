// tb_pim_csr: pim_csr (rtl/l3/pim_csr.sv) alone against a register-file model written from
// docs/spec/pim.md (register map, command format, push check, run rules).
//
// Every cycle the TB drives (posedge, non-blocking) a random register access interface (write
// strobe with random address / data, read strobe with random address), random FIFO status
// (fifo_ready_i, fifo_level_i) and random events (done_i only while the model is busy, AXI errors,
// stalls, MAC / WRGB / RDMAC events, command done pulses one at a time). At negedge it compares:
// rd_data_o of the presented read address, start_o, busy_o, run_flush_o, push_o and push_data_o,
// push_busy_o. Push timing (pim.md 4.1, S4-6b): a CMD_PUSH write in c without a check in progress
// takes a copy of CMD0..3; the verdict on the copy (push_o or BAD_CMD / BAD_DESC / MISALIGN /
// FIFO_OVF with fifo_ready_i of that cycle) is in p = c + PCHK, PCHK = max(bits(ceil(NMAX/16)),
// bits(ceil(NMAX/8) + 1)) + 1; a CMD_PUSH in c + 1 .. p sets PUSH_BUSY (bit 8) and is ignored;
// STATUS bit3 = check in progress.
// Command words draw from legal and illegal values: op 0..15 (mostly 1..3), n 0 / 1 / NMAX /
// NMAX + 1 / 4095, rows 0 / 1 / 65535, base so that the bank range ends exactly at DEPTH (+- 1),
// addresses unaligned and with the DDR range ending exactly at 2^32 (+- 8) for the op's length.
// Coverage counted and required: pushes, every ERR bit, each BAD_DESC reason, both 2^32 and DEPTH
// edges accepted, START_BUSY (also with an illegal op), CTRL in the done cycle (start 0 / 1),
// W1C against a set of the same bit, FLUSH runs.
// Plusargs: +SEED +N_CYC +PDONE +PEV
`timescale 1ns / 1ps
module tb_pim_csr #(
  parameter int NB    = 4,
  parameter int DEPTH = 4096,
  parameter int NMAX  = 1024,
  parameter int CMD_DEPTH = 32
);
  import tb_util_pkg::*;
  import llm_pkg::*;

  localparam int ADDR_W = 12, LV_W = $clog2(CMD_DEPTH + 1);
  localparam int A_ID = 'h00, A_CONFIG = 'h04, A_CTRL = 'h08, A_STATUS = 'h0C, A_ERR = 'h10,
                 A_CYCLES = 'h14, A_RDSTALL = 'h18, A_WRSTALL = 'h1C, A_OPS = 'h20, A_CONFIG2 = 'h24,
                 A_CMD0 = 'h40, A_CMD1 = 'h44, A_CMD2 = 'h48, A_CMD3 = 'h4C, A_PUSH = 'h50,
                 A_STWRGB = 'h60, A_STMAC = 'h64, A_STRDMAC = 'h68, A_NLDW = 'h6C, A_NWRGB = 'h70,
                 A_NMACAB = 'h74;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic              wr_en = 0, rd_en = 0, fifo_ready = 1, done_i = 0, rd_err = 0, wr_err = 0;
  logic              rd_stall = 0, wr_stall = 0, ev_mac = 0, ev_wrgb = 0, ev_rdmac = 0;
  logic              dn_ldw = 0, dn_wrgb = 0, dn_mac = 0;
  logic [ADDR_W-1:0] wr_addr = 0, rd_addr = 0;
  logic [31:0]       wr_data = 0, rd_data;
  logic [LV_W-1:0]   fifo_level = 0;
  logic              push, start, busy, flush, push_busy;
  logic [127:0]      push_data;

  pim_csr #(.ADDR_W(ADDR_W), .NB(NB), .LB(16), .DEPTH(DEPTH), .NMAX(NMAX), .CMD_DEPTH(CMD_DEPTH),
            .FCLK_MHZ(100)) dut (
    .clk, .rst_n,
    .wr_en_i(wr_en), .wr_addr_i(wr_addr), .wr_data_i(wr_data),
    .rd_en_i(rd_en), .rd_addr_i(rd_addr), .rd_data_o(rd_data),
    .push_o(push), .push_data_o(push_data), .fifo_ready_i(fifo_ready), .fifo_level_i(fifo_level),
    .start_o(start), .busy_o(busy), .push_busy_o(push_busy), .run_flush_o(flush), .done_i(done_i),
    .rd_err_i(rd_err), .wr_err_i(wr_err), .rd_stall_i(rd_stall), .wr_stall_i(wr_stall),
    .ev_mac_i(ev_mac), .ev_wrgb_i(ev_wrgb), .ev_rdmac_i(ev_rdmac), .done_ldw_i(dn_ldw),
    .done_wrgb_i(dn_wrgb), .done_mac_i(dn_mac));

  tb_checker c_rd = new("read_data"), c_ctl = new("start_busy"), c_push = new("push"),
             c_cov = new("coverage");

  // ---------------- model ----------------
  localparam int PCHK = (($clog2((NMAX + 15) / 16 + 1) > $clog2((NMAX + 7) / 8 + 2)) ?
                         $clog2((NMAX + 15) / 16 + 1) : $clog2((NMAX + 7) / 8 + 2)) + 1;
  logic [31:0] m_cmd[4], p_cmd[4], ck[4];   // registers, copy of the checked push, view of the checks
  int          m_pchk = 0;
  bit          m_busy, m_done, m_flush;
  logic [8:0]  m_err;
  logic [31:0] m_cyc, m_rdst, m_wrst, m_ops, m_stw, m_stm, m_str, m_nl, m_nx, m_nm;

  function automatic void model_reset();
    m_cmd = '{0, 0, 0, 0}; p_cmd = '{0, 0, 0, 0}; ck = '{0, 0, 0, 0}; m_pchk = 0;
    m_busy = 0; m_done = 0; m_flush = 0; m_err = 0;
    m_cyc = 0; m_rdst = 0; m_wrst = 0; m_ops = 0; m_stw = 0; m_stm = 0; m_str = 0;
    m_nl = 0; m_nx = 0; m_nm = 0;
  endfunction

  function automatic logic [31:0] model_read(int a);
    if (a >= 256) return 0;
    case (a & ~3)
      A_ID:      return 32'h5049_0001;
      A_CONFIG:  return {16'(NMAX), 4'd4, 4'(NB), 8'd100};
      A_STATUS:  return {8'd0, 16'(fifo_level), 4'd0, m_pchk != 0, m_err != 0, m_done, m_busy};
      A_ERR:     return 32'(m_err);
      A_CYCLES:  return m_cyc;
      A_RDSTALL: return m_rdst;
      A_WRSTALL: return m_wrst;
      A_OPS:     return m_ops;
      A_CONFIG2: return {16'(CMD_DEPTH), 16'(DEPTH)};
      A_CMD0:    return m_cmd[0];
      A_CMD1:    return m_cmd[1];
      A_CMD2:    return m_cmd[2];
      A_CMD3:    return m_cmd[3];
      A_STWRGB:  return m_stw;
      A_STMAC:   return m_stm;
      A_STRDMAC: return m_str;
      A_NLDW:    return m_nl;
      A_NWRGB:   return m_nx;
      A_NMACAB:  return m_nm;
      default:   return 0;
    endcase
  endfunction

  // command fields and checks (pim.md) of the command in ck
  function automatic int f_op();   return ck[0][3:0]; endfunction
  function automatic int f_n();    return ck[0][15:4]; endfunction
  function automatic int f_rows(); return ck[0][31:16]; endfunction
  function automatic int f_base(); return ck[1][31:17]; endfunction
  function automatic longint unsigned ddr_len();
    case (f_op())
      1: return longint'(f_rows()) * 8 * (1 + (f_n() + 7) / 8);
      2: return longint'(f_n());
      default: return 4 * longint'(f_rows());
    endcase
  endfunction
  function automatic longint used();
    return longint'((f_rows() + NB - 1) / NB) * ((f_n() + 15) / 16);
  endfunction
  function automatic bit is_op(); return f_op() >= 1 && f_op() <= 3; endfunction
  // BAD_DESC reasons: 0 n, 1 rows, 2 bank range, 3 DDR range
  function automatic logic [3:0] desc_bad();
    logic [3:0] b = '0;
    b[0] = f_n() == 0 || f_n() > NMAX;
    b[1] = f_op() != 2 && f_rows() == 0;
    b[2] = f_op() != 2 && longint'(f_base()) + used() > DEPTH;
    b[3] = longint'(ck[2]) + ddr_len() > 64'h1_0000_0000;
    return b;
  endfunction
  function automatic bit align_ok(); return ck[2][2:0] == 0; endfunction

  longint n_start = 0, n_flush = 0, n_busy_start = 0, n_badop_busy = 0, n_ctrl_done0 = 0,
          n_ctrl_done1 = 0, n_w1c_set = 0, n_push = 0, n_err[9], n_desc[4], n_edge_ddr[3], n_edge_base = 0,
          n_push_reg_diff = 0;

  always @(negedge clk) if (rst_n) begin
    bit ctrl, start_req, idle, op_ok, st, w1c, preq, pok, pacc, pverd;
    logic [8:0] set, clr;
    logic [3:0] db;
    logic [31:0] e;
    e = model_read(int'(rd_addr));
    if (rd_data !== e) c_rd.fail($sformatf("rd_addr 0x%03h: %h, model %h", rd_addr, rd_data, e));
    else c_rd.pass();
    ctrl      = wr_en && wr_addr < 256 && (wr_addr & ~3) == A_CTRL;
    start_req = ctrl && wr_data[0];
    idle      = !m_busy || done_i;
    op_ok     = wr_data[7:4] == 1 || wr_data[7:4] == 2;
    st        = start_req && idle && op_ok;
    if (start !== st || busy !== m_busy || (m_busy && flush !== m_flush))
      c_ctl.fail($sformatf("start_o %b busy_o %b flush %b, model %b %b %b", start, busy, flush, st, m_busy, m_flush));
    else c_ctl.pass();
    // push: accepted in c, verdict on the copy in p
    preq  = wr_en && wr_addr < 256 && (wr_addr & ~3) == A_PUSH;
    pacc  = preq && m_pchk == 0;
    pverd = m_pchk == 1;
    ck    = p_cmd;
    db    = desc_bad();
    pok   = pverd && is_op() && db == 0 && align_ok() && fifo_ready;
    if (push !== pok || (pok && push_data !== {p_cmd[3], p_cmd[2], p_cmd[1], p_cmd[0]}) ||
        push_busy !== (m_pchk != 0))
      c_push.fail($sformatf("push %b data %h push_busy %b, model %b %h %b", push, push_data, push_busy, pok,
                            {p_cmd[3], p_cmd[2], p_cmd[1], p_cmd[0]}, m_pchk != 0));
    else c_push.pass();
    // coverage
    if (pok) begin
      n_push++;
      if (longint'(p_cmd[2]) + ddr_len() == 64'h1_0000_0000) n_edge_ddr[f_op() - 1]++;
      if (f_op() != 2 && longint'(f_base()) + used() == DEPTH) n_edge_base++;
    end
    if (pverd && is_op()) for (int i = 0; i < 4; i++) if (db[i] && (db & ~(4'b1 << i)) == 0) n_desc[i]++;
    if (pverd && {m_cmd[3], m_cmd[2], m_cmd[1], m_cmd[0]} != {p_cmd[3], p_cmd[2], p_cmd[1], p_cmd[0]}) n_push_reg_diff++;
    if (st) begin n_start++; if (wr_data[7:4] == 2) n_flush++; end
    if (start_req && !idle) n_busy_start++;
    if (start_req && !idle && !op_ok) n_badop_busy++;
    if (ctrl && done_i) begin if (wr_data[0]) n_ctrl_done1++; else n_ctrl_done0++; end
    // ERR
    set = '0;
    set[0] = start_req && !idle;
    set[1] = start_req && !op_ok;
    set[2] = pverd && !is_op();
    set[3] = pverd && is_op() && db != 0;
    set[4] = pverd && is_op() && !align_ok();
    set[5] = rd_err;
    set[6] = wr_err;
    set[7] = pverd && is_op() && db == 0 && align_ok() && !fifo_ready;
    set[8] = preq && m_pchk != 0;
    w1c = wr_en && wr_addr < 256 && (wr_addr & ~3) == A_ERR;
    clr = w1c ? wr_data[8:0] : '0;
    if ((set & clr) != 0) n_w1c_set++;
    for (int b = 0; b < 9; b++) if (set[b]) n_err[b]++;
    // next state
    if (ctrl && idle && !(wr_data[0] && !op_ok)) m_done = 0;
    else if (done_i) m_done = 1;
    m_err = (m_err & ~clr) | set;
    if (st) begin m_cyc = 0; m_rdst = 0; m_wrst = 0; end
    else if (m_busy) begin
      m_cyc++;
      if (rd_stall) m_rdst++;
      if (wr_stall) m_wrst++;
    end
    if (dn_ldw || dn_wrgb || dn_mac) m_ops++;
    m_stw += ev_wrgb; m_stm += ev_mac; m_str += ev_rdmac;
    m_nl += dn_ldw; m_nx += dn_wrgb; m_nm += dn_mac;
    if (st) begin m_busy = 1; m_flush = wr_data[7:4] == 2; end
    else if (done_i) m_busy = 0;
    if (pacc) begin m_pchk = PCHK; p_cmd = m_cmd; end
    else if (m_pchk != 0) m_pchk--;
    if (wr_en && wr_addr < 256 && (wr_addr & ~3) >= A_CMD0 && (wr_addr & ~3) <= A_CMD3)
      m_cmd[((wr_addr & ~3) - A_CMD0) / 4] = wr_data;
  end

  // ---------------- stimulus ----------------
  int pdone = 5, pev = 30;
  int addrs[] = '{A_ID, A_CONFIG, A_CTRL, A_STATUS, A_ERR, A_CYCLES, A_RDSTALL, A_WRSTALL, A_OPS,
                  A_CONFIG2, A_CMD0, A_CMD1, A_CMD2, A_CMD3, A_PUSH, A_STWRGB, A_STMAC, A_STRDMAC,
                  A_NLDW, A_NWRGB, A_NMACAB, 'h28, 'h3C, 'h54, 'h5C, 'h78, 'hFC, 'h100, 'hFFC};

  function automatic logic [31:0] rnd_val(int a);
    int k = $urandom_range(11);
    ck = m_cmd;                       // edge values from the current registers
    case (a)
      A_CMD0: begin
        int op = k < 9 ? $urandom_range(3, 1) : $urandom_range(15);
        int n  = (k == 0) ? 0 : (k == 1 ? NMAX + 1 : (k == 2 ? NMAX : (k == 3 ? 4095 : (k == 4 ? 1 : $urandom_range(NMAX, 1)))));
        int r  = (k == 5) ? 0 : (k == 6 ? 65535 : (k == 7 ? 1 : $urandom_range(400, 1)));
        return {16'(r), 12'(n), 4'(op)};
      end
      A_CMD1: begin
        int b;
        longint u = used();
        if (k < 4 && u <= DEPTH) b = int'(DEPTH - u) + (k == 0 ? 1 : 0) - (k == 1 ? 1 : 0);   // range edge
        else if (k == 4) b = 32767;
        else b = $urandom_range(DEPTH - 1);
        return {15'(b), 17'($urandom)};
      end
      A_CMD2: case (k)
          0, 1, 2: return 32'(64'h1_0000_0000 - ddr_len() + 8 * (longint'($urandom_range(2)) - 1));
          3: return $urandom;
          4: return 8 * $urandom_range(1000) + $urandom_range(7, 1);
          default: return 8 * $urandom_range(32'h0FFF_FFFF);
        endcase
      A_CTRL: return k < 6 ? {24'($urandom_range(31)), 4'($urandom_range(2, 1)), 3'($urandom), 1'b1} :
                     (k < 8 ? {24'($urandom), 4'($urandom), 3'($urandom), 1'($urandom)} : 32'h10);
      A_ERR: return k < 6 ? 32'h1FF : $urandom;
      default: return $urandom;
    endcase
  endfunction

  int unsigned seed;
  longint n_cyc = 200000;

  initial begin
    foreach (n_err[i]) n_err[i] = 0;
    foreach (n_desc[i]) n_desc[i] = 0;
    foreach (n_edge_ddr[i]) n_edge_ddr[i] = 0;
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("N_CYC=%d", n_cyc));
    void'($value$plusargs("PDONE=%d", pdone));
    void'($value$plusargs("PEV=%d", pev));
    $display("tb_pim_csr: NB %0d DEPTH %0d NMAX %0d CMD_DEPTH %0d SEED %0d N_CYC %0d PDONE %0d PEV %0d",
             NB, DEPTH, NMAX, CMD_DEPTH, seed, n_cyc, pdone, pev);
    model_reset();
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    for (longint i = 0; i < n_cyc; i++) begin
      @(posedge clk);
      begin
        automatic int a = addrs[$urandom_range(addrs.size() - 1)];
        automatic int k = $urandom_range(19);
        automatic int d = $urandom_range(2);
        if (k < 3) a = A_CTRL;
        else if (k < 5) a = A_ERR;
        else if (k < 9) a = A_PUSH;
        else if (k < 15) a = A_CMD0 + 4 * $urandom_range(3);
        wr_en   <= $urandom_range(2) != 0;
        wr_addr <= ADDR_W'(a + ($urandom_range(7) == 0 ? $urandom_range(3) : 0));
        wr_data <= rnd_val(a);
        rd_en   <= $urandom_range(1);
        rd_addr <= ADDR_W'(addrs[$urandom_range(addrs.size() - 1)] + $urandom_range(3));
        fifo_ready <= $urandom_range(9) != 0;
        fifo_level <= LV_W'($urandom_range(CMD_DEPTH));
        done_i   <= m_busy && $urandom_range(99) < pdone;
        rd_err   <= $urandom_range(99) < pev / 3;
        wr_err   <= $urandom_range(99) < pev / 3;
        rd_stall <= $urandom_range(99) < pev;
        wr_stall <= $urandom_range(99) < pev;
        ev_mac   <= $urandom_range(99) < pev;
        ev_wrgb  <= $urandom_range(99) < pev;
        ev_rdmac <= $urandom_range(99) < pev;
        dn_ldw   <= d == 0 && $urandom_range(99) < pev;
        dn_wrgb  <= d == 1 && $urandom_range(99) < pev;
        dn_mac   <= d == 2 && $urandom_range(99) < pev;
      end
    end
    @(posedge clk);
    wr_en <= 0; rd_en <= 0; done_i <= 0;
    repeat (2) @(posedge clk);
    $display("coverage: starts %0d (flush %0d), pushes %0d, START_BUSY %0d (bad op %0d), CTRL at done %0d/%0d, W1C vs set %0d",
             n_start, n_flush, n_push, n_busy_start, n_badop_busy, n_ctrl_done0, n_ctrl_done1, n_w1c_set);
    $display("ERR sets %p, BAD_DESC single reasons (n, rows, bank, ddr) %p, accepted edges ddr (LDW, WRGB, MACAB) %p bank %0d, CMD written during the push check %0d",
             n_err, n_desc, n_edge_ddr, n_edge_base, n_push_reg_diff);
    if (n_push_reg_diff == 0) c_cov.fail("no CMD write during a push check"); else c_cov.pass();
    if (n_start < 20 || n_flush == 0 || n_push < 20 || n_busy_start == 0 || n_badop_busy == 0 ||
        n_ctrl_done0 == 0 || n_ctrl_done1 == 0 || n_w1c_set == 0)
      c_cov.fail("a run / push / collision case did not happen");
    else c_cov.pass();
    foreach (n_err[b]) if (n_err[b] == 0) c_cov.fail($sformatf("ERR bit %0d never set", b)); else c_cov.pass();
    foreach (n_desc[b]) if (n_desc[b] == 0) c_cov.fail($sformatf("BAD_DESC reason %0d never alone", b)); else c_cov.pass();
    foreach (n_edge_ddr[b]) if (n_edge_ddr[b] == 0) c_cov.fail($sformatf("2^32 edge op %0d never accepted", b + 1)); else c_cov.pass();
    if (n_edge_base == 0) c_cov.fail("DEPTH edge never accepted"); else c_cov.pass();
    void'(tb_final_report('{c_rd, c_ctl, c_push, c_cov}));
    $finish;
  end
endmodule
