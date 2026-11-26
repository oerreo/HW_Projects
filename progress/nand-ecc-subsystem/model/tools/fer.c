/* Monte Carlo FER simulator. No command-line arguments (process-privacy.md): config file from env CFG.
 *
 * Keys (defaults in brackets):
 *   code <path>                  QC table (model/code/qc_*.txt) or .alist
 *   chan awgn|tlc|mlc            channel
 *   pts <list>                   AWGN: Eb/N0 dB; tlc: alpha (sigma scale); mlc: P/E cycles N
 *   rate <r>                     AWGN Eb/N0 rate [k/n]
 *   zero_cw 0|1                  all-zero codeword (AFF3CT AZCW) [0]
 *   tlc_tab, days, pe            TLC fit table and condition [data/params/tlc_cui2021.txt, 15, 500]
 *   mlc_t                        MLC retention hours [8760]
 *   page                         page index [0]
 *   grid_g, grid_step            sensing grid points per boundary and step [15, 2.0] (mlc step [0.02])
 *   sense 1|3|5|7, dstep         levels per boundary and soft spacing in grid steps [1, 2]
 *   lut_scale, lut_w             soft LUT scale and width [2.0, 6]; hard reads use +-hardA [hardA 15]
 *   lut_match 1|0, lut_pe, lut_days, lut_alpha   LUT from the channel condition, or a nominal one [1]
 *   awgn_scale                   fixed-point AWGN LLR scale (LLR * scale, round, saturate) [2.0]
 *   decs <list>                  decoder specs separated by spaces, e.g.
 *       ref:spa:flood:it=100  ref:spa:layer:it=50  ref:nms:layer:a=0.75:it=20  ref:oms:flood:b=0.5:it=20
 *       fix:w=6,6,8:nms=12:it=20:et=a  fix:w=6,6,8:oms=1:it=20:et=b    bch (BCH t=73 on the same channel)
 *   stop_dec <i>                 decoder index whose error count stops a point [0]
 *   max_fe, max_frames, max_sec  stop rules per point [50, 1e9, 1e9]
 *   seed                         [1]
 *   out <path>                   result lines appended (one per finished point)
 *   ckpt <path>                  checkpoint, rewritten every ck_sec seconds and at the end of a point
 *   ck_sec [60], run_sec         stop the whole run after run_sec seconds (resume later) [7000]
 * Frame f of point p uses rng_seed(seed ^ (p << 48), f): the run is exactly resumable. */
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "io.h"
#include "../src/bch.h"
#include "../src/chan.h"
#include "../src/code.h"
#include "../src/dec_fix.h"
#include "../src/dec_ref.h"
#include "../src/enc.h"
#include "../src/llr.h"
#include "../src/rng.h"
#include "../src/sense.h"

#define MAXD 8
#define MAXP 64

typedef struct {
  char spec[96];
  int kind;      /* 0 ref, 1 fix, 2 bch */
  dref_cfg_t rc;
  dfix_cfg_t fc;
  dref_t dr;
  dfix_t df;
} dec_t;

typedef struct {
  long frames, fe, fe_info, undet, be_info, iters, fe_ok;
  long cls_err[3];        /* residual bit errors in failed frames: info, p0, dual-diagonal columns */
  long hist[6];           /* residual weight of failed frames: 1-2, 3-5, 6-10, 11-20, 21-50, >50 */
  double t_dec;
} cnt_t;

static int parse_dec(dec_t *d, const char *s)
{
  char buf[96], *tok, *sv;
  memset(d, 0, sizeof *d);
  strncpy(d->spec, s, sizeof d->spec - 1);
  strncpy(buf, s, sizeof buf - 1);
  buf[sizeof buf - 1] = 0;
  tok = strtok_r(buf, ":", &sv);
  if (!tok) return -1;
  if (!strcmp(tok, "bch")) { d->kind = 2; return 0; }
  if (!strcmp(tok, "ref")) {
    d->kind = 0;
    d->rc.iters = 20; d->rc.norm = 1.0; d->rc.et = 1;
    while ((tok = strtok_r(NULL, ":", &sv))) {
      if (!strcmp(tok, "spa")) d->rc.rule = DR_SPA;
      else if (!strcmp(tok, "nms") || !strcmp(tok, "ms")) d->rc.rule = DR_NMS;
      else if (!strcmp(tok, "oms")) d->rc.rule = DR_OMS;
      else if (!strcmp(tok, "flood")) d->rc.layered = 0;
      else if (!strcmp(tok, "layer")) d->rc.layered = 1;
      else if (!strncmp(tok, "it=", 3)) d->rc.iters = atoi(tok + 3);
      else if (!strncmp(tok, "a=", 2)) d->rc.norm = atof(tok + 2);
      else if (!strncmp(tok, "b=", 2)) d->rc.offset = atof(tok + 2);
      else if (!strcmp(tok, "noet")) d->rc.et = 0;
      else return -1;
    }
    return 0;
  }
  if (!strcmp(tok, "fix")) {
    d->kind = 1;
    d->fc.wc = 6; d->fc.wm = 6; d->fc.wa = 8; d->fc.corr = DF_NMS; d->fc.nms_num = 12;
    d->fc.iters = 20; d->fc.et = DF_ET_A;
    while ((tok = strtok_r(NULL, ":", &sv))) {
      if (!strncmp(tok, "w=", 2)) { if (sscanf(tok + 2, "%d,%d,%d", &d->fc.wc, &d->fc.wm, &d->fc.wa) != 3) return -1; }
      else if (!strncmp(tok, "nms=", 4)) { d->fc.corr = DF_NMS; d->fc.nms_num = atoi(tok + 4); }
      else if (!strncmp(tok, "oms=", 4)) { d->fc.corr = DF_OMS; d->fc.oms_beta = atoi(tok + 4); }
      else if (!strncmp(tok, "it=", 3)) d->fc.iters = atoi(tok + 3);
      else if (!strcmp(tok, "et=a")) d->fc.et = DF_ET_A;
      else if (!strcmp(tok, "et=b")) d->fc.et = DF_ET_B;
      else if (!strcmp(tok, "et=none")) d->fc.et = DF_ET_NONE;
      else return -1;
    }
    return 0;
  }
  return -1;
}

/* P(Binomial(n, p) > t) */
static double binom_tail(int n, double p, int t)
{
  double s = 0;
  int i;
  for (i = t + 1; i <= n; i++) {
    double lp = lgamma(n + 1.0) - lgamma(i + 1.0) - lgamma(n - i + 1.0) + i * log(p) + (n - i) * log1p(-p);
    double v = exp(lp);
    s += v;
    if (i > t + 10 && v < s * 1e-16) break;
  }
  return s;
}

static FILE *open_out(const char *path)
{
  FILE *f = fopen(path, "a");
  if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(1); }
  return f;
}

int main(void)
{
  code_t code;
  genc_t ge;
  bch_t bch;
  chan_t ch, chn;
  grid_t grid;
  rdcfg_t rc, rch;
  llrlut_t lut, luth;
  dec_t dec[MAXD];
  cnt_t cnt[MAXD];
  double pts[MAXP];
  int npts, nd = 0, p, i, use_genc = 0, have_bch = 0, n, k, chan_kind;
  const char *cpath, *cs, *outp, *ckp;
  char decs[1024], *tok, *sv;
  long max_fe, max_frames, seed;
  double max_sec, run_sec, ck_sec, t_run0;
  uint8_t *u, *cw, *hard, *q, *ub, *cb, *qb;
  int8_t *lq;
  double *lf;
  FILE *fo;
  long start_frame = 0;
  int start_pt = 0;
  cnt_t start_cnt[MAXD];
  char *tabtxt = NULL;
  long start_hard = 0;
  double awgn_scale;
  double prof_msg = 0, prof_enc = 0, prof_chan = 0, prof_llr = 0, prof_bch = 0;

  if (cfg_load()) { fprintf(stderr, "no config (CFG)\n"); return 1; }
  cpath = cfg_s("code", NULL);
  if (!cpath || io_code(&code, cpath)) { fprintf(stderr, "code load failed\n"); return 1; }
  n = code.n;
  cs = cfg_s("chan", "awgn");
  chan_kind = !strcmp(cs, "awgn") ? 0 : !strcmp(cs, "tlc") ? 1 : !strcmp(cs, "mlc") ? 2 : -1;
  if (chan_kind < 0) { fprintf(stderr, "bad chan\n"); return 1; }
  npts = cfg_list("pts", pts, MAXP);
  max_fe = cfg_i("max_fe", 50);
  max_frames = (long)cfg_d("max_frames", 1e9);
  max_sec = cfg_d("max_sec", 1e9);
  run_sec = cfg_d("run_sec", 7000);
  ck_sec = cfg_d("ck_sec", 60);
  seed = cfg_i("seed", 1);
  awgn_scale = cfg_d("awgn_scale", 2.0);
  outp = cfg_s("out", "fer.out");
  ckp = cfg_s("ckpt", NULL);
  /* encoder: QC dual diagonal, otherwise generic elimination */
  if (!(code.qc && code.ddiag)) {
    if (genc_build(&ge, &code)) { fprintf(stderr, "genc failed\n"); return 1; }
    use_genc = 1;
    k = ge.k;
  } else k = code.k;
  /* decoders */
  strncpy(decs, cfg_s("decs", "ref:spa:flood:it=50"), sizeof decs - 1);
  decs[sizeof decs - 1] = 0;
  for (tok = strtok_r(decs, " \t", &sv); tok && nd < MAXD; tok = strtok_r(NULL, " \t", &sv)) {
    if (parse_dec(&dec[nd], tok)) { fprintf(stderr, "bad decoder spec %s\n", tok); return 1; }
    if (dec[nd].kind == 0 && dref_init(&dec[nd].dr, &code, &dec[nd].rc)) return 1;
    if (dec[nd].kind == 1 && dfix_init(&dec[nd].df, &code, &dec[nd].fc)) { fprintf(stderr, "dfix_init failed\n"); return 1; }
    if (dec[nd].kind == 2) {
      if (chan_kind == 0) { fprintf(stderr, "bch needs a NAND channel\n"); return 1; }
      if (!have_bch && bch_init(&bch, 14, 0x4443, 73, 8192)) { fprintf(stderr, "bch init failed\n"); return 1; }
      have_bch = 1;
    }
    nd++;
  }
  u = calloc(k + 64, 1); cw = calloc(n, 1); hard = calloc(n, 1); q = calloc(n + 9216, 1);
  lq = calloc(n, 1); lf = calloc(n, sizeof(double));
  ub = calloc(9216, 1); cb = calloc(9216, 1); qb = calloc(9216, 1);
  if (chan_kind == 1) {
    tabtxt = io_read(cfg_s("tlc_tab", "../data/params/tlc_cui2021.txt"), NULL);
    if (!tabtxt) { fprintf(stderr, "no tlc table\n"); return 1; }
  }
  /* resume */
  memset(start_cnt, 0, sizeof start_cnt);
  if (ckp) {
    FILE *f = fopen(ckp, "r");
    if (f) {
      int d2, nd2;
      if (fscanf(f, "ckpt %d %ld %d %ld", &start_pt, &start_frame, &nd2, &start_hard) == 4 && nd2 == nd) {
        for (d2 = 0; d2 < nd; d2++) {
          cnt_t *c = &start_cnt[d2];
          if (fscanf(f, "%ld %ld %ld %ld %ld %ld %ld %ld %ld %ld %ld %ld %ld %ld %ld %ld %lf", &c->frames, &c->fe,
                     &c->fe_info, &c->undet, &c->be_info, &c->iters, &c->fe_ok, &c->cls_err[0], &c->cls_err[1],
                     &c->cls_err[2], &c->hist[0], &c->hist[1], &c->hist[2], &c->hist[3], &c->hist[4], &c->hist[5],
                     &c->t_dec) != 17) { start_pt = 0; start_frame = 0; memset(start_cnt, 0, sizeof start_cnt); break; }
        }
        fprintf(stderr, "resume point %d frame %ld\n", start_pt, start_frame);
      }
      fclose(f);
    }
  }
  fo = open_out(outp);
  if (start_pt == 0 && start_frame == 0) {
    fprintf(fo, "# code %s n %d k %d chan %s seed %ld max_fe %ld\n", cpath, n, k, cs, seed, max_fe);
    for (i = 0; i < nd; i++) fprintf(fo, "# dec%d %s\n", i, dec[i].spec);
    fflush(fo);
  }
  t_run0 = io_now();
  for (p = start_pt; p < npts; p++) {
    double x = pts[p], sigma = 0, rate, rb_ana = 0, rb_tab = 0, t0 = io_now(), t_ck = io_now();
    long f, hard_err = 0;
    int stop = 0;
    /* channel set-up */
    if (chan_kind == 0) {
      rate = cfg_d("rate", (double)k / n);
      sigma = sqrt(1.0 / (2.0 * rate * pow(10.0, x / 10.0)));
    } else {
      double mu[8], sg[8];
      int page = (int)cfg_i("page", 0), lev = (int)cfg_i("sense", 1), ds = (int)cfg_i("dstep", 2);
      int G = (int)cfg_i("grid_g", 15), w = (int)cfg_i("lut_w", 6);
      double step;
      if (chan_kind == 1) {
        if (chan_tlc_lookup(tabtxt, (int)cfg_i("days", 15), (int)cfg_i("pe", 500), mu, sg) ||
            chan_tlc(&ch, mu, sg, x)) { fprintf(stderr, "tlc condition not found\n"); return 1; }
        step = cfg_d("grid_step", 2.0);
      } else {
        mlc_param_t mp;
        mlc_param_default(&mp);
        if (chan_mlc(&ch, &mp, x, cfg_d("mlc_t", 8760))) { fprintf(stderr, "mlc failed\n"); return 1; }
        step = cfg_d("grid_step", 0.02);
      }
      if (grid_build(&grid, &ch, page, G, step, NULL)) { fprintf(stderr, "grid failed\n"); return 1; }
      if (rdcfg_make(&rc, &grid, lev, ds, NULL) || rdcfg_make(&rch, &grid, 1, 1, NULL)) { fprintf(stderr, "rdcfg failed\n"); return 1; }
      /* LUT channel: matched, or a nominal condition */
      if (cfg_i("lut_match", 1)) chn = ch;
      else if (chan_kind == 1) {
        if (chan_tlc_lookup(tabtxt, (int)cfg_i("lut_days", 30), (int)cfg_i("lut_pe", 3000), mu, sg)) return 1;
        chan_tlc(&chn, mu, sg, cfg_d("lut_alpha", x));
      } else { fprintf(stderr, "mlc nominal LUT not supported\n"); return 1; }
      if (lev == 1) llr_build_hard(&lut, &rc, w, (int)cfg_i("hardA", 15));
      else llr_build(&lut, &grid, &chn, &rc, w, cfg_d("lut_scale", 2.0));
      llr_build_hard(&luth, &rch, w, (int)cfg_i("hardA", 15));
      rb_ana = rber_analytic(&grid, &ch, &rch);
      rb_tab = rber_table(&grid, &rch);
      if (p == start_pt && start_frame == 0) {
        fprintf(fo, "# pt %g refs", x);
        for (i = 0; i < grid.B; i++) fprintf(fo, " %.3f", grid.ref[i]);
        fprintf(fo, " lut");
        for (i = 0; i < rc.nreg; i++) fprintf(fo, " %d", lut.lut[i]);
        fprintf(fo, "\n");
      }
    }
    if (p == start_pt) { memcpy(cnt, start_cnt, sizeof cnt); hard_err = start_hard; }
    else { memset(cnt, 0, sizeof cnt); start_frame = 0; hard_err = 0; }
    for (f = (p == start_pt ? start_frame : 0); !stop; f++) {
      rng_t r;
      double ta, tb;
      int d;
      rng_seed(&r, (uint64_t)seed ^ ((uint64_t)p << 48), (uint64_t)f);
      ta = io_now();
      if (!cfg_i("zero_cw", 0)) {
        for (i = 0; i < k; i += 32) {
          uint32_t w32 = rng_next(&r);
          int j;
          for (j = 0; j < 32 && i + j < k; j++) u[i + j] = (w32 >> j) & 1;
        }
      } else memset(u, 0, (size_t)k);
      tb = io_now(); prof_msg += tb - ta; ta = tb;
      if (use_genc) genc_encode(&ge, u, cw);
      else enc_qc(&code, u, cw);
      tb = io_now(); prof_enc += tb - ta; ta = tb;
      if (chan_kind == 0) {
        for (i = 0; i < n; i++) {
          double y = (cw[i] ? -1.0 : 1.0) + sigma * rng_gauss(&r);
          lf[i] = 2.0 * y / (sigma * sigma);
          hard_err += (y < 0) != cw[i];
        }
        tb = io_now(); prof_chan += tb - ta; ta = tb;
        tb = io_now(); prof_llr += tb - ta; ta = tb;
      } else {
        chan_sample(&grid, cw, n, &r, q);
        tb = io_now(); prof_chan += tb - ta; ta = tb;
        llr_map(&lut, q, n, lq);
        llr_map_f(&lut, &rc, q, n, lf);
        for (i = 0; i < n; i++) hard_err += (luth.full[q[i]] < 0) != cw[i];
        tb = io_now(); prof_llr += tb - ta; ta = tb;
      }
      for (d = 0; d < nd; d++) {
        cnt_t *c = &cnt[d];
        int ok = 0, nerr = 0, nei = 0;
        double t1 = io_now();
        if (dec[d].kind == 2) {
          /* BCH frame: own message and cells from a separate stream */
          rng_t r2;
          int j;
          rng_seed(&r2, (uint64_t)seed ^ ((uint64_t)p << 48) ^ 0xBC4ull, (uint64_t)f);
          for (j = 0; j < bch.k; j++) ub[j] = rng_next(&r2) & 1;
          bch_encode(&bch, ub, cb);
          chan_sample(&grid, cb, bch.n, &r2, qb);
          for (j = 0; j < bch.n; j++) qb[j] = luth.full[qb[j]] < 0;   /* hard bits */
          ok = bch_decode(&bch, qb, NULL) == 0;
          for (j = 0; j < bch.n; j++) nerr += qb[j] != cb[j];
          for (j = bch.r; j < bch.n; j++) nei += qb[j] != cb[j];
          c->t_dec += io_now() - t1;
          prof_bch += io_now() - t1;
          c->frames++;
          if (nerr) { c->fe++; if (ok) c->undet++; }
          if (nei) c->fe_info++;
          c->be_info += nei;
          continue;
        }
        if (dec[d].kind == 0) {
          ok = dref_decode(&dec[d].dr, lf, hard);
          c->iters += dec[d].dr.iters_used;
        } else {
          if (chan_kind == 0) {
            const double sc = awgn_scale;
            for (i = 0; i < n; i++) lq[i] = (int8_t)llr_quant(lf[i], sc, dec[d].fc.wc);
          }
          ok = dfix_decode(&dec[d].df, lq);
          memcpy(hard, dec[d].df.hard, (size_t)n);
          c->iters += dec[d].df.iters_used;
        }
        c->t_dec += io_now() - t1;
        c->frames++;
        for (i = 0; i < n; i++) if (hard[i] != cw[i]) nerr++;
        if (use_genc) { for (i = 0; i < k; i++) nei += hard[ge.info_col[i]] != cw[ge.info_col[i]]; }
        else for (i = 0; i < k; i++) nei += hard[i] != cw[i];
        c->be_info += nei;
        if (nei) c->fe_info++;
        if (ok) c->fe_ok++;
        if (nerr) {
          c->fe++;
          if (ok) c->undet++;
          if (code.qc) {
            int ni = (code.nb - code.mb) * code.Z;
            for (i = 0; i < n; i++)
              if (hard[i] != cw[i]) c->cls_err[i < ni ? 0 : (i < ni + code.Z ? 1 : 2)]++;
          }
          c->hist[nerr <= 2 ? 0 : nerr <= 5 ? 1 : nerr <= 10 ? 2 : nerr <= 20 ? 3 : nerr <= 50 ? 4 : 5]++;
        }
      }
      {
        int si = (int)cfg_i("stop_dec", 0);
        double now = io_now();
        if (cnt[si].fe >= max_fe || cnt[si].frames >= max_frames || now - t0 >= max_sec) stop = 1;
        if (now - t_run0 >= run_sec) stop = 2;
        if (ckp && (stop || now - t_ck >= ck_sec)) {
          FILE *fc = fopen(ckp, "w");
          int d;
          t_ck = now;
          if (fc) {
            fprintf(fc, "ckpt %d %ld %d %ld\n", stop == 1 ? p + 1 : p, stop == 1 ? 0L : f + 1, nd, stop == 1 ? 0L : hard_err);
            for (d = 0; d < nd; d++) {
              cnt_t *c = stop == 1 ? &(cnt_t){0} : &cnt[d];
              fprintf(fc, "%ld %ld %ld %ld %ld %ld %ld %ld %ld %ld %ld %ld %ld %ld %ld %ld %.6f\n", c->frames, c->fe,
                      c->fe_info, c->undet, c->be_info, c->iters, c->fe_ok, c->cls_err[0], c->cls_err[1],
                      c->cls_err[2], c->hist[0], c->hist[1], c->hist[2], c->hist[3], c->hist[4], c->hist[5], c->t_dec);
            }
            fclose(fc);
          }
        }
      }
    }
    if (stop == 2) {
      fprintf(stderr, "run_sec reached at point %d; resume with the same config\n", p);
      fclose(fo);
      return 0;
    }
    {
      int d;
      long fr = cnt[0].frames;
      double rb_meas = fr ? (double)hard_err / ((double)fr * n) : 0;
      fprintf(fo, "pt %g sigma %.6f rber_ana %.4e rber_tab %.4e rber_meas %.4e frames %ld sec %.1f\n", x, sigma, rb_ana,
              rb_tab, rb_meas, fr, io_now() - t0);
      for (d = 0; d < nd; d++) {
        cnt_t *c = &cnt[d];
        double fer = c->frames ? (double)c->fe / c->frames : 0;
        double kk = dec[d].kind == 2 ? bch.k : k;
        fprintf(fo, "  d%d fe %ld fer %.4e fe_info %ld ber_info %.4e undet %ld avg_it %.3f dec_ms %.4f cls %ld %ld %ld hist %ld %ld %ld %ld %ld %ld",
                d, c->fe, fer, c->fe_info, c->frames ? c->be_info / (kk * c->frames) : 0, c->undet,
                c->frames ? (double)c->iters / c->frames : 0, c->frames ? 1e3 * c->t_dec / c->frames : 0,
                c->cls_err[0], c->cls_err[1], c->cls_err[2], c->hist[0], c->hist[1], c->hist[2], c->hist[3],
                c->hist[4], c->hist[5]);
        if (dec[d].kind == 2) fprintf(fo, " fer_binom %.4e", binom_tail(bch.n, rb_tab, bch.t));
        fprintf(fo, "\n");
      }
      fprintf(fo, "  prof_ms msg %.4f enc %.4f chan %.4f llr %.4f\n", 1e3 * prof_msg / (fr ? fr : 1),
              1e3 * prof_enc / (fr ? fr : 1), 1e3 * prof_chan / (fr ? fr : 1), 1e3 * prof_llr / (fr ? fr : 1));
      fflush(fo);
      prof_msg = prof_enc = prof_chan = prof_llr = prof_bch = 0;
    }
    if (chan_kind == 2) chan_free(&ch);
    start_frame = 0;
  }
  fprintf(fo, "# done\n");
  fclose(fo);
  if (ckp) remove(ckp);
  return 0;
}
