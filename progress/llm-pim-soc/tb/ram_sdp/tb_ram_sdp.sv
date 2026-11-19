// tb_ram_sdp: ram_sdp against an array reference model.
//
// Phase 0 writes every address once (reads of already written addresses run in parallel);
// phase 1 drives random writes and reads (+N cycles), with 20 % of the cycles reading the
// address written in the same cycle (read-first: the old word is expected). At every
// negedge rdata_o is compared with the word of the last read that has reached the output
// (RD_LAT edges after it was issued), so a change of rdata_o without re_i is an error.
// Coverage counters (same-address read/write, cycles without read) must be non-zero.
// Negative runs (+NEG, DEPTH not a power of two): 1 one write to address DEPTH
// (RAM_ADDR, write dropped), 2 one read of address DEPTH (RAM_ADDR, X expected),
// 3 we_i = X for one cycle (RAM_X, no write).
// Plusargs: +SEED=<n> +N=<cycles, default 200000> +NEG=<0..3>.
`timescale 1ns / 1ps
module tb_ram_sdp;
  import tb_util_pkg::*;

  parameter int W      = 64;
  parameter int DEPTH  = 128;
  parameter int RD_LAT = 1;
  localparam int AW = (DEPTH > 1) ? $clog2(DEPTH) : 1;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic          we_i = 1'b0, re_i = 1'b0;
  logic [AW-1:0] waddr_i = '0, raddr_i = '0;
  logic [W-1:0]  wdata_i = '0, rdata_o;

  ram_sdp #(.W(W), .DEPTH(DEPTH), .RD_LAT(RD_LAT)) dut (
    .clk(clk), .rst_n(rst_n), .we_i(we_i), .waddr_i(waddr_i), .wdata_i(wdata_i),
    .re_i(re_i), .raddr_i(raddr_i), .rdata_o(rdata_o));

  tb_checker c_rd = new("read"), c_cov = new("coverage");

  logic [W-1:0] mref [DEPTH];
  typedef struct { longint at; logic [W-1:0] v; } rd_t;
  rd_t rq[$];
  logic [W-1:0] cur;
  bit cur_ok = 1'b0;
  longint nidx = 0;
  int n_coll = 0, n_noread = 0, n_reads = 0, n_writes = 0;
  bit go = 1'b0;

  always @(negedge clk) begin
    nidx++;
    if (rst_n && go) begin
      if (rq.size() != 0 && rq[0].at == nidx) begin
        cur    = rq[0].v;
        void'(rq.pop_front());
        cur_ok = 1'b1;
      end
      if (cur_ok) begin
        if (rdata_o !== cur) c_rd.fail($sformatf("negedge %0d rdata %h exp %h", nidx, rdata_o, cur));
        else c_rd.pass();
      end
      if (re_i === 1'b1) begin
        rd_t r;
        r.at = nidx + RD_LAT;
        r.v  = (int'(raddr_i) < DEPTH) ? mref[raddr_i] : 'x;
        rq.push_back(r);
        n_reads++;
        if (we_i === 1'b1 && waddr_i == raddr_i) n_coll++;
      end else n_noread++;
      if (we_i === 1'b1 && int'(waddr_i) < DEPTH) begin
        mref[waddr_i] = wdata_i;
        n_writes++;
      end
    end
  end

  int n_cyc = 200000, neg = 0;
  int unsigned seed;

  function automatic logic [W-1:0] rdata();
    logic [W-1:0] v;
    for (int i = 0; i < W; i += 32) v[i +: 32] = $urandom();
    return v;
  endfunction

  initial begin
    static int inj = 0;
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("N=%d", n_cyc));
    void'($value$plusargs("NEG=%d", neg));
    $display("tb_ram_sdp: W=%0d DEPTH=%0d RD_LAT=%0d LATENCY=%0d seed=%0d N=%0d NEG=%0d",
             W, DEPTH, RD_LAT, dut.LATENCY, seed, n_cyc, neg);
    if (dut.LATENCY != RD_LAT) c_cov.fail("LATENCY localparam != RD_LAT");
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    @(posedge clk);
    go = 1'b1;
    // phase 0: fill
    for (int a = 0; a < DEPTH; a++) begin
      @(posedge clk);
      we_i    <= 1'b1;
      waddr_i <= AW'(a);
      wdata_i <= rdata();
      re_i    <= (a > 0) && $urandom_range(1);
      raddr_i <= (a > 0) ? AW'($urandom_range(a - 1)) : '0;
    end
    // phase 1: random
    for (int c = 0; c < n_cyc; c++) begin
      automatic bit w = $urandom_range(1), r = $urandom_range(99) < 60;
      automatic int wa = $urandom_range(DEPTH - 1), ra = $urandom_range(DEPTH - 1);
      if ($urandom_range(4) == 0) begin w = 1; r = 1; ra = wa; end
      @(posedge clk);
      we_i    <= w;
      waddr_i <= AW'(wa);
      wdata_i <= rdata();
      re_i    <= r;
      raddr_i <= AW'(ra);
      if (neg != 0 && inj == 0 && c == n_cyc / 2) begin
        inj = 1;
        case (neg)
          1: begin we_i <= 1'b1; waddr_i <= AW'(DEPTH); end
          2: begin re_i <= 1'b1; raddr_i <= AW'(DEPTH); end
          default: we_i <= 1'bx;
        endcase
      end
    end
    @(posedge clk);
    we_i <= 1'b0;
    re_i <= 1'b0;
    repeat (RD_LAT + 3) @(posedge clk);
    if (rq.size() != 0) c_rd.fail($sformatf("%0d reads not seen", rq.size()));
    $display("coverage: reads %0d writes %0d same-address %0d no-read cycles %0d",
             n_reads, n_writes, n_coll, n_noread);
    if (n_coll == 0 || n_noread == 0 || (neg != 0 && inj == 0)) c_cov.fail("coverage or injection missing");
    else c_cov.pass();
    void'(tb_final_report('{c_rd, c_cov}));
    $finish;
  end
endmodule
