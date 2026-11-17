// coef_ram: one coefficient bank of pqc-ntt-ip (L2), 256 x 12b true dual-port
// RAM wrapper. ntt_core instantiates two (bank0, bank1).
//
// ASIC / FPGA replacement point: the body below is an inferable behavioral
// RAM (FPGA: block RAM or distributed RAM, true dual port). For ASIC, replace
// the body with a dual-port SRAM macro (or a register-file macro) and keep the
// port contract below; if the macro does not hold its output while not
// reading, add an enable-gated output register in this wrapper.
//
// Port contract (ports A and B are identical and independent, one clock):
//   en_x_i = 1, we_x_i = 1 : write wdata_x_i to addr_x_i at the rising edge.
//   en_x_i = 1, we_x_i = 0 : read addr_x_i; rdata_x_o shows the word from the
//                            next cycle (LATENCY = 1).
//   en_x_i = 0             : no access.
//   rdata_x_o changes only after a read of port x and holds otherwise (also
//   during and after a write on port x: "no change" mode). ntt_ctrl relies on
//   the hold for UNLOAD backpressure.
//
// Collisions (both ports, same cycle, same address):
//   read  / read  : allowed, both ports return the stored word.
//   write / read  : forbidden (read data undefined in general, simulation
//                   returns the old word). Assertion L2_RAM_RW.
//   write / write : forbidden (stored word undefined). Assertion L2_RAM_WW.
//   ntt_ctrl schedules never produce the forbidden cases.
//
// Coding style: the two ports are two separate clocked processes on a shared
// array, as in the vendor true dual-port templates. They use plain "always"
// instead of always_ff because SystemVerilog forbids writing one variable
// from two always_ff processes; this is the only exception to the always_ff
// rule in the L2 RTL. No reset: memory contents and read registers are data.
module coef_ram
  import mlkem_pkg::*;
  import ntt_l2_pkg::*;
#(
  parameter int DEPTH = N_COEF,             // words
  parameter int AW    = $clog2(DEPTH)       // address width
) (
  input  logic              clk,
  input  logic              rst_n,          // only used by simulation checks
  // port A
  input  logic              en_a_i,
  input  logic              we_a_i,
  input  logic [AW-1:0]     addr_a_i,
  input  logic [COEF_W-1:0] wdata_a_i,
  output logic [COEF_W-1:0] rdata_a_o,
  // port B
  input  logic              en_b_i,
  input  logic              we_b_i,
  input  logic [AW-1:0]     addr_b_i,
  input  logic [COEF_W-1:0] wdata_b_i,
  output logic [COEF_W-1:0] rdata_b_o
);

  localparam int LATENCY = 1;   // read latency in cycles

  if (DEPTH < 2 || DEPTH > (1 << AW)) begin : g_bad_depth
    $error("coef_ram: DEPTH=%0d does not fit AW=%0d", DEPTH, AW);
  end

  logic [COEF_W-1:0] mem [DEPTH];
  logic [COEF_W-1:0] rdata_a_q, rdata_b_q;

  // Port A
  always @(posedge clk) begin : p_port_a
    if (en_a_i) begin
      if (we_a_i) mem[addr_a_i] <= wdata_a_i;
      else        rdata_a_q     <= mem[addr_a_i];
    end
  end

  // Port B
  always @(posedge clk) begin : p_port_b
    if (en_b_i) begin
      if (we_b_i) mem[addr_b_i] <= wdata_b_i;
      else        rdata_b_q     <= mem[addr_b_i];
    end
  end

  assign rdata_a_o = rdata_a_q;
  assign rdata_b_o = rdata_b_q;

`ifndef SYNTHESIS
  // Control inputs must be known after reset; addresses must be known and in
  // range when the port is enabled.
  always_comb begin
    if (rst_n === 1'b1) begin
      ctl_known : assert final (!$isunknown({en_a_i, en_b_i}))
        else $error("L2_RAM_X coef_ram: en_a_i=%b en_b_i=%b", en_a_i, en_b_i);
      if (en_a_i === 1'b1) begin
        a_ok : assert final (!$isunknown({we_a_i, addr_a_i}) && int'(addr_a_i) < DEPTH)
          else $error("L2_RAM_X coef_ram: port A we=%b addr=%0d", we_a_i, addr_a_i);
      end
      if (en_b_i === 1'b1) begin
        b_ok : assert final (!$isunknown({we_b_i, addr_b_i}) && int'(addr_b_i) < DEPTH)
          else $error("L2_RAM_X coef_ram: port B we=%b addr=%0d", we_b_i, addr_b_i);
      end
    end
  end

  // Forbidden same-address collisions.
  always_comb begin
    if (rst_n === 1'b1 && en_a_i === 1'b1 && en_b_i === 1'b1 && addr_a_i === addr_b_i) begin
      no_ww : assert final (!(we_a_i === 1'b1 && we_b_i === 1'b1))
        else $error("L2_RAM_WW coef_ram: both ports write addr %0d", addr_a_i);
      no_rw : assert final (we_a_i === we_b_i)
        else $error("L2_RAM_RW coef_ram: write and read of addr %0d in the same cycle (port A we=%b)",
                    addr_a_i, we_a_i);
    end
  end
`endif

endmodule
