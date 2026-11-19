// axil_bfm: AXI4-Lite master BFM for testbenches (not synthesizable), S4-3.
//
// Written after the AXI4-Lite tasks of the pqc-ntt-ip top testbench (aw_phase / w_phase /
// b_phase / r_phase), reduced to one transaction at a time: write() drives AW and W (in the
// order and with the gaps chosen by maxd), waits for both handshakes and then for B; read()
// drives AR and waits for R. Inputs are driven at posedge with non-blocking assignments and the
// handshakes are sampled at negedge (design-methodology.md). VALID payloads are random junk
// while VALID = 0. BREADY / RREADY are raised after a random delay (0..maxd).
//
// Timing information for the caller: cyc counts posedges after reset; write() returns in
// t_hs the cycle in which the later of the AW and W handshakes happened (the slave then
// performs the write in t_hs + 1 when no B is pending, axil_slave header).
// Checks: BRESP / RRESP must be OKAY (tag AXIL_RESP), timeouts (AXIL_TIMEOUT).
module axil_bfm #(
  parameter int ADDR_W  = 12,
  parameter int TIMEOUT = 100000
) (
  input  logic              clk,
  input  logic              rst_n,
  output logic [ADDR_W-1:0] awaddr,
  output logic [2:0]        awprot,
  output logic              awvalid,
  input  logic              awready,
  output logic [31:0]       wdata,
  output logic [3:0]        wstrb,
  output logic              wvalid,
  input  logic              wready,
  input  logic [1:0]        bresp,
  input  logic              bvalid,
  output logic              bready,
  output logic [ADDR_W-1:0] araddr,
  output logic [2:0]        arprot,
  output logic              arvalid,
  input  logic              arready,
  input  logic [31:0]       rdata,
  input  logic [1:0]        rresp,
  input  logic              rvalid,
  output logic              rready
);

  int maxd = 0;                 // random delay bound (0: no gaps)
  longint unsigned cyc = 0;
  longint unsigned n_wr = 0, n_rd = 0;
  semaphore sem = new(1);

  initial begin
    awaddr = '0; awprot = '0; awvalid = 1'b0; wdata = '0; wstrb = '0; wvalid = 1'b0;
    bready = 1'b0; araddr = '0; arprot = '0; arvalid = 1'b0; rready = 1'b0;
  end

  always @(posedge clk or negedge rst_n)
    if (!rst_n) cyc <= 0;
    else cyc <= cyc + 1;

  function automatic int rnd(int n);
    return n <= 0 ? 0 : $urandom_range(n);
  endfunction

  task automatic aw_phase(logic [ADDR_W-1:0] a, int dly, output longint unsigned t);
    int n = 0;
    @(posedge clk);
    repeat (dly) @(posedge clk);
    awaddr  <= a;
    awprot  <= 3'($urandom_range(7));
    awvalid <= 1'b1;
    do begin
      @(negedge clk);
      if (++n > TIMEOUT) $fatal(1, "AXIL_TIMEOUT axil_bfm: AWREADY (addr 0x%0h)", a);
    end while (awready !== 1'b1);
    t = cyc;
    @(posedge clk);
    awvalid <= 1'b0;
    awaddr  <= ADDR_W'($urandom);
  endtask

  task automatic w_phase(logic [31:0] d, int dly, output longint unsigned t);
    int n = 0;
    @(posedge clk);
    repeat (dly) @(posedge clk);
    wdata  <= d;
    wstrb  <= 4'hF;
    wvalid <= 1'b1;
    do begin
      @(negedge clk);
      if (++n > TIMEOUT) $fatal(1, "AXIL_TIMEOUT axil_bfm: WREADY");
    end while (wready !== 1'b1);
    t = cyc;
    @(posedge clk);
    wvalid <= 1'b0;
    wdata  <= $urandom;
  endtask

  task automatic write(logic [ADDR_W-1:0] a, logic [31:0] d, output longint unsigned t_hs);
    longint unsigned ta, tw;
    int da, dw, n = 0;
    sem.get(1);
    da = rnd(maxd);
    dw = rnd(maxd);
    fork
      aw_phase(a, da, ta);
      w_phase(d, dw, tw);
    join
    t_hs = ta > tw ? ta : tw;
    repeat (rnd(maxd)) @(posedge clk);
    bready <= 1'b1;
    do begin
      @(negedge clk);
      if (++n > TIMEOUT) $fatal(1, "AXIL_TIMEOUT axil_bfm: BVALID (addr 0x%0h)", a);
    end while (bvalid !== 1'b1);
    if (bresp !== 2'b00) $error("AXIL_RESP axil_bfm: BRESP %0d at 0x%0h", bresp, a);
    @(posedge clk);
    bready <= 1'b0;
    n_wr++;
    sem.put(1);
  endtask

  task automatic write0(logic [ADDR_W-1:0] a, logic [31:0] d);
    longint unsigned t;
    write(a, d, t);
  endtask

  task automatic read(logic [ADDR_W-1:0] a, output logic [31:0] d);
    int n = 0;
    sem.get(1);
    @(posedge clk);
    repeat (rnd(maxd)) @(posedge clk);
    araddr  <= a;
    arprot  <= 3'($urandom_range(7));
    arvalid <= 1'b1;
    do begin
      @(negedge clk);
      if (++n > TIMEOUT) $fatal(1, "AXIL_TIMEOUT axil_bfm: ARREADY (addr 0x%0h)", a);
    end while (arready !== 1'b1);
    @(posedge clk);
    arvalid <= 1'b0;
    araddr  <= ADDR_W'($urandom);
    repeat (rnd(maxd)) @(posedge clk);
    rready <= 1'b1;
    n = 0;
    do begin
      @(negedge clk);
      if (++n > TIMEOUT) $fatal(1, "AXIL_TIMEOUT axil_bfm: RVALID (addr 0x%0h)", a);
    end while (rvalid !== 1'b1);
    d = rdata;
    if (rresp !== 2'b00) $error("AXIL_RESP axil_bfm: RRESP %0d at 0x%0h", rresp, a);
    @(posedge clk);
    rready <= 1'b0;
    n_rd++;
    sem.put(1);
  endtask

endmodule
