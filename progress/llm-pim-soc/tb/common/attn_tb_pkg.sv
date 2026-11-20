// attn_tb_pkg: one attention call (head) for the S4-6 testbenches. Every value (inputs, stage
// trace, outputs) is read back from the DPI scratch call of tb/dpi/kdpi.c (k_attn2_st of
// model/src/kern.c, LUT k_exp_lut(8)): a case comes either from the current K_ATTN2 / K_ATTN
// record (load_rec) or from random inputs set by gen_syn and run through the golden.
//
// gen_syn modes (synthetic inputs; values stay inside the golden preconditions: q, K, V inside
// their kb / vb bit range (-2^(b-1) included), mantissas < 2^17, exponents signed 8-bit):
//   0 mixed random (T 1..tmax, hs 1..hsmax, kb / vb in {8, 12, 16}, about 25 % vs.m = 0)
//   1 all scores equal (qm = 0 or identical K rows)
//   2 saturation: huge qm km with small exponents (s saturates to +-2^31), and the clamp
//     d < -2^30 in P2
//   3 every vs.m = 0 (have = 0, o = 0)
//   4 extreme exponents (shifts beyond the operand widths, negative shifts)
//   5 T = tmax and hs = hsmax with full-range values
package attn_tb_pkg;
  import kdpi_pkg::*;

  class att_case;
    int T, hs, kb, vb, qm, qe, d0;
    int q[], K[], V[];          // K, V: index t * hs + i
    int ksm[], kse[], vsm[], vse[];
    // golden outputs and trace
    int p[], o[], s[], e[];
    longint w[], acc[], dot[];
    int mx, emin, mmax, G, have;
    longint sum, R;
    string tag;

    // reads everything from the DPI scratch call (after kd_att_run)
    function void read_back();
      T  = int'(kd_att_get(AG_T, 0));  hs = int'(kd_att_get(AG_HS, 0));
      kb = int'(kd_att_get(AG_KB, 0)); vb = int'(kd_att_get(AG_VB, 0));
      qm = int'(kd_att_get(AG_QM, 0)); qe = int'(kd_att_get(AG_QE, 0));
      d0 = int'(kd_att_get(AG_D0, 0)); mx = int'(kd_att_get(AG_MX, 0));
      sum = kd_att_get(AG_SUM, 0); R = kd_att_get(AG_R, 0);
      emin = int'(kd_att_get(AG_EMIN, 0)); mmax = int'(kd_att_get(AG_MMAX, 0));
      G = int'(kd_att_get(AG_G, 0)); have = int'(kd_att_get(AG_HAVE, 0));
      q = new[hs]; o = new[hs]; acc = new[hs];
      K = new[T * hs]; V = new[T * hs];
      ksm = new[T]; kse = new[T]; vsm = new[T]; vse = new[T];
      p = new[T]; s = new[T]; e = new[T]; w = new[T]; dot = new[T];
      foreach (q[i]) begin
        q[i] = int'(kd_att_get(AG_Q, i)); o[i] = int'(kd_att_get(AG_O, i)); acc[i] = kd_att_get(AG_ACC, i);
      end
      foreach (K[i]) begin
        K[i] = int'(kd_att_get(AG_K, i)); V[i] = int'(kd_att_get(AG_V, i));
      end
      for (int t = 0; t < T; t++) begin
        ksm[t] = int'(kd_att_get(AG_KSM, t)); kse[t] = int'(kd_att_get(AG_KSE, t));
        vsm[t] = int'(kd_att_get(AG_VSM, t)); vse[t] = int'(kd_att_get(AG_VSE, t));
        p[t] = int'(kd_att_get(AG_P, t)); s[t] = int'(kd_att_get(AG_S, t));
        e[t] = int'(kd_att_get(AG_E, t)); w[t] = kd_att_get(AG_W, t); dot[t] = kd_att_get(AG_DOT, t);
      end
    endfunction

    // current record of the open record file; returns 0, or the kd_att_from_rec error
    function int load_rec();
      int rc = kd_att_from_rec();
      if (rc != 0) return rc;
      void'(kd_att_run());
      read_back();
      tag = $sformatf("rec %0d", kd_rec_index());
      if (kd_att_rec_cmp() != 0) return -3;  // trace run differs from the recorded outputs
      return 0;
    endfunction

    static function int rv(int b);  // random value of a b-bit signed range
      int k = $urandom_range(99);
      int lim = (1 << (b - 1));
      if (k < 3) return -lim;
      if (k < 6) return lim - 1;
      if (k < 10) return 0;
      if (k < 50) return int'($urandom_range(2 * lim - 1)) - lim;
      begin
        int r = $urandom_range(b - 1);  // magnitude class: [-2^r, 2^r - 1]
        return int'($urandom_range((1 << r) * 2 - 1)) - (1 << r);
      end
    endfunction

    static function int rm();  // random 17-bit mantissa (nonzero, mostly normalized)
      int k = $urandom_range(9);
      if (k < 6) return 65536 + $urandom_range(65535);
      if (k < 8) return 1 + $urandom_range(131070);
      return k == 8 ? 1 : 131071;
    endfunction

    function void gen_syn(int mode, int tmax, int hsmax);
      int kbs[3] = '{8, 12, 16};
      int Tn, hn, kbn, vbn, qmn, qen, ebase, vbase;
      int clampv;
      Tn  = $urandom_range(9) < 2 ? $urandom_range(4, 1) : $urandom_range(tmax, 1);
      hn  = $urandom_range(3) == 0 ? hsmax : $urandom_range(hsmax, 1);
      if ($urandom_range(2) == 0) hn = ((hn + 7) / 8) * 8 > hsmax ? hn : ((hn + 7) / 8) * 8;
      kbn = kbs[$urandom_range(2)];
      vbn = kbs[$urandom_range(2)];
      if (mode == 5) begin Tn = tmax; hn = hsmax; end
      qmn = rm();
      ebase = $urandom_range(30, 10);
      qen = ebase + $urandom_range(6) - 3;
      vbase = $urandom_range(40);
      if (mode == 4) begin
        qen = $urandom_range(1) ? 127 - $urandom_range(10) : -128 + $urandom_range(10);
        ebase = $urandom_range(255) - 128;
      end
      if (mode == 1 && $urandom_range(1)) qmn = 0;
      void'(kd_att_begin(Tn, hn, kbn, vbn, qmn, qen));
      for (int i = 0; i < hn; i++) void'(kd_att_set(AS_Q, i, rv(kbn)));
      for (int t = 0; t < Tn; t++) begin
        int km = rm(), ke = ebase + $urandom_range(6) - 3;
        int vm = $urandom_range(3) == 0 ? 0 : rm(), ve = vbase + $urandom_range(12) - 6;
        if (mode == 2) begin
          km = 131071 - $urandom_range(3);
          ke = -($urandom_range(30));
        end
        if (mode == 3) vm = 0;
        if (mode == 4) begin
          ke = $urandom_range(255) - 128;
          ve = $urandom_range(255) - 128;
        end
        if (mode == 1) begin
          km = 65536;
          ke = ebase;
        end
        void'(kd_att_set(AS_KSM, t, km)); void'(kd_att_set(AS_KSE, t, ke));
        void'(kd_att_set(AS_VSM, t, vm)); void'(kd_att_set(AS_VSE, t, ve));
        for (int i = 0; i < hn; i++) begin
          int kv = rv(kbn);
          if (mode == 1) kv = (i * 37 + 11) % (1 << (kbn - 2));  // identical rows
          if (mode == 2 && $urandom_range(1)) kv = $urandom_range(1) ? (1 << (kbn - 1)) - 1 : -(1 << (kbn - 1));
          void'(kd_att_set(AS_K, t * hn + i, kv));
          void'(kd_att_set(AS_V, t * hn + i, rv(vbn)));
        end
      end
      if (mode == 2) begin
        // a few positions far below the maximum (P2 clamp at -2^30)
        clampv = 0;
        for (int t = 0; t < Tn; t += 3) begin
          void'(kd_att_set(AS_KSM, t, 1));
          void'(kd_att_set(AS_KSE, t, 100));
          clampv++;
        end
      end
      void'(kd_att_run());
      read_back();
      tag = $sformatf("syn mode %0d", mode);
    endfunction

    function string desc();
      return $sformatf("%s T %0d hs %0d kb %0d vb %0d", tag, T, hs, kb, vb);
    endfunction
  endclass

endpackage
