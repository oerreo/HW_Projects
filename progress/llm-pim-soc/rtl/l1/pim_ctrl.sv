// pim_ctrl: command controller of the PIM core (arch.md 3.3, hierarchy.md 3.3; command format
// and timing docs/spec/pim.md). One command at a time:
//
//   LDW   (op 1) rows, n, base, addr : read command (addr, rows x 8 (1 + ceil(n/8)) bytes) for the
//                row records (arch.md 2.2), word assembly, bank writes: row r -> bank r mod NB,
//                word base + (r div NB) nw + w (nw = ceil(n/LB)); lane i of word w = column
//                LB w + i (columns >= n written 0), tag = wm in word 0, 0 in the others. The empty
//                slots of the last round (rows not a multiple of NB) are written with zero words.
//                Golden: bimg_pack (model/src/bank.c).
//   WRGB  (op 2) n, addr             : read command (addr, n bytes), the stream goes to pim_gb
//                (gb_sel_o), pim_gb is loaded with n (gb_load_o in the handshake cycle).
//   MACAB (op 3) rows, n, base, xm, we, xe, fo, addr : write command (addr, 4 rows bytes) for y,
//                then ceil(rows/NB) rounds of nw lock-step words: word w of round i is read at
//                base + i nw + w from every bank b with i NB + b < rows (mr_en_o) together with
//                global buffer word w. Each round's results are gathered in bank order
//                (g_valid_o / g_sel_o, one per cycle, row i NB + b) with the command's xm and
//                sh = we + xe - fo; g_last_o marks the command's last row. Golden: bank_gemv
//                BANK_ROW (no reduction between banks).
//
// Schedule rules (MACAB):
//   - The words of a round are read in consecutive cycles. A round may start only if the y
//     results it adds fit the y FIFO credit (rows reserved and not yet popped, y_pop_i, plus the
//     round's rows <= Y_DEPTH), and its last word is read at least NB cycles after the last word
//     of the previous round (any command), so that the gather of NB results (MAC_REG, one per
//     cycle) ends before the next round's results arrive. With nw >= NB rounds follow each other
//     without a gap; with nw < NB a round takes NB cycles.
//   - The results of a round are in the banks' MAC_REG L_BANK cycles after its last word was read
//     (pim_bank LATENCY); the gather starts in that cycle.
//   - A MACAB is accepted only when the write command of the previous MACAB has been taken.
// The controller returns to idle after the last word of the last round (MACAB), the last bank
// write (LDW) or the last gb beat (WRGB); the next command may be accepted in the next cycle.
//
// Events (1-cycle pulses, counted by the CSR; bank_stat_t of model/src/bank.c is the reference):
//   ev_mac_o    one all-bank MAC step (a read cycle; bank_stat mac = ceil(rows/NB) x nw per MACAB)
//   ev_wrgb_o   one 32-byte unit of a WRGB (gb beats 0, 4, 8, ...: ceil(n/32) per WRGB)
//   ev_rdmac_o  one gathered result (rows per MACAB)
//   done_ldw_o / done_wrgb_o / done_mac_o  the command is finished in the controller
// idle_o: nothing of this core in flight: idle, no reserved y, no pending write command.
//
// Commands must be legal (pim_csr checks them before they are queued): op 1..3, 1 <= n <= NMAX,
// rows >= 1 and base + ceil(rows/NB) nw <= DEPTH for LDW / MACAB. Simulation-only checks:
// PIM_RANGE (illegal command; it is dropped), PIM_GATHER (gather overlap), PIM_YOVF (y credit).
module pim_ctrl
  import llm_pkg::*;
#(
  parameter int NB      = 4,
  parameter int LB      = 16,
  parameter int DEPTH   = 4096,
  parameter int NMAX    = N_MAX,
  parameter int Y_DEPTH = 32,
  parameter int L_BANK  = 5,
  parameter int ROWS_W  = 16,
  localparam int AA     = $clog2(DEPTH),
  localparam int NW     = $clog2(NMAX + 1),
  localparam int GA     = $clog2(NMAX / LB),
  localparam int BI_W   = (NB > 1) ? $clog2(NB) : 1,
  localparam int W_WORD = 8 * LB + WM_W
) (
  input  logic                    clk,
  input  logic                    rst_n,
  // command
  input  logic                    cmd_valid_i,
  output logic                    cmd_ready_o,
  input  logic [3:0]              cmd_op_i,
  input  logic [ROWS_W-1:0]       cmd_rows_i,
  input  logic [NW-1:0]           cmd_n_i,
  input  logic [AA-1:0]           cmd_base_i,
  input  logic [31:0]             cmd_addr_i,
  input  logic [AM_W-1:0]         cmd_xm_i,
  input  logic signed [E_W-1:0]   cmd_we_i,
  input  logic signed [E_W-1:0]   cmd_xe_i,
  input  logic signed [E_W-1:0]   cmd_fo_i,
  // read command (axi_rd_eng)
  output logic                    rd_cmd_valid_o,
  input  logic                    rd_cmd_ready_i,
  output logic [31:0]             rd_cmd_addr_o,
  output logic [31:0]             rd_cmd_bytes_o,
  // write command (axi_wr_eng, y)
  output logic                    wr_cmd_valid_o,
  input  logic                    wr_cmd_ready_i,
  output logic [31:0]             wr_cmd_addr_o,
  output logic [31:0]             wr_cmd_bytes_o,
  // LDW row record stream
  input  logic                    ld_valid_i,
  output logic                    ld_ready_o,
  input  logic [63:0]             ld_data_i,
  // global buffer
  output logic                    gb_sel_o,
  output logic                    gb_load_o,
  output logic [NW-1:0]           gb_n_o,
  input  logic                    gb_beat_i,
  input  logic                    gb_done_i,
  output logic                    gb_rd_en_o,
  output logic [GA-1:0]           gb_rd_addr_o,
  // bank write
  output logic [NB-1:0]           bw_en_o,
  output logic [AA-1:0]           bw_addr_o,
  output logic [W_WORD-1:0]       bw_data_o,
  // bank MAC read
  output logic [NB-1:0]           mr_en_o,
  output logic [AA-1:0]           mr_addr_o,
  output logic                    mr_first_o,
  output logic                    mr_last_o,
  // gather
  output logic                    g_valid_o,
  output logic [BI_W-1:0]         g_sel_o,
  output logic                    g_last_o,
  output logic [AM_W-1:0]         g_xm_o,
  output logic signed [SH_W-1:0]  g_sh_o,
  input  logic                    y_pop_i,
  // status and events
  output logic                    busy_o,
  output logic                    idle_o,
  output logic                    ev_mac_o,
  output logic                    ev_wrgb_o,
  output logic                    ev_rdmac_o,
  output logic                    done_ldw_o,
  output logic                    done_wrgb_o,
  output logic                    done_mac_o
);
  localparam logic [3:0] OP_LDW = 4'd1, OP_WRGB = 4'd2, OP_MACAB = 4'd3;
  localparam int NWW  = $clog2(NMAX / LB + 1);         // words of a row, 1 .. NMAX/LB
  localparam int NBT  = NMAX / 8;
  localparam int BTW  = $clog2(NBT + 1);               // beat index within a record 0 .. nb8
  localparam int RN_W = ROWS_W;                        // rounds / rows counters
  localparam int YC_W = $clog2(Y_DEPTH + NB + 1);
  localparam int SC_W = $clog2(NB + 1);
  localparam int LD   = L_BANK - 1;                    // gather delay line stages

  if (NB < 2 || NB > 16 || (NB & (NB - 1)) != 0) $error("pim_ctrl: NB=%0d must be a power of two in 2..16", NB);
  if (LB != 16) $error("pim_ctrl: LB=%0d must be 16 (one word = two 64-bit beats)", LB);
  if (NMAX < 32 || NMAX % 16 != 0 || NMAX > 4095) $error("pim_ctrl: NMAX=%0d must be a multiple of 16 in 32..4095", NMAX);
  if (DEPTH < 2 || DEPTH > 32768) $error("pim_ctrl: DEPTH=%0d must be 2..32768", DEPTH);
  if (Y_DEPTH < NB) $error("pim_ctrl: Y_DEPTH=%0d must be >= NB=%0d", Y_DEPTH, NB);
  if (L_BANK < 2) $error("pim_ctrl: L_BANK=%0d must be >= 2", L_BANK);
  if (ROWS_W < 1 || ROWS_W > 16) $error("pim_ctrl: ROWS_W=%0d must be 1..16", ROWS_W);

  typedef enum logic [2:0] {S_IDLE, S_LDATA, S_LFILL, S_XDATA, S_MAC} state_t;
  state_t state_q;

  // ---------------- command registers (datapath, loaded at the handshake) ----------------
  logic [ROWS_W-1:0]      rows_q;
  logic [NWW-1:0]         nw_q;        // ceil(n / LB)
  logic [BTW-1:0]         nb8_q;       // ceil(n / 8)
  logic [RN_W-1:0]        nrnd_q;      // ceil(rows / NB)
  logic [BI_W:0]          nvl_q;       // rows of the last round, 1..NB
  logic [7:0]             lmask_q;     // lanes kept in the last beat of a row
  logic [AM_W-1:0]        xm_q;
  logic signed [SH_W-1:0] sh_q;

  logic cmd_hs, op_ok;
  assign op_ok       = cmd_op_i == OP_LDW || cmd_op_i == OP_WRGB || cmd_op_i == OP_MACAB;
  assign cmd_ready_o = (state_q == S_IDLE) && !rd_cmd_valid_o &&
                       !(cmd_op_i == OP_MACAB && wr_cmd_valid_o);
  assign cmd_hs      = cmd_valid_i && cmd_ready_o;

  logic [ROWS_W:0] rows_p;
  assign rows_p = {1'b0, cmd_rows_i} + (ROWS_W + 1)'(NB - 1);

  always_ff @(posedge clk)
    if (cmd_hs) begin
      rows_q  <= cmd_rows_i;
      nw_q    <= NWW'((cmd_n_i + (LB - 1)) / LB);
      nb8_q   <= BTW'((cmd_n_i + 7) >> 3);
      nrnd_q  <= RN_W'(rows_p >> BI_W);
      nvl_q   <= (BI_W + 1)'(cmd_rows_i[BI_W-1:0] == '0 ? NB : cmd_rows_i[BI_W-1:0]);
      lmask_q <= (cmd_n_i[2:0] == 3'd0) ? 8'hFF : 8'((9'd1 << cmd_n_i[2:0]) - 1'b1);
      xm_q    <= cmd_xm_i;
      sh_q    <= SH_W'(cmd_we_i) + SH_W'(cmd_xe_i) - SH_W'(cmd_fo_i);
    end

  // ---------------- read and write commands ----------------
  logic        rdc_q, wrc_q;
  logic [31:0] rdc_addr_q, rdc_bytes_q, wrc_addr_q, wrc_bytes_q;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      rdc_q <= 1'b0;
      wrc_q <= 1'b0;
    end else begin
      if (cmd_hs && (cmd_op_i == OP_LDW || cmd_op_i == OP_WRGB)) rdc_q <= 1'b1;
      else if (rd_cmd_ready_i) rdc_q <= 1'b0;
      if (cmd_hs && cmd_op_i == OP_MACAB) wrc_q <= 1'b1;
      else if (wr_cmd_ready_i) wrc_q <= 1'b0;
    end

  always_ff @(posedge clk)
    if (cmd_hs) begin
      rdc_addr_q  <= cmd_addr_i;
      rdc_bytes_q <= (cmd_op_i == OP_LDW) ?
                     32'(cmd_rows_i) * (32'(((cmd_n_i + 7) >> 3) + 1) << 3) : 32'(cmd_n_i);
      if (cmd_op_i == OP_MACAB) begin
        wrc_addr_q  <= cmd_addr_i;
        wrc_bytes_q <= 32'(cmd_rows_i) << 2;
      end
    end

  assign rd_cmd_valid_o = rdc_q;
  assign rd_cmd_addr_o  = rdc_addr_q;
  assign rd_cmd_bytes_o = rdc_bytes_q;
  assign wr_cmd_valid_o = wrc_q;
  assign wr_cmd_addr_o  = wrc_addr_q;
  assign wr_cmd_bytes_o = wrc_bytes_q;

  // ---------------- LDW ----------------
  logic [ROWS_W-1:0] lrow_q;    // row of the record being received
  logic [BTW-1:0]    lbeat_q;   // beat within the record (0 = header)
  logic [AA-1:0]     rbase_q;   // bank word of word 0 of the current round
  logic [WM_W-1:0]   lwm_q;     // wm of the current row
  logic [63:0]       llo_q;     // low half of the word being assembled
  logic [BI_W-1:0]   fb_q;      // fill: bank
  logic [NWW-1:0]    fw_q;      // fill: word
  logic              ld_hs, l_lastbeat, l_lastrow, l_wr, l_hi;
  logic [NWW-1:0]    l_w;       // word index of the current beat
  logic [63:0]       l_dm;      // beat with lanes >= n of the row's last beat cleared

  assign ld_ready_o = (state_q == S_LDATA);
  assign ld_hs      = ld_valid_i && ld_ready_o;
  assign l_lastbeat = lbeat_q == nb8_q;
  assign l_lastrow  = lrow_q == rows_q - 1'b1;
  assign l_hi       = !lbeat_q[0];                   // beat j: half (j - 1) mod 2
  assign l_w        = NWW'((lbeat_q - 1'b1) >> 1);
  assign l_wr       = ld_hs && lbeat_q != '0 && (l_hi || l_lastbeat);
  always_comb
    for (int l = 0; l < 8; l++)
      l_dm[l*8 +: 8] = (l_lastbeat && !lmask_q[l]) ? 8'h00 : ld_data_i[l*8 +: 8];

  // ---------------- MACAB ----------------
  logic [RN_W-1:0]  rnd_q;     // round
  logic [NWW-1:0]   w_q;       // word within the round
  logic [AA-1:0]    abase_q;   // bank word of word 0 of the round
  logic [SC_W-1:0]  since_q;   // cycles since the last word of the last round (saturates at NB)
  logic [YC_W-1:0]  yres_q;    // y rows reserved and not yet popped
  logic             m_lastrnd, m_first, m_lastw, m_ok, m_issue;
  logic [BI_W:0]    m_nv;      // rows of this round
  logic [NB-1:0]    m_mask;

  assign m_lastrnd = rnd_q == nrnd_q - 1'b1;
  assign m_nv      = m_lastrnd ? nvl_q : (BI_W + 1)'(NB);
  assign m_first   = w_q == '0;
  assign m_lastw   = w_q == nw_q - 1'b1;
  assign m_ok      = !m_first ||
                     ((32'(since_q) + 32'(nw_q) - 32'd1 >= 32'(NB)) &&
                      (32'(yres_q) + 32'(m_nv) <= 32'(Y_DEPTH)));
  assign m_issue   = (state_q == S_MAC) && m_ok;
  always_comb
    for (int b = 0; b < NB; b++) m_mask[b] = (BI_W + 1)'(b) < m_nv;

  // ---------------- state ----------------
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      state_q <= S_IDLE;
      lrow_q  <= '0;
      lbeat_q <= '0;
      fb_q    <= '0;
      fw_q    <= '0;
      rnd_q   <= '0;
      w_q     <= '0;
      since_q <= SC_W'(NB);
      yres_q  <= '0;
    end else begin
      // since_q: cycles since the last word of a round was read
      if (m_issue && m_lastw) since_q <= SC_W'(1);
      else if (since_q != SC_W'(NB)) since_q <= since_q + 1'b1;
      yres_q <= yres_q + ((m_issue && m_first) ? YC_W'(m_nv) : YC_W'(0)) - YC_W'(y_pop_i);
      unique case (state_q)
        S_IDLE:
          if (cmd_hs)
            unique case (cmd_op_i)
              OP_LDW:   begin state_q <= S_LDATA; lrow_q <= '0; lbeat_q <= '0; end
              OP_WRGB:  state_q <= S_XDATA;
              OP_MACAB: begin state_q <= S_MAC; rnd_q <= '0; w_q <= '0; end
              default:  ;
            endcase
        S_LDATA:
          if (ld_hs) begin
            if (l_lastbeat) begin
              lbeat_q <= '0;
              lrow_q  <= lrow_q + 1'b1;
              if (l_lastrow) begin
                if (32'(rows_q[BI_W-1:0]) != 0) begin
                  state_q <= S_LFILL;
                  fb_q    <= BI_W'(rows_q[BI_W-1:0]);
                  fw_q    <= '0;
                end else state_q <= S_IDLE;
              end
            end else lbeat_q <= lbeat_q + 1'b1;
          end
        S_LFILL:
          if (fw_q == nw_q - 1'b1) begin
            fw_q <= '0;
            fb_q <= fb_q + 1'b1;
            if (fb_q == BI_W'(NB - 1)) state_q <= S_IDLE;
          end else fw_q <= fw_q + 1'b1;
        S_XDATA:
          if (gb_done_i) state_q <= S_IDLE;
        S_MAC:
          if (m_issue) begin
            if (m_lastw) begin
              w_q   <= '0;
              rnd_q <= rnd_q + 1'b1;
              if (m_lastrnd) state_q <= S_IDLE;
            end else w_q <= w_q + 1'b1;
          end
        default: state_q <= S_IDLE;
      endcase
    end

  // datapath registers of LDW and MACAB (no reset)
  always_ff @(posedge clk) begin
    if (cmd_hs) begin
      rbase_q <= cmd_base_i;
      abase_q <= cmd_base_i;
    end else begin
      if (ld_hs && l_lastbeat && lrow_q[BI_W-1:0] == BI_W'(NB - 1)) rbase_q <= rbase_q + AA'(nw_q);
      if (m_issue && m_lastw) abase_q <= abase_q + AA'(nw_q);
    end
    if (ld_hs && lbeat_q == '0) lwm_q <= ld_data_i[WM_W-1:0];
    if (ld_hs && lbeat_q != '0 && !l_hi) llo_q <= l_dm;
  end

  // ---------------- bank write port ----------------
  always_comb begin
    bw_en_o   = '0;
    bw_addr_o = '0;
    bw_data_o = '0;
    if (state_q == S_LFILL) begin
      bw_en_o[fb_q] = 1'b1;
      bw_addr_o     = rbase_q + AA'(fw_q);
    end else if (l_wr) begin
      bw_en_o[lrow_q[BI_W-1:0]] = 1'b1;
      bw_addr_o = rbase_q + AA'(l_w);
      bw_data_o = {(l_w == '0) ? lwm_q : WM_W'(0),
                   l_hi ? l_dm : 64'd0,
                   l_hi ? llo_q : l_dm};
    end
  end

  // ---------------- WRGB ----------------
  logic [1:0] xb_q;    // gb beat index mod 4
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) xb_q <= '0;
    else if (cmd_hs) xb_q <= '0;
    else if (gb_beat_i) xb_q <= xb_q + 1'b1;

  assign gb_sel_o  = (state_q == S_XDATA);
  assign gb_load_o = cmd_hs && cmd_op_i == OP_WRGB;
  assign gb_n_o    = cmd_n_i;

  // ---------------- MAC read port ----------------
  assign mr_en_o      = m_issue ? m_mask : '0;
  assign mr_addr_o    = abase_q + AA'(w_q);
  assign mr_first_o   = m_first;
  assign mr_last_o    = m_lastw;
  assign gb_rd_en_o   = m_issue;
  assign gb_rd_addr_o = GA'(w_q);

  // ---------------- gather ----------------
  // delay line: one entry per round, pushed with the round's last word, out after LD stages
  typedef struct packed {
    logic                   cl;     // last round of the command
    logic [BI_W:0]          nv;     // rows of the round
    logic [AM_W-1:0]        xm;
    logic signed [SH_W-1:0] sh;
  } gent_t;
  logic  dlv_q [LD];
  gent_t dld_q [LD];
  logic  dlv_in;
  gent_t dld_in;
  assign dlv_in = m_issue && m_lastw;
  assign dld_in = '{cl: m_lastrnd, nv: m_nv, xm: xm_q, sh: sh_q};

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) for (int i = 0; i < LD; i++) dlv_q[i] <= 1'b0;
    else begin
      dlv_q[0] <= dlv_in;
      for (int i = 1; i < LD; i++) dlv_q[i] <= dlv_q[i-1];
    end
  always_ff @(posedge clk) begin
    if (dlv_in) dld_q[0] <= dld_in;
    for (int i = 1; i < LD; i++)
      if (dlv_q[i-1]) dld_q[i] <= dld_q[i-1];
  end

  logic                   ga_q;
  gent_t                  gd_q;
  logic [BI_W-1:0]        gcnt_q;
  logic                   g_end;
  assign g_end = ga_q && (BI_W + 1)'(gcnt_q) == gd_q.nv - 1'b1;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      ga_q   <= 1'b0;
      gcnt_q <= '0;
    end else if (dlv_q[LD-1]) begin
      ga_q   <= 1'b1;
      gcnt_q <= '0;
    end else if (ga_q) begin
      gcnt_q <= gcnt_q + 1'b1;
      if (g_end) ga_q <= 1'b0;
    end
  always_ff @(posedge clk)
    if (dlv_q[LD-1]) gd_q <= dld_q[LD-1];

  assign g_valid_o = ga_q;
  assign g_sel_o   = gcnt_q;
  assign g_last_o  = gd_q.cl && g_end;
  assign g_xm_o    = gd_q.xm;
  assign g_sh_o    = gd_q.sh;

  // ---------------- status and events ----------------
  assign busy_o      = state_q != S_IDLE;
  assign idle_o      = state_q == S_IDLE && yres_q == '0 && !wrc_q;
  assign ev_mac_o    = m_issue;
  assign ev_wrgb_o   = gb_beat_i && gb_sel_o && xb_q == 2'd0;
  assign ev_rdmac_o  = ga_q;
  assign done_ldw_o  = (state_q == S_LDATA && ld_hs && l_lastbeat && l_lastrow && rows_q[BI_W-1:0] == '0) ||
                       (state_q == S_LFILL && fw_q == nw_q - 1'b1 && fb_q == BI_W'(NB - 1));
  assign done_wrgb_o = (state_q == S_XDATA) && gb_done_i;
  assign done_mac_o  = m_issue && m_lastw && m_lastrnd;

`ifndef SYNTHESIS
  always @(posedge clk)
    if (rst_n === 1'b1) begin
      if (cmd_hs === 1'b1) begin
        automatic int n = int'(cmd_n_i), r = int'(cmd_rows_i);
        automatic int used = ((r + NB - 1) / NB) * ((n + LB - 1) / LB);
        if (!op_ok)
          $error("PIM_RANGE pim_ctrl %m: op %0d (dropped)", cmd_op_i);
        else if (n < 1 || n > NMAX ||
                 (cmd_op_i != OP_WRGB && (r < 1 || int'(cmd_base_i) + used > DEPTH)))
          $error("PIM_RANGE pim_ctrl %m: op %0d rows %0d n %0d base %0d (NMAX %0d DEPTH %0d)",
                 cmd_op_i, r, n, cmd_base_i, NMAX, DEPTH);
      end
      if (dlv_q[LD-1] === 1'b1 && ga_q === 1'b1 && !g_end)
        $error("PIM_GATHER pim_ctrl %m: round results arrive while the gather of the previous round runs");
      if (32'(yres_q) > Y_DEPTH) $error("PIM_YOVF pim_ctrl %m: %0d y reserved > Y_DEPTH %0d", yres_q, Y_DEPTH);
    end
`endif

endmodule
