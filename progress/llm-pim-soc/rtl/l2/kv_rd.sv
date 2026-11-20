// kv_rd: DDR KV reader of the 15M accelerator system (arch.md 4.2; hierarchy.md 3.4). Reads the
// golden KV buffers of one kv head (model/src/fwd_h.c: kc int16 or int8 rows, vc rows, kcs / vcs
// {int32 m, int32 e} per position) through an axi_rd_eng command / data stream and produces the
// attn_core pass stream.
//
// Request (rq_*, taken while idle): pass (0 = K, 1 = V), T, hs (multiple of 8, = KL x beats),
// ths = T x hs (given by the requester: attn_csr computes it once per call), element sizes (ek2 / ev2: 2-byte elements, else 1 byte) and the byte addresses of position 0
// of this kv head: kaddr (K rows, hs x ek bytes each), vaddr (V rows), ksaddr / vsaddr (8 bytes
// per position: m in bits [31:0], e in [63:32]).
// K pass: per chunk of CH positions (t0, n = min(CH, T - t0)) three read commands: ks (n x 8 B),
// vs (n x 8 B), K rows (n x hs x ek B). Output: per position hs/8 beats of 8 lanes (16-bit,
// sign-extended from ek bytes), every beat with the position's (km, ke, vm, ve).
// V pass: one command (T x hs x ev B); output beats of V lanes (scales 0).
// Command addresses and lengths without a runtime multiplier: ks / vs at 8 t0 (shift), K rows at
// kaddr + koff (koff += CH hs ek per chunk, CH constant), a full chunk CH hs ek bytes, the last
// chunk T hs ek - koff, the V pass T hs ev (from ths).
// Data of one ek / ev = 2 output beat is two input beats (lanes 0..3, 4..7), of ek / ev = 1 one
// input beat. Commands are issued as soon as the engine takes them (it queues them while the
// previous one is still returning data); data arrives in command order.
// Preconditions (attn_top checks them): hs % 8 == 0, T >= 1, aligned addresses, ranges below
// 2^32; scale fields m < 2^17 and e inside E_W bits (L2_RANGE otherwise, low bits used).
module kv_rd
  import llm_pkg::*;
#(
  parameter int KL     = 8,
  parameter int HS_MAX = 64,
  parameter int TMAX   = llm_pkg::T_MAX,
  parameter int CH     = 16,
  localparam int HS_W  = $clog2(HS_MAX + 1),
  localparam int TW    = $clog2(TMAX + 1),
  localparam int TH_W  = TW + HS_W
) (
  input  logic                  clk,
  input  logic                  rst_n,
  // pass request
  input  logic                  rq_valid_i,
  output logic                  rq_ready_o,
  input  logic                  rq_pass_i,
  input  logic [TW-1:0]         rq_t_i,
  input  logic [HS_W-1:0]       rq_hs_i,
  input  logic [TH_W-1:0]       rq_ths_i,      // T x hs (precondition, L2_THS)
  input  logic                  rq_ek2_i,
  input  logic                  rq_ev2_i,
  input  logic [31:0]           rq_kaddr_i,
  input  logic [31:0]           rq_vaddr_i,
  input  logic [31:0]           rq_ksaddr_i,
  input  logic [31:0]           rq_vsaddr_i,
  // read engine command and data
  output logic                  rc_valid_o,
  input  logic                  rc_ready_i,
  output logic [31:0]           rc_addr_o,
  output logic [31:0]           rc_bytes_o,
  input  logic                  d_valid_i,
  output logic                  d_ready_o,
  input  logic [63:0]           d_data_i,
  // pass stream
  output logic                  kv_valid_o,
  input  logic                  kv_ready_i,
  output logic [KL*16-1:0]      kv_data_o,
  output logic [AM_W-1:0]       kv_km_o,
  output logic signed [E_W-1:0] kv_ke_o,
  output logic [AM_W-1:0]       kv_vm_o,
  output logic signed [E_W-1:0] kv_ve_o,
  output logic                  busy_o
);
  localparam int CI_W = $clog2(CH + 1);
  localparam int NG   = HS_MAX / KL;
  localparam int GB_W = (NG > 1) ? $clog2(NG) : 1;

  if (KL != 8) $error("kv_rd: KL=%0d must be 8 (one 64-bit beat holds 8 int8 or 4 int16 lanes)", KL);
  if (HS_MAX % 8 != 0) $error("kv_rd: HS_MAX=%0d must be a multiple of 8", HS_MAX);
  if (CH < 1) $error("kv_rd: CH=%0d must be >= 1", CH);

  // ---------------- request ----------------
  logic            act_q, pass_q, ek2_q, ev2_q;
  logic [TW-1:0]   T_q;
  logic [HS_W-1:0] hs_q;
  logic [TH_W-1:0] ths_q;
  logic [31:0]     ka_q, va_q, ksa_q, vsa_q;
  logic            rq_hs;
  assign rq_ready_o = !act_q;
  assign rq_hs      = rq_valid_i && !act_q;

  localparam int CR_W = HS_W + $clog2(CH + 1); // CH x hs
  logic [CR_W-1:0] chs;
  logic [31:0]     chrow, kall, vall;
  assign chs   = CR_W'(hs_q) * CR_W'(CH);       // constant multiple
  assign chrow = 32'(chs) << ek2_q;             // K bytes of a full chunk
  assign kall  = 32'(ths_q) << ek2_q;           // K bytes of all T positions
  assign vall  = 32'(ths_q) << ev2_q;           // V bytes of all T positions

  // ---------------- command generator ----------------
  logic          cact_q;        // commands left
  logic [1:0]    ck_q;          // K pass: 0 ks, 1 vs, 2 K rows
  logic [TW-1:0] ct0_q;         // chunk start
  logic [TW-1:0] cn;            // positions of the chunk
  logic          clast;         // last chunk shorter than CH
  logic [31:0]   koff_q;        // K row bytes before the chunk: ct0 hs ek
  assign clast = 32'(T_q) - 32'(ct0_q) < CH;
  assign cn    = clast ? TW'(T_q - ct0_q) : TW'(CH);

  always_comb begin
    rc_addr_o  = '0;
    rc_bytes_o = '0;
    if (pass_q) begin
      rc_addr_o  = va_q;
      rc_bytes_o = vall;
    end else
      unique case (ck_q)
        2'd0:    begin rc_addr_o = ksa_q + 32'({ct0_q, 3'b000}); rc_bytes_o = 32'({cn, 3'b000}); end
        2'd1:    begin rc_addr_o = vsa_q + 32'({ct0_q, 3'b000}); rc_bytes_o = 32'({cn, 3'b000}); end
        default: begin rc_addr_o = ka_q + koff_q;  rc_bytes_o = clast ? kall - koff_q : chrow; end
      endcase
  end
  assign rc_valid_o = cact_q;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      cact_q <= 1'b0;
      ck_q   <= '0;
      ct0_q  <= '0;
    end else if (rq_hs) begin
      cact_q <= 1'b1;
      ck_q   <= '0;
      ct0_q  <= '0;
    end else if (cact_q && rc_ready_i) begin
      if (pass_q) cact_q <= 1'b0;
      else if (ck_q != 2'd2) ck_q <= ck_q + 1'b1;
      else begin
        ck_q  <= '0;
        ct0_q <= ct0_q + cn;
        if (32'(ct0_q) + 32'(cn) >= 32'(T_q)) cact_q <= 1'b0;
      end
    end

  always_ff @(posedge clk)
    if (rq_hs) koff_q <= '0;
    else if (cact_q && rc_ready_i && !pass_q && ck_q == 2'd2) koff_q <= koff_q + chrow;

  always_ff @(posedge clk)
    if (rq_hs) begin
      pass_q <= rq_pass_i;
      T_q    <= rq_t_i;
      hs_q   <= rq_hs_i;
      ths_q  <= rq_ths_i;
      ek2_q  <= rq_ek2_i;
      ev2_q  <= rq_ev2_i;
      ka_q   <= rq_kaddr_i;
      va_q   <= rq_vaddr_i;
      ksa_q  <= rq_ksaddr_i;
      vsa_q  <= rq_vsaddr_i;
    end

  // ---------------- data path ----------------
  // ds: 0 ks beats, 1 vs beats, 2 element beats
  logic [1:0]       ds_q;
  logic [TW-1:0]    dt0_q;          // chunk start (K pass)
  logic [CI_W-1:0]  di_q;           // position in chunk / scale index
  logic [GB_W-1:0]  dg_q;           // output beat in position
  logic             dh_q;           // half (2-byte elements)
  logic [TW-1:0]    dn;             // positions of the data chunk
  logic             es2, last_sub, ob_free, d_hs, last_pos, last_g;
  logic [AM_W-1:0]  skm [CH], svm [CH];
  logic [E_W-1:0]   ske [CH], sve [CH];
  logic [63:0]      half_q;
  logic             ov_q;
  logic [KL*16-1:0] od_q;
  logic [AM_W+E_W-1:0] oks_q, ovs_q;
  logic [GB_W-1:0]  nbm1;

  assign dn       = pass_q ? T_q : ((32'(T_q) - 32'(dt0_q) < CH) ? TW'(T_q - dt0_q) : TW'(CH));
  assign es2      = pass_q ? ev2_q : ek2_q;
  assign last_sub = !es2 || dh_q;
  assign ob_free  = !ov_q || kv_ready_i;
  assign nbm1     = GB_W'(32'(hs_q) / KL - 1);
  assign last_g   = dg_q == nbm1;
  assign last_pos = 32'(di_q) == 32'(dn) - 1 || (pass_q && 32'(dt0_q) + 32'(di_q) == 32'(T_q) - 1);
  assign d_ready_o = act_q && (ds_q != 2'd2 || !last_sub || ob_free);
  assign d_hs      = d_valid_i && d_ready_o;

  // output beat from the current input beat (and the held first half)
  logic [KL*16-1:0] obeat;
  always_comb
    for (int l = 0; l < KL; l++)
      if (es2) obeat[l*16 +: 16] = (l < 4) ? half_q[l*16 +: 16] : d_data_i[(l-4)*16 +: 16];
      else     obeat[l*16 +: 16] = 16'($signed(d_data_i[l*8 +: 8]));

  // the position counter of the V pass runs over all T (one chunk); di_q counts inside it
  logic [TW-1:0] vt_q;

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      act_q <= 1'b0;
      ds_q  <= '0;
      dt0_q <= '0;
      di_q  <= '0;
      dg_q  <= '0;
      dh_q  <= 1'b0;
      ov_q  <= 1'b0;
      vt_q  <= '0;
    end else begin
      if (kv_ready_i) ov_q <= 1'b0;
      if (rq_hs) begin
        act_q <= 1'b1;
        ds_q  <= rq_pass_i ? 2'd2 : 2'd0;
        dt0_q <= '0;
        di_q  <= '0;
        dg_q  <= '0;
        dh_q  <= 1'b0;
        vt_q  <= '0;
      end else if (d_hs) begin
        unique case (ds_q)
          2'd0, 2'd1: begin
            if (32'(di_q) == 32'(dn) - 1) begin
              di_q <= '0;
              ds_q <= ds_q + 1'b1;
            end else di_q <= di_q + 1'b1;
          end
          default: begin
            dh_q <= es2 && !dh_q;
            if (last_sub) begin
              ov_q <= 1'b1;
              dg_q <= last_g ? '0 : dg_q + 1'b1;
              if (last_g) begin
                if (pass_q) begin
                  vt_q <= vt_q + 1'b1;
                  if (32'(vt_q) == 32'(T_q) - 1) act_q <= 1'b0;
                end else if (32'(di_q) == 32'(dn) - 1) begin
                  di_q  <= '0;
                  dt0_q <= dt0_q + dn;
                  ds_q  <= 2'd0;
                  if (32'(dt0_q) + 32'(dn) >= 32'(T_q)) act_q <= 1'b0;
                end else di_q <= di_q + 1'b1;
              end
            end
          end
        endcase
      end
    end

  always_ff @(posedge clk) begin
    if (d_hs && ds_q == 2'd0) begin
      skm[di_q] <= AM_W'(d_data_i[31:0]);
      ske[di_q] <= E_W'(d_data_i[63:32]);
    end
    if (d_hs && ds_q == 2'd1) begin
      svm[di_q] <= AM_W'(d_data_i[31:0]);
      sve[di_q] <= E_W'(d_data_i[63:32]);
    end
    if (d_hs && ds_q == 2'd2 && es2 && !dh_q) half_q <= d_data_i;
    if (d_hs && ds_q == 2'd2 && last_sub) begin
      od_q  <= obeat;
      oks_q <= pass_q ? '0 : {ske[di_q], skm[di_q]};
      ovs_q <= pass_q ? '0 : {sve[di_q], svm[di_q]};
    end
  end

  assign kv_valid_o = ov_q;
  assign kv_data_o  = od_q;
  assign {kv_ke_o, kv_km_o} = oks_q;
  assign {kv_ve_o, kv_vm_o} = ovs_q;
  assign busy_o     = act_q || ov_q || cact_q;

  logic unused_last_pos;
  assign unused_last_pos = last_pos;

`ifndef SYNTHESIS
  always @(posedge clk)
    if (rst_n === 1'b1) begin
      if (rq_hs && (rq_t_i == '0 || 32'(rq_t_i) > TMAX || rq_hs_i == '0 || 32'(rq_hs_i) > HS_MAX ||
                    rq_hs_i % 8 != 0))
        $error("L2_RANGE kv_rd %m: request T %0d hs %0d", rq_t_i, rq_hs_i);
      if (rq_hs && 32'(rq_ths_i) != 32'(rq_t_i) * 32'(rq_hs_i))   // simulation-only check
        $error("L2_THS kv_rd %m: request ths %0d != T %0d x hs %0d", rq_ths_i, rq_t_i, rq_hs_i);
      if (d_hs && ds_q != 2'd2 &&
          (d_data_i[31:0] >= 32'(1 << AM_W) || $signed(d_data_i[63:32]) != $signed(E_W'(d_data_i[63:32]))))
        $error("L2_RANGE kv_rd %m: scale m %0d e %0d outside 17 / %0d bits", d_data_i[31:0],
               $signed(d_data_i[63:32]), E_W);
      if (d_valid_i === 1'b1 && !act_q) $error("L2_UNEXP kv_rd %m: read data while idle");
    end
`endif

endmodule
