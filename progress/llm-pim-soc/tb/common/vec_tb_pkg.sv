// vec_tb_pkg: one vec kernel call (K_ACTQ, K_RMSNORM, K_SWIGLU, K_ARGMAX) for the S4-7 testbenches.
// Every value (inputs of records, outputs, stage traces) comes from the golden model through DPI-C
// (tb/dpi/kdpi.c kd_vec_*: k_actq_st, k_rmsnorm_st, k_swiglu_st, k_argmax); this package only
// chooses synthetic inputs and copies the results.
package vec_tb_pkg;
  import kdpi_pkg::*;

  class vcase;
    int  kid, n, p0, p1, p2;   // ACTQ: f, qmax; RMSNORM: ge, epsc, fy; SWIGLU: sb (8); ARGMAX: -
    int  in0[], in1[];         // x / h1 / v (int32); g (int16 values) / h3 (int32)
    int  q[], y[];             // quantized output; rmsnorm y / swiglu g before quantization
    int  sm, se, idx;          // scale {m, e}, argmax index
    longint amax, ymax, k, re, sh, ss, u, rm, M, R, e;   // stage trace (quantizer: M, R, e)
    int  rec = -1;             // record index, -1 for a synthetic call
    string tag = "";

    function int qmax();
      return kid == K_ACTQ ? p1 : 127;
    endfunction
    function int f();          // exponent offset of the quantizer
      return kid == K_ACTQ ? p0 : kid == K_RMSNORM ? p2 : 16;
    endfunction
    function longint qamax();  // amax seen by the quantizer
      return kid == K_RMSNORM ? ymax : amax;
    endfunction

    // copies the scratch call of kdpi after kd_vec_run
    function void read_back();
      kid = int'(kd_vec_get(VG_KID, 0));
      n   = int'(kd_vec_get(VG_N, 0));
      p0  = int'(kd_vec_get(VG_P0, 0));
      p1  = int'(kd_vec_get(VG_P1, 0));
      p2  = int'(kd_vec_get(VG_P2, 0));
      in0 = new[n]; in1 = new[n]; q = new[n]; y = new[n];
      for (int i = 0; i < n; i++) begin
        in0[i] = int'(kd_vec_get(VG_IN0, i));
        in1[i] = int'(kd_vec_get(VG_IN1, i));
        q[i]   = int'(kd_vec_get(VG_Q, i));
        y[i]   = int'(kd_vec_get(VG_Y, i));
      end
      sm = int'(kd_vec_get(VG_SM, 0)); se = int'(kd_vec_get(VG_SE, 0)); idx = int'(kd_vec_get(VG_IDX, 0));
      amax = kd_vec_get(VG_AMAX, 0); ymax = kd_vec_get(VG_YMAX, 0); k = kd_vec_get(VG_K, 0);
      re = kd_vec_get(VG_RE, 0); sh = kd_vec_get(VG_SH, 0); ss = kd_vec_get(VG_SS, 0);
      u = kd_vec_get(VG_U, 0); rm = kd_vec_get(VG_RM, 0); M = kd_vec_get(VG_M, 0);
      R = kd_vec_get(VG_R, 0); e = kd_vec_get(VG_E, 0);
    endfunction

    // current record (after kd_rec_next): 0 ok, -1 not a vec kernel / not MANT / foreign LUT,
    // -2 the golden replay differs from the recorded outputs
    function int load_rec();
      int k_ = kd_vec_from_rec();
      if (k_ <= 0) return -1;
      void'(kd_vec_run());
      if (kd_vec_rec_cmp() != 0) return -2;
      read_back();
      rec = kd_rec_index();
      tag = $sformatf("rec %0d", rec);
      return 0;
    endfunction

    // random int32 with a magnitude of b bits (b 0: 0), random sign
    static function int rmag(int b);
      longint v;
      if (b <= 0) return 0;
      v = (b >= 32) ? longint'($urandom()) : (longint'($urandom()) & ((64'd1 << b) - 1));
      if (b < 32) v = v | (64'd1 << (b - 1));
      return $urandom_range(1) ? int'(v) : -int'(v);
    endfunction

    // synthetic call: kid, n and a mode that shapes the inputs; parameters chosen here
    function void gen_syn(int kid_, int n_, int mode);
      int qm[3] = '{127, 2047, 32767};
      int b = $urandom_range(31, 1);
      int pa = 0, pb = 0, pc = 0;
      int kr = $urandom_range(16, 1);
      case (kid_)
        K_ACTQ:    begin pa = $urandom_range(3) == 0 ? $urandom_range(255) - 128 : 16; pb = mode == 9 ? 32767 : qm[$urandom_range(2)]; end
        K_RMSNORM: begin pa = $urandom_range(15); pb = $urandom_range(3) == 0 ? int'($urandom() >> 1) : $urandom_range(1 << 22);
                         pc = $urandom_range(7) == 0 ? $urandom_range(255) - 128 : 16; end
        K_SWIGLU:  pa = 8;
        default: ;
      endcase
      void'(kd_vec_begin(kid_, n_, pa, pb, pc));
      for (int i = 0; i < n_; i++) begin
        int v0 = rmag($urandom_range(b)), v1;
        case (mode)
          1: v0 = 0;                                                    // all zero
          2: v0 = (i == n_ / 2) ? ($urandom_range(1) ? 1 : rmag(b)) : 0; // one nonzero
          3: v0 = (i == 0 || $urandom_range(15) == 0) ? 32'h8000_0000 : rmag($urandom_range(31)); // -2^31
          4: v0 = (i == n_ - 1) ? 32'h7FFF_FFFF : rmag($urandom_range(31));
          5: v0 = $urandom_range(2) - 1;                                // amax 1
          6: v0 = $urandom_range(1) ? (1 << (b - 1)) : -(1 << (b - 1)); // all |v| equal
          7: v0 = rmag(b) | 1;                                          // full magnitude b
          // amax = 2^(15 + kk) - 1 at a negative x: rmsnorm rshr(x, k) rounds to -32768 and the
          // clamp to -32767 decides (kk = k >= 1); other x smaller
          8: v0 = (i == n_ / 3) ? -((1 << (15 + kr)) - 1) : rmag($urandom_range(15 + kr - 1));
          // actq qmax 32767: amax 67126271 gives rshr(-amax R, 40 - e) = -32768 before the clamp
          // (found by a C search over k_aq_setup / k_rshr; the only such case in 2e8 random amax)
          9: v0 = (i == n_ / 2) ? -67126271 : (i == 0 ? 67126271 : rmag($urandom_range(26)));
          default: ;
        endcase
        void'(kd_vec_set(0, i, v0));
        case (kid_)
          K_RMSNORM: begin
            v1 = int'($urandom()) >>> 16;                               // int16
            if (mode == 6) v1 = $urandom_range(1) ? -32768 : 32767;
            if (mode == 1 && $urandom_range(1)) begin v1 = 0; void'(kd_vec_set(0, i, rmag(b))); end
            void'(kd_vec_set(1, i, v1));
          end
          K_SWIGLU: begin
            v1 = rmag($urandom_range(31));
            if (mode == 3) v1 = $urandom_range(1) ? 32'h8000_0000 : 32'h7FFF_FFFF;
            if (mode == 5) v1 = rmag(b);
            void'(kd_vec_set(1, i, v1));
          end
          K_ARGMAX: if (mode == 6 || mode == 5) void'(kd_vec_set(0, i, $urandom_range(2) - 1)); // ties
          default: ;
        endcase
      end
      void'(kd_vec_run());
      read_back();
      rec = -1;
      tag = $sformatf("syn mode %0d", mode);
    endfunction

    function string desc();
      return $sformatf("%s kid %0d n %0d prm %0d %0d %0d", tag, kid, n, p0, p1, p2);
    endfunction
  endclass

  // bit length of an unsigned value (0 for 0)
  function automatic int bitlen(longint unsigned v);
    int L = 0;
    for (int i = 0; i < 64; i++) if (v[i]) L = i + 1;
    return L;
  endfunction

endpackage
