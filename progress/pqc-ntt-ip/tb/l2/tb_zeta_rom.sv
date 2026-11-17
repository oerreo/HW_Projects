// tb_zeta_rom: self-checking testbench for the L2 constant ROM zeta_rom.
//
// DUT: zeta_rom with ALGO and OUT_REG from the TB parameters.
// Expected values: golden model DPI-C mlkem_dpi_rom(algo, kind, index)
// (kind 0 zeta, 1 gamma, 2 K2 with index 0).
//
// Items (one check = one read compared at its data cycle):
//   sweep : every address of the zeta and gamma ROM in order, then K2 at
//           address 0 and at 127 (address must be ignored). 258 reads.
//   rand  : N_RAND reads with random kind (0..2) and address; en_i dropped
//           with probability GAP_PCT per cycle while junk kind/address are
//           driven.
//   hold  : OUT_REG = 1 only: in every cycle with en_i = 0, data_o must keep
//           the value of the last read.
//   hex_xcheck: the DPI values are compared with the committed ROM files
//           rtl/l2/rom/rom_{zeta,gamma,k2}_<algo>.hex ($readmemh), i.e. the
//           generator input equals the golden model (258 checks).
// Inputs are driven at the rising edge, outputs checked at the falling edge.
//
// Plusargs: +SEED=<n> (1) +N_RAND=<n> (20000) +GAP_PCT=<n> (25)
//           +ROM_DIR=<dir> (../../rtl/l2/rom)
`timescale 1ns / 1ps

module tb_zeta_rom;
  import mlkem_pkg::*;
  import ntt_l2_pkg::*;
  import mlkem_dpi_pkg::*;
  import tb_util_pkg::*;

  parameter int ALGO    = 0;
  parameter int OUT_REG = 1;

  localparam time T_CLK = 10ns;

  logic              clk    = 1'b0;
  logic              rst_n  = 1'b0;
  logic              en_i   = 1'b0;
  rom_kind_e         kind_i = ROM_ZETA;
  logic [ROM_AW-1:0] addr_i = '0;
  logic [COEF_W-1:0] data_o;

  zeta_rom #(.ALGO(algo_e'(ALGO)), .OUT_REG(OUT_REG)) dut (.*);

  always #(T_CLK / 2) clk = ~clk;

  tb_checker chk_sweep, chk_rand, chk_hold, chk_hex;
  int        lat;

  function automatic string algo_name(int a);
    case (a)
      0: return "barrett";
      1: return "mont12";
      2: return "shiftadd";
      3: return "k2red";
      default: return "?";
    endcase
  endfunction

  // pending read: expected value checked lat cycles after issue
  typedef struct { bit v; int kind; int addr; int exp; tb_checker chk; } rd_t;
  rd_t pend [0:1];
  logic [COEF_W-1:0] last_data;
  bit                last_known;

  task automatic cycle(bit en, int kind, int addr, tb_checker chk);
    rd_t r;
    @(posedge clk);
    en_i   <= en;
    kind_i <= rom_kind_e'(kind[1:0]);
    addr_i <= ROM_AW'(addr);
    pend[1] = pend[0];
    r.v    = en;
    r.kind = kind;
    r.addr = addr;
    r.exp  = en ? mlkem_dpi_rom(ALGO, kind, (kind == 2) ? 0 : addr) : -1;
    r.chk  = chk;
    pend[0] = r;
    @(negedge clk);
    // OUT_REG = 0: the read issued in this cycle is visible now.
    // OUT_REG = 1: the read issued in the previous cycle is visible now.
    if (pend[lat].v) begin
      if (data_o === COEF_W'(pend[lat].exp)) pend[lat].chk.pass();
      else pend[lat].chk.fail($sformatf("kind %0d addr %0d: expected %03h got %03h",
                                        pend[lat].kind, pend[lat].addr, pend[lat].exp, data_o));
      last_data  = data_o;
      last_known = 1'b1;
    end else if (lat == 1 && last_known) begin
      if (data_o === last_data) chk_hold.pass();
      else chk_hold.fail($sformatf("data_o changed to %03h while en_i = 0 (last read %03h)",
                                   data_o, last_data));
    end
  endtask

  task automatic xcheck_hex(string dir);
    logic [COEF_W-1:0] tz [ROM_DEPTH];
    logic [COEF_W-1:0] tg [ROM_DEPTH];
    logic [COEF_W-1:0] tk [1];
    string an = algo_name(ALGO);
    $readmemh({dir, "/rom_zeta_", an, ".hex"}, tz);
    $readmemh({dir, "/rom_gamma_", an, ".hex"}, tg);
    $readmemh({dir, "/rom_k2_", an, ".hex"}, tk);
    for (int i = 0; i < ROM_DEPTH; i++) begin
      if (tz[i] === COEF_W'(mlkem_dpi_rom(ALGO, 0, i))) chk_hex.pass();
      else chk_hex.fail($sformatf("zeta[%0d]: file %03h DPI %03h", i, tz[i], mlkem_dpi_rom(ALGO, 0, i)));
      if (tg[i] === COEF_W'(mlkem_dpi_rom(ALGO, 1, i))) chk_hex.pass();
      else chk_hex.fail($sformatf("gamma[%0d]: file %03h DPI %03h", i, tg[i], mlkem_dpi_rom(ALGO, 1, i)));
    end
    if (tk[0] === COEF_W'(mlkem_dpi_rom(ALGO, 2, 0))) chk_hex.pass();
    else chk_hex.fail($sformatf("K2: file %03h DPI %03h", tk[0], mlkem_dpi_rom(ALGO, 2, 0)));
  endtask

  initial begin
    int unsigned seed;
    int          n_rand, gap_pct, n_sweep;
    string       rom_dir;
    bit          ok;

    seed    = tb_seed_from_plusarg();
    n_rand  = 20000;
    gap_pct = 25;
    rom_dir = "../../rtl/l2/rom";
    void'($value$plusargs("N_RAND=%d", n_rand));
    void'($value$plusargs("GAP_PCT=%d", gap_pct));
    void'($value$plusargs("ROM_DIR=%s", rom_dir));
    lat = dut.LATENCY;
    chk_sweep = new("sweep");
    chk_rand  = new("rand");
    chk_hold  = new("hold");
    chk_hex   = new("hex_xcheck");
    pend[0].v = 0;
    pend[1].v = 0;
    last_known = 0;
    $display("TB_CONFIG: tb_zeta_rom ALGO=%0d(%s) OUT_REG=%0d LATENCY=%0d SEED=%0d N_RAND=%0d GAP_PCT=%0d",
             ALGO, algo_name(ALGO), OUT_REG, lat, seed, n_rand, gap_pct);
    if (lat != OUT_REG) $fatal(1, "LATENCY %0d != OUT_REG %0d", lat, OUT_REG);

    xcheck_hex(rom_dir);

    repeat (2) cycle(0, 0, 0, chk_rand);
    @(negedge clk);
    rst_n = 1'b1;

    n_sweep = 0;
    for (int k = 0; k < 2; k++)
      for (int a = 0; a < ROM_DEPTH; a++) begin
        cycle(1, k, a, chk_sweep);
        n_sweep++;
      end
    cycle(1, 2, 0, chk_sweep);
    cycle(1, 2, ROM_DEPTH - 1, chk_sweep);
    n_sweep += 2;

    for (int i = 0; i < n_rand; i++) begin
      while ($urandom_range(99) < gap_pct)
        cycle(0, $urandom_range(3), $urandom_range(ROM_DEPTH - 1), chk_rand);
      cycle(1, $urandom_range(2), $urandom_range(ROM_DEPTH - 1), chk_rand);
    end
    repeat (3) cycle(0, $urandom_range(3), $urandom_range(ROM_DEPTH - 1), chk_rand);

    if (chk_sweep.n_checks != longint'(n_sweep))
      chk_sweep.fail($sformatf("check count %0d != %0d", chk_sweep.n_checks, n_sweep));
    if (chk_rand.n_checks != longint'(n_rand))
      chk_rand.fail($sformatf("check count %0d != %0d", chk_rand.n_checks, n_rand));
    if (OUT_REG == 1)
      ok = tb_final_report('{chk_sweep, chk_rand, chk_hold, chk_hex});
    else
      ok = tb_final_report('{chk_sweep, chk_rand, chk_hex});
    $finish;
  end

endmodule
