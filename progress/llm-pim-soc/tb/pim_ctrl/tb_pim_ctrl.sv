// tb_pim_ctrl: pim_ctrl (rtl/l1/pim_ctrl.sv) alone against a reference of the command sequences
// written from docs/spec/pim.md and model/src/bank.c (BANK_ROW, bimg_pack, bank_stat_t).
//
// The TB plays every neighbour of the controller: the command source (random gaps), the read
// engine (rd_cmd accepted after a random delay, then the row record beats of an LDW or the gb
// beats of a WRGB with random gaps), the write engine (wr_cmd accepted after a random delay, up to
// long blocks), pim_gb (gb_beat_i / gb_done_i), the banks (a shadow memory per bank fed by the
// write port) and the y pipeline (gather -> fixed delay -> FIFO -> random y_ready, y_pop_i).
// For every command the reference appends the expected items to in-order queues:
//   rd_cmd (addr, bytes), wr_cmd (addr, 4 rows), gb load n, bank writes (bank, word, data: row r
//   -> bank r mod NB at base + (r div NB) nw + w, lanes >= n zero, tag wm in word 0, then the zero
//   words of the empty slots of the last round), MAC reads (bank mask, word, first, last, gb word),
//   gathers (bank, last, xm, sh = we + xe - fo), events (bank_stat_t: mac = ceil(rows/NB) nw,
//   wrgb = ceil(n/32), rdmac = rows; one done pulse per command).
// Timing rules checked every cycle: the words of a round in consecutive cycles; last words of two
// rounds >= NB cycles apart; the gather of a round starts exactly L_BANK cycles after its last word
// and takes one bank per cycle; the y FIFO model never holds more than Y_DEPTH; busy_o / idle_o;
// the read command of a WRGB is presented in h + 1 and that of an LDW in h + 1 + LDW_CYC
// (h = handshake cycle, LDW_CYC = bits(NMAX/8 + 2) + 1: sequential length product, pim.md 5).
// +STALL=0 (no gaps, y_ready 1, engines accept at once): every MACAB's done_mac_o cycle equals the
// schedule formula (pim.md). +YBLK=1: long y_ready blocks, the credit limit must be reached.
// Records (+VEC): the LDW of the 36 matrices of the first position at the bimg_map bases, then the
// shadow banks must equal model/build/vec/pim/bank<b>.hex (bimg_pack image, 4,072 words) and the
// words above it must keep their prefill; then a MACAB per K_GEMV record (+MAXREC).
// Synthetic (+SYN=k): random LDW / WRGB / MACAB (rows 1..300 incl. non-multiples of NB, n 1..NMAX,
// random bases), back-to-back.
// Plusargs: +SEED +VEC +MAXREC +SYN +STALL +YBLK +NEG
`timescale 1ns / 1ps
module tb_pim_ctrl #(
  parameter int NB      = 4,
  parameter int Y_DEPTH = 32,
  parameter int L_BANK  = 5,
  parameter int DEPTH   = 4096
);
  import tb_util_pkg::*;
  import kdpi_pkg::*;
  import llm_pkg::*;

  localparam int LB = 16, NMAX = 1024, ROWS_W = 16, LS = 3;
  localparam int AA = $clog2(DEPTH), NW = $clog2(NMAX + 1), GA = $clog2(NMAX / LB);
  localparam int BI_W = $clog2(NB), WW = 8 * LB + 16;
  localparam int LDW_CYC = $clog2(NMAX / 8 + 2) + 1;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  // ---------------- DUT ----------------
  logic cmd_valid = 0, cmd_ready;
  logic [3:0] cmd_op = 0;
  logic [ROWS_W-1:0] cmd_rows = 0;
  logic [NW-1:0] cmd_n = 0;
  logic [AA-1:0] cmd_base = 0;
  logic [31:0] cmd_addr = 0;
  logic [AM_W-1:0] cmd_xm = 0;
  logic signed [E_W-1:0] cmd_we = 0, cmd_xe = 0, cmd_fo = 0;
  logic rdc_v, rdc_r = 0, wrc_v, wrc_r = 0;
  logic [31:0] rdc_a, rdc_b, wrc_a, wrc_b;
  logic ld_v = 0, ld_r;
  logic [63:0] ld_d = 0;
  logic gb_sel, gb_load, gb_beat = 0, gb_done = 0, gb_rd_en;
  logic [NW-1:0] gb_n;
  logic [GA-1:0] gb_rd_addr;
  logic [NB-1:0] bw_en, mr_en;
  logic [AA-1:0] bw_addr, mr_addr;
  logic [WW-1:0] bw_data;
  logic mr_first, mr_last, g_valid, g_last, y_pop = 0, busy, idle;
  logic [BI_W-1:0] g_sel;
  logic [AM_W-1:0] g_xm;
  logic signed [SH_W-1:0] g_sh;
  logic ev_mac, ev_wrgb, ev_rdmac, d_ldw, d_wrgb, d_mac;

  pim_ctrl #(.NB(NB), .LB(LB), .DEPTH(DEPTH), .NMAX(NMAX), .Y_DEPTH(Y_DEPTH), .L_BANK(L_BANK),
             .ROWS_W(ROWS_W)) dut (
    .clk, .rst_n,
    .cmd_valid_i(cmd_valid), .cmd_ready_o(cmd_ready), .cmd_op_i(cmd_op), .cmd_rows_i(cmd_rows),
    .cmd_n_i(cmd_n), .cmd_base_i(cmd_base), .cmd_addr_i(cmd_addr), .cmd_xm_i(cmd_xm),
    .cmd_we_i(cmd_we), .cmd_xe_i(cmd_xe), .cmd_fo_i(cmd_fo),
    .rd_cmd_valid_o(rdc_v), .rd_cmd_ready_i(rdc_r), .rd_cmd_addr_o(rdc_a), .rd_cmd_bytes_o(rdc_b),
    .wr_cmd_valid_o(wrc_v), .wr_cmd_ready_i(wrc_r), .wr_cmd_addr_o(wrc_a), .wr_cmd_bytes_o(wrc_b),
    .ld_valid_i(ld_v), .ld_ready_o(ld_r), .ld_data_i(ld_d),
    .gb_sel_o(gb_sel), .gb_load_o(gb_load), .gb_n_o(gb_n), .gb_beat_i(gb_beat), .gb_done_i(gb_done),
    .gb_rd_en_o(gb_rd_en), .gb_rd_addr_o(gb_rd_addr),
    .bw_en_o(bw_en), .bw_addr_o(bw_addr), .bw_data_o(bw_data),
    .mr_en_o(mr_en), .mr_addr_o(mr_addr), .mr_first_o(mr_first), .mr_last_o(mr_last),
    .g_valid_o(g_valid), .g_sel_o(g_sel), .g_last_o(g_last), .g_xm_o(g_xm), .g_sh_o(g_sh),
    .y_pop_i(y_pop), .busy_o(busy), .idle_o(idle), .ev_mac_o(ev_mac), .ev_wrgb_o(ev_wrgb),
    .ev_rdmac_o(ev_rdmac), .done_ldw_o(d_ldw), .done_wrgb_o(d_wrgb), .done_mac_o(d_mac));

  tb_checker c_cmd = new("eng_cmds"), c_bw = new("bank_writes"), c_mr = new("mac_reads"),
             c_g = new("gather"), c_ev = new("events"), c_tim = new("timing"), c_img = new("bank_image"),
             c_cyc = new("cycle_formula"), c_reach = new("limits");

  // ---------------- command description and reference ----------------
  typedef struct {
    int op, rows, n, base, xm, we, xe, fo;
    longint unsigned addr;
    byte w[];       // LDW: rows x n weights
    int  wm[];      // LDW: rows mantissas
    string tag;
  } cmd_t;

  typedef struct { longint unsigned a, b; } ecmd_t;
  typedef struct { int bank, addr; logic [WW-1:0] d; } ebw_t;
  typedef struct { logic [NB-1:0] mask; int addr, first, last, gw; } emr_t;
  typedef struct { int sel, last, xm, sh; } eg_t;

  ecmd_t q_rdc[$], q_wrc[$];
  int    q_gbn[$];
  ebw_t  q_bw[$];
  emr_t  q_mr[$];
  eg_t   q_g[$];
  int    q_done[$];           // op of each command, in order
  longint n_ev_mac = 0, n_ev_wrgb = 0, n_ev_rdmac = 0, x_ev_mac = 0, x_ev_wrgb = 0, x_ev_rdmac = 0;
  // LDW beat stream / WRGB beat count per read command (in order)
  typedef struct { int is_ld; logic [63:0] beats[$]; int ngb; } feed_t;
  feed_t q_feed[$];

  function automatic int cdiv(int a, int b); return (a + b - 1) / b; endfunction

  function automatic void reference(cmd_t c);
    int nw = cdiv(c.n, LB), nb8 = cdiv(c.n, 8), R = cdiv(c.rows, NB);
    case (c.op)
      1: begin
        feed_t f;
        f.is_ld = 1;
        f.ngb = 0;
        q_rdc.push_back('{c.addr, longint'(c.rows) * 8 * (1 + nb8)});
        for (int r = 0; r < c.rows; r++) begin
          f.beats.push_back({$urandom, 16'($urandom), 16'(c.wm[r])});      // garbage above wm
          for (int j = 0; j < nb8; j++) begin
            logic [63:0] b;
            for (int l = 0; l < 8; l++) b[8*l +: 8] = (8 * j + l < c.n) ? c.w[r * c.n + 8 * j + l] : 8'($urandom);
            f.beats.push_back(b);
          end
          for (int w = 0; w < nw; w++) begin
            logic [WW-1:0] d = '0;
            for (int l = 0; l < LB; l++) if (LB * w + l < c.n) d[8*l +: 8] = c.w[r * c.n + LB * w + l];
            if (w == 0) d[WW-1 -: 16] = 16'(c.wm[r]);
            q_bw.push_back('{r % NB, c.base + (r / NB) * nw + w, d});
          end
        end
        for (int r = c.rows; r < R * NB; r++)
          for (int w = 0; w < nw; w++) q_bw.push_back('{r % NB, c.base + (r / NB) * nw + w, '0});
        q_feed.push_back(f);
      end
      2: begin
        feed_t f;
        f.is_ld = 0;
        f.ngb = nb8;
        q_rdc.push_back('{c.addr, longint'(c.n)});
        q_gbn.push_back(c.n);
        q_feed.push_back(f);
        x_ev_wrgb += cdiv(c.n, 32);
      end
      3: begin
        q_wrc.push_back('{c.addr, 4 * longint'(c.rows)});
        for (int i = 0; i < R; i++) begin
          int nv = (i == R - 1) ? c.rows - (R - 1) * NB : NB;
          logic [NB-1:0] m = '0;
          for (int b = 0; b < nv; b++) m[b] = 1'b1;
          for (int w = 0; w < nw; w++) q_mr.push_back('{m, c.base + i * nw + w, w == 0, w == nw - 1, w});
          for (int b = 0; b < nv; b++) q_g.push_back('{b, i == R - 1 && b == nv - 1, c.xm, c.we + c.xe - c.fo});
        end
        x_ev_mac += R * nw;
        x_ev_rdmac += c.rows;
      end
      default: ;
    endcase
    q_done.push_back(c.op);
  endfunction

  // ---------------- environment ----------------
  int stall = 1, yblk = 0;
  longint cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // command source
  cmd_t cq[$];
  longint hs_t[$], hs_tl[$]; // cycle of each command handshake, last round word before it
  longint hs_cr[$], n_fskip = 0;  // credit-hold count at the handshake, formula checks skipped
  int     hs_op[$], hs_nw[$], hs_R[$];
  bit     cmd_hs_seen = 0, rdc_v_q = 0;
  longint t_prev_round_last = -1000;
  longint n_credit = 0;      // cycles a round waits for y credit
  int     tb_res = 0;        // y rows reserved (round starts) and not yet popped
  bit     exp_busy = 0;
  task automatic cmd_driver();
    forever begin
      @(posedge clk);
      if (!cmd_valid || cmd_hs_seen) begin
        cmd_hs_seen = 0;
        if (cq.size() == 0 || (stall && $urandom_range(3) == 0)) begin
          cmd_valid <= 1'b0;
          cmd_op <= 4'($urandom); cmd_rows <= ROWS_W'($urandom); cmd_n <= NW'($urandom);
          cmd_addr <= $urandom; cmd_base <= AA'($urandom);
        end else begin
          automatic cmd_t c = cq.pop_front();
          reference(c);
          cmd_valid <= 1'b1;
          cmd_op <= 4'(c.op); cmd_rows <= ROWS_W'(c.rows); cmd_n <= NW'(c.n); cmd_base <= AA'(c.base);
          cmd_addr <= 32'(c.addr); cmd_xm <= AM_W'(c.xm); cmd_we <= E_W'(c.we); cmd_xe <= E_W'(c.xe);
          cmd_fo <= E_W'(c.fo);
        end
      end
    end
  endtask

  // read engine + LDW stream + gb model
  task automatic rd_driver();
    forever begin
      @(posedge clk);
      rdc_r <= 1'b0;
      if (rdc_v && (!stall || $urandom_range(2) == 0)) begin
        automatic feed_t f;
        rdc_r <= 1'b1;
        @(posedge clk);
        rdc_r <= 1'b0;
        if (q_feed.size() == 0) begin c_cmd.fail("read command without a command"); continue; end
        f = q_feed.pop_front();
        if (f.is_ld) begin
          while (f.beats.size() > 0) begin
            if (stall && $urandom_range(3) == 0) begin
              ld_v <= 1'b0; ld_d <= {$urandom, $urandom};
              @(posedge clk);
              continue;
            end
            ld_v <= 1'b1;
            ld_d <= f.beats[0];
            do @(negedge clk); while (ld_r !== 1'b1);
            void'(f.beats.pop_front());
            @(posedge clk);
          end
          ld_v <= 1'b0;
        end else begin
          for (int j = 0; j < f.ngb; j++) begin
            while (stall && $urandom_range(3) == 0) begin gb_beat <= 1'b0; gb_done <= 1'b0; @(posedge clk); end
            gb_beat <= 1'b1;
            gb_done <= j == f.ngb - 1;
            @(posedge clk);
          end
          gb_beat <= 1'b0;
          gb_done <= 1'b0;
        end
      end
    end
  endtask

  // write engine
  int wblk = 0;
  task automatic wr_driver();
    forever begin
      @(posedge clk);
      wrc_r <= 1'b0;
      if (wrc_v) begin
        if (stall) repeat ($urandom_range(9) == 0 ? $urandom_range(300) : $urandom_range(3)) @(posedge clk);
        wrc_r <= 1'b1;
        @(posedge clk);
        wrc_r <= 1'b0;
      end
    end
  endtask

  // y pipeline model: gather -> LS + 1 cycles -> FIFO -> random ready
  longint ypipe[$];           // arrival cycles
  int yfifo = 0, ymax = 0;
  longint n_full = 0;
  bit yblock = 0;

  // ---------------- monitor ----------------
  longint t_lastw = -1000, t_round_first = -1, t_prev_read = -1000;
  longint g_exp_t[$];
  int     cur_op = 0;
  longint n_hs = 0, n_bw = 0, n_mr = 0, n_g = 0;
  // shadow banks
  logic [WW-1:0] shadow [NB][int];

  always @(negedge clk) if (rst_n) begin
    // ---- command handshake ----
    if (cmd_valid && cmd_ready) begin
      cmd_hs_seen = 1;
      hs_t.push_back(cyc);
      hs_tl.push_back(t_prev_round_last);
      hs_cr.push_back(n_credit);
      hs_op.push_back(cmd_op);
      hs_nw.push_back(cdiv(cmd_n, LB));
      hs_R.push_back(cdiv(cmd_rows, NB));
      n_hs++;
    end
    // ---- engine commands ----
    if (rdc_v === 1'b1 && !rdc_v_q) begin
      automatic longint h = hs_t.size() > 0 ? hs_t[$] : -1;
      automatic int op = hs_op.size() > 0 ? hs_op[$] : 0;
      if (cyc != h + 1 + (op == 1 ? LDW_CYC : 0))
        c_tim.fail($sformatf("read command of op %0d presented in cycle %0d, handshake %0d", op, cyc, h));
      else c_tim.pass();
    end
    rdc_v_q = rdc_v === 1'b1;
    if (rdc_v && rdc_r) begin
      if (q_rdc.size() == 0) c_cmd.fail("unexpected rd_cmd");
      else begin
        automatic ecmd_t e = q_rdc.pop_front();
        if (rdc_a !== 32'(e.a) || rdc_b !== 32'(e.b)) c_cmd.fail($sformatf("rd_cmd %h %0d, expected %h %0d", rdc_a, rdc_b, e.a, e.b));
        else c_cmd.pass();
      end
    end
    if (wrc_v && wrc_r) begin
      if (q_wrc.size() == 0) c_cmd.fail("unexpected wr_cmd");
      else begin
        automatic ecmd_t e = q_wrc.pop_front();
        if (wrc_a !== 32'(e.a) || wrc_b !== 32'(e.b)) c_cmd.fail($sformatf("wr_cmd %h %0d, expected %h %0d", wrc_a, wrc_b, e.a, e.b));
        else c_cmd.pass();
      end
    end
    if (gb_load) begin
      if (q_gbn.size() == 0) c_cmd.fail("unexpected gb_load_o");
      else begin
        automatic int e = q_gbn.pop_front();
        if (int'(gb_n) != e || !(cmd_valid && cmd_ready)) c_cmd.fail($sformatf("gb_load n %0d, expected %0d (in the handshake cycle)", gb_n, e));
        else c_cmd.pass();
      end
    end
    if (gb_beat && !gb_sel) c_cmd.fail("gb beat while gb_sel_o = 0");
    // ---- bank writes ----
    if (bw_en != '0) begin
      if ($countones(bw_en) != 1) c_bw.fail($sformatf("bw_en %b", bw_en));
      else if (q_bw.size() == 0) c_bw.fail("unexpected bank write");
      else begin
        automatic ebw_t e = q_bw.pop_front();
        automatic int b = $clog2(bw_en);
        if (b != e.bank || int'(bw_addr) != e.addr || bw_data !== e.d)
          c_bw.fail($sformatf("write bank %0d word %0d %h, expected %0d %0d %h", b, bw_addr, bw_data, e.bank, e.addr, e.d));
        else c_bw.pass();
        shadow[b][int'(bw_addr)] = bw_data;
        n_bw++;
      end
      if (mr_en != '0) c_bw.fail("bank write and MAC read in the same cycle");
    end
    // ---- MAC reads ----
    if (mr_en != '0 || gb_rd_en) begin
      if (q_mr.size() == 0) c_mr.fail("unexpected MAC read");
      else begin
        automatic emr_t e = q_mr.pop_front();
        if (mr_en !== e.mask || int'(mr_addr) != e.addr || mr_first !== 1'(e.first) || mr_last !== 1'(e.last) ||
            !gb_rd_en || int'(gb_rd_addr) != e.gw)
          c_mr.fail($sformatf("read mask %b word %0d first %b last %b gb %b/%0d, expected %b %0d %0d %0d %0d",
                              mr_en, mr_addr, mr_first, mr_last, gb_rd_en, gb_rd_addr, e.mask, e.addr, e.first, e.last, e.gw));
        else c_mr.pass();
        // timing: words of a round consecutive, last words >= NB apart, gather after L_BANK
        if (!mr_first && t_prev_read != cyc - 1) c_tim.fail($sformatf("word read in %0d not right after %0d", cyc, t_prev_read));
        else c_tim.pass();
        if (mr_last) begin
          automatic int nv = $countones(mr_en);
          if (cyc - t_lastw < NB) c_tim.fail($sformatf("round last words %0d and %0d closer than NB", t_lastw, cyc));
          else c_tim.pass();
          t_lastw = cyc;
          for (int b = 0; b < nv; b++) g_exp_t.push_back(cyc + L_BANK + b);
        end
        t_prev_read = cyc;
        n_mr++;
      end
    end
    // ---- gather ----
    if (g_valid) begin
      if (q_g.size() == 0 || g_exp_t.size() == 0) c_g.fail("unexpected gather");
      else begin
        automatic eg_t e = q_g.pop_front();
        automatic longint et = g_exp_t.pop_front();
        if (int'(g_sel) != e.sel || g_last !== 1'(e.last) || int'(g_xm) != e.xm || int'(g_sh) != e.sh)
          c_g.fail($sformatf("gather bank %0d last %b xm %h sh %0d, expected %0d %0d %h %0d", g_sel, g_last, g_xm, g_sh, e.sel, e.last, e.xm, e.sh));
        else c_g.pass();
        if (cyc != et) c_tim.fail($sformatf("gather in %0d, expected %0d", cyc, et)); else c_tim.pass();
        ypipe.push_back(cyc + LS + 1);
        n_g++;
      end
    end
    // ---- events ----
    if (ev_mac !== (mr_en != '0)) c_ev.fail("ev_mac_o differs from a MAC read");
    if (ev_rdmac !== g_valid) c_ev.fail("ev_rdmac_o differs from a gather");
    n_ev_mac += ev_mac;
    n_ev_wrgb += ev_wrgb;
    n_ev_rdmac += ev_rdmac;
    if (d_ldw || d_wrgb || d_mac) begin
      automatic int op = d_ldw ? 1 : d_wrgb ? 2 : 3;
      if (int'(d_ldw) + int'(d_wrgb) + int'(d_mac) != 1) c_ev.fail("two done pulses in one cycle");
      if (q_done.size() == 0) c_ev.fail("done pulse without a command");
      else begin
        automatic int e = q_done.pop_front();
        if (e != op) c_ev.fail($sformatf("done of op %0d, expected op %0d", op, e)); else c_ev.pass();
      end
      // the done pulse comes with the command's last action
      if (d_ldw && bw_en == '0) c_ev.fail("done_ldw_o without the last bank write");
      if (d_wrgb && !gb_done) c_ev.fail("done_wrgb_o without gb_done_i");
      if (d_mac && !(mr_last && mr_en != '0)) c_ev.fail("done_mac_o without the last MAC read");
      if (d_mac && !stall && hs_op.size() > 0 && n_credit != hs_cr[$]) n_fskip++;
      else if (d_mac && !stall && hs_op.size() > 0) begin
        // schedule formula (no stalls): first word max(hs + 1, last word of the previous round + NB - (nw - 1)),
        // then rounds every max(nw, NB) cycles
        automatic int nw = hs_nw[$], R = hs_R[$], P = nw > NB ? nw : NB;
        automatic longint t0 = hs_t[$] + 1, f;
        if (hs_tl[$] + NB - (nw - 1) > t0) t0 = hs_tl[$] + NB - (nw - 1);
        f = t0 + longint'(R - 1) * P + nw - 1;
        if (f != cyc) c_cyc.fail($sformatf("MACAB nw %0d R %0d hs %0d: done_mac in %0d, formula %0d", nw, R, hs_t[$], cyc, f));
        else c_cyc.pass();
      end
    end
    if (mr_last && mr_en != '0) t_prev_round_last = cyc;
    // ---- y FIFO model ----
    while (ypipe.size() > 0 && ypipe[0] <= cyc) begin void'(ypipe.pop_front()); yfifo++; end
    if (yfifo > ymax) ymax = yfifo;
    if (yfifo > Y_DEPTH) c_tim.fail($sformatf("y FIFO model holds %0d > Y_DEPTH", yfifo));
    if (yfifo + ypipe.size() >= Y_DEPTH - NB + 1) n_full++;
    // ---- busy / idle (state of this cycle, then this cycle's updates) ----
    if (busy !== exp_busy) c_tim.fail($sformatf("busy_o %b, expected %b at %0d", busy, exp_busy, cyc));
    if (idle !== (!exp_busy && tb_res == 0 && !wrc_v))
      c_tim.fail($sformatf("idle_o %b at %0d (reserved %0d, wr_cmd %b)", idle, cyc, tb_res, wrc_v));
    if (cmd_valid && cmd_ready && cmd_op >= 1 && cmd_op <= 3) exp_busy = 1;
    if (d_ldw || d_wrgb || d_mac) exp_busy = 0;
    if (mr_first && mr_en != '0) tb_res += $countones(mr_en);
    if (y_pop) tb_res--;
    // a round start held by the y credit
    if (int'(dut.state_q) == 4 && dut.m_first && 32'(dut.yres_q) + 32'(dut.m_nv) > Y_DEPTH) n_credit++;
  end

  // y_ready / y_pop: posedge
  always @(posedge clk) begin
    automatic bit rdy = !stall || (!yblock && $urandom_range(3) != 0);
    y_pop <= 1'b0;
    if (rst_n && yfifo > 0 && rdy) begin
      y_pop <= 1'b1;
      yfifo--;    // popped in the coming cycle
    end
  end

  task automatic yblocker();
    forever begin
      repeat ($urandom_range(3000, 300)) @(posedge clk);
      yblock = 1;
      repeat ($urandom_range(800, 100)) @(posedge clk);
      yblock = 0;
    end
  endtask

  // ---------------- scenarios ----------------
  function automatic cmd_t syn_cmd(int op);
    cmd_t c;
    int k = $urandom_range(9);
    c.op = op;
    c.n = k < 3 ? $urandom_range(48, 1) : (k == 3 ? NMAX : $urandom_range(NMAX, 1));
    c.rows = k == 4 ? $urandom_range(3, 1) : (k == 5 ? NB * $urandom_range(40, 1) : $urandom_range(300, 1));
    begin
      int used = cdiv(c.rows, NB) * cdiv(c.n, LB);
      while (used > DEPTH) begin c.rows = c.rows / 2 + 1; used = cdiv(c.rows, NB) * cdiv(c.n, LB); end
      c.base = $urandom_range(3) == 0 ? DEPTH - used : $urandom_range(DEPTH - used);
    end
    c.addr = 8 * longint'($urandom_range(32'h0FFF_FFFF));
    c.xm = $urandom_range((1 << AM_W) - 1);
    c.we = int'($urandom_range(255)) - 128; c.xe = int'($urandom_range(255)) - 128; c.fo = int'($urandom_range(255)) - 128;
    if (op == 1) begin
      c.w = new[c.rows * c.n];
      c.wm = new[c.rows];
      foreach (c.w[i]) c.w[i] = byte'($urandom);
      foreach (c.wm[i]) c.wm[i] = $urandom_range(65535);
    end
    c.tag = $sformatf("syn op %0d", op);
    return c;
  endfunction

  typedef struct { string name; int rows, n, base, words, we; } bm_t;
  bm_t bmap[$];

  function automatic int read_bmap(string f);
    int fd = $fopen(f, "r");
    string line, nm;
    int rows, n, nw, base, words, we;
    if (fd == 0) return -1;
    while (!$feof(fd)) begin
      line = "";
      void'($fgets(line, fd));
      if (line.len() < 4 || line.substr(0, 3) != "mat ") continue;
      if ($sscanf(line, "mat %s %d %d %d %d %d %d", nm, rows, n, nw, base, words, we) == 7)
        bmap.push_back('{nm, rows, n, base, words, we});
    end
    $fclose(fd);
    return bmap.size();
  endfunction

  task automatic wait_drain();
    longint t0 = cyc;
    while (cq.size() != 0 || q_done.size() != 0 || q_g.size() != 0 || !idle || yfifo != 0) begin
      @(posedge clk);
      if (cyc - t0 > 5_000_000) begin c_tim.fail("WATCHDOG: commands do not finish"); break; end
    end
    repeat (3) @(posedge clk);
  endtask

  task automatic run_records(string vdir, int maxrec);
    int nm, nrec = 0;
    logic [WW-1:0] hw [NB][$];
    string pimdir = {vdir, "/../pim"};
    nm = read_bmap({pimdir, "/bimg_map.txt"});
    if (nm != 36) begin c_img.fail("bimg_map.txt"); return; end
    // prefill the shadow banks (words above the image must keep it)
    for (int b = 0; b < NB; b++) for (int a = 0; a < DEPTH; a++) shadow[b][a] = {5{$urandom}};
    begin
      logic [WW-1:0] pre [NB][int];
      for (int b = 0; b < NB; b++) for (int a = 0; a < DEPTH; a++) pre[b][a] = shadow[b][a];
      // LDW of the 36 matrices of the first position, data from the records (golden packer)
      if (kd_rec_open({vdir, "/gemv.bin"}) != 0) begin c_img.fail("gemv.bin"); return; end
      for (int m = 0; m < 36 && kd_rec_next() == K_GEMV; m++) begin
        cmd_t c;
        c.op = 1; c.rows = kd_rec_prm(0); c.n = kd_rec_prm(1); c.base = bmap[m].base;
        c.addr = 64'h1000_0000 + 8 * m * 4096;
        c.w = new[c.rows * c.n];
        c.wm = new[c.rows];
        void'(kd_rec_bytes(0, 0, c.w, c.rows * c.n));
        foreach (c.wm[r]) c.wm[r] = kd_rec_getu(1, r);
        if (c.rows != bmap[m].rows || c.n != bmap[m].n) c_img.fail($sformatf("matrix %0d does not match the map", m));
        c.tag = bmap[m].name;
        cq.push_back(c);
      end
      void'(kd_rec_close());
      wait_drain();
      // shadow == bimg image (bank<b>.hex), words above the image unchanged
      for (int b = 0; b < NB; b++) begin
        int fd = $fopen($sformatf("%s/bank%0d.hex", pimdir, b), "r");
        int a = 0, bad = 0;
        logic [WW-1:0] v;
        if (fd == 0) begin c_img.fail($sformatf("bank%0d.hex", b)); continue; end
        while ($fscanf(fd, "%h", v) == 1) begin
          automatic logic [WW-1:0] e = a < 4072 ? v : pre[b][a];
          if (shadow[b][a] !== e) begin
            bad++;
            if (bad <= 3) c_img.fail($sformatf("bank %0d word %0d: %h, expected %h", b, a, shadow[b][a], e));
          end
          a++;
        end
        $fclose(fd);
        if (a != DEPTH) c_img.fail($sformatf("bank%0d.hex has %0d words", b, a));
        if (bad == 0) c_img.pass();
      end
    end
    // MACAB per record (the sequences do not depend on the data)
    if (kd_rec_open({vdir, "/gemv.bin"}) != 0) return;
    while ((maxrec == 0 || nrec < maxrec) && kd_rec_next() == K_GEMV) begin
      cmd_t c;
      bm_t m = bmap[nrec % 36];
      c.op = 3; c.rows = kd_rec_prm(0); c.n = kd_rec_prm(1); c.base = m.base;
      c.we = kd_rec_prm(3); c.xm = kd_rec_prm(4); c.xe = kd_rec_prm(5); c.fo = kd_rec_prm(6);
      c.addr = 64'h3000_0000 + 8 * $urandom_range(4095);
      c.tag = m.name;
      if (nrec % 36 == 0 || m.name.substr(0, 1) == "wq" || m.name.substr(0, 1) == "wo" ||
          m.name.substr(0, 1) == "w1" || m.name.substr(0, 1) == "w2" || m.name == "cls") begin
        cmd_t x;
        x.op = 2; x.n = c.n; x.addr = 64'h2000_0000 + 8 * nrec; x.tag = "wrgb";
        x.rows = 0; x.base = 0;
        cq.push_back(x);       // WRGB before each group of matrices with the same x (layer order)
      end
      cq.push_back(c);
      nrec++;
      if (cq.size() > 40) wait_drain();
    end
    void'(kd_rec_close());
    wait_drain();
    $display("records: %0d MACAB", nrec);
  endtask

  task automatic run_syn(int nsyn);
    for (int s = 0; s < nsyn; s++) begin
      int k = $urandom_range(9);
      cq.push_back(syn_cmd(k < 2 ? 1 : (k < 4 ? 2 : 3)));
      if (cq.size() > 20) wait_drain();
    end
    wait_drain();
  endtask

  int unsigned seed;
  string vdir = "";
  int maxrec = 0, nsyn = 0, neg = 0;

  initial begin
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("VEC=%s", vdir));
    void'($value$plusargs("MAXREC=%d", maxrec));
    void'($value$plusargs("SYN=%d", nsyn));
    void'($value$plusargs("STALL=%d", stall));
    void'($value$plusargs("YBLK=%d", yblk));
    void'($value$plusargs("NEG=%d", neg));
    $display("tb_pim_ctrl: NB %0d Y_DEPTH %0d L_BANK %0d DEPTH %0d SEED %0d VEC %s MAXREC %0d SYN %0d STALL %0d YBLK %0d NEG %0d",
             NB, Y_DEPTH, L_BANK, DEPTH, seed, vdir, maxrec, nsyn, stall, yblk, neg);
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    repeat (2) @(posedge clk);
    if (neg) begin       // an illegal command reaching the controller: PIM_RANGE once, dropped
      @(posedge clk);
      cmd_valid <= 1'b1; cmd_op <= 4'd7; cmd_rows <= 4; cmd_n <= 16; cmd_base <= 0;
      @(posedge clk);
      cmd_valid <= 1'b0;
      repeat (10) @(posedge clk);
      if (busy !== 1'b0) c_cmd.fail("illegal op not dropped"); else c_cmd.pass();
      void'(tb_final_report('{c_cmd}));
      $finish;
    end
    fork cmd_driver(); rd_driver(); wr_driver(); join_none
    if (yblk) fork yblocker(); join_none
    if (vdir != "") run_records(vdir, maxrec);
    if (nsyn > 0) run_syn(nsyn);
    repeat (20) @(posedge clk);
    $display("rounds held by the y credit: %0d cycles; MACAB formula checks skipped (credit held): %0d", n_credit, n_fskip);
    $display("events: mac %0d/%0d wrgb %0d/%0d rdmac %0d/%0d; bank writes %0d, MAC reads %0d, gathers %0d, y FIFO max %0d, near-full cycles %0d",
             n_ev_mac, x_ev_mac, n_ev_wrgb, x_ev_wrgb, n_ev_rdmac, x_ev_rdmac, n_bw, n_mr, n_g, ymax, n_full);
    if (n_ev_mac != x_ev_mac || n_ev_wrgb != x_ev_wrgb || n_ev_rdmac != x_ev_rdmac) c_ev.fail("event counts (bank_stat_t)");
    else c_ev.pass();
    if (q_bw.size() || q_mr.size() || q_g.size() || q_rdc.size() || q_wrc.size() || q_done.size())
      c_tim.fail($sformatf("expected items left: bw %0d mr %0d g %0d rdc %0d wrc %0d done %0d",
                           q_bw.size(), q_mr.size(), q_g.size(), q_rdc.size(), q_wrc.size(), q_done.size()));
    if (yblk) begin
      if (n_credit == 0) c_reach.fail($sformatf("YBLK: no round waited for y credit (y FIFO max %0d)", ymax));
      else c_reach.pass();
    end
    begin
      automatic tb_checker_q chks;
      chks.push_back(c_cmd); chks.push_back(c_ev); chks.push_back(c_tim);
      if (n_bw > 0 || vdir != "") chks.push_back(c_bw);
      chks.push_back(c_mr); chks.push_back(c_g);
      if (vdir != "") chks.push_back(c_img);
      if (!stall) chks.push_back(c_cyc);
      if (yblk) chks.push_back(c_reach);
      void'(tb_final_report(chks));
    end
    $finish;
  end

  initial begin
    #5s;
    $error("TB_TIMEOUT global");
    $finish;
  end
endmodule
