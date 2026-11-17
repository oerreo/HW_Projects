// tb_coef_ram: self-checking testbench for the L2 bank RAM coef_ram.
//
// Reference: a behavioral array in this TB (ref_mem), updated with the same
// writes as the DUT. Contract checked (rtl/l2/coef_ram.sv header):
//   read latency 1, "no change" read data (rdata_x holds unless port x read
//   in the previous cycle, also across a write on port x), both ports
//   independent, same-address read/read allowed.
//
// Phases:
//   fill : every address written once, alternating ports, then every address
//          read on both ports at the same time (same-address read/read).
//   rand : N_OPS cycles. Each port independently: idle / read / write with
//          probabilities 20 / 45 / 35 %. Addresses: 40 % from a 4-word hot
//          window (frequent same-address pairs), else uniform. A pair that
//          would be a forbidden collision (same address, at least one write)
//          is turned into a read/read pair, so the forbidden cases never occur
//          in this phase; the counters below show how often each allowed
//          combination was hit.
// Checkers: rd_a, rd_b (every read, one cycle later), hold_a, hold_b (every
// cycle without a read in the previous cycle on that port), final (backdoor
// compare of all 256 words after the run).
//
// +COLL_TEST: after fill, drive COLL_WW = 3 write/write and COLL_RW = 4
// write/read same-address collisions (2 with A writing, 2 with B writing)
// between legal cycles. The DUT assertions must fire exactly 3 times
// (L2_RAM_WW) and 4 times (L2_RAM_RW); the data of the collided words is not
// checked afterwards (they are marked unknown in the reference). This run is
// evaluated by hand (sim/run.sh cannot count L2_* tags, see the report).
//
// Plusargs: +SEED=<n> (1) +N_OPS=<n> (200000) +COLL_TEST
`timescale 1ns / 1ps

module tb_coef_ram;
  import mlkem_pkg::*;
  import ntt_l2_pkg::*;
  import tb_util_pkg::*;

  localparam time T_CLK   = 10ns;
  localparam int  DEPTH   = N_COEF;
  localparam int  AW      = RAM_AW;
  localparam int  COLL_WW = 3;
  localparam int  COLL_RW = 4;

  logic              clk = 1'b0;
  logic              rst_n = 1'b0;
  logic              en_a_i = 1'b0, we_a_i = 1'b0, en_b_i = 1'b0, we_b_i = 1'b0;
  logic [AW-1:0]     addr_a_i = '0, addr_b_i = '0;
  logic [COEF_W-1:0] wdata_a_i = '0, wdata_b_i = '0;
  logic [COEF_W-1:0] rdata_a_o, rdata_b_o;

  coef_ram #(.DEPTH(DEPTH)) dut (.*);

  always #(T_CLK / 2) clk = ~clk;

  tb_checker chk_rd [2];
  tb_checker chk_hold [2];
  tb_checker chk_final;

  int  ref_mem [DEPTH];           // -1: unknown
  int  exp_rd  [2];               // expected read data (-1: unknown / do not check)
  bit  rd_prev [2];               // port read in the previous cycle
  int  hold_v  [2];               // value rdata must hold (-1: unknown)
  longint n_rr_same, n_both, n_rd [2], n_wr [2], n_wr_rd_same_port;

  typedef struct { bit en; bit we; int addr; int wd; } acc_t;

  // One cycle: drive both ports at the rising edge, update the reference,
  // check the outputs at the falling edge.
  task automatic cycle(acc_t a, acc_t b, bit coll = 1'b0);
    acc_t p [2];
    int   e  [2];
    p[0] = a;
    p[1] = b;
    @(posedge clk);
    en_a_i <= a.en; we_a_i <= a.we; addr_a_i <= AW'(a.addr); wdata_a_i <= COEF_W'(a.wd);
    en_b_i <= b.en; we_b_i <= b.we; addr_b_i <= AW'(b.addr); wdata_b_i <= COEF_W'(b.wd);
    // reads see the memory before this cycle's writes (no legal RW collision)
    for (int x = 0; x < 2; x++) e[x] = (p[x].en && !p[x].we) ? ref_mem[p[x].addr] : -2;
    if (coll) for (int x = 0; x < 2; x++) if (e[x] != -2) e[x] = -1;
    for (int x = 0; x < 2; x++)
      if (p[x].en && p[x].we) ref_mem[p[x].addr] = coll ? -1 : p[x].wd;
    if (a.en && b.en) n_both++;
    if (a.en && b.en && !a.we && !b.we && a.addr == b.addr) n_rr_same++;
    for (int x = 0; x < 2; x++) begin
      if (p[x].en && !p[x].we) n_rd[x]++;
      if (p[x].en && p[x].we) begin
        n_wr[x]++;
        if (rd_prev[x]) n_wr_rd_same_port++;   // write right after a read on the same port
      end
    end
    @(negedge clk);
    // outputs now reflect the accesses of the previous cycle (latency 1)
    for (int x = 0; x < 2; x++) begin
      logic [COEF_W-1:0] got = (x == 0) ? rdata_a_o : rdata_b_o;
      if (rd_prev[x]) begin
        if (exp_rd[x] >= 0) begin
          if (got === COEF_W'(exp_rd[x])) chk_rd[x].pass();
          else chk_rd[x].fail($sformatf("port %0d read: expected %03h got %03h", x, exp_rd[x], got));
          hold_v[x] = exp_rd[x];
        end else hold_v[x] = -1;
      end else if (hold_v[x] >= 0) begin
        if (got === COEF_W'(hold_v[x])) chk_hold[x].pass();
        else chk_hold[x].fail($sformatf("port %0d rdata changed to %03h without a read (held %03h)",
                                        x, got, hold_v[x]));
      end
    end
    for (int x = 0; x < 2; x++) begin
      rd_prev[x] = (e[x] != -2);
      exp_rd[x]  = e[x];
    end
  endtask

  function automatic acc_t idle_acc();
    acc_t r;
    r.en = 0; r.we = $urandom_range(1); r.addr = $urandom_range(DEPTH - 1);
    r.wd = $urandom_range(2 ** COEF_W - 1);
    return r;
  endfunction

  function automatic acc_t mk(bit we, int addr, int wd = -1);
    acc_t r;
    r.en = 1; r.we = we; r.addr = addr;
    r.wd = (wd >= 0) ? wd : $urandom_range(Q - 1);
    return r;
  endfunction

  function automatic acc_t rnd_acc(int hot_base);
    int k = $urandom_range(99);
    int addr = ($urandom_range(99) < 40) ? (hot_base + $urandom_range(3)) % DEPTH
                                          : $urandom_range(DEPTH - 1);
    if (k < 20) return idle_acc();
    return mk(k >= 65, addr);
  endfunction

  initial begin
    int unsigned seed;
    int          n_ops, hot;
    bit          coll_test, ok;
    acc_t        a, b;

    seed      = tb_seed_from_plusarg();
    n_ops     = 200000;
    void'($value$plusargs("N_OPS=%d", n_ops));
    coll_test = $test$plusargs("COLL_TEST");
    chk_rd[0]   = new("rd_a");
    chk_rd[1]   = new("rd_b");
    chk_hold[0] = new("hold_a");
    chk_hold[1] = new("hold_b");
    chk_final   = new("final");
    foreach (ref_mem[i]) ref_mem[i] = -1;
    rd_prev   = '{0, 0};
    exp_rd    = '{-1, -1};
    hold_v    = '{-1, -1};
    n_rr_same = 0; n_both = 0; n_rd = '{0, 0}; n_wr = '{0, 0}; n_wr_rd_same_port = 0;
    $display("TB_CONFIG: tb_coef_ram DEPTH=%0d LATENCY=%0d SEED=%0d N_OPS=%0d COLL_TEST=%0d",
             DEPTH, dut.LATENCY, seed, n_ops, coll_test);
    if (dut.LATENCY != 1) $fatal(1, "coef_ram LATENCY %0d != 1", dut.LATENCY);

    repeat (2) cycle(idle_acc(), idle_acc());
    @(negedge clk);
    rst_n = 1'b1;

    // fill: port A even addresses, port B odd addresses, same cycle
    for (int i = 0; i < DEPTH; i += 2) cycle(mk(1, i), mk(1, i + 1));
    // read every address on both ports simultaneously (read/read same address)
    for (int i = 0; i < DEPTH; i++) cycle(mk(0, i), mk(0, i));

    if (coll_test) begin
      for (int i = 0; i < COLL_WW; i++) begin
        cycle(mk(1, 10 + i), mk(1, 10 + i), 1'b1);
        cycle(idle_acc(), idle_acc());
      end
      for (int i = 0; i < COLL_RW; i++) begin
        if (i % 2 == 0) cycle(mk(1, 20 + i), mk(0, 20 + i), 1'b1);
        else            cycle(mk(0, 20 + i), mk(1, 20 + i), 1'b1);
        cycle(idle_acc(), idle_acc());
      end
      $display("COLL_TEST: drove %0d write/write and %0d write/read same-address collisions",
               COLL_WW, COLL_RW);
    end

    hot = $urandom_range(DEPTH - 1);
    for (int i = 0; i < n_ops; i++) begin
      if (i % 1000 == 0) hot = $urandom_range(DEPTH - 1);
      a = rnd_acc(hot);
      b = rnd_acc(hot);
      if (a.en && b.en && a.addr == b.addr && (a.we || b.we)) begin
        a.we = 0;
        b.we = 0;
      end
      cycle(a, b);
    end
    repeat (2) cycle(idle_acc(), idle_acc());

    // backdoor compare
    for (int i = 0; i < DEPTH; i++) begin
      if (ref_mem[i] < 0) continue;
      if (dut.mem[i] === COEF_W'(ref_mem[i])) chk_final.pass();
      else chk_final.fail($sformatf("mem[%0d] = %03h, reference %03h", i, dut.mem[i], ref_mem[i]));
    end

    $display("STATS: reads A=%0d B=%0d writes A=%0d B=%0d both-ports-active=%0d same-addr read/read=%0d write-after-read same port=%0d",
             n_rd[0], n_rd[1], n_wr[0], n_wr[1], n_both, n_rr_same, n_wr_rd_same_port);
    ok = tb_final_report('{chk_rd[0], chk_rd[1], chk_hold[0], chk_hold[1], chk_final});
    $finish;
  end

endmodule
