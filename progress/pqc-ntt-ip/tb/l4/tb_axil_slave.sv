// tb_axil_slave: self-checking testbench of axil_slave alone (L4).
//
// Spec: docs/spec/l4_axi.md ("decided behaviour", "L4 implementation
// results"), the channel behaviour in the rtl/l4/axil_slave.sv header.
//
// Register side: a simple memory model in this TB. Every performed write
// (wr_en_o) is stored; the read data offered in a read cycle (rd_en_o = 1) is
// fval(rd_addr_o, rd_cnt), rd_cnt = number of reads performed so far, so a
// read performed twice (or too early / late) shows up as wrong data. Outside
// rd_en_o the read data input carries random junk that changes every cycle.
//
// AXI master (random phase): N_WR write and N_RD read transactions, issued on
// independent AW / W / AR channels with random gaps. Per write transaction one
// of four orders: AW first (W waits for the AW handshake), W first (AW waits
// for the W handshake), same (both offered with no gap), free (independent
// gaps). BREADY / RREADY random, payloads random junk while VALID = 0, WSTRB
// random (ignored by the DUT), AWPROT / ARPROT random. A stimulus profile
// (gap length, ready probability) changes every PROF_LEN cycles. Random
// resets (1..4 cycles) are inserted while transactions are in flight; the
// master drops every VALID during reset and restarts with new transactions.
//
// Checkers:
//   cyc     cycle reference model of the documented channel behaviour (buffer
//           full flags, BVALID / RVALID hold until handshake, perform rule),
//           compared every cycle: AWREADY, WREADY, ARREADY, BVALID, RVALID,
//           wr_en_o, rd_en_o; BRESP / RRESP = OKAY while VALID
//   wr      scoreboard: every performed write matches the oldest captured
//           AW / W pair (address, full data), in request order, exactly once
//   rd      scoreboard: every performed read matches the oldest captured AR
//           address, exactly once; RDATA (every RVALID cycle) = fval of that
//           request with its request index
//   resp    exactly one B per performed write, exactly one R per performed
//           read, no response without a request; all queues empty at the end
//   lat     latency rule per transaction (no response pending: handshake c,
//           register access c+1, VALID c+2): write performed at
//           max(t_aw, t_w, t_last_b_handshake) + 1, BVALID rises one cycle
//           after the write; reads likewise with AR / R
//   dir     directed: latency c, c+1, c+2 for the three AW / W orders and for
//           reads; throughput 1 transaction per 3 cycles with a master that
//           waits for each response (writes, reads, both at once); a master
//           that keeps VALID high (pipelined) is measured and reported
//   mem     final compare of the memory model with the expected contents
//   cover   every listed coverage counter must be non-zero
//
// Plusargs: +SEED=<n> (1) +N_WR=<n> (60000) +N_RD=<n> (60000)
//           +RST_PERMIL=<n> resets per 1000 cycles x 10 (default 3, i.e. 0.3/1000)
//           +PROF_LEN=<n> (2000)
`timescale 1ns / 1ps

module tb_axil_slave;
  import tb_util_pkg::*;

  parameter int ADDR_W = 12;
  parameter int DATA_W = 32;

  localparam time    T_CLK = 10ns;
  localparam int     SW    = DATA_W / 8;
  localparam longint NEVER = -64'sd1000000;

  logic              clk = 1'b0;
  logic              rst_n = 1'b0;
  logic [ADDR_W-1:0] awaddr = '0;
  logic [2:0]        awprot = '0;
  logic              awvalid = 1'b0;
  logic              awready;
  logic [DATA_W-1:0] wdata = '0;
  logic [SW-1:0]     wstrb = '0;
  logic              wvalid = 1'b0;
  logic              wready;
  logic [1:0]        bresp;
  logic              bvalid;
  logic              bready = 1'b0;
  logic [ADDR_W-1:0] araddr = '0;
  logic [2:0]        arprot = '0;
  logic              arvalid = 1'b0;
  logic              arready;
  logic [DATA_W-1:0] rdata;
  logic [1:0]        rresp;
  logic              rvalid;
  logic              rready = 1'b0;
  logic              wr_en, rd_en;
  logic [ADDR_W-1:0] wr_addr, rd_addr;
  logic [DATA_W-1:0] wr_data, rd_data;

  axil_slave #(.ADDR_W(ADDR_W), .DATA_W(DATA_W)) dut (
    .clk             (clk),
    .rst_n           (rst_n),
    .s_axi_awaddr_i  (awaddr),
    .s_axi_awprot_i  (awprot),
    .s_axi_awvalid_i (awvalid),
    .s_axi_awready_o (awready),
    .s_axi_wdata_i   (wdata),
    .s_axi_wstrb_i   (wstrb),
    .s_axi_wvalid_i  (wvalid),
    .s_axi_wready_o  (wready),
    .s_axi_bresp_o   (bresp),
    .s_axi_bvalid_o  (bvalid),
    .s_axi_bready_i  (bready),
    .s_axi_araddr_i  (araddr),
    .s_axi_arprot_i  (arprot),
    .s_axi_arvalid_i (arvalid),
    .s_axi_arready_o (arready),
    .s_axi_rdata_o   (rdata),
    .s_axi_rresp_o   (rresp),
    .s_axi_rvalid_o  (rvalid),
    .s_axi_rready_i  (rready),
    .wr_en_o         (wr_en),
    .wr_addr_o       (wr_addr),
    .wr_data_o       (wr_data),
    .rd_en_o         (rd_en),
    .rd_addr_o       (rd_addr),
    .rd_data_i       (rd_data)
  );

  always #(T_CLK / 2) clk = ~clk;

  // --------------------------------------------------------------------------
  // Register-side memory model
  // --------------------------------------------------------------------------
  longint unsigned   rd_cnt = 0;          // reads performed (never reset)
  logic [DATA_W-1:0] junk = '0;
  logic [DATA_W-1:0] mem [logic [ADDR_W-1:0]];      // written by the DUT strobes
  logic [DATA_W-1:0] exp_mem [logic [ADDR_W-1:0]];  // written by the scoreboard

  function automatic logic [DATA_W-1:0] fval(logic [ADDR_W-1:0] a, longint unsigned k);
    logic [63:0] x;
    x = (64'(a) * 64'h9E37_79B9_7F4A_7C15) ^ (64'(k) * 64'hC2B2_AE3D_27D4_EB4F) ^ 64'h5A5A_1234;
    x = x ^ (x >> 29);
    return DATA_W'(x);
  endfunction

  assign rd_data = (rd_en === 1'b1) ? fval(rd_addr, rd_cnt) : junk;

  always @(posedge clk) begin
    junk <= DATA_W'({$urandom, $urandom});
    if (rd_en === 1'b1) rd_cnt <= rd_cnt + 1;
    // blocking: the key and data are DUT outputs that change only after this edge
    if (wr_en === 1'b1) mem[wr_addr] = wr_data;
  end

  // --------------------------------------------------------------------------
  // Checkers, coverage
  // --------------------------------------------------------------------------
  tb_checker chk_cyc  = new("cyc");
  tb_checker chk_wr   = new("wr");
  tb_checker chk_rd   = new("rd");
  tb_checker chk_resp = new("resp");
  tb_checker chk_lat  = new("lat");
  tb_checker chk_dir  = new("dir");
  tb_checker chk_mem  = new("mem");
  tb_checker chk_cov  = new("cover");

  longint cov [string];
  string  cov_names [$] = '{"aw_before_w", "w_before_aw", "aw_w_same_cycle", "b_stall", "r_stall",
                            "wr_rd_same_cycle", "aw_hs_while_bvalid", "w_hs_while_bvalid",
                            "ar_hs_while_rvalid", "wr_blocked_by_b", "rd_blocked_by_r",
                            "aw_hs_ar_hs_same_cycle", "b_hs_r_hs_same_cycle", "rst",
                            "rst_inflight_w", "rst_inflight_r", "wstrb_partial",
                            "aw_b2b", "ar_b2b", "w_lat_min", "r_lat_min"};

  function automatic void cv(string n);
    if (cov.exists(n)) cov[n]++; else cov[n] = 1;
  endfunction

  // --------------------------------------------------------------------------
  // Monitor state (updated at negedge)
  // --------------------------------------------------------------------------
  typedef struct { logic [ADDR_W-1:0] a; longint t; } aq_t;
  typedef struct { logic [DATA_W-1:0] d; logic [SW-1:0] s; longint t; } wq_t;
  typedef struct { logic [DATA_W-1:0] d; longint t; } rq_t;

  longint cyc = 0;                // index of the cycle being checked
  aq_t    aw_sb [$], ar_sb [$];   // captured, not yet performed
  wq_t    w_sb [$];
  longint b_pend [$];             // performed writes waiting for B (cycle of the write)
  rq_t    r_exp [$];              // performed reads waiting for R (data, cycle of the read)
  longint ar_assign = 0;          // request index of the next AR handshake
  longint ar_idx_q [$];           // request index of each captured AR
  longint last_bhs = NEVER, last_rhs = NEVER;
  longint last_awhs = NEVER, last_arhs = NEVER;
  bit     bv_prev = 0, bhs_prev = 0, rv_prev = 0, rhs_prev = 0;
  // reference model (documented channel behaviour)
  bit     m_awf = 0, m_wf = 0, m_bv = 0, m_arf = 0, m_rv = 0;
  // totals
  longint n_aw = 0, n_w = 0, n_ar = 0, n_wr = 0, n_rd = 0, n_b = 0, n_r = 0, n_rst = 0;
  // event log for directed tests
  bit     log_on = 0;
  longint log_aw [$], log_w [$], log_ar [$], log_wr [$], log_rd [$], log_brise [$], log_rrise [$];
  longint log_bhs [$], log_rhs [$];
  // handshake flags for the random master (set at negedge, consumed at posedge)
  bit     aw_hs_seen = 0, w_hs_seen = 0, ar_hs_seen = 0;

  function automatic void chk(tb_checker c, bit ok, string msg);
    if (ok) c.pass(); else c.fail($sformatf("cyc %0d: %s", cyc, msg));
  endfunction

  function automatic longint max3(longint a, longint b, longint c);
    longint m = a;
    if (b > m) m = b;
    if (c > m) m = c;
    return m;
  endfunction

  always @(negedge clk) begin
    if (rst_n !== 1'b1) begin
      // reset: in-flight transactions are lost
      if (aw_sb.size() || w_sb.size() || b_pend.size()) cv("rst_inflight_w");
      if (ar_sb.size() || r_exp.size()) cv("rst_inflight_r");
      aw_sb.delete(); w_sb.delete(); ar_sb.delete(); ar_idx_q.delete();
      b_pend.delete(); r_exp.delete();
      ar_assign = longint'(rd_cnt);
      last_bhs = NEVER; last_rhs = NEVER; last_awhs = NEVER; last_arhs = NEVER;
      bv_prev = 0; bhs_prev = 0; rv_prev = 0; rhs_prev = 0;
      m_awf = 0; m_wf = 0; m_bv = 0; m_arf = 0; m_rv = 0;
      aw_hs_seen = 0; w_hs_seen = 0; ar_hs_seen = 0;
      // outputs in reset
      chk(chk_cyc, awready === 1'b1 && wready === 1'b1 && arready === 1'b1 && bvalid === 1'b0
                   && rvalid === 1'b0 && wr_en === 1'b0 && rd_en === 1'b0,
          $sformatf("reset outputs awr=%b wr=%b arr=%b bv=%b rv=%b wr_en=%b rd_en=%b",
                    awready, wready, arready, bvalid, rvalid, wr_en, rd_en));
    end else begin
      bit     aw_hs, w_hs, ar_hs, b_hs, r_hs, e_wr, e_rd;
      aq_t    a;
      wq_t    w;
      longint e_t, idx;
      aw_hs = awvalid && awready;
      w_hs  = wvalid && wready;
      ar_hs = arvalid && arready;
      b_hs  = bvalid && bready;
      r_hs  = rvalid && rready;

      // ---- cycle reference model ----
      e_wr = m_awf && m_wf && !m_bv;
      e_rd = m_arf && !m_rv;
      chk(chk_cyc, awready === !m_awf && wready === !m_wf && arready === !m_arf
                   && bvalid === m_bv && rvalid === m_rv && wr_en === e_wr && rd_en === e_rd,
          $sformatf("got awr=%b wr=%b arr=%b bv=%b rv=%b wr_en=%b rd_en=%b exp %b %b %b %b %b %b %b",
                    awready, wready, arready, bvalid, rvalid, wr_en, rd_en,
                    !m_awf, !m_wf, !m_arf, m_bv, m_rv, e_wr, e_rd));
      if (bvalid === 1'b1) chk(chk_cyc, bresp === 2'b00, $sformatf("BRESP %b", bresp));
      if (rvalid === 1'b1) chk(chk_cyc, rresp === 2'b00, $sformatf("RRESP %b", rresp));

      // ---- write performed (uses entries captured in earlier cycles) ----
      if (wr_en === 1'b1) begin
        n_wr++;
        if (log_on) log_wr.push_back(cyc);
        if (aw_sb.size() == 0 || w_sb.size() == 0) begin
          chk(chk_wr, 0, $sformatf("write performed without captured AW (%0d) / W (%0d)",
                                   aw_sb.size(), w_sb.size()));
        end else begin
          a   = aw_sb.pop_front();
          w   = w_sb.pop_front();
          e_t = max3(a.t, w.t, last_bhs) + 1;
          chk(chk_wr, wr_addr === a.a && wr_data === w.d,
              $sformatf("write addr %h data %h, expected %h %h", wr_addr, wr_data, a.a, w.d));
          exp_mem[a.a] = w.d;
          chk(chk_lat, cyc == e_t, $sformatf("write performed at %0d, expected %0d (aw %0d w %0d b %0d)",
                                             cyc, e_t, a.t, w.t, last_bhs));
          if (a.t < w.t) cv("aw_before_w");
          else if (w.t < a.t) cv("w_before_aw");
          else cv("aw_w_same_cycle");
          if (cyc == a.t + 1 && cyc == w.t + 1) cv("w_lat_min");
        end
        b_pend.push_back(cyc);
      end
      // ---- read performed ----
      if (rd_en === 1'b1) begin
        n_rd++;
        if (log_on) log_rd.push_back(cyc);
        if (ar_sb.size() == 0) begin
          chk(chk_rd, 0, "read performed without captured AR");
          r_exp.push_back('{d: 'x, t: cyc});
        end else begin
          a   = ar_sb.pop_front();
          idx = ar_idx_q.pop_front();
          e_t = max3(a.t, last_rhs, NEVER) + 1;
          chk(chk_rd, rd_addr === a.a, $sformatf("read addr %h, expected %h", rd_addr, a.a));
          chk(chk_lat, cyc == e_t, $sformatf("read performed at %0d, expected %0d (ar %0d r %0d)",
                                             cyc, e_t, a.t, last_rhs));
          if (cyc == a.t + 1) cv("r_lat_min");
          r_exp.push_back('{d: fval(a.a, longint'(idx)), t: cyc});
        end
      end
      if (wr_en === 1'b1 && rd_en === 1'b1) cv("wr_rd_same_cycle");
      if (m_awf && m_wf && m_bv) cv("wr_blocked_by_b");
      if (m_arf && m_rv) cv("rd_blocked_by_r");

      // ---- B channel ----
      if (bvalid === 1'b1 && (!bv_prev || bhs_prev)) begin
        if (log_on) log_brise.push_back(cyc);
        if (b_pend.size() == 0) chk(chk_resp, 0, "BVALID without a performed write");
        else chk(chk_lat, cyc == b_pend[0] + 1,
                 $sformatf("BVALID at %0d, write performed at %0d", cyc, b_pend[0]));
      end
      if (bvalid === 1'b1 && bready !== 1'b1) cv("b_stall");
      if (b_hs) begin
        n_b++;
        if (log_on) log_bhs.push_back(cyc);
        if (b_pend.size() == 0) chk(chk_resp, 0, "B handshake without a performed write");
        else begin void'(b_pend.pop_front()); chk_resp.pass(); end
        last_bhs = cyc;
      end
      // ---- R channel ----
      if (rvalid === 1'b1) begin
        if (r_exp.size() == 0) chk(chk_resp, 0, "RVALID without a performed read");
        else begin
          chk(chk_rd, rdata === r_exp[0].d, $sformatf("RDATA %h, expected %h", rdata, r_exp[0].d));
          if (!rv_prev || rhs_prev) begin
            if (log_on) log_rrise.push_back(cyc);
            chk(chk_lat, cyc == r_exp[0].t + 1,
                $sformatf("RVALID at %0d, read performed at %0d", cyc, r_exp[0].t));
          end
        end
      end
      if (rvalid === 1'b1 && rready !== 1'b1) cv("r_stall");
      if (r_hs) begin
        n_r++;
        if (log_on) log_rhs.push_back(cyc);
        if (r_exp.size() == 0) chk(chk_resp, 0, "R handshake without a performed read");
        else begin void'(r_exp.pop_front()); chk_resp.pass(); end
        last_rhs = cyc;
      end
      if (b_hs && r_hs) cv("b_hs_r_hs_same_cycle");

      // ---- request handshakes (captured for later cycles) ----
      if (aw_hs) begin
        n_aw++;
        aw_sb.push_back('{a: awaddr, t: cyc});
        if (log_on) log_aw.push_back(cyc);
        if (bvalid === 1'b1) cv("aw_hs_while_bvalid");
        if (last_awhs == cyc - 2) cv("aw_b2b");
        last_awhs = cyc;
        aw_hs_seen = 1;
      end
      if (w_hs) begin
        n_w++;
        w_sb.push_back('{d: wdata, s: wstrb, t: cyc});
        if (log_on) log_w.push_back(cyc);
        if (bvalid === 1'b1) cv("w_hs_while_bvalid");
        if (wstrb !== '1) cv("wstrb_partial");
        w_hs_seen = 1;
      end
      if (ar_hs) begin
        n_ar++;
        ar_sb.push_back('{a: araddr, t: cyc});
        ar_idx_q.push_back(ar_assign++);
        if (log_on) log_ar.push_back(cyc);
        if (rvalid === 1'b1) cv("ar_hs_while_rvalid");
        if (last_arhs == cyc - 2) cv("ar_b2b");
        last_arhs = cyc;
        ar_hs_seen = 1;
      end
      if (aw_hs && ar_hs) cv("aw_hs_ar_hs_same_cycle");

      // ---- reference model next state ----
      if (aw_hs) m_awf = 1; else if (e_wr) m_awf = 0;
      if (w_hs)  m_wf  = 1; else if (e_wr) m_wf  = 0;
      if (e_wr)  m_bv  = 1; else if (b_hs) m_bv  = 0;
      if (ar_hs) m_arf = 1; else if (e_rd) m_arf = 0;
      if (e_rd)  m_rv  = 1; else if (r_hs) m_rv  = 0;

      bv_prev = (bvalid === 1'b1); bhs_prev = b_hs;
      rv_prev = (rvalid === 1'b1); rhs_prev = r_hs;
    end
    cyc++;
  end

  // --------------------------------------------------------------------------
  // Random master
  // --------------------------------------------------------------------------
  typedef enum int { M_AW_FIRST, M_W_FIRST, M_SAME, M_FREE } wmode_e;

  int                n_wr_tx = 60000, n_rd_tx = 60000, rst_permil = 3, prof_len = 2000;
  logic [ADDR_W-1:0] wtx_addr [];
  logic [DATA_W-1:0] wtx_data [];
  logic [SW-1:0]     wtx_strb [];
  wmode_e            wtx_mode [];
  bit                wtx_aw_done [], wtx_w_done [];
  logic [ADDR_W-1:0] rtx_addr [];

  bit  rand_on = 0;
  int  aw_next = 0, w_next = 0, ar_next = 0;
  int  aw_wait = -1, w_wait = -1, ar_wait = -1;
  bit  s_awv = 0, s_wv = 0, s_arv = 0;
  int  rst_cnt = 0;
  int  prof = 0, prof_cnt = 0;
  int  p_bready = 100, p_rready = 100;

  function automatic int pick_dly();
    int k = $urandom_range(99);
    case (prof)
      0: return 0;
      1: return (k < 70) ? 0 : $urandom_range(1, 3);
      2: return (k < 30) ? 0 : $urandom_range(1, 12);
      default: return (k < 50) ? 0 : ((k < 95) ? $urandom_range(1, 4) : $urandom_range(5, 40));
    endcase
  endfunction

  function automatic logic [ADDR_W-1:0] rnd_addr();
    // half of the addresses in a small window, so that repeated addresses occur
    if ($urandom_range(1)) return ADDR_W'($urandom_range(31));
    return ADDR_W'({$urandom, $urandom});
  endfunction

  task automatic master_step();
    // profile
    if (prof_cnt == 0) begin
      prof     = $urandom_range(3);
      prof_cnt = prof_len;
      case (prof)
        0: begin p_bready = 100; p_rready = 100; end
        1: begin p_bready = 70;  p_rready = 70;  end
        2: begin p_bready = 15;  p_rready = 25;  end
        default: begin p_bready = $urandom_range(5, 95); p_rready = $urandom_range(5, 95); end
      endcase
    end
    prof_cnt--;
    bready <= ($urandom_range(99) < p_bready);
    rready <= ($urandom_range(99) < p_rready);

    // reset insertion / reset in progress
    if (rst_cnt > 0) begin
      rst_cnt--;
      if (rst_cnt == 0) rst_n <= 1'b1;
      awvalid <= 0; wvalid <= 0; arvalid <= 0;
      awaddr <= ADDR_W'($urandom); wdata <= DATA_W'($urandom); araddr <= ADDR_W'($urandom);
      return;
    end
    if (rst_permil > 0 && $urandom_range(9999) < rst_permil) begin
      rst_cnt = $urandom_range(1, 4);
      rst_n   <= 1'b0;
      n_rst++;
      cv("rst");
      s_awv = 0; s_wv = 0; s_arv = 0;
      if (w_next > aw_next) aw_next = w_next; else w_next = aw_next;
      aw_wait = -1; w_wait = -1; ar_wait = -1;
      aw_hs_seen = 0; w_hs_seen = 0; ar_hs_seen = 0;
      awvalid <= 0; wvalid <= 0; arvalid <= 0;
      return;
    end

    // AW channel
    if (s_awv && aw_hs_seen) begin
      wtx_aw_done[aw_next] = 1;
      s_awv = 0; aw_next++; aw_wait = -1;
    end
    aw_hs_seen = 0;
    if (!s_awv && aw_next < n_wr_tx
        && (wtx_mode[aw_next] != M_W_FIRST || wtx_w_done[aw_next])) begin
      if (aw_wait < 0) aw_wait = (wtx_mode[aw_next] == M_SAME) ? 0 : pick_dly();
      if (aw_wait == 0) s_awv = 1; else aw_wait--;
    end
    // W channel
    if (s_wv && w_hs_seen) begin
      wtx_w_done[w_next] = 1;
      s_wv = 0; w_next++; w_wait = -1;
    end
    w_hs_seen = 0;
    if (!s_wv && w_next < n_wr_tx
        && (wtx_mode[w_next] != M_AW_FIRST || wtx_aw_done[w_next])) begin
      if (w_wait < 0) w_wait = (wtx_mode[w_next] == M_SAME) ? 0 : pick_dly();
      if (w_wait == 0) s_wv = 1; else w_wait--;
    end
    // AR channel
    if (s_arv && ar_hs_seen) begin
      s_arv = 0; ar_next++; ar_wait = -1;
    end
    ar_hs_seen = 0;
    if (!s_arv && ar_next < n_rd_tx) begin
      if (ar_wait < 0) ar_wait = pick_dly();
      if (ar_wait == 0) s_arv = 1; else ar_wait--;
    end

    awvalid <= s_awv;
    awaddr  <= s_awv ? wtx_addr[aw_next] : ADDR_W'({$urandom, $urandom});
    awprot  <= 3'($urandom);
    wvalid  <= s_wv;
    wdata   <= s_wv ? wtx_data[w_next] : DATA_W'({$urandom, $urandom});
    wstrb   <= s_wv ? wtx_strb[w_next] : SW'($urandom);
    arvalid <= s_arv;
    araddr  <= s_arv ? rtx_addr[ar_next] : ADDR_W'({$urandom, $urandom});
    arprot  <= 3'($urandom);
  endtask

  always @(posedge clk) if (rand_on) master_step();

  function automatic bit master_done();
    return aw_next >= n_wr_tx && w_next >= n_wr_tx && ar_next >= n_rd_tx && !s_awv && !s_wv
           && !s_arv && rst_cnt == 0;
  endfunction

  function automatic bit slave_idle();
    return aw_sb.size() == 0 && w_sb.size() == 0 && ar_sb.size() == 0 && b_pend.size() == 0
           && r_exp.size() == 0 && awvalid === 1'b0 && wvalid === 1'b0 && arvalid === 1'b0
           && bvalid === 1'b0 && rvalid === 1'b0;
  endfunction

  // --------------------------------------------------------------------------
  // Directed tests (master random off)
  // --------------------------------------------------------------------------
  function automatic void log_clear();
    log_aw.delete(); log_w.delete(); log_ar.delete(); log_wr.delete(); log_rd.delete();
    log_brise.delete(); log_rrise.delete(); log_bhs.delete(); log_rhs.delete();
  endfunction

  task automatic idle_cycles(int n);
    repeat (n) begin
      @(posedge clk);
      awvalid <= 0; wvalid <= 0; arvalid <= 0;
      awaddr <= ADDR_W'($urandom); wdata <= DATA_W'($urandom); araddr <= ADDR_W'($urandom);
    end
  endtask

  // One write from an idle slave, BREADY = 1. order 0: AW and W in the same
  // cycle; 1: AW first, W gap cycles later; 2: W first, AW gap cycles later.
  task automatic d_write(int order, int gap);
    longint tc;
    log_clear();
    log_on = 1;
    bready <= 1'b1;
    @(posedge clk);
    if (order != 2) begin awvalid <= 1; awaddr <= ADDR_W'($urandom); end
    if (order != 1) begin wvalid <= 1; wdata <= DATA_W'($urandom); wstrb <= SW'($urandom); end
    @(posedge clk);
    awvalid <= 0; wvalid <= 0;
    if (order != 0) begin
      repeat (gap - 1) @(posedge clk);
      if (order == 1) begin wvalid <= 1; wdata <= DATA_W'($urandom); wstrb <= SW'($urandom); end
      else begin awvalid <= 1; awaddr <= ADDR_W'($urandom); end
      @(posedge clk);
      awvalid <= 0; wvalid <= 0;
    end
    idle_cycles(5);
    log_on = 0;
    if (log_aw.size() != 1 || log_w.size() != 1 || log_wr.size() != 1 || log_brise.size() != 1
        || log_bhs.size() != 1) begin
      chk_dir.fail($sformatf("write order %0d: events aw=%0d w=%0d wr=%0d brise=%0d bhs=%0d", order,
                             log_aw.size(), log_w.size(), log_wr.size(), log_brise.size(), log_bhs.size()));
      return;
    end
    // the handshakes happen in the cycle the master offers them (idle slave)
    chk(chk_dir, log_w[0] - log_aw[0] == ((order == 0) ? 0 : ((order == 1) ? gap : -gap)),
        $sformatf("write order %0d gap %0d: AW handshake %0d, W handshake %0d", order, gap,
                  log_aw[0], log_w[0]));
    // c = the later of the AW and W handshakes
    tc = (log_aw[0] > log_w[0]) ? log_aw[0] : log_w[0];
    if (log_wr[0] == tc + 1 && log_brise[0] == tc + 2 && log_bhs[0] == tc + 2) chk_dir.pass();
    else chk_dir.fail($sformatf("write order %0d gap %0d: c=%0d wr=%0d bvalid=%0d bhs=%0d (exp c+1, c+2)",
                                order, gap, tc, log_wr[0], log_brise[0], log_bhs[0]));
    $display("DIR write order=%0d gap=%0d: c=%0d access=c+%0d BVALID=c+%0d", order, gap, tc,
             log_wr[0] - tc, log_brise[0] - tc);
  endtask

  task automatic d_read();
    log_clear();
    log_on = 1;
    rready <= 1'b1;
    @(posedge clk);
    arvalid <= 1; araddr <= ADDR_W'($urandom);
    @(posedge clk);
    arvalid <= 0;
    idle_cycles(5);
    log_on = 0;
    if (log_ar.size() != 1 || log_rd.size() != 1 || log_rrise.size() != 1 || log_rhs.size() != 1) begin
      chk_dir.fail($sformatf("read: events ar=%0d rd=%0d rrise=%0d rhs=%0d",
                             log_ar.size(), log_rd.size(), log_rrise.size(), log_rhs.size()));
      return;
    end
    if (log_rd[0] == log_ar[0] + 1 && log_rrise[0] == log_ar[0] + 2 && log_rhs[0] == log_ar[0] + 2)
      chk_dir.pass();
    else chk_dir.fail($sformatf("read: c=%0d rd=%0d rvalid=%0d rhs=%0d (exp c+1, c+2)",
                                log_ar[0], log_rd[0], log_rrise[0], log_rhs[0]));
    $display("DIR read: c=%0d access=c+%0d RVALID=c+%0d", log_ar[0], log_rd[0] - log_ar[0],
             log_rrise[0] - log_ar[0]);
  endtask

  // N writes by a master that offers the next request in the cycle after the
  // B handshake (pipelined = 0) or keeps VALID high with the next payload
  // right after each handshake (pipelined = 1). BREADY = 1.
  task automatic d_wr_stream(int n, bit pipelined);
    for (int i = 0; i < n; i++) begin
      @(posedge clk);
      awvalid <= 1; awaddr <= ADDR_W'($urandom);
      wvalid  <= 1; wdata  <= DATA_W'($urandom); wstrb <= SW'($urandom);
      do @(negedge clk); while (!(awvalid === 1'b1 && awready === 1'b1));
      if (!pipelined || i == n - 1) begin
        @(posedge clk);
        awvalid <= 0; wvalid <= 0;
        if (!pipelined) do @(negedge clk); while (!(bvalid === 1'b1 && bready === 1'b1));
      end
    end
  endtask

  task automatic d_rd_stream(int n, bit pipelined);
    for (int i = 0; i < n; i++) begin
      @(posedge clk);
      arvalid <= 1; araddr <= ADDR_W'($urandom);
      do @(negedge clk); while (!(arvalid === 1'b1 && arready === 1'b1));
      if (!pipelined || i == n - 1) begin
        @(posedge clk);
        arvalid <= 0;
        if (!pipelined) do @(negedge clk); while (!(rvalid === 1'b1 && rready === 1'b1));
      end
    end
  endtask

  // spacing of consecutive handshakes in a log; returns min / max
  function automatic void spacing(longint q [$], output longint mn, output longint mx);
    mn = 1 << 30; mx = 0;
    for (int i = 1; i < q.size(); i++) begin
      if (q[i] - q[i-1] < mn) mn = q[i] - q[i-1];
      if (q[i] - q[i-1] > mx) mx = q[i] - q[i-1];
    end
  endfunction

  task automatic d_throughput(int mode);  // 0 write, 1 read, 2 both at once
    localparam int N = 40;
    longint mn, mx;
    bit     pipe;
    for (int p = 0; p < 2; p++) begin
      pipe = bit'(p);
      log_clear();
      log_on = 1;
      bready <= 1'b1; rready <= 1'b1;
      fork
        if (mode != 1) d_wr_stream(N, pipe);
        if (mode != 0) d_rd_stream(N, pipe);
      join
      idle_cycles(6);
      log_on = 0;
      if (mode != 1) begin
        spacing(log_aw, mn, mx);
        chk(chk_dir, log_aw.size() == N && log_wr.size() == N && log_bhs.size() == N,
            $sformatf("write stream: aw=%0d wr=%0d b=%0d", log_aw.size(), log_wr.size(), log_bhs.size()));
        if (!pipe) chk(chk_dir, mn == 3 && mx == 3,
                       $sformatf("write throughput (wait for B): spacing %0d..%0d, expected 3", mn, mx));
        else chk(chk_dir, mx <= 3, $sformatf("write throughput (pipelined): spacing %0d..%0d > 3", mn, mx));
        $display("DIR throughput mode=%0d %s write: %0d transactions in %0d cycles, spacing %0d..%0d",
                 mode, pipe ? "pipelined" : "wait-for-response", N, log_bhs[N-1] - log_aw[0] + 1, mn, mx);
      end
      if (mode != 0) begin
        spacing(log_ar, mn, mx);
        chk(chk_dir, log_ar.size() == N && log_rd.size() == N && log_rhs.size() == N,
            $sformatf("read stream: ar=%0d rd=%0d r=%0d", log_ar.size(), log_rd.size(), log_rhs.size()));
        if (!pipe) chk(chk_dir, mn == 3 && mx == 3,
                       $sformatf("read throughput (wait for R): spacing %0d..%0d, expected 3", mn, mx));
        else chk(chk_dir, mx <= 3, $sformatf("read throughput (pipelined): spacing %0d..%0d > 3", mn, mx));
        $display("DIR throughput mode=%0d %s read: %0d transactions in %0d cycles, spacing %0d..%0d",
                 mode, pipe ? "pipelined" : "wait-for-response", N, log_rhs[N-1] - log_ar[0] + 1, mn, mx);
      end
      if (mode == 2) begin
        int same = 0;
        foreach (log_wr[i]) foreach (log_rd[j]) if (log_wr[i] == log_rd[j]) same++;
        chk(chk_dir, same > 0, "concurrent streams never accessed in the same cycle");
        $display("DIR both %s: write and read performed in the same cycle %0d times",
                 pipe ? "pipelined" : "wait-for-response", same);
      end
    end
  endtask

  // --------------------------------------------------------------------------
  // Main
  // --------------------------------------------------------------------------
  initial begin
    int unsigned seed;
    longint      t_wd;
    bit          ok;
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("N_WR=%d", n_wr_tx));
    void'($value$plusargs("N_RD=%d", n_rd_tx));
    void'($value$plusargs("RST_PERMIL=%d", rst_permil));
    void'($value$plusargs("PROF_LEN=%d", prof_len));
    $display("tb_axil_slave: ADDR_W=%0d SEED=%0d N_WR=%0d N_RD=%0d RST=%0d/10000 PROF_LEN=%0d",
             ADDR_W, seed, n_wr_tx, n_rd_tx, rst_permil, prof_len);

    wtx_addr = new[n_wr_tx]; wtx_data = new[n_wr_tx]; wtx_strb = new[n_wr_tx];
    wtx_mode = new[n_wr_tx]; wtx_aw_done = new[n_wr_tx]; wtx_w_done = new[n_wr_tx];
    rtx_addr = new[n_rd_tx];
    foreach (wtx_addr[i]) begin
      wtx_addr[i] = rnd_addr();
      wtx_data[i] = DATA_W'({$urandom, $urandom});
      wtx_strb[i] = ($urandom_range(1)) ? '1 : SW'($urandom);
      wtx_mode[i] = wmode_e'($urandom_range(3));
    end
    foreach (rtx_addr[i]) rtx_addr[i] = rnd_addr();

    // reset
    rst_n <= 1'b0;
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    idle_cycles(2);

    // directed: latency from an idle slave
    d_write(0, 0);
    for (int g = 1; g <= 3; g++) begin d_write(1, g); d_write(2, g); end
    d_read();
    // directed: throughput
    d_throughput(0);
    d_throughput(1);
    d_throughput(2);
    idle_cycles(4);

    // random phase
    rand_on = 1;
    t_wd = cyc;
    while (!master_done()) @(posedge clk);
    rand_on = 0;
    @(posedge clk);
    awvalid <= 0; wvalid <= 0; arvalid <= 0; bready <= 1; rready <= 1;
    repeat (200) begin
      @(posedge clk);
      if (slave_idle()) break;
    end
    idle_cycles(3);
    chk(chk_resp, slave_idle(),
        $sformatf("not idle at the end: aw=%0d w=%0d ar=%0d b=%0d r=%0d bvalid=%b rvalid=%b",
                  aw_sb.size(), w_sb.size(), ar_sb.size(), b_pend.size(), r_exp.size(), bvalid, rvalid));
    $display("random phase: %0d cycles; totals (directed + random): AW %0d W %0d AR %0d, writes %0d reads %0d, B %0d R %0d, resets %0d",
             cyc - t_wd, n_aw, n_w, n_ar, n_wr, n_rd, n_b, n_r, n_rst);

    // final memory compare
    foreach (exp_mem[a]) begin
      if (mem.exists(a) && mem[a] === exp_mem[a]) chk_mem.pass();
      else chk_mem.fail($sformatf("mem[%h] = %h, expected %h", a, mem.exists(a) ? mem[a] : 'x, exp_mem[a]));
    end
    chk(chk_mem, mem.size() == exp_mem.size(), $sformatf("mem has %0d addresses, expected %0d",
                                                         mem.size(), exp_mem.size()));

    // coverage
    foreach (cov_names[i]) begin
      longint v;
      v = cov.exists(cov_names[i]) ? cov[cov_names[i]] : 0;
      $display("COVER %-24s %0d", cov_names[i], v);
      if (v > 0) chk_cov.pass(); else chk_cov.fail($sformatf("coverage item %s never hit", cov_names[i]));
    end

    ok = tb_final_report('{chk_cyc, chk_wr, chk_rd, chk_resp, chk_lat, chk_dir, chk_mem, chk_cov});
    $finish;
  end

  // watchdog
  initial begin
    #(T_CLK * 64'd50_000_000);
    $display("MISMATCH [watchdog] simulation did not finish");
    $display("TB_RESULT: FAIL");
    $finish;
  end

endmodule
