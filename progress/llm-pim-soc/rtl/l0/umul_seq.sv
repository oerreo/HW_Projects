// umul_seq: sequential unsigned multiplication p = a * b, one multiplier bit per cycle
// (shift-add, LSB of b first). Golden: the exact integer product (S4-6b: descriptor range
// checks and address strides of the L3 CSRs and pim_ctrl, computed once per call instead of a
// combinational runtime multiplier; hierarchy.md 3.2).
//
// Handshake (the same as udiv_seq): start_i is taken when the multiplier is not busy
// (busy_o = 0, including the done cycle). If start_i is high in cycle c, busy_o is 1 in
// c+1 .. c+B_W and done_o is a 1-cycle pulse in c + CYCLES (CYCLES = B_W + 1); p_o holds the
// product from that cycle until the next accepted start (it changes from c+1 on while busy).
// start_i while busy is ignored. Operands are sampled in the start cycle only.
// Datapath: one A_W-bit adder (+ carry) and an (A_W + B_W)-bit shift register {hi, lo}:
// lo starts as b, hi as 0; each step adds a to hi when lo[0] is 1 and shifts {carry, hi, lo}
// right by one. After B_W steps {hi, lo} = a * b (exact, no overflow).
//
// Simulation-only checks (tag = first word of the message):
//   UMUL_START  start_i while busy (ignored)
//   UMUL_X      X/Z on start_i after reset or on the operands of a start
module umul_seq #(
  parameter int A_W = 16,
  parameter int B_W = 8,
  localparam int P_W = A_W + B_W
) (
  input  logic           clk,
  input  logic           rst_n,
  input  logic           start_i,
  input  logic [A_W-1:0] a_i,
  input  logic [B_W-1:0] b_i,
  output logic [P_W-1:0] p_o,
  output logic           done_o,
  output logic           busy_o
);
  localparam int CYCLES = B_W + 1;
  localparam int CNT_W  = $clog2(B_W + 1);

  if (A_W < 1 || A_W > 64) $error("umul_seq: A_W=%0d must be 1..64", A_W);
  if (B_W < 1 || B_W > 64) $error("umul_seq: B_W=%0d must be 1..64", B_W);

  logic             busy_q, done_q;
  logic [CNT_W-1:0] cnt_q;
  logic [A_W-1:0]   a_q, hi_q;
  logic [B_W-1:0]   lo_q;
  logic             go;

  assign go = start_i && !busy_q;

  // one shift-add step
  logic [A_W:0] sum;
  assign sum = {1'b0, hi_q} + (lo_q[0] ? {1'b0, a_q} : '0);

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      busy_q <= 1'b0;
      done_q <= 1'b0;
      cnt_q  <= '0;
    end else begin
      done_q <= 1'b0;
      if (go) begin
        busy_q <= 1'b1;
        cnt_q  <= CNT_W'(B_W);
      end else if (busy_q) begin
        cnt_q <= cnt_q - 1'b1;
        if (cnt_q == CNT_W'(1)) begin
          busy_q <= 1'b0;
          done_q <= 1'b1;
        end
      end
    end

  always_ff @(posedge clk)
    if (go) begin
      a_q  <= a_i;
      hi_q <= '0;
      lo_q <= b_i;
    end else if (busy_q) begin
      hi_q <= sum[A_W:1];
      lo_q <= B_W'({sum[0], lo_q} >> 1);   // {sum[0], lo_q[B_W-1:1]}
    end

  assign p_o    = {hi_q, lo_q};
  assign done_o = done_q;
  assign busy_o = busy_q;

`ifndef SYNTHESIS
  always @(posedge clk)
    if (rst_n === 1'b1) begin
      if ($isunknown(start_i)) $error("UMUL_X umul_seq %m: X/Z on start_i");
      else if (start_i) begin
        if (busy_q) $error("UMUL_START umul_seq %m: start while busy (ignored)");
        else if ($isunknown(a_i) || $isunknown(b_i)) $error("UMUL_X umul_seq %m: X/Z operand");
      end
    end
`endif

endmodule
