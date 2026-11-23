// tb_axil_xbar: self-checking testbench of rtl/l4/axil_xbar.sv (S5-2).
//
// Master: an AXI4-Lite master driver with independent write and read processes (+CONC=1: both
// run at the same time). Each write chooses an address class (present slot, absent slot
// (slot >= N or SLOT_EN = 0), out of range (address bits above the slot index)), random data,
// WSTRB and PROT, the order of AW and W (AW first, W first, same cycle) with random gaps
// (0..MAXD), and the BREADY delay; reads likewise (RREADY delay). +B2B percent of transactions
// back-to-back (VALID in the cycle after the previous response handshake, no gaps); +LONG
// per-mille of transactions with a long response backpressure (50..400 cycles of BREADY / RREADY 0).
// Slaves: N response models (one per port). READY random per cycle (1 in SMAXD + 1, may be 1
// before VALID), long READY blocks (+LONG), random response delay, random BRESP / RRESP (OKAY,
// SLVERR, DECERR) and RDATA. Every accepted request is logged with its port, offset, data,
// WSTRB, PROT, response and cycle stamps.
// Reference model and checks:
//   - decode (independent of the RTL): slot = addr[12 +: SLOT_W], out of range if any bit above
//     is 1, present if slot < N and SLOT_EN[slot]
//   - every master write / read: present -> exactly one logged slave access at that port with
//     offset addr[11:0], data, WSTRB, PROT, and the master response == the slave's response
//     (read data included); absent / out of range -> no slave access, OKAY, read data 0
//   - order: one transaction per channel at a time on the slave side (TB_XB_OUTS check), the
//     logs are consumed in master order
//   - cycle rules of the header of axil_xbar.sv for every transaction (REG 1 and REG 0), and
//     dut.LAT_REQ / LAT_RSP == REG
//   - protocol: VALID and payload held until READY on every slave port (requests) and on the
//     master port (responses) (TB_XB_HOLD, $error), no X on VALID / READY (TB_XB_X)
//   - coverage: every address class, AW / W orders, concurrent read and write, back-to-back,
//     long backpressure (master and slave side), every response code.
// Negative: +NEG_AW / +NEG_W / +NEG_AR = k: the master drops AWVALID / WVALID / ARVALID once
// before READY, k times (each in a cycle where the xbar's READY is 0); the xbar must report
// exactly k L4_XB_AW / L4_XB_W / L4_XB_AR. +NEG_R = k (REG 0): a slave drops RVALID before RREADY
// k times (L4_XB_R, and TB_XB_HOLD on the master side since REG 0 passes R through).
// +PERF=1: measurement phase (no gaps, slaves always ready, response in the next cycle): period of
// back-to-back reads / writes to a present and to an absent slot, printed as XB_PERF.
`timescale 1ns / 1ps
module tb_axil_xbar;
  import tb_util_pkg::*;

  parameter int          N        = 4;
  parameter int          SLOT_W   = 4;
  parameter int          S_ADDR_W = 16;
  parameter logic [15:0] SLOT_EN  = 16'hFFFF >> (16 - N);
  parameter int          REG      = 1;

  localparam int NP = (N >= 1) ? N : 2;   // TB array size = DUT port size (also for illegal N)

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;
  longint cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // master port
  logic [S_ADDR_W-1:0] awaddr = '0, araddr = '0;
  logic [2:0]  awprot = '0, arprot = '0;
  logic        awvalid = 1'b0, wvalid = 1'b0, bready = 1'b0, arvalid = 1'b0, rready = 1'b0;
  logic [31:0] wdata = '0, rdata;
  logic [3:0]  wstrb = '0;
  logic        awready, wready, bvalid, arready, rvalid;
  logic [1:0]  bresp, rresp;
  // slave ports
  logic [NP-1:0][11:0] m_awaddr, m_araddr;
  logic [NP-1:0][2:0]  m_awprot, m_arprot;
  logic [NP-1:0]       m_awvalid, m_awready, m_wvalid, m_wready, m_bvalid, m_bready;
  logic [NP-1:0]       m_arvalid, m_arready, m_rvalid, m_rready;
  logic [NP-1:0][31:0] m_wdata, m_rdata;
  logic [NP-1:0][3:0]  m_wstrb;
  logic [NP-1:0][1:0]  m_bresp, m_rresp;

  axil_xbar #(.N(N), .SLOT_W(SLOT_W), .S_ADDR_W(S_ADDR_W), .SLOT_EN(SLOT_EN), .REG(REG)) dut (
    .clk, .rst_n,
    .s_axi_awaddr_i(awaddr), .s_axi_awprot_i(awprot), .s_axi_awvalid_i(awvalid), .s_axi_awready_o(awready),
    .s_axi_wdata_i(wdata), .s_axi_wstrb_i(wstrb), .s_axi_wvalid_i(wvalid), .s_axi_wready_o(wready),
    .s_axi_bresp_o(bresp), .s_axi_bvalid_o(bvalid), .s_axi_bready_i(bready),
    .s_axi_araddr_i(araddr), .s_axi_arprot_i(arprot), .s_axi_arvalid_i(arvalid), .s_axi_arready_o(arready),
    .s_axi_rdata_o(rdata), .s_axi_rresp_o(rresp), .s_axi_rvalid_o(rvalid), .s_axi_rready_i(rready),
    .m_axi_awaddr_o(m_awaddr), .m_axi_awprot_o(m_awprot), .m_axi_awvalid_o(m_awvalid),
    .m_axi_awready_i(m_awready), .m_axi_wdata_o(m_wdata), .m_axi_wstrb_o(m_wstrb),
    .m_axi_wvalid_o(m_wvalid), .m_axi_wready_i(m_wready), .m_axi_bresp_i(m_bresp),
    .m_axi_bvalid_i(m_bvalid), .m_axi_bready_o(m_bready),
    .m_axi_araddr_o(m_araddr), .m_axi_arprot_o(m_arprot), .m_axi_arvalid_o(m_arvalid),
    .m_axi_arready_i(m_arready), .m_axi_rdata_i(m_rdata), .m_axi_rresp_i(m_rresp),
    .m_axi_rvalid_i(m_rvalid), .m_axi_rready_o(m_rready));

  tb_checker c_wr = new("write"), c_rd = new("read"), c_time = new("timing"), c_ord = new("order"),
             c_cov = new("coverage"), c_neg = new("negative");

  // ---------------- settings ----------------
  int maxd = 3, smaxd = 3, long_pm = 10, b2b_pc = 20, fast = 0;
  int neg_aw = 0, neg_w = 0, neg_ar = 0, neg_r = 0;
  int neg_aw_done = 0, neg_w_done = 0, neg_ar_done = 0, neg_r_done = 0;

  function automatic int rnd(int n);
    return n <= 0 ? 0 : $urandom_range(n);
  endfunction

  // ---------------- reference decode ----------------
  function automatic int ref_slot(longint unsigned a);
    return int'((a >> 12) & ((64'd1 << SLOT_W) - 1));
  endfunction
  function automatic bit ref_oor(longint unsigned a);
    return (a >> (12 + SLOT_W)) != 0;
  endfunction
  function automatic bit ref_hit(longint unsigned a);
    int k = ref_slot(a);
    return !ref_oor(a) && k < N && SLOT_EN[k];
  endfunction

  int present[$], absent[$];
  // address class: 0 present slot, 1 absent slot, 2 out of range
  function automatic logic [S_ADDR_W-1:0] gen_addr(output int cls);
    longint unsigned a;
    int k, opts[$];
    opts.push_back(0); opts.push_back(0); opts.push_back(0);
    if (absent.size() > 0) opts.push_back(1);
    if (S_ADDR_W > 12 + SLOT_W) opts.push_back(2);
    cls = opts[$urandom_range(opts.size() - 1)];
    a = $urandom_range(3) == 0 ? longint'($urandom_range(4095)) : longint'(4 * $urandom_range(1023));
    case (cls)
      0: k = present[$urandom_range(present.size() - 1)];
      1: k = absent[$urandom_range(absent.size() - 1)];
      default: k = $urandom_range((1 << SLOT_W) - 1);
    endcase
    a |= longint'(k) << 12;
    if (cls == 2) begin
      longint unsigned up = {$urandom, $urandom};
      up &= (64'd1 << (S_ADDR_W - 12 - SLOT_W)) - 1;
      if (up == 0) up = 64'd1 << $urandom_range(S_ADDR_W - 13 - SLOT_W);
      a |= up << (12 + SLOT_W);
    end
    return S_ADDR_W'(a);
  endfunction

  // ---------------- slave models ----------------
  typedef struct {
    int slot;
    logic [11:0] off;
    logic [31:0] data;
    logic [3:0]  strb;
    logic [2:0]  prot;
    logic [1:0]  resp;
    longint c_a, c_w, c_b;   // write: AWVALID rise, WVALID rise, B handshake / read: ARVALID rise, -, R handshake
    longint h_a, h_w;        // write: AW, W handshake / read: AR handshake
  } ev_t;
  ev_t wr_log[$], rd_log[$];
  int wr_outs = 0, rd_outs = 0;   // slave-side transactions in progress (all ports)
  longint n_resp[4] = '{0, 0, 0, 0};
  longint n_sblk = 0;

  function automatic logic [1:0] rnd_resp();
    int k = $urandom_range(9);
    return k < 6 ? 2'b00 : (k < 8 ? 2'b10 : 2'b11);
  endfunction

  for (genvar k = 0; k < NP; k++) begin : g_slv
    logic awr = 1'b0, wr_ = 1'b0, bv = 1'b0, arr = 1'b0, rv = 1'b0;
    logic [1:0]  br = '0, rr = '0;
    logic [31:0] rd = '0;
    assign m_awready[k] = awr;
    assign m_wready[k]  = wr_;
    assign m_bvalid[k]  = bv;
    assign m_bresp[k]   = br;
    assign m_arready[k] = arr;
    assign m_rvalid[k]  = rv;
    assign m_rdata[k]   = rd;
    assign m_rresp[k]   = rr;

    // handshakes sampled at negedge, applied at the next posedge
    bit hs_aw, hs_w, hs_b, hs_ar, hs_r;
    bit aw_got = 0, w_got = 0, b_wait = 0, ar_got = 0, r_wait = 0, r_drop = 0;
    int b_dly = 0, r_dly = 0, blk = 0;
    ev_t we, re;
    bit p_awv = 0, p_wv = 0, p_arv = 0;
    logic [11:0] p_awa, p_ara;
    logic [31:0] p_wd;
    logic [3:0]  p_ws;
    logic [2:0]  p_awp, p_arp;

    always @(negedge clk) begin
      hs_aw = rst_n && m_awvalid[k] === 1'b1 && awr;
      hs_w  = rst_n && m_wvalid[k] === 1'b1 && wr_;
      hs_b  = rst_n && bv && m_bready[k] === 1'b1;
      hs_ar = rst_n && m_arvalid[k] === 1'b1 && arr;
      hs_r  = rst_n && rv && m_rready[k] === 1'b1;
      if (rst_n) begin
        // request VALID / payload held until READY (xbar outputs)
        if (p_awv && !(m_awvalid[k] === 1'b1 && m_awaddr[k] === p_awa && m_awprot[k] === p_awp))
          $error("TB_XB_HOLD port %0d: AWVALID / AWADDR / AWPROT changed before AWREADY", k);
        if (p_wv && !(m_wvalid[k] === 1'b1 && m_wdata[k] === p_wd && m_wstrb[k] === p_ws))
          $error("TB_XB_HOLD port %0d: WVALID / WDATA / WSTRB changed before WREADY", k);
        if (p_arv && !(m_arvalid[k] === 1'b1 && m_araddr[k] === p_ara && m_arprot[k] === p_arp))
          $error("TB_XB_HOLD port %0d: ARVALID / ARADDR / ARPROT changed before ARREADY", k);
        if ($isunknown({m_awvalid[k], m_wvalid[k], m_bready[k], m_arvalid[k], m_rready[k]}))
          $error("TB_XB_X port %0d: X on a slave-side VALID / READY", k);
        p_awv = m_awvalid[k] === 1'b1 && !awr; p_awa = m_awaddr[k]; p_awp = m_awprot[k];
        p_wv  = m_wvalid[k] === 1'b1 && !wr_;  p_wd = m_wdata[k];   p_ws = m_wstrb[k];
        p_arv = m_arvalid[k] === 1'b1 && !arr; p_ara = m_araddr[k]; p_arp = m_arprot[k];
        // the xbar issues W to a port only after (or with) the AW of the same write
        if (m_wvalid[k] === 1'b1 && !aw_got && we.c_a < 0 && m_awvalid[k] !== 1'b1)
          c_ord.fail($sformatf("port %0d: WVALID without an AW of this write", k));
        // VALID rise stamps
        if (m_awvalid[k] === 1'b1 && !aw_got && we.c_a < 0) we.c_a = cyc;
        if (m_wvalid[k] === 1'b1 && !w_got && we.c_w < 0) we.c_w = cyc;
        if (m_arvalid[k] === 1'b1 && !ar_got && re.c_a < 0) re.c_a = cyc;
        if (hs_aw) begin
          if (aw_got) c_ord.fail($sformatf("port %0d: second AW before the B of the first", k));
          if (wr_outs != 0 && !(w_got && !aw_got))
            c_ord.fail($sformatf("port %0d: AW while another write is in progress (%0d)", k, wr_outs));
          else c_ord.pass();
          we.off = m_awaddr[k]; we.prot = m_awprot[k]; we.h_a = cyc;
        end
        if (hs_w) begin
          if (w_got) c_ord.fail($sformatf("port %0d: second W before the B of the first", k));
          we.data = m_wdata[k]; we.strb = m_wstrb[k]; we.h_w = cyc;
        end
        if (hs_ar) begin
          if (rd_outs != 0) c_ord.fail($sformatf("port %0d: AR while another read is in progress (%0d)", k, rd_outs));
          else c_ord.pass();
          re.off = m_araddr[k]; re.prot = m_arprot[k]; re.h_a = cyc;
        end
        if (hs_b) begin we.c_b = cyc; wr_log.push_back(we); end
        if (hs_r) begin re.c_b = cyc; rd_log.push_back(re); end
        if (hs_aw && !w_got) wr_outs++;
        if (hs_w && !aw_got && !hs_aw) wr_outs++;
        if (hs_b) wr_outs--;
        if (hs_ar) rd_outs++;
        if (hs_r) rd_outs--;
        // NEG_R: drop RVALID once before RREADY (REG 0 passes it to the master)
        r_drop = 0;
        if (rv && m_rready[k] !== 1'b1 && neg_r_done < neg_r && $urandom_range(1) == 0) begin
          r_drop = 1;
          neg_r_done++;
        end
      end
    end

    initial begin
      we.c_a = -1; we.c_w = -1; re.c_a = -1;
    end

    always @(posedge clk) begin
      if (!rst_n) begin
        awr <= 1'b0; wr_ <= 1'b0; bv <= 1'b0; arr <= 1'b0; rv <= 1'b0;
      end else begin
        automatic bit rdy;
        if (blk > 0) blk--;
        else if (!fast && $urandom_range(9999) < long_pm) begin blk = $urandom_range(400, 50); n_sblk++; end
        // ---- write ----
        if (hs_aw) aw_got = 1;
        if (hs_w)  w_got = 1;
        if (aw_got && w_got && !b_wait && !bv) begin
          b_wait = 1;
          b_dly = fast ? 0 : rnd(smaxd);
        end
        if (b_wait && !bv) begin
          if (b_dly > 0) b_dly--;
          else if (blk == 0) begin
            we.slot = k;
            we.resp = rnd_resp();
            br <= we.resp;
            bv <= 1'b1;
          end
        end
        if (hs_b) begin
          bv <= 1'b0;
          aw_got = 0; w_got = 0; b_wait = 0;
          we.c_a = -1; we.c_w = -1;
        end
        rdy = fast || (blk == 0 && $urandom_range(smaxd) == 0);
        awr <= !aw_got && rdy;
        rdy = fast || (blk == 0 && $urandom_range(smaxd) == 0);
        wr_ <= !w_got && rdy;
        // ---- read ----
        if (hs_ar) begin
          ar_got = 1;
          r_wait = 1;
          r_dly = fast ? 0 : rnd(smaxd);
        end
        if (r_drop) rv <= 1'b0;
        else if (r_wait && !rv) begin
          if (re.c_b == -2) rv <= 1'b1;       // re-raise after a NEG_R drop (same data)
          else if (r_dly > 0) r_dly--;
          else if (blk == 0) begin
            re.slot = k;
            re.resp = rnd_resp();
            re.data = $urandom;
            rr <= re.resp;
            rd <= re.data;
            rv <= 1'b1;
          end
        end
        if (r_drop) re.c_b = -2;
        if (hs_r) begin
          rv <= 1'b0;
          ar_got = 0; r_wait = 0;
          re.c_a = -1; re.c_b = 0;
        end
        rdy = fast || (blk == 0 && $urandom_range(smaxd) == 0);
        arr <= !ar_got && rdy;
      end
    end
  end

  // ---------------- master-side monitors ----------------
  longint m_brise = -1, m_rrise = -1;
  bit p_bv = 0, p_rv = 0;
  logic [1:0] p_br, p_rr;
  logic [31:0] p_rd;
  bit wr_act = 0, rd_act = 0;
  longint n_conc = 0;
  always @(negedge clk)
    if (rst_n) begin
      if (p_bv && !(bvalid === 1'b1 && bresp === p_br))
        $error("TB_XB_HOLD master: BVALID / BRESP changed before BREADY");
      if (p_rv && !(rvalid === 1'b1 && rresp === p_rr && rdata === p_rd))
        $error("TB_XB_HOLD master: RVALID / RDATA / RRESP changed before RREADY");
      if ($isunknown({awready, wready, bvalid, arready, rvalid}))
        $error("TB_XB_X master: X on a master-side READY / VALID");
      p_bv = bvalid === 1'b1 && !bready; p_br = bresp;
      p_rv = rvalid === 1'b1 && !rready; p_rr = rresp; p_rd = rdata;
      if (bvalid === 1'b1 && m_brise < 0) m_brise = cyc;
      if (rvalid === 1'b1 && m_rrise < 0) m_rrise = cyc;
      if (wr_act && rd_act) n_conc++;
    end

  // ---------------- master driver ----------------
  longint n_cls_w[3] = '{0, 0, 0}, n_cls_r[3] = '{0, 0, 0}, n_ord[3] = '{0, 0, 0};
  longint n_b2b = 0, n_mlong = 0, n_wr = 0, n_rd = 0;

  // write: order 0 AW first, 1 W first, 2 same cycle; returns at the B handshake (negedge),
  // BREADY still 1 (dropped by the next call)
  task automatic m_write(logic [S_ADDR_W-1:0] a, int cls, bit b2b, output longint t_b);
    logic [31:0] d = $urandom;
    logic [3:0]  s = 4'($urandom);
    logic [2:0]  p = 3'($urandom);
    int order = b2b ? 2 : $urandom_range(2);
    int da = 0, dw = 0, dbr;
    bit lng = !b2b && $urandom_range(999) < long_pm;
    longint ca = -1, cw = -1, cb;
    bit hit = ref_hit(a);
    int k = ref_slot(a);
    @(posedge clk);
    bready <= 1'b0;
    wr_act = 1;
    if (!b2b) begin
      if (order == 0) dw = 1 + rnd(maxd + 1);
      if (order == 1) da = 1 + rnd(maxd + 1);
      if (order == 2) begin da = rnd(maxd); dw = da; end
    end
    n_ord[order]++;
    m_brise = -1;
    fork
      begin
        repeat (da) @(posedge clk);
        awaddr <= a; awprot <= p; awvalid <= 1'b1;
        do @(negedge clk); while (awready !== 1'b1);
        ca = cyc;
        @(posedge clk);
        awvalid <= 1'b0; awaddr <= S_ADDR_W'({$urandom, $urandom}); awprot <= 3'($urandom);
      end
      begin
        repeat (dw) @(posedge clk);
        wdata <= d; wstrb <= s; wvalid <= 1'b1;
        do @(negedge clk); while (wready !== 1'b1);
        cw = cyc;
        @(posedge clk);
        wvalid <= 1'b0; wdata <= $urandom; wstrb <= 4'($urandom);
      end
    join
    // negative: AWVALID / WVALID dropped before READY (READY is 0 until the B handshake)
    if (neg_aw_done < neg_aw && $urandom_range(3) == 0) begin
      awvalid <= 1'b1; awaddr <= S_ADDR_W'($urandom);
      @(posedge clk);
      awvalid <= 1'b0;
      neg_aw_done++;
    end else if (neg_w_done < neg_w && $urandom_range(3) == 0) begin
      wvalid <= 1'b1; wdata <= $urandom;
      @(posedge clk);
      wvalid <= 1'b0;
      neg_w_done++;
    end
    dbr = b2b ? 0 : (lng ? $urandom_range(400, 50) : rnd(maxd));
    if (lng) n_mlong++;
    repeat (dbr) @(posedge clk);
    bready <= 1'b1;
    do @(negedge clk); while (bvalid !== 1'b1);
    cb = cyc;
    #1;   // after the slave models and monitors of this negedge
    t_b = cb;
    wr_act = 0;
    n_wr++;
    if (b2b) n_b2b++;
    n_cls_w[cls]++;
    // ---- scoreboard ----
    if (hit) begin
      if (wr_log.size() != 1) c_wr.fail($sformatf("write 0x%0h (port %0d): %0d slave accesses logged", a, k, wr_log.size()));
      else begin
        ev_t e = wr_log.pop_front();
        if (e.slot != k || e.off !== a[11:0] || e.data !== d || e.strb !== s || e.prot !== p || bresp !== e.resp)
          c_wr.fail($sformatf("write 0x%0h: slave port %0d off 0x%0h data %h strb %h prot %0d resp %0d; expected port %0d off 0x%0h data %h strb %h prot %0d, master BRESP %0d",
                              a, e.slot, e.off, e.data, e.strb, e.prot, e.resp, k, a[11:0], d, s, p, bresp));
        else c_wr.pass();
        n_resp[e.resp]++;
        // cycle rules
        if (REG == 1) begin
          if (e.c_a != ca + 1 || e.c_w != (ca > cw ? ca : cw) + 1 || m_brise != e.c_b + 1)
            c_time.fail($sformatf("write 0x%0h REG 1: AW hs %0d W hs %0d -> slave AWVALID %0d WVALID %0d; slave B hs %0d -> BVALID %0d",
                                  a, ca, cw, e.c_a, e.c_w, e.c_b, m_brise));
          else c_time.pass();
        end else begin
          if (e.h_a != ca || e.h_w != cw || cw <= ca || cb != e.c_b)
            c_time.fail($sformatf("write 0x%0h REG 0: master AW %0d W %0d B %0d, slave AW %0d W %0d B %0d",
                                  a, ca, cw, cb, e.h_a, e.h_w, e.c_b));
          else c_time.pass();
        end
      end
    end else begin
      if (wr_log.size() != 0 || bresp !== 2'b00)
        c_wr.fail($sformatf("write 0x%0h (class %0d, no slave): %0d slave accesses, BRESP %0d", a, cls, wr_log.size(), bresp));
      else c_wr.pass();
      wr_log.delete();
      if (m_brise != (REG == 1 ? (ca > cw ? ca : cw) + 1 : cw + 1) || (REG == 0 && cw <= ca))
        c_time.fail($sformatf("write 0x%0h (no slave) REG %0d: AW hs %0d W hs %0d BVALID %0d", a, REG, ca, cw, m_brise));
      else c_time.pass();
    end
  endtask

  task automatic m_read(logic [S_ADDR_W-1:0] a, int cls, bit b2b, output longint t_r);
    logic [2:0] p = 3'($urandom);
    int da = b2b ? 0 : rnd(maxd), drr;
    bit lng = !b2b && $urandom_range(999) < long_pm;
    longint car, cr;
    bit hit = ref_hit(a);
    int k = ref_slot(a);
    @(posedge clk);
    rready <= 1'b0;
    rd_act = 1;
    m_rrise = -1;
    repeat (da) @(posedge clk);
    araddr <= a; arprot <= p; arvalid <= 1'b1;
    do @(negedge clk); while (arready !== 1'b1);
    car = cyc;
    @(posedge clk);
    arvalid <= 1'b0; araddr <= S_ADDR_W'({$urandom, $urandom}); arprot <= 3'($urandom);
    if (neg_ar_done < neg_ar && $urandom_range(3) == 0) begin
      arvalid <= 1'b1; araddr <= S_ADDR_W'($urandom);
      @(posedge clk);
      arvalid <= 1'b0;
      neg_ar_done++;
    end
    drr = b2b ? 0 : (lng ? $urandom_range(400, 50) : rnd(maxd));
    if (lng) n_mlong++;
    repeat (drr) @(posedge clk);
    rready <= 1'b1;
    do @(negedge clk); while (rvalid !== 1'b1);
    cr = cyc;
    #1;
    t_r = cr;
    rd_act = 0;
    n_rd++;
    if (b2b) n_b2b++;
    n_cls_r[cls]++;
    if (hit) begin
      if (rd_log.size() != 1) c_rd.fail($sformatf("read 0x%0h (port %0d): %0d slave accesses logged", a, k, rd_log.size()));
      else begin
        ev_t e = rd_log.pop_front();
        if (e.slot != k || e.off !== a[11:0] || e.prot !== p || rdata !== e.data || rresp !== e.resp)
          c_rd.fail($sformatf("read 0x%0h: slave port %0d off 0x%0h prot %0d data %h resp %0d; expected port %0d off 0x%0h prot %0d, master RDATA %h RRESP %0d",
                              a, e.slot, e.off, e.prot, e.data, e.resp, k, a[11:0], p, rdata, rresp));
        else c_rd.pass();
        n_resp[e.resp]++;
        if (REG == 1) begin
          if (e.c_a != car + 1 || m_rrise != e.c_b + 1)
            c_time.fail($sformatf("read 0x%0h REG 1: AR hs %0d -> slave ARVALID %0d; slave R hs %0d -> RVALID %0d", a, car, e.c_a, e.c_b, m_rrise));
          else c_time.pass();
        end else begin
          if (e.h_a != car || cr != e.c_b)
            c_time.fail($sformatf("read 0x%0h REG 0: master AR %0d R %0d, slave AR %0d R %0d", a, car, cr, e.h_a, e.c_b));
          else c_time.pass();
        end
      end
    end else begin
      if (rd_log.size() != 0 || rdata !== 32'd0 || rresp !== 2'b00)
        c_rd.fail($sformatf("read 0x%0h (class %0d, no slave): %0d slave accesses, RDATA %h RRESP %0d", a, cls, rd_log.size(), rdata, rresp));
      else c_rd.pass();
      rd_log.delete();
      if (m_rrise != car + 1) c_time.fail($sformatf("read 0x%0h (no slave): AR hs %0d RVALID %0d", a, car, m_rrise));
      else c_time.pass();
    end
  endtask

  task automatic wr_proc(int n);
    longint t;
    for (int i = 0; i < n; i++) begin
      int cls;
      logic [S_ADDR_W-1:0] a = gen_addr(cls);
      m_write(a, cls, $urandom_range(99) < b2b_pc, t);
    end
    @(posedge clk);
    bready <= 1'b0;
  endtask
  task automatic rd_proc(int n);
    longint t;
    for (int i = 0; i < n; i++) begin
      int cls;
      logic [S_ADDR_W-1:0] a = gen_addr(cls);
      m_read(a, cls, $urandom_range(99) < b2b_pc, t);
    end
    @(posedge clk);
    rready <= 1'b0;
  endtask

  // ---------------- measurement ----------------
  // period of n back-to-back transactions to address a (class cls), from the first to the last
  // response handshake, divided by n - 1
  task automatic perf(string what, bit wr, logic [S_ADDR_W-1:0] a, int cls, int n, output real per,
                      output longint lat);
    longint t0 = 0, t1 = 0, t;
    longint mn = 1 << 30, mx = 0, tp = 0;
    for (int i = 0; i < n; i++) begin
      if (wr) m_write(a, cls, 1'b1, t); else m_read(a, cls, 1'b1, t);
      if (i == 0) t0 = t;
      else begin
        if (t - tp < mn) mn = t - tp;
        if (t - tp > mx) mx = t - tp;
      end
      tp = t;
      t1 = t;
    end
    @(posedge clk);
    bready <= 1'b0; rready <= 1'b0;
    per = real'(t1 - t0) / real'(n - 1);
    lat = mn;
    if (mn != mx) c_time.fail($sformatf("XB_PERF %s: period not constant (%0d..%0d)", what, mn, mx));
    else c_time.pass();
    $display("XB_PERF REG=%0d %s: %0d transactions, period %0.2f cycles (%0.3f per cycle)", REG, what, n, per, 1.0 / per);
  endtask

  // ---------------- main ----------------
  initial begin
    automatic int unsigned seed;
    automatic int n_wr_req = 2000, n_rd_req = 2000, conc = 1, do_perf = 0;
    automatic longint wd = 0;
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("N_WR=%d", n_wr_req));
    void'($value$plusargs("N_RD=%d", n_rd_req));
    void'($value$plusargs("MAXD=%d", maxd));
    void'($value$plusargs("SMAXD=%d", smaxd));
    void'($value$plusargs("LONG=%d", long_pm));
    void'($value$plusargs("B2B=%d", b2b_pc));
    void'($value$plusargs("CONC=%d", conc));
    void'($value$plusargs("PERF=%d", do_perf));
    void'($value$plusargs("NEG_AW=%d", neg_aw));
    void'($value$plusargs("NEG_W=%d", neg_w));
    void'($value$plusargs("NEG_AR=%d", neg_ar));
    void'($value$plusargs("NEG_R=%d", neg_r));
    for (int k = 0; k < (1 << SLOT_W); k++)
      if (k < N && SLOT_EN[k]) present.push_back(k); else absent.push_back(k);
    $display("tb_axil_xbar: N %0d SLOT_W %0d S_ADDR_W %0d SLOT_EN 0x%0h REG %0d seed %0d; %0d writes, %0d reads, MAXD %0d SMAXD %0d LONG %0d B2B %0d CONC %0d",
             N, SLOT_W, S_ADDR_W, SLOT_EN, REG, seed, n_wr_req, n_rd_req, maxd, smaxd, long_pm, b2b_pc, conc);
    if (dut.LAT_REQ != REG || dut.LAT_RSP != REG)
      c_time.fail($sformatf("LAT_REQ %0d LAT_RSP %0d, expected %0d", dut.LAT_REQ, dut.LAT_RSP, REG));
    else c_time.pass();
    // watchdog
    fork
      begin
        repeat (200 * (n_wr_req + n_rd_req) + 200000) @(posedge clk);
        $fatal(1, "TB_WATCHDOG tb_axil_xbar: no end after %0d cycles", 200 * (n_wr_req + n_rd_req) + 200000);
      end
    join_none
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);
    if (conc) fork wr_proc(n_wr_req); rd_proc(n_rd_req); join
    else begin wr_proc(n_wr_req); rd_proc(n_rd_req); end
    repeat (20) @(posedge clk);
    if (wr_log.size() != 0 || rd_log.size() != 0 || wr_outs != 0 || rd_outs != 0)
      c_ord.fail($sformatf("end: logs %0d / %0d, outstanding %0d / %0d", wr_log.size(), rd_log.size(), wr_outs, rd_outs));
    else c_ord.pass();
    $display("tb_axil_xbar: writes %0d (present %0d, absent %0d, out of range %0d; AW first %0d, W first %0d, same %0d), reads %0d (%0d, %0d, %0d)",
             n_wr, n_cls_w[0], n_cls_w[1], n_cls_w[2], n_ord[0], n_ord[1], n_ord[2], n_rd, n_cls_r[0], n_cls_r[1], n_cls_r[2]);
    $display("tb_axil_xbar: back-to-back %0d, master long backpressure %0d, slave long blocks %0d, concurrent cycles %0d, slave responses OKAY %0d SLVERR %0d DECERR %0d",
             n_b2b, n_mlong, n_sblk, n_conc, n_resp[0], n_resp[2], n_resp[3]);
    // coverage of the random phase
    if (n_wr_req > 50 && n_rd_req > 50) begin
      if (n_cls_w[0] > 0 && n_cls_r[0] > 0 && (absent.size() == 0 || (n_cls_w[1] > 0 && n_cls_r[1] > 0)) &&
          (S_ADDR_W == 12 + SLOT_W || (n_cls_w[2] > 0 && n_cls_r[2] > 0)) && n_ord[0] > 0 && n_ord[1] > 0 &&
          n_ord[2] > 0 && (b2b_pc == 0 || n_b2b > 0) && (long_pm == 0 || (n_mlong > 0 && n_sblk > 0)) &&
          (!conc || n_conc > 0) && n_resp[0] > 0 && n_resp[2] > 0 && n_resp[3] > 0)
        c_cov.pass();
      else c_cov.fail("a coverage class was not reached (see the counts above)");
    end
    if (neg_aw != neg_aw_done || neg_w != neg_w_done || neg_ar != neg_ar_done || neg_r != neg_r_done)
      c_neg.fail($sformatf("injected AW %0d/%0d W %0d/%0d AR %0d/%0d R %0d/%0d", neg_aw_done, neg_aw,
                           neg_w_done, neg_w, neg_ar_done, neg_ar, neg_r_done, neg_r));
    else c_neg.pass();
    if (neg_aw + neg_w + neg_ar + neg_r > 0)
      $display("tb_axil_xbar: injected protocol violations AW %0d W %0d AR %0d R %0d", neg_aw_done, neg_w_done, neg_ar_done, neg_r_done);
    if (do_perf) begin
      automatic real p;
      automatic longint l;
      automatic logic [S_ADDR_W-1:0] ah = S_ADDR_W'(present[0]) << 12;
      fast = 1; maxd = 0; smaxd = 0; long_pm = 0;
      repeat (5) @(posedge clk);
      perf("read present", 1'b0, ah | 4, 0, 200, p, l);
      perf("write present", 1'b1, ah | 8, 0, 200, p, l);
      if (absent.size() > 0) begin
        automatic logic [S_ADDR_W-1:0] am = S_ADDR_W'(absent[0]) << 12;
        perf("read absent", 1'b0, am, 1, 200, p, l);
        perf("write absent", 1'b1, am, 1, 200, p, l);
      end
      // single-transaction latency (master handshake -> master response VALID) with a slave that
      // answers in the cycle after its request handshake
      begin
        automatic longint t;
        repeat (5) @(posedge clk);
        m_read(ah | 12, 0, 1'b1, t);
        $display("XB_PERF REG=%0d read latency: master AR handshake -> master RVALID %0d cycles (slave ARREADY 1, RVALID in the cycle after its AR)",
                 REG, m_rrise - rd_ar_cyc);
        m_write(ah | 16, 0, 1'b1, t);
        $display("XB_PERF REG=%0d write latency: last of the master AW / W handshakes -> master BVALID %0d cycles (slave BVALID in the cycle after its last handshake)",
                 REG, m_brise - wr_hs_cyc);
      end
      @(posedge clk);
      bready <= 1'b0;
      @(posedge clk);
      rready <= 1'b0;
    end
    repeat (10) @(posedge clk);
    void'(tb_final_report('{c_wr, c_rd, c_time, c_ord, c_cov, c_neg}));
    $finish;
  end

  // AR handshake cycle of the last read, last AW / W handshake of the last write (latency print)
  longint rd_ar_cyc = 0, wr_hs_cyc = 0;
  always @(negedge clk)
    if (rst_n) begin
      if (arvalid && arready) rd_ar_cyc = cyc;
      if ((awvalid && awready) || (wvalid && wready)) wr_hs_cyc = cyc;
    end

endmodule
