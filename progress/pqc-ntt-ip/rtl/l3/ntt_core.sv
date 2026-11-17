// ntt_core: NTT / INTT / basemul core of pqc-ntt-ip (L3).
//
// Spec: docs/spec/arch.md ("decisions", "bfu interface", "bfu pipeline",
// "basemul datapath requirements", "L2 results"), docs/spec/hierarchy.md.
// Built from the L2 / L1 modules only:
//   u_ctrl   ntt_ctrl   schedule controller (pure control)
//   u_bank0  coef_ram   bank 0, 256 x 12b true dual port
//   u_bank1  coef_ram   bank 1
//   u_rom    zeta_rom   zeta / gamma / K2 constants of ALGO
//   u_bfu    bfu        unified CT / GS butterfly
// plus the datapath glue of this level, which decodes the ntt_ctrl outputs
// exactly as in the timing table of the rtl/l2/ntt_ctrl.sv header (that table
// is the authority; nothing of ntt_ctrl is re-derived here):
//
//   glue element          width   load / select (cycle of ntt_ctrl table)
//   A0, A1 (bank0 A/B)    2 x 12  opnd_ld_o (E): A0 <= bank0 rdata_a, A1 <= bank0 rdata_b
//   B0, B1 (bank1 A/B)    2 x 12  opnd_ld_o (E): B0 <= bank1 rdata_a, B1 <= bank1 rdata_b
//   R0                    12      tmp_ld_o[0] (W): R0 <= bfu x_o
//   R1                    12      tmp_ld_o[1] (W): R1 <= bfu x_o; only built when the
//                                 basemul program has 7 ops (S != 1, MONT12 / K2RED)
//   bfu a_i mux 3:1       12      bfu_a_sel_o (E): RAM rdata_a[rd_bank_o] | 0 | R0
//   bfu b_i mux 5:1       12      bfu_b_sel_o (E): RAM rdata_b[rd_bank_o] | A0 | A1 | R0 | R1
//   bfu z_i mux 3:1       12      bfu_z_sel_o (E): zeta_rom data_o | B0 | B1
//   RAM port A wdata 2:1  12      ram_wsrc_o: bfu x_o | s_data_i (LOAD), shared by both banks
//   RAM port B wdata      12      bfu y_o (no mux), shared by both banks
//   out stream data 2:1   12      rd_bank_o (UNLOAD): rdata_a of bank rd_bank_o
// All glue registers are datapath registers: no reset, loaded only by their
// enable (design-methodology.md register reset rule). The stream handshakes
// (s_ready_o, m_valid_o) and everything else of the control come from ntt_ctrl.
//
// Local interface (arch.md, "CSR and stream"):
//   start_i / op_i / bank_i   command, accepted when busy_o = 0 (see ntt_ctrl)
//     OP_LOAD    bank_i <- 256 words of the input stream          result bank_i
//     OP_NTT     bank_i -> NTT (7 CT layers, ping-pong)           result ~bank_i
//     OP_INTT    bank_i -> NTT^-1 (7 GS layers, 1/2 per layer)    result ~bank_i
//     OP_BASEMUL bank0 (a) x bank1 (b) in the NTT domain          result bank0
//     OP_UNLOAD  256 words of bank_i -> output stream             result bank_i
//   NTT and INTT use both banks: the contents of the input bank are
//   overwritten by intermediate layers.
//   busy_o, done_o (1-cycle pulse, start_i accepted in that cycle),
//   result_bank_o (valid from done_o until the next done_o).
//   s_valid_i / s_ready_o / s_data_i   input stream (AXI4-Stream style). Data
//     must be canonical [0, Q) (simulation assertion L3_RANGE).
//   m_valid_o / m_ready_i / m_data_o   output stream, backpressure supported;
//     m_data_o is held by the RAM while m_valid_o = 1 and m_ready_i = 0.
//     Combinational path m_ready_i -> RAM enable inside ntt_ctrl.
//
// Parameters: ALGO and the bfu pipeline (PRE_REG, MUL_REG, RED_PIPE, OUT_REG,
// SHARE_ADDSUB, see bfu.sv), ROM_OUT_REG = zeta_rom OUT_REG. The ntt_ctrl
// timing parameters are not inputs: BFU_LATENCY and ROM_LAT are computed here
// with the same expressions as the bfu / zeta_rom LATENCY localparams and are
// checked against those localparams when the simulator elaborates the design
// (hierarchical reference, an elaboration error on mismatch), RAM_LAT likewise
// against coef_ram LATENCY.
//
// SHARE_ADDSUB = 1 needs at least LATENCY idle bfu cycles between a CT input
// and a later GS input. ntt_ctrl provides this at every op boundary: an op
// ends D_WB = RAM_LAT + BFU_LATENCY cycles after its last issue and the next
// op issues its first read at the earliest in the done_o cycle, so the next
// bfu input follows the last one by at least BFU_LATENCY + 1 cycles. The bfu
// assertion L1_SHARE checks it in simulation.
module ntt_core
  import mlkem_pkg::*;
  import ntt_l2_pkg::*;
#(
  parameter algo_e ALGO         = ALGO_BARRETT, // reduction variant
  parameter int    PRE_REG      = 0,            // bfu, 0..1
  parameter int    MUL_REG      = 0,            // bfu, 0..1
  parameter int    RED_PIPE     = 0,            // bfu, 0..MOD_RED_PIPE_MAX
  parameter int    OUT_REG      = 0,            // bfu, 0..1
  parameter int    SHARE_ADDSUB = 0,            // bfu, 0..1
  parameter int    ROM_OUT_REG  = 1             // zeta_rom OUT_REG, 0..1
) (
  input  logic              clk,
  input  logic              rst_n,        // async assert, sync deassert
  // command / status
  input  logic              start_i,
  input  op_e               op_i,
  input  logic              bank_i,
  output logic              busy_o,
  output logic              done_o,
  output logic              result_bank_o,
  // input coefficient stream
  input  logic              s_valid_i,
  output logic              s_ready_o,
  input  logic [COEF_W-1:0] s_data_i,     // [0, Q)
  // output coefficient stream
  output logic              m_valid_o,
  input  logic              m_ready_i,
  output logic [COEF_W-1:0] m_data_o      // [0, Q)
);

  // --------------------------------------------------------------------------
  // Timing parameters of ntt_ctrl, derived from the sub-module LATENCY
  // localparams (same expressions, checked below).
  // --------------------------------------------------------------------------
  localparam int BFU_LATENCY = PRE_REG + MUL_REG + RED_PIPE + OUT_REG;   // bfu LATENCY
  localparam int ROM_LAT     = ROM_OUT_REG;                              // zeta_rom LATENCY
  localparam int RAM_LAT     = 1;                                        // coef_ram LATENCY
  localparam int BM_NOPS     = basemul_nops(ALGO);

  // --------------------------------------------------------------------------
  // Sub-modules
  // --------------------------------------------------------------------------
  // ntt_ctrl outputs
  logic [1:0]             ram_en_a, ram_we_a, ram_en_b, ram_we_b;
  logic [1:0][RAM_AW-1:0] ram_addr_a, ram_addr_b;
  wsrc_e                  ram_wsrc;
  logic                   rom_en;
  rom_kind_e              rom_kind;
  logic [ROM_AW-1:0]      rom_addr;
  logic                   bfu_valid;
  mode_e                  bfu_mode;
  a_sel_e                 bfu_a_sel;
  b_sel_e                 bfu_b_sel;
  z_sel_e                 bfu_z_sel;
  logic                   rd_bank;
  logic                   opnd_ld;
  logic [1:0]             tmp_ld;

  // datapath
  logic [COEF_W-1:0] rdata_a [2];
  logic [COEF_W-1:0] rdata_b [2];
  logic [COEF_W-1:0] wdata_a, wdata_b;
  logic [COEF_W-1:0] rom_data;
  logic [COEF_W-1:0] bfu_a, bfu_b, bfu_z, bfu_x, bfu_y;
  logic              bfu_vo;

  ntt_ctrl #(
    .ALGO        (ALGO),
    .BFU_LATENCY (BFU_LATENCY),
    .RAM_LAT     (RAM_LAT),
    .ROM_LAT     (ROM_LAT)
  ) u_ctrl (
    .clk           (clk),
    .rst_n         (rst_n),
    .start_i       (start_i),
    .op_i          (op_i),
    .bank_i        (bank_i),
    .busy_o        (busy_o),
    .done_o        (done_o),
    .result_bank_o (result_bank_o),
    .s_valid_i     (s_valid_i),
    .s_ready_o     (s_ready_o),
    .m_valid_o     (m_valid_o),
    .m_ready_i     (m_ready_i),
    .ram_en_a_o    (ram_en_a),
    .ram_we_a_o    (ram_we_a),
    .ram_addr_a_o  (ram_addr_a),
    .ram_en_b_o    (ram_en_b),
    .ram_we_b_o    (ram_we_b),
    .ram_addr_b_o  (ram_addr_b),
    .ram_wsrc_o    (ram_wsrc),
    .rom_en_o      (rom_en),
    .rom_kind_o    (rom_kind),
    .rom_addr_o    (rom_addr),
    .bfu_valid_o   (bfu_valid),
    .bfu_mode_o    (bfu_mode),
    .bfu_a_sel_o   (bfu_a_sel),
    .bfu_b_sel_o   (bfu_b_sel),
    .bfu_z_sel_o   (bfu_z_sel),
    .rd_bank_o     (rd_bank),
    .opnd_ld_o     (opnd_ld),
    .tmp_ld_o      (tmp_ld)
  );

  coef_ram #(.DEPTH(N_COEF)) u_bank0 (
    .clk       (clk),
    .rst_n     (rst_n),
    .en_a_i    (ram_en_a[0]),
    .we_a_i    (ram_we_a[0]),
    .addr_a_i  (ram_addr_a[0]),
    .wdata_a_i (wdata_a),
    .rdata_a_o (rdata_a[0]),
    .en_b_i    (ram_en_b[0]),
    .we_b_i    (ram_we_b[0]),
    .addr_b_i  (ram_addr_b[0]),
    .wdata_b_i (wdata_b),
    .rdata_b_o (rdata_b[0])
  );

  coef_ram #(.DEPTH(N_COEF)) u_bank1 (
    .clk       (clk),
    .rst_n     (rst_n),
    .en_a_i    (ram_en_a[1]),
    .we_a_i    (ram_we_a[1]),
    .addr_a_i  (ram_addr_a[1]),
    .wdata_a_i (wdata_a),
    .rdata_a_o (rdata_a[1]),
    .en_b_i    (ram_en_b[1]),
    .we_b_i    (ram_we_b[1]),
    .addr_b_i  (ram_addr_b[1]),
    .wdata_b_i (wdata_b),
    .rdata_b_o (rdata_b[1])
  );

  zeta_rom #(.ALGO(ALGO), .OUT_REG(ROM_OUT_REG)) u_rom (
    .clk    (clk),
    .rst_n  (rst_n),
    .en_i   (rom_en),
    .kind_i (rom_kind),
    .addr_i (rom_addr),
    .data_o (rom_data)
  );

  bfu #(
    .ALGO         (ALGO),
    .PRE_REG      (PRE_REG),
    .MUL_REG      (MUL_REG),
    .RED_PIPE     (RED_PIPE),
    .OUT_REG      (OUT_REG),
    .SHARE_ADDSUB (SHARE_ADDSUB)
  ) u_bfu (
    .clk     (clk),
    .rst_n   (rst_n),
    .mode_i  (bfu_mode),
    .a_i     (bfu_a),
    .b_i     (bfu_b),
    .z_i     (bfu_z),
    .valid_i (bfu_valid),
    .x_o     (bfu_x),
    .y_o     (bfu_y),
    .valid_o (bfu_vo)
  );

  // --------------------------------------------------------------------------
  // Elaboration checks: the derived timing must equal the sub-module LATENCY
  // localparams (a mismatch would shift every write back of ntt_ctrl).
  // Hierarchical names in a generate condition are accepted by Questa but not
  // guaranteed by every synthesis tool, so the checks are simulation-only;
  // the values above use the same expressions as the sub-modules.
  // --------------------------------------------------------------------------
`ifndef SYNTHESIS
  if (u_bfu.LATENCY != BFU_LATENCY) begin : g_bad_bfu_lat
    $error("ntt_core: BFU_LATENCY=%0d passed to ntt_ctrl != bfu LATENCY=%0d",
           BFU_LATENCY, u_bfu.LATENCY);
  end
  if (u_rom.LATENCY != ROM_LAT) begin : g_bad_rom_lat
    $error("ntt_core: ROM_LAT=%0d passed to ntt_ctrl != zeta_rom LATENCY=%0d",
           ROM_LAT, u_rom.LATENCY);
  end
  if (u_bank0.LATENCY != RAM_LAT || u_bank1.LATENCY != RAM_LAT) begin : g_bad_ram_lat
    $error("ntt_core: RAM_LAT=%0d passed to ntt_ctrl != coef_ram LATENCY", RAM_LAT);
  end
`endif

  // --------------------------------------------------------------------------
  // Datapath glue
  // --------------------------------------------------------------------------
  // basemul operand registers (E) and temporaries (W)
  logic [COEF_W-1:0] a0_q, a1_q, b0_q, b1_q, r0_q, r1_q;

  always_ff @(posedge clk) begin
    if (opnd_ld) begin
      a0_q <= rdata_a[0];
      a1_q <= rdata_b[0];
      b0_q <= rdata_a[1];
      b1_q <= rdata_b[1];
    end
  end

  always_ff @(posedge clk) begin
    if (tmp_ld[0]) r0_q <= bfu_x;
  end

  if (BM_NOPS > 5) begin : g_r1
    always_ff @(posedge clk) begin
      if (tmp_ld[1]) r1_q <= bfu_x;
    end
  end else begin : g_no_r1
    // 5-op program (S = 1) never selects or loads R1.
    assign r1_q = '0;
  end

  // bfu input muxes (E)
  always_comb begin
    unique case (bfu_a_sel)
      ASEL_RAM:  bfu_a = rdata_a[rd_bank];
      ASEL_R0:   bfu_a = r0_q;
      default:   bfu_a = '0;                    // ASEL_ZERO
    endcase
    unique case (bfu_b_sel)
      BSEL_RAM:  bfu_b = rdata_b[rd_bank];
      BSEL_A0:   bfu_b = a0_q;
      BSEL_A1:   bfu_b = a1_q;
      BSEL_R0:   bfu_b = r0_q;
      BSEL_R1:   bfu_b = r1_q;
      default:   bfu_b = '0;
    endcase
    unique case (bfu_z_sel)
      ZSEL_B0:   bfu_z = b0_q;
      ZSEL_B1:   bfu_z = b1_q;
      default:   bfu_z = rom_data;              // ZSEL_ROM
    endcase
  end

  // RAM write data (both banks share it; ntt_ctrl enables one bank)
  assign wdata_a = (ram_wsrc == WSRC_STREAM) ? s_data_i : bfu_x;
  assign wdata_b = bfu_y;

  // output stream data: port A read data of the UNLOAD bank, held by the RAM
  assign m_data_o = rdata_a[rd_bank];

  // --------------------------------------------------------------------------
  // Simulation-only checks
  // --------------------------------------------------------------------------
`ifndef SYNTHESIS
  // Input stream words must be known and canonical when accepted.
  always_comb begin
    if (rst_n === 1'b1 && s_valid_i === 1'b1 && s_ready_o === 1'b1) begin
      s_in_range : assert final (!$isunknown(s_data_i) && s_data_i < COEF_W'(Q))
        else $error("L3_RANGE ntt_core: input stream word out of [0, Q): s_data_i=%0d", s_data_i);
    end
  end

  // The bfu output valid must match the write back timing of ntt_ctrl: every
  // RAM write of bfu data and every temporary load happens with valid_o = 1.
  always_comb begin
    if (rst_n === 1'b1 && (tmp_ld != 2'b00
                           || ((ram_we_a & ram_en_a) != 2'b00 && ram_wsrc == WSRC_BFU)
                           || (ram_we_b & ram_en_b) != 2'b00)) begin
      wb_valid : assert final (bfu_vo === 1'b1)
        else $error("L3_WB ntt_core: bfu result written back while bfu valid_o=%b", bfu_vo);
    end
  end
`endif

endmodule
