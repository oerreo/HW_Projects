// kdpi_pkg: DPI-C imports of the golden model wrapper tb/dpi/kdpi.c (model/src kernels,
// stage functions, row records, PIM bank image). Compiled with DPI=1 in sim/tests/<name>.cfg.
//
// Record files: model/build/vec/<m1|m2>/<kernel>.bin (vt job split, model/README.md).
// Buffer order per kernel: model/src/kern.h ("Descriptor layout per kernel").
package kdpi_pkg;

  // kernel ids (model/src/kern.h)
  localparam int K_EMBED = 1, K_GEMV = 2, K_RMSNORM = 3, K_ACTQ = 4, K_ROPE = 5, K_ATTN = 6,
                 K_SWIGLU = 7, K_ADD = 8, K_ARGMAX = 9, K_TOPK = 10, K_ATTN2 = 11;

  // ---- record file ----
  import "DPI-C" function int kd_rec_open(input string path);  // 0 ok, -1 no file
  import "DPI-C" function int kd_rec_close();
  import "DPI-C" function int kd_rec_next();                   // kid, 0 at EOF, -1 format error
  import "DPI-C" function int kd_rec_index();                  // 0-based index of the current record
  import "DPI-C" function int kd_rec_kid();
  import "DPI-C" function int kd_rec_np();
  import "DPI-C" function int kd_rec_prm(input int i);
  import "DPI-C" function int kd_rec_nb();
  import "DPI-C" function int kd_rec_esz(input int b);
  import "DPI-C" function int kd_rec_n(input int b);
  import "DPI-C" function int kd_rec_out(input int b);
  import "DPI-C" function int kd_rec_get(input int b, input int i);   // sign-extended
  import "DPI-C" function int kd_rec_getu(input int b, input int i);  // zero-extended
  import "DPI-C" function int kd_rec_replay();  // differing output elements, -1 if rejected

  // ---- K_GEMV record helpers ----
  import "DPI-C" function longint kd_rec_gemv_s(input int r);    // k_gemv_row
  import "DPI-C" function int kd_rec_gemv_acc(input int r);      // k_dot8 of row r (gs == n)
  import "DPI-C" function int kd_rec_rrec_nbeat();               // 1 + ceil(n/8)
  import "DPI-C" function longint kd_rec_rrec_beat(input int r, input int j);  // row record beat
  import "DPI-C" function int kd_rec_bimg(input int nb);         // words per bank, -1 if gs != n
  import "DPI-C" function longint kd_bimg_lo(input int k, input int a);  // lanes 7..0
  import "DPI-C" function longint kd_bimg_hi(input int k, input int a);  // lanes 15..8
  import "DPI-C" function int kd_bimg_tag(input int k, input int a);     // 16-bit tag

  // ---- scalar stage functions ----
  import "DPI-C" pure function longint kd_rshr(input longint x, input int s);
  import "DPI-C" pure function int kd_sat32(input longint x);
  import "DPI-C" pure function int kd_gemv_out(input longint s, input int xm, input int sh);
  import "DPI-C" pure function int kd_exp2neg(input int u, input int eb);
  import "DPI-C" pure function int kd_sigmoid(input int a, input int sb);
  import "DPI-C" function int kd_rsqrt(input longint u, output int re);
  import "DPI-C" function int kd_dot8(input byte a[], input byte b[], input int n);

  // ---- S4-2 bulk accessors ----
  // n int8 elements of buffer b from element off into v (-1 if not int8 / out of range)
  import "DPI-C" function int kd_rec_bytes(input int b, input int off, inout byte v[], input int n);
  // all row record beats of row r (rrec_pack), returns 1 + ceil(n/8) or -1
  import "DPI-C" function int kd_rec_rrec_row(input int r, inout longint beats[]);
  // y of one synthetic row: k_gemv_out(k_gemv_row(w, wm, x, n, n), xm, sh)
  import "DPI-C" function int kd_gemv1(input byte w[], input byte x[], input int n, input int wm,
                                       input int xm, input int sh);

  // ---- S4-4 ----
  // k_argmax over the first n elements of v (index of the first maximum)
  import "DPI-C" function int kd_argmax(input int v[], input int n);

  // ---- S4-5: PIM bank model (bank_pack BANK_ROW + bank_gemv) ----
  // current K_GEMV record over nb banks: st = {wrgb, mac, rdmac} of this call (bank_stat_t);
  // returns the number of y differing from the recorded y, -1 if not row-wise
  import "DPI-C" function int kd_rec_bank(input int nb, inout longint st[]);
  // synthetic rows x n matrix (w row-major, wm[rows] as 16-bit values, x[n]): y[rows], st
  import "DPI-C" function int kd_bank_syn(input byte w[], input shortint wm[], input byte x[],
                                          input int rows, input int n, input int we, input int xm,
                                          input int xe, input int fo, input int nb,
                                          inout int y[], inout longint st[]);

  // ---- S4-6: attention (src/kern.c k_attn2_st and the A3 stage functions) ----
  import "DPI-C" pure function int kd_attn_score(input longint dot, input int qm, input int km,
                                                 input int qe, input int ke, input int d0);
  import "DPI-C" pure function int kd_attn_exp(input int s, input int mx);    // eb 8
  import "DPI-C" pure function int kd_attn_pn(input int e, input longint r);
  import "DPI-C" pure function longint kd_attn_w(input int p, input int vm, input int ve,
                                                 input int emin, input int g);
  import "DPI-C" pure function int kd_attn_out(input longint acc, input int emin, input int g);
  import "DPI-C" pure function int kd_exp_lut8(input int i);                 // k_exp_lut(8)[i]
  // scratch call: begin (T, hs, kb, vb, qm, qe), set inputs, or load the current K_ATTN2 /
  // K_ATTN record (-1 not attention, -2 LUT is not k_exp_lut(8)); run k_attn2_st; get values
  // (what: 0 p, 1 o, 2 dot, 3 s, 4 e, 5 w, 6 acc, 7 q, 8 K, 9 V, 10 ks.m, 11 ks.e, 12 vs.m,
  //  13 vs.e; scalars 20 T, 21 hs, 22 kb, 23 vb, 24 qm, 25 qe, 30 d0, 31 mx, 32 sum, 33 R,
  //  34 emin, 35 mmax, 36 G, 37 have)
  import "DPI-C" function int kd_att_begin(input int t, input int hs, input int kb, input int vb,
                                           input int qm, input int qe);
  import "DPI-C" function int kd_att_set(input int what, input int i, input int v);
  import "DPI-C" function int kd_att_from_rec();
  import "DPI-C" function int kd_att_run();
  import "DPI-C" function int kd_att_rec_cmp();  // p/o differing from the record's outputs
  import "DPI-C" function longint kd_att_get(input int what, input int i);
  localparam int AG_P = 0, AG_O = 1, AG_DOT = 2, AG_S = 3, AG_E = 4, AG_W = 5, AG_ACC = 6,
                 AG_Q = 7, AG_K = 8, AG_V = 9, AG_KSM = 10, AG_KSE = 11, AG_VSM = 12, AG_VSE = 13,
                 AG_T = 20, AG_HS = 21, AG_KB = 22, AG_VB = 23, AG_QM = 24, AG_QE = 25,
                 AG_D0 = 30, AG_MX = 31, AG_SUM = 32, AG_R = 33, AG_EMIN = 34, AG_MMAX = 35,
                 AG_G = 36, AG_HAVE = 37;
  localparam int AS_Q = 0, AS_K = 1, AS_V = 2, AS_KSM = 3, AS_KSE = 4, AS_VSM = 5, AS_VSE = 6;

endpackage
