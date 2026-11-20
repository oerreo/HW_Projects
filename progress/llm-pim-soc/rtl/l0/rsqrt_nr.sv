// rsqrt_nr: 1 / sqrt(u) ~= rm * 2^-re, sequential (hierarchy.md 3.2, arch.md 5.2). Golden:
// model/src/kern.c k_rsqrt(u, &re) (seed table k_rsq_lut, 48 entries, and two Newton steps).
//
//   u = max(u, 1), L = bitlen(u), t = L - 32 rounded up to even, re = 31 + t / 2
//   mn = u >> t (t >= 0) or u << -t: mn in [2^30, 2^32)
//   y  = k_rsq_lut[(mn >> 26) - 16]          (lut_pkg::RSQ_TAB, generated from model/src/tabs.c)
//   twice: z = y^2, p = (mn (z >> 2)) >> 28, p = min(p, 3 2^32 - 1), y = (y (3 2^32 - p)) >> 33
//   rm = y
// Widths (exact): the seed is < 2^16 (k_rsq_lut <= 64535). A Newton step gives
// y' <= 2^31 / sqrt(mn) + 1 <= 2^16 + 1 (the maximum of y (3 - a y^2) / 2 is 1 / sqrt(a); the
// truncations of z >> 2 and >> 28 lower p by at most mn / 2^28 + 1 <= 17, which raises y' by
// y 17 / 2^33 < 1), so y always fits Y_W = 17 bits (simulation check L0_RANGE). z < 2^34,
// z >> 2 < 2^32, mn (z >> 2) < 2^64, p < 2^36, 3 2^32 - p in [1, 3 2^32] (34 bits), y (3 2^32 - p)
// < 2^51. rm_o is the 17-bit y (golden: uint32 with the same value).
// One unsigned multiplier MA_W x MB_W = 17 x 35 (the product mn (z >> 2) is formed from the two
// 16-bit halves of z >> 2: (mn zh) 2^16 + mn zl), used once per cycle:
//   k = 1      normalize: mn, re
//   k = 2      seed: y = T[idx]
//   k = 3..8   Newton 1: A z = y y, B mn zh (zh = z[33:18], zl = z[17:2] kept), C mn zl,
//              D tp = 3 2^32 - min(p, 3 2^32 - 1), E y tp, F y = (y tp) >> 33
//   k = 9..14  Newton 2 (the same six steps)
// Handshake (the same as udiv_seq / umul_seq): start_i is taken when not busy (busy_o = 0,
// including the done cycle). start_i in cycle c: busy_o is 1 in c+1 .. c+CYCLES-1, done_o is a
// 1-cycle pulse in c + CYCLES (CYCLES = 15), rm_o / re_o hold the result from that cycle until the
// next accepted start. start_i while busy is ignored. u_i is sampled in the start cycle only.
//
// Simulation-only checks (tag = first word of the message):
//   RSQ_START  start_i while busy (ignored)
//   RSQ_X      X/Z on start_i after reset or on u_i of a start
//   L0_RANGE   u_i >= 2^U_W is impossible by the port width; y >= 2^Y_W (never, see above)
module rsqrt_nr
  import llm_pkg::*;
#(
  parameter int U_W = 42   // input width (rmsnorm u = ss + rshr(epsc, 2k) < 2^42 for N_MAX 1024)
) (
  input  logic                  clk,
  input  logic                  rst_n,
  input  logic                  start_i,
  input  logic [U_W-1:0]        u_i,
  output logic [16:0]           rm_o,
  output logic signed [E_W-1:0] re_o,
  output logic                  done_o,
  output logic                  busy_o
);
  localparam int CYCLES = 15;
  localparam int Y_W    = 17;
  localparam int MA_W   = 17;
  localparam int MB_W   = 35;
  localparam int LW     = $clog2(U_W + 1);

  if (U_W < 1 || U_W > 62) $error("rsqrt_nr: U_W=%0d must be 1..62", U_W);
  // re = 31 + t / 2 <= 31 + (U_W - 31) / 2 must fit E_W signed bits
  if (31 + (U_W - 31) / 2 + 1 > (1 << (E_W - 1)) - 1)
    $error("rsqrt_nr: U_W=%0d gives re beyond E_W=%0d bits", U_W, E_W);

  logic             busy_q, done_q;
  logic [3:0]       k_q;               // step 1..14 while busy
  logic [U_W-1:0]   u_q;
  logic [31:0]      mn_q;
  logic [Y_W-1:0]   y_q;
  logic [15:0]      zl_q;
  logic [47:0]      ph_q;
  logic [33:0]      tp_q;
  logic [MA_W+MB_W-1:0] prod_q;
  logic signed [E_W-1:0] re_q;
  logic             go;

  assign go = start_i && !busy_q;

  // ---- normalization (k = 1) ----
  logic [LW-1:0]  bl;
  logic signed [LW+1:0] t;
  logic [31:0]    mn_n;
  always_comb begin
    bl = '0;
    for (int i = 0; i < U_W; i++) if (u_q[i]) bl = LW'(i + 1);
    t = $signed({2'b00, bl}) - (LW + 2)'(32);
    if (t[0]) t = t + (LW + 2)'(1);
    if (t >= 0) mn_n = 32'(u_q >> t);
    else        mn_n = 32'(64'(u_q) << (-t));
  end

  // ---- Newton steps ----
  // step within a Newton iteration: 0 A, 1 B, 2 C, 3 D, 4 E, 5 F (k = 3 + 6 i + step)
  logic [2:0]          ns;
  logic [MA_W-1:0]     ma;
  logic [MB_W-1:0]     mb;
  logic [64:0]         psum;
  logic [36:0]         p;
  localparam logic [33:0] THREE = 34'h3_0000_0000;
  always_comb begin
    ns   = 3'((k_q >= 4'd9) ? k_q - 4'd9 : k_q - 4'd3);
    ma   = '0;
    mb   = '0;
    unique case (ns)
      3'd0:    begin ma = y_q;                     mb = MB_W'(y_q);  end   // z = y y
      3'd1:    begin ma = MA_W'(prod_q[33:18]);    mb = MB_W'(mn_q); end   // mn zh
      3'd2:    begin ma = MA_W'(zl_q);             mb = MB_W'(mn_q); end   // mn zl
      3'd4:    begin ma = y_q;                     mb = MB_W'(tp_q); end   // y tp
      default: ;
    endcase
    psum = {1'b0, ph_q, 16'd0} + 65'(prod_q[47:0]);
    p    = 37'(psum >> 28);
  end

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      busy_q <= 1'b0;
      done_q <= 1'b0;
      k_q    <= '0;
    end else begin
      done_q <= 1'b0;
      if (go) begin
        busy_q <= 1'b1;
        k_q    <= 4'd1;
      end else if (busy_q) begin
        k_q <= k_q + 4'd1;
        if (k_q == 4'(CYCLES - 1)) begin
          busy_q <= 1'b0;
          done_q <= 1'b1;
        end
      end
    end

  always_ff @(posedge clk)
    if (go) u_q <= (u_i == '0) ? U_W'(1) : u_i;
    else if (busy_q) begin
      if (k_q == 4'd1) begin
        mn_q <= mn_n;
        re_q <= E_W'(31 + (t >>> 1));
      end else if (k_q == 4'd2)
        y_q <= Y_W'(lut_pkg::RSQ_TAB[6'(mn_q[31:26] - 6'd16)]);   // k_rsq_lut[(mn >> 26) - 16]
      else begin
        if (ns == 3'd0 || ns == 3'd1 || ns == 3'd2 || ns == 3'd4) prod_q <= ma * mb;
        if (ns == 3'd1) zl_q <= prod_q[17:2];
        if (ns == 3'd2) ph_q <= prod_q[47:0];
        if (ns == 3'd3) tp_q <= THREE - ((p >= 37'(THREE)) ? THREE - 34'd1 : 34'(p));
        if (ns == 3'd5) y_q <= Y_W'(prod_q >> 33);
      end
    end


  assign rm_o   = y_q;
  assign re_o   = re_q;
  assign done_o = done_q;
  assign busy_o = busy_q;

`ifndef SYNTHESIS
  always @(posedge clk)
    if (rst_n === 1'b1) begin
      if ($isunknown(start_i)) $error("RSQ_X rsqrt_nr %m: X/Z on start_i");
      else if (start_i) begin
        if (busy_q) $error("RSQ_START rsqrt_nr %m: start while busy (ignored)");
        else if ($isunknown(u_i)) $error("RSQ_X rsqrt_nr %m: X/Z on u_i");
      end
      if (busy_q && ns == 3'd5 && k_q >= 4'd3 && (prod_q >> 33) >= (1 << Y_W))
        $error("L0_RANGE rsqrt_nr %m: Newton result %0d does not fit %0d bits", prod_q >> 33, Y_W);
    end
`endif

endmodule
