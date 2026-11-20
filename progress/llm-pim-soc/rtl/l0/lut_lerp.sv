// lut_lerp: 257-entry table + linear interpolation (hierarchy.md 3.2). Golden:
// model/src/kern.c k_exp2neg(u, 8, k_exp_lut(8)) for FUNC = EXP2N (S4-6),
// k_sigmoid(a, 8, k_sig_lut(8)) for FUNC = SIGM (S4-7).
//
// FUNC 0 EXP2N: y = 2^(-u / 65536) in Q16, u >= 0 (u_i unsigned 32 bits):
//   I = u >> 16, f = u & 0xFFFF, idx = f >> 8, fr = f & 0xFF, a = T[idx], b = T[idx + 1]
//   e = a - (((a - b) fr + 128) >> 8)
//   y = 0 if I >= 32, else rshr(e, I) (round half up; I = 0: e)
// T = lut_pkg::EXP2N_TAB (k_exp_lut(8)). e <= 65536 < 2^17, so every I >= 18 also gives 0
// (the RTL uses that bound; identical results, checked exhaustively for u < 2^21).
// (a - b) fr stays far below 2^32 (a - b <= 177), so golden's uint32 arithmetic does not wrap.
//
// FUNC 1 SIGM: y = sigmoid(a) in Q16, a = u_i read as a signed Q16 value (int32):
//   ua = |a| (ua = 2^31 for a = -2^31)
//   ua >= 2^20 (|a| >= 16): s = T[256]
//   else idx = ua >> 12, fr = ua & 0xFFF, A = T[idx], B = T[idx + 1],
//        s = A + (((B - A) fr + 2048) >> 12)
//   y = 65536 - s if a < 0, else s
// T = lut_pkg::SIGM_TAB (k_sig_lut(8), increasing: B - A >= 0, <= 1024, so (B - A) fr < 2^22 and
// golden's uint32 arithmetic does not wrap). s <= T[256] = 65536, y in [0, 65536] (17 bits).
//
// Pipeline (valid only, no backpressure): stage 1 is the registered table read (pair (a, b)
// indexed by idx, 256 x 34; SIGM saturation loads the pair (T[256], T[256]) with fr = 0), always
// present. PIPE >= 2 adds a register after the interpolation, PIPE >= 3 one at the output after
// the shift (EXP2N) or the sign correction (SIGM). LATENCY = PIPE (1..3) for both functions.
module lut_lerp #(
  parameter int FUNC = 0,  // 0 = EXP2N, 1 = SIGM
  parameter int PIPE = 2
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        valid_i,
  input  logic [31:0] u_i,     // EXP2N: u (unsigned Q16); SIGM: a (signed Q16)
  output logic        valid_o,
  output logic [16:0] y_o
);
  localparam int LATENCY = PIPE;

  if (FUNC != 0 && FUNC != 1) $error("lut_lerp: FUNC=%0d must be 0 (EXP2N) or 1 (SIGM)", FUNC);
  if (PIPE < 1 || PIPE > 3) $error("lut_lerp: PIPE=%0d must be 1..3", PIPE);

  logic        v1_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) v1_q <= 1'b0;
    else        v1_q <= valid_i;

  // stage 2 input (after the interpolation) and the final value of each function
  logic        v2;
  logic [16:0] y2;

  if (FUNC == 0) begin : g_exp
    // ---- stage 1: table pair read ----
    logic [16:0] a1_q, b1_q;
    logic [7:0]  fr1_q;
    logic [4:0]  ish1_q;   // shift I (valid when !zero1_q)
    logic        zero1_q;  // I >= 18: result 0

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
  end else begin : g_sig
    // ---- stage 1: |a|, saturation, table pair read ----
    logic [31:0] ua;
    logic        sat;
    assign ua  = u_i[31] ? 32'(-u_i) : u_i;   // -(-2^31) = 2^31 as unsigned
    assign sat = ua[31:20] != '0;            // |a| >= 2^20 (16.0)

    logic [16:0] a1_q, b1_q;
    logic [11:0] fr1_q;
    logic        neg1_q;
    always_ff @(posedge clk)
      if (valid_i) begin
        a1_q   <= sat ? lut_pkg::SIGM_TAB[256] : lut_pkg::SIGM_TAB[ua[19:12]];
        b1_q   <= sat ? lut_pkg::SIGM_TAB[256] : lut_pkg::SIGM_TAB[9'(ua[19:12]) + 9'd1];
        fr1_q  <= sat ? 12'd0 : ua[11:0];
        neg1_q <= u_i[31];
      end

    // ---- interpolation: s = A + (((B - A) fr + 2048) >> 12) ----
    logic [16:0] s1;
    always_comb begin
      logic [16:0] d;
      logic [29:0] p;
      d  = b1_q - a1_q;
      p  = 30'(d) * 30'(fr1_q) + 30'd2048;
      s1 = a1_q + 17'(p >> 12);
    end

    logic [16:0] s2;
    logic        neg2;
    if (PIPE >= 2) begin : g_mid
      logic        vq, nq;
      logic [16:0] sq;
      always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) vq <= 1'b0;
        else        vq <= v1_q;
      always_ff @(posedge clk)
        if (v1_q) begin
          sq <= s1;
          nq <= neg1_q;
        end
      assign v2 = vq; assign s2 = sq; assign neg2 = nq;
    end else begin : g_nomid
      assign v2 = v1_q; assign s2 = s1; assign neg2 = neg1_q;
    end

    // ---- sign: 1 - s for a < 0 ----
    assign y2 = neg2 ? 17'd65536 - s2 : s2;
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
