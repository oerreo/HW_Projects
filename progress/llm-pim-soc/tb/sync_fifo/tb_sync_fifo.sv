// tb_sync_fifo: sync_fifo against a SystemVerilog queue reference model.
//
// Every cycle (negedge): out_valid_o == (model not empty), in_ready_o == (model not
// full), level_o == model size, out_data_o == model front; then the handshakes of the
// cycle (push = in_valid && in_ready, pop = out_valid && out_ready) update the model.
// The producer obeys valid/ready (holds valid and data while not accepted). Phases of
// 2,000 cycles cycle through valid/ready probabilities (90/90, 95/5 fill to full,
// 5/95 drain to empty, 50/50, 100/100 simultaneous, 70/30, 30/70). Coverage counters
// (full with a pending push, empty with a pending pop, push and pop in one cycle, push and
// pop at full, level reaching DEPTH and 0) must all be non-zero.
// Negative runs (+NEG): 1 drops in_valid while it waits (VR_HOLD), 2 changes in_data
// while it waits (VR_STABLE), 3 drives in_valid = X for one cycle while full (VR_X).
// Each is injected once; the data checks still pass.
// Plusargs: +SEED=<n> +N=<cycles, default 200000> +NEG=<0..3>.
`timescale 1ns / 1ps
module tb_sync_fifo;
  import tb_util_pkg::*;

  parameter int W     = 16;
  parameter int DEPTH = 16;
  localparam int LW = $clog2(DEPTH + 1);

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic          in_valid_i = 1'b0, in_ready_o, out_valid_o, out_ready_i = 1'b0;
  logic [W-1:0]  in_data_i = '0, out_data_o;
  logic [LW-1:0] level_o;

  sync_fifo #(.W(W), .DEPTH(DEPTH)) dut (
    .clk(clk), .rst_n(rst_n), .in_valid_i(in_valid_i), .in_ready_o(in_ready_o),
    .in_data_i(in_data_i), .out_valid_o(out_valid_o), .out_ready_i(out_ready_i),
    .out_data_o(out_data_o), .level_o(level_o));

  tb_checker c_data = new("data"), c_flag = new("flags"), c_cov = new("coverage");

  logic [W-1:0] mq[$];
  bit acc_q = 1'b0;          // in handshake of the last cycle (sampled at negedge)
  bit stalled_q = 1'b0;      // in_valid and not ready at the last negedge
  int n_full_push = 0, n_empty_pop = 0, n_both = 0, n_both_full = 0, n_full = 0, n_empty = 0,
      n_push = 0, n_pop = 0;
  bit go = 1'b0;

  always @(negedge clk) begin
    if (rst_n && go) begin
      bit push, pop;
      // flags
      if (out_valid_o !== (mq.size() != 0) || in_ready_o !== (mq.size() != DEPTH) ||
          level_o !== LW'(mq.size()))
        c_flag.fail($sformatf("size %0d: out_valid %b in_ready %b level %0d", mq.size(),
                              out_valid_o, in_ready_o, level_o));
      else c_flag.pass();
      if (mq.size() != 0) begin
        if (out_data_o !== mq[0]) c_data.fail($sformatf("front got %h exp %h", out_data_o, mq[0]));
        else c_data.pass();
      end
      push = in_valid_i === 1'b1 && in_ready_o === 1'b1;
      pop  = out_valid_o === 1'b1 && out_ready_i === 1'b1;
      if (in_valid_i === 1'b1 && in_ready_o === 1'b0) n_full_push++;
      if (out_ready_i === 1'b1 && out_valid_o === 1'b0) n_empty_pop++;
      if (push && pop) n_both++;
      if (pop && in_valid_i === 1'b1 && mq.size() == DEPTH) n_both_full++;
      if (mq.size() == DEPTH) n_full++;
      if (mq.size() == 0) n_empty++;
      if (pop) begin void'(mq.pop_front()); n_pop++; end
      if (push) begin mq.push_back(in_data_i); n_push++; end
      acc_q     = push;
      stalled_q = in_valid_i === 1'b1 && !push;
    end
  end

  int n_cyc = 200000, neg = 0;
  int unsigned seed;
  int pv_tab[7] = '{90, 95, 5, 50, 100, 70, 30};
  int pr_tab[7] = '{90, 5, 95, 50, 100, 30, 70};

  initial begin
    static int inj_done = 0;
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("N=%d", n_cyc));
    void'($value$plusargs("NEG=%d", neg));
    $display("tb_sync_fifo: W=%0d DEPTH=%0d seed=%0d N=%0d NEG=%0d", W, DEPTH, seed, n_cyc, neg);
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    @(posedge clk);
    go = 1'b1;
    for (int c = 0; c < n_cyc; c++) begin
      automatic int ph = (c / 2000) % 7;
      automatic bit want_v = $urandom_range(99) < pv_tab[ph];
      @(posedge clk);
      out_ready_i <= $urandom_range(99) < pr_tab[ph];
      if (neg != 0 && inj_done == 0 && c > 1000 && stalled_q && neg != 3) begin
        inj_done = 1;
        if (neg == 1) in_valid_i <= 1'b0;                 // VR_HOLD
        else          in_data_i  <= in_data_i ^ W'(1);    // VR_STABLE (valid kept)
      end else if (neg == 3 && inj_done == 0 && c > 1000 && !in_valid_i && mq.size() == DEPTH) begin
        inj_done = 1;
        in_valid_i <= 1'bx;                                // VR_X (cannot push: full)
      end else if (stalled_q && in_valid_i === 1'b1) begin
        // hold valid and data
      end else begin
        in_valid_i <= want_v;
        in_data_i  <= W'({$urandom(), $urandom()});
      end
    end
    // drain: a waiting push is completed first (valid/ready rule), then valid drops
    for (int c = 0; c < DEPTH + 8; c++) begin
      @(posedge clk);
      out_ready_i <= 1'b1;
      if (!(stalled_q && in_valid_i === 1'b1)) in_valid_i <= 1'b0;
    end
    if (mq.size() != 0) c_flag.fail($sformatf("%0d entries left after drain", mq.size()));
    if (neg != 0 && inj_done == 0) c_cov.fail("negative case was not injected");
    $display("coverage: push %0d pop %0d full-cycles %0d empty-cycles %0d push-at-full %0d pop-at-empty %0d push&pop %0d pop-at-full-with-valid %0d",
             n_push, n_pop, n_full, n_empty, n_full_push, n_empty_pop, n_both, n_both_full);
    if (n_full == 0 || n_empty == 0 || n_full_push == 0 || n_empty_pop == 0 || n_both_full == 0 ||
        (DEPTH > 1 && n_both == 0))
      c_cov.fail("a coverage counter is zero");
    else c_cov.pass();
    void'(tb_final_report('{c_data, c_flag, c_cov}));
    $finish;
  end
endmodule
