// lut_lerp: 257-entry table + linear interpolation (hierarchy.md 3.2). Golden:
// model/src/kern.c k_exp2neg(u, 8, k_exp_lut(8)) for FUNC = EXP2N.
//
// EXP2N: y = 2^(-u / 65536) in Q16, u >= 0 (u_i unsigned 32 bits):
//   I = u >> 16, f = u & 0xFFFF, idx = f >> 8, fr = f & 0xFF, a = T[idx], b = T[idx + 1]
//   e = a - (((a - b) fr + 128) >> 8)
//   y = 0 if I >= 32, else rshr(e, I) (round half up; I = 0: e)
// T = lut_pkg::EXP2N_TAB (k_exp_lut(8)). e <= 65536 < 2^17, so every I >= 18 also gives 0
// (the RTL uses that bound; identical results, checked exhaustively for u < 2^21).
// (a - b) fr stays far below 2^32 (a - b <= 177), so golden's uint32 arithmetic does not wrap.
// FUNC = SIGM (sigmoid) belongs to S4-7 and is not implemented (elaboration error).
//
// Pipeline (valid only, no backpressure): stage 1 is the registered table read (pair ROM
// (a, b) indexed by idx, 256 x 34), always present. PIPE >= 2 adds a register after the
// interpolation, PIPE >= 3 one at the output after the shift. LATENCY = PIPE (1..3).
module lut_lerp #(
  parameter int FUNC = 0,  // 0 = EXP2N, 1 = SIGM (not implemented)
  parameter int PIPE = 2
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        valid_i,
  input  logic [31:0] u_i,
  output logic        valid_o,
  output logic [16:0] y_o
);
  localparam int LATENCY = PIPE;

  if (FUNC != 0) $error("lut_lerp: FUNC=%0d not implemented (0 = EXP2N; SIGM is S4-7)", FUNC);
  if (PIPE < 1 || PIPE > 3) $error("lut_lerp: PIPE=%0d must be 1..3", PIPE);

  // ---- stage 1: table pair read ----
  logic        v1_q;
  logic [16:0] a1_q, b1_q;
  logic [7:0]  fr1_q;
  logic [4:0]  ish1_q;   // shift I (valid when !zero1_q)
  logic        zero1_q;  // I >= 18: result 0

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) v1_q <= 1'b0;
    else        v1_q <= valid_i;

  always_ff @(posedge clk)
    if (valid_i) begin
      a1_q    <= lut_pkg::EXP2N_TAB[u_i[15:8]];
      b1_q    <= lut_pkg::EXP2N_TAB[9'(u_i[15:8]) + 9'd1];
      fr1_q   <= u_i[7:0];
      ish1_q  <= u_i[20:16];
      zero1_q <= u_i[31:16] >= 16'd18;
    end

  // ---- interpolation ----
  logic [16:0] e1;
  always_comb begin
    logic [16:0] d;
    logic [24:0] p;
    d  = a1_q - b1_q;
    p  = 25'(d) * 25'(fr1_q) + 25'd128;
    e1 = a1_q - 17'(p >> 8);
  end

  logic        v2;
  logic [16:0] e2;
  logic [4:0]  ish2;
  logic        zero2;
  if (PIPE >= 2) begin : g_mid
    logic        vq, zq;
    logic [16:0] eq;
    logic [4:0]  iq;
    always_ff @(posedge clk or negedge rst_n)
      if (!rst_n) vq <= 1'b0;
      else        vq <= v1_q;
    always_ff @(posedge clk)
      if (v1_q) begin
        eq <= e1;
        iq <= ish1_q;
        zq <= zero1_q;
      end
    assign v2 = vq; assign e2 = eq; assign ish2 = iq; assign zero2 = zq;
  end else begin : g_nomid
    assign v2 = v1_q; assign e2 = e1; assign ish2 = ish1_q; assign zero2 = zero1_q;
  end

  // ---- shift: rshr(e, I), 0 <= I <= 17 ----
  logic [16:0] y2;
  always_comb begin
    logic [17:0] r;
    if (zero2)            y2 = '0;
    else if (ish2 == '0)  y2 = e2;
    else begin
      // floor((e + 2^(I-1)) / 2^I) = (floor(e / 2^(I-1)) + 1) >> 1
      r  = 18'(e2 >> (ish2 - 5'd1)) + 18'd1;
      y2 = 17'(r >> 1);
    end
  end

  if (PIPE >= 3) begin : g_out
    logic        vq;
    logic [16:0] yq;
    always_ff @(posedge clk or negedge rst_n)
      if (!rst_n) vq <= 1'b0;
      else        vq <= v2;
    always_ff @(posedge clk)
      if (v2) yq <= y2;
    assign valid_o = vq;
    assign y_o     = yq;
  end else begin : g_noout
    assign valid_o = v2;
    assign y_o     = y2;
  end

endmodule
