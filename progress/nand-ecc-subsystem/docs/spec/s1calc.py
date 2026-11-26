# N1 scope.md / channel.md [계산] values: decoder cycles per iteration (layer overlap and hazard
# stalls on the real shift table), throughput, memory bits and BRAM36 counts, barrel shifter mux
# count, PL channel emulator FER depth, Irwin-Hall Gaussian tail error.  Standard library only, no
# arguments.  Run from the project root:  python3 -I docs/spec/s1calc.py
# Every number printed is computed from the assumptions printed next to it. Nothing is measured.
import math
import os

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
TAB = os.path.join(ROOT, 'model', 'code', 'qc_m128.txt')
cd = lambda a, b: -(-a // b)
F = 100e6          # assumed PL clock
HP_BYTES = 8       # HP port data width (64 bit) per beat


def read_table(path):
    rows = [l.split() for l in open(path) if l.strip() and not l.startswith('#')]
    mb, nb, Z = map(int, rows[0])
    S = [list(map(int, r)) for r in rows[1:]]
    return mb, nb, Z, S


mb, nb, Z, S = read_table(TAB)
n, k = nb * Z, (nb - mb) * Z
cols = [[c for c in range(nb) if S[r][c] >= 0] for r in range(mb)]
dc = [len(x) for x in cols]
E = sum(dc)
print('code: %s  mb %d nb %d Z %d  n %d k %d  block edges %d  dc per layer %s' %
      (os.path.relpath(TAB, ROOT), mb, nb, Z, n, k, E, dc))
print('assumptions: PL clock %.0f MHz, HP port %d bit, 1 block (Z lanes) per cycle, decoder = layered, '
      'two-phase CNU (read dc blocks, then write dc blocks)' % (F / 1e6, HP_BYTES * 8))


# ---------------------------------------------------------------------------------------------
# 1. cycles per iteration: non-overlapped and overlapped (phase 2 of layer l with phase 1 of l+1)
def order_layers(mode):
    """(read order, write order) of block columns per layer (wrap around: layer mb-1 -> 0).
    nat:   both natural (ascending column).
    split: read the columns not shared with the previous layer first; write (phase 2) the
           columns shared with the next layer first, in the next layer's read order. Phase 2
           can emit edges in any order because R is rebuilt from min1/min2/idx/sign."""
    rd = []
    for r in range(mb):
        prv = set(cols[(r - 1) % mb])
        if mode == 'nat':
            rd.append(list(cols[r]))
        else:
            rd.append([c for c in cols[r] if c not in prv] + [c for c in cols[r] if c in prv])
    wr = []
    for r in range(mb):
        if mode == 'nat':
            wr.append(list(cols[r]))
            continue
        nxt = rd[(r + 1) % mb]
        pos = {c: i for i, c in enumerate(nxt)}
        wr.append(sorted(cols[r], key=lambda c: (pos.get(c, 10 ** 6), c)))
    return rd, wr


def overlapped(L, mode, iters=4):
    """L: cycles from the last read of a layer to its first write (CNU pipeline).
    A read of column c at cycle t needs t > last write cycle of c (no bypass). Returns the
    steady-state cycles per iteration and the stall cycles in that iteration."""
    rd, wr = order_layers(mode)
    lastw = {}
    t = 0
    starts = []
    stalls = 0
    for it in range(iters):
        starts.append(t)
        st_it = 0
        for r in range(mb):
            for i, c in enumerate(rd[r]):
                need = lastw.get(c, -1) + 1
                if need > t:
                    st_it += need - t
                    t = need
                if i < len(rd[r]) - 1:
                    t += 1
            rend = t
            for i, c in enumerate(wr[r]):
                lastw[c] = rend + L + i
            t = rend + 1
        stalls = st_it
    return starts[-1] - starts[-2], stalls


print('\n[1] cycles per iteration (Z = %d lanes, full parallel)' % Z)
print('    non-overlapped: sum(2*dc + L) ; overlapped: next layer reads while the previous writes')
for L in (2, 4, 6, 8):
    non = sum(2 * d + L for d in dc)
    o_nat, s_nat = overlapped(L, 'nat')
    o_heu, s_heu = overlapped(L, 'split')
    print('    L %d: non-overlapped %d | overlapped natural column order %d (stall %d) | '
          'overlapped split read/write order %d (stall %d) | lower bound %d' %
          (L, non, o_nat, s_nat, o_heu, s_heu, E))

# ---------------------------------------------------------------------------------------------
# 2. throughput
print('\n[2] throughput, info bits %d per codeword' % k)
llr_beats = {'8 bit/LLR': cd(n * 8, HP_BYTES * 8), '6 bit packed (10/beat)': cd(n, 10)}
out_beats = cd(k, HP_BYTES * 8)
for nm, b in llr_beats.items():
    print('    input %s: %d beats/codeword; output hard bits: %d beats; HP-port bound %.0f codeword/s = %.0f Mbps info'
          % (nm, b, out_beats, F / b, F / b * k / 1e6))
L = 6
cit, _ = overlapped(L, 'split')
tail = L + max(dc)
print('    decoder (L %d, overlapped split order %d cycles/iter, + drain %d), input double-buffered:' % (L, cit, tail))
print('    %-6s %-12s %-12s %-14s %-14s' % ('iter', 'cyc/cw', 'Mbps(P=128)', 'Mbps(P=64)', 'Mbps(P=32)'))
for it in (1, 2, 3, 5, 10, 15, 20):
    c = it * cit + tail
    io = llr_beats['8 bit/LLR']
    row = []
    for P in (128, 64, 32):
        cc = max(it * cit * (Z // P) + tail, io)
        row.append(F / cc * k / 1e6)
    print('    %-6d %-12d %-12.1f %-14.1f %-14.1f' % (it, c, row[0], row[1], row[2]))
print('    (P < Z: every block takes Z/P cycles; the cyclic-shift network for P < Z is not costed here)')

# ---------------------------------------------------------------------------------------------
# 3. memories
print('\n[3] memory (BRAM36 used as 512 x 72 SDP [R52]; counts = ceil(width/72) x ceil(depth/512))')


def b36(width, depth):
    return cd(width, 72) * cd(depth, 512)


for qm in (4, 5, 6):
    qa = qm + 2
    app_bits = n * qa
    r_bits = E * Z * qm
    lm = 2 * (qm - 1) + math.ceil(math.log2(max(dc)))
    rc_bits = mb * Z * lm + E * Z
    qbuf = max(dc) * Z * (qa + 1)
    print('    msg %d bit / APP %d bit:' % (qm, qa))
    print('      APP           %7d bit, word %4d bit x %3d deep (x2 ping-pong = %d deep) -> BRAM36 %d'
          % (app_bits, Z * qa, nb, 2 * nb, b36(Z * qa, 2 * nb)))
    print('      R edge-wise   %7d bit, word %4d bit x %3d deep -> BRAM36 %d'
          % (r_bits, Z * qm, E, b36(Z * qm, E)))
    print('      R compressed  %7d bit = min1,min2,idx %d bit x %d checks (word %d bit x %d deep, FF/LUTRAM) '
          '+ sign/edge %d bit (word %d x %d deep -> BRAM36 %d)'
          % (rc_bits, lm, mb * Z, Z * lm, mb, E * Z, Z, E, b36(Z, E)))
    print('      Q buffer      %7d bit (dc_max %d x Z x (APP+1)) -> BRAM36 %d if in BRAM'
          % (qbuf, max(dc), b36(Z * (qa + 1), max(dc))))

# ---------------------------------------------------------------------------------------------
# 4. barrel shifter
print('\n[4] cyclic shifter for Z = %d, log2 stages %d' % (Z, int(math.log2(Z))))
for w in (6, 7, 8):
    m2 = int(math.log2(Z)) * Z * w
    print('    width %d bit: 2:1 mux %d; if a LUT6 does a 4:1 mux (2 stages) -> about %d LUT per shifter [추정]'
          % (w, m2, cd(int(math.log2(Z)), 2) * Z * w))

# ---------------------------------------------------------------------------------------------
# 5. PL channel emulator and FER depth
print('\n[5] board FER depth (codeword/s = F / max(decoder cycles, emulator cycles, 0 IO when in-PL))')
for it_avg in (2, 5, 10):
    dec = it_avg * cit + tail
    for G in (4, 8, 16):
        emu = cd(n, G)
        cw = F / max(dec, emu)
        hr = cw * 3600
        print('    avg iter %2d, emulator %2d cells/cycle: dec %5d cyc, emu %5d cyc -> %7.0f cw/s, %.2e cw/h, '
              'FER floor at 100 frame errors per hour %.1e, per 8 h %.1e' %
              (it_avg, G, dec, emu, cw, hr, 100 / hr, 100 / (8 * hr)))
print('    ARM-fed (no emulator) [추정]: Cortex-A9 667 MHz, cycles per cell sample C_s; codeword = %d samples' % n)
for cs in (40, 80, 300):
    t = n * cs / 667e6
    print('      C_s %3d -> %.2f ms/codeword -> %.0f cw/s, %.2e cw/h (channel generation only)' % (cs, t * 1e3, 1 / t, 3600 / t))

# ---------------------------------------------------------------------------------------------
# 6. Irwin-Hall (sum of K uniforms, normalised) tail vs Gaussian
print('\n[6] CLT Gaussian approximation: P(X > x sigma), X = (sum of K U(0,1) - K/2) / sqrt(K/12)')


def ih_sf(K, x):
    """P(sum of K U(0,1) > s), exact Irwin-Hall."""
    s = K / 2 - x * math.sqrt(K / 12)   # by symmetry P(S > K/2 + d) = P(S < K/2 - d)
    if s <= 0:
        return 0.0
    return sum((-1) ** j * math.comb(K, j) * (s - j) ** K for j in range(int(math.floor(s)) + 1)) / math.factorial(K)


for x in (2, 3, 4, 5):
    q = 0.5 * math.erfc(x / math.sqrt(2))
    print('    x %d: Gaussian %.3e | ' % (x, q) +
          ' | '.join('K %2d %.3e (ratio %.3f)' % (K, ih_sf(K, x), ih_sf(K, x) / q) for K in (4, 8, 12)))
print('    tail cut: K uniforms cannot exceed sqrt(3K) sigma: K 4 -> %.2f, K 12 -> %.2f' % (math.sqrt(12), 6.0))
print('    discrete inverse-CDF sampling with a 32-bit uniform: smallest nonzero region probability 2^-32 = %.2e'
      % 2 ** -32)

# ---------------------------------------------------------------------------------------------
# 7. 3D TLC fit table example: [R5] P/E 500, retention 15 days (the only column copied in the
#    survey, 1.2(c)). Normalised units. Hard references = intersection of adjacent Gaussians
#    (equal priors). Raw BER per page with the [R5] Table 1 Gray mapping. Soft example: LSB page.
print('\n[7] TLC example from survey 1.2(c) ([R5], P/E 500, 15 days); Gaussian per state, equal priors')
MU = [-85, 64.5, 121.9, 181.6, 236.4, 289.5, 341.2, 401.5]
SD = [18.2, 9.1, 8.9, 9.1, 7.5, 7.8, 7.6, 9.0]
MAP = {'MSB': [1, 0, 0, 1, 1, 0, 0, 1], 'CSB': [1, 1, 0, 0, 0, 0, 1, 1], 'LSB': [1, 1, 1, 1, 0, 0, 0, 0]}
Phi = lambda x: 0.5 * math.erfc(-x / math.sqrt(2))


def cross(m1, s1, m2, s2):
    a = 1 / s1 ** 2 - 1 / s2 ** 2
    b = -2 * (m1 / s1 ** 2 - m2 / s2 ** 2)
    c = m1 ** 2 / s1 ** 2 - m2 ** 2 / s2 ** 2 + 2 * math.log(s1 / s2)
    if abs(a) < 1e-15:
        return -c / b
    d = math.sqrt(b * b - 4 * a * c)
    for x in ((-b + d) / (2 * a), (-b - d) / (2 * a)):
        if m1 < x < m2:
            return x
    raise ValueError


def rber(refs, sscale=1.0):
    out = {}
    for pg, mp in MAP.items():
        e = 0.0
        for s in range(8):
            edges = [-math.inf] + refs + [math.inf]
            for j in range(8):
                if mp[j] != mp[s]:
                    e += Phi((edges[j + 1] - MU[s]) / (SD[s] * sscale)) - Phi((edges[j] - MU[s]) / (SD[s] * sscale))
        out[pg] = e / 8
    return out


refs = [cross(MU[i], SD[i], MU[i + 1], SD[i + 1]) for i in range(7)]
print('    hard references (Gaussian intersections): ' + ', '.join('%.2f' % r for r in refs))
print('    page boundaries: LSB R3 (P3|P4); CSB R1, R5; MSB R0, R2, R4, R6 -> hard reads 1 / 2 / 4')
for sc in (1.0, 1.25, 1.5, 2.0):
    rb = rber(refs, sc)
    print('    sigma scale %.2f: raw BER  LSB %.3e  CSB %.3e  MSB %.3e  mean %.3e' %
          (sc, rb['LSB'], rb['CSB'], rb['MSB'], sum(rb.values()) / 3))
print('    soft example, LSB page, sigma scale 1.5, levels hard +6 at R3 + j*delta, j = -3..3, delta 4:')
sc, delta = 1.5, 4.0
th = [refs[3] + j * delta for j in range(-3, 4)]
edges = [-math.inf] + th + [math.inf]
llrs = []
for q in range(len(edges) - 1):
    p0 = sum(Phi((edges[q + 1] - MU[s]) / (SD[s] * sc)) - Phi((edges[q] - MU[s]) / (SD[s] * sc))
             for s in range(8) if MAP['LSB'][s] == 0)
    p1 = sum(Phi((edges[q + 1] - MU[s]) / (SD[s] * sc)) - Phi((edges[q] - MU[s]) / (SD[s] * sc))
             for s in range(8) if MAP['LSB'][s] == 1)
    llrs.append(math.log(p0 / p1))
print('    region 0..7 LLR = ln P(bit 0)/P(bit 1): ' + ', '.join('%.2f' % x for x in llrs))

# ---------------------------------------------------------------------------------------------
# 8. BCH with the same data (8192 bits) and parity budget (<= 1024 bits, the LDPC parity size):
#    generator degree = sum of the cyclotomic coset sizes of alpha^1, alpha^3, ..., alpha^(2t-1).
print('\n[8] binary BCH, k = %d, parity budget %d bits' % (k, n - k))


def bch_deg(m, t):
    N = 2 ** m - 1
    seen = set()
    deg = 0
    small = []
    for i in range(1, 2 * t, 2):
        if i in seen:
            continue
        cos = set()
        x = i
        while x not in cos:
            cos.add(x)
            x = (2 * x) % N
        seen |= cos
        deg += len(cos)
        if len(cos) < m:
            small.append((i, len(cos)))
    return deg, small


for m in (13, 14, 15):
    N = 2 ** m - 1
    if N < k + m:
        print('    m %d: n_max %d < k + m, impossible' % (m, N))
        continue
    t = 1
    while True:
        d, _ = bch_deg(m, t + 1)
        if d > n - k or k + d > N:
            break
        t += 1
    d, small = bch_deg(m, t)
    print('    GF(2^%d): t max %d, parity %d bits, shortened (n, k) = (%d, %d), rate %.6f, '
          'cosets smaller than m: %s' % (m, t, d, k + d, k, k / (k + d), small))
