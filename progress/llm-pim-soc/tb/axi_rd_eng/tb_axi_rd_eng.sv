// tb_axi_rd_eng: axi_rd_eng (rtl/l1/axi_rd_eng.sv) against the AXI slave memory model.
//
// Reference = the memory contents themselves: every delivered beat k of a command must equal
// the 64-bit word at addr + 8k (backdoor read of tb/common/axi_mem_slave.sv), d_last on beat
// n-1 only. The memory is filled through the backdoor before the test and never written, and
// reads of unwritten bytes are errors (AXI_UNINIT).
//
// Checkers
//   data     delivered beats and d_last vs memory
//   ar       every AR (address, length) equals the split rule of hierarchy.md 3.6, computed
//            here from the command (min(remaining, burst limit, beats to 4 KiB)); the burst
//            limit and outstanding limit are the clamped cfg values of the command
//   outs     bursts outstanding (AR handshake .. RLAST handshake) <= the command's limit
//   rch      R never stalled by the engine (RVALID && !RREADY), buffer level (R beats -
//            delivered beats) never above FIFO_DEPTH
//   status   done_o, stall_o, busy_o, err_resp_o, err_cmd_o every cycle vs a TB model
//   cov      coverage that must be reached: buffer full (+BLK), outstanding limit reached
//            (+OREACH), error beats seen (+ERRINJ), 1 beat/cycle (+TPUT=2)
// The protocol assertions of the memory model (AXI_*) and the engine (ENG_*, VR_*) count as
// errors in sim/run.sh.
//
// Phases: directed commands (sizes 1..17 and around MAX_BURST, 4 KiB boundary before/after,
// exact pages, top of the address space), N_CMD random commands (1 B .. MAXB bytes, 4 KiB
// edges, random cfg incl. 0 and out-of-range values, back-to-back or random gaps), then the
// optional phases: BLK (consumer blocked for thousands of cycles during long reads, buffer
// must fill), OREACH (long memory latency, limit OUTS must be reached), TPUT (throughput of a
// 64 KiB read without stalls, printed; TPUT=2 also requires exactly 1 beat/cycle between the
// first and last beat), NEG (one rejected or illegal command, see neg_test).
//
// Plusargs: +SEED +PROF=<0|1|2> (memory stalls/latency) +DPROF=<0|1|2> (consumer ready:
// always, 70 %, 30 %) +GAP=<pct> (command gaps) +N_CMD +MAXB +BLK +OREACH +TPUT +ERRINJ +NEG
`timescale 1ns / 1ps
module tb_axi_rd_eng #(
  parameter int MAX_BURST  = 16,
  parameter int OUTS       = 4,
  parameter int FIFO_DEPTH = MAX_BURST * OUTS,
  parameter int LEN_W      = 32
);
  import tb_util_pkg::*;

  localparam longint unsigned BASE = 64'h1000_0000;
  localparam longint unsigned SIZE = 64'h4_0000;       // 256 KiB filled region
  localparam longint unsigned TOPB = 64'hFFFF_E000;    // top-of-space region (8 KiB)
  localparam int IDW = 1;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;
  longint unsigned cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // DUT ports
  logic [8:0] cfg_burst = '0;
  logic [6:0] cfg_outs = '0;
  logic cmd_valid = 1'b0, cmd_ready;
  logic [31:0] cmd_addr = '0;
  logic [LEN_W-1:0] cmd_bytes = '0;
  logic d_valid, d_ready = 1'b0, d_last;
  logic [63:0] d_data;
  logic busy, done, stall, err_resp, err_cmd, err_clr = 1'b0;
  logic [IDW-1:0] arid, rid, awid_n, bid_n;
  logic [31:0] araddr;
  logic [7:0] arlen;
  logic [2:0] arsize, arprot;
  logic [1:0] arburst, rresp, bresp_n;
  logic arlock;
  logic [3:0] arcache, arqos;
  logic arvalid, arready, rvalid, rready, rlast, awready_n, wready_n, bvalid_n;
  logic [63:0] rdata;

  axi_rd_eng #(.AW(32), .IDW(IDW), .LEN_W(LEN_W), .MAX_BURST(MAX_BURST), .OUTS(OUTS),
               .FIFO_DEPTH(FIFO_DEPTH)) dut (
    .clk, .rst_n,
    .cfg_burst_i(cfg_burst), .cfg_outs_i(cfg_outs),
    .cmd_valid_i(cmd_valid), .cmd_ready_o(cmd_ready), .cmd_addr_i(cmd_addr), .cmd_bytes_i(cmd_bytes),
    .d_valid_o(d_valid), .d_ready_i(d_ready), .d_data_o(d_data), .d_last_o(d_last),
    .busy_o(busy), .done_o(done), .stall_o(stall), .err_resp_o(err_resp), .err_cmd_o(err_cmd),
    .err_clr_i(err_clr),
    .m_axi_arid_o(arid), .m_axi_araddr_o(araddr), .m_axi_arlen_o(arlen), .m_axi_arsize_o(arsize),
    .m_axi_arburst_o(arburst), .m_axi_arlock_o(arlock), .m_axi_arcache_o(arcache),
    .m_axi_arprot_o(arprot), .m_axi_arqos_o(arqos), .m_axi_arvalid_o(arvalid),
    .m_axi_arready_i(arready),
    .m_axi_rid_i(rid), .m_axi_rdata_i(rdata), .m_axi_rresp_i(rresp), .m_axi_rlast_i(rlast),
    .m_axi_rvalid_i(rvalid), .m_axi_rready_o(rready));

  axi_mem_slave #(.DW(64), .AW(32), .IDW(IDW), .MAX_LEN(MAX_BURST - 1), .MAX_OUTS(16),
                  .NAME("mem")) u_mem (
    .clk, .rst_n,
    .awid_i('0), .awaddr_i('0), .awlen_i('0), .awsize_i(3'd3), .awburst_i(2'b01),
    .awvalid_i(1'b0), .awready_o(awready_n),
    .wdata_i('0), .wstrb_i('0), .wlast_i(1'b0), .wvalid_i(1'b0), .wready_o(wready_n),
    .bid_o(bid_n), .bresp_o(bresp_n), .bvalid_o(bvalid_n), .bready_i(1'b1),
    .arid_i(arid), .araddr_i(araddr), .arlen_i(arlen), .arsize_i(arsize), .arburst_i(arburst),
    .arvalid_i(arvalid), .arready_o(arready),
    .rid_o(rid), .rdata_o(rdata), .rresp_o(rresp), .rlast_o(rlast), .rvalid_o(rvalid),
    .rready_i(rready));

  tb_checker c_data = new("data"), c_ar = new("ar"), c_outs = new("outs"), c_rch = new("rch"),
             c_stat = new("status"), c_cov = new("cov");

  // ---------------- command model ----------------
  typedef struct {
    longint unsigned addr;
    longint unsigned bytes;
    int burst, outs;          // raw cfg values driven with the command
    bit hold_drop;            // NEG 1: drop valid before ready
    int  chg_bytes;           // NEG 2: >0 new byte count after 3 waiting cycles
  } cmd_t;
  typedef struct {
    longint unsigned addr;
    int len;
    int olim;
  } ar_t;
  typedef struct {
    longint unsigned addr;
    bit last;
  } beat_t;

  cmd_t cmd_todo[$];
  ar_t  ar_exp[$];
  beat_t d_exp[$];
  int gap_pct = 0;
  longint unsigned n_cmd_ok = 0, n_cmd_bad = 0, n_beats = 0, n_ar = 0, n_done = 0;

  function automatic int eff(int v, int mx);
    return (v == 0 || v > mx) ? mx : v;
  endfunction
  function automatic bit is_bad(longint unsigned a, longint unsigned b);
    return (a % 8) != 0 || b == 0 || a + b > 64'h1_0000_0000;
  endfunction

  // split rule of hierarchy.md 3.6
  function automatic void expect_cmd(longint unsigned a, longint unsigned b, int burst, int outs);
    longint unsigned nb = (b + 7) / 8;
    int bl = eff(burst, MAX_BURST), ol = eff(outs, OUTS);
    for (longint unsigned k = 0; k < nb; k++) begin
      beat_t e;
      e.addr = a + 8 * k;
      e.last = (k == nb - 1);
      d_exp.push_back(e);
    end
    while (nb > 0) begin
      ar_t r;
      longint unsigned t4 = (4096 - (a % 4096)) / 8, n = nb;
      if (n > bl) n = bl;
      if (n > t4) n = t4;
      r.addr = a; r.len = int'(n) - 1; r.olim = ol;
      ar_exp.push_back(r);
      a += 8 * n;
      nb -= n;
    end
  endfunction

  // command driver (posedge, non-blocking)
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
          // NEG: present while the engine is busy, then drop or change the payload
          repeat (3) @(posedge clk);
          if (cmd_ready) $error("TB_NEG engine became ready too early for the negative command");
          if (c.hold_drop) cmd_valid <= 1'b0;
          else cmd_bytes <= LEN_W'(c.chg_bytes);
        end
      end
    end
  end

  // consumer ready
  int dprof = 0, blk = 0;
  bit force_block = 1'b0;
  always @(posedge clk) begin
    if (force_block) d_ready <= 1'b0;
    else case (dprof)
      0: d_ready <= 1'b1;
      1: d_ready <= $urandom_range(99) < 70;
      default: d_ready <= $urandom_range(99) < 30;
    endcase
  end

  // ---------------- monitor (negedge) ----------------
  int outs_tb = 0, max_outs = 0, lvl = 0, max_lvl = 0, pend = 0;
  bit exp_err_resp = 1'b0, exp_err_cmd = 1'b0;
  longint unsigned n_err_beats = 0, t_first = 0, t_last = 0, n_rstall = 0, n_err_clr = 0;
  bit tput_on = 1'b0;

  always @(negedge clk) if (rst_n) begin
    bit cmd_hs, ar_hs, r_hs, rl_hs, d_hs, bad;
    cmd_hs = cmd_valid && cmd_ready;
    ar_hs  = arvalid && arready;
    r_hs   = rvalid && rready;
    rl_hs  = r_hs && rlast;
    d_hs   = d_valid && d_ready;
    bad    = cmd_hs && is_bad(cmd_addr, cmd_bytes);

    // status outputs (state from earlier cycles)
    if (busy !== (pend != 0) || stall !== ((pend != 0) && d_ready && !d_valid) ||
        done !== ((d_hs && d_last) || bad) || err_resp !== exp_err_resp || err_cmd !== exp_err_cmd)
      c_stat.fail($sformatf("cyc %0d busy %b (pend %0d) stall %b done %b err_resp %b/%b err_cmd %b/%b",
                            cyc, busy, pend, stall, done, err_resp, exp_err_resp, err_cmd, exp_err_cmd));
    else c_stat.pass();
    if (cmd_valid && is_bad(cmd_addr, cmd_bytes) && pend != 0 && cmd_ready)
      c_stat.fail($sformatf("cyc %0d rejected command accepted while busy", cyc));
    if ($isunknown({cmd_ready, d_valid, arvalid, rready, busy, done, stall}))
      c_stat.fail($sformatf("cyc %0d X on a DUT control output", cyc));

    // command acceptance
    if (cmd_hs) begin
      if (bad) begin
        n_cmd_bad++;
        exp_err_cmd = 1'b1;
      end else begin
        n_cmd_ok++;
        expect_cmd(cmd_addr, cmd_bytes, cfg_burst, cfg_outs);
      end
    end

    // AR
    if (ar_hs) begin
      n_ar++;
      if (ar_exp.size() == 0) c_ar.fail($sformatf("unexpected AR 0x%0h len %0d", araddr, arlen));
      else begin
        ar_t e;
        e = ar_exp.pop_front();
        if (araddr !== e.addr[31:0] || arlen !== 8'(e.len) || arsize !== 3'd3 || arburst !== 2'b01 ||
            arid !== '0 || arlock !== 1'b0 || arcache !== 4'b0011)
          c_ar.fail($sformatf("AR 0x%0h len %0d size %0d burst %0d exp 0x%0h len %0d", araddr, arlen,
                              arsize, arburst, e.addr, e.len));
        else c_ar.pass();
        if (outs_tb + 1 > e.olim)
          c_outs.fail($sformatf("cyc %0d %0d bursts outstanding, limit %0d", cyc, outs_tb + 1, e.olim));
        else c_outs.pass();
      end
      outs_tb++;
      if (outs_tb > max_outs) max_outs = outs_tb;
    end
    if (rl_hs) outs_tb--;

    // R channel
    if (rvalid && !rready) begin
      n_rstall++;
      c_rch.fail($sformatf("cyc %0d RVALID stalled by the engine", cyc));
    end
    if (r_hs && rresp[1]) n_err_beats++;
    if (r_hs && rresp[1] && err_clr) n_err_clr++;
    lvl += int'(r_hs) - int'(d_hs);
    if (lvl > FIFO_DEPTH || lvl < 0) c_rch.fail($sformatf("cyc %0d buffer level %0d", cyc, lvl));
    else c_rch.pass();
    if (lvl > max_lvl) max_lvl = lvl;

    // delivered data
    if (d_hs) begin
      n_beats++;
      if (tput_on) begin
        if (t_first == 0) t_first = cyc;
        t_last = cyc;
      end
      if (d_exp.size() == 0) c_data.fail($sformatf("unexpected beat %h", d_data));
      else begin
        beat_t e;
        logic [63:0] w;
        e = d_exp.pop_front();
        w = u_mem.bd_read64(e.addr);
        if (d_data !== w || d_last !== e.last)
          c_data.fail($sformatf("addr 0x%0h got %h last %b exp %h last %b", e.addr, d_data, d_last, w, e.last));
        else c_data.pass();
      end
    end
    if (done) n_done++;

    // model state for the next cycle
    pend += int'(cmd_hs && !bad) - int'(d_hs && d_last);
    if (r_hs && rresp[1]) exp_err_resp = 1'b1;
    else if (err_clr) exp_err_resp = 1'b0;
    if (!bad && err_clr) exp_err_cmd = 1'b0;
  end

  // ---------------- stimulus helpers ----------------
  task automatic push(longint unsigned a, longint unsigned b, int burst = 0, int outs = 0);
    cmd_t c;
    c.addr = a; c.bytes = b; c.burst = burst; c.outs = outs; c.hold_drop = 0; c.chg_bytes = 0;
    cmd_todo.push_back(c);
  endtask

  function automatic int rnd_cfg(int mx);
    case ($urandom_range(9))
      0: return 0;                          // 0 -> maximum
      1: return mx + 1 + $urandom_range(3); // out of range -> maximum
      2, 3, 4: return mx;
      default: return $urandom_range(mx, 1);
    endcase
  endfunction

  task automatic wait_idle(longint unsigned max_cyc = 5000000);
    longint unsigned c0 = cyc;
    while ((cmd_todo.size() || cmd_valid || d_exp.size() || ar_exp.size() || pend != 0 || busy) &&
           cyc - c0 < max_cyc)
      @(posedge clk);
    if (cyc - c0 >= max_cyc) begin
      $error("TB_TIMEOUT cmd %0d d_exp %0d ar_exp %0d pend %0d", cmd_todo.size(), d_exp.size(),
             ar_exp.size(), pend);
      $finish;
    end
    repeat (3) @(posedge clk);
  endtask

  task automatic directed();
    longint unsigned pg = BASE + 4096 * 5;
    int mb8 = 8 * MAX_BURST;
    for (int b = 1; b <= 17; b++) push(BASE + 8 * b, b);
    push(pg, 1); push(pg - 8, 8); push(pg - 8, 9); push(pg - 8, 16); push(pg - 16, 4096);
    push(pg, 4096); push(pg + 8, 4096 - 8); push(pg + 8, 4096); push(pg - 4096, 3 * 4096);
    push(pg + 4096 - mb8, mb8); push(pg + 4096 - mb8 - 8, mb8 + 16); push(pg + 8, mb8 - 1);
    push(pg, mb8 + 1);
    push(BASE + SIZE - 40 * 1024, 40 * 1024, MAX_BURST, OUTS);
    push(TOPB + 8192 - 64, 64);           // ends exactly at 2^32
    push(TOPB, 8192, 1, 1);               // single-beat bursts, one outstanding
    push(TOPB + 4096 - 8, 4096 + 8, 0, 0);
    wait_idle();
  endtask

  task automatic random_cmds(int n, longint unsigned maxb);
    for (int i = 0; i < n; i++) begin
      longint unsigned a, b, pgb;
      case ($urandom_range(9))
        0, 1, 2: b = $urandom_range(64, 1);
        3, 4:    b = $urandom_range(1024, 65);
        5, 6:    b = $urandom_range(16384, 1025);
        7:       b = $urandom_range(maxb > 16385 ? maxb : 16385, 16385);
        default: b = $urandom_range(3 * 8 * MAX_BURST + 16, 1);
      endcase
      if (b > maxb) b = maxb;
      if ($urandom_range(3) == 0) begin   // start at / near a 4 KiB edge
        pgb = BASE + 4096 * $urandom_range(int'(SIZE / 4096) - 12, 1);
        a = pgb + 8 * $urandom_range(4) - 8 * $urandom_range(4);
      end else a = BASE + 8 * $urandom_range(int'((SIZE - b) / 8));
      if (a + b > BASE + SIZE) a = BASE + SIZE - ((b + 7) & ~64'h7);
      push(a, b, rnd_cfg(MAX_BURST), rnd_cfg(OUTS));
      if ($urandom_range(30) == 0) begin  // occasional clear of the sticky errors
        @(posedge clk);
        err_clr <= 1'b1;
        @(posedge clk);
        err_clr <= 1'b0;
      end
    end
    wait_idle();
  endtask

  // ---------------- negative tests ----------------
  task automatic neg_test(int neg);
    cmd_t c;
    push(BASE, 32 * 1024, MAX_BURST, OUTS);   // keeps the engine busy
    c.addr = BASE + 64; c.bytes = 100; c.burst = 0; c.outs = 0; c.hold_drop = 0; c.chg_bytes = 0;
    case (neg)
      1: c.hold_drop = 1;                     // VR_HOLD: valid dropped before ready
      2: c.chg_bytes = 200;                   // VR_STABLE: byte count changed while waiting
      3: c.addr = BASE + 4;                   // ENG_CMD: misaligned (waits until idle)
      4: c.bytes = 0;                         // ENG_CMD: zero length
      5: begin c.addr = 64'hFFFF_FFF8; c.bytes = 16; end  // ENG_CMD: passes 2^32
      default: $error("TB_BADNEG unknown +NEG=%0d", neg);
    endcase
    cmd_todo.push_back(c);
    push(BASE + 1024, 64);                    // next good command
    wait_idle();
  endtask

  // ---------------- main ----------------
  initial begin
    int unsigned seed;
    int prof, n_cmd, neg, oreach, tput, errinj;
    longint unsigned maxb;
    prof = 1; n_cmd = 400; neg = 0; oreach = 0; tput = 0; errinj = 0; maxb = 40960;
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("PROF=%d", prof));
    void'($value$plusargs("DPROF=%d", dprof));
    void'($value$plusargs("GAP=%d", gap_pct));
    void'($value$plusargs("N_CMD=%d", n_cmd));
    void'($value$plusargs("MAXB=%d", maxb));
    void'($value$plusargs("BLK=%d", blk));
    void'($value$plusargs("OREACH=%d", oreach));
    void'($value$plusargs("TPUT=%d", tput));
    void'($value$plusargs("ERRINJ=%d", errinj));
    void'($value$plusargs("NEG=%d", neg));
    $display("tb_axi_rd_eng: SEED %0d MAX_BURST %0d OUTS %0d FIFO_DEPTH %0d PROF %0d DPROF %0d GAP %0d N_CMD %0d BLK %0d OREACH %0d TPUT %0d ERRINJ %0d NEG %0d",
             seed, MAX_BURST, OUTS, FIFO_DEPTH, prof, dprof, gap_pct, n_cmd, blk, oreach, tput, errinj, neg);
    case (prof)
      0: begin u_mem.cfg_stall(0, 0, 0, 0, 0); u_mem.cfg_lat(1, 1, 1, 1); end
      1: begin u_mem.cfg_stall(30, 0, 0, 30, 0); u_mem.cfg_lat(1, 20, 1, 1); end
      default: begin u_mem.cfg_stall(70, 0, 0, 70, 0); u_mem.cfg_lat(1, 60, 1, 1); end
    endcase
    u_mem.cfg_uninit_err(1'b1);
    for (longint unsigned i = 0; i < SIZE / 8; i++) u_mem.bd_write64(BASE + 8 * i, {$urandom, $urandom});
    for (longint unsigned i = 0; i < 8192 / 8; i++) u_mem.bd_write64(TOPB + 8 * i, {$urandom, $urandom});
    if (errinj) begin
      u_mem.inj_rd_err(BASE + 8192, BASE + 8192 + 256, 2'b10);
      u_mem.inj_rd_err(BASE + 65536 - 8, BASE + 65536 + 8, 2'b11);
      u_mem.inj_rd_err(BASE + 160000, BASE + 170000, 2'b10);
    end
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);

    directed();
    random_cmds(n_cmd, maxb);
    if (errinj) begin  // make sure the windows are read, then clear
      push(BASE + 8192 - 64, 512);
      push(BASE + 160000 - 8000, 20000, 0, 0);
      wait_idle();
      @(posedge clk); err_clr <= 1'b1; @(posedge clk); err_clr <= 1'b0;
      repeat (2) @(posedge clk);
      // err_clr_i held high while error beats arrive: the new error must win in that cycle
      @(posedge clk); err_clr <= 1'b1;
      push(BASE + 8192 - 64, 512);
      push(BASE + 65536 - 64, 128);
      wait_idle();
      @(posedge clk); err_clr <= 1'b0;
      repeat (2) @(posedge clk);
      if (n_err_clr == 0) c_cov.fail("no error beat in a cycle with err_clr_i");
      else c_cov.pass();
    end

    if (blk) begin
      // (a) consumer blocked before a long aligned read starts: with FIFO_DEPTH a multiple of
      //     MAX_BURST the buffer must become exactly full (bursts of MAX_BURST beats, no 4 KiB
      //     partial bursts); otherwise it must fill to within one burst
      // (b) consumer blocked in the middle of long reads with random burst limits
      for (int r = 0; r < 2; r++) begin
        force_block = 1'b1;
        push(BASE + 4096 * (2 + 8 * r), 24 * 1024, MAX_BURST, 0);
        repeat (3000 + 2000 * r) @(posedge clk);
        force_block = 1'b0;
        wait_idle();
      end
      if (FIFO_DEPTH % MAX_BURST == 0 ? max_lvl != FIFO_DEPTH : max_lvl <= FIFO_DEPTH - MAX_BURST)
        c_cov.fail($sformatf("buffer not filled while blocked: max level %0d of %0d", max_lvl, FIFO_DEPTH));
      else c_cov.pass();
      for (int r = 0; r < 3; r++) begin
        push(BASE + 4096 * (3 * r + 1) + 8 * r, 24 * 1024 + 8 * r, 0, 0);
        push(BASE + 128 * 1024 + 8 * r, 9 * 1024, $urandom_range(MAX_BURST, 1), 0);
        repeat (40) @(posedge clk);
        force_block = 1'b1;
        repeat (3000 + 1000 * r) @(posedge clk);
        force_block = 1'b0;
        wait_idle();
      end
      $display("BLK buffer max level %0d of FIFO_DEPTH %0d", max_lvl, FIFO_DEPTH);
    end

    if (oreach) begin  // long latency, consumer always ready: the outstanding limit is the bound
      int sv_dprof;
      sv_dprof = dprof;
      dprof = 0;
      u_mem.cfg_stall(0, 0, 0, 0, 0);
      u_mem.cfg_lat(80, 80, 1, 1);
      max_outs = 0;
      push(BASE + 4096, 64 * 1024, MAX_BURST, OUTS);
      wait_idle();
      // OUTS is the bound when the buffer holds OUTS full bursts; a smaller buffer allows at
      // least FIFO_DEPTH / MAX_BURST (more once beats drain while a burst is still arriving)
      if (FIFO_DEPTH >= OUTS * MAX_BURST ? max_outs != OUTS
          : (max_outs < FIFO_DEPTH / MAX_BURST || max_outs > OUTS))
        c_cov.fail($sformatf("max outstanding %0d (OUTS %0d, buffer %0d bursts)", max_outs, OUTS,
                             FIFO_DEPTH / MAX_BURST));
      else c_cov.pass();
      $display("OREACH outstanding reached %0d (limit OUTS %0d, buffer allows %0d)", max_outs, OUTS,
               FIFO_DEPTH / MAX_BURST);
      dprof = sv_dprof;
    end

    if (tput) begin  // throughput without stalls, memory latency 1 (model minimum)
      int sv_dprof;
      longint unsigned c0, nb;
      int bls[$];
      sv_dprof = dprof;
      bls = '{MAX_BURST};
      if (MAX_BURST >= 16 && MAX_BURST != 16) bls.push_back(16);
      dprof = 0;
      u_mem.cfg_stall(0, 0, 0, 0, 0);
      foreach (bls[i]) for (int o = 1; o <= OUTS; o = o * 2) for (int lat = 1; lat <= 33; lat += 32) begin
        u_mem.cfg_lat(lat, lat, 1, 1);
        repeat (5) @(posedge clk);
        t_first = 0; t_last = 0; tput_on = 1'b1;
        nb = 8192;
        c0 = cyc;
        push(BASE + 4096, 8 * nb, bls[i], o);
        wait_idle();
        tput_on = 1'b0;
        $display("TPUT blen %0d outs %0d mem_lat %0d beats %0d first..last %0d cycles (%.3f beats/cycle) cmd..idle %0d cycles",
                 bls[i], o, lat, nb, t_last - t_first + 1, real'(nb) / real'(t_last - t_first + 1),
                 cyc - c0);
        if (tput >= 2 && lat == 1 && o == OUTS && bls[i] == MAX_BURST) begin
          if (t_last - t_first + 1 != nb)
            c_cov.fail($sformatf("throughput %0d beats in %0d cycles (expected 1 beat/cycle)", nb, t_last - t_first + 1));
          else c_cov.pass();
        end
      end
      dprof = sv_dprof;
    end

    if (neg != 0) neg_test(neg);

    wait_idle();
    if (errinj) begin
      if (n_err_beats == 0) c_cov.fail("no error beat seen");
      else c_cov.pass();
    end
    c_cov.pass();  // reached the end (keeps the checker non-empty without coverage phases)
    if (d_exp.size() || ar_exp.size() || cmd_todo.size() || pend != 0 || lvl != 0 || outs_tb != 0)
      c_data.fail($sformatf("left over: d_exp %0d ar_exp %0d cmd %0d pend %0d lvl %0d outs %0d",
                            d_exp.size(), ar_exp.size(), cmd_todo.size(), pend, lvl, outs_tb));
    if (n_done != n_cmd_ok + n_cmd_bad) c_stat.fail($sformatf("done pulses %0d, commands %0d", n_done, n_cmd_ok + n_cmd_bad));
    u_mem.check_idle();
    u_mem.report();
    $display("tb_axi_rd_eng: commands %0d (+%0d rejected), AR %0d, beats %0d, max outstanding %0d, max buffer level %0d/%0d, error beats %0d",
             n_cmd_ok, n_cmd_bad, n_ar, n_beats, max_outs, max_lvl, FIFO_DEPTH, n_err_beats);
    void'(tb_final_report('{c_data, c_ar, c_outs, c_rch, c_stat, c_cov}));
    $finish;
  end

  initial begin
    #2s;
    $error("TB_TIMEOUT global");
    $finish;
  end

endmodule
