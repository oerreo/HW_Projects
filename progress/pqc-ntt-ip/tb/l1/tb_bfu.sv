// tb_bfu: self-checking testbench for the L1 unified butterfly bfu.
//
// The DUT is bfu with ALGO, PRE_REG, MUL_REG, RED_PIPE, OUT_REG and
// SHARE_ADDSUB taken from the TB parameters.
//
// Expected values: golden model DPI-C mlkem_dpi_bfu(algo, mode, a, b, z, x, y)
//   CT: x = a + mul(b, z), y = a - mul(b, z)
//   GS: x = half(a + b),   y = half(mul(b - a, z)),  mul(u, v) = u * v * S mod Q
// Every DPI result is cross-checked against an independent plain SV
// expression with % and SCALE = 1, 2704, 1, 169 written here
// ("model_xcheck"); SCALE itself is checked against mlkem_dpi_algo_scale().
//
// Stimulus items (each has its own data checker, one check = x and y of one
// vector):
//   edge  : a, b, z each in {0, 1, 2, (Q-1)/2, (Q+1)/2, Q-2, Q-1}, all 7^3
//           combinations, for CT then GS (686 vectors).
//   rom   : z = every zeta ROM (128), gamma ROM (128) and K2 (1) value of the
//           ALGO (mlkem_dpi_rom), N_ROM random (a, b) each, CT then GS.
//   rand  : N_RAND random (a, b, z) per mode, CT then GS.
//   mix   : N_MIX vectors with gap 0 %, then N_MIX with gap 25 %. MIX_MODE = 1:
//           mode drawn at random for every vector (CT/GS interleaved cycle by
//           cycle). MIX_MODE = 0: mode-fixed bursts of 1..64 vectors.
//           z alternates between a random value and a random ROM value.
//   trace : replay of the golden hardware-schedule traces in file order
//           (model/vectors): hw_ntt_trace_<algo>.txt (896 CT),
//           hw_intt_trace_<algo>.txt (896 GS), hw_basemul_trace_<algo>.txt
//           (640 or 896 CT). Expected x, y are the values in the file
//           (basemul records x only; its y is checked against the DPI). The
//           file values are also cross-checked against the DPI and the ROM
//           (zeta / gamma / K2 addresses), and the record counts against
//           896 and 128 * mlkem_dpi_basemul_nops().
// Items edge, rom, rand and trace drop valid_i with probability GAP_PCT per
// cycle; junk data and a random mode are driven while valid_i is low.
//
// Mode switch drain (DRAIN = 1, default when SHARE_ADDSUB = 1): before a
// vector whose mode differs from the previous vector, LATENCY idle cycles are
// inserted. This is the traffic rule of the shared add/sub variant.
//
// Checking: a reference delay line of depth LATENCY (read from the DUT and
// checked against PRE_REG + MUL_REG + RED_PIPE + OUT_REG) holds
// (valid, inputs, expected). Every cycle valid_o must equal the delayed valid
// ("valid_align"); when it is 1, x_o and y_o must equal the delayed expected
// values. Inputs are driven at the rising edge, outputs checked at the
// falling edge.
//
// Plusargs:
//   +SEED=<n> (1)  +GAP_PCT=<n> (0)  +N_ROM=<n> (2000)  +N_RAND=<n> (2000000)
//   +N_MIX=<n> (1000000)  +MIX_MODE=<0|1> (1, or 0 when SHARE_ADDSUB = 1)
//   +DRAIN=<0|1> (SHARE_ADDSUB)  +VEC_DIR=<dir> (../../model/vectors)
//   +OOR_TEST  instead of the items, drive OOR_N = 4 valid out-of-range
//              vectors (CT a=Q / CT b=Q / GS z=Q / GS a=Q) between in-range
//              boundary vectors. The bfu L1_RANGE assertion must fire 4
//              times; the L0 instances that receive the bad value fire too
//              (L0_RANGE, 6 times with SHARE_ADDSUB = 0).
`timescale 1ns / 1ps

module tb_bfu;
  import mlkem_pkg::*;
  import mlkem_dpi_pkg::*;
  import tb_util_pkg::*;

  parameter int ALGO         = 0;       // mlkem_pkg::algo_e value
  parameter int PRE_REG      = 0;
  parameter int MUL_REG      = 0;
  parameter int RED_PIPE     = 0;
  parameter int OUT_REG      = 0;
  parameter int SHARE_ADDSUB = 0;

  localparam time T_CLK   = 10ns;
  localparam int  MAX_LAT = 8;
  localparam int  OOR_N   = 4;
  localparam int  SCALE   = (ALGO == int'(ALGO_MONT12)) ? 2704 :
                            (ALGO == int'(ALGO_K2RED))  ? 169  : 1;
  localparam int  N_ITEMS = 5;
  localparam int  IT_EDGE = 0, IT_ROM = 1, IT_RAND = 2, IT_MIX = 3, IT_TRACE = 4;
  localparam int  N_EDGE  = 7;
  localparam int  EDGE [N_EDGE] = '{0, 1, 2, (Q - 1) / 2, (Q + 1) / 2, Q - 2, Q - 1};

  if (ALGO < 0 || ALGO > 3) begin : g_bad_algo
    $error("tb_bfu: ALGO=%0d not supported", ALGO);
  end

  logic              clk     = 1'b0;
  logic              rst_n   = 1'b0;
  mode_e             mode_i  = MODE_CT;
  logic [COEF_W-1:0] a_i     = '0;
  logic [COEF_W-1:0] b_i     = '0;
  logic [COEF_W-1:0] z_i     = '0;
  logic              valid_i = 1'b0;
  logic [COEF_W-1:0] x_o;
  logic [COEF_W-1:0] y_o;
  logic              valid_o;

  bfu #(
    .ALGO(algo_e'(ALGO)), .PRE_REG(PRE_REG), .MUL_REG(MUL_REG), .RED_PIPE(RED_PIPE),
    .OUT_REG(OUT_REG), .SHARE_ADDSUB(SHARE_ADDSUB)
  ) dut (.*);

  always #(T_CLK / 2) clk = ~clk;

  // --------------------------------------------------------------------------
  // Reference delay line and checkers
  // --------------------------------------------------------------------------
  typedef struct {
    bit v;
    int item;
    int mode;
    int a;
    int b;
    int z;
    int ex;    // -1: do not check (out-of-range stimulus)
    int ey;
  } ref_t;

  ref_t      ref_pipe [0:MAX_LAT];
  int        lat;
  tb_checker chk_item [N_ITEMS];
  tb_checker chk_valid;
  tb_checker chk_model;
  longint    n_vec [N_ITEMS];
  int        last_mode;
  bit        drain;
  string     vec_dir;

  function automatic string algo_name(int a);
    case (a)
      0:       return "barrett";
      1:       return "mont12";
      2:       return "shiftadd";
      3:       return "k2red";
      default: return "?";
    endcase
  endfunction

  // Independent reference with plain % arithmetic.
  function automatic void sv_ref(int mode, int a, int b, int z, output int x, output int y);
    longint t, d, m;
    if (mode == 0) begin
      t = (longint'(b) * z * SCALE) % Q;
      x = int'((a + t) % Q);
      y = int'((a - t + Q) % Q);
    end else begin
      d = (longint'(b) - a + Q) % Q;
      m = (d * z * SCALE) % Q;
      x = int'((longint'(a + b) * Q_INV2) % Q);
      y = int'((m * Q_INV2) % Q);
    end
  endfunction

  // DPI golden value, cross-checked against sv_ref.
  function automatic void golden(int mode, int a, int b, int z, output int x, output int y);
    int rx, ry;
    mlkem_dpi_bfu(ALGO, mode, a, b, z, x, y);
    sv_ref(mode, a, b, z, rx, ry);
    if (x == rx && y == ry) chk_model.pass();
    else chk_model.fail($sformatf("DPI bfu(%0d, mode %0d, a %0d, b %0d, z %0d) = (%0d, %0d), SV ref (%0d, %0d)",
                                  ALGO, mode, a, b, z, x, y, rx, ry));
  endfunction

  task automatic check_outputs();
    ref_t r = ref_pipe[lat];
    if (valid_o === r.v) chk_valid.pass();
    else chk_valid.fail($sformatf("valid_o=%b expected %b", valid_o, r.v));
    if (r.v && r.ex >= 0) begin
      if (x_o === COEF_W'(r.ex) && y_o === COEF_W'(r.ey)) chk_item[r.item].pass();
      else chk_item[r.item].fail($sformatf("mode=%0d a=%0d b=%0d z=%0d expected (x,y)=(%0d,%0d) got (%0d,%0d)",
                                           r.mode, r.a, r.b, r.z, r.ex, r.ey, x_o, y_o));
    end
  endtask

  // One clock cycle: advance the reference line at the rising edge, apply the
  // new inputs with nonblocking assignments, check at the falling edge.
  task automatic cycle(bit v, int item, int mode, int a, int b, int z, int ex, int ey);
    @(posedge clk);
    for (int i = lat; i > 0; i--) ref_pipe[i] = ref_pipe[i - 1];
    valid_i     <= v;
    mode_i      <= mode_e'(mode[0]);
    a_i         <= COEF_W'(a);
    b_i         <= COEF_W'(b);
    z_i         <= COEF_W'(z);
    ref_pipe[0] = '{v: v, item: item, mode: mode, a: a, b: b, z: z, ex: ex, ey: ey};
    @(negedge clk);
    check_outputs();
  endtask

  task automatic idle();
    cycle(1'b0, 0, $urandom_range(1), $urandom_range(2 ** COEF_W - 1),
          $urandom_range(2 ** COEF_W - 1), $urandom_range(2 ** COEF_W - 1), -1, -1);
  endtask

  // Drive one valid vector. ex / ey >= 0 override the golden value (trace
  // replay); the golden value is then cross-checked against them.
  task automatic send(int item, int mode, int a, int b, int z, int gap_pct,
                      int tx = -1, int ty = -1);
    int gx, gy;
    if (drain && last_mode >= 0 && mode != last_mode) repeat (lat) idle();
    last_mode = mode;
    while ($urandom_range(99) < gap_pct) idle();
    golden(mode, a, b, z, gx, gy);
    if (tx >= 0) begin
      if (tx == gx && (ty < 0 || ty == gy)) chk_model.pass();
      else chk_model.fail($sformatf("trace mode %0d a %0d b %0d z %0d: file (%0d, %0d), DPI (%0d, %0d)",
                                    mode, a, b, z, tx, ty, gx, gy));
      gx = tx;
      if (ty >= 0) gy = ty;
    end
    cycle(1'b1, item, mode, a, b, z, gx, gy);
    n_vec[item]++;
  endtask

  function automatic int rnd_q();
    return $urandom_range(Q - 1);
  endfunction

  function automatic int rnd_rom();
    int k = $urandom_range(256);
    if (k < 128)      return mlkem_dpi_rom(ALGO, 0, k);
    else if (k < 256) return mlkem_dpi_rom(ALGO, 1, k - 128);
    else              return mlkem_dpi_rom(ALGO, 2, 0);
  endfunction

  // --------------------------------------------------------------------------
  // Trace replay
  // --------------------------------------------------------------------------
  task automatic replay_transform(string fname, int want_mode, int gap_pct, output int n);
    int    fd, rc, layer, step, len, rdb, wrb, a0, a1, za, md, a, b, z, x, y, zr;
    string line;
    n  = 0;
    fd = $fopen(fname, "r");
    if (fd == 0) begin
      chk_item[IT_TRACE].fail($sformatf("cannot open %s", fname));
      return;
    end
    while ($fgets(line, fd) > 0) begin
      if (line.len() < 2 || line.substr(0, 1) == "//") continue;
      rc = $sscanf(line, "%d %d %d %d %d %d %d %d %d %h %h %h %h %h",
                   layer, step, len, rdb, wrb, a0, a1, za, md, a, b, z, x, y);
      if (rc != 14) begin
        chk_item[IT_TRACE].fail($sformatf("%s: bad line '%s'", fname, line));
        continue;
      end
      zr = mlkem_dpi_rom(ALGO, 0, za);
      if (md == want_mode && z == zr) chk_model.pass();
      else chk_model.fail($sformatf("%s line %0d: mode %0d (want %0d), z %0d, zeta ROM[%0d] = %0d",
                                    fname, n, md, want_mode, z, za, zr));
      send(IT_TRACE, md, a, b, z, gap_pct, x, y);
      n++;
    end
    $fclose(fd);
  endtask

  function automatic int src_rom_value(string src, int pair);
    if (src == "GAMMA") return mlkem_dpi_rom(ALGO, 1, pair);
    if (src == "K2")    return mlkem_dpi_rom(ALGO, 2, 0);
    if (src == "ZERO")  return 0;
    return -1;                          // data source, value not known here
  endfunction

  task automatic replay_basemul(string fname, int gap_pct, output int n);
    int    fd, rc, pair, op, a, b, z, x, e;
    string sa, sb, sz, sd, line;
    n  = 0;
    fd = $fopen(fname, "r");
    if (fd == 0) begin
      chk_item[IT_TRACE].fail($sformatf("cannot open %s", fname));
      return;
    end
    while ($fgets(line, fd) > 0) begin
      if (line.len() < 2 || line.substr(0, 1) == "//") continue;
      rc = $sscanf(line, "%d %d %s %s %s %s %h %h %h %h", pair, op, sa, sb, sz, sd, a, b, z, x);
      if (rc != 10) begin
        chk_item[IT_TRACE].fail($sformatf("%s: bad line '%s'", fname, line));
        continue;
      end
      // Constant sources must hold the ROM / zero value.
      e = src_rom_value(sa, pair);
      if (e >= 0) begin if (a == e) chk_model.pass(); else chk_model.fail($sformatf("%s pair %0d op %0d a_src %s = %0d, want %0d", fname, pair, op, sa, a, e)); end
      e = src_rom_value(sz, pair);
      if (e >= 0) begin if (z == e) chk_model.pass(); else chk_model.fail($sformatf("%s pair %0d op %0d z_src %s = %0d, want %0d", fname, pair, op, sz, z, e)); end
      send(IT_TRACE, 0, a, b, z, gap_pct, x, -1);
      n++;
    end
    $fclose(fd);
  endtask

  // --------------------------------------------------------------------------
  // Main sequence
  // --------------------------------------------------------------------------
  initial begin
    int unsigned seed;
    int          gap_pct, n_rom, n_rand, n_mix, mix_mode, drain_arg;
    int          n_ntt, n_intt, n_bm, nops, s_dpi, z, burst;
    bit          oor_test;
    bit          ok;
    longint      want [N_ITEMS];
    string       an;

    seed      = tb_seed_from_plusarg();
    gap_pct   = 0;
    n_rom     = 2000;
    n_rand    = 2000000;
    n_mix     = 1000000;
    mix_mode  = (SHARE_ADDSUB == 0);
    drain_arg = SHARE_ADDSUB;
    vec_dir   = "../../model/vectors";
    void'($value$plusargs("GAP_PCT=%d", gap_pct));
    void'($value$plusargs("N_ROM=%d", n_rom));
    void'($value$plusargs("N_RAND=%d", n_rand));
    void'($value$plusargs("N_MIX=%d", n_mix));
    void'($value$plusargs("MIX_MODE=%d", mix_mode));
    void'($value$plusargs("DRAIN=%d", drain_arg));
    void'($value$plusargs("VEC_DIR=%s", vec_dir));
    oor_test  = $test$plusargs("OOR_TEST");
    drain     = (drain_arg != 0);
    lat       = dut.LATENCY;
    last_mode = -1;
    an        = algo_name(ALGO);
    chk_item[IT_EDGE]  = new("edge");
    chk_item[IT_ROM]   = new("rom");
    chk_item[IT_RAND]  = new("rand");
    chk_item[IT_MIX]   = new("mix");
    chk_item[IT_TRACE] = new("trace");
    chk_valid = new("valid_align");
    chk_model = new("model_xcheck");
    foreach (n_vec[i]) n_vec[i] = 0;
    foreach (ref_pipe[i]) ref_pipe[i] = '{v: 1'b0, item: 0, mode: 0, a: 0, b: 0, z: 0, ex: -1, ey: -1};

    $display("TB_CONFIG: tb_bfu ALGO=%0d(%s) PRE_REG=%0d MUL_REG=%0d RED_PIPE=%0d OUT_REG=%0d SHARE_ADDSUB=%0d LATENCY=%0d SEED=%0d GAP_PCT=%0d N_ROM=%0d N_RAND=%0d N_MIX=%0d MIX_MODE=%0d DRAIN=%0d OOR_TEST=%0d",
             ALGO, an, PRE_REG, MUL_REG, RED_PIPE, OUT_REG, SHARE_ADDSUB, lat, seed, gap_pct,
             n_rom, n_rand, n_mix, mix_mode, drain, oor_test);
    if (lat < 0 || lat > MAX_LAT) $fatal(1, "LATENCY %0d outside TB support", lat);
    // The DUT latency must be the documented sum of its four cut points.
    if (lat != PRE_REG + MUL_REG + RED_PIPE + OUT_REG)
      $fatal(1, "dut.LATENCY=%0d != PRE_REG + MUL_REG + RED_PIPE + OUT_REG = %0d", lat,
             PRE_REG + MUL_REG + RED_PIPE + OUT_REG);

    s_dpi = mlkem_dpi_algo_scale(ALGO, 1);
    if (s_dpi == SCALE) chk_model.pass();
    else chk_model.fail($sformatf("algo_scale(%0d) = %0d, TB SCALE = %0d", ALGO, s_dpi, SCALE));

    // Reset: valid_o must be 0 while rst_n is low. Release at a falling edge.
    repeat (3) idle();
    @(negedge clk);
    rst_n = 1'b1;
    repeat (2) idle();

    if (oor_test) begin
      send(IT_EDGE, 0, 1, 2, 3, 0);
      cycle(1'b1, 0, 0, Q, 0, 0, -1, -1);    repeat (lat + 1) idle();
      cycle(1'b1, 0, 0, 0, Q, 1, -1, -1);    repeat (lat + 1) idle();
      cycle(1'b1, 0, 1, 0, 0, Q, -1, -1);    repeat (lat + 1) idle();
      cycle(1'b1, 0, 1, Q, 0, 0, -1, -1);    repeat (lat + 1) idle();
      last_mode = 1;
      send(IT_EDGE, 1, Q - 1, Q - 1, Q - 1, 0);
      send(IT_EDGE, 1, 0, 0, 0, 0);
      $display("OOR_TEST: drove %0d out-of-range valid inputs (L1_RANGE must fire %0d times)",
               OOR_N, OOR_N);
    end else begin
      // 1. edge combinations
      for (int m = 0; m < 2; m++)
        foreach (EDGE[ia]) foreach (EDGE[ib]) foreach (EDGE[iz])
          send(IT_EDGE, m, EDGE[ia], EDGE[ib], EDGE[iz], gap_pct);
      $display("PROGRESS: edge done vectors=%0d time=%0t", n_vec[IT_EDGE], $time);

      // 2. z = ROM values
      for (int m = 0; m < 2; m++)
        for (int k = 0; k < 2; k++)             // 0 zeta ROM, 1 gamma ROM
          for (int idx = 0; idx < 128; idx++) begin
            z = mlkem_dpi_rom(ALGO, k, idx);
            if (z < 0 || z >= Q) chk_model.fail($sformatf("rom(%0d, %0d, %0d) = %0d", ALGO, k, idx, z));
            repeat (n_rom) send(IT_ROM, m, rnd_q(), rnd_q(), z, gap_pct);
          end
      for (int m = 0; m < 2; m++) begin
        z = mlkem_dpi_rom(ALGO, 2, 0);
        if (z < 0 || z >= Q) chk_model.fail($sformatf("rom(%0d, 2, 0) = %0d", ALGO, z));
        repeat (n_rom) send(IT_ROM, m, rnd_q(), rnd_q(), z, gap_pct);
      end
      $display("PROGRESS: rom done vectors=%0d time=%0t", n_vec[IT_ROM], $time);

      // 3. full random
      for (int m = 0; m < 2; m++)
        for (int i = 0; i < n_rand; i++) send(IT_RAND, m, rnd_q(), rnd_q(), rnd_q(), gap_pct);
      $display("PROGRESS: rand done vectors=%0d time=%0t", n_vec[IT_RAND], $time);

      // 4. mixed-mode stream, gap 0 % then 25 %
      foreach (want[i]) want[i] = 0;
      for (int g = 0; g < 2; g++) begin
        automatic int m = 0;
        burst = 0;
        for (int i = 0; i < n_mix; i++) begin
          if (mix_mode != 0) m = $urandom_range(1);
          else if (burst == 0) begin
            m     = $urandom_range(1);
            burst = $urandom_range(64, 1);
          end
          if (burst > 0) burst--;
          z = (i % 2 == 0) ? rnd_q() : rnd_rom();
          send(IT_MIX, m, rnd_q(), rnd_q(), z, (g == 0) ? 0 : 25);
        end
      end
      $display("PROGRESS: mix done vectors=%0d time=%0t", n_vec[IT_MIX], $time);

      // 5. trace replay
      replay_transform({vec_dir, "/hw_ntt_trace_", an, ".txt"}, 0, gap_pct, n_ntt);
      replay_transform({vec_dir, "/hw_intt_trace_", an, ".txt"}, 1, gap_pct, n_intt);
      replay_basemul({vec_dir, "/hw_basemul_trace_", an, ".txt"}, gap_pct, n_bm);
      nops = mlkem_dpi_basemul_nops(ALGO);
      $display("TRACE: ntt=%0d intt=%0d basemul=%0d (expected 896 896 %0d)", n_ntt, n_intt,
               n_bm, 128 * nops);
      if (n_ntt != 896 || n_intt != 896 || n_bm != 128 * nops)
        chk_item[IT_TRACE].fail("trace record count");
    end

    repeat (lat + 2) idle();

    $display("VECTORS: edge=%0d rom=%0d rand=%0d mix=%0d trace=%0d", n_vec[IT_EDGE],
             n_vec[IT_ROM], n_vec[IT_RAND], n_vec[IT_MIX], n_vec[IT_TRACE]);
    if (oor_test) begin
      ok = tb_final_report('{chk_item[IT_EDGE], chk_valid, chk_model});
    end else begin
      want[IT_EDGE]  = 2 * N_EDGE * N_EDGE * N_EDGE;
      want[IT_ROM]   = 2 * 257 * longint'(n_rom);
      want[IT_RAND]  = 2 * longint'(n_rand);
      want[IT_MIX]   = 2 * longint'(n_mix);
      want[IT_TRACE] = 896 + 896 + 128 * nops;
      for (int i = 0; i < N_ITEMS; i++) begin
        if (n_vec[i] != want[i])
          chk_item[i].fail($sformatf("vector count %0d != %0d", n_vec[i], want[i]));
        if (chk_item[i].n_checks != n_vec[i])
          chk_item[i].fail($sformatf("check count %0d != vectors %0d", chk_item[i].n_checks, n_vec[i]));
      end
      ok = tb_final_report('{chk_item[IT_EDGE], chk_item[IT_ROM], chk_item[IT_RAND],
                             chk_item[IT_MIX], chk_item[IT_TRACE], chk_valid, chk_model});
    end
    $finish;
  end

endmodule
