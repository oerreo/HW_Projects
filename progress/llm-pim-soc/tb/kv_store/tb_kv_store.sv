// tb_kv_store: kv_store against a TB shadow memory (the store is a memory; the golden layout of
// the K/V buffers is checked at attn_top with real records).
// Phase 1: +NW random writes (random kv head, layer, position; K / V inside KW / VW bits, edges
// -2^(b-1) and 2^(b-1) - 1; random scales), including rewrites of the same slot.
// Phase 2: on every port concurrently, +NP random pass requests (kv head of the port, random
// layer, T 1..SEQ (also SEQ), pass K or V); every beat must equal the shadow word (lanes
// sign-extended, scales), exactly T beats per request, in position order. Consumer ready is
// random (+PY percent) with long blocks (+BLK) that must fill the port FIFO (coverage).
// Writes may also run during the reads to other slots (+WR_DURING=1).
// Throughput (+PY=100): a pass of T beats must end within T + 3 cycles of its request.
// Negative: +NEG=1 request on the wrong port (L2_RANGE), +NEG=2 K value outside KW bits (L2_RANGE).
// Plusargs: +SEED +NW +NP +PY +BLK +WR_DURING +NEG.
`timescale 1ns / 1ps
module tb_kv_store;
  import tb_util_pkg::*;
  import llm_pkg::*;

  parameter int NKV    = 4;
  parameter int NL     = 5;
  parameter int SEQ    = 512;
  parameter int KL     = 8;
  parameter int KW     = 12;
  parameter int VW     = 8;
  parameter int H_PAR  = 2;
  parameter int FIFO_D = 4;
  localparam int KVH_W = (NKV > 1) ? $clog2(NKV) : 1;
  localparam int L_W   = (NL > 1) ? $clog2(NL) : 1;
  localparam int TW    = $clog2(SEQ + 1);
  localparam int PW    = (SEQ > 1) ? $clog2(SEQ) : 1;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic                        w_valid_i = 1'b0;
  logic [KVH_W-1:0]            w_kvh_i = '0;
  logic [L_W-1:0]              w_layer_i = '0;
  logic [PW-1:0]               w_pos_i = '0;
  logic [KL*16-1:0]            w_k_i = '0, w_v_i = '0;
  logic [AM_W-1:0]             w_km_i = '0, w_vm_i = '0;
  logic signed [E_W-1:0]       w_ke_i = '0, w_ve_i = '0;
  logic [H_PAR-1:0]            rq_valid_i = '0, rq_ready_o, rq_pass_i = '0;
  logic [H_PAR-1:0][KVH_W-1:0] rq_kvh_i = '0;
  logic [H_PAR-1:0][L_W-1:0]   rq_layer_i = '0;
  logic [H_PAR-1:0][TW-1:0]    rq_t_i = '0;
  logic [H_PAR-1:0]            kv_valid_o, kv_ready_i = '0, busy_o;
  logic [H_PAR-1:0][KL*16-1:0] kv_data_o;
  logic [H_PAR-1:0][AM_W-1:0]  kv_km_o, kv_vm_o;
  logic [H_PAR-1:0][E_W-1:0]   kv_ke_o, kv_ve_o;

  kv_store #(.NKV(NKV), .NL(NL), .SEQ(SEQ), .KL(KL), .KW(KW), .VW(VW), .H_PAR(H_PAR),
             .FIFO_D(FIFO_D)) dut (.*);

  tb_checker c_beat = new("beats"), c_cnt = new("count"), c_thr = new("throughput"),
             c_cov = new("coverage");

  // shadow: per slot (kvh, layer, pos) the written word
  typedef struct { int k[KL], v[KL], km, ke, vm, ve; bit w; } slot_t;
  slot_t mem [NKV][NL][SEQ];
  int py = 70, blk = 0, neg = 0;
  int blk_left [H_PAR];
  longint n_full = 0, cyc = 0;

  always @(posedge clk) cyc <= cyc + 1;

  function automatic int rv(int b);
    case ($urandom_range(9))
      0: return -(1 << (b - 1));
      1: return (1 << (b - 1)) - 1;
      default: return int'($urandom_range((1 << b) - 1)) - (1 << (b - 1));
    endcase
  endfunction

  task automatic write_slot(int j, int l, int t, bit bad = 0);
    slot_t s;
    for (int i = 0; i < KL; i++) begin
      s.k[i] = rv(KW);
      s.v[i] = rv(VW);
    end
    if (bad) s.k[0] = 1 << (KW - 1);   // outside KW bits
    s.km = $urandom_range((1 << AM_W) - 1); s.vm = $urandom_range((1 << AM_W) - 1);
    s.ke = int'($urandom_range(255)) - 128; s.ve = int'($urandom_range(255)) - 128;
    s.w = 1;
    w_valid_i <= 1'b1;
    w_kvh_i   <= KVH_W'(j);
    w_layer_i <= L_W'(l);
    w_pos_i   <= PW'(t);
    for (int i = 0; i < KL; i++) begin
      w_k_i[i*16 +: 16] <= 16'(s.k[i]);
      w_v_i[i*16 +: 16] <= 16'(s.v[i]);
    end
    w_km_i <= AM_W'(s.km); w_ke_i <= E_W'(s.ke); w_vm_i <= AM_W'(s.vm); w_ve_i <= E_W'(s.ve);
    if (!bad) mem[j][l][t] = s;
    @(posedge clk);
    w_valid_i <= 1'b0;
  endtask

  // consumer ready per port
  always @(posedge clk)
    for (int p = 0; p < H_PAR; p++) begin
      if (blk && blk_left[p] > 0) begin
        kv_ready_i[p] <= 1'b0;
        blk_left[p]--;
      end else begin
        kv_ready_i[p] <= $urandom_range(99) < py;
        if (blk && $urandom_range(199) == 0) blk_left[p] = $urandom_range(30, 8);
      end
    end

  logic [H_PAR-1:0] fifo_full;
  for (genvar p = 0; p < H_PAR; p++) begin : g_full
    assign fifo_full[p] = dut.g_port[p].level == FIFO_D;
  end
  always @(negedge clk)
    if (rst_n && |fifo_full) n_full++;

  // one port: NP requests
  task automatic port_run(int p, int np);
    for (int r = 0; r < np; r++) begin
      int j, l, T, pass, got = 0;
      longint t0;
      do j = $urandom_range(NKV - 1); while (j % H_PAR != p);
      l = $urandom_range(NL - 1);
      T = $urandom_range(9) == 0 ? SEQ : $urandom_range(SEQ < 64 ? SEQ : 64, 1);
      pass = $urandom_range(1);
      @(posedge clk);
      while (busy_o[p] !== 1'b0) @(posedge clk);
      rq_valid_i[p] <= 1'b1;
      rq_pass_i[p]  <= pass;
      rq_kvh_i[p]   <= KVH_W'(j);
      rq_layer_i[p] <= L_W'(l);
      rq_t_i[p]     <= TW'(T);
      t0 = cyc + 1;
      @(posedge clk);
      rq_valid_i[p] <= 1'b0;
      rq_kvh_i[p] <= $urandom(); rq_t_i[p] <= $urandom(); rq_layer_i[p] <= $urandom();
      while (got < T) begin
        @(negedge clk);
        if (kv_valid_o[p] === 1'b1 && kv_ready_i[p] === 1'b1) begin
          slot_t s = mem[j][l][got];
          bit ok = s.w;
          for (int i = 0; i < KL; i++)
            if (int'($signed(kv_data_o[p][i*16 +: 16])) != (pass ? s.v[i] : s.k[i])) ok = 0;
          if (int'(kv_km_o[p]) != s.km || int'($signed(kv_ke_o[p])) != s.ke ||
              int'(kv_vm_o[p]) != s.vm || int'($signed(kv_ve_o[p])) != s.ve) ok = 0;
          if (!ok) c_beat.fail($sformatf("port %0d kvh %0d layer %0d pos %0d pass %0d", p, j, l, got, pass));
          else c_beat.pass();
          got++;
        end
      end
      if (py == 100) begin
        if (cyc - t0 > T + 3) c_thr.fail($sformatf("port %0d T %0d took %0d cycles", p, T, cyc - t0));
        else c_thr.pass();
      end
      @(posedge clk);
      @(negedge clk);
      if (kv_valid_o[p] !== 1'b0) c_cnt.fail($sformatf("port %0d: extra beat after T %0d", p, T));
      else c_cnt.pass();
    end
  endtask

  initial begin
    automatic int unsigned seed;
    automatic int nw = 3000, np = 40, wrd = 0;
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("NW=%d", nw));
    void'($value$plusargs("NP=%d", np));
    void'($value$plusargs("PY=%d", py));
    void'($value$plusargs("BLK=%d", blk));
    void'($value$plusargs("WR_DURING=%d", wrd));
    void'($value$plusargs("NEG=%d", neg));
    $display("tb_kv_store: NKV %0d NL %0d SEQ %0d KW %0d VW %0d H_PAR %0d FIFO_D %0d seed %0d", NKV, NL,
             SEQ, KW, VW, H_PAR, FIFO_D, seed);
    foreach (blk_left[p]) blk_left[p] = 0;
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    @(posedge clk);
    // fill every slot that the passes read (layer x positions 0..SEQ-1 of every head)
    for (int j = 0; j < NKV; j++)
      for (int l = 0; l < NL; l++)
        for (int t = 0; t < SEQ; t++) write_slot(j, l, t);
    for (int i = 0; i < nw; i++) write_slot($urandom_range(NKV - 1), $urandom_range(NL - 1), $urandom_range(SEQ - 1));
    if (neg == 2) begin
      write_slot(0, 0, 0, 1);  // out of range (stored truncated), then rewritten legally
      write_slot(0, 0, 0);
    end
    if (neg == 1 && H_PAR > 1) begin
      @(posedge clk);
      rq_valid_i[0] <= 1'b1;
      rq_kvh_i[0]   <= KVH_W'(1);   // kv head 1 belongs to port 1
      rq_layer_i[0] <= '0;
      rq_t_i[0]     <= TW'(1);
      @(posedge clk);
      rq_valid_i[0] <= 1'b0;
      repeat (10) @(posedge clk);
    end
    fork
      begin
        for (int p = 0; p < H_PAR; p++) begin
          automatic int pp = p;
          fork port_run(pp, np); join_none
        end
        wait fork;
      end
    join
    repeat (5) @(posedge clk);
    if (blk) begin
      if (n_full > 0) c_cov.pass();
      else c_cov.fail("port FIFO never full");
    end
    begin
      automatic tb_checker_q l = '{c_beat, c_cnt};
      if (py == 100) l.push_back(c_thr);
      if (blk) l.push_back(c_cov);
      void'(tb_final_report(l));
    end
    $finish;
  end

  // watchdog: a lost beat must not hang the run
  initial begin
    automatic longint tmo = 20000000;
    void'($value$plusargs("TMO=%d", tmo));
    repeat (tmo) @(posedge clk);
    $fatal(1, "TB_TIMEOUT: no end after %0d cycles", tmo);
  end

endmodule
