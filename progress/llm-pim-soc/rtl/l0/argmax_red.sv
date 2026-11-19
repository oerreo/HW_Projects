// argmax_red: argmax of a signed int32 stream (hierarchy.md 3.2, arch.md 5.4).
// golden: model/src/kern.c k_argmax (records K_ARGMAX): the index of the first maximum,
// i.e. the running maximum is replaced only when a new element is strictly greater (">"), so
// equal values keep the earlier index.
//
// Stream: one element per valid_i cycle, no backpressure (the producer never waits).
//   first_i marks element 0 of a stream (it restarts the reduction, also in the middle of an
//   unfinished stream), last_i its last element (first_i and last_i together: a 1-element
//   stream). Element k of a stream has index k (k < 2^IDX_W).
// Result: done_o is a 1-cycle pulse in the cycle after the valid_i cycle with last_i (latency
// 1); idx_o / max_o hold the index and the value of the maximum from the done_o cycle until the
// next valid_i. A new stream may start in the done_o cycle (first_i right after last_i).
// Reset: done_o and the element counter (control); idx_o, max_o are datapath registers,
// meaningful only from a done_o cycle on.
// Simulation-only checks (tag first): L0_SEQ valid_i without first_i outside a stream,
// L0_RANGE more than 2^IDX_W elements in a stream, VR_X X/Z on valid_i (on first_i / last_i
// only with valid_i).
module argmax_red #(
  parameter int IDX_W = 16   // index width 1..31
) (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    valid_i,
  input  logic                    first_i,
  input  logic                    last_i,
  input  logic signed [31:0]      v_i,
  output logic                    done_o,
  output logic [IDX_W-1:0]        idx_o,
  output logic signed [31:0]      max_o
);
  if (IDX_W < 1 || IDX_W > 31) $error("argmax_red: IDX_W=%0d must be 1..31", IDX_W);

  localparam int LATENCY = 1;

  logic [IDX_W-1:0]   cnt_q;    // index of the next element
  logic               open_q;   // inside a stream (control, simulation check only)
  logic               done_q;
  logic [IDX_W-1:0]   idx_q;
  logic signed [31:0] max_q;
  logic               take;

  // element 0 always taken, later ones only if strictly greater (first maximum wins)
  assign take = first_i || (v_i > max_q);

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      cnt_q  <= '0;
      open_q <= 1'b0;
      done_q <= 1'b0;
    end else begin
      done_q <= valid_i && last_i;
      if (valid_i) begin
        cnt_q  <= first_i ? IDX_W'(1) : cnt_q + 1'b1;
        open_q <= !last_i;
      end
    end

  always_ff @(posedge clk)
    if (valid_i && take) begin
      max_q <= v_i;
      idx_q <= first_i ? '0 : cnt_q;
    end

  assign done_o = done_q;
  assign idx_o  = idx_q;
  assign max_o  = max_q;

`ifndef SYNTHESIS
  logic c_wrap_q;   // the counter wrapped inside the current stream
  always @(posedge clk) begin
    if (rst_n === 1'b1) begin
      if ($isunknown(valid_i) || (valid_i === 1'b1 && $isunknown({first_i, last_i})))
        $error("VR_X argmax_red %m: X/Z on valid_i, or on first_i / last_i with valid_i");
      if (valid_i === 1'b1 && first_i !== 1'b1 && !open_q)
        $error("L0_SEQ argmax_red %m: element without first_i outside a stream");
      if (valid_i === 1'b1 && first_i !== 1'b1 && open_q && c_wrap_q)
        $error("L0_RANGE argmax_red %m: more than 2^%0d elements in a stream", IDX_W);
    end
    if (rst_n !== 1'b1) c_wrap_q <= 1'b0;
    else if (valid_i === 1'b1) c_wrap_q <= (first_i === 1'b1) ? 1'b0 : (c_wrap_q || cnt_q == '1);
  end
`endif

endmodule
