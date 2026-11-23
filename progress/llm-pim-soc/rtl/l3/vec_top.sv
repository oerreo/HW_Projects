// vec_top: vector IP (L3, arch.md 5, 7 and D10, hierarchy.md 1; register map, descriptor and run
// rules docs/spec/vec.md). One HP port: one AXI4 read master and one AXI4 write master.
//
//   op 1 RMSNORM  reads x int32 [N] at IN0_ADDR, g int16 [N] at IN1_ADDR;
//                 writes q int8 [N] at OUT_ADDR, scale {int32 m, int32 e} at SCL_ADDR
//   op 2 SWIGLU   reads h1 int32 [N] at IN0_ADDR, h3 int32 [N] at IN1_ADDR; writes q int8, scale
//   op 3 ACTQ     reads v int32 [N] at IN0_ADDR; writes q int8 (qmax 127) or int16 (2047, 32767)
//                 [N] at OUT_ADDR, scale at SCL_ADDR
//   op 4 ARGMAX   reads v int32 [N] at IN0_ADDR; writes idx int32 at OUT_ADDR (4 bytes),
//                 ARGMAX_IDX / ARGMAX_VAL registers
// (the golden buffer layouts of model/src/kern.h, little-endian).
//
// Structure (instances, wiring and the control of this level):
//   axil_slave + vec_csr       registers, descriptor check (1 cycle), run control
//   read sequencer             at the start (cycle v): command IN0 (4N bytes), then IN1 (RMSNORM
//                              2N, SWIGLU 4N); axi_rd_eng -> vec_core beat stream
//   vec_core                   unpacker, fronts, actq_core, argmax_red
//   write sequencer            at the start: command OUT (N qb bytes; ARGMAX 4), then SCL (8 bytes)
//   packer                     q values 8 (int8) or 4 (int16) per beat, the last beat partial (the
//                              engine masks it with WSTRB), then the scale beat {e, m}; ARGMAX one
//                              beat {0, idx}; -> axi_wr_eng
// Call: CTRL write s, verdict v = s + 1 (vec_csr); start in v starts vec_core and both sequencers.
// Run end e: vec_core done seen, the packer has handed every beat to the write engine, every write
// command issued and the write engine idle (last B). CYCLES = e - s (check included).
// Addresses: byte counts are shifts of N (4N, 2N, N qb), no multiplier.
// RD_STALL: the core waits for read data: read engine busy && vec_core d_want_o && no beat
// (d_valid 0). Not axi_rd_eng stall_o: that uses d_ready, which vec_core raises only together with
// d_valid (pop of a beat), so it would never count. WR_STALL: axi_wr_eng stall_o.
module vec_top
  import llm_pkg::*;
#(
  parameter int N_MAX     = 1024,
  parameter int IDX_W     = 16,
  parameter int LUT_PIPE  = 2,
  parameter int Q_DEPTH   = 8,
  parameter int MAX_BURST = 16,
  parameter int OUTS      = 4,
  parameter int RD_FIFO   = MAX_BURST * OUTS,
  parameter int WR_FIFO   = 2 * MAX_BURST,
  parameter int IDW       = 1,
  parameter int FCLK_MHZ  = 100,
  parameter int ADDR_W    = 12
) (
  input  logic              clk,
  input  logic              rst_n,
  // AXI4-Lite slave
  input  logic [ADDR_W-1:0] s_axi_awaddr_i,
  input  logic [2:0]        s_axi_awprot_i,
  input  logic              s_axi_awvalid_i,
  output logic              s_axi_awready_o,
  input  logic [31:0]       s_axi_wdata_i,
  input  logic [3:0]        s_axi_wstrb_i,
  input  logic              s_axi_wvalid_i,
  output logic              s_axi_wready_o,
  output logic [1:0]        s_axi_bresp_o,
  output logic              s_axi_bvalid_o,
  input  logic              s_axi_bready_i,
  input  logic [ADDR_W-1:0] s_axi_araddr_i,
  input  logic [2:0]        s_axi_arprot_i,
  input  logic              s_axi_arvalid_i,
  output logic              s_axi_arready_o,
  output logic [31:0]       s_axi_rdata_o,
  output logic [1:0]        s_axi_rresp_o,
  output logic              s_axi_rvalid_o,
  input  logic              s_axi_rready_i,
  // AXI4 master write
  output logic [IDW-1:0]    m_axi_awid_o,
  output logic [31:0]       m_axi_awaddr_o,
  output logic [7:0]        m_axi_awlen_o,
  output logic [2:0]        m_axi_awsize_o,
  output logic [1:0]        m_axi_awburst_o,
  output logic              m_axi_awlock_o,
  output logic [3:0]        m_axi_awcache_o,
  output logic [2:0]        m_axi_awprot_o,
  output logic [3:0]        m_axi_awqos_o,
  output logic              m_axi_awvalid_o,
  input  logic              m_axi_awready_i,
  output logic [63:0]       m_axi_wdata_o,
  output logic [7:0]        m_axi_wstrb_o,
  output logic              m_axi_wlast_o,
  output logic              m_axi_wvalid_o,
  input  logic              m_axi_wready_i,
  input  logic [IDW-1:0]    m_axi_bid_i,
  input  logic [1:0]        m_axi_bresp_i,
  input  logic              m_axi_bvalid_i,
  output logic              m_axi_bready_o,
  // AXI4 master read
  output logic [IDW-1:0]    m_axi_arid_o,
  output logic [31:0]       m_axi_araddr_o,
  output logic [7:0]        m_axi_arlen_o,
  output logic [2:0]        m_axi_arsize_o,
  output logic [1:0]        m_axi_arburst_o,
  output logic              m_axi_arlock_o,
  output logic [3:0]        m_axi_arcache_o,
  output logic [2:0]        m_axi_arprot_o,
  output logic [3:0]        m_axi_arqos_o,
  output logic              m_axi_arvalid_o,
  input  logic              m_axi_arready_i,
  input  logic [IDW-1:0]    m_axi_rid_i,
  input  logic [63:0]       m_axi_rdata_i,
  input  logic [1:0]        m_axi_rresp_i,
  input  logic              m_axi_rlast_i,
  input  logic              m_axi_rvalid_i,
  output logic              m_axi_rready_o
);
  localparam int NV_W = IDX_W + 1;
  localparam logic [1:0] OP_RMS = 2'd0, OP_SWI = 2'd1, OP_ACTQ = 2'd2, OP_AMAX = 2'd3;

  // ---------------- AXI4-Lite and CSR ----------------
  logic              wr_en, rd_en;
  logic [ADDR_W-1:0] wr_addr, rd_addr;
  logic [31:0]       wr_data, rd_data;

  axil_slave #(.ADDR_W(ADDR_W), .DATA_W(32)) u_axil (
    .clk, .rst_n,
    .s_axi_awaddr_i, .s_axi_awprot_i, .s_axi_awvalid_i, .s_axi_awready_o,
    .s_axi_wdata_i, .s_axi_wstrb_i, .s_axi_wvalid_i, .s_axi_wready_o,
    .s_axi_bresp_o, .s_axi_bvalid_o, .s_axi_bready_i,
    .s_axi_araddr_i, .s_axi_arprot_i, .s_axi_arvalid_i, .s_axi_arready_o,
    .s_axi_rdata_o, .s_axi_rresp_o, .s_axi_rvalid_o, .s_axi_rready_i,
    .wr_en_o(wr_en), .wr_addr_o(wr_addr), .wr_data_o(wr_data),
    .rd_en_o(rd_en), .rd_addr_o(rd_addr), .rd_data_i(rd_data));

  logic                  start, busy, run_done, am_valid;
  logic                  rd_err_ev, wr_err_ev, rd_stall_ev, wr_stall_ev;
  logic [1:0]            d_op;
  logic [31:0]           d_in0, d_in1, d_out, d_scl, d_epsc;
  logic [NV_W-1:0]       d_n;
  logic [15:0]           d_qmax;
  logic signed [E_W-1:0] d_f, d_ge;
  logic [IDX_W-1:0]      am_idx;
  logic signed [31:0]    am_max;

  vec_csr #(.ADDR_W(ADDR_W), .N_MAX(N_MAX), .IDX_W(IDX_W), .FCLK_MHZ(FCLK_MHZ)) u_csr (
    .clk, .rst_n, .wr_en_i(wr_en), .wr_addr_i(wr_addr), .wr_data_i(wr_data), .rd_en_i(rd_en),
    .rd_addr_i(rd_addr), .rd_data_o(rd_data),
    .start_o(start), .busy_o(busy), .done_i(run_done),
    .op_o(d_op), .in0_o(d_in0), .in1_o(d_in1), .out_o(d_out), .scl_o(d_scl), .n_o(d_n),
    .qmax_o(d_qmax), .f_o(d_f), .ge_o(d_ge), .epsc_o(d_epsc),
    .am_valid_i(am_valid), .am_idx_i(am_idx), .am_val_i(am_max),
    .rd_err_i(rd_err_ev), .wr_err_i(wr_err_ev), .rd_stall_i(rd_stall_ev), .wr_stall_i(wr_stall_ev));

  // byte counts (shifts of N)
  logic        q16;
  logic [31:0] n32, b_in0, b_in1, b_out;
  assign q16   = d_op == OP_ACTQ && d_qmax != 16'd127;
  assign n32   = 32'(d_n);
  assign b_in0 = n32 << 2;
  assign b_in1 = (d_op == OP_RMS) ? n32 << 1 : n32 << 2;
  assign b_out = (d_op == OP_AMAX) ? 32'd4 : q16 ? n32 << 1 : n32;

  // ---------------- read sequencer + engine ----------------
  logic [1:0]  rc_n_q;           // read commands left
  logic        rc_k_q;           // next command: 0 IN0, 1 IN1
  logic        rc_valid, rc_ready;
  logic [31:0] rc_addr, rc_bytes;
  assign rc_valid = rc_n_q != '0;
  assign rc_addr  = rc_k_q ? d_in1 : d_in0;
  assign rc_bytes = rc_k_q ? b_in1 : b_in0;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      rc_n_q <= '0;
      rc_k_q <= 1'b0;
    end else if (start) begin
      rc_n_q <= (d_op == OP_RMS || d_op == OP_SWI) ? 2'd2 : 2'd1;
      rc_k_q <= 1'b0;
    end else if (rc_valid && rc_ready) begin
      rc_n_q <= rc_n_q - 2'd1;
      rc_k_q <= 1'b1;
    end

  logic        d_valid, d_ready, d_want, d_last, rd_busy, rd_ecmd;
  logic [63:0] d_data;
  axi_rd_eng #(.AW(32), .IDW(IDW), .LEN_W(32), .MAX_BURST(MAX_BURST), .OUTS(OUTS),
               .FIFO_DEPTH(RD_FIFO)) u_rd (
    .clk, .rst_n, .cfg_burst_i(9'd0), .cfg_outs_i(7'd0),
    .cmd_valid_i(rc_valid), .cmd_ready_o(rc_ready), .cmd_addr_i(rc_addr), .cmd_bytes_i(rc_bytes),
    .d_valid_o(d_valid), .d_ready_i(d_ready), .d_data_o(d_data), .d_last_o(d_last),
    .busy_o(rd_busy), .done_o(), .stall_o(), .err_resp_o(), .err_cmd_o(rd_ecmd),
    .err_clr_i(start),
    .m_axi_arid_o, .m_axi_araddr_o, .m_axi_arlen_o, .m_axi_arsize_o, .m_axi_arburst_o,
    .m_axi_arlock_o, .m_axi_arcache_o, .m_axi_arprot_o, .m_axi_arqos_o, .m_axi_arvalid_o,
    .m_axi_arready_i, .m_axi_rid_i, .m_axi_rdata_i, .m_axi_rresp_i, .m_axi_rlast_i,
    .m_axi_rvalid_i, .m_axi_rready_o);

  // ---------------- core ----------------
  logic                   q_valid, q_ready, scl_valid, c_busy, c_done;
  logic [15:0]            q;
  logic [AM_W-1:0]        m;
  logic signed [SH_W-1:0] e;
  vec_core #(.N_MAX(N_MAX), .IDX_W(IDX_W), .LUT_PIPE(LUT_PIPE), .Q_DEPTH(Q_DEPTH)) u_core (
    .clk, .rst_n, .start_i(start), .op_i(d_op), .n_i(d_n), .f_i(d_f), .qmax_i(d_qmax), .ge_i(d_ge),
    .epsc_i(d_epsc), .d_valid_i(d_valid), .d_ready_o(d_ready), .d_want_o(d_want), .d_data_i(d_data),
    .d_last_i(d_last),
    .q_valid_o(q_valid), .q_ready_i(q_ready), .q_o(q), .m_o(m), .e_o(e), .scl_valid_o(scl_valid),
    .am_idx_o(am_idx), .am_max_o(am_max), .busy_o(c_busy), .done_o(c_done));

  // ---------------- write sequencer ----------------
  logic [1:0]  wc_n_q;
  logic        wc_k_q;           // next command: 0 OUT, 1 SCL
  logic        wc_valid, wc_ready;
  logic [31:0] wc_addr, wc_bytes;
  assign wc_valid = wc_n_q != '0;
  assign wc_addr  = wc_k_q ? d_scl : d_out;
  assign wc_bytes = wc_k_q ? 32'd8 : b_out;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      wc_n_q <= '0;
      wc_k_q <= 1'b0;
    end else if (start) begin
      wc_n_q <= (d_op == OP_AMAX) ? 2'd1 : 2'd2;
      wc_k_q <= 1'b0;
    end else if (wc_valid && wc_ready) begin
      wc_n_q <= wc_n_q - 2'd1;
      wc_k_q <= 1'b1;
    end

  // ---------------- packer ----------------
  // phase: PK_Q (q values), PK_S (scale beat), PK_A (argmax beat after the core's done), PK_D (done)
  typedef enum logic [1:0] {PK_Q, PK_S, PK_A, PK_D} pk_t;
  pk_t             ph_q;
  logic            pk_valid_q, pk_ready, wr_in_ready, q_hs, emit_q, cd_q;
  logic [63:0]     pk_data_q, acc_q, acc_n;
  logic [2:0]      lane_q;       // next lane (int8: 0..7, int16: 0..3)
  logic [NV_W-1:0] qc_q;         // q values packed
  logic            q_last;

  assign pk_ready = !pk_valid_q || wr_in_ready;
  assign q_ready  = busy && ph_q == PK_Q && pk_ready;
  assign q_hs     = q_valid && q_ready;
  assign q_last   = qc_q == d_n - 1'b1;
  assign emit_q   = q_hs && (q_last || lane_q == (q16 ? 3'd3 : 3'd7));
  always_comb begin
    acc_n = acc_q;
    if (q16) acc_n[16 * lane_q[1:0] +: 16] = q;
    else     acc_n[8 * lane_q +: 8]        = q[7:0];
  end

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      ph_q       <= PK_D;
      pk_valid_q <= 1'b0;
      lane_q     <= '0;
      qc_q       <= '0;
      cd_q       <= 1'b0;
    end else begin
      if (start) begin
        ph_q   <= (d_op == OP_AMAX) ? PK_A : PK_Q;
        lane_q <= '0;
        qc_q   <= '0;
        cd_q   <= 1'b0;
      end else begin
        if (c_done) cd_q <= 1'b1;
        unique case (ph_q)
          PK_Q: if (q_hs) begin
            qc_q   <= qc_q + 1'b1;
            lane_q <= emit_q ? 3'd0 : lane_q + 3'd1;
            if (q_last) ph_q <= PK_S;
          end
          PK_S: if (pk_ready && scl_valid) ph_q <= PK_D;
          PK_A: if (pk_ready && cd_q) ph_q <= PK_D;
          default: ;
        endcase
      end
      if (emit_q || (ph_q == PK_S && pk_ready && scl_valid) || (ph_q == PK_A && pk_ready && cd_q))
        pk_valid_q <= 1'b1;
      else if (wr_in_ready) pk_valid_q <= 1'b0;
    end

  always_ff @(posedge clk) begin
    if (start) acc_q <= '0;
    else if (q_hs) acc_q <= emit_q ? 64'd0 : acc_n;
    if (emit_q) pk_data_q <= acc_n;
    else if (ph_q == PK_S && pk_ready) pk_data_q <= {32'(e), 32'(m)};
    else if (ph_q == PK_A && pk_ready) pk_data_q <= {32'd0, 32'(am_idx)};
  end

  logic wr_busy, wr_ecmd;
  axi_wr_eng #(.AW(32), .IDW(IDW), .LEN_W(32), .MAX_BURST(MAX_BURST), .OUTS(OUTS),
               .FIFO_DEPTH(WR_FIFO)) u_wr (
    .clk, .rst_n, .cfg_burst_i(9'd0), .cfg_outs_i(7'd0),
    .cmd_valid_i(wc_valid), .cmd_ready_o(wc_ready), .cmd_addr_i(wc_addr), .cmd_bytes_i(wc_bytes),
    .in_valid_i(pk_valid_q), .in_ready_o(wr_in_ready), .in_data_i(pk_data_q),
    .busy_o(wr_busy), .done_o(), .stall_o(wr_stall_ev), .err_resp_o(), .err_cmd_o(wr_ecmd),
    .err_clr_i(start),
    .m_axi_awid_o, .m_axi_awaddr_o, .m_axi_awlen_o, .m_axi_awsize_o, .m_axi_awburst_o,
    .m_axi_awlock_o, .m_axi_awcache_o, .m_axi_awprot_o, .m_axi_awqos_o, .m_axi_awvalid_o,
    .m_axi_awready_i, .m_axi_wdata_o, .m_axi_wstrb_o, .m_axi_wlast_o, .m_axi_wvalid_o,
    .m_axi_wready_i, .m_axi_bid_i, .m_axi_bresp_i, .m_axi_bvalid_i, .m_axi_bready_o);

  // ---------------- run end, events ----------------
  assign run_done    = busy && !start && cd_q && ph_q == PK_D && !pk_valid_q && wc_n_q == '0 &&
                       rc_n_q == '0 && !wr_busy;
  assign am_valid    = run_done && d_op == OP_AMAX;
  assign rd_stall_ev = rd_busy && d_want && !d_valid;
  assign rd_err_ev   = m_axi_rvalid_i && m_axi_rready_o && m_axi_rresp_i[1];
  assign wr_err_ev   = m_axi_bvalid_i && m_axi_bready_o && m_axi_bresp_i[1];

`ifndef SYNTHESIS
  logic c_rec_q, c_wec_q;
  always @(posedge clk) begin
    if (rst_n === 1'b1 && rd_ecmd && !c_rec_q) $error("L3_ENGCMD vec_top %m: the read engine rejected a command");
    if (rst_n === 1'b1 && wr_ecmd && !c_wec_q) $error("L3_ENGCMD vec_top %m: the write engine rejected a command");
    c_rec_q <= (rst_n === 1'b1) && rd_ecmd;
    c_wec_q <= (rst_n === 1'b1) && wr_ecmd;
    if (rst_n === 1'b1 && q_valid && !busy) $error("L3_SEQ vec_top %m: q outside a call");
  end
`endif

endmodule
