"""Summarize fer result files as markdown tables (standard library only, no arguments).
Environment: S_IN (space separated result files). Prints per point and decoder: frames, frame errors,
FER with a 95 % interval (Wilson score), average iterations, undetected count, failure statistics.
"""
import math
import os


def wilson(k, n, z=1.96):
    if n == 0:
        return (0.0, 0.0)
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (max(0.0, c - h), c + h)


def parse(path):
    decs, pts, cur = {}, [], None
    for ln in open(path):
        t = ln.split()
        if not t:
            continue
        if t[0] == '#' and len(t) > 2 and t[1].startswith('dec'):
            decs[int(t[1][3:])] = t[2]
        elif t[0] == 'pt':
            cur = dict(zip(t[0::2], t[1::2]))
            cur['d'] = {}
            pts.append(cur)
        elif t[0].startswith('d') and t[0][1:].isdigit() and cur is not None:
            kv = {}
            i = 1
            while i < len(t):
                k = t[i]
                if k in ('cls', 'hist'):
                    n = 3 if k == 'cls' else 6
                    kv[k] = [int(x) for x in t[i + 1:i + 1 + n]]
                    i += 1 + n
                else:
                    kv[k] = t[i + 1]
                    i += 2
            cur['d'][int(t[0][1:])] = kv
        elif t[0] == 'prof_ms' and cur is not None:
            cur['prof'] = dict(zip(t[1::2], t[2::2]))
    return decs, pts


def main():
    for path in os.environ['S_IN'].split():
        decs, pts = parse(path)
        print('### %s' % path)
        for i in sorted(decs):
            print('- d%d = `%s`' % (i, decs[i]))
        print()
        print('| x | raw BER (ana / meas) | dec | frames | FE | FER [95%] | avg it | undet | fail hist (1-2,3-5,6-10,11-20,21-50,51+) | cls (info,p0,dd) |')
        print('|---|---|---|---|---|---|---|---|---|---|')
        for p in pts:
            n = int(p['frames'])
            for i in sorted(p['d']):
                d = p['d'][i]
                k = int(d['fe'])
                lo, hi = wilson(k, n)
                rb = '%s / %s' % (p['rber_ana'], p['rber_meas']) if float(p['rber_ana']) > 0 else '- / %s' % p['rber_meas']
                print('| %s | %s | d%d | %d | %d | %.2e [%.1e, %.1e] | %s | %s | %s | %s |' % (
                    p['pt'], rb, i, n, k, k / n if n else 0, lo, hi, d['avg_it'], d['undet'],
                    ','.join(str(x) for x in d['hist']), ','.join(str(x) for x in d['cls'])))
        print()


if __name__ == '__main__':
    main()
