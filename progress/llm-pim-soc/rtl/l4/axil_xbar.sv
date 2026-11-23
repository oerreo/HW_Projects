// axil_xbar: AXI4-Lite crossbar, one master port -> N slave ports (L4 in llm-pim-soc,
// docs/spec/system.md 1.4 and 1.7, decision O4 / O6 of system.md 10).
//
// Address map: the master address is split into fixed 4 KiB slots,
//   slot   = addr[12 +: SLOT_W]            (SLOT_W 4: addr[15:12], slots 0..15)
//   offset = addr[11:0]                    (passed to the slave port, slave ADDR_W 12)
//   above  = addr[S_ADDR_W-1 : 12+SLOT_W]  (must be 0, otherwise "out of range")
// A slot k is "present" if k < N and SLOT_EN[k] = 1. An access to an absent slot or out of range
// reaches no slave: a read returns 0 with OKAY, a write is ignored with OKAY (system.md 1.4: the
// SW reads the ID register of every slot to find the build; a DECERR would abort the ARM).
// The slave response (BRESP / RRESP, RDATA) of a present slot is passed unchanged.
//
// Transactions: the write path (AW, W, B) and the read path (AR, R) are independent. Each path has
// at most one transaction outstanding: the next AW / W (AR) is accepted only after the B (R)
// handshake of the previous one on the master side. AW and W may arrive in any order and with
// any delay between them; WSTRB and AxPROT are passed unchanged.
//
// REG (register slice) parameter:
//   REG = 1 (default): no combinational path between the master port and the slave ports in
//     either direction. Every output is a flip-flop (or a constant): AWREADY / WREADY / ARREADY
//     come from the transaction state, the slave AWVALID / WVALID / ARVALID, the slave address /
//     data and the slave BREADY / RREADY are registered, the master BVALID / BRESP / RVALID /
//     RDATA / RRESP are registered copies of the slave response.
//     Latency (localparam LAT_REQ = 1, LAT_RSP = 1):
//       slave AWVALID in a + 1 (a = master AW handshake cycle),
//       slave WVALID  in max(a, w) + 1 (w = master W handshake cycle; W waits for the slot),
//       slave ARVALID in r + 1 (r = master AR handshake cycle),
//       master BVALID in b + 1 (b = slave B handshake cycle; slave BREADY is 1 from the AW issue),
//       master RVALID in d + 1 (d = slave R handshake cycle; slave RREADY is 1 from the AR issue),
//       absent slot / out of range: master BVALID in max(a, w) + 1, RVALID in r + 1.
//   REG = 0: combinational pass-through (LAT_REQ = 0, LAT_RSP = 0). The slave AWVALID / ARVALID
//     follow the master VALID in the same cycle (decoded from the master address), the master
//     AWREADY / ARREADY follow the selected slave READY; W is passed only after the AW handshake
//     (master W handshake >= a + 1, in the cycle of the slave W handshake); B and R pass through
//     in the cycle of the master handshake. Absent slot: BVALID in w + 1, RVALID in r + 1.
//     Combinational paths: master AxVALID / AxADDR / WVALID -> slave valid, slave READY -> master
//     READY, slave BVALID / RVALID / data -> master, master BREADY / RREADY -> slave.
//
// Reset: transaction state, slave-side valid / ready registers and the master-side response
// valid are reset; addresses, data, PROT, WSTRB and the slot index are datapath registers
// loaded at a handshake (design-methodology.md), only used while the matching state is set.
//
// Parameters: N 1..2^SLOT_W slave ports, SLOT_W 1..4, S_ADDR_W 12 + SLOT_W .. 32, SLOT_EN
// (bit k: slot k present; bits >= N must be 0), REG 0 or 1. Illegal values fail elaboration.
module axil_xbar #(
  parameter int          N        = 4,
  parameter int          SLOT_W   = 4,
  parameter int          S_ADDR_W = 16,
  parameter logic [15:0] SLOT_EN  = 16'hFFFF >> (16 - N),
  parameter int          REG      = 1
) (
  input  logic                  clk,
  input  logic                  rst_n,          // async assert, sync deassert
  // AXI4-Lite slave port (from the master, e.g. Zynq M_AXI_GP0)
  input  logic [S_ADDR_W-1:0]   s_axi_awaddr_i,
  input  logic [2:0]            s_axi_awprot_i,
  input  logic                  s_axi_awvalid_i,
  output logic                  s_axi_awready_o,
  input  logic [31:0]           s_axi_wdata_i,
  input  logic [3:0]            s_axi_wstrb_i,
  input  logic                  s_axi_wvalid_i,
  output logic                  s_axi_wready_o,
  output logic [1:0]            s_axi_bresp_o,
  output logic                  s_axi_bvalid_o,
  input  logic                  s_axi_bready_i,
  input  logic [S_ADDR_W-1:0]   s_axi_araddr_i,
  input  logic [2:0]            s_axi_arprot_i,
  input  logic                  s_axi_arvalid_i,
  output logic                  s_axi_arready_o,
  output logic [31:0]           s_axi_rdata_o,
  output logic [1:0]            s_axi_rresp_o,
  output logic                  s_axi_rvalid_o,
  input  logic                  s_axi_rready_i,
  // AXI4-Lite master ports, index = slot (to the IP CSR ports, address = slot offset)
  output logic [N-1:0][11:0]    m_axi_awaddr_o,
  output logic [N-1:0][2:0]     m_axi_awprot_o,
  output logic [N-1:0]          m_axi_awvalid_o,
  input  logic [N-1:0]          m_axi_awready_i,
  output logic [N-1:0][31:0]    m_axi_wdata_o,
  output logic [N-1:0][3:0]     m_axi_wstrb_o,
  output logic [N-1:0]          m_axi_wvalid_o,
  input  logic [N-1:0]          m_axi_wready_i,
  input  wire  [N-1:0][1:0]     m_axi_bresp_i,
  input  logic [N-1:0]          m_axi_bvalid_i,
  output logic [N-1:0]          m_axi_bready_o,
  output logic [N-1:0][11:0]    m_axi_araddr_o,
  output logic [N-1:0][2:0]     m_axi_arprot_o,
  output logic [N-1:0]          m_axi_arvalid_o,
  input  logic [N-1:0]          m_axi_arready_i,
  input  wire  [N-1:0][31:0]    m_axi_rdata_i,
  input  wire  [N-1:0][1:0]     m_axi_rresp_i,
  input  logic [N-1:0]          m_axi_rvalid_i,
  output logic [N-1:0]          m_axi_rready_o
);

  // ---------------- parameter checks (elaboration) ----------------
  if (SLOT_W < 1 || SLOT_W > 4) begin : g_bad_slot_w
    $error("axil_xbar: SLOT_W=%0d not supported (1..4)", SLOT_W);
  end
  if (N < 1 || N > (1 << SLOT_W)) begin : g_bad_n
    $error("axil_xbar: N=%0d must be 1..2^SLOT_W", N);
  end
  if (S_ADDR_W < 12 + SLOT_W || S_ADDR_W > 32) begin : g_bad_addr_w
    $error("axil_xbar: S_ADDR_W=%0d must be 12+SLOT_W..32", S_ADDR_W);
  end
  if (REG != 0 && REG != 1) begin : g_bad_reg
    $error("axil_xbar: REG=%0d must be 0 or 1", REG);
  end
  if (N >= 1 && N < 16 && (SLOT_EN >> N) != 16'd0) begin : g_bad_en
    $error("axil_xbar: SLOT_EN=0x%0h has bits at or above N=%0d", SLOT_EN, N);
  end

  // latency of the request (master handshake -> slave VALID) and of the response (slave
  // handshake -> master VALID) in cycles, see the header
  localparam int LAT_REQ = REG;
  localparam int LAT_RSP = REG;

  localparam int IW = SLOT_W;
  localparam logic [1:0] OKAY = 2'b00;

  // slot decode: present (hit) and index
  function automatic logic dec_hit(logic [S_ADDR_W-1:0] a);
    logic hit;
    logic [IW-1:0] k;
    k   = a[12 +: IW];
    hit = 1'b0;
    for (int i = 0; i < N; i++)
      if (k == IW'(i) && SLOT_EN[i]) hit = 1'b1;
    if (S_ADDR_W > 12 + IW)
      for (int b = 12 + IW; b < S_ADDR_W; b++)
        if (a[b]) hit = 1'b0;
    return hit;
  endfunction

  function automatic logic [IW-1:0] dec_idx(logic [S_ADDR_W-1:0] a);
    return a[12 +: IW];
  endfunction

  // one-hot select of index k among N ports
  function automatic logic [N-1:0] onehot(logic [IW-1:0] k);
    logic [N-1:0] v;
    for (int i = 0; i < N; i++) v[i] = (k == IW'(i));
    return v;
  endfunction

  // AND-OR multiplexers with a one-hot (or zero) select
  function automatic logic [31:0] mux32(logic [N-1:0] sel, logic [N-1:0][31:0] d);
    logic [31:0] v;
    v = '0;
    for (int i = 0; i < N; i++) if (sel[i]) v = v | d[i];
    return v;
  endfunction
  function automatic logic [1:0] mux2(logic [N-1:0] sel, logic [N-1:0][1:0] d);
    logic [1:0] v;
    v = '0;
    for (int i = 0; i < N; i++) if (sel[i]) v = v | d[i];
    return v;
  endfunction

  if (REG == 1) begin : g_reg
    // ======================= registered (REG = 1) =======================
    // ---- write path ----
    logic             aw_acc_q, w_acc_q, w_iss_q, aw_hit_q, bvalid_q;
    logic [IW-1:0]    wsel_q;
    logic [11:0]      awaddr_q;
    logic [2:0]       awprot_q;
    logic [31:0]      wdata_q;
    logic [3:0]       wstrb_q;
    logic [1:0]       bresp_q;
    logic [N-1:0]     m_awvalid_q, m_wvalid_q, m_bready_q;
    logic             aw_hs, w_hs, b_hs, w_issue, aw_hit_now, w_hit_now;
    logic [IW-1:0]    w_sel_now;
    logic [N-1:0]     b_take;

    assign s_axi_awready_o = !aw_acc_q;
    assign s_axi_wready_o  = !w_acc_q;
    assign aw_hs   = s_axi_awvalid_i && !aw_acc_q;
    assign w_hs    = s_axi_wvalid_i && !w_acc_q;
    assign b_hs    = bvalid_q && s_axi_bready_i;
    assign aw_hit_now = dec_hit(s_axi_awaddr_i);
    // W is issued when its data is (being) captured and the slot is known
    assign w_issue   = !w_iss_q && (w_acc_q || w_hs) && (aw_acc_q || aw_hs);
    assign w_sel_now = aw_acc_q ? wsel_q : dec_idx(s_axi_awaddr_i);
    assign w_hit_now = aw_acc_q ? aw_hit_q : aw_hit_now;
    assign b_take    = m_bready_q & m_axi_bvalid_i;

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        aw_acc_q    <= 1'b0;
        w_acc_q     <= 1'b0;
        w_iss_q     <= 1'b0;
        bvalid_q    <= 1'b0;
        m_awvalid_q <= '0;
        m_wvalid_q  <= '0;
        m_bready_q  <= '0;
      end else begin
        m_awvalid_q <= m_awvalid_q & ~m_axi_awready_i;
        m_wvalid_q  <= m_wvalid_q & ~m_axi_wready_i;
        if (aw_hs) begin
          aw_acc_q <= 1'b1;
          if (aw_hit_now) begin
            m_awvalid_q <= onehot(dec_idx(s_axi_awaddr_i));
            m_bready_q  <= onehot(dec_idx(s_axi_awaddr_i));
          end
        end
        if (w_hs) w_acc_q <= 1'b1;
        if (w_issue) begin
          w_iss_q <= 1'b1;
          if (w_hit_now) m_wvalid_q <= onehot(w_sel_now);
          else           bvalid_q   <= 1'b1;            // absent slot: OKAY, write ignored
        end
        if (b_take != '0) begin
          m_bready_q <= '0;
          bvalid_q   <= 1'b1;
        end
        if (b_hs) begin
          bvalid_q <= 1'b0;
          aw_acc_q <= 1'b0;
          w_acc_q  <= 1'b0;
          w_iss_q  <= 1'b0;
        end
      end
    end

    always_ff @(posedge clk) begin
      if (aw_hs) begin
        awaddr_q <= s_axi_awaddr_i[11:0];
        awprot_q <= s_axi_awprot_i;
        wsel_q   <= dec_idx(s_axi_awaddr_i);
        aw_hit_q <= aw_hit_now;
      end
      if (w_hs) begin
        wdata_q <= s_axi_wdata_i;
        wstrb_q <= s_axi_wstrb_i;
      end
      if (w_issue && !w_hit_now) bresp_q <= OKAY;
      else if (b_take != '0)     bresp_q <= mux2(m_bready_q, m_axi_bresp_i);
    end

    assign s_axi_bvalid_o = bvalid_q;
    assign s_axi_bresp_o  = bresp_q;
    for (genvar k = 0; k < N; k++) begin : g_wport
      assign m_axi_awaddr_o[k]  = awaddr_q;
      assign m_axi_awprot_o[k]  = awprot_q;
      assign m_axi_awvalid_o[k] = m_awvalid_q[k];
      assign m_axi_wdata_o[k]   = wdata_q;
      assign m_axi_wstrb_o[k]   = wstrb_q;
      assign m_axi_wvalid_o[k]  = m_wvalid_q[k];
      assign m_axi_bready_o[k]  = m_bready_q[k];
    end

    // ---- read path ----
    logic             ar_acc_q, rvalid_q, ar_hit_now;
    logic [IW-1:0]    rsel_q;
    logic [11:0]      araddr_q;
    logic [2:0]       arprot_q;
    logic [31:0]      rdata_q;
    logic [1:0]       rresp_q;
    logic [N-1:0]     m_arvalid_q, m_rready_q, r_take;
    logic             ar_hs, r_hs;

    assign s_axi_arready_o = !ar_acc_q;
    assign ar_hs      = s_axi_arvalid_i && !ar_acc_q;
    assign r_hs       = rvalid_q && s_axi_rready_i;
    assign ar_hit_now = dec_hit(s_axi_araddr_i);
    assign r_take     = m_rready_q & m_axi_rvalid_i;

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        ar_acc_q    <= 1'b0;
        rvalid_q    <= 1'b0;
        m_arvalid_q <= '0;
        m_rready_q  <= '0;
      end else begin
        m_arvalid_q <= m_arvalid_q & ~m_axi_arready_i;
        if (ar_hs) begin
          ar_acc_q <= 1'b1;
          if (ar_hit_now) begin
            m_arvalid_q <= onehot(dec_idx(s_axi_araddr_i));
            m_rready_q  <= onehot(dec_idx(s_axi_araddr_i));
          end else rvalid_q <= 1'b1;                   // absent slot: 0, OKAY
        end
        if (r_take != '0) begin
          m_rready_q <= '0;
          rvalid_q   <= 1'b1;
        end
        if (r_hs) begin
          rvalid_q <= 1'b0;
          ar_acc_q <= 1'b0;
        end
      end
    end

    always_ff @(posedge clk) begin
      if (ar_hs) begin
        araddr_q <= s_axi_araddr_i[11:0];
        arprot_q <= s_axi_arprot_i;
        rsel_q   <= dec_idx(s_axi_araddr_i);
      end
      if (ar_hs && !ar_hit_now) begin
        rdata_q <= '0;
        rresp_q <= OKAY;
      end else if (r_take != '0) begin
        rdata_q <= mux32(m_rready_q, m_axi_rdata_i);
        rresp_q <= mux2(m_rready_q, m_axi_rresp_i);
      end
    end

    assign s_axi_rvalid_o = rvalid_q;
    assign s_axi_rdata_o  = rdata_q;
    assign s_axi_rresp_o  = rresp_q;
    for (genvar k = 0; k < N; k++) begin : g_rport
      assign m_axi_araddr_o[k]  = araddr_q;
      assign m_axi_arprot_o[k]  = arprot_q;
      assign m_axi_arvalid_o[k] = m_arvalid_q[k];
      assign m_axi_rready_o[k]  = m_rready_q[k];
    end

  end else begin : g_comb
    // ======================= pass-through (REG = 0) =======================
    // ---- write path ----
    logic             aw_acc_q, w_acc_q, aw_hit_q;
    logic [IW-1:0]    wsel_q;
    logic             aw_hit, aw_hs, w_hs, b_hs, bvalid;
    logic [IW-1:0]    aw_idx;
    logic [N-1:0]     aw_sel, w_sel;

    assign aw_hit = dec_hit(s_axi_awaddr_i);
    assign aw_idx = dec_idx(s_axi_awaddr_i);
    assign aw_sel = aw_hit ? onehot(aw_idx) : '0;
    assign w_sel  = aw_hit_q ? onehot(wsel_q) : '0;
    assign s_axi_awready_o = !aw_acc_q && (!aw_hit || (aw_sel & m_axi_awready_i) != '0);
    assign s_axi_wready_o  = aw_acc_q && !w_acc_q && (!aw_hit_q || (w_sel & m_axi_wready_i) != '0);
    assign aw_hs  = s_axi_awvalid_i && s_axi_awready_o;
    assign w_hs   = s_axi_wvalid_i && s_axi_wready_o;
    assign bvalid = aw_acc_q && w_acc_q && (!aw_hit_q || (w_sel & m_axi_bvalid_i) != '0);
    assign b_hs   = bvalid && s_axi_bready_i;

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        aw_acc_q <= 1'b0;
        w_acc_q  <= 1'b0;
      end else begin
        if (aw_hs) aw_acc_q <= 1'b1;
        if (w_hs)  w_acc_q  <= 1'b1;
        if (b_hs) begin
          aw_acc_q <= 1'b0;
          w_acc_q  <= 1'b0;
        end
      end
    end
    always_ff @(posedge clk) begin
      if (aw_hs) begin
        wsel_q   <= aw_idx;
        aw_hit_q <= aw_hit;
      end
    end

    assign s_axi_bvalid_o = bvalid;
    assign s_axi_bresp_o  = mux2(w_sel, m_axi_bresp_i);           // 0 (OKAY) for an absent slot
    for (genvar k = 0; k < N; k++) begin : g_wport
      assign m_axi_awaddr_o[k]  = s_axi_awaddr_i[11:0];
      assign m_axi_awprot_o[k]  = s_axi_awprot_i;
      assign m_axi_awvalid_o[k] = s_axi_awvalid_i && !aw_acc_q && aw_sel[k];
      assign m_axi_wdata_o[k]   = s_axi_wdata_i;
      assign m_axi_wstrb_o[k]   = s_axi_wstrb_i;
      assign m_axi_wvalid_o[k]  = s_axi_wvalid_i && aw_acc_q && !w_acc_q && w_sel[k];
      assign m_axi_bready_o[k]  = s_axi_bready_i && aw_acc_q && w_acc_q && w_sel[k];
    end

    // ---- read path ----
    logic             ar_acc_q, ar_hit_q;
    logic [IW-1:0]    rsel_q;
    logic             ar_hit, ar_hs, rvalid, r_hs;
    logic [IW-1:0]    ar_idx;
    logic [N-1:0]     ar_sel, r_sel;

    assign ar_hit = dec_hit(s_axi_araddr_i);
    assign ar_idx = dec_idx(s_axi_araddr_i);
    assign ar_sel = ar_hit ? onehot(ar_idx) : '0;
    assign r_sel  = ar_hit_q ? onehot(rsel_q) : '0;
    assign s_axi_arready_o = !ar_acc_q && (!ar_hit || (ar_sel & m_axi_arready_i) != '0);
    assign ar_hs  = s_axi_arvalid_i && s_axi_arready_o;
    assign rvalid = ar_acc_q && (!ar_hit_q || (r_sel & m_axi_rvalid_i) != '0);
    assign r_hs   = rvalid && s_axi_rready_i;

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) ar_acc_q <= 1'b0;
      else if (ar_hs) ar_acc_q <= 1'b1;
      else if (r_hs)  ar_acc_q <= 1'b0;
    end
    always_ff @(posedge clk) begin
      if (ar_hs) begin
        rsel_q   <= ar_idx;
        ar_hit_q <= ar_hit;
      end
    end

    assign s_axi_rvalid_o = rvalid;
    assign s_axi_rdata_o  = mux32(r_sel, m_axi_rdata_i);          // 0 for an absent slot
    assign s_axi_rresp_o  = mux2(r_sel, m_axi_rresp_i);           // OKAY for an absent slot
    for (genvar k = 0; k < N; k++) begin : g_rport
      assign m_axi_araddr_o[k]  = s_axi_araddr_i[11:0];
      assign m_axi_arprot_o[k]  = s_axi_arprot_i;
      assign m_axi_arvalid_o[k] = s_axi_arvalid_i && !ar_acc_q && ar_sel[k];
      assign m_axi_rready_o[k]  = s_axi_rready_i && ar_acc_q && r_sel[k];
    end
  end

  // --------------------------------------------------------------------------
  // Simulation-only protocol checks (tags for sim/run.sh assert:<TAG>=<n>):
  //   L4_XB_AW / L4_XB_W / L4_XB_AR  master VALID or payload changed before READY
  //   L4_XB_B / L4_XB_R              slave BVALID / RVALID or response changed before READY
  //   L4_XB_UNEXP                    slave B / R response at a port without a request
  // --------------------------------------------------------------------------
`ifndef SYNTHESIS
  logic                p_awv, p_wv, p_arv;
  logic [S_ADDR_W-1:0] p_awa, p_ara;
  logic [31:0]         p_wd;
  logic [N-1:0]        p_bv, p_rv;
  logic [N-1:0][1:0]   p_br, p_rr;
  logic [N-1:0][31:0]  p_rd;
  logic [N-1:0]        exp_b, exp_r;   // slave port k owes a B / R response
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p_awv <= 1'b0;
      p_wv  <= 1'b0;
      p_arv <= 1'b0;
      p_bv  <= '0;
      p_rv  <= '0;
      exp_b <= '0;
      exp_r <= '0;
    end else begin
      p_awv <= s_axi_awvalid_i && !s_axi_awready_o;
      p_wv  <= s_axi_wvalid_i && !s_axi_wready_o;
      p_arv <= s_axi_arvalid_i && !s_axi_arready_o;
      p_awa <= s_axi_awaddr_i;
      p_wd  <= s_axi_wdata_i;
      p_ara <= s_axi_araddr_i;
      p_bv  <= m_axi_bvalid_i & ~m_axi_bready_o;
      p_rv  <= m_axi_rvalid_i & ~m_axi_rready_o;
      p_br  <= m_axi_bresp_i;
      p_rr  <= m_axi_rresp_i;
      p_rd  <= m_axi_rdata_i;
      exp_b <= (exp_b | (m_axi_awvalid_o & m_axi_awready_i)) & ~(m_axi_bvalid_i & m_axi_bready_o);
      exp_r <= (exp_r | (m_axi_arvalid_o & m_axi_arready_i)) & ~(m_axi_rvalid_i & m_axi_rready_o);
    end
  end
  always_ff @(posedge clk) begin
    if (rst_n === 1'b1) begin
      if (p_awv) xb_aw_hold : assert (s_axi_awvalid_i === 1'b1 && s_axi_awaddr_i === p_awa)
        else $error("L4_XB_AW axil_xbar: AWVALID / AWADDR changed before AWREADY");
      if (p_wv) xb_w_hold : assert (s_axi_wvalid_i === 1'b1 && s_axi_wdata_i === p_wd)
        else $error("L4_XB_W axil_xbar: WVALID / WDATA changed before WREADY");
      if (p_arv) xb_ar_hold : assert (s_axi_arvalid_i === 1'b1 && s_axi_araddr_i === p_ara)
        else $error("L4_XB_AR axil_xbar: ARVALID / ARADDR changed before ARREADY");
      for (int k = 0; k < N; k++) begin
        if (p_bv[k] && !(m_axi_bvalid_i[k] === 1'b1 && m_axi_bresp_i[k] === p_br[k]))
          $error("L4_XB_B axil_xbar: slave %0d BVALID / BRESP changed before BREADY", k);
        if (p_rv[k] && !(m_axi_rvalid_i[k] === 1'b1 && m_axi_rresp_i[k] === p_rr[k] &&
                         m_axi_rdata_i[k] === p_rd[k]))
          $error("L4_XB_R axil_xbar: slave %0d RVALID / RDATA / RRESP changed before RREADY", k);
        if (m_axi_bvalid_i[k] === 1'b1 && !p_bv[k] && !exp_b[k])
          $error("L4_XB_UNEXP axil_xbar: slave %0d BVALID without a write", k);
        if (m_axi_rvalid_i[k] === 1'b1 && !p_rv[k] && !exp_r[k])
          $error("L4_XB_UNEXP axil_xbar: slave %0d RVALID without a read", k);
      end
    end
  end
`endif

endmodule
