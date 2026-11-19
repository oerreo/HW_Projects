// bw_top: HP-port bandwidth measurement top (S4-3, docs/spec/bwtest.md; arch.md 9 item 3).
//
// AXI4-Lite CSR (axil_slave) + per port p < P: axi_rd_eng (data discarded into a checksum)
// and axi_wr_eng (fed by a pattern generator). One op runs the selected engines of the
// enabled ports at the same time:
//   op 1 RD   each enabled port reads LEN bytes at RD_ADDRp; XOR and SUM (mod 2^64) of the
//             64-bit beats, bytes beyond LEN in the last beat masked to 0
//   op 2 WR   each enabled port writes LEN bytes at WR_ADDRp: beat k = PAT_p(k),
//             PAT_p(0) = {SEED_HI ^ p, SEED_LO}, PAT_p(k + 1) = PAT_p(k) + INC (mod 2^64)
//   op 3 RW   both at the same time on every enabled port
// Register map, timing definitions and error rules: docs/spec/bwtest.md. This module is the
// L3 control (CSR, op sequencing, counters, checksum, pattern); the AXI work is in the engines.
//
// ERR.ENG_CMD (an engine rejected a command) cannot occur after the descriptor check above;
// it stays as a guard. Timing reference: the CTRL write that starts an op is performed in cycle s (axil_slave
// wr_en_o). The engines get their commands in s + 1. A port's read is done in the cycle its
// last beat leaves the engine (e_rd), its write in the cycle of the last B handshake (e_wr).
// CYCLES = e - s for the last of them, RD_CYCp = e_rd - s, WR_CYCp = e_wr - s.
// RD_STALLp = cycles of the read engine being busy without a beat (the sink is always ready),
// so RD_STALLp = RD_CYCp - 1 - beats. WR_STALLp = cycles the pattern generator had a beat the
// write engine did not take.
module bw_top #(
  parameter int P         = 1,                 // ports 1 or 2
  parameter int MAX_BURST = 16,                // engine burst limit (16: AXI3 HP port)
  parameter int OUTS      = 4,                 // engine outstanding limit
  parameter int RD_FIFO   = MAX_BURST * OUTS,  // axi_rd_eng FIFO_DEPTH
  parameter int WR_FIFO   = 2 * MAX_BURST,     // axi_wr_eng FIFO_DEPTH
  parameter int IDW       = 1,                 // AXI ID width of the masters
  parameter int FCLK_MHZ  = 100,               // CONFIG register only, 1..255
  parameter int ADDR_W    = 12                 // AXI4-Lite address width 8..32
) (
  input  logic                    clk,
  input  logic                    rst_n,
  // AXI4-Lite slave (CSR)
  input  logic [ADDR_W-1:0]       s_axi_awaddr_i,
  input  logic [2:0]              s_axi_awprot_i,
  input  logic                    s_axi_awvalid_i,
  output logic                    s_axi_awready_o,
  input  logic [31:0]             s_axi_wdata_i,
  input  logic [3:0]              s_axi_wstrb_i,
  input  logic                    s_axi_wvalid_i,
  output logic                    s_axi_wready_o,
  output logic [1:0]              s_axi_bresp_o,
  output logic                    s_axi_bvalid_o,
  input  logic                    s_axi_bready_i,
  input  logic [ADDR_W-1:0]       s_axi_araddr_i,
  input  logic [2:0]              s_axi_arprot_i,
  input  logic                    s_axi_arvalid_i,
  output logic                    s_axi_arready_o,
  output logic [31:0]             s_axi_rdata_o,
  output logic [1:0]              s_axi_rresp_o,
  output logic                    s_axi_rvalid_o,
  input  logic                    s_axi_rready_i,
  // AXI4 masters, index = port
  output logic [P-1:0][IDW-1:0]   m_axi_awid_o,
  output logic [P-1:0][31:0]      m_axi_awaddr_o,
  output logic [P-1:0][7:0]       m_axi_awlen_o,
  output logic [P-1:0][2:0]       m_axi_awsize_o,
  output logic [P-1:0][1:0]       m_axi_awburst_o,
  output logic [P-1:0]            m_axi_awlock_o,
  output logic [P-1:0][3:0]       m_axi_awcache_o,
  output logic [P-1:0][2:0]       m_axi_awprot_o,
  output logic [P-1:0][3:0]       m_axi_awqos_o,
  output logic [P-1:0]            m_axi_awvalid_o,
  input  logic [P-1:0]            m_axi_awready_i,
  output logic [P-1:0][63:0]      m_axi_wdata_o,
  output logic [P-1:0][7:0]       m_axi_wstrb_o,
  output logic [P-1:0]            m_axi_wlast_o,
  output logic [P-1:0]            m_axi_wvalid_o,
  input  logic [P-1:0]            m_axi_wready_i,
  input  wire  [P-1:0][IDW-1:0]   m_axi_bid_i,
  input  wire  [P-1:0][1:0]       m_axi_bresp_i,
  input  logic [P-1:0]            m_axi_bvalid_i,
  output logic [P-1:0]            m_axi_bready_o,
  output logic [P-1:0][IDW-1:0]   m_axi_arid_o,
  output logic [P-1:0][31:0]      m_axi_araddr_o,
  output logic [P-1:0][7:0]       m_axi_arlen_o,
  output logic [P-1:0][2:0]       m_axi_arsize_o,
  output logic [P-1:0][1:0]       m_axi_arburst_o,
  output logic [P-1:0]            m_axi_arlock_o,
  output logic [P-1:0][3:0]       m_axi_arcache_o,
  output logic [P-1:0][2:0]       m_axi_arprot_o,
  output logic [P-1:0][3:0]       m_axi_arqos_o,
  output logic [P-1:0]            m_axi_arvalid_o,
  input  logic [P-1:0]            m_axi_arready_i,
  input  wire  [P-1:0][IDW-1:0]   m_axi_rid_i,
  input  wire  [P-1:0][63:0]      m_axi_rdata_i,
  input  wire  [P-1:0][1:0]       m_axi_rresp_i,
  input  logic [P-1:0]            m_axi_rlast_i,
  input  logic [P-1:0]            m_axi_rvalid_i,
  output logic [P-1:0]            m_axi_rready_o
);

  if (P < 1 || P > 2) $error("bw_top: P=%0d must be 1 or 2", P);
  if (FCLK_MHZ < 1 || FCLK_MHZ > 255) $error("bw_top: FCLK_MHZ=%0d must be 1..255", FCLK_MHZ);
  if (ADDR_W < 8 || ADDR_W > 32) $error("bw_top: ADDR_W=%0d must be 8..32", ADDR_W);
  // MAX_BURST, OUTS, FIFO depths: checked by the engines

  localparam logic [31:0] ID_VAL  = 32'h4257_0001;            // "BW", version 1
  localparam logic [63:0] PAT_INC = 64'h9E37_79B9_7F4A_7C15;
  localparam logic [31:0] CONFIG_VAL = {3'd0, 9'(MAX_BURST), 8'(OUTS), 4'(P), 8'(FCLK_MHZ)};

  // register word offsets (byte offset / 4)
  localparam logic [5:0] R_ID = 6'h00, R_CONFIG = 6'h01, R_CTRL = 6'h02, R_STATUS = 6'h03,
                         R_ERR = 6'h04, R_CYCLES = 6'h05, R_RDSTALL = 6'h06, R_WRSTALL = 6'h07,
                         R_OPS = 6'h08, R_LEN = 6'h10, R_BURST = 6'h11, R_OUTS = 6'h12,
                         R_PORTS = 6'h13, R_SEEDLO = 6'h14, R_SEEDHI = 6'h15,
                         R_RDADDR0 = 6'h18, R_RDADDR1 = 6'h19, R_WRADDR0 = 6'h1A, R_WRADDR1 = 6'h1B;
  // per-port result block at 0x80 + 0x20 p: word 0x20 + 8 p + i
  // beats at 0xC0 + 8 p (RD_BEATS) and 0xC4 + 8 p (WR_BEATS): word 0x30 + 2 p (+1)

  localparam int E_START_BUSY = 0, E_BAD_OP = 1, E_BAD_DESC = 2, E_RD_RESP = 3, E_WR_RESP = 4,
                 E_ENG_CMD = 5;

  // ---------------- AXI4-Lite ----------------
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
    .rd_en_o(rd_en), .rd_addr_o(rd_addr), .rd_data_i(rd_data)
  );

  logic       wr_hit, rd_hit;
  logic [5:0] wr_w, rd_w;
  logic [31:0] wr_a32, rd_a32;
  assign wr_a32 = 32'(wr_addr);
  assign rd_a32 = 32'(rd_addr);
  assign wr_hit = wr_a32[31:8] == 24'd0;   // registers in the first 256 bytes, rest reads 0
  assign rd_hit = rd_a32[31:8] == 24'd0;
  assign wr_w   = wr_addr[7:2];
  assign rd_w   = rd_addr[7:2];

  // ---------------- configuration registers ----------------
  logic [31:0] len_r, seed_lo_r, seed_hi_r;
  logic [8:0]  burst_r;
  logic [6:0]  outs_r;
  logic [1:0]  ports_r;
  logic [1:0][31:0] rdaddr_r, wraddr_r;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      len_r     <= 32'd0;
      burst_r   <= 9'(MAX_BURST);
      outs_r    <= 7'(OUTS);
      ports_r   <= 2'b01;
      seed_lo_r <= 32'd0;
      seed_hi_r <= 32'd0;
      rdaddr_r  <= '0;
      wraddr_r  <= '0;
    end else if (wr_en && wr_hit) begin
      case (wr_w)
        R_LEN:     len_r       <= wr_data;
        R_BURST:   burst_r     <= wr_data[8:0];
        R_OUTS:    outs_r      <= wr_data[6:0];
        R_PORTS:   ports_r     <= wr_data[1:0];
        R_SEEDLO:  seed_lo_r   <= wr_data;
        R_SEEDHI:  seed_hi_r   <= wr_data;
        R_RDADDR0: rdaddr_r[0] <= wr_data;
        R_RDADDR1: rdaddr_r[1] <= wr_data;
        R_WRADDR0: wraddr_r[0] <= wr_data;
        R_WRADDR1: wraddr_r[1] <= wr_data;
        default: ;
      endcase
    end

  // ---------------- start and descriptor check ----------------
  logic       ctrl_wr, start_req;
  logic [1:0] op_w;
  logic       op_rd_w, op_wr_w, desc_ok;
  logic       busy_q, done_q, all_done;
  logic [5:0] err_q, err_set;
  logic       start;

  assign ctrl_wr   = wr_en && wr_hit && (wr_w == R_CTRL);
  assign start_req = ctrl_wr && wr_data[0];
  assign op_w      = wr_data[5:4];
  assign op_rd_w   = op_w[0];
  assign op_wr_w   = op_w[1];
  always_comb begin
    desc_ok = (len_r != 32'd0) && (burst_r != 9'd0) && (burst_r <= 9'(MAX_BURST)) &&
              (outs_r != 7'd0) && (outs_r <= 7'(OUTS)) && (ports_r != 2'b00) &&
              ((P == 2) || !ports_r[1]);
    // per used engine: 8-byte aligned address and no range past 2^32 (the engines would
    // reject such a command; a rejected write would leave pattern beats in its buffer)
    for (int p = 0; p < 2; p++)
      if (ports_r[p] && ((op_rd_w && (rdaddr_r[p][2:0] != 3'd0 ||
                                      {1'b0, rdaddr_r[p]} + {1'b0, len_r} > 33'h1_0000_0000)) ||
                         (op_wr_w && (wraddr_r[p][2:0] != 3'd0 ||
                                      {1'b0, wraddr_r[p]} + {1'b0, len_r} > 33'h1_0000_0000))))
        desc_ok = 1'b0;
  end
  assign start = start_req && !busy_q && (op_w != 2'd0) && desc_ok;

  // op registers, latched at the start
  logic [31:0] len_q;
  logic [8:0]  burst_q;
  logic [6:0]  outs_q;
  logic [31:0] cnt_q, ops_q;
  always_ff @(posedge clk)
    if (start) begin
      len_q   <= len_r;
      burst_q <= burst_r;
      outs_q  <= outs_r;
    end

  // ---------------- ports ----------------
  wire [P-1:0] p_done_now, p_rd_eresp, p_wr_eresp, p_ecmd;
  wire [P-1:0][63:0] xor_w, sum_w;
  wire [P-1:0][31:0] rdcyc_w, wrcyc_w, rdst_w, wrst_w, rdbt_w, wrbt_w;

  for (genvar p = 0; p < P; p++) begin : g_port
    logic        use_rd, use_wr;                // this port takes part in the op (start values)
    logic        rd_cmd_q, wr_cmd_q, rd_cmd_rdy, wr_cmd_rdy;
    logic        rd_fin_q, wr_fin_q, rd_done, wr_done;
    logic [31:0] rd_a_q, wr_a_q;
    logic        d_valid, d_last, rd_stall, wr_stall, rd_eresp, rd_ecmd, wr_eresp, wr_ecmd;
    logic [63:0] d_data, d_m, src_d_q;
    logic [29:0] src_n_q;                        // beats left, up to 2^29
    logic        src_valid, src_ready;
    logic        rd_eresp_q, rd_ecmd_q, wr_eresp_q, wr_ecmd_q;
    logic [63:0] xor_q, sum_q;
    logic [31:0] rdcyc_q, wrcyc_q, rdst_q, wrst_q, rdbt_q, wrbt_q;

    assign use_rd = op_rd_w && ports_r[p];
    assign use_wr = op_wr_w && ports_r[p];

    axi_rd_eng #(.AW(32), .IDW(IDW), .LEN_W(32), .MAX_BURST(MAX_BURST), .OUTS(OUTS),
                 .FIFO_DEPTH(RD_FIFO)) u_rd (
      .clk, .rst_n,
      .cfg_burst_i(burst_q), .cfg_outs_i(outs_q),
      .cmd_valid_i(rd_cmd_q), .cmd_ready_o(rd_cmd_rdy), .cmd_addr_i(rd_a_q), .cmd_bytes_i(len_q),
      .d_valid_o(d_valid), .d_ready_i(1'b1), .d_data_o(d_data), .d_last_o(d_last),
      .busy_o(), .done_o(rd_done), .stall_o(rd_stall), .err_resp_o(rd_eresp), .err_cmd_o(rd_ecmd),
      .err_clr_i(start),
      .m_axi_arid_o(m_axi_arid_o[p]), .m_axi_araddr_o(m_axi_araddr_o[p]),
      .m_axi_arlen_o(m_axi_arlen_o[p]), .m_axi_arsize_o(m_axi_arsize_o[p]),
      .m_axi_arburst_o(m_axi_arburst_o[p]), .m_axi_arlock_o(m_axi_arlock_o[p]),
      .m_axi_arcache_o(m_axi_arcache_o[p]), .m_axi_arprot_o(m_axi_arprot_o[p]),
      .m_axi_arqos_o(m_axi_arqos_o[p]), .m_axi_arvalid_o(m_axi_arvalid_o[p]),
      .m_axi_arready_i(m_axi_arready_i[p]),
      .m_axi_rid_i(m_axi_rid_i[p]), .m_axi_rdata_i(m_axi_rdata_i[p]), .m_axi_rresp_i(m_axi_rresp_i[p]),
      .m_axi_rlast_i(m_axi_rlast_i[p]), .m_axi_rvalid_i(m_axi_rvalid_i[p]),
      .m_axi_rready_o(m_axi_rready_o[p]));

    axi_wr_eng #(.AW(32), .IDW(IDW), .LEN_W(32), .MAX_BURST(MAX_BURST), .OUTS(OUTS),
                 .FIFO_DEPTH(WR_FIFO)) u_wr (
      .clk, .rst_n,
      .cfg_burst_i(burst_q), .cfg_outs_i(outs_q),
      .cmd_valid_i(wr_cmd_q), .cmd_ready_o(wr_cmd_rdy), .cmd_addr_i(wr_a_q), .cmd_bytes_i(len_q),
      .in_valid_i(src_valid), .in_ready_o(src_ready), .in_data_i(src_d_q),
      .busy_o(), .done_o(wr_done), .stall_o(wr_stall), .err_resp_o(wr_eresp), .err_cmd_o(wr_ecmd),
      .err_clr_i(start),
      .m_axi_awid_o(m_axi_awid_o[p]), .m_axi_awaddr_o(m_axi_awaddr_o[p]),
      .m_axi_awlen_o(m_axi_awlen_o[p]), .m_axi_awsize_o(m_axi_awsize_o[p]),
      .m_axi_awburst_o(m_axi_awburst_o[p]), .m_axi_awlock_o(m_axi_awlock_o[p]),
      .m_axi_awcache_o(m_axi_awcache_o[p]), .m_axi_awprot_o(m_axi_awprot_o[p]),
      .m_axi_awqos_o(m_axi_awqos_o[p]), .m_axi_awvalid_o(m_axi_awvalid_o[p]),
      .m_axi_awready_i(m_axi_awready_i[p]),
      .m_axi_wdata_o(m_axi_wdata_o[p]), .m_axi_wstrb_o(m_axi_wstrb_o[p]),
      .m_axi_wlast_o(m_axi_wlast_o[p]), .m_axi_wvalid_o(m_axi_wvalid_o[p]),
      .m_axi_wready_i(m_axi_wready_i[p]),
      .m_axi_bid_i(m_axi_bid_i[p]), .m_axi_bresp_i(m_axi_bresp_i[p]),
      .m_axi_bvalid_i(m_axi_bvalid_i[p]), .m_axi_bready_o(m_axi_bready_o[p]));

    // last-beat mask: bytes beyond LEN are 0 in the checksum
    always_comb begin
      d_m = d_data;
      if (d_last && len_q[2:0] != 3'd0)
        for (int b = 0; b < 8; b++) if (b >= int'(len_q[2:0])) d_m[8*b +: 8] = 8'h00;
    end

    assign src_valid = src_n_q != '0;

    // control: command valid, finish flags, pattern beat count
    always_ff @(posedge clk or negedge rst_n)
      if (!rst_n) begin
        rd_cmd_q   <= 1'b0;
        wr_cmd_q   <= 1'b0;
        rd_fin_q   <= 1'b1;
        wr_fin_q   <= 1'b1;
        src_n_q    <= '0;
        rd_eresp_q <= 1'b0;
        rd_ecmd_q  <= 1'b0;
        wr_eresp_q <= 1'b0;
        wr_ecmd_q  <= 1'b0;
      end else begin
        if (start) begin
          rd_cmd_q <= use_rd;
          wr_cmd_q <= use_wr;
          rd_fin_q <= !use_rd;
          wr_fin_q <= !use_wr;
          src_n_q  <= use_wr ? 30'(({2'b0, len_r} + 34'd7) >> 3) : 30'd0;
        end else begin
          if (rd_cmd_rdy) rd_cmd_q <= 1'b0;
          if (wr_cmd_rdy) wr_cmd_q <= 1'b0;
          if (rd_done) rd_fin_q <= 1'b1;
          if (wr_done) wr_fin_q <= 1'b1;
          if (src_valid && src_ready) src_n_q <= src_n_q - 1'b1;
        end
        rd_eresp_q <= rd_eresp;
        rd_ecmd_q  <= rd_ecmd;
        wr_eresp_q <= wr_eresp;
        wr_ecmd_q  <= wr_ecmd;
      end

    // results (counters reset by the start of an op)
    always_ff @(posedge clk or negedge rst_n)
      if (!rst_n) begin
        xor_q   <= '0;
        sum_q   <= '0;
        rdcyc_q <= '0;
        wrcyc_q <= '0;
        rdst_q  <= '0;
        wrst_q  <= '0;
        rdbt_q  <= '0;
        wrbt_q  <= '0;
      end else if (start) begin
        xor_q   <= '0;
        sum_q   <= '0;
        rdcyc_q <= '0;
        wrcyc_q <= '0;
        rdst_q  <= '0;
        wrst_q  <= '0;
        rdbt_q  <= '0;
        wrbt_q  <= '0;
      end else begin
        if (d_valid) begin            // the sink is always ready: d_valid = beat accepted
          xor_q <= xor_q ^ d_m;
          sum_q <= sum_q + d_m;
        end
        if (rd_done && !rd_fin_q) rdcyc_q <= cnt_q + 32'd1;
        if (wr_done && !wr_fin_q) wrcyc_q <= cnt_q + 32'd1;
        if (rd_stall) rdst_q <= rdst_q + 32'd1;
        if (wr_stall) wrst_q <= wrst_q + 32'd1;
        if (m_axi_rvalid_i[p] && m_axi_rready_o[p]) rdbt_q <= rdbt_q + 32'd1;
        if (m_axi_wvalid_o[p] && m_axi_wready_i[p]) wrbt_q <= wrbt_q + 32'd1;
      end
    assign xor_w[p]   = xor_q;
    assign sum_w[p]   = sum_q;
    assign rdcyc_w[p] = rdcyc_q;
    assign wrcyc_w[p] = wrcyc_q;
    assign rdst_w[p]  = rdst_q;
    assign wrst_w[p]  = wrst_q;
    assign rdbt_w[p]  = rdbt_q;
    assign wrbt_w[p]  = wrbt_q;

    // pattern generator data (datapath)
    always_ff @(posedge clk)
      if (start) src_d_q <= {seed_hi_r ^ 32'(p), seed_lo_r};
      else if (src_valid && src_ready) src_d_q <= src_d_q + PAT_INC;

    always_ff @(posedge clk)
      if (start) begin
        rd_a_q <= rdaddr_r[p];
        wr_a_q <= wraddr_r[p];
      end

    assign p_done_now[p] = (rd_fin_q || rd_done) && (wr_fin_q || wr_done);
    assign p_rd_eresp[p] = rd_eresp && !rd_eresp_q;
    assign p_wr_eresp[p] = wr_eresp && !wr_eresp_q;
    assign p_ecmd[p]     = (rd_ecmd && !rd_ecmd_q) || (wr_ecmd && !wr_ecmd_q);
  end

  assign all_done = busy_q && (&p_done_now);

  // ---------------- op state, ERR, counters ----------------
  always_comb begin
    err_set = '0;
    if (ctrl_wr && wr_data[0] && busy_q) err_set[E_START_BUSY] = 1'b1;
    if (start_req && !busy_q && op_w == 2'd0) err_set[E_BAD_OP] = 1'b1;
    if (start_req && !busy_q && op_w != 2'd0 && !desc_ok) err_set[E_BAD_DESC] = 1'b1;
    if (|p_rd_eresp) err_set[E_RD_RESP] = 1'b1;
    if (|p_wr_eresp) err_set[E_WR_RESP] = 1'b1;
    if (|p_ecmd) err_set[E_ENG_CMD] = 1'b1;
  end

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      busy_q <= 1'b0;
      done_q <= 1'b0;
      err_q  <= '0;
      cnt_q  <= '0;
      ops_q  <= '0;
    end else begin
      if (start) busy_q <= 1'b1;
      else if (all_done) busy_q <= 1'b0;
      // done_sticky: set at the end of an op, cleared by a CTRL write while idle
      if (all_done) done_q <= 1'b1;
      else if (ctrl_wr && !busy_q) done_q <= 1'b0;
      // ERR: W1C, a new error in the same cycle wins
      err_q <= (err_q & ~((wr_en && wr_hit && wr_w == R_ERR) ? wr_data[5:0] : 6'd0)) | err_set;
      if (start) cnt_q <= '0;
      else if (busy_q) cnt_q <= cnt_q + 32'd1;
      if (all_done) ops_q <= ops_q + 32'd1;
    end

  // ---------------- read mux ----------------
  always_comb begin
    rd_data = 32'd0;
    if (rd_hit) begin
      case (rd_w)
        R_ID:      rd_data = ID_VAL;
        R_CONFIG:  rd_data = CONFIG_VAL;
        R_STATUS:  rd_data = {29'd0, err_q != '0, done_q, busy_q};
        R_ERR:     rd_data = {26'd0, err_q};
        R_CYCLES:  rd_data = cnt_q;
        R_RDSTALL: rd_data = rdst_w[0];
        R_WRSTALL: rd_data = wrst_w[0];
        R_OPS:     rd_data = ops_q;
        R_LEN:     rd_data = len_r;
        R_BURST:   rd_data = {23'd0, burst_r};
        R_OUTS:    rd_data = {25'd0, outs_r};
        R_PORTS:   rd_data = {30'd0, ports_r};
        R_SEEDLO:  rd_data = seed_lo_r;
        R_SEEDHI:  rd_data = seed_hi_r;
        R_RDADDR0: rd_data = rdaddr_r[0];
        R_RDADDR1: rd_data = rdaddr_r[1];
        R_WRADDR0: rd_data = wraddr_r[0];
        R_WRADDR1: rd_data = wraddr_r[1];
        default: begin
          for (int p = 0; p < P; p++) begin
            if (rd_w[5:3] == 3'(4 + p)) begin
              case (rd_w[2:0])
                3'd0: rd_data = xor_w[p][31:0];
                3'd1: rd_data = xor_w[p][63:32];
                3'd2: rd_data = sum_w[p][31:0];
                3'd3: rd_data = sum_w[p][63:32];
                3'd4: rd_data = rdcyc_w[p];
                3'd5: rd_data = wrcyc_w[p];
                3'd6: rd_data = rdst_w[p];
                default: rd_data = wrst_w[p];
              endcase
            end
            if (rd_w == 6'(6'h30 + 2 * p)) rd_data = rdbt_w[p];
            if (rd_w == 6'(6'h31 + 2 * p)) rd_data = wrbt_w[p];
          end
        end
      endcase
    end
  end

  logic unused_rd_en;
  assign unused_rd_en = rd_en;  // reads have no side effects

endmodule
