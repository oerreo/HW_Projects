// tb_pim_core: pim_core (rtl/l2/pim_core.sv) at its stream boundary.
// The TB is the read engine (rd_cmd accepted after a random delay, then ceil(bytes/8) beats from a
// byte memory with random gaps), the write engine (wr_cmd accepted after a random delay, y popped
// with random y_ready, +YBLK long blocks) and the command source.
// Golden (nothing from the RTL):
//   bank RAM   after the LDW of the 36 260K matrices (row records model/build/vec/m1/rrec.bin at
//              the bimg_map.txt bases): every bank RAM == model/build/vec/pim/bank<b>.hex
//              (bimg_pack) for the 4,072 used words, the words above keep their random prefill.
//   y          K_GEMV records (recorded y), or synthetic matrices through kd_bank_syn
//              (bank_pack BANK_ROW + bank_gemv of model/src/bank.c; also compared with kd_gemv1).
//   counts     events per command vs bank_stat_t of the same call (kd_rec_bank / kd_bank_syn):
//              mac, rdmac per MACAB; wrgb per WRGB (bank_gemv counts ceil(n/32) per call).
//   order      y_last on the last y of every MACAB, y count = rows, wr_cmd (addr, 4 rows),
//              rd_cmd (addr, bytes).
// Call orders: +LAYER=1 (default): per position, the arch.md 3.3 order: WRGB, MACAB q k v /
// WRGB, MACAB o / WRGB, MACAB w1 w3 / WRGB, MACAB w2 per layer, WRGB, MACAB cls (the TB checks that
// the records of a group carry the same x). +LAYER=0: WRGB + MACAB per record.
// +STALL=0: no gaps, everything accepted at once; every MACAB's last y must be valid exactly in the
// cycle of the formula (docs/spec/pim.md), and per position the sum of R nw (= 4,072) and the
// MACAB / total cycles are printed.
// +SYN=k synthetic groups: LDW (rows 1..300, n 1..NMAX, random base), WRGB, 1..3 MACABs.
// Plusargs: +SEED +VEC +MAXPOS +LAYER +SYN +STALL +YBLK +GAP
`timescale 1ns / 1ps
module tb_pim_core #(
  parameter int NB         = 4,
  parameter int DEPTH      = 4096,
  parameter int DOT_PIPE   = 2,
  parameter int SCALE_PIPE = 3,
  parameter int Y_DEPTH    = 32
);
  import tb_util_pkg::*;
  import kdpi_pkg::*;
  import llm_pkg::*;

  localparam int LB = 16, NMAX = 1024, ROWS_W = 16, AA = $clog2(DEPTH), NW = $clog2(NMAX + 1);
  localparam int WW = 8 * LB + 16, L_BANK = 3 + DOT_PIPE, L_S = SCALE_PIPE;
  localparam longint unsigned W_BASE = 64'h1000_0000, X_BASE = 64'h2000_0000, Y_BASE = 64'h3000_0000,
                              SW_BASE = 64'h0800_0000;

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
  logic rdc_v, rdc_r = 0, wrc_v, wrc_r = 0, d_v = 0, d_r, y_v, y_r = 0, y_last;
  logic [31:0] rdc_a, rdc_b, wrc_a, wrc_b, y_d;
  logic [63:0] d_d = 0;
  logic busy, rd_stall, ev_mac, ev_wrgb, ev_rdmac, d_ldw, d_wrgb, d_mac;

  pim_core #(.NB(NB), .LB(LB), .DEPTH(DEPTH), .NMAX(NMAX), .DOT_PIPE(DOT_PIPE),
             .SCALE_PIPE(SCALE_PIPE), .Y_DEPTH(Y_DEPTH), .ROWS_W(ROWS_W)) dut (
    .clk, .rst_n,
    .cmd_valid_i(cmd_valid), .cmd_ready_o(cmd_ready), .cmd_op_i(cmd_op), .cmd_rows_i(cmd_rows),
    .cmd_n_i(cmd_n), .cmd_base_i(cmd_base), .cmd_addr_i(cmd_addr), .cmd_xm_i(cmd_xm),
    .cmd_we_i(cmd_we), .cmd_xe_i(cmd_xe), .cmd_fo_i(cmd_fo),
    .rd_cmd_valid_o(rdc_v), .rd_cmd_ready_i(rdc_r), .rd_cmd_addr_o(rdc_a), .rd_cmd_bytes_o(rdc_b),
    .d_valid_i(d_v), .d_ready_o(d_r), .d_data_i(d_d),
    .wr_cmd_valid_o(wrc_v), .wr_cmd_ready_i(wrc_r), .wr_cmd_addr_o(wrc_a), .wr_cmd_bytes_o(wrc_b),
    .y_valid_o(y_v), .y_ready_i(y_r), .y_data_o(y_d), .y_last_o(y_last),
    .busy_o(busy), .rd_stall_o(rd_stall), .ev_mac_o(ev_mac), .ev_wrgb_o(ev_wrgb),
    .ev_rdmac_o(ev_rdmac), .done_ldw_o(d_ldw), .done_wrgb_o(d_wrgb), .done_mac_o(d_mac));

  tb_checker c_y = new("y"), c_img = new("bank_image"), c_cnt = new("bank_stat"),
             c_ord = new("streams"), c_cyc = new("cycle_formula"), c_x = new("same_x"),
             c_reach = new("limits");

  // ---------------- DDR model ----------------
  byte unsigned ddr [longint unsigned];
  function automatic byte unsigned m8(longint unsigned a);
    return ddr.exists(a) ? ddr[a] : 8'hA5;
  endfunction

  // ---------------- commands ----------------
  typedef struct {
    int op, rows, n, base, xm, we, xe, fo;
    longint unsigned addr;
    int ey[$];                  // MACAB: expected y
    longint st[3];              // expected bank_stat (wrgb, mac, rdmac) of this command
    string tag;
  } cmd_t;
  cmd_t cq[$];                  // to be issued
  cmd_t amq[$], aoq[$];         // issued MACABs / LDW and WRGB, waiting for completion (in order)
  bit   hs_seen = 0;
  typedef struct { longint unsigned a, b; } ecmd_t;
  ecmd_t q_rdc[$], q_wrc[$];

  int stall = 1, yblk = 0, gap = 25;
  longint cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  // command source
  task automatic cmd_driver();
    forever begin
      @(posedge clk);
      if (!cmd_valid || hs_seen) begin
        hs_seen = 0;
        if (cq.size() == 0 || (stall && $urandom_range(4) == 0)) begin
          cmd_valid <= 1'b0;
          cmd_op <= 4'($urandom); cmd_rows <= ROWS_W'($urandom); cmd_n <= NW'($urandom);
        end else begin
          automatic cmd_t c = cq.pop_front();
          if (c.op == 1) q_rdc.push_back('{c.addr, longint'(c.rows) * 8 * (1 + (c.n + 7) / 8)});
          if (c.op == 2) q_rdc.push_back('{c.addr, longint'(c.n)});
          if (c.op == 3) q_wrc.push_back('{c.addr, 4 * longint'(c.rows)});
          if (c.op == 3) amq.push_back(c); else aoq.push_back(c);
          cmd_valid <= 1'b1;
          cmd_op <= 4'(c.op); cmd_rows <= ROWS_W'(c.rows); cmd_n <= NW'(c.n); cmd_base <= AA'(c.base);
          cmd_addr <= 32'(c.addr); cmd_xm <= AM_W'(c.xm); cmd_we <= E_W'(c.we); cmd_xe <= E_W'(c.xe);
          cmd_fo <= E_W'(c.fo);
        end
      end
    end
  endtask

  // read engine
  task automatic rd_driver();
    forever begin
      @(posedge clk);
      rdc_r <= 1'b0;
      if (rdc_v && (!stall || $urandom_range(3) == 0)) begin
        automatic longint unsigned a = rdc_a, nb = (longint'(rdc_b) + 7) / 8;
        rdc_r <= 1'b1;
        @(posedge clk);
        rdc_r <= 1'b0;
        if (stall) repeat ($urandom_range(6)) @(posedge clk);
        for (longint j = 0; j < nb; j++) begin
          automatic logic [63:0] b;
          for (int l = 0; l < 8; l++) b[8*l +: 8] = m8(a + 8 * j + l);
          while (stall && $urandom_range(99) < gap) begin
            d_v <= 1'b0; d_d <= {$urandom, $urandom};
            @(posedge clk);
          end
          d_v <= 1'b1;
          d_d <= b;
          do @(negedge clk); while (d_r !== 1'b1);
          @(posedge clk);
        end
        d_v <= 1'b0;
      end
    end
  endtask

  // write engine command side
  task automatic wr_driver();
    forever begin
      @(posedge clk);
      wrc_r <= 1'b0;
      if (wrc_v) begin
        if (stall) repeat ($urandom_range(9) == 0 ? $urandom_range(200) : $urandom_range(3)) @(posedge clk);
        wrc_r <= 1'b1;
        @(posedge clk);
        wrc_r <= 1'b0;
      end
    end
  endtask

  // y ready
  bit yblock = 0;
  always @(posedge clk) y_r <= !stall || (!yblock && $urandom_range(3) != 0);
  task automatic yblocker();
    forever begin
      repeat ($urandom_range(4000, 300)) @(posedge clk);
      yblock = 1;
      repeat ($urandom_range(1500, 100)) @(posedge clk);
      yblock = 0;
    end
  endtask

  // ---------------- monitor (one negedge block: order of the updates matters) ----------------
  int     ycnt = 0;             // y of the current write command
  longint n_y = 0, n_cmd_done = 0, n_credit = 0, n_stall_rd = 0;
  longint t_lastw = -1000;
  typedef struct { longint t; int ix; } fexp_t;
  fexp_t  fq[$];                // expected cycle of the last y of each MACAB (STALL=0)
  int     mac_ix = 0;
  longint sum_rnw = 0, sum_occ = 0, t_hs = 0;
  bit     y_lv_prev = 0;
  // events per command: WRGB between its handshake and done, MAC steps between a MACAB's handshake
  // and its done pulse, gathers between two g_last
  longint wg_acc = 0, mac_acc = 0, rd_acc = 0;
  longint wg_q[$], mac_q[$], rd_q[$];
  cmd_t   done_q[$];            // completed commands to check

  always @(negedge clk) if (rst_n) begin
    if (cmd_valid && cmd_ready) begin
      hs_seen = 1;
      t_hs = cyc;
      if (cmd_op == 3) begin
        automatic int nw = (int'(cmd_n) + LB - 1) / LB, R = (int'(cmd_rows) + NB - 1) / NB;
        automatic int P = nw > NB ? nw : NB, nvl = int'(cmd_rows) - (R - 1) * NB;
        automatic longint t0 = cyc + 1, tl;
        if (t_lastw + NB - (nw - 1) > t0) t0 = t_lastw + NB - (nw - 1);
        tl = t0 + longint'(R - 1) * P + nw - 1;
        if (!stall) fq.push_back('{tl + L_BANK + nvl + L_S, mac_ix});
        mac_ix++;
        sum_rnw += longint'(R) * nw;
      end
    end
    if (dut.u_ctrl.mr_last_o && dut.u_ctrl.mr_en_o != '0) t_lastw = cyc;
    if (d_mac) sum_occ += cyc - t_hs + 1;
    if (int'(dut.u_ctrl.state_q) == 4 && dut.u_ctrl.m_first &&
        32'(dut.u_ctrl.yres_q) + 32'(dut.u_ctrl.m_nv) > Y_DEPTH) n_credit++;
    if (rd_stall) n_stall_rd++;
    if (rd_stall !== (d_r && !d_v)) c_ord.fail("rd_stall_o");
    // events
    wg_acc += ev_wrgb;
    mac_acc += ev_mac;
    rd_acc += ev_rdmac;
    if (d_wrgb) begin wg_q.push_back(wg_acc); wg_acc = 0; end
    if (d_mac) begin mac_q.push_back(mac_acc); mac_acc = 0; end
    if (dut.u_ctrl.g_valid_o && dut.u_ctrl.g_last_o) begin rd_q.push_back(rd_acc); rd_acc = 0; end
    if (ev_rdmac !== dut.u_ctrl.g_valid_o) c_ord.fail("ev_rdmac_o");
    // engine commands
    if (rdc_v && rdc_r) begin
      if (q_rdc.size() == 0) c_ord.fail("unexpected rd_cmd");
      else begin
        automatic ecmd_t e = q_rdc.pop_front();
        if (rdc_a !== 32'(e.a) || rdc_b !== 32'(e.b)) c_ord.fail($sformatf("rd_cmd %h %0d, expected %h %0d", rdc_a, rdc_b, e.a, e.b));
        else c_ord.pass();
      end
    end
    if (wrc_v && wrc_r) begin
      if (q_wrc.size() == 0) c_ord.fail("unexpected wr_cmd");
      else begin
        automatic ecmd_t e = q_wrc.pop_front();
        if (wrc_a !== 32'(e.a) || wrc_b !== 32'(e.b)) c_ord.fail($sformatf("wr_cmd %h %0d, expected %h %0d", wrc_a, wrc_b, e.a, e.b));
        else c_ord.pass();
      end
    end
    // first cycle in which the last y of a MACAB is valid (formula, STALL=0)
    if (y_v && y_last && !y_lv_prev && !stall) begin
      if (fq.size() == 0) c_cyc.fail("last y without an expectation");
      else begin
        automatic fexp_t f = fq.pop_front();
        if (f.t != cyc) c_cyc.fail($sformatf("MACAB %0d: last y valid in %0d, formula %0d", f.ix, cyc, f.t));
        else c_cyc.pass();
      end
    end
    y_lv_prev = y_v && y_last && !y_r;
    // y stream: destination = the oldest unfinished MACAB (y may come before the write command is
    // taken: the write engine buffers data ahead of its command)
    if (y_v && y_r) begin
      if (amq.size() == 0) c_ord.fail("y without a MACAB");
      else begin
        automatic int rows = amq[0].rows;
        for (int k = 0; k < 4; k++) ddr[amq[0].addr + 4 * ycnt + k] = y_d[8*k +: 8];
        ycnt++;
        n_y++;
        if (y_last !== (ycnt == rows)) c_ord.fail($sformatf("y_last %b at y %0d of %0d", y_last, ycnt, rows));
        if (ycnt == rows) begin
          ycnt = 0;
          done_q.push_back(amq.pop_front());
        end
      end
    end
    if (d_ldw || d_wrgb) begin
      if (aoq.size() == 0 || aoq[0].op != (d_ldw ? 1 : 2)) c_ord.fail("LDW / WRGB done out of order");
      else done_q.push_back(aoq.pop_front());
    end
    // check completed commands
    while (done_q.size() > 0) begin
      automatic cmd_t c = done_q.pop_front();
      n_cmd_done++;
      if (c.op == 3) begin
        automatic int bad = 0;
        for (int r = 0; r < c.rows; r++) begin
          automatic logic [31:0] v = {m8(c.addr + 4 * r + 3), m8(c.addr + 4 * r + 2), m8(c.addr + 4 * r + 1), m8(c.addr + 4 * r)};
          if (v !== 32'(c.ey[r])) begin
            bad++;
            if (bad <= 3) c_y.fail($sformatf("%s row %0d: y %0d, expected %0d", c.tag, r, $signed(v), c.ey[r]));
          end
        end
        if (bad == 0) c_y.pass();
        if (mac_q.size() == 0 || rd_q.size() == 0) c_cnt.fail({c.tag, ": MAC events missing"});
        else begin
          automatic longint em = mac_q.pop_front(), er = rd_q.pop_front();
          if (em != c.st[1] || er != c.st[2])
            c_cnt.fail($sformatf("%s: mac %0d rdmac %0d, bank_stat %0d %0d", c.tag, em, er, c.st[1], c.st[2]));
          else c_cnt.pass();
        end
      end else if (c.op == 2) begin
        if (wg_q.size() == 0) c_cnt.fail({c.tag, ": WRGB events missing"});
        else begin
          automatic longint ew = wg_q.pop_front();
          if (ew != c.st[0]) c_cnt.fail($sformatf("%s: wrgb %0d, bank_stat %0d", c.tag, ew, c.st[0]));
          else c_cnt.pass();
        end
      end
    end
  end

  // ---------------- records ----------------
  typedef struct { string name; int rows, n, base; } bm_t;
  bm_t bmap[$];
  typedef struct { string name; int rows, n; longint unsigned off; } rm_t;
  rm_t rmap[$];

  function automatic void read_maps(string vdir);
    int fd;
    string line, nm;
    int rows, n, nw, base, words, we;
    longint unsigned off, bytes;
    fd = $fopen({vdir, "/../pim/bimg_map.txt"}, "r");
    while (fd != 0 && !$feof(fd)) begin
      line = ""; void'($fgets(line, fd));
      if (line.len() > 4 && line.substr(0, 3) == "mat " &&
          $sscanf(line, "mat %s %d %d %d %d %d %d", nm, rows, n, nw, base, words, we) == 7)
        bmap.push_back('{nm, rows, n, base});
    end
    if (fd) $fclose(fd);
    fd = $fopen({vdir, "/rrec_map.txt"}, "r");
    while (fd != 0 && !$feof(fd)) begin
      line = ""; void'($fgets(line, fd));
      if (line.len() > 4 && line.substr(0, 3) == "mat " &&
          $sscanf(line, "mat %s %d %d %d %d %d", nm, rows, n, off, bytes, we) == 6)
        rmap.push_back('{nm, rows, n, off});
    end
    if (fd) $fclose(fd);
  endfunction

  function automatic longint load_file(string f, longint unsigned base);
    int fd = $fopen(f, "rb");
    logic [7:0] b8 [4096];
    longint tot = 0;
    int k;
    if (fd == 0) return -1;
    while (1) begin
      k = $fread(b8, fd);
      if (k <= 0) break;
      for (int i = 0; i < k; i++) ddr[base + tot + i] = b8[i];
      tot += k;
      if (k < 4096) break;
    end
    $fclose(fd);
    return tot;
  endfunction

  task automatic wait_drain();
    longint t0 = cyc;
    while (cq.size() != 0 || amq.size() != 0 || aoq.size() != 0 || busy) begin
      @(posedge clk);
      if (cyc - t0 > 20_000_000) begin c_ord.fail("WATCHDOG: commands do not finish"); break; end
    end
    repeat (2) @(posedge clk);
  endtask

  task automatic check_banks(string pimdir, logic [WW-1:0] pre [NB][DEPTH]);
    for (int b = 0; b < NB; b++) begin
      int fd = $fopen($sformatf("%s/bank%0d.hex", pimdir, b), "r");
      int a = 0, bad = 0;
      logic [WW-1:0] v;
      if (fd == 0) begin c_img.fail("bank hex"); continue; end
      while ($fscanf(fd, "%h", v) == 1) begin
        automatic logic [WW-1:0] got = bank_word(b, a), e = (a < 4072) ? v : pre[b][a];
        if (got !== e) begin
          bad++;
          if (bad <= 3) c_img.fail($sformatf("bank %0d word %0d: %h, expected %h", b, a, got, e));
        end
        a++;
      end
      $fclose(fd);
      if (a != DEPTH) c_img.fail("bank hex length");
      if (bad == 0) c_img.pass();
    end
  endtask

  function automatic logic [WW-1:0] bank_word(int b, int a);
    case (b)
      0: return dut.g_bank[0].u_bank.u_ram.mem[a];
      1: return dut.g_bank[1].u_bank.u_ram.mem[a];
      2: return dut.g_bank[2].u_bank.u_ram.mem[a];
      default: return dut.g_bank[3].u_bank.u_ram.mem[a];
    endcase
  endfunction
  task automatic set_bank_word(int b, int a, logic [WW-1:0] v);
    case (b)
      0: dut.g_bank[0].u_bank.u_ram.mem[a] = v;
      1: dut.g_bank[1].u_bank.u_ram.mem[a] = v;
      2: dut.g_bank[2].u_bank.u_ram.mem[a] = v;
      default: dut.g_bank[3].u_bank.u_ram.mem[a] = v;
    endcase
  endtask

  task automatic run_records(string vdir, int maxpos, int layer);
    logic [WW-1:0] pre [NB][DEPTH];
    int nrec = 0, pos = 0;
    byte gx[];                  // x of the current group
    longint gst0 = 0;
    read_maps(vdir);
    if (bmap.size() != 36 || rmap.size() != 36 || load_file({vdir, "/rrec.bin"}, W_BASE) <= 0) begin
      c_img.fail("maps / rrec.bin");
      return;
    end
    for (int b = 0; b < NB; b++) for (int a = 0; a < DEPTH; a++) begin
      pre[b][a] = {$urandom, $urandom, $urandom, $urandom, $urandom};
      set_bank_word(b, a, pre[b][a]);
    end
    for (int m = 0; m < 36; m++) begin
      cmd_t c;
      c.op = 1; c.rows = bmap[m].rows; c.n = bmap[m].n; c.base = bmap[m].base;
      c.addr = W_BASE + rmap[m].off; c.tag = {"LDW ", bmap[m].name};
      cq.push_back(c);
    end
    wait_drain();
    check_banks({vdir, "/../pim"}, pre);
    // MACABs
    if (kd_rec_open({vdir, "/gemv.bin"}) != 0) begin c_y.fail("gemv.bin"); return; end
    while (kd_rec_next() == K_GEMV) begin
      int m = nrec % 36;
      string nm = bmap[m].name;
      bit grp = layer ? (m == 0 || nm.substr(0, 1) == "wq" || nm.substr(0, 1) == "wo" ||
                         nm.substr(0, 1) == "w1" || nm.substr(0, 1) == "w2" || nm == "cls") : 1;
      cmd_t c;
      byte xb[];
      longint st[] = new[3];
      if (m == 0) begin
        if (maxpos > 0 && pos == maxpos) break;
        pos++;
      end
      c.op = 3; c.rows = kd_rec_prm(0); c.n = kd_rec_prm(1); c.base = bmap[m].base;
      c.we = kd_rec_prm(3); c.xm = kd_rec_prm(4); c.xe = kd_rec_prm(5); c.fo = kd_rec_prm(6);
      c.addr = Y_BASE + 64'h1_0000 * m + 8 * $urandom_range(511);
      c.tag = $sformatf("rec %0d %s", kd_rec_index(), nm);
      if (c.rows != bmap[m].rows || c.n != bmap[m].n || kd_rec_prm(2) != c.n) c_y.fail({c.tag, ": record does not match the map"});
      for (int r = 0; r < c.rows; r++) c.ey.push_back(kd_rec_get(3, r));
      if (kd_rec_bank(NB, st) != 0) c_cnt.fail({c.tag, ": bank_gemv differs from the record (golden)"});
      c.st[0] = st[0]; c.st[1] = st[1]; c.st[2] = st[2];
      xb = new[c.n];
      void'(kd_rec_bytes(2, 0, xb, c.n));
      if (grp) begin
        cmd_t x;
        x.op = 2; x.n = c.n; x.rows = 0; x.base = 0; x.addr = X_BASE + 64'h1000 * (nrec % 64);
        x.st[0] = st[0]; x.tag = {"WRGB ", nm};
        for (int i = 0; i < 8 * ((c.n + 7) / 8); i++) ddr[x.addr + i] = (i < c.n) ? xb[i] : 8'($urandom);
        gx = xb;
        cq.push_back(x);
      end else begin
        // the same x as the group's first record (layer order)
        bit same = gx.size() == c.n;
        for (int i = 0; same && i < c.n; i++) same = gx[i] == xb[i];
        if (!same) c_x.fail({c.tag, ": x differs from its group"}); else c_x.pass();
      end
      cq.push_back(c);
      nrec++;
      if (cq.size() > 24) while (cq.size() > 4) @(posedge clk);
    end
    void'(kd_rec_close());
    wait_drain();
    $display("records: %0d MACAB (%0d positions), layer order %0d", nrec, pos, layer);
  endtask

  // ---------------- synthetic ----------------
  int ncorner[] = '{1, 15, 16, 17, 48, 49, NMAX};
  int xslot = 0;

  task automatic run_syn(int nsyn);
    for (int s = 0; s < nsyn; s++) begin
      int k = $urandom_range(9);
      int n = s < ncorner.size() ? ncorner[s] : (k < 4 ? $urandom_range(48, 1) : $urandom_range(NMAX, 1));
      int rows = k == 4 ? $urandom_range(3, 1) : (k == 5 ? NB * $urandom_range(30, 1) : $urandom_range(300, 1));
      int nw = (n + LB - 1) / LB, used, base, nmac = $urandom_range(3, 1), rb = 8 * (1 + (n + 7) / 8);
      byte w[] = new[rows * n], xb[] = new[n];
      shortint wm[] = new[rows];
      cmd_t c, x;
      while ((rows + NB - 1) / NB * nw > DEPTH) rows = rows / 2 + 1;
      used = (rows + NB - 1) / NB * nw;
      base = $urandom_range(2) == 0 ? DEPTH - used : $urandom_range(DEPTH - used);
      foreach (w[i]) w[i] = (k == 6) ? -128 : byte'($urandom);
      foreach (wm[i]) wm[i] = (k == 7) ? 16'hFFFF : 16'($urandom);
      // row records with garbage in the header and padding
      c.op = 1; c.rows = rows; c.n = n; c.base = base; c.tag = $sformatf("syn %0d LDW", s);
      c.addr = SW_BASE + 64'h40_0000 * (s % 16) + 8 * $urandom_range(511);
      for (int r = 0; r < rows; r++) begin
        longint unsigned a = c.addr + longint'(r) * rb;
        logic [63:0] h = {$urandom, 16'($urandom), wm[r]};
        for (int i = 0; i < 8; i++) ddr[a + i] = h[8*i +: 8];
        for (int i = 0; i < rb - 8; i++) ddr[a + 8 + i] = (i < n) ? w[r * n + i] : 8'($urandom);
      end
      cq.push_back(c);
      for (int mi = 0; mi < nmac; mi++) begin
        int ey[] = new[rows], ey2;
        longint st[] = new[3];
        bit newx = mi == 0 || $urandom_range(1);
        cmd_t mc;
        if (newx) foreach (xb[i]) xb[i] = (k == 6) ? -127 : byte'(int'($urandom_range(254)) - 127);
        mc.op = 3; mc.rows = rows; mc.n = n; mc.base = base;
        mc.xm = (k == 8) ? (1 << AM_W) - 1 : $urandom_range((1 << AM_W) - 1);
        mc.we = (k == 9) ? int'($urandom_range(255)) - 128 : $urandom_range(30, 18);
        mc.xe = (k == 9) ? int'($urandom_range(255)) - 128 : $urandom_range(30, 15);
        mc.fo = (k == 9) ? int'($urandom_range(255)) - 128 : 16;
        mc.addr = Y_BASE + 64'h80_0000 + 64'h1_0000 * mi + 8 * $urandom_range(511);
        mc.tag = $sformatf("syn %0d MACAB %0d rows %0d n %0d", s, mi, rows, n);
        if (kd_bank_syn(w, wm, xb, rows, n, mc.we, mc.xm, mc.xe, mc.fo, NB, ey, st) != 0) c_y.fail("kd_bank_syn");
        // golden cross-check: bank_gemv == k_gemv on a few rows
        for (int r = 0; r < rows; r += (rows > 8 ? rows / 8 : 1)) begin
          byte wr[] = new[n];
          for (int i = 0; i < n; i++) wr[i] = w[r * n + i];
          ey2 = kd_gemv1(wr, xb, n, int'(wm[r]) & 'hFFFF, mc.xm, mc.we + mc.xe - mc.fo);
          if (ey2 != ey[r]) c_y.fail($sformatf("%s: golden bank_gemv %0d != k_gemv %0d", mc.tag, ey[r], ey2));
        end
        foreach (ey[r]) mc.ey.push_back(ey[r]);
        mc.st[0] = st[0]; mc.st[1] = st[1]; mc.st[2] = st[2];
        if (newx) begin
          x.op = 2; x.n = n; x.rows = 0; x.base = 0; x.tag = $sformatf("syn %0d WRGB", s);
          x.addr = X_BASE + 64'h10_0000 + 64'h800 * (xslot % 256) + 8 * $urandom_range(127);
          xslot++;
          x.st[0] = st[0];                         // bank_stat wrgb of the call
          for (int i = 0; i < 8 * ((n + 7) / 8); i++) ddr[x.addr + i] = (i < n) ? xb[i] : 8'($urandom);
          cq.push_back(x);
        end
        cq.push_back(mc);
      end
      if (cq.size() > 16) while (cq.size() > 4) @(posedge clk);
    end
    wait_drain();
  endtask

  int unsigned seed;
  string vdir = "";
  int maxpos = 0, layer = 1, nsyn = 0;

  initial begin
    seed = tb_seed_from_plusarg();
    void'($value$plusargs("VEC=%s", vdir));
    void'($value$plusargs("MAXPOS=%d", maxpos));
    void'($value$plusargs("LAYER=%d", layer));
    void'($value$plusargs("SYN=%d", nsyn));
    void'($value$plusargs("STALL=%d", stall));
    void'($value$plusargs("YBLK=%d", yblk));
    void'($value$plusargs("GAP=%d", gap));
    $display("tb_pim_core: NB %0d DEPTH %0d PIPE %0d/%0d Y_DEPTH %0d SEED %0d VEC %s MAXPOS %0d LAYER %0d SYN %0d STALL %0d YBLK %0d GAP %0d",
             NB, DEPTH, DOT_PIPE, SCALE_PIPE, Y_DEPTH, seed, vdir, maxpos, layer, nsyn, stall, yblk, gap);
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    fork cmd_driver(); rd_driver(); wr_driver(); join_none
    if (yblk) fork yblocker(); join_none
    repeat (2) @(posedge clk);
    if (vdir != "") run_records(vdir, maxpos, layer);
    if (nsyn > 0) run_syn(nsyn);
    repeat (20) @(posedge clk);
    $display("y %0d, commands %0d, rounds held by the y credit %0d cycles, read stall %0d cycles",
             n_y, n_cmd_done, n_credit, n_stall_rd);
    if (!stall && vdir != "")
      $display("MACAB sum of ceil(rows/NB) x nw = %0d (all positions), controller occupancy %0d", sum_rnw, sum_occ);
    if (yblk) begin
      if (n_credit == 0) c_reach.fail("YBLK: the y credit limit was never reached"); else c_reach.pass();
    end
    if (q_rdc.size() || q_wrc.size() || amq.size() || aoq.size() || fq.size()) c_ord.fail("items left");
    else c_ord.pass();
    begin
      automatic tb_checker_q chks;
      chks.push_back(c_y); chks.push_back(c_cnt); chks.push_back(c_ord);
      if (vdir != "") chks.push_back(c_img);
      if (vdir != "" && layer) chks.push_back(c_x);
      if (!stall) chks.push_back(c_cyc);
      if (yblk) chks.push_back(c_reach);
      void'(tb_final_report(chks));
    end
    $finish;
  end

  initial begin
    #10s;
    $error("TB_TIMEOUT global");
    $finish;
  end
endmodule
