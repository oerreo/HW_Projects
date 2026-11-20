// tb_kv_rd: kv_rd with axi_rd_eng on the AXI memory model (tb/common/axi_mem_slave.sv), against a
// TB reference built from the same arrays that are written into the model memory in the golden
// buffer layout (model/src/fwd_h.c: K / V rows of hs elements of ek / ev bytes, scales
// {int32 m, int32 e} per position).
// Per request: random T (1..TMAX, chunk edges CH-1, CH, CH+1), hs (multiple of 8 up to HS_MAX),
// ek / ev in {1, 2}, pass K or V, random 8-byte-aligned bases (4 KiB crossings); random element
// values (full 8 / 16-bit range), m < 2^17, e in -128..127. Every output beat must equal the
// reference (K pass: lanes sign-extended, the position's ks and vs on every beat; V pass: lanes,
// scales 0), exactly T x hs/8 beats per request.
// Stall: memory AR / R stall and latency (+MSTALL), consumer ready (+PY percent) with long
// blocks (+BLK; the engine read buffer must fill: coverage).
// Plusargs: +SEED +NREQ +MSTALL=0|1 +PY +BLK.
`timescale 1ns / 1ps
module tb_kv_rd;
  import tb_util_pkg::*;
  import llm_pkg::*;

  parameter int HS_MAX    = 64;
  parameter int TMAX      = 512;
  parameter int CH        = 16;
  parameter int MAX_BURST = 16;
  parameter int OUTS      = 4;
  localparam int KL   = 8;
  localparam int HS_W = $clog2(HS_MAX + 1);
  localparam int TW   = $clog2(TMAX + 1);

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic                  rq_valid_i = 1'b0, rq_ready_o, rq_pass_i = 1'b0, rq_ek2_i = 1'b0, rq_ev2_i = 1'b0;
  logic [TW-1:0]         rq_t_i = '0;
  logic [HS_W-1:0]       rq_hs_i = '0;
  logic [31:0]           rq_kaddr_i = '0, rq_vaddr_i = '0, rq_ksaddr_i = '0, rq_vsaddr_i = '0;
  logic                  rc_valid, rc_ready, d_valid, d_ready, d_last;
  logic [31:0]           rc_addr, rc_bytes;
  logic [63:0]           d_data;
  logic                  kv_valid_o, kv_ready_i = 1'b0, busy_o;
  logic [KL*16-1:0]      kv_data_o;
  logic [AM_W-1:0]       kv_km_o, kv_vm_o;
  logic signed [E_W-1:0] kv_ke_o, kv_ve_o;

  kv_rd #(.KL(KL), .HS_MAX(HS_MAX), .TMAX(TMAX), .CH(CH)) dut (
    .clk, .rst_n, .rq_valid_i, .rq_ready_o, .rq_pass_i, .rq_t_i, .rq_hs_i, .rq_ek2_i, .rq_ev2_i,
    .rq_kaddr_i, .rq_vaddr_i, .rq_ksaddr_i, .rq_vsaddr_i,
    .rc_valid_o(rc_valid), .rc_ready_i(rc_ready), .rc_addr_o(rc_addr), .rc_bytes_o(rc_bytes),
    .d_valid_i(d_valid), .d_ready_o(d_ready), .d_data_i(d_data),
    .kv_valid_o, .kv_ready_i, .kv_data_o, .kv_km_o, .kv_ke_o, .kv_vm_o, .kv_ve_o, .busy_o);

  // AXI
  logic [0:0]  arid, rid, awid, bid;
  logic [31:0] araddr, awaddr;
  logic [7:0]  arlen, awlen;
  logic [2:0]  arsize, arprot, awsize;
  logic [1:0]  arburst, rresp, awburst, bresp;
  logic        arlock, arvalid, arready, rlast, rvalid, rready;
  logic [3:0]  arcache, arqos;
  logic [63:0] rdata;
  logic        rd_stall, rd_busy, rd_ecmd, rd_eresp;

  axi_rd_eng #(.AW(32), .IDW(1), .LEN_W(32), .MAX_BURST(MAX_BURST), .OUTS(OUTS)) u_rd (
    .clk, .rst_n, .cfg_burst_i(9'd0), .cfg_outs_i(7'd0),
    .cmd_valid_i(rc_valid), .cmd_ready_o(rc_ready), .cmd_addr_i(rc_addr), .cmd_bytes_i(rc_bytes),
    .d_valid_o(d_valid), .d_ready_i(d_ready), .d_data_o(d_data), .d_last_o(d_last),
    .busy_o(rd_busy), .done_o(), .stall_o(rd_stall), .err_resp_o(rd_eresp), .err_cmd_o(rd_ecmd), .err_clr_i(1'b0),
    .m_axi_arid_o(arid), .m_axi_araddr_o(araddr), .m_axi_arlen_o(arlen), .m_axi_arsize_o(arsize),
    .m_axi_arburst_o(arburst), .m_axi_arlock_o(arlock), .m_axi_arcache_o(arcache),
    .m_axi_arprot_o(arprot), .m_axi_arqos_o(arqos), .m_axi_arvalid_o(arvalid),
    .m_axi_arready_i(arready), .m_axi_rid_i(rid), .m_axi_rdata_i(rdata), .m_axi_rresp_i(rresp),
    .m_axi_rlast_i(rlast), .m_axi_rvalid_i(rvalid), .m_axi_rready_o(rready));

  axi_mem_slave #(.DW(64), .AW(32), .IDW(1), .MAX_LEN(15)) u_mem (
    .clk, .rst_n,
    .awid_i(1'b0), .awaddr_i('0), .awlen_i('0), .awsize_i(3'd3), .awburst_i(2'b01), .awvalid_i(1'b0),
    .awready_o(), .wdata_i('0), .wstrb_i('0), .wlast_i(1'b0), .wvalid_i(1'b0), .wready_o(),
    .bid_o(), .bresp_o(), .bvalid_o(), .bready_i(1'b1),
    .arid_i(arid), .araddr_i(araddr), .arlen_i(arlen), .arsize_i(arsize), .arburst_i(arburst),
    .arvalid_i(arvalid), .arready_o(arready),
    .rid_o(rid), .rdata_o(rdata), .rresp_o(rresp), .rlast_o(rlast), .rvalid_o(rvalid), .rready_i(rready));

  tb_checker c_beat = new("beats"), c_cnt = new("count"), c_cov = new("coverage");

  int py = 70, blk = 0, blk_left = 0;
  longint n_full = 0, n_chunked = 0, n_4k = 0;
  typedef struct { logic [KL*16-1:0] d; int km, ke, vm, ve; } beat_t;
  beat_t expq[$];

  always @(posedge clk) begin
    if (blk && blk_left > 0) begin
      kv_ready_i <= 1'b0;
      blk_left--;
    end else begin
      kv_ready_i <= $urandom_range(99) < py;
      if (blk && $urandom_range(149) == 0) blk_left = $urandom_range(60, 20);
    end
  end

  always @(negedge clk)
    if (rst_n) begin
      if (u_rd.u_rbuf.level_q == MAX_BURST * OUTS) n_full++;
      if (kv_valid_o === 1'b1 && kv_ready_i === 1'b1) begin
        if (expq.size() == 0) c_cnt.fail("beat without expectation");
        else begin
          automatic beat_t x = expq.pop_front();
          if (kv_data_o !== x.d || int'(kv_km_o) != x.km || int'(kv_ke_o) != x.ke ||
              int'(kv_vm_o) != x.vm || int'(kv_ve_o) != x.ve)
            c_beat.fail($sformatf("beat %h km %0d ke %0d vm %0d ve %0d exp %h %0d %0d %0d %0d", kv_data_o,
                                  kv_km_o, kv_ke_o, kv_vm_o, kv_ve_o, x.d, x.km, x.ke, x.vm, x.ve));
          else c_beat.pass();
        end
      end
    end

  function automatic int rv(int bytes);
    int b = 8 * bytes;
    case ($urandom_range(9))
      0: return -(1 << (b - 1));
      1: return (1 << (b - 1)) - 1;
      default: return int'($urandom_range((1 << b) - 1)) - (1 << (b - 1));
    endcase
  endfunction

  longint unsigned base_next = 64'h0001_0000;
  function automatic longint unsigned alloc(longint unsigned bytes);
    longint unsigned a = base_next + 8 * $urandom_range(600);   // random 8 B offset
    base_next = (a + bytes + 4096 + 7) & ~64'd7;
    return a;
  endfunction

  task automatic one_req(int idx);
    int T, hs, ek, ev, pass, nb;
    longint unsigned ka, va, ksa, vsa;
    int K[], V[], km[], ke[], vm[], ve[];
    case (idx % 5)
      0: T = CH;
      1: T = CH + 1;
      2: T = $urandom_range(TMAX, 1);
      3: T = (CH > 1) ? CH - 1 : 1;
      default: T = $urandom_range(TMAX < 64 ? TMAX : 64, 1);
    endcase
    if (T > TMAX) T = TMAX;
    hs = 8 * $urandom_range(HS_MAX / 8, 1);
    ek = $urandom_range(1) + 1;
    ev = $urandom_range(1) + 1;
    pass = $urandom_range(1);
    nb = hs / 8;
    K = new[T * hs]; V = new[T * hs]; km = new[T]; ke = new[T]; vm = new[T]; ve = new[T];
    ka = alloc(T * hs * ek); va = alloc(T * hs * ev); ksa = alloc(T * 8); vsa = alloc(T * 8);
    if (T > CH) n_chunked++;
    if ((ka % 4096) + T * hs * ek > 4096) n_4k++;
    foreach (K[i]) begin
      K[i] = rv(ek);
      V[i] = rv(ev);
      for (int b = 0; b < ek; b++) u_mem.bd_write8(ka + i * ek + b, 8'(K[i] >> (8 * b)));
      for (int b = 0; b < ev; b++) u_mem.bd_write8(va + i * ev + b, 8'(V[i] >> (8 * b)));
    end
    for (int t = 0; t < T; t++) begin
      km[t] = $urandom_range((1 << AM_W) - 1); ke[t] = int'($urandom_range(255)) - 128;
      vm[t] = $urandom_range((1 << AM_W) - 1); ve[t] = int'($urandom_range(255)) - 128;
      u_mem.bd_write64(ksa + t * 8, {32'(ke[t]), 32'(km[t])});
      u_mem.bd_write64(vsa + t * 8, {32'(ve[t]), 32'(vm[t])});
    end
    for (int t = 0; t < T; t++)
      for (int g = 0; g < nb; g++) begin
        beat_t x;
        for (int l = 0; l < KL; l++) x.d[l*16 +: 16] = 16'(pass ? V[t * hs + g * 8 + l] : K[t * hs + g * 8 + l]);
        if (pass) begin x.km = 0; x.ke = 0; x.vm = 0; x.ve = 0; end
        else begin x.km = km[t]; x.ke = ke[t]; x.vm = vm[t]; x.ve = ve[t]; end
        expq.push_back(x);
      end
    // request
    @(posedge clk);
    while (rq_ready_o !== 1'b1) @(posedge clk);
    rq_valid_i  <= 1'b1;
    rq_pass_i   <= pass;
    rq_t_i      <= TW'(T);
    rq_hs_i     <= HS_W'(hs);
    rq_ek2_i    <= ek == 2;
    rq_ev2_i    <= ev == 2;
    rq_kaddr_i  <= 32'(ka); rq_vaddr_i <= 32'(va); rq_ksaddr_i <= 32'(ksa); rq_vsaddr_i <= 32'(vsa);
    @(posedge clk);
    rq_valid_i <= 1'b0;
    rq_kaddr_i <= $urandom(); rq_t_i <= $urandom();
    // wait until this request is consumed
    while (expq.size() > 0) @(posedge clk);
    c_cnt.pass();
  endtask

  initial begin
    automatic int unsigned seed;
    automatic int nreq = 100, mstall = 0;
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("NREQ=%d", nreq));
    void'($value$plusargs("MSTALL=%d", mstall));
    void'($value$plusargs("PY=%d", py));
    void'($value$plusargs("BLK=%d", blk));
    $display("tb_kv_rd: HS_MAX %0d TMAX %0d CH %0d seed %0d NREQ %0d", HS_MAX, TMAX, CH, seed, nreq);
    if (mstall) begin
      u_mem.cfg_stall(30, 0, 0, 30, 0);
      u_mem.cfg_lat(1, 20, 1, 1);
    end
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    for (int i = 0; i < nreq; i++) one_req(i);
    repeat (20) @(posedge clk);
    if (kv_valid_o !== 1'b0 || busy_o !== 1'b0) c_cnt.fail("extra beats or busy at the end");
    $display("tb_kv_rd: chunked %0d, 4 KiB crossing %0d, buffer full %0d cycles", n_chunked, n_4k, n_full);
    if (n_chunked > 0 && n_4k > 0 && (!blk || n_full > 0)) c_cov.pass();
    else c_cov.fail("coverage: chunked / 4 KiB / buffer full not reached");
    u_mem.check_idle();
    void'(tb_final_report('{c_beat, c_cnt, c_cov}));
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
