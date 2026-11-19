// sync_fifo: single-clock valid/ready FIFO, first-word fall-through (hierarchy.md 3.2).
//
//   in_ready_o  = level != DEPTH (does not depend on out_ready_i: no combinational
//                 path from the output side to the input side; a push into a full FIFO
//                 waits even when a pop happens in the same cycle)
//   out_valid_o = level != 0, out_data_o = oldest entry (register array read)
//   level_o     = number of entries
// Simultaneous push and pop are allowed in every non-full, non-empty state.
// DEPTH may be any value >= 1 (pointers wrap at DEPTH - 1).
//
// Simulation-only checks of the input stream (tag = first word of the message):
//   VR_X       X/Z on in_valid_i or out_ready_i after reset
//   VR_HOLD    in_valid_i dropped while it was waiting for in_ready_o
//   VR_STABLE  in_data_i changed while in_valid_i waited for in_ready_o
module sync_fifo #(
  parameter int W     = 32,
  parameter int DEPTH = 16
) (
  input  logic                       clk,
  input  logic                       rst_n,
  input  logic                       in_valid_i,
  output logic                       in_ready_o,
  input  logic [W-1:0]               in_data_i,
  output logic                       out_valid_o,
  input  logic                       out_ready_i,
  output logic [W-1:0]               out_data_o,
  output logic [$clog2(DEPTH+1)-1:0] level_o
);
  localparam int PW = (DEPTH > 1) ? $clog2(DEPTH) : 1;
  localparam int LW = $clog2(DEPTH + 1);

  if (W < 1) $error("sync_fifo: W=%0d must be >= 1", W);
  if (DEPTH < 1) $error("sync_fifo: DEPTH=%0d must be >= 1", DEPTH);

  logic [W-1:0]  mem [DEPTH];
  logic [PW-1:0] wptr_q, rptr_q;
  logic [LW-1:0] level_q;
  logic          push, pop;

  assign in_ready_o  = level_q != LW'(DEPTH);
  assign out_valid_o = level_q != '0;
  assign out_data_o  = mem[rptr_q];
  assign level_o     = level_q;
  assign push        = in_valid_i && in_ready_o;
  assign pop         = out_valid_o && out_ready_i;

  function automatic logic [PW-1:0] inc(logic [PW-1:0] p);
    return (p == PW'(DEPTH - 1)) ? '0 : p + 1'b1;
  endfunction

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      wptr_q  <= '0;
      rptr_q  <= '0;
      level_q <= '0;
    end else begin
      if (push) wptr_q <= inc(wptr_q);
      if (pop)  rptr_q <= inc(rptr_q);
      if (push && !pop)      level_q <= level_q + 1'b1;
      else if (pop && !push) level_q <= level_q - 1'b1;
    end

  always_ff @(posedge clk)
    if (push) mem[wptr_q] <= in_data_i;

`ifndef SYNTHESIS
  logic         chk_pend_q;
  logic [W-1:0] chk_data_q;
  always @(posedge clk) begin
    if (rst_n === 1'b1) begin
      if ($isunknown(in_valid_i) || $isunknown(out_ready_i))
        $error("VR_X sync_fifo %m: in_valid_i=%b out_ready_i=%b", in_valid_i, out_ready_i);
      if (chk_pend_q && in_valid_i === 1'b0)
        $error("VR_HOLD sync_fifo %m: in_valid_i dropped before in_ready_o");
      if (chk_pend_q && in_valid_i === 1'b1 && in_data_i !== chk_data_q)
        $error("VR_STABLE sync_fifo %m: in_data_i changed while waiting (%h -> %h)", chk_data_q, in_data_i);
    end
    chk_pend_q <= rst_n === 1'b1 && in_valid_i === 1'b1 && in_ready_o === 1'b0;
    chk_data_q <= in_data_i;
  end
`endif

endmodule
