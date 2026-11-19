// tb_axi_wr_eng: axi_wr_eng (rtl/l1/axi_wr_eng.sv) against the AXI slave memory model.
//
// Reference = the memory contents themselves: the memory is filled with random bytes through
// the backdoor and a byte shadow is kept; every accepted command writes its input bytes into
// the shadow. After every command (done_o) its range and 8 guard bytes on each side are
// compared with the memory, and at every idle point the whole region (256 KiB + 8 KiB at the
// top of the address space) is compared. Commands in flight at the same time never overlap.
//
// Checkers
//   mem      memory == shadow (per command at done, whole region at idle points)
//   aw       every AW (address, length) equals the split rule of hierarchy.md 3.6
//   w        every W beat: data, WSTRB (8'hFF, partial on the last beat of a command), WLAST;
//            no W beat before the AW of its burst was accepted; WVALID stays high from the
//            first to the last beat of a burst (store and forward)
//   outs     bursts outstanding (AW handshake .. B handshake) <= the command's limit
//   bch      B never stalled (BREADY), buffer level (input beats - W beats) <= FIFO_DEPTH
//   status   done_o, busy_o, stall_o, err_resp_o, err_cmd_o every cycle vs a TB model
//   cov      buffer full while AW/W are blocked (+BLK), outstanding limit reached (+OREACH),
//            error responses seen (+ERRINJ), 1 beat/cycle on W (+TPUT=2)
//
// Plusargs: +SEED +PROF=<0|1|2> (memory AW/W/B stalls and B latency) +DGAP=<pct> (input
// gaps) +GAP=<pct> (command gaps) +N_CMD +MAXB +BLK +OREACH +TPUT +ERRINJ +NEG
`timescale 1ns / 1ps
module tb_axi_wr_eng #(
  parameter int MAX_BURST  = 16,
  parameter int OUTS       = 4,
  parameter int FIFO_DEPTH = 2 * MAX_BURST,
  parameter int LEN_W      = 32
);
  import tb_util_pkg::*;

  localparam longint unsigned BASE = 64'h2000_0000;
  localparam longint unsigned SIZE = 64'h4_0000;
  localparam longint unsigned TOPB = 64'hFFFF_E000;
  localparam int IDW = 1;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;
  longint unsigned cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  logic [8:0] cfg_burst = '0;
  logic [6:0] cfg_outs = '0;
  logic cmd_valid = 1'b0, cmd_ready;
  logic [31:0] cmd_addr = '0;
  logic [LEN_W-1:0] cmd_bytes = '0;
  logic in_valid = 1'b0, in_ready;
  logic [63:0] in_data = '0;
  logic busy, done, stall, err_resp, err_cmd, err_clr = 1'b0;
  logic [IDW-1:0] awid, bid, rid_n;
  logic [31:0] awaddr;
  logic [7:0] awlen, wstrb;
  logic [2:0] awsize, awprot;
  logic [1:0] awburst, bresp, rresp_n;
  logic awlock, awvalid, awready, wvalid, wready, wlast, bvalid, bready, arready_n, rlast_n, rvalid_n;
  logic [3:0] awcache, awqos;
  logic [63:0] wdata, rdata_n;

  axi_wr_eng #(.AW(32), .IDW(IDW), .LEN_W(LEN_W), .MAX_BURST(MAX_BURST), .OUTS(OUTS),
               .FIFO_DEPTH(FIFO_DEPTH)) dut (
    .clk, .rst_n,
    .cfg_burst_i(cfg_burst), .cfg_outs_i(cfg_outs),
    .cmd_valid_i(cmd_valid), .cmd_ready_o(cmd_ready), .cmd_addr_i(cmd_addr), .cmd_bytes_i(cmd_bytes),
    .in_valid_i(in_valid), .in_ready_o(in_ready), .in_data_i(in_data),
    .busy_o(busy), .done_o(done), .stall_o(stall), .err_resp_o(err_resp), .err_cmd_o(err_cmd),
    .err_clr_i(err_clr),
    .m_axi_awid_o(awid), .m_axi_awaddr_o(awaddr), .m_axi_awlen_o(awlen), .m_axi_awsize_o(awsize),
    .m_axi_awburst_o(awburst), .m_axi_awlock_o(awlock), .m_axi_awcache_o(awcache),
    .m_axi_awprot_o(awprot), .m_axi_awqos_o(awqos), .m_axi_awvalid_o(awvalid),
    .m_axi_awready_i(awready),
    .m_axi_wdata_o(wdata), .m_axi_wstrb_o(wstrb), .m_axi_wlast_o(wlast), .m_axi_wvalid_o(wvalid),
    .m_axi_wready_i(wready),
    .m_axi_bid_i(bid), .m_axi_bresp_i(bresp), .m_axi_bvalid_i(bvalid), .m_axi_bready_o(bready));

  axi_mem_slave #(.DW(64), .AW(32), .IDW(IDW), .MAX_LEN(MAX_BURST - 1), .MAX_OUTS(16),
                  .WBUF(64), .NAME("mem")) u_mem (
    .clk, .rst_n,
    .awid_i(awid), .awaddr_i(awaddr), .awlen_i(awlen), .awsize_i(awsize), .awburst_i(awburst),
    .awvalid_i(awvalid), .awready_o(awready),
    .wdata_i(wdata), .wstrb_i(wstrb), .wlast_i(wlast), .wvalid_i(wvalid), .wready_o(wready),
    .bid_o(bid), .bresp_o(bresp), .bvalid_o(bvalid), .bready_i(bready),
    .arid_i('0), .araddr_i('0), .arlen_i('0), .arsize_i(3'd3), .arburst_i(2'b01),
    .arvalid_i(1'b0), .arready_o(arready_n),
    .rid_o(rid_n), .rdata_o(rdata_n), .rresp_o(rresp_n), .rlast_o(rlast_n), .rvalid_o(rvalid_n),
    .rready_i(1'b1));

  tb_checker c_mem = new("mem"), c_aw = new("aw"), c_w = new("w"), c_outs = new("outs"),
             c_bch = new("bch"), c_stat = new("status"), c_cov = new("cov");

  // ---------------- model ----------------
  typedef struct {
    longint unsigned addr, bytes;
    int burst, outs;
    bit hold_drop;
    int chg_bytes;
  } cmd_t;
  typedef struct {
    longint unsigned addr;
    int len, olim;
    bit lastc;
  } aw_t;
  typedef struct {
    logic [63:0] d;
    logic [7:0] s;
    bit l;
  } wb_t;

  cmd_t cmd_todo[$];
  logic [63:0] din_todo[$];
  aw_t aw_exp[$], b_exp[$];
  wb_t w_exp[$];
  longint unsigned chk_lo[$], chk_hi[$];   // ranges to compare at the next done
  byte unsigned shadow[longint unsigned];
  int gap_pct = 0, dgap_pct = 0;
  bit neg_in_drop = 1'b0;
  longint unsigned n_cmd_ok = 0, n_cmd_bad = 0, n_wbeat = 0, n_aw = 0, n_done = 0, n_b = 0;

  function automatic int eff(int v, int mx);
    return (v == 0 || v > mx) ? mx : v;
  endfunction
  function automatic bit is_bad(longint unsigned a, longint unsigned b);
    return (a % 8) != 0 || b == 0 || a + b > 64'h1_0000_0000;
  endfunction

  // expectations of an accepted good command (WSTRB, WLAST, AW list). The W data are checked
  // against the accepted input beats in order (din_acc); the shadow is written by gen_data.
  logic [63:0] din_acc[$];
  function automatic void expect_cmd(longint unsigned a, longint unsigned b, int burst, int outs);
    longint unsigned nb = (b + 7) / 8, a0 = a;
    int bl = eff(burst, MAX_BURST), ol = eff(outs, OUTS);
    for (longint unsigned k = 0; k < nb; k++) begin
      wb_t e;
      int nby = (k == nb - 1 && b % 8 != 0) ? int'(b % 8) : 8;
      e.d = '0;
      e.s = 8'((9'd1 << nby) - 1);
      e.l = 1'b0;
      w_exp.push_back(e);
    end
    while (nb > 0) begin
      aw_t r;
      longint unsigned t4 = (4096 - (a % 4096)) / 8, n = nb;
      if (n > bl) n = bl;
      if (n > t4) n = t4;
      r.addr = a; r.len = int'(n) - 1; r.olim = ol; r.lastc = (n == nb);
      aw_exp.push_back(r);
      w_exp[w_exp.size() - nb + n - 1].l = 1'b1;
      a += 8 * n;
      nb -= n;
    end
    chk_lo.push_back(a0 - 8);
    chk_hi.push_back(a0 + b + 8);
  endfunction

  function automatic int cmp_range(longint unsigned lo, longint unsigned hi, string what);
    int bad = 0;
    for (longint unsigned x = lo; x < hi; x++) begin
      if (!shadow.exists(x)) continue;
      if (u_mem.bd_read8(x) !== shadow[x]) begin
        if (bad < 5) c_mem.fail($sformatf("%s byte 0x%0h mem %h exp %h", what, x, u_mem.bd_read8(x), shadow[x]));
        else c_mem.fail("");
        bad++;
      end else c_mem.pass();
    end
    return bad;
  endfunction

  // ---------------- drivers ----------------
  initial begin
    wait (rst_n);
    forever begin
      @(posedge clk);
      if (cmd_valid && cmd_ready) cmd_valid <= 1'b0;
      if ((!cmd_valid || cmd_ready) && cmd_todo.size() > 0 && !($urandom_range(99) < gap_pct)) begin
        cmd_t c;
        c = cmd_todo.pop_front();
        cmd_valid <= 1'b1;
        cmd_addr  <= c.addr[31:0];
        cmd_bytes <= LEN_W'(c.bytes);
        cfg_burst <= 9'(c.burst);
        cfg_outs  <= 7'(c.outs);
        if (c.hold_drop || c.chg_bytes > 0) begin
          repeat (3) @(posedge clk);
          if (cmd_ready) $error("TB_NEG engine became ready too early for the negative command");
          if (c.hold_drop) cmd_valid <= 1'b0;
          else cmd_bytes <= LEN_W'(c.chg_bytes);
        end
      end
    end
  end

  logic [63:0] din_cur;
  initial begin
    wait (rst_n);
    forever begin
      @(posedge clk);
      if (in_valid && in_ready) in_valid <= 1'b0;
      else if (in_valid && !in_ready && neg_in_drop) begin  // NEG 6: drop and present again
        neg_in_drop = 1'b0;
        in_valid <= 1'b0;
        din_todo.push_front(din_cur);
        continue;
      end
      if ((!in_valid || in_ready) && din_todo.size() > 0 && !($urandom_range(99) < dgap_pct)) begin
        din_cur = din_todo.pop_front();
        in_valid <= 1'b1;
        in_data  <= din_cur;
      end
    end
  end

  // ---------------- monitor (negedge) ----------------
  int outs_tb = 0, max_outs = 0, lvl = 0, max_lvl = 0, pend = 0, aw_beats = 0, w_in_burst = 0;
  bit exp_err_resp = 1'b0, exp_err_cmd = 1'b0;
  longint unsigned n_err_b = 0, t_first = 0, t_last = 0, n_err_clr = 0;
  bit tput_on = 1'b0;

  always @(negedge clk) if (rst_n) begin
    bit cmd_hs, aw_hs, w_hs, b_hs, in_hs, bad, b_last;
    cmd_hs = cmd_valid && cmd_ready;
    aw_hs  = awvalid && awready;
    w_hs   = wvalid && wready;
    b_hs   = bvalid && bready;
    in_hs  = in_valid && in_ready;
    bad    = cmd_hs && is_bad(cmd_addr, cmd_bytes);
    b_last = b_hs && b_exp.size() > 0 && b_exp[0].lastc;

    if (busy !== (pend != 0) || stall !== (in_valid && !in_ready) || done !== (b_last || bad) ||
        err_resp !== exp_err_resp || err_cmd !== exp_err_cmd)
      c_stat.fail($sformatf("cyc %0d busy %b (pend %0d) stall %b done %b err_resp %b/%b err_cmd %b/%b",
                            cyc, busy, pend, stall, done, err_resp, exp_err_resp, err_cmd, exp_err_cmd));
    else c_stat.pass();
    if (cmd_valid && is_bad(cmd_addr, cmd_bytes) && pend != 0 && cmd_ready)
      c_stat.fail($sformatf("cyc %0d rejected command accepted while busy", cyc));
    if ($isunknown({cmd_ready, in_ready, awvalid, wvalid, bready, busy, done, stall}))
      c_stat.fail($sformatf("cyc %0d X on a DUT control output", cyc));

    if (cmd_hs) begin
      if (bad) begin
        n_cmd_bad++;
        exp_err_cmd = 1'b1;
      end else begin
        n_cmd_ok++;
        expect_cmd(cmd_addr, cmd_bytes, cfg_burst, cfg_outs);
      end
    end

    if (aw_hs) begin
      n_aw++;
      if (aw_exp.size() == 0) c_aw.fail($sformatf("unexpected AW 0x%0h len %0d", awaddr, awlen));
      else begin
        aw_t e;
        e = aw_exp.pop_front();
        if (awaddr !== e.addr[31:0] || awlen !== 8'(e.len) || awsize !== 3'd3 || awburst !== 2'b01 ||
            awid !== '0 || awlock !== 1'b0 || awcache !== 4'b0011)
          c_aw.fail($sformatf("AW 0x%0h len %0d exp 0x%0h len %0d", awaddr, awlen, e.addr, e.len));
        else c_aw.pass();
        if (outs_tb + 1 > e.olim)
          c_outs.fail($sformatf("cyc %0d %0d bursts outstanding, limit %0d", cyc, outs_tb + 1, e.olim));
        else c_outs.pass();
        b_exp.push_back(e);
      end
      outs_tb++;
      if (outs_tb > max_outs) max_outs = outs_tb;
    end

    if (in_hs) din_acc.push_back(in_data);
    // W: continuity inside a burst, order after AW, payload
    if (w_in_burst > 0 && wvalid !== 1'b1)
      c_w.fail($sformatf("cyc %0d WVALID dropped inside a burst", cyc));
    if (w_hs) begin
      n_wbeat++;
      if (tput_on) begin
        if (t_first == 0) t_first = cyc;
        t_last = cyc;
      end
      if (aw_beats <= 0) c_w.fail($sformatf("cyc %0d W beat before the AW of its burst", cyc));
      if (w_exp.size() == 0) c_w.fail($sformatf("unexpected W beat %h", wdata));
      else begin
        wb_t e;
        e = w_exp.pop_front();
        e.d = din_acc.size() ? din_acc.pop_front() : 64'hx;
        if (wdata !== e.d || wstrb !== e.s || wlast !== e.l)
          c_w.fail($sformatf("W got %h strb %h last %b exp %h strb %h last %b", wdata, wstrb, wlast,
                             e.d, e.s, e.l));
        else c_w.pass();
      end
      aw_beats--;
      w_in_burst = wlast ? 0 : w_in_burst + 1;
    end
    if (aw_hs) aw_beats += int'(awlen) + 1;  // visible to W from the next cycle

    if (bvalid && !bready) c_bch.fail($sformatf("cyc %0d BVALID stalled", cyc));
    if (b_hs) begin
      n_b++;
      if (b_exp.size() == 0) c_bch.fail("B without a burst");
      else void'(b_exp.pop_front());
      if (bresp[1]) n_err_b++;
      if (bresp[1] && err_clr) n_err_clr++;
      outs_tb--;
    end
    lvl += int'(in_hs) - int'(w_hs);
    if (lvl > FIFO_DEPTH || lvl < 0) c_bch.fail($sformatf("cyc %0d buffer level %0d", cyc, lvl));
    else c_bch.pass();
    if (lvl > max_lvl) max_lvl = lvl;

    if (done) begin
      n_done++;
      if (!bad) begin
        if (chk_lo.size() == 0) c_mem.fail("done without a command");
        else void'(cmp_range(chk_lo.pop_front(), chk_hi.pop_front(), "done"));
      end
    end

    pend += int'(cmd_hs && !bad) - int'(b_last);
    if (b_hs && bresp[1]) exp_err_resp = 1'b1;
    else if (err_clr) exp_err_resp = 1'b0;
    if (!bad && err_clr) exp_err_cmd = 1'b0;
  end

  // ---------------- stimulus ----------------
  longint unsigned cursor = BASE;

  task automatic wait_idle(longint unsigned max_cyc = 5000000);
    longint unsigned c0 = cyc;
    while ((cmd_todo.size() || cmd_valid || din_todo.size() || in_valid || w_exp.size() ||
            aw_exp.size() || b_exp.size() || pend != 0 || busy) && cyc - c0 < max_cyc)
      @(posedge clk);
    if (cyc - c0 >= max_cyc) begin
      $error("TB_TIMEOUT cmd %0d din %0d w_exp %0d aw_exp %0d b_exp %0d pend %0d", cmd_todo.size(),
             din_todo.size(), w_exp.size(), aw_exp.size(), b_exp.size(), pend);
      $finish;
    end
    repeat (3) @(posedge clk);
  endtask

  task automatic full_check(string what);
    longint unsigned bad = 0;
    foreach (shadow[x]) if (u_mem.bd_read8(x) !== shadow[x]) begin
      if (bad < 5) c_mem.fail($sformatf("%s byte 0x%0h mem %h exp %h", what, x, u_mem.bd_read8(x), shadow[x]));
      else c_mem.fail("");
      bad++;
    end else c_mem.pass();
  endtask

  // input beats of a good command; the shadow gets its bytes now (commands in flight never
  // overlap, and the memory is compared only after the command is done)
  function automatic void gen_data(longint unsigned a, longint unsigned b);
    for (longint unsigned k = 0; k < (b + 7) / 8; k++) begin
      logic [63:0] d = {$urandom, $urandom};
      din_todo.push_back(d);
      for (int i = 0; i < 8; i++) if (8 * k + i < b) shadow[a + 8 * k + i] = d[8*i +: 8];
    end
  endfunction

  // one command; good commands also get their input beats
  task automatic push(longint unsigned a, longint unsigned b, int burst = 0, int outs = 0);
    cmd_t c;
    c.addr = a; c.bytes = b; c.burst = burst; c.outs = outs; c.hold_drop = 0; c.chg_bytes = 0;
    cmd_todo.push_back(c);
    if (!is_bad(a, b)) gen_data(a, b);
  endtask

  // next non-overlapping start for b bytes inside the region (waits for idle when it wraps)
  task automatic place(longint unsigned b, output longint unsigned a);
    longint unsigned c = cursor + 8 * $urandom_range(8);
    if ($urandom_range(3) == 0) c = ((c + 4095) & ~64'hFFF) - 8 * $urandom_range(3);  // near an edge
    if (c < cursor) c = cursor;
    if (c + b + 16 > BASE + SIZE) begin
      wait_idle();
      full_check("round");
      c = BASE + 8 + 8 * $urandom_range(8);
    end
    a = c;
    cursor = (c + b + 8 + 7) & ~64'h7;
  endtask

  function automatic int rnd_cfg(int mx);
    case ($urandom_range(9))
      0: return 0;
      1: return mx + 1 + $urandom_range(3);
      2, 3, 4: return mx;
      default: return $urandom_range(mx, 1);
    endcase
  endfunction

  task automatic directed();
    longint unsigned a;
    int mb8 = 8 * MAX_BURST;
    for (int b = 1; b <= 17; b++) begin place(b, a); push(a, b); end
    begin
      longint unsigned pg = BASE + 4096 * 40;
      wait_idle();
      push(pg, 1); push(pg + 64 - 8, 8); push(pg + 128, 9);
      push(pg + 4096 - 8, 16); push(pg + 2 * 4096 - 16, 4096 - 3); push(pg + 4 * 4096, 4096);
      push(pg + 6 * 4096 + 8, 4096); push(pg + 8 * 4096 + 4096 - mb8, mb8);
      push(pg + 9 * 4096 + 4096 - mb8 - 8, mb8 + 16); push(pg + 10 * 4096 + 16, mb8 - 1);
      push(pg + 11 * 4096, mb8 + 1); push(pg + 12 * 4096 + 4096 - 8, 3 * 4096 + 5, 1, 1);
      push(TOPB + 8192 - 64, 61);
      push(TOPB, 4096 + 7, 0, 0);
      wait_idle();
      full_check("directed");
    end
  endtask

  task automatic random_cmds(int n, longint unsigned maxb);
    for (int i = 0; i < n; i++) begin
      longint unsigned a, b;
      case ($urandom_range(9))
        0, 1, 2: b = $urandom_range(64, 1);
        3, 4:    b = $urandom_range(1024, 65);
        5, 6:    b = $urandom_range(16384, 1025);
        7:       b = $urandom_range(maxb > 16385 ? maxb : 16385, 16385);
        default: b = $urandom_range(3 * 8 * MAX_BURST + 16, 1);
      endcase
      if (b > maxb) b = maxb;
      place(b, a);
      push(a, b, rnd_cfg(MAX_BURST), rnd_cfg(OUTS));
      if ($urandom_range(30) == 0) begin
        @(posedge clk);
        err_clr <= 1'b1;
        @(posedge clk);
        err_clr <= 1'b0;
      end
    end
    wait_idle();
    full_check("random");
  endtask

  task automatic neg_test(int neg);
    cmd_t c;
    wait_idle();
    push(BASE + 8, 32 * 1024, MAX_BURST, OUTS);
    c.addr = BASE + 64 * 1024; c.bytes = 100; c.burst = 0; c.outs = 0; c.hold_drop = 0; c.chg_bytes = 0;
    case (neg)
      1: c.hold_drop = 1;
      2: c.chg_bytes = 200;
      3: c.addr = BASE + 64 * 1024 + 4;
      4: c.bytes = 0;
      5: begin c.addr = 64'hFFFF_FFF8; c.bytes = 16; end
      6: ;  // VR_HOLD on the data input: see below
      default: $error("TB_BADNEG unknown +NEG=%0d", neg);
    endcase
    cmd_todo.push_back(c);
    if (!is_bad(c.addr, c.bytes) && !c.hold_drop)
      gen_data(c.addr, c.chg_bytes > 0 ? c.chg_bytes : c.bytes);
    if (neg == 6) begin  // block the write side so that the input waits, then drop it once
      u_mem.cfg_stall(0, 100, 100, 0, 0);
      neg_in_drop = 1'b1;
      repeat (FIFO_DEPTH + 200) @(posedge clk);
      u_mem.cfg_stall(0, 0, 0, 0, 0);
    end
    push(BASE + 128 * 1024, 64);
    wait_idle();
    full_check("neg");
  endtask

  initial begin
    int unsigned seed;
    int prof, n_cmd, neg, blk, oreach, tput, errinj;
    longint unsigned maxb;
    prof = 1; n_cmd = 400; neg = 0; blk = 0; oreach = 0; tput = 0; errinj = 0; maxb = 40960;
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("PROF=%d", prof));
    void'($value$plusargs("DGAP=%d", dgap_pct));
    void'($value$plusargs("GAP=%d", gap_pct));
    void'($value$plusargs("N_CMD=%d", n_cmd));
    void'($value$plusargs("MAXB=%d", maxb));
    void'($value$plusargs("BLK=%d", blk));
    void'($value$plusargs("OREACH=%d", oreach));
    void'($value$plusargs("TPUT=%d", tput));
    void'($value$plusargs("ERRINJ=%d", errinj));
    void'($value$plusargs("NEG=%d", neg));
    $display("tb_axi_wr_eng: SEED %0d MAX_BURST %0d OUTS %0d FIFO_DEPTH %0d PROF %0d DGAP %0d GAP %0d N_CMD %0d BLK %0d OREACH %0d TPUT %0d ERRINJ %0d NEG %0d",
             seed, MAX_BURST, OUTS, FIFO_DEPTH, prof, dgap_pct, gap_pct, n_cmd, blk, oreach, tput, errinj, neg);
    case (prof)
      0: begin u_mem.cfg_stall(0, 0, 0, 0, 0); u_mem.cfg_lat(1, 1, 1, 1); end
      1: begin u_mem.cfg_stall(0, 30, 30, 0, 30); u_mem.cfg_lat(1, 1, 1, 20); end
      default: begin u_mem.cfg_stall(0, 70, 70, 0, 70); u_mem.cfg_lat(1, 1, 1, 60); end
    endcase
    for (longint unsigned i = 0; i < SIZE; i++) begin
      automatic byte unsigned v = 8'($urandom);
      u_mem.bd_write8(BASE + i, v);
      shadow[BASE + i] = v;
    end
    for (longint unsigned i = 0; i < 8192; i++) begin
      automatic byte unsigned v = 8'($urandom);
      u_mem.bd_write8(TOPB + i, v);
      shadow[TOPB + i] = v;
    end
    if (errinj) begin
      u_mem.inj_wr_err(BASE + 8192, BASE + 8192 + 256, 2'b10);
      u_mem.inj_wr_err(BASE + 65536 - 8, BASE + 65536 + 8, 2'b11);
      u_mem.inj_wr_err(BASE + 160000, BASE + 170000, 2'b10);
    end
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);

    directed();
    random_cmds(n_cmd, maxb);
    if (errinj) begin
      wait_idle();
      push(BASE + 8192 - 64, 512);
      push(BASE + 160000 - 8000, 20000, 0, 0);
      wait_idle();
      @(posedge clk); err_clr <= 1'b1; @(posedge clk); err_clr <= 1'b0;
      repeat (2) @(posedge clk);
      if (n_err_b == 0) c_cov.fail("no error response seen");
      else c_cov.pass();
      // err_clr_i held high while error responses arrive: the new error must win in that cycle
      @(posedge clk); err_clr <= 1'b1;
      begin
        longint unsigned a;
        place(512, a);
        u_mem.inj_wr_err(a + 64, a + 72, 2'b10);
        push(a, 512);
        place(128, a);
        u_mem.inj_wr_err(a, a + 8, 2'b11);
        push(a, 128);
      end
      wait_idle();
      @(posedge clk); err_clr <= 1'b0;
      repeat (2) @(posedge clk);
      if (n_err_clr == 0) c_cov.fail("no error response in a cycle with err_clr_i");
      else c_cov.pass();
    end

    if (blk) begin
      // (a) AW and W blocked while a long command streams in: the buffer must become full
      // (b) blocks in the middle of random traffic
      wait_idle();
      u_mem.cfg_stall(0, 100, 100, 0, 0);
      push(BASE + 4096, 24 * 1024, 0, 0);
      repeat (FIFO_DEPTH * 4 + 500) @(posedge clk);
      if (max_lvl != FIFO_DEPTH) c_cov.fail($sformatf("buffer not full: max level %0d of %0d", max_lvl, FIFO_DEPTH));
      else c_cov.pass();
      u_mem.cfg_stall(0, 0, 0, 0, 0);
      wait_idle();
      for (int r = 0; r < 3; r++) begin
        longint unsigned a;
        place(9 * 1024, a);
        push(a, 9 * 1024, $urandom_range(MAX_BURST, 1), 0);
        place(20 * 1024 + 8 * r, a);
        push(a, 20 * 1024 + 8 * r, 0, 0);
        repeat (50) @(posedge clk);
        u_mem.cfg_stall(0, 100 * (r % 2), 100, 0, 100 * (r / 2));
        repeat (2000) @(posedge clk);
        u_mem.cfg_stall(0, 30, 30, 0, 30);
        wait_idle();
      end
      full_check("blk");
      $display("BLK buffer max level %0d of FIFO_DEPTH %0d", max_lvl, FIFO_DEPTH);
    end

    if (oreach) begin  // long B latency: the outstanding limit is the bound
      wait_idle();
      dgap_pct = 0;
      u_mem.cfg_stall(0, 0, 0, 0, 0);
      // B latency longer than OUTS bursts of W beats, so that the limit is what stops the AWs
      u_mem.cfg_lat(1, 1, 400 + 2 * OUTS * MAX_BURST, 400 + 2 * OUTS * MAX_BURST);
      max_outs = 0;
      push(BASE + 4096, 64 * 1024, MAX_BURST, OUTS);
      wait_idle();
      if (max_outs != OUTS) c_cov.fail($sformatf("max outstanding %0d, OUTS %0d", max_outs, OUTS));
      else c_cov.pass();
      $display("OREACH outstanding reached %0d (OUTS %0d)", max_outs, OUTS);
      full_check("oreach");
    end

    if (tput) begin
      longint unsigned c0, nb;
      int bls[$];
      bls = '{MAX_BURST};
      if (MAX_BURST > 16) bls.push_back(16);
      dgap_pct = 0;
      u_mem.cfg_stall(0, 0, 0, 0, 0);
      foreach (bls[i]) for (int o = 1; o <= OUTS; o = o * 2) for (int lat = 1; lat <= 33; lat += 32) begin
        wait_idle();
        u_mem.cfg_lat(1, 1, lat, lat);
        nb = 8192;
        t_first = 0; t_last = 0; tput_on = 1'b1;
        c0 = cyc;
        push(BASE + 4096, 8 * nb, bls[i], o);
        wait_idle();
        tput_on = 1'b0;
        $display("TPUT blen %0d outs %0d b_lat %0d beats %0d W first..last %0d cycles (%.3f beats/cycle) cmd..idle %0d cycles",
                 bls[i], o, lat, nb, t_last - t_first + 1, real'(nb) / real'(t_last - t_first + 1), cyc - c0);
        if (tput >= 2 && lat == 1 && o == OUTS && bls[i] == MAX_BURST) begin
          if (t_last - t_first + 1 != nb)
            c_cov.fail($sformatf("throughput %0d beats in %0d cycles (expected 1 beat/cycle)", nb, t_last - t_first + 1));
          else c_cov.pass();
        end
      end
      full_check("tput");
    end

    if (neg != 0) neg_test(neg);

    wait_idle();
    full_check("end");
    c_cov.pass();
    if (w_exp.size() || aw_exp.size() || b_exp.size() || cmd_todo.size() || din_todo.size() ||
        din_acc.size() || pend != 0 || lvl != 0 || outs_tb != 0 || chk_lo.size())
      c_mem.fail($sformatf("left over: w %0d aw %0d b %0d cmd %0d din %0d acc %0d pend %0d lvl %0d outs %0d chk %0d",
                           w_exp.size(), aw_exp.size(), b_exp.size(), cmd_todo.size(), din_todo.size(),
                           din_acc.size(), pend, lvl, outs_tb, chk_lo.size()));
    if (n_done != n_cmd_ok + n_cmd_bad) c_stat.fail($sformatf("done pulses %0d, commands %0d", n_done, n_cmd_ok + n_cmd_bad));
    u_mem.check_idle();
    u_mem.report();
    $display("tb_axi_wr_eng: commands %0d (+%0d rejected), AW %0d, W beats %0d, B %0d, max outstanding %0d, max buffer level %0d/%0d, error responses %0d",
             n_cmd_ok, n_cmd_bad, n_aw, n_wbeat, n_b, max_outs, max_lvl, FIFO_DEPTH, n_err_b);
    void'(tb_final_report('{c_mem, c_aw, c_w, c_outs, c_bch, c_stat, c_cov}));
    $finish;
  end

  initial begin
    #2s;
    $error("TB_TIMEOUT global");
    $finish;
  end

endmodule
