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

endpackage
