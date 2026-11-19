// tb_axi_mem: self-test of the AXI slave memory model tb/common/axi_mem_slave.sv.
//
// A master written here drives random INCR bursts (64-bit, size 3) with random IDs,
// random VALID gaps, random RREADY/BREADY, W beats that may lead their AW, partial WSTRB,
// several bursts outstanding. A byte shadow memory gives the expected read data.
//
// Rounds: round r writes N_BURST bursts into region (r % 2) while it reads N_BURST bursts
// from the other region at the same time, then waits for every response. Region 0 is
// prefilled through the backdoor; region 1 is first read in round 1 after one round of
// writes, so unwritten bytes are read too (expected 8'hA5, counted by both sides).
// Then file round trips: dump_hex/load_hex and dump_bin/load_bin to another base, read
// back over AXI.
//
// Checkers: rdata (every R beat vs shadow), rid/rlast (order and last beat), bid (order),
// slv (slave side: RVALID/BVALID held with stable payload until READY), file (backdoor
// file round trips), uninit (model count == TB count), cnt (beats and bursts).
// +NEG=<n> injects one protocol violation (see neg_* tasks); sim/tests/axi_mem.cfg expects
// exactly one message of the matching tag and TB_RESULT PASS.
//
// Plusargs: +SEED=<n> +PROF=<0|1|2> (stall/latency profile) +N_ROUND +N_BURST +MAXL=<len>
// +NEG=<n>.
`timescale 1ns / 1ps
module tb_axi_mem #(
  parameter int DW      = 64,
  parameter int IDW     = 6,
  parameter int MAX_LEN = 15
);
  import tb_util_pkg::*;

  localparam int NBY = DW / 8;
  localparam longint unsigned REG0 = 64'h0000_0000_1000_0000;  // region bases (32-bit)
  localparam longint unsigned REG1 = 64'h0000_0000_2000_0000;
  localparam longint unsigned FBASE = 64'h0000_0000_3000_0000; // file round trip targets
  localparam longint unsigned NBASE = 64'h0000_0000_4000_0000; // negative-test area
  localparam int WIN = 16384;  // bytes per region (4 pages)

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [IDW-1:0] awid = '0, arid = '0, bid, rid;
  logic [31:0] awaddr = '0, araddr = '0;
  logic [7:0] awlen = '0, arlen = '0;
  logic [2:0] awsize = 3'd3, arsize = 3'd3;
  logic [1:0] awburst = 2'b01, arburst = 2'b01, bresp, rresp;
  logic awvalid = 1'b0, awready, wvalid = 1'b0, wready, wlast = 1'b0, bvalid, bready = 1'b0;
  logic arvalid = 1'b0, arready, rvalid, rready = 1'b0, rlast;
  logic [DW-1:0] wdata = '0, rdata;
  logic [NBY-1:0] wstrb = '0;

  axi_mem_slave #(.DW(DW), .AW(32), .IDW(IDW), .MAX_LEN(MAX_LEN), .NAME("mem")) u_mem (
    .clk(clk), .rst_n(rst_n),
    .awid_i(awid), .awaddr_i(awaddr), .awlen_i(awlen), .awsize_i(awsize), .awburst_i(awburst),
    .awvalid_i(awvalid), .awready_o(awready),
    .wdata_i(wdata), .wstrb_i(wstrb), .wlast_i(wlast), .wvalid_i(wvalid), .wready_o(wready),
    .bid_o(bid), .bresp_o(bresp), .bvalid_o(bvalid), .bready_i(bready),
    .arid_i(arid), .araddr_i(araddr), .arlen_i(arlen), .arsize_i(arsize), .arburst_i(arburst),
    .arvalid_i(arvalid), .arready_o(arready),
    .rid_o(rid), .rdata_o(rdata), .rresp_o(rresp), .rlast_o(rlast), .rvalid_o(rvalid),
    .rready_i(rready));

  tb_checker c_rdata = new("rdata"), c_rid = new("rid_rlast"), c_bid = new("bid"),
             c_slv = new("slv"), c_file = new("file"), c_uninit = new("uninit"),
             c_cnt = new("cnt");

  // ---------------- shadow memory ----------------
  byte unsigned shadow[longint unsigned];
  longint unsigned tb_uninit = 0;

  function automatic logic [63:0] exp_word(longint unsigned a, output bit u);
    logic [63:0] d;
    longint unsigned w0 = a & ~64'h7;
    u = 1'b0;
    for (int i = 0; i < 8; i++)
      if (shadow.exists(w0 + i)) d[8*i +: 8] = shadow[w0 + i];
      else begin
        d[8*i +: 8] = 8'hA5;
        u = 1'b1;
      end
    return d;
  endfunction

  // ---------------- master: request queues ----------------
  typedef struct {
    logic [IDW-1:0] id;
    longint unsigned addr;
    int len;
    logic [2:0] size;
    logic [1:0] burst;
    int wlast_at;  // W: beat that carries WLAST (-1: the last one)
  } burst_t;
  typedef struct {
    logic [63:0] d;
    logic [7:0] s;
    logic l;
  } wb_t;

  burst_t ar_todo[$], aw_todo[$], r_exp[$];
  logic [IDW-1:0] b_exp[$];
  wb_t w_todo[$];
  int gap_pct = 0, rr_pct = 100, br_pct = 100;  // VALID gap %, RREADY / BREADY high %
  longint unsigned n_rbeat = 0, n_bresp = 0, n_rburst = 0, exp_rbeat = 0, exp_bresp = 0;

  function automatic bit coin(int pct);
    return $urandom_range(99) < pct;
  endfunction

  // AR driver
  initial begin
    wait (rst_n);
    forever begin
      @(posedge clk);
      if (arvalid && arready) arvalid <= 1'b0;
      if ((!arvalid || arready) && ar_todo.size() > 0 && !coin(gap_pct)) begin
        burst_t q;
        q = ar_todo.pop_front();
        arvalid <= 1'b1;
        arid <= q.id;
        araddr <= q.addr[31:0];
        arlen <= q.len[7:0];
        arsize <= q.size;
        arburst <= q.burst;
      end
    end
  end

  // AW driver
  initial begin
    wait (rst_n);
    forever begin
      @(posedge clk);
      if (awvalid && awready) awvalid <= 1'b0;
      if ((!awvalid || awready) && aw_todo.size() > 0 && !coin(gap_pct)) begin
        burst_t q;
        q = aw_todo.pop_front();
        awvalid <= 1'b1;
        awid <= q.id;
        awaddr <= q.addr[31:0];
        awlen <= q.len[7:0];
        awsize <= q.size;
        awburst <= q.burst;
      end
    end
  end

  // W driver (independent of AW: beats may lead their address)
  initial begin
    wait (rst_n);
    forever begin
      @(posedge clk);
      if (wvalid && wready) wvalid <= 1'b0;
      if ((!wvalid || wready) && w_todo.size() > 0 && !coin(gap_pct)) begin
        wb_t b;
        b = w_todo.pop_front();
        wvalid <= 1'b1;
        wdata <= b.d;
        wstrb <= b.s;
        wlast <= b.l;
      end
    end
  end

  // READY drivers
  always @(posedge clk) begin
    rready <= coin(rr_pct);
    bready <= coin(br_pct);
  end

  // R / B collectors and slave-side protocol checks
  int rk = 0;  // beat index inside the expected burst
  logic r_hold = 1'b0, b_hold = 1'b0;
  logic [IDW+DW+1:0] r_prev;
  logic [IDW-1:0] b_prev;
  always @(posedge clk) if (rst_n) begin
    if (r_hold) begin
      if (rvalid !== 1'b1 || {rid, rdata, rlast, rresp[1]} !== r_prev)
        c_slv.fail($sformatf("R beat changed or dropped before RREADY (rvalid %b)", rvalid));
      else c_slv.pass();
    end
    if (b_hold) begin
      if (bvalid !== 1'b1 || bid !== b_prev) c_slv.fail("B changed or dropped before BREADY");
      else c_slv.pass();
    end
    // no X/Z on a presented beat or response (also counts beats when nothing stalls)
    if (rvalid === 1'b1) begin
      if ($isunknown({rid, rdata, rlast, rresp})) c_slv.fail("X/Z on R payload while RVALID");
      else c_slv.pass();
    end
    if (bvalid === 1'b1) begin
      if ($isunknown({bid, bresp})) c_slv.fail("X/Z on B payload while BVALID");
      else c_slv.pass();
    end
    if ($isunknown({rvalid, bvalid, arready, awready, wready})) c_slv.fail("X/Z on a slave VALID/READY");
    r_hold <= rvalid && !rready;
    r_prev <= {rid, rdata, rlast, rresp[1]};
    b_hold <= bvalid && !bready;
    b_prev <= bid;

    if (rvalid && rready) begin
      n_rbeat++;
      if (r_exp.size() == 0) c_rid.fail("R beat without a request");
      else begin
        burst_t q;
        longint unsigned a0, ba;
        bit u;
        logic [63:0] e;
        q = r_exp[0];
        a0 = q.addr & ~64'h7;
        ba = rk == 0 ? q.addr : a0 + 8 * rk;
        e = exp_word(ba, u);
        if (u) tb_uninit++;
        if (rdata !== e) c_rdata.fail($sformatf("addr 0x%0h beat %0d got %h exp %h", ba, rk, rdata, e));
        else c_rdata.pass();
        if (rid !== q.id || rlast !== (rk == q.len) || rresp !== 2'b00)
          c_rid.fail($sformatf("burst 0x%0h beat %0d/%0d rid %0d exp %0d rlast %b rresp %0d",
                               q.addr, rk, q.len, rid, q.id, rlast, rresp));
        else c_rid.pass();
        if (rk == q.len) begin
          void'(r_exp.pop_front());
          rk = 0;
          n_rburst++;
        end else rk++;
      end
    end
    if (bvalid && bready) begin
      n_bresp++;
      if (b_exp.size() == 0) c_bid.fail("B without a write");
      else begin
        logic [IDW-1:0] e;
        e = b_exp.pop_front();
        if (bid !== e || bresp !== 2'b00) c_bid.fail($sformatf("bid %0d exp %0d bresp %0d", bid, e, bresp));
        else c_bid.pass();
      end
    end
  end

  // ---------------- request generation ----------------
  int maxl = MAX_LEN;

  function automatic burst_t rnd_burst(longint unsigned base, int span);
    burst_t q;
    int lim;
    q.id = $urandom_range((1 << IDW) - 1);
    q.addr = base + 8 * $urandom_range(span / 8 - 1);
    q.len = $urandom_range(maxl);
    lim = (4096 - int'(q.addr % 4096)) / 8 - 1;
    if (q.len > lim) q.len = lim;
    q.size = 3'd3;
    q.burst = 2'b01;
    q.wlast_at = -1;
    return q;
  endfunction

  task automatic issue_read(burst_t q);
    ar_todo.push_back(q);
    r_exp.push_back(q);
    exp_rbeat += q.len + 1;
  endtask

  // write data into the shadow when queued (reads never overlap a region being written)
  task automatic issue_write(burst_t q, bit partial = 1'b1, bit update = 1'b1);
    longint unsigned a0 = q.addr & ~64'h7;
    aw_todo.push_back(q);
    b_exp.push_back(q.id);
    exp_bresp++;
    for (int k = 0; k <= q.len; k++) begin
      wb_t b;
      longint unsigned ba = k == 0 ? q.addr : a0 + 8 * k;
      b.d = {$urandom, $urandom};
      b.s = (partial && coin(20)) ? 8'($urandom) : 8'hFF;
      b.l = q.wlast_at < 0 ? (k == q.len) : (k == q.wlast_at);
      for (int i = 0; i < 8; i++)
        if (b.s[i] && update) shadow[(ba & ~64'h7) + i] = b.d[8*i +: 8];
      w_todo.push_back(b);
    end
  endtask

  task automatic wait_done(int max_cyc = 2000000);
    int c = 0;
    while ((n_rbeat != exp_rbeat || n_bresp != exp_bresp || ar_todo.size() || aw_todo.size() ||
            w_todo.size() || arvalid || awvalid || wvalid) && c < max_cyc) begin
      @(posedge clk);
      c++;
    end
    if (c >= max_cyc) begin
      $error("TB_TIMEOUT waiting for responses: rbeat %0d/%0d bresp %0d/%0d", n_rbeat, exp_rbeat,
             n_bresp, exp_bresp);
      $finish;
    end
    repeat (2) @(posedge clk);
  endtask

  // ---------------- negative tests (one violation each) ----------------
  task automatic quiesce_ar(int pct);
    u_mem.cfg_stall(pct, u_mem.st_aw, u_mem.st_w, u_mem.st_r, u_mem.st_b);
    repeat (3) @(posedge clk);
  endtask

  task automatic neg_test(int neg);
    burst_t q;
    q.id = 1; q.size = 3'd3; q.burst = 2'b01; q.wlast_at = -1;
    case (neg)
      1: begin  // AXI_HOLD: ARVALID dropped while ARREADY is held low
        quiesce_ar(100);
        @(posedge clk);
        arvalid <= 1'b1; arid <= 1; araddr <= NBASE[31:0]; arlen <= 0; arsize <= 3; arburst <= 1;
        repeat (2) @(posedge clk);
        arvalid <= 1'b0;
        repeat (2) @(posedge clk);
        quiesce_ar(0);
      end
      2: begin  // AXI_STABLE: AWADDR changes while AWVALID waits; the second address is written
        u_mem.cfg_stall(u_mem.st_ar, 100, u_mem.st_w, u_mem.st_r, u_mem.st_b);
        repeat (3) @(posedge clk);
        awvalid <= 1'b1; awid <= 2; awaddr <= NBASE[31:0]; awlen <= 0; awsize <= 3; awburst <= 1;
        repeat (2) @(posedge clk);
        awaddr <= NBASE[31:0] + 8;
        @(posedge clk);
        u_mem.cfg_stall(u_mem.st_ar, 0, u_mem.st_w, u_mem.st_r, u_mem.st_b);
        do @(posedge clk); while (!(awvalid && awready));
        awvalid <= 1'b0;
        q.id = 2; q.addr = NBASE + 8; q.len = 0;
        // W beat and B only (the AW was driven by hand)
        b_exp.push_back(2);
        exp_bresp++;
        begin
          wb_t b;
          b.d = 64'h0123_4567_89AB_CDEF; b.s = 8'hFF; b.l = 1'b1;
          for (int i = 0; i < 8; i++) shadow[NBASE + 8 + i] = b.d[8*i +: 8];
          w_todo.push_back(b);
        end
        wait_done();
        q.len = 0;
        issue_read(q);
      end
      3: begin  // AXI_LEN: 32-beat read with MAX_LEN 15
        q.addr = REG0; q.len = 31;
        issue_read(q);
      end
      4: begin  // AXI_4K: read crossing a page
        q.addr = REG0 + 4096 - 16; q.len = 3;
        issue_read(q);
      end
      5: begin  // AXI_4K: write crossing a page (read back with two legal bursts)
        q.addr = NBASE + 4096 - 8; q.len = 1;
        issue_write(q, 1'b0);
        wait_done();
        q.len = 0;
        issue_read(q);
        q.addr = NBASE + 4096;
        issue_read(q);
      end
      6: begin  // AXI_WLAST: WLAST on beat 1 of 4 (and missing on beat 3): one message
        q.addr = NBASE + 64; q.len = 3; q.wlast_at = 1;
        issue_write(q, 1'b0);
        wait_done();
        q.wlast_at = -1;
        issue_read(q);
      end
      7: begin  // AXI_BURST: FIXED read (served as INCR)
        q.addr = REG0 + 256; q.len = 2; q.burst = 2'b00;
        issue_read(q);
      end
      8: begin  // AXI_ALIGN: read at an address not aligned to 8 bytes
        q.addr = REG0 + 512 + 4; q.len = 1;
        issue_read(q);
      end
      9: begin  // AXI_X: WVALID is X for one cycle while the W channel is idle
        @(posedge clk);
        wvalid <= 1'bx;
        @(posedge clk);
        wvalid <= 1'b0;
        repeat (2) @(posedge clk);
      end
      10: ;  // AXI_IDLE: handled at the end (a W beat without AW)
      default: $error("TB_BADNEG unknown +NEG=%0d", neg);
    endcase
    wait_done();
  endtask

  // ---------------- file round trips ----------------
  task automatic file_tests();
    string fh = "axi_mem_t.hex", fb = "axi_mem_t.bin";
    int nw = 512, n;
    longint nb;
    // zero bytes must survive the binary round trip
    u_mem.bd_write64(REG0 + 8, 64'h00FF_0000_0A00_000D);
    for (int i = 0; i < 8; i++) shadow[REG0 + 8 + i] = 8'(64'h00FF_0000_0A00_000D >> (8 * i));
    n = u_mem.dump_hex(fh, REG0, nw);
    if (u_mem.load_hex(fh, FBASE) != nw || n != nw) c_file.fail("hex word count");
    else c_file.pass();
    nb = u_mem.dump_bin(fb, REG0, 8 * nw);
    if (u_mem.load_bin(fb, FBASE + WIN) != 8 * nw || nb != 8 * nw) c_file.fail("bin byte count");
    else c_file.pass();
    for (int i = 0; i < 8 * nw; i++) begin  // backdoor compare, then AXI reads of the copies
      bit u;
      logic [63:0] e = exp_word(REG0 + (i & ~7), u);
      byte unsigned eb = e[8*(i % 8) +: 8];
      if (u_mem.bd_read8(FBASE + i) !== eb || u_mem.bd_read8(FBASE + WIN + i) !== eb)
        c_file.fail($sformatf("byte %0d: hex %h bin %h exp %h", i, u_mem.bd_read8(FBASE + i),
                              u_mem.bd_read8(FBASE + WIN + i), eb));
      else c_file.pass();
      shadow[FBASE + i] = eb;
      shadow[FBASE + WIN + i] = eb;
    end
    for (int k = 0; k < 2 * nw / 16; k++) begin
      burst_t q;
      q.id = k; q.addr = FBASE + (k < nw / 16 ? 0 : WIN) + 128 * (k % (nw / 16)); q.len = 15;
      q.size = 3; q.burst = 1; q.wlast_at = -1;
      if (q.len > maxl) q.len = maxl;
      issue_read(q);
    end
    wait_done();
  endtask

  // ---------------- main ----------------
  initial begin
    int unsigned seed;
    int prof, n_round, n_burst, neg;
    prof = 1;
    n_round = 6;
    n_burst = 200;
    neg = 0;
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("PROF=%d", prof));
    void'($value$plusargs("N_ROUND=%d", n_round));
    void'($value$plusargs("N_BURST=%d", n_burst));
    void'($value$plusargs("MAXL=%d", maxl));
    void'($value$plusargs("NEG=%d", neg));
    if (maxl > MAX_LEN) maxl = MAX_LEN;
    $display("tb_axi_mem: SEED %0d PROF %0d N_ROUND %0d N_BURST %0d MAXL %0d MAX_LEN %0d NEG %0d",
             seed, prof, n_round, n_burst, maxl, MAX_LEN, neg);
    case (prof)
      0: begin u_mem.cfg_stall(0, 0, 0, 0, 0); u_mem.cfg_lat(1, 1, 1, 1); gap_pct = 0; rr_pct = 100; br_pct = 100; end
      1: begin u_mem.cfg_stall(30, 30, 30, 30, 30); u_mem.cfg_lat(1, 20, 1, 10); gap_pct = 20; rr_pct = 70; br_pct = 70; end
      default: begin u_mem.cfg_stall(70, 70, 70, 70, 70); u_mem.cfg_lat(1, 60, 1, 40); gap_pct = 60; rr_pct = 30; br_pct = 30; end
    endcase
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);
    // prefill region 0 through the backdoor (some zero words)
    for (int i = 0; i < WIN / 8; i++) begin
      logic [63:0] d;
      d = coin(10) ? 64'h0 : {$urandom, $urandom};
      u_mem.bd_write64(REG0 + 8 * i, d);
      for (int b = 0; b < 8; b++) shadow[REG0 + 8 * i + b] = d[8*b +: 8];
    end
    for (int r = 0; r < n_round; r++) begin
      longint unsigned wb, rb;
      wb = (r % 2) ? REG0 : REG1;
      rb = (r % 2) ? REG1 : REG0;
      for (int k = 0; k < n_burst; k++) begin
        issue_write(rnd_burst(wb, WIN));
        issue_read(rnd_burst(rb, WIN));
      end
      wait_done();
    end
    file_tests();
    if (neg != 0) neg_test(neg);
    if (neg == 10) begin  // orphan W beat: no AW ever comes
      wb_t b;
      b.d = '0; b.s = 8'hFF; b.l = 1'b1;
      w_todo.push_back(b);
      repeat (20) @(posedge clk);
    end
    repeat (10) @(posedge clk);
    if (u_mem.n_uninit != tb_uninit)
      c_uninit.fail($sformatf("model %0d tb %0d", u_mem.n_uninit, tb_uninit));
    else c_uninit.pass();
    if (n_rbeat != exp_rbeat || n_bresp != exp_bresp || r_exp.size() || b_exp.size() ||
        u_mem.n_rd_beat != n_rbeat || u_mem.n_wr_beat < exp_bresp)
      c_cnt.fail($sformatf("rbeat %0d/%0d (model %0d) bresp %0d/%0d", n_rbeat, exp_rbeat,
                           u_mem.n_rd_beat, n_bresp, exp_bresp));
    else c_cnt.pass();
    u_mem.check_idle();
    u_mem.report();
    $display("tb_axi_mem: read beats %0d bursts %0d, write responses %0d, uninit words %0d",
             n_rbeat, n_rburst, n_bresp, tb_uninit);
    void'(tb_final_report('{c_rdata, c_rid, c_bid, c_slv, c_file, c_uninit, c_cnt}));
    $finish;
  end

  // watchdog
  initial begin
    #500ms;
    $error("TB_TIMEOUT global");
    $finish;
  end

endmodule
