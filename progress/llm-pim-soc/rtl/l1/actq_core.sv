// actq_core: activation quantizer, MANT mode (hierarchy.md 3.3, arch.md 5.1). Golden:
// model/src/kern.c k_actq_st / k_aq_setup / k_aq_one (records K_ACTQ; the quantizer of k_rmsnorm
// and k_swiglu is the same pair of functions with f = fy and f = K_FX = 16, qmax = 127).
//
// One call (start_i, cfg n_i, f_i, qmax_i sampled in the start cycle):
//   LOAD  v[0..n-1] from the input stream into the buffer (ram_sdp N_MAX x 32), amax = max |v|
//         (|-2^31| = 2^31, unsigned 32 bits). v_ready_o = 1 in the whole LOAD phase (the fronts
//         rely on it: their output is valid-only).
//   SETUP amax == 0: M = 0, e_o = 0, every q = 0 (golden: s = {0, 0}).
//         else L = bitlen(amax), lq = bitlen(qmax), e = 16 + lq - L,
//         num = rshr(amax, -e) (rshr_sat), M = (num + qmax / 2) / qmax, R = (2^40 + M / 2) / M
//         (one udiv_seq NUM_W 41 / DEN_W 17 / Q_W 25 used twice; M in (2^15, 2^17), R < 2^25).
//         Steps: SET0 L, lq, e (registered); SET1 num and the start of the M division; DIVM the
//         division (its done cycle starts the R division); DIVR.
//   QUANT q[i] = clamp(rshr(v[i] R, 40 - e), qmax) for i = 0..n-1 (buffer read again, v R is a
//         32 x 25 product, rshr_sat to 17 bits (the saturation to [-2^16, 2^16 - 1] and the clamp
//         to +-qmax <= 32767 equal the clamp alone), out FIFO with credit)
//   scale m_o = M, e_o = e + f (0 if amax == 0), valid (scl_valid_o) from the first q until the
//   next start.
// q_o is the int16 container of q (int8 values sign-extended for qmax 127).
// done_o: 1-cycle pulse in the cycle after the handshake of the last q; busy_o from the cycle after
// the start to the done cycle (a new start is taken in the done cycle).
// Cycles (stall-free input at one element per cycle, q_ready_i = 1): start in cycle 0, element i
// accepted in cycle 1 + i; then SETUP (SET0, SET1, 2 x 26 divider cycles; SET0 only if amax == 0)
// and QUANT n + pipeline (cycle formula measured in tb_actq_core, docs/spec/vec.md).
//
// Simulation-only checks (tag first): L1_START start while busy (ignored), L1_CFG bad n / qmax at
// a start, L1_SEQ input element outside LOAD (dropped), VR_X X/Z on valid / ready / start.
module actq_core
  import llm_pkg::*;
#(
  parameter int N_MAX  = 1024,
  parameter int Q_DEPTH = 8,          // output FIFO depth (>= 5 for one element per cycle)
  localparam int NW    = $clog2(N_MAX + 1),
  localparam int AW    = (N_MAX > 1) ? $clog2(N_MAX) : 1
) (
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic                   start_i,
  input  logic [NW-1:0]          n_i,
  input  logic signed [E_W-1:0]  f_i,
  input  logic [15:0]            qmax_i,
  // input stream (LOAD)
  input  logic                   v_valid_i,
  output logic                   v_ready_o,
  input  logic [31:0]            v_i,
  // output stream
  output logic                   q_valid_o,
  input  logic                   q_ready_i,
  output logic [15:0]            q_o,
  // scale
  output logic [AM_W-1:0]        m_o,
  output logic signed [SH_W-1:0] e_o,
  output logic                   scl_valid_o,
  output logic                   busy_o,
  output logic                   done_o
);
  if (N_MAX < 2 || N_MAX > 65536) $error("actq_core: N_MAX=%0d must be 2..65536", N_MAX);
  if (Q_DEPTH < 5) $error("actq_core: Q_DEPTH=%0d must be >= 5", Q_DEPTH);

  localparam int QL_W = $clog2(Q_DEPTH + 1);

  typedef enum logic [2:0] {S_IDLE, S_LOAD, S_SET0, S_SET1, S_DIVM, S_DIVR, S_QUANT, S_FIN} st_t;
  st_t st_q;

  logic [NW-1:0]         n_q, wcnt_q, rcnt_q, ocnt_q;
  logic [15:0]           qmax_q;
  logic signed [E_W-1:0] f_q;
  logic [31:0]           amax_q;
  logic                  zero_q;
  logic signed [SH_W-1:0] e_q;      // e = 16 + lq - L
  logic [AM_W-1:0]       m_q;
  logic [24:0]           r_q;
  logic                  scl_q;
  logic                  go, take, done_q;

  assign go        = start_i && (st_q == S_IDLE || done_q);
  assign v_ready_o = st_q == S_LOAD;
  assign take      = v_valid_i && v_ready_o;

  // ---------------- buffer ----------------
  logic          b_re;
  logic [AW-1:0] b_raddr;
  logic [31:0]   b_rdata;
  ram_sdp #(.W(32), .DEPTH(N_MAX), .RD_LAT(1)) u_buf (
    .clk, .rst_n, .we_i(take), .waddr_i(AW'(wcnt_q)), .wdata_i(v_i), .re_i(b_re), .raddr_i(b_raddr),
    .rdata_o(b_rdata));

  // ---------------- setup ----------------
  // |v| as unsigned 32 bits
  logic [31:0] av;
  assign av = v_i[31] ? 32'(-v_i) : v_i;

  // bit lengths
  logic [5:0] L, lq;
  always_comb begin
    L  = '0;
    lq = '0;
    for (int i = 0; i < 32; i++) if (amax_q[i]) L = 6'(i + 1);
    for (int i = 0; i < 16; i++) if (qmax_q[i]) lq = 6'(i + 1);
  end

  // num = rshr(amax, -e) (e >= 0: amax 2^e < 2^(16 + lq) <= 2^31; e < 0: rounded right shift)
  logic signed [32:0] num;
  rshr_sat #(.IN_W(33), .OUT_W(33), .SAT_MODE(0), .PIPE(0)) u_num (
    .clk, .rst_n, .valid_i(1'b0), .x_i($signed({1'b0, amax_q})), .sh_i(SH_W'(-e_q)), .valid_o(),
    .y_o(num));

  // divider: M = (num + qmax / 2) / qmax, then R = (2^40 + M / 2) / M
  logic        d_start, d_done, d_busy;
  logic [40:0] d_num;
  logic [16:0] d_den;
  logic [24:0] d_q;
  always_comb begin
    if (st_q == S_SET1) begin
      d_num = 41'(num) + 41'(qmax_q >> 1);
      d_den = 17'(qmax_q);
    end else begin
      d_num = (41'd1 << 40) + 41'(d_q[16:0] >> 1);
      d_den = d_q[16:0];
    end
  end
  assign d_start = st_q == S_SET1 || (st_q == S_DIVM && d_done);
  udiv_seq #(.NUM_W(41), .DEN_W(17), .Q_W(25)) u_div (
    .clk, .rst_n, .start_i(d_start), .num_i(d_num), .den_i(d_den), .q_o(d_q), .done_o(d_done),
    .busy_o(d_busy));

  // ---------------- quantization pipeline ----------------
  // stage 0: buffer read (rcnt), stage 1: v R, stage 2: rshr_sat (PIPE 1), then clamp -> FIFO
  logic                  v1_q, v2_q;
  logic signed [56:0]    prod_q;
  logic                  y_valid;
  logic signed [16:0]    y;
  logic [QL_W-1:0]       f_level;
  logic                  f_in_ready;
  logic [2:0]            infl;        // reads in flight (issued, not yet pushed)
  logic                  credit;

  assign infl   = 3'(v1_q) + 3'(v2_q) + 3'(y_valid);
  assign credit = 32'(f_level) + 32'(infl) < Q_DEPTH;
  assign b_re   = st_q == S_QUANT && rcnt_q != n_q && credit;
  assign b_raddr = AW'(rcnt_q);

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      v1_q <= 1'b0;
      v2_q <= 1'b0;
    end else begin
      v1_q <= b_re;
      v2_q <= v1_q;
    end
  always_ff @(posedge clk)
    if (v1_q) prod_q <= $signed(b_rdata) * $signed({1'b0, r_q});

  rshr_sat #(.IN_W(57), .OUT_W(17), .SAT_MODE(0), .PIPE(1)) u_q (
    .clk, .rst_n, .valid_i(v2_q), .x_i(prod_q), .sh_i(SH_W'(10'sd40 - e_q)), .valid_o(y_valid),
    .y_o(y));

  logic signed [16:0] qmx;
  logic [15:0]        qc;
  assign qmx = $signed({1'b0, qmax_q});
  assign qc  = (y > qmx) ? 16'(qmx) : (y < -qmx) ? 16'(-qmx) : 16'(y);

  sync_fifo #(.W(16), .DEPTH(Q_DEPTH)) u_qf (
    .clk, .rst_n, .in_valid_i(y_valid), .in_ready_o(f_in_ready), .in_data_i(qc),
    .out_valid_o(q_valid_o), .out_ready_i(q_ready_i), .out_data_o(q_o), .level_o(f_level));

  // ---------------- control ----------------
  logic q_hs;
  assign q_hs = q_valid_o && q_ready_i;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      st_q   <= S_IDLE;
      wcnt_q <= '0;
      rcnt_q <= '0;
      ocnt_q <= '0;
      done_q <= 1'b0;
      scl_q  <= 1'b0;
    end else begin
      done_q <= 1'b0;
      if (go) begin
        st_q   <= S_LOAD;
        wcnt_q <= '0;
        rcnt_q <= '0;
        ocnt_q <= '0;
        scl_q  <= 1'b0;
      end else
        unique case (st_q)
          S_LOAD:  if (take) begin
            wcnt_q <= wcnt_q + 1'b1;
            if (wcnt_q + 1'b1 == n_q) st_q <= S_SET0;
          end
          S_SET0:  st_q <= zero_q ? S_QUANT : S_SET1;
          S_SET1:  st_q <= S_DIVM;
          S_DIVM:  if (d_done) st_q <= S_DIVR;
          S_DIVR:  if (d_done) st_q <= S_QUANT;
          S_QUANT: begin
            if (b_re) rcnt_q <= rcnt_q + 1'b1;
            if (q_hs) begin
              ocnt_q <= ocnt_q + 1'b1;
              if (ocnt_q + 1'b1 == n_q) begin
                st_q   <= S_FIN;
                done_q <= 1'b1;
              end
            end
            scl_q <= 1'b1;
          end
          S_FIN:   st_q <= S_IDLE;
          default: ;
        endcase
    end

  // datapath registers
  always_ff @(posedge clk) begin
    if (go) begin
      n_q    <= n_i;
      f_q    <= f_i;
      qmax_q <= qmax_i;
      amax_q <= '0;
    end else if (take && av > amax_q) amax_q <= av;
    if (st_q == S_LOAD && take && wcnt_q + 1'b1 == n_q) zero_q <= amax_q == '0 && av == '0;
    // e = 16 + lq - L (amax != 0; L and lq are combinational on amax_q / qmax_q), registered in
    // SET0 for num (SET1) and QUANT
    if (st_q == S_SET0) e_q <= zero_q ? '0 : SH_W'(16) + SH_W'(lq) - SH_W'(L);
    if (st_q == S_SET0 && zero_q) begin
      m_q <= '0;
      r_q <= '0;
    end
    if (st_q == S_DIVM && d_done) m_q <= d_q[AM_W-1:0];
    if (st_q == S_DIVR && d_done) r_q <= d_q;
  end

  assign m_o         = m_q;
  assign e_o         = zero_q ? '0 : e_q + SH_W'(f_q);
  assign scl_valid_o = scl_q;
  assign busy_o      = st_q != S_IDLE;
  assign done_o      = done_q;

`ifndef SYNTHESIS
  always @(posedge clk)
    if (rst_n === 1'b1) begin
      if ($isunknown(start_i) || $isunknown(v_valid_i) || $isunknown(q_ready_i))
        $error("VR_X actq_core %m: X/Z on start_i, v_valid_i or q_ready_i");
      if (start_i === 1'b1 && !go) $error("L1_START actq_core %m: start while busy (ignored)");
      if (go && (n_i == '0 || 32'(n_i) > N_MAX || !(qmax_i == 16'd127 || qmax_i == 16'd2047 ||
                                                   qmax_i == 16'd32767)))
        $error("L1_CFG actq_core %m: n %0d qmax %0d", n_i, qmax_i);
      if (v_valid_i === 1'b1 && st_q != S_LOAD)
        $error("L1_SEQ actq_core %m: input element outside LOAD (dropped)");
      if (y_valid && !f_in_ready) $error("L1_OVF actq_core %m: output FIFO overflow");
    end
`endif

endmodule
