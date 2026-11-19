"""Paired statistics over per-story results of `job ceval` (tools/run.c).

Settings come from environment variables (no command-line arguments):
  CI_IN    space-separated ceval result files of the same model and story range.
           Every file must start with F; the F sums must agree across files.
  CI_OUT   output text file (also printed)
  CI_B     bootstrap resamples (default 4000)
  CI_SEED  bootstrap seed (default 20261118)
  CI_PAIRS optional space-separated "A:B" pairs to list first (all pairs are listed anyway)

dCE(v) = sum_s (CE_v,s - CE_F,s) / sum_s n_s, the token-weighted mean increase of the
cross-entropy (nats/token) over the stories s. Both intervals are 95 %, paired over stories:
  boot  percentile interval of the story bootstrap (same resample for every variant)
  se    ratio estimator, normal approximation: dCE +- 1.96 * SE
A difference between two variants is "distinct" when the paired bootstrap interval of
dCE(a) - dCE(b) excludes 0. Standard library only.
"""
import math
import os
import random


def load(paths):
    names, rows, fref = [], {}, {}
    for path in paths:
        vars_ = None
        with open(path) as fh:
            for line in fh:
                w = line.split()
                if not w or w[0].startswith("#"):
                    continue
                if w[0] == "vars":
                    vars_ = w[1:]
                    if vars_[0] != "F":
                        raise SystemExit("first variant must be F: " + path)
                    continue
                if w[0] != "st":
                    continue
                idx, n = int(w[1]), int(w[2])
                bar = w.index("|")
                ce = [float(x) for x in w[3:bar]]
                t1 = [int(x) for x in w[bar + 1:]]
                if len(ce) != len(vars_) or len(t1) != len(vars_) - 1:
                    raise SystemExit("bad row in " + path)
                key = idx
                if key in fref:
                    if fref[key] != (n, w[3]):
                        raise SystemExit("F differs between files at story %d" % idx)
                else:
                    fref[key] = (n, w[3])
                r = rows.setdefault(key, {"n": n, "F": ce[0], "ce": {}, "t1": {}})
                for j, v in enumerate(vars_[1:]):
                    r["ce"][v] = ce[j + 1]
                    r["t1"][v] = t1[j]
        for v in vars_[1:]:
            if v not in names:
                names.append(v)
    keys = sorted(rows)
    for v in names:
        missing = [k for k in keys if v not in rows[k]["ce"]]
        if missing:
            raise SystemExit("variant %s missing %d stories" % (v, len(missing)))
    return names, [rows[k] for k in keys], keys


def main():
    paths = os.environ.get("CI_IN", "").split()
    out = os.environ.get("CI_OUT", "")
    B = int(os.environ.get("CI_B", "4000"))
    seed = int(os.environ.get("CI_SEED", "20261118"))
    names, rows, keys = load(paths)
    S = len(rows)
    N = sum(r["n"] for r in rows)
    n_s = [r["n"] for r in rows]
    d = {v: [r["ce"][v] - r["F"] for r in rows] for v in names}
    ce_f = sum(r["F"] for r in rows) / N
    est = {v: sum(d[v]) / N for v in names}

    # bootstrap: one multiset of stories per resample, shared by all variants
    rng = random.Random(seed)
    boot = {v: [] for v in names}
    for _ in range(B):
        cnt = [0] * S
        for i in rng.choices(range(S), k=S):
            cnt[i] += 1
        nb = 0
        sums = dict.fromkeys(names, 0.0)
        for i in range(S):
            c = cnt[i]
            if c:
                nb += c * n_s[i]
                for v in names:
                    sums[v] += c * d[v][i]
        for v in names:
            boot[v].append(sums[v] / nb)

    def pct(xs):
        ys = sorted(xs)
        lo = ys[int(math.floor(0.025 * (len(ys) - 1)))]
        hi = ys[int(math.ceil(0.975 * (len(ys) - 1)))]
        return lo, hi

    def se_ratio(dd):
        R = sum(dd) / N
        nbar = N / S
        var = sum((x - R * n) ** 2 for x, n in zip(dd, n_s)) / (S - 1)
        return math.sqrt(var / S) / nbar

    lines = []
    P = lines.append
    P("# ci stories=%d (index %d..%d) tokens=%d CE_F=%.5f bootstrap B=%d seed=%d"
      % (S, keys[0], keys[-1], N, ce_f, B, seed))
    P("# variant dCE boot_lo boot_hi se se_lo se_hi top1_pct stories_worse_than_F")
    for v in names:
        lo, hi = pct(boot[v])
        se = se_ratio(d[v])
        t1 = 100.0 * sum(r["t1"][v] for r in rows) / N
        worse = sum(1 for x in d[v] if x > 0)
        P("v %s %+.5f %+.5f %+.5f %.5f %+.5f %+.5f %.3f %d/%d"
          % (v, est[v], lo, hi, se, est[v] - 1.96 * se, est[v] + 1.96 * se, t1, worse, S))
    P("# pair A B dCE(A)-dCE(B) boot_lo boot_hi se distinct(boot CI excludes 0)")
    pairs = []
    for a in os.environ.get("CI_PAIRS", "").split():
        x, y = a.split(":")
        pairs.append((x, y))
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            if (a, b) not in pairs and (b, a) not in pairs:
                pairs.append((a, b))
    for a, b in pairs:
        diff = [x - y for x, y in zip(boot[a], boot[b])]
        lo, hi = pct(diff)
        se = se_ratio([x - y for x, y in zip(d[a], d[b])])
        P("p %s %s %+.5f %+.5f %+.5f %.5f %s"
          % (a, b, est[a] - est[b], lo, hi, se, "yes" if lo > 0 or hi < 0 else "no"))
    text = "\n".join(lines) + "\n"
    print(text, end="")
    if out:
        with open(out, "w") as fh:
            fh.write(text)


if __name__ == "__main__":
    main()
