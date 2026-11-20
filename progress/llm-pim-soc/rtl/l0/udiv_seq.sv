// udiv_seq: sequential unsigned division q = floor(num / den), one quotient bit per cycle
// (restoring). Golden: C "/" (attention R = 2^48 / sum, arch.md 4.1; actq M and R in S4-7),
// hierarchy.md 3.2.
//
// Precondition: den > 0 and the quotient fits Q_W bits (num < den * 2^Q_W). Then the
// remainder before the first step, num >> Q_W, is < den and fits DEN_W bits.
// Handshake: start_i is taken when the divider is not busy (busy_o = 0, including the done
// cycle). If start_i is high in cycle c, busy_o is 1 in c+1 .. c+Q_W and done_o is a 1-cycle
// pulse in c + CYCLES (CYCLES = Q_W + 1); q_o holds the quotient from that cycle until the next
// accepted start. start_i while busy is ignored.
//
// Simulation-only checks (tag = first word of the message):
//   UDIV_ZERO   start with den_i == 0
//   UDIV_OVF    start with a quotient that does not fit Q_W bits (num >> Q_W >= den, den > 0)
//   UDIV_START  start_i while busy (ignored)
//   UDIV_X      X/Z on start_i after reset or on the operands of a start
module udiv_seq #(
  parameter int NUM_W = 49,
  parameter int DEN_W = 26,
  parameter int Q_W   = 33
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             start_i,
  input  logic [NUM_W-1:0] num_i,
  input  logic [DEN_W-1:0] den_i,
  output logic [Q_W-1:0]   q_o,
  output logic             done_o,
  output logic             busy_o
);
  localparam int CYCLES = Q_W + 1;
  localparam int CNT_W  = $clog2(Q_W + 1);

  if (NUM_W < 1 || NUM_W > 64) $error("udiv_seq: NUM_W=%0d must be 1..64", NUM_W);
  if (DEN_W < 1 || DEN_W > 63) $error("udiv_seq: DEN_W=%0d must be 1..63", DEN_W);
  if (Q_W < 1 || Q_W > 64) $error("udiv_seq: Q_W=%0d must be 1..64", Q_W);

  // num split: high part (initial remainder) and low Q_W bits (shifted in, MSB first)
  logic [DEN_W-1:0] hi0;
  logic [Q_W-1:0]   lo0;
  always_comb begin
    logic [NUM_W+Q_W-1:0] nx;
    nx  = (NUM_W + Q_W)'(num_i);
    lo0 = nx[Q_W-1:0];
    hi0 = DEN_W'(nx >> Q_W);  // < den by the precondition
  end

  logic             busy_q, done_q;
  logic [CNT_W-1:0] cnt_q;
  logic [DEN_W-1:0] rem_q, den_q;
  logic [Q_W-1:0]   sh_q;        // remaining dividend bits, then quotient bits
  logic             go;

  assign go = start_i && !busy_q;

  // one restoring step
  logic [DEN_W:0]   r2;
  logic             qb;
  logic [DEN_W-1:0] rem_n;
  always_comb begin
    r2    = {rem_q, sh_q[Q_W-1]};
    qb    = r2 >= {1'b0, den_q};
    rem_n = qb ? DEN_W'(r2 - {1'b0, den_q}) : r2[DEN_W-1:0];
  end

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      busy_q <= 1'b0;
      done_q <= 1'b0;
      cnt_q  <= '0;
    end else begin
      done_q <= 1'b0;
      if (go) begin
        busy_q <= 1'b1;
        cnt_q  <= CNT_W'(Q_W);
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
      rem_q <= hi0;
      den_q <= den_i;
      sh_q  <= lo0;
    end else if (busy_q) begin
      rem_q <= rem_n;
      if (Q_W > 1) sh_q <= {sh_q[Q_W-2:0], qb};
      else         sh_q <= qb;
    end

  assign q_o    = sh_q;
  assign done_o = done_q;
  assign busy_o = busy_q;

`ifndef SYNTHESIS
  always @(posedge clk)
    if (rst_n === 1'b1) begin
      if ($isunknown(start_i)) $error("UDIV_X udiv_seq %m: X/Z on start_i");
      else if (start_i) begin
        if (busy_q) $error("UDIV_START udiv_seq %m: start while busy (ignored)");
        else if ($isunknown(num_i) || $isunknown(den_i)) $error("UDIV_X udiv_seq %m: X/Z operand");
        else if (den_i == '0) $error("UDIV_ZERO udiv_seq %m: division by zero (num %0d)", num_i);
        else if ((NUM_W + Q_W)'(num_i) >> Q_W >= (NUM_W + Q_W)'(den_i))
          $error("UDIV_OVF udiv_seq %m: quotient of %0d / %0d does not fit %0d bits", num_i, den_i, Q_W);
      end
    end
`endif

endmodule
