// mac_row: lane dot product (dotp) of each beat accumulated over one row.
// Golden: the int32 row sum of model/src/kern.c k_dot8 (stage A1, hierarchy.md 3.3).
//
//   in : valid_i, first_i, last_i (first / last beat of a row; a one-beat row has both),
//        a_i / b_i (LANES lanes of AW / BW bits, lane i = bits [i*W +: W])
//   out: acc_o (row sum), acc_valid_o (1 cycle, LATENCY cycles after the last beat)
// acc_o holds the row sum while acc_valid_o is high and may change in the next cycle
// (the next row may start right after the last beat). Gaps (valid_i low) are allowed
// anywhere; no backpressure.
//
// Width: ACC_W >= AW + BW - 1 + clog2(N_MAX) is checked at elaboration. This
// covers N_MAX products of magnitude <= 2^(AW-1) * (2^(BW-1) - 1) (one operand never the
// most negative value, as the gemv activations from actq, |x| <= 127); the all
// -2^(AW-1) x -2^(BW-1) corner over N_MAX elements needs one more bit. Any accumulator
// overflow is reported in simulation (L1_RANGE, sim-only 64-bit shadow sum).
// LATENCY = DOT_PIPE + 1.
module mac_row #(
  parameter int LANES    = 8,
  parameter int AW       = 8,
  parameter int BW       = 8,
  parameter int ACC_W    = 25,
  parameter int N_MAX    = 1024,
  parameter int DOT_PIPE = 2
) (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    valid_i,
  input  logic                    first_i,
  input  logic                    last_i,
  input  logic [LANES*AW-1:0]     a_i,
  input  logic [LANES*BW-1:0]     b_i,
  output logic signed [ACC_W-1:0] acc_o,
  output logic                    acc_valid_o
);
  localparam int SW      = AW + BW + $clog2(LANES);
  localparam int LATENCY = DOT_PIPE + 1;

  if (N_MAX < LANES) $error("mac_row: N_MAX=%0d must be >= LANES=%0d", N_MAX, LANES);
  if (ACC_W < AW + BW - 1 + $clog2(N_MAX) || ACC_W < SW || ACC_W > 64)
    $error("mac_row: ACC_W=%0d must be %0d..64 for N_MAX=%0d", ACC_W,
           (AW + BW - 1 + $clog2(N_MAX) > SW) ? AW + BW - 1 + $clog2(N_MAX) : SW, N_MAX);

  logic                 dv;
  logic signed [SW-1:0] ds;

  dotp #(.LANES(LANES), .AW(AW), .BW(BW), .PIPE(DOT_PIPE)) u_dotp (
    .clk(clk), .rst_n(rst_n), .valid_i(valid_i), .a_i(a_i), .b_i(b_i),
    .valid_o(dv), .sum_o(ds));

  // first / last aligned with the dotp output
  logic first_d, last_d;
  if (DOT_PIPE == 0) begin : g_fl0
    assign first_d = first_i;
    assign last_d  = last_i;
  end else begin : g_fl
    logic [DOT_PIPE-1:0] f_q, l_q;
    always_ff @(posedge clk or negedge rst_n)
      if (!rst_n) begin
        f_q <= '0;
        l_q <= '0;
      end else begin
        f_q <= (f_q << 1) | DOT_PIPE'(first_i);
        l_q <= (l_q << 1) | DOT_PIPE'(last_i);
      end
    assign first_d = f_q[DOT_PIPE-1];
    assign last_d  = l_q[DOT_PIPE-1];
  end

  logic signed [ACC_W-1:0] acc_q;
  logic                    av_q;

  always_ff @(posedge clk)
    if (dv) acc_q <= first_d ? ACC_W'(ds) : acc_q + ACC_W'(ds);

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) av_q <= 1'b0;
    else        av_q <= dv && last_d;

  assign acc_o       = acc_q;
  assign acc_valid_o = av_q;

`ifndef SYNTHESIS
  // exact row sum: report when it leaves the ACC_W range
  longint shadow_q;
  always @(posedge clk)
    if (rst_n === 1'b1 && dv === 1'b1) begin
      automatic longint s = (first_d ? 64'sd0 : shadow_q) + longint'(ds);
      shadow_q <= s;
      if (s > (64'sd1 <<< (ACC_W - 1)) - 1 || s < -(64'sd1 <<< (ACC_W - 1)))
        $error("L1_RANGE mac_row %m: row sum %0d outside ACC_W=%0d", s, ACC_W);
    end
`endif

endmodule
