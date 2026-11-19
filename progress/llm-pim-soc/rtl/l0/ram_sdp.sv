// ram_sdp: simple dual-port RAM (one write port, one read port, one clock), inferred
// (no vendor primitive; FPGA/ASIC replacement point, hierarchy.md 3.2).
//
//   write: we_i at a clock edge writes wdata_i to waddr_i
//   read : re_i at a clock edge reads raddr_i; rdata_o shows the word RD_LAT edges later
//          and keeps it until the next read reaches the output (no update without re_i)
//   read and write of the same address in the same cycle return the OLD word
//          (read-first)
//   RD_LAT 1: registered read (BRAM / LUTRAM + output FF), 2: plus an output register
// Contents are not reset or initialized.
//
// Simulation-only checks (tag = first word of the message):
//   RAM_X     X/Z on we_i or re_i after reset, or on the address of an enabled port
//   RAM_ADDR  enabled port with address >= DEPTH (only possible if DEPTH is not a power
//             of two); the write is dropped, the read returns X
module ram_sdp #(
  parameter int W      = 64,
  parameter int DEPTH  = 128,
  parameter int RD_LAT = 1
) (
  input  logic                              clk,
  input  logic                              rst_n,
  input  logic                              we_i,
  input  logic [(DEPTH>1?$clog2(DEPTH):1)-1:0] waddr_i,
  input  logic [W-1:0]                      wdata_i,
  input  logic                              re_i,
  input  logic [(DEPTH>1?$clog2(DEPTH):1)-1:0] raddr_i,
  output logic [W-1:0]                      rdata_o
);
  localparam int AW      = (DEPTH > 1) ? $clog2(DEPTH) : 1;
  localparam int LATENCY = RD_LAT;

  if (W < 1) $error("ram_sdp: W=%0d must be >= 1", W);
  if (DEPTH < 2) $error("ram_sdp: DEPTH=%0d must be >= 2", DEPTH);
  if (RD_LAT < 1 || RD_LAT > 2) $error("ram_sdp: RD_LAT=%0d must be 1 or 2", RD_LAT);

  logic [W-1:0] mem [DEPTH];
  logic [W-1:0] rd_q;

  always_ff @(posedge clk) begin
    if (we_i) mem[waddr_i] <= wdata_i;
    if (re_i) rd_q <= mem[raddr_i];
  end

  if (RD_LAT == 2) begin : g_lat2
    logic         re_q;
    logic [W-1:0] out_q;
    always_ff @(posedge clk or negedge rst_n)
      if (!rst_n) re_q <= 1'b0;
      else        re_q <= re_i;
    always_ff @(posedge clk)
      if (re_q) out_q <= rd_q;
    assign rdata_o = out_q;
  end else begin : g_lat1
    assign rdata_o = rd_q;
  end

`ifndef SYNTHESIS
  always @(posedge clk) begin
    if (rst_n === 1'b1) begin
      if ($isunknown(we_i) || $isunknown(re_i))
        $error("RAM_X ram_sdp %m: we_i=%b re_i=%b", we_i, re_i);
      else begin
        if (we_i && $isunknown(waddr_i)) $error("RAM_X ram_sdp %m: X on waddr_i");
        if (re_i && $isunknown(raddr_i)) $error("RAM_X ram_sdp %m: X on raddr_i");
        if (we_i && !$isunknown(waddr_i) && int'(waddr_i) >= DEPTH)
          $error("RAM_ADDR ram_sdp %m: write address %0d >= DEPTH %0d", waddr_i, DEPTH);
        if (re_i && !$isunknown(raddr_i) && int'(raddr_i) >= DEPTH)
          $error("RAM_ADDR ram_sdp %m: read address %0d >= DEPTH %0d", raddr_i, DEPTH);
      end
    end
  end
`endif

endmodule
