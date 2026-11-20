// vec_core: vector kernel core (L2, hierarchy.md 1 and 3.4, arch.md 5 and D10). One of four ops
// per call; actq_core is shared by RMSNORM, SWIGLU and ACTQ. Golden: model/src/kern.c k_rmsnorm,
// k_swiglu, k_actq (MANT) and k_argmax (records K_RMSNORM, K_SWIGLU, K_ACTQ, K_ARGMAX).
//
//   op 0 RMSNORM  stream: x int32 [n], then g int16 [n]   rms_front -> actq_core (f = fy, qmax 127)
//   op 1 SWIGLU   stream: h1 int32 [n], then h3 int32 [n] swi_front -> actq_core (f = 16, qmax 127)
//   op 2 ACTQ     stream: v int32 [n]                      actq_core (f, qmax 127 / 2047 / 32767)
//   op 3 ARGMAX   stream: v int32 [n]                      argmax_red (index of the first maximum)
// The input is the 64-bit beat stream of one read engine with one command per array, in the order
// above (the caller issues them); each command is ceil(n esz / 8) beats, d_last_i on its last beat.
// The unpacker (control of this level) takes the elements of a beat in lane order (esz 4: lanes
// [31:0], [63:32]; esz 2: four 16-bit lanes, sign-extended) and pops the beat after its last lane
// or after the last element of the command (the rest of a last beat is ignored). One element per
// cycle at most.
// The front buffer (ram_sdp N_MAX x 32, read latency 1) is shared: rms_front keeps x in it,
// swi_front keeps silu (the op selects whose port drives it).
// Outputs: q stream (valid / ready, int16 container; RMSNORM / SWIGLU / ACTQ), scale m_o / e_o
// (valid with scl_valid_o), argmax am_idx_o / am_max_o (from the done cycle of an ARGMAX call).
// start_i (when idle or in the done cycle) samples op_i and the cfg; done_o is a 1-cycle pulse: the
// done of actq_core (ops 0..2) or of argmax_red (op 3); busy_o from the start to the done cycle.
// n: 1..N_MAX for ops 0..2, 1..2^IDX_W for ARGMAX (the caller checks, simulation L2_CFG).
// Simulation-only checks: L2_START (start while busy), L2_CFG, L2_LAST (d_last_i not on the last
// beat of a command), L2_SEQ (beat outside a call).
module vec_core
  import llm_pkg::*;
#(
  parameter int N_MAX    = 1024,
  parameter int IDX_W    = 16,
  parameter int LUT_PIPE = 2,
  parameter int Q_DEPTH  = 8,
  localparam int NV_W    = IDX_W + 1,                  // n of any op (ARGMAX up to 2^IDX_W)
  localparam int NW      = $clog2(N_MAX + 1),
  localparam int AW      = (N_MAX > 1) ? $clog2(N_MAX) : 1
) (
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic                   start_i,
  input  logic [1:0]             op_i,
  input  logic [NV_W-1:0]        n_i,
  input  logic signed [E_W-1:0]  f_i,       // ACTQ f, RMSNORM fy
  input  logic [15:0]            qmax_i,    // ACTQ
  input  logic signed [E_W-1:0]  ge_i,      // RMSNORM
  input  logic [31:0]            epsc_i,    // RMSNORM (>= 0)
  // read beats
  input  logic                   d_valid_i,
  output logic                   d_ready_o,
  input  logic [63:0]            d_data_i,
  input  logic                   d_last_i,
  // q stream
  output logic                   q_valid_o,
  input  logic                   q_ready_i,
  output logic [15:0]            q_o,
  // results
  output logic [AM_W-1:0]        m_o,
  output logic signed [SH_W-1:0] e_o,
  output logic                   scl_valid_o,
  output logic [IDX_W-1:0]       am_idx_o,
  output logic signed [31:0]     am_max_o,
  output logic                   busy_o,
  output logic                   done_o
);
  localparam logic [1:0] OP_RMS = 2'd0, OP_SWI = 2'd1, OP_ACTQ = 2'd2, OP_AMAX = 2'd3;

  if (N_MAX < 2 || N_MAX > 65536) $error("vec_core: N_MAX=%0d must be 2..65536", N_MAX);
  if (IDX_W < 1 || IDX_W > 30) $error("vec_core: IDX_W=%0d must be 1..30", IDX_W);
  if ((1 << IDX_W) < N_MAX) $error("vec_core: 2^IDX_W must be >= N_MAX");

  // ---------------- call state ----------------
  logic            busy_q, go, done;
  logic [1:0]      op_q;
  logic [NV_W-1:0] n_q;
  assign go = start_i && (!busy_q || done);

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) busy_q <= 1'b0;
    else if (go) busy_q <= 1'b1;
    else if (done) busy_q <= 1'b0;
  always_ff @(posedge clk)
    if (go) begin
      op_q <= op_i;
      n_q  <= n_i;
    end

  // ---------------- unpacker ----------------
  logic            k_q;            // command 0 or 1 of the call
  logic            ek_q;           // all elements of the call taken
  logic [NV_W-1:0] cnt_q;          // element of the command
  logic [1:0]      lane_q;
  logic            e2;             // 16-bit elements (RMSNORM g)
  logic            e_valid, e_ready, e_take, e_last, pop;
  logic [31:0]     e_data;

  assign e2      = op_q == OP_RMS && k_q;
  assign e_valid = busy_q && !ek_q && d_valid_i;
  assign e_data  = e2 ? 32'($signed(d_data_i[16*lane_q +: 16])) : d_data_i[32*lane_q[0] +: 32];
  assign e_last  = cnt_q == n_q - 1'b1;
  assign e_take  = e_valid && e_ready;
  assign pop     = e_take && (e_last || lane_q == (e2 ? 2'd3 : 2'd1));
  assign d_ready_o = pop;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      k_q    <= 1'b0;
      ek_q   <= 1'b0;
      cnt_q  <= '0;
      lane_q <= '0;
    end else if (go) begin
      k_q    <= 1'b0;
      ek_q   <= 1'b0;
      cnt_q  <= '0;
      lane_q <= '0;
    end else if (e_take) begin
      if (e_last) begin
        cnt_q  <= '0;
        lane_q <= '0;
        k_q    <= 1'b1;
        if (k_q || op_q == OP_ACTQ || op_q == OP_AMAX) ek_q <= 1'b1;
      end else begin
        cnt_q  <= cnt_q + 1'b1;
        lane_q <= pop ? 2'd0 : lane_q + 2'd1;
      end
    end

  // ---------------- shared front buffer ----------------
  logic          rb_we, rb_re, sb_we, sb_re;
  logic [AW-1:0] rb_waddr, rb_raddr, sb_waddr, sb_raddr;
  logic [31:0]   rb_wdata, sb_wdata, b_rdata;
  ram_sdp #(.W(32), .DEPTH(N_MAX), .RD_LAT(1)) u_buf (
    .clk, .rst_n,
    .we_i(op_q == OP_RMS ? rb_we : sb_we), .waddr_i(op_q == OP_RMS ? rb_waddr : sb_waddr),
    .wdata_i(op_q == OP_RMS ? rb_wdata : sb_wdata),
    .re_i(op_q == OP_RMS ? rb_re : sb_re), .raddr_i(op_q == OP_RMS ? rb_raddr : sb_raddr),
    .rdata_o(b_rdata));

  // ---------------- fronts ----------------
  logic r_ready, r_yv, r_busy, r_done, s_ready, s_gv, s_busy, s_done;
  logic [31:0] r_y, s_g;
  rms_front #(.N_MAX(N_MAX)) u_rms (
    .clk, .rst_n, .start_i(go && op_i == OP_RMS), .n_i(NW'(n_i)), .ge_i, .epsc_i, .fy_i(f_i),
    .e_valid_i(e_valid && op_q == OP_RMS), .e_ready_o(r_ready), .e_i(e_data),
    .b_we_o(rb_we), .b_waddr_o(rb_waddr), .b_wdata_o(rb_wdata), .b_re_o(rb_re),
    .b_raddr_o(rb_raddr), .b_rdata_i(b_rdata), .y_valid_o(r_yv), .y_o(r_y), .busy_o(r_busy),
    .done_o(r_done));
  swi_front #(.N_MAX(N_MAX), .LUT_PIPE(LUT_PIPE)) u_swi (
    .clk, .rst_n, .start_i(go && op_i == OP_SWI), .n_i(NW'(n_i)),
    .e_valid_i(e_valid && op_q == OP_SWI), .e_ready_o(s_ready), .e_i(e_data),
    .b_we_o(sb_we), .b_waddr_o(sb_waddr), .b_wdata_o(sb_wdata), .b_re_o(sb_re),
    .b_raddr_o(sb_raddr), .b_rdata_i(b_rdata), .g_valid_o(s_gv), .g_o(s_g), .busy_o(s_busy),
    .done_o(s_done));

  // ---------------- actq_core ----------------
  logic        a_vvalid, a_vready, a_busy, a_done;
  logic [31:0] a_v;
  always_comb
    unique case (op_q)
      OP_RMS:  begin a_vvalid = r_yv; a_v = r_y; end
      OP_SWI:  begin a_vvalid = s_gv; a_v = s_g; end
      OP_ACTQ: begin a_vvalid = e_valid; a_v = e_data; end
      default: begin a_vvalid = 1'b0; a_v = e_data; end
    endcase
  actq_core #(.N_MAX(N_MAX), .Q_DEPTH(Q_DEPTH)) u_aq (
    .clk, .rst_n, .start_i(go && op_i != OP_AMAX), .n_i(NW'(n_i)),
    .f_i(op_i == OP_SWI ? E_W'(16) : f_i), .qmax_i(op_i == OP_ACTQ ? qmax_i : 16'd127),
    .v_valid_i(a_vvalid), .v_ready_o(a_vready), .v_i(a_v), .q_valid_o, .q_ready_i, .q_o, .m_o, .e_o,
    .scl_valid_o, .busy_o(a_busy), .done_o(a_done));

  // ---------------- argmax ----------------
  logic am_done;
  argmax_red #(.IDX_W(IDX_W)) u_am (
    .clk, .rst_n, .valid_i(e_take && op_q == OP_AMAX), .first_i(cnt_q == '0), .last_i(e_last),
    .v_i(e_data), .done_o(am_done), .idx_o(am_idx_o), .max_o(am_max_o));

  always_comb
    unique case (op_q)
      OP_RMS:  e_ready = r_ready;
      OP_SWI:  e_ready = s_ready;
      OP_ACTQ: e_ready = a_vready;
      default: e_ready = 1'b1;
    endcase

  assign done   = busy_q && (op_q == OP_AMAX ? am_done : a_done);
  assign done_o = done;
  assign busy_o = busy_q;

`ifndef SYNTHESIS
  always @(posedge clk)
    if (rst_n === 1'b1) begin
      if (start_i === 1'b1 && !go) $error("L2_START vec_core %m: start while busy (ignored)");
      if (go && (n_i == '0 || (op_i != OP_AMAX && 32'(n_i) > N_MAX) || 32'(n_i) > (1 << IDX_W)))
        $error("L2_CFG vec_core %m: op %0d n %0d", op_i, n_i);
      if (pop && (d_last_i !== (e_last ? 1'b1 : 1'b0)))
        $error("L2_LAST vec_core %m: d_last_i %b on a beat %s the last of its command", d_last_i,
               e_last ? "that is" : "that is not");
      if (d_valid_i === 1'b1 && (!busy_q || ek_q) && !go)
        $error("L2_SEQ vec_core %m: read beat outside the commands of a call");
    end
`endif

endmodule
