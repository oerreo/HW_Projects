# 수치 규칙 (bit-exact): nand-ecc-subsystem C golden

상태: N2 (2026-11-26). 이 문서는 `model/src/`의 정수 경로(채널 감지 샘플, LLR, 고정소수점 decoder, encoder)를 RTL과 ARM이 같은 출력을 내도록 고정한다. 문서와 코드가 다르면 코드가 틀린 것으로 보고 둘을 같은 커밋에서 고친다.

- 검증: `model/tools/fixref.py`는 이 문서 4절만 보고 쓴 독립 Python 구현이다(R을 edge별로 저장하고 block 열마다 순환 shift를 명시적으로 수행, C는 압축 저장). `make test`의 `xcheck`가 C의 kernel 경계 trace(`tools/xdump.c`)와 모든 값을 비교한다(결과는 `docs/spec/n2_results.md` 1절).
- 표기: 정수 나눗셈과 shift는 C99 의미. `>>`는 음이 아닌 값에만 쓴다.

## 1. 공통
| 항목 | 규칙 |
|---|---|
| 비트 | `uint8_t` 0/1, codeword 비트 i = 배열 index i |
| LLR 부호 | 양수 = 비트 0. hard decision `h = (x < 0)`, 0은 비트 0 |
| 포화 | `sat(x, M) = min(max(x, -M), M)`, `M = 2^(w-1) - 1` (대칭, `-2^(w-1)`은 쓰지 않음) |
| QC 규약 | `code.md` 2.1. check `(r, i)` = `r*Z + i`가 variable `c*Z + (i + s) mod Z`에 연결(s = S[r][c] ≥ 0), 한 check의 edge는 block 열 오름차순 |

## 2. 난수와 seed (`src/rng.c`)
- xoshiro128** [R50]: 상태 `s[0..3]`(uint32), 출력 `rotl(s1 * 5, 7) * 9`, 갱신은 참조 코드 그대로(`rng.h`). 상태 {1,2,3,4}의 첫 출력 0x2d00, 0x0, 0x5a7080, 0x4389d80(독립 Python 계산과 `make test`에서 일치).
- seed: `rng_seed(seed, stream)`: `x = seed XOR (stream * 0xD1B54A32D192ED03)` (64 bit wrap), splitmix64를 두 번 불러 `a`, `b`, 상태 = `{lo(a), hi(a), lo(b), hi(b)}`. 상태가 전부 0이면 `s[0] = 0x9E3779B9`.
- stream: FER 시뮬레이터는 frame마다 `rng_seed(seed XOR (point << 48), frame)`. 그래서 frame 하나를 단독으로 재현할 수 있고 checkpoint 재시작이 정확하다.
- 한 frame 안의 소비 순서: (1) 정보 비트 k개: 출력 하나가 32비트를 주고 비트 j = `(w >> j) & 1` (j = 0..31, 마지막 출력은 남는 비트를 버림) (2) codeword의 셀마다 `chan_sample` 2개(3절). (`zero_cw`이면 (1)을 건너뛴다.) AWGN 검증 채널은 Box-Muller(double)라 bit-exact 대상이 아니다.

## 3. 채널 감지 샘플 (`src/sense.c`, 결정 H2, H3)
### 3.1 격자와 표 (double로 계산, 정수로 교환)
- page의 hard 경계 b = 0..B-1(인접 state 쌍 `bstate[b] | bstate[b]+1`, 오름차순), 각 경계의 중심 `R_b`(기본: `chan_ref_opt`, 같은 사전확률에서 `(1 - F_s(x)) + F_{s+1}(x)` 최소점), 경계당 G점 `e = R_b + k * step`, `k = -(G-1)/2 .. (G-1)/2`. 전체 격자 `e[0..npt-1]`, `npt = B*G ≤ 63`, 엄격히 증가해야 한다. 기본 G = 15, step = 2.0(TLC 정규화 단위), 0.02(MLC).
- 표: `T[s][j] = min(floor(2^32 * F_s(e[j]) + 0.5), 2^32 - 1)` (uint32). F_s는 `chan_cdf`(TLC: `0.5 * erfc(-(x - mu)/(alpha*sigma*sqrt 2))`).
- state 순서: page 비트 b(0/1)를 가진 state를 오름차순으로 나열한 것이 `state_of[b][0..2^(bits-1)-1]`.

### 3.2 샘플 (정수만, K_CHAN)
셀 i(codeword 비트 `c_i`)마다:
```
r1 = next(); u = next();                       (이 순서)
s  = state_of[c_i][ other_bits ? r1 >> (32 - other_bits) : 0 ]     (TLC other_bits = 2, MLC 1)
q  = #{ j in 0..npt-1 : u >= T[s][j] }         (grid region 0..npt, uint8)
```
- 의미: `P(q <= j) = T[s][j] / 2^32 ≈ F_s(e[j])`, 즉 q = Vth보다 아래에 있는 격자점 수. 같은 셀을 여러 read 설정으로 다시 읽어도 결과가 서로 모순되지 않는다(retry, soft 모두 같은 q에서 계산).
- T가 j에 대해 단조라 선형 계수와 이진 탐색(6단)의 결과가 같다. `u = T[s][j]`인 경계값은 `u >= T`이므로 위쪽 구간으로 간다.

### 3.3 read 설정과 read region (K_SENSE)
- read 설정 = 경계당 감지 레벨 L(1, 3, 5, 7), soft 간격 `dstep`(격자 step 단위), 경계별 retry offset `off[b]`(격자 step 단위). threshold 격자 index `t = b*G + (G-1)/2 + off[b] + j*dstep`, `j = -(L-1)/2 .. (L-1)/2`(모두 경계 b의 G점 안이어야 함), 오름차순 `gidx[0..nthr-1]`.
- read region `reg = #{ t : q > gidx[t] }` (0..nthr). 표 `map[q]`로 구현.
- hard 비트 `hbit[reg]`: region이 경계 b의 중심 threshold 위/아래 어느 쪽인지로 정한 state의 page 비트.

## 4. 고정소수점 layered min-sum (`src/dec_fix.c`, RTL golden)
### 4.1 parameter
| 이름 | 의미 | 범위 |
|---|---|---|
| wc | 채널 LLR 폭. 입력은 `|llr| ≤ 2^(wc-1)-1`이어야 한다 | 2..8 |
| wm | Q, R 폭. `mmax = 2^(wm-1)-1` | wc..wa |
| wa | APP 폭. `amax = 2^(wa-1)-1` | wm..15 |
| corr | NMS: `f(m) = (m * num) >> 4` (num/16, 내림), OMS: `f(m) = max(m - beta, 0)` | num 1..16, beta ≥ 0 |
| iters | iteration 상한 | 1..63 |
| et | 조기 종료: none, ET-A, ET-B | |

### 4.2 상태
- `APP[v]` (wa bit), check마다 압축 상태 `(f1, f2, idx, sgn)`: `f1 = f(min1)`, `f2 = f(min2)`(보정 후 크기, 0..f(mmax)), `idx` = min1의 edge 위치(check 안 0..dc-1), `sgn` = Q 부호의 XOR. edge마다 `sq[e]` = Q의 부호(1 = 음수).
- edge e(check의 위치 j)의 R: `m = (j == idx) ? f2 : f1`, `R = (sgn XOR sq[e]) ? -m : m`.
- 이 압축 저장과 edge별 R 저장은 같은 R 값을 준다(f가 크기에만 작용하고 부호는 sgn과 sq로 복원). D2(edge별 BRAM)로 구현해도 golden과 bit-exact다. `fixref.py`가 edge별 저장으로 같음을 확인한다.

### 4.3 초기화
`APP[v] = llr[v]`, `hard[v] = (llr[v] < 0)`, 모든 check의 `(f1, f2, idx, sgn) = (0, 0, 0, 0)`, 모든 `sq = 0` → 첫 iteration의 R_old는 모두 0.

### 4.4 한 iteration
layer L = 0..mb-1 순서로(고정). layer 안에서 check(Z개)와 edge의 처리 순서는 결과에 영향이 없다(한 layer 안에서 variable이 한 번만 나옴, `dfix_init`이 확인). RTL은 열 순서를 바꿔도 된다(`code.md` 6절).

phase 1 (layer의 check마다, edge j = 0..dc-1):
```
a    = APP[var(e)]                         (shifter 출력 lane 값, trace LI)
Rold = R(e) from the stored state          (4.2)
Q    = sat(a - Rold, mmax)                 (trace Q; 뺄셈은 넓은 int로 한 뒤 포화)
mag  = |Q|
초기 m1 = m2 = mmax, id = 0;  if mag < m1: (m2, m1, id) = (m1, mag, j)  elif mag < m2: m2 = mag   (엄격 <, 동점이면 앞 edge가 min1)
sg  ^= (Q < 0);  par ^= (a < 0)
```
check 상태 갱신(trace CN): `(f1, f2, idx, sgn) = (f(m1), f(m2), id, sg)`, `sq[e] = (Q < 0)`.

phase 2 (같은 layer의 check마다, edge j):
```
Rnew = R(e) from the new state             (trace RN)
APP[var(e)] = sat(Q + Rnew, amax)          (trace LO)
h = (APP < 0); 바뀌면 hard 갱신, changed = 1
```

### 4.5 조기 종료와 출력
- ET-A: iteration 끝에 `hard`의 syndrome이 0이면 종료, ok = 1.
- ET-B: 그 iteration의 모든 check에서 phase 1의 `par`가 0이고(읽은 APP 부호로 모든 check 만족) 그 iteration 동안 `hard`가 한 번도 바뀌지 않았으면 종료, ok = 1. 이 경우 hard는 codeword다. 같은 frame에서 ET-B는 ET-A보다 일찍 멈추지 않는다(`make test` 확인, 4.4의 궤적은 ET와 무관).
- none: iters번 모두 돈 뒤 syndrome이 0이면 ok = 1.
- 출력: `hard[0..n-1]`, `iters_used`(1..iters), `ok`. 상한에 걸리면 `iters_used = iters`.

### 4.6 kernel 경계 (dump hook, `dfix_t.hook`)
| 사건 | 시점 | 유효한 값 |
|---|---|---|
| `DF_EV_START` | 초기화 뒤 | `app` |
| `DF_EV_LAYER_IN` | layer의 phase 1 뒤 | `lane_in`(shifter 출력), `q`, `rold`, check 상태(`min1`, `min2`, `idx`, `sgn`, `sq`) |
| `DF_EV_LAYER_OUT` | phase 2 뒤 | `rnew`, `lane_out`(역 shift 전 APP), `app` |
| `DF_EV_ITER_END` | iteration 끝 | `app`, `hard`, ET-B 플래그 |
| `DF_EV_DONE` | 종료 | `hard`, `iters_used`, `ok` |
layer 배열의 순서는 "layer의 check i(0..Z-1), 그 check의 edge(block 열 오름차순)"이다. lane 단위(block 열 c의 lane i)로 바꾸려면 check i의 j번째 edge = block 열 `cols[j]`, lane i.

## 5. LLR (`src/llr.c`)
- soft LUT: read region r의 확률 `P(r|s) = F_s(e_hi) - F_s(e_lo)`를 공칭 채널(LUT 조건)에서 double로 계산, `LLR(r) = ln(Σ_{bit(s)=0} P / Σ_{bit(s)=1} P)`(state 사전확률 같음), 정수 `sat(sign(x) * floor(|x| * scale + 0.5), 2^(w-1)-1)`(|x|가 1e6 이상이거나 무한이면 최대값). 교환 형식은 정수 표 `lut[reg]`, bit-exact 기준도 정수 표다.
- hard LUT: `±A`(region의 hard 비트가 1이면 `-A`).
- `llr_map`(K_LLR) = `full[q] = lut[map[q]]` 표 하나. PL `llr_gen`은 같은 표를 쓴다.
- AWGN(검증용): `llr = 2y/σ²`(double), 고정소수점 입력은 같은 양자화 식(`awgn_scale` 배).

## 6. Encoder (`src/enc.c`, K_ENC)
`code.md` 2.3 그대로. `λ_r = Σ_c P^{s(r,c)} u_c`(`(P^s x)[i] = x[(i+s) mod Z]`), `p0 = Σ_r λ_r`, `p1 = λ_0 + P^a p0`, `p_{r+1} = λ_r + p_r + [s(r,p0) ≥ 0] P^{s(r,p0)} p0`(r = 1..mb-2), 마지막 행 검사. codeword = `[u | p0 | p1 .. p_{mb-1}]`.

## 7. BCH (`src/bch.c`, C만)
GF(2^14), 원시 다항식 `x^14 + x^10 + x^6 + x + 1`(0x4443, `make test`에서 α의 위수 16383 확인), t = 73, g = α^1, α^3, .., α^145의 최소다항식 곱(차수 1015), (9207, 8192). codeword 다항식 계수 `c[i]`: parity `c[0..1014]`, 정보 `c[1015 + j] = u[j]`. 복호: S_1..S_146(짝수는 제곱), inversionless BM(2t 단계, Sarwate-Shanbhag iBM), Chien(위치 0..9206). 근 수 ≠ deg Λ 또는 deg Λ > t이면 실패, 입력을 그대로 둔다(AFF3CT `STD` 규칙).
