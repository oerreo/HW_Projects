// dotp: LANES signed products a[i] * b[i] and their adder-tree sum.
// Golden: model/src/kern.c k_dot8 (AW = BW = 8; hierarchy.md 3.2, 4 A1).
//
// Lane i of a_i / b_i is bits [i*AW +: AW] / [i*BW +: BW]. The sum is exact:
// SW = AW + BW + log2(LANES) bits hold LANES * (-2^(AW-1)) * (-2^(BW-1)).
//
// Pipeline: the tree has LV + 1 combinational levels (level 0 the products, levels
// 1..LV the adders, LV = log2(LANES)). PIPE registers (0..LV+1) are placed as
//   PIPE >= 1: after the last adder level (output)
//   PIPE >= 2: after the products
//   PIPE >= j+2: after adder level j (j = 1..LV-1)
// LATENCY = PIPE. No backpressure (valid only).
module dotp #(
  parameter int LANES = 8,
  parameter int AW    = 8,
  parameter int BW    = 8,
  parameter int PIPE  = 2
) (
  input  logic                         clk,
  input  logic                         rst_n,
  input  logic                         valid_i,
  input  logic        [LANES*AW-1:0]   a_i,
  input  logic        [LANES*BW-1:0]   b_i,
  output logic                         valid_o,
  output logic signed [AW+BW+$clog2(LANES)-1:0] sum_o
);
  localparam int LV      = $clog2(LANES);
  localparam int SW      = AW + BW + LV;
  localparam int LATENCY = PIPE;

  if (LANES < 2 || (1 << LV) != LANES)
    $error("dotp: LANES=%0d must be a power of two >= 2", LANES);
  if (AW < 2 || BW < 2 || AW > 32 || BW > 32) $error("dotp: AW=%0d BW=%0d must be 2..32", AW, BW);
  if (PIPE < 0 || PIPE > LV + 1) $error("dotp: PIPE=%0d must be 0..%0d", PIPE, LV + 1);

  // register after level j?
  function automatic bit reg_after(int j);
    if (j == LV) return PIPE >= 1;
    if (j == 0) return PIPE >= 2;
    return PIPE >= j + 2;
  endfunction

  for (genvar j = 0; j <= LV; j++) begin : g_lv
    localparam int NN = LANES >> j;
    logic signed [SW-1:0] c [NN];  // combinational result of level j
    logic signed [SW-1:0] q [NN];  // level output (registered or not)
    logic                 vin;     // valid entering level j
    logic                 v;       // valid of q

    if (j == 0) begin : g_mul
      assign vin = valid_i;
      for (genvar i = 0; i < NN; i++) begin : g_l
        logic signed [SW-1:0] ax, bx;
        assign ax   = SW'($signed(a_i[i*AW +: AW]));
        assign bx   = SW'($signed(b_i[i*BW +: BW]));
        assign c[i] = ax * bx;  // exact: |a*b| <= 2^(AW+BW-2) < 2^(SW-1)
      end
    end else begin : g_add
      assign vin = g_lv[j-1].v;
      for (genvar i = 0; i < NN; i++) begin : g_n
        assign c[i] = g_lv[j-1].q[2*i] + g_lv[j-1].q[2*i+1];
      end
    end

    if (reg_after(j)) begin : g_r
      always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) v <= 1'b0;
        else        v <= vin;
      always_ff @(posedge clk)
        if (vin) q <= c;
    end else begin : g_c
      assign v = vin;
      assign q = c;
    end
  end

  assign valid_o = g_lv[LV].v;
  assign sum_o   = g_lv[LV].q[0];

endmodule
