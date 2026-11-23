// axi_mem_slave: AXI4 slave memory model for testbenches (not synthesizable).
//
// Stands in for the Zynq HP port + DDR seen by the IP's AXI masters (axi_rd_eng,
// axi_wr_eng): 64-bit data, INCR bursts, IDs. Behaviour:
//   - Sparse byte-addressed memory (4 KiB pages created on first touch). A read of a
//     never-written byte returns 8'hA5 in that lane and counts as an uninitialized read
//     (counter n_uninit; error AXI_UNINIT only if cfg_uninit_err(1)).
//   - Read: AR requests are queued (up to MAX_OUTS); each burst becomes ready
//     RD_LAT cycles after its AR handshake (random in [lat_rmin, lat_rmax]) and is
//     returned in AR order (in-order for every ID). RVALID gaps between beats are random.
//   - Write: AW requests and W beats are queued independently (W may lead AW). Beats are
//     written with WSTRB in AW order; B is returned in order, random [lat_bmin, lat_bmax]
//     cycles after the last beat was written.
//   - Random backpressure: ARREADY, AWREADY, WREADY low, RVALID / BVALID gap with the
//     percentages set by cfg_stall (default 0: always ready, no gaps).
//   - Error injection (S4-3): inj_rd_err(lo, hi, resp) / inj_wr_err(lo, hi, resp) add an
//     address window [lo, hi) (byte addresses, compared with the 8-byte-aligned word address
//     of each beat). A read beat whose word lies in a read window gets RRESP = resp
//     (2 SLVERR, 3 DECERR; data is still returned from memory). A write burst with at least
//     one beat in a write window gets BRESP = resp of the first such beat (the data is still
//     written). The first matching window wins. inj_clear() removes all windows. Counters
//     n_rd_err (beats) and n_wr_err (bursts).
//   - Backdoor: bd_write8/bd_read8/bd_write64/bd_read64, load_hex/dump_hex (one 64-bit
//     word per line, word i at base + 8 i), load_bin/dump_bin (raw little-endian bytes),
//     clear(). A testbench loads golden data from a file or from DPI-C (tb/dpi/kdpi_pkg.sv)
//     through these.
//   - Shared store (EXT_STORE = 1, S5-3, docs/spec/system.md 3.2): the bytes are not kept in
//     this instance but in one C memory reached through DPI-C (axm_rd64 / axm_wr64, 64-bit
//     beats with WSTRB, implemented by the testbench's C side, e.g. tb/sys_top/hal_dpi.c), so
//     that the instances of several HP ports see the same DDR image as the C program. The
//     backdoor functions go to the same store (bd_written is then always 1, clear() does
//     nothing, there are no uninitialized reads). A beat outside the C memory is an error
//     (tag AXI_EXT). EXT_STORE = 0 (default) is the behaviour above, unchanged; the imports
//     are then never called and need no C implementation.
//   - Hang injection (S5-4): inj_hang(r, b) stops returning R beats (r) and / or B responses
//     (b) from now on (requests are still accepted up to MAX_OUTS): a master waiting for them
//     never finishes (timeout path of a driver). inj_hang(0, 0) resumes.
//
// Protocol assertions on the master inputs. Every message starts with its tag so that
// sim/run.sh (expect assert:<TAG>=<n>) can count them; each one fires once per event:
//   AXI_HOLD    xVALID dropped before xREADY (AW, W, AR)
//   AXI_STABLE  AW / W / AR payload changed while VALID and not READY
//   AXI_X       X or Z on a VALID (after reset) or on the payload of a handshake
//   AXI_LEN     AxLEN > MAX_LEN (15 = AXI3 / HP port limit)
//   AXI_BURST   AxBURST != INCR or AxSIZE > log2(DW/8) (the burst is then served as INCR)
//   AXI_4K      burst crosses a 4 KiB boundary
//   AXI_ALIGN   address not aligned to AxSIZE (only if REQ_ALIGN)
//   AXI_WLAST   WLAST on a beat other than the last of its burst, or missing on the last
//               (once per burst)
//   AXI_IDLE    check_idle(): requests, beats or responses still pending at the end
//   AXI_UNINIT  read of an unwritten byte (only after cfg_uninit_err(1))
//   AXI_EXT     (EXT_STORE) beat outside the shared C memory
// RVALID/RDATA/RLAST/RID and BVALID/BID are held until RREADY / BREADY (model side, checked
// by the self-test tb/axi_mem/tb_axi_mem.sv).
module axi_mem_slave #(
  parameter int    DW        = 64,   // data width, power of two, 8..1024
  parameter int    AW        = 32,   // address width
  parameter int    IDW       = 6,    // ID width (HP port: 6)
  parameter int    MAX_LEN   = 15,   // largest AxLEN without AXI_LEN (15: AXI3 / HP, 255: AXI4)
  parameter int    MAX_OUTS  = 8,    // AR and AW requests accepted ahead
  parameter int    WBUF      = 64,   // W beats accepted ahead of their AW
  parameter bit    REQ_ALIGN = 1'b1, // AXI_ALIGN check
  parameter bit    EXT_STORE = 1'b0, // 1: bytes in the shared C memory (DPI-C), DW must be 64
  parameter string NAME      = "mem"
) (
  input  logic               clk,
  input  logic               rst_n,
  // write address
  input  logic [IDW-1:0]     awid_i,
  input  logic [AW-1:0]      awaddr_i,
  input  logic [7:0]         awlen_i,
  input  logic [2:0]         awsize_i,
  input  logic [1:0]         awburst_i,
  input  logic               awvalid_i,
  output logic               awready_o,
  // write data
  input  logic [DW-1:0]      wdata_i,
  input  logic [DW/8-1:0]    wstrb_i,
  input  logic               wlast_i,
  input  logic               wvalid_i,
  output logic               wready_o,
  // write response
  output logic [IDW-1:0]     bid_o,
  output logic [1:0]         bresp_o,
  output logic               bvalid_o,
  input  logic               bready_i,
  // read address
  input  logic [IDW-1:0]     arid_i,
  input  logic [AW-1:0]      araddr_i,
  input  logic [7:0]         arlen_i,
  input  logic [2:0]         arsize_i,
  input  logic [1:0]         arburst_i,
  input  logic               arvalid_i,
  output logic               arready_o,
  // read data
  output logic [IDW-1:0]     rid_o,
  output logic [DW-1:0]      rdata_o,
  output logic [1:0]         rresp_o,
  output logic               rlast_o,
  output logic               rvalid_o,
  input  logic               rready_i
);

  localparam int NBY = DW / 8;
  localparam int SZ  = $clog2(NBY);
  localparam int PG  = 4096;

  // parameter checks (elaboration)
  if (DW < 8 || DW > 1024 || (DW & (DW - 1)) != 0)
    $error("axi_mem_slave: DW=%0d must be a power of two in 8..1024", DW);
  if (IDW < 1 || IDW > 32) $error("axi_mem_slave: IDW=%0d must be 1..32", IDW);
  if (AW < 12 || AW > 64) $error("axi_mem_slave: AW=%0d must be 12..64", AW);
  if (MAX_LEN < 0 || MAX_LEN > 255) $error("axi_mem_slave: MAX_LEN=%0d must be 0..255", MAX_LEN);
  if (MAX_OUTS < 1 || WBUF < 1) $error("axi_mem_slave: MAX_OUTS and WBUF must be >= 1");
  if (EXT_STORE && DW != 64) $error("axi_mem_slave: EXT_STORE needs DW=64 (DW=%0d)", DW);

  // shared store (EXT_STORE): 8-byte word at a (a % 8 == 0); return 0 = inside the C memory
  import "DPI-C" function int axm_rd64(input longint unsigned a, output longint unsigned d);
  import "DPI-C" function int axm_wr64(input longint unsigned a, input longint unsigned d,
                                       input int unsigned strb);

  // ---------------- memory ----------------
  typedef byte unsigned page_t[PG];
  typedef bit page_v_t[PG];
  page_t   mem [longint unsigned];
  page_v_t vld [longint unsigned];

  longint unsigned n_uninit = 0;
  bit uninit_err = 1'b0;

  function automatic void bd_write8(longint unsigned a, byte unsigned d);
    longint unsigned p = a / PG;
    if (EXT_STORE) begin
      void'(axm_wr64(a & ~longint'(7), longint'(d) << (8 * (a % 8)), 1 << (a % 8)));
      return;
    end
    if (!mem.exists(p)) begin
      page_t z;
      page_v_t zv;
      foreach (z[i]) begin z[i] = 8'h00; zv[i] = 1'b0; end
      mem[p] = z;
      vld[p] = zv;
    end
    mem[p][a % PG] = d;
    vld[p][a % PG] = 1'b1;
  endfunction

  // unwritten bytes read as 8'hA5; *u is set if any byte was unwritten
  function automatic byte unsigned rd8(longint unsigned a, ref bit u);
    longint unsigned p = a / PG;
    if (EXT_STORE) begin
      longint unsigned w;
      void'(axm_rd64(a & ~longint'(7), w));
      return w[8 * (a % 8) +: 8];
    end
    if (!mem.exists(p) || !vld[p][a % PG]) begin
      u = 1'b1;
      return 8'hA5;
    end
    return mem[p][a % PG];
  endfunction

  function automatic byte unsigned bd_read8(longint unsigned a);
    bit u = 1'b0;
    return rd8(a, u);
  endfunction

  function automatic bit bd_written(longint unsigned a);
    longint unsigned p = a / PG;
    if (EXT_STORE) return 1'b1;
    return mem.exists(p) && vld[p][a % PG];
  endfunction

  function automatic void bd_write64(longint unsigned a, logic [63:0] d, logic [7:0] strb = 8'hFF);
    for (int i = 0; i < 8; i++)
      if (strb[i]) bd_write8(a + i, d[8*i +: 8]);
  endfunction

  function automatic logic [63:0] bd_read64(longint unsigned a);
    logic [63:0] d;
    for (int i = 0; i < 8; i++) d[8*i +: 8] = bd_read8(a + i);
    return d;
  endfunction

  function automatic void clear();
    if (EXT_STORE) return;
    mem.delete();
    vld.delete();
    n_uninit = 0;
  endfunction

  // one 64-bit hex word per line ("//" comments and empty lines skipped); returns words
  function automatic int load_hex(string file, longint unsigned base);
    int fd = $fopen(file, "r"), n = 0, rc;
    string line;
    logic [63:0] w;
    if (fd == 0) begin
      $error("AXI_FILE %s: cannot open %s", NAME, file);
      return -1;
    end
    while (!$feof(fd)) begin
      line = "";
      void'($fgets(line, fd));
      if (line.len() == 0 || line.substr(0, 1) == "//" || line == "\n") continue;
      rc = $sscanf(line, "%h", w);
      if (rc != 1) continue;
      bd_write64(base + 8 * n, w);
      n++;
    end
    $fclose(fd);
    return n;
  endfunction

  function automatic int dump_hex(string file, longint unsigned base, int nwords);
    int fd = $fopen(file, "w");
    if (fd == 0) begin
      $error("AXI_FILE %s: cannot write %s", NAME, file);
      return -1;
    end
    for (int i = 0; i < nwords; i++) $fdisplay(fd, "%016h", bd_read64(base + 8 * i));
    $fclose(fd);
    return nwords;
  endfunction

  // raw bytes, file byte i -> address base + i; returns bytes
  function automatic longint load_bin(string file, longint unsigned base);
    int fd = $fopen(file, "rb"), c;
    longint n = 0;
    if (fd == 0) begin
      $error("AXI_FILE %s: cannot open %s", NAME, file);
      return -1;
    end
    c = $fgetc(fd);
    while (c != -1) begin
      bd_write8(base + n, c[7:0]);
      n++;
      c = $fgetc(fd);
    end
    $fclose(fd);
    return n;
  endfunction

  function automatic longint dump_bin(string file, longint unsigned base, longint nbytes);
    int fd = $fopen(file, "wb");
    if (fd == 0) begin
      $error("AXI_FILE %s: cannot write %s", NAME, file);
      return -1;
    end
    for (longint i = 0; i < nbytes; i++) $fwrite(fd, "%c", bd_read8(base + i));
    $fclose(fd);
    return nbytes;
  endfunction

  // ---------------- configuration ----------------
  int st_ar = 0, st_aw = 0, st_w = 0, st_r = 0, st_b = 0;  // percent of cycles stalled
  int lat_rmin = 1, lat_rmax = 1, lat_bmin = 1, lat_bmax = 1;

  function automatic void cfg_stall(int ar, int aw, int w, int r, int b);
    st_ar = ar; st_aw = aw; st_w = w; st_r = r; st_b = b;
  endfunction
  function automatic void cfg_lat(int rmin, int rmax, int bmin, int bmax);
    lat_rmin = rmin < 1 ? 1 : rmin;
    lat_rmax = rmax < lat_rmin ? lat_rmin : rmax;
    lat_bmin = bmin < 1 ? 1 : bmin;
    lat_bmax = bmax < lat_bmin ? lat_bmin : bmax;
  endfunction
  function automatic void cfg_uninit_err(bit e);
    uninit_err = e;
  endfunction

  bit hang_r = 1'b0, hang_b = 1'b0;
  function automatic void inj_hang(bit r, bit b);
    hang_r = r;
    hang_b = b;
  endfunction

  function automatic bit stall(int pct);
    return pct > 0 && $urandom_range(99) < pct;
  endfunction

  // ---------------- error injection ----------------
  typedef struct {
    longint unsigned lo, hi;
    logic [1:0] resp;
  } errwin_t;
  errwin_t rd_errw[$], wr_errw[$];
  longint unsigned n_rd_err = 0, n_wr_err = 0;

  function automatic void inj_rd_err(longint unsigned lo, longint unsigned hi, logic [1:0] resp);
    errwin_t w;
    w.lo = lo; w.hi = hi; w.resp = resp;
    rd_errw.push_back(w);
  endfunction
  function automatic void inj_wr_err(longint unsigned lo, longint unsigned hi, logic [1:0] resp);
    errwin_t w;
    w.lo = lo; w.hi = hi; w.resp = resp;
    wr_errw.push_back(w);
  endfunction
  function automatic void inj_clear();
    rd_errw.delete();
    wr_errw.delete();
  endfunction
  function automatic logic [1:0] win_resp(ref errwin_t q[$], input longint unsigned a);
    longint unsigned w0 = a & ~longint'(NBY - 1);
    foreach (q[i]) if (w0 >= q[i].lo && w0 < q[i].hi) return q[i].resp;
    return 2'b00;
  endfunction

  // ---------------- statistics ----------------
  longint unsigned n_rd_burst = 0, n_rd_beat = 0, n_wr_burst = 0, n_wr_beat = 0;
  int max_rd_outs = 0, max_wr_outs = 0;
  int n_viol = 0;  // all assertion messages of this instance

  function automatic void viol(string tag, string msg);
    n_viol++;
    $error("%s %s: %s", tag, NAME, msg);
  endfunction

  // ---------------- request queues ----------------
  typedef struct {
    logic [IDW-1:0] id;
    longint unsigned addr;
    int len, size;
    logic [1:0] burst;
    longint unsigned t;
  } req_t;
  typedef struct {
    logic [DW-1:0] d;
    logic [NBY-1:0] s;
    logic l;
  } wbeat_t;
  typedef struct {
    logic [IDW-1:0] id;
    longint unsigned t;
    logic [1:0] resp;
  } bresp_t;

  req_t   arq[$], awq[$];
  wbeat_t wq[$];
  bresp_t bq[$];
  longint unsigned cyc = 0;
  int rbeat = 0, wbeat = 0;
  bit wlast_bad = 1'b0;
  logic [1:0] wresp_acc = 2'b00;  // BRESP of the burst being written (first error beat)

  // address of beat k of a burst (always INCR from the size-aligned start)
  function automatic longint unsigned beat_addr(req_t q, int k);
    longint unsigned a0 = q.addr & ~((longint'(1) << q.size) - 1);
    return k == 0 ? q.addr : a0 + longint'(k) * (longint'(1) << q.size);
  endfunction

  function automatic void check_req(string ch, req_t q);
    longint unsigned bytes = longint'(1) << q.size;
    longint unsigned a0 = q.addr & ~(bytes - 1);
    if (q.len > MAX_LEN) viol("AXI_LEN", $sformatf("%s len %0d > MAX_LEN %0d at 0x%0h", ch, q.len, MAX_LEN, q.addr));
    if (q.burst != 2'b01 || q.size > SZ)
      viol("AXI_BURST", $sformatf("%s burst %0d size %0d (INCR, size <= %0d supported) at 0x%0h", ch, q.burst, q.size, SZ, q.addr));
    if ((a0 % PG) + longint'(q.len + 1) * bytes > PG)
      viol("AXI_4K", $sformatf("%s burst at 0x%0h len %0d size %0d crosses 4 KiB", ch, q.addr, q.len, q.size));
    if (REQ_ALIGN && (q.addr % bytes) != 0)
      viol("AXI_ALIGN", $sformatf("%s address 0x%0h not aligned to size %0d", ch, q.addr, q.size));
  endfunction

  function automatic logic [DW-1:0] rd_word(longint unsigned a);
    logic [DW-1:0] d;
    bit u = 1'b0;
    longint unsigned w0 = a & ~longint'(NBY - 1);
    if (EXT_STORE) begin
      longint unsigned w;
      if (axm_rd64(w0, w) != 0) viol("AXI_EXT", $sformatf("read beat at 0x%0h outside the shared memory", w0));
      return DW'(w);
    end
    for (int i = 0; i < NBY; i++) d[8*i +: 8] = rd8(w0 + i, u);
    if (u) begin
      n_uninit++;
      if (uninit_err) viol("AXI_UNINIT", $sformatf("read of unwritten bytes at 0x%0h", w0));
    end
    return d;
  endfunction

  function automatic void wr_word(longint unsigned a, logic [DW-1:0] d, logic [NBY-1:0] s);
    longint unsigned w0 = a & ~longint'(NBY - 1);
    if (EXT_STORE) begin
      if (axm_wr64(w0, 64'(d), 32'(s)) != 0)
        viol("AXI_EXT", $sformatf("write beat at 0x%0h outside the shared memory", w0));
      return;
    end
    for (int i = 0; i < NBY; i++)
      if (s[i]) bd_write8(w0 + i, d[8*i +: 8]);
  endfunction

  // ---------------- input protocol monitor state ----------------
  bit ar_pend = 1'b0, aw_pend = 1'b0, w_pend = 1'b0;
  logic [IDW+AW+8+3+2-1:0] ar_prev, aw_prev;
  logic [DW+NBY:0] w_prev;

  wire [IDW+AW+8+3+2-1:0] ar_pl = {arid_i, araddr_i, arlen_i, arsize_i, arburst_i};
  wire [IDW+AW+8+3+2-1:0] aw_pl = {awid_i, awaddr_i, awlen_i, awsize_i, awburst_i};
  wire [DW+NBY:0]         w_pl  = {wdata_i, wstrb_i, wlast_i};

  // ---------------- main process ----------------
  always @(posedge clk or negedge rst_n) begin  // TB model: shares memory with the backdoor functions
    if (!rst_n) begin
      awready_o <= 1'b0;
      wready_o  <= 1'b0;
      arready_o <= 1'b0;
      bvalid_o  <= 1'b0;
      rvalid_o  <= 1'b0;
      bid_o     <= '0;
      bresp_o   <= 2'b00;
      rid_o     <= '0;
      rdata_o   <= '0;
      rresp_o   <= 2'b00;
      rlast_o   <= 1'b0;
      arq.delete();
      awq.delete();
      wq.delete();
      bq.delete();
      rbeat = 0;
      wbeat = 0;
      wlast_bad = 1'b0;
      wresp_acc = 2'b00;
      ar_pend = 1'b0;
      aw_pend = 1'b0;
      w_pend = 1'b0;
    end else begin
      cyc++;
      // ---- input protocol checks ----
      if ($isunknown({arvalid_i, awvalid_i, wvalid_i, rready_i, bready_i}))
        viol("AXI_X", $sformatf("X/Z on a VALID/READY input (ar %b aw %b w %b rr %b br %b)",
             arvalid_i, awvalid_i, wvalid_i, rready_i, bready_i));
      if (ar_pend) begin
        if (arvalid_i !== 1'b1) viol("AXI_HOLD", "ARVALID dropped before ARREADY");
        else if (ar_pl !== ar_prev) viol("AXI_STABLE", "AR payload changed while waiting for ARREADY");
      end
      if (aw_pend) begin
        if (awvalid_i !== 1'b1) viol("AXI_HOLD", "AWVALID dropped before AWREADY");
        else if (aw_pl !== aw_prev) viol("AXI_STABLE", "AW payload changed while waiting for AWREADY");
      end
      if (w_pend) begin
        if (wvalid_i !== 1'b1) viol("AXI_HOLD", "WVALID dropped before WREADY");
        else if (w_pl !== w_prev) viol("AXI_STABLE", "W payload changed while waiting for WREADY");
      end
      ar_pend = (arvalid_i === 1'b1) && !arready_o;
      aw_pend = (awvalid_i === 1'b1) && !awready_o;
      w_pend  = (wvalid_i === 1'b1) && !wready_o;
      ar_prev = ar_pl;
      aw_prev = aw_pl;
      w_prev  = w_pl;

      // ---- AR ----
      if (arvalid_i === 1'b1 && arready_o) begin
        req_t q;
        if ($isunknown(ar_pl)) viol("AXI_X", "X/Z on the AR payload at the handshake");
        q.id = arid_i; q.addr = araddr_i; q.len = arlen_i; q.size = arsize_i; q.burst = arburst_i;
        q.t = cyc + $urandom_range(lat_rmax, lat_rmin);
        check_req("AR", q);
        arq.push_back(q);
        n_rd_burst++;
        if (arq.size() > max_rd_outs) max_rd_outs = arq.size();
      end
      arready_o <= (arq.size() < MAX_OUTS) && !stall(st_ar);

      // ---- R ----
      if (!(rvalid_o && !rready_i)) begin  // not holding a beat
        if (rvalid_o && rready_i) begin
          n_rd_beat++;
          if (rbeat == arq[0].len) begin
            void'(arq.pop_front());
            rbeat = 0;
          end else rbeat++;
        end
        if (arq.size() > 0 && cyc >= arq[0].t && !hang_r && !stall(st_r)) begin
          logic [1:0] rr;
          rr = win_resp(rd_errw, beat_addr(arq[0], rbeat));
          if (rr != 2'b00) n_rd_err++;
          rvalid_o <= 1'b1;
          rid_o    <= arq[0].id;
          rdata_o  <= rd_word(beat_addr(arq[0], rbeat));
          rresp_o  <= rr;
          rlast_o  <= (rbeat == arq[0].len);
        end else begin
          rvalid_o <= 1'b0;
          rlast_o  <= 1'b0;
        end
      end

      // ---- AW, W ----
      if (awvalid_i === 1'b1 && awready_o) begin
        req_t q;
        if ($isunknown(aw_pl)) viol("AXI_X", "X/Z on the AW payload at the handshake");
        q.id = awid_i; q.addr = awaddr_i; q.len = awlen_i; q.size = awsize_i; q.burst = awburst_i;
        q.t = 0;
        check_req("AW", q);
        awq.push_back(q);
        n_wr_burst++;
        if (awq.size() > max_wr_outs) max_wr_outs = awq.size();
      end
      if (wvalid_i === 1'b1 && wready_o) begin
        wbeat_t b;
        if ($isunknown({wstrb_i, wlast_i})) viol("AXI_X", "X/Z on WSTRB/WLAST at the handshake");
        b.d = wdata_i; b.s = wstrb_i; b.l = wlast_i;
        wq.push_back(b);
      end
      while (awq.size() > 0 && wq.size() > 0) begin
        wbeat_t b;
        bit last;
        b = wq.pop_front();
        last = (wbeat == awq[0].len);
        if (wresp_acc == 2'b00) wresp_acc = win_resp(wr_errw, beat_addr(awq[0], wbeat));
        wr_word(beat_addr(awq[0], wbeat), b.d, b.s);
        n_wr_beat++;
        if (b.l !== last && !wlast_bad) begin
          viol("AXI_WLAST", $sformatf("WLAST=%b on beat %0d of a %0d-beat burst at 0x%0h",
               b.l, wbeat, awq[0].len + 1, awq[0].addr));
          wlast_bad = 1'b1;
        end
        if (last) begin
          bresp_t r;
          r.id = awq[0].id;
          r.t = cyc + $urandom_range(lat_bmax, lat_bmin);
          r.resp = wresp_acc;
          if (wresp_acc != 2'b00) n_wr_err++;
          wresp_acc = 2'b00;
          bq.push_back(r);
          void'(awq.pop_front());
          wbeat = 0;
          wlast_bad = 1'b0;
        end else wbeat++;
      end
      awready_o <= (awq.size() < MAX_OUTS) && !stall(st_aw);
      wready_o  <= (wq.size() < WBUF) && !stall(st_w);

      // ---- B ----
      if (!(bvalid_o && !bready_i)) begin
        if (bvalid_o && bready_i) void'(bq.pop_front());
        if (bq.size() > 0 && cyc >= bq[0].t && !hang_b && !stall(st_b)) begin
          bvalid_o <= 1'b1;
          bid_o    <= bq[0].id;
          bresp_o  <= bq[0].resp;
        end else bvalid_o <= 1'b0;
      end
    end
  end

  // end-of-test check: nothing may be left in flight
  function automatic void check_idle();
    if (arq.size() || awq.size() || wq.size() || bq.size() || rvalid_o || bvalid_o)
      viol("AXI_IDLE", $sformatf("pending at end: AR %0d AW %0d W %0d B %0d rvalid %b bvalid %b",
           arq.size(), awq.size(), wq.size(), bq.size(), rvalid_o, bvalid_o));
  endfunction

  function automatic void report();
    $display("AXI_MEM %s: rd bursts %0d beats %0d max outstanding %0d | wr bursts %0d beats %0d max outstanding %0d | uninit reads %0d | injected rd err beats %0d wr err bursts %0d | violations %0d",
             NAME, n_rd_burst, n_rd_beat, max_rd_outs, n_wr_burst, n_wr_beat, max_wr_outs,
             n_uninit, n_rd_err, n_wr_err, n_viol);
  endfunction

endmodule
