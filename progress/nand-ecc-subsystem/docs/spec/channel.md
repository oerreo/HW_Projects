# 채널 모델과 LLR 스펙: nand-ecc-subsystem

상태: **초안** (2026-11-25, N1). 오케스트레이터 검토 후 확정. 열린 결정은 `scope.md` 9절(H로 시작하는 ID).

- 근거: `survey/survey.md` 1.2~1.5절(원문 확인된 parameter만 사용). 서베이에 값이 없는 것은 **미확인**으로 두고 지어내지 않는다.
- 표기: **[계산]** `docs/spec/s1calc.py`(출력 `s1calc.txt`)나 식으로 구한 값. **[추정]** 가정이나 판단. 측정값 없음.
- 범위: C golden(N2)의 `chan`, `sense`, `llr` 모듈과 PL 채널 에뮬레이터(선택, `scope.md` 6절)가 공유하는 정의.

## 1. 공통 정의

| 항목 | 정의 |
|---|---|
| 셀 | MLC 2 bit/cell(state E, P1, P2, P3) 또는 TLC 3 bit/cell(P0..P7). Vth는 정규화 단위(문헌 단위 그대로) |
| page | 한 codeword(9216 bit)는 한 page 종류(MLC: lower/upper, TLC: LSB/CSB/MSB)에 들어간다. codeword 비트 하나 = 셀 하나. 셀의 다른 page 비트는 독립 균등 random [추정: 모델 가정] |
| state 결정 | page 비트와 나머지 random 비트로 Gray 매핑에서 state를 정하고, 그 state의 분포에서 Vth(또는 감지 구간)를 뽑는다 |
| 셀 독립 | v1은 셀끼리 독립(i.i.d. given state). CCI는 victim 셀 분포에 평균적으로만 반영한다(2.3절) |

### 1.1 Gray 매핑
- **MLC** [R4] Example 2.1: state E, P1, P2, P3 = 11, 10, 00, 01. 비트 순서(어느 쪽이 upper/lower page인가)는 서베이에 없음 → **미확인**. v1 가정: 앞 비트 = upper(MSB) page, 뒤 비트 = lower(LSB) page [추정]. 그러면 lower page 경계 1개(P1|P2), upper page 경계 2개(E|P1, P2|P3).
- **TLC** [R5] Table 1 (P0..P7): MSB 1,0,0,1,1,0,0,1 / CSB 1,1,0,0,0,0,1,1 / LSB 1,1,1,1,0,0,0,0. page별 hard 경계: LSB R3(P3|P4), CSB R1, R5, MSB R0, R2, R4, R6 → hard read 1/2/4회 [R5 표에서 도출, 서베이 1.2(c)].

## 2. 모델 A: MLC 해석 모델 ([R3] Example 2.1, 보조로 [R4])

### 2.1 식
셀 하나의 Vth(정규화 전압):
```
x0  = 초기 Vth:  E  상태 ~ N(μe, σe²)
                 Pk 상태 ~ U[Vp_k, Vp_k + ΔVpp]                 (ISPP 이상 분포)
x1  = x0 + n_rtn,  n_rtn ~ Laplace(0, λr),  p(x) = 1/(2λr) exp(-|x|/λr),  λr = Kλ · N^0.5
x2  = x1 + F_cci,  F = Σ_k ΔVt(k) · γ(k)                        (2.3절)
Vth = x2 - d,      d ~ N(μd, σd²)                               (retention)
     μd  = Ks (x − x0') · Kd · N^0.5 · ln(1 + t/t0)
     σd² = Ks (x − x0') · Km · N^0.6 · ln(1 + t/t0)
```
- N = P/E cycle 수, t = retention 시간(h). 식의 `x`는 초기 Vth, `x0'`는 상수 x0(= 1.4)로 [R3]의 기호를 그대로 쓰되 초기 Vth `x0`와 구분하려고 프라임을 붙였다.
- retention 항의 **부호**(Vth가 내려가는 방향으로 빼는가)와 **효과를 더하는 순서**(RTN, CCI, retention)는 서베이에 없다 → **미확인**. 위 식은 전하 손실이 Vth를 낮춘다는 일반론에 따른 [추정]이다. N2 시작 시 [R3] 원문 2절에서 확인하고 고친다.
- x < x0'이면 μd, σd²가 음수가 된다(E 상태의 일부). v1은 `max(0, x − x0')`로 자른다 [추정]. 원문 처리 **미확인**.

### 2.2 parameter 표

| 기호 | 값 [R3] | 값 [R4] | 의미 |
|---|---|---|---|
| σe, μe | 0.35, 1.4 | 0.35, 1.2 | 지움 상태 Gaussian |
| ΔVpp | 0.3 | 0.3 | ISPP step(균일 분포 폭) |
| Vp (P1, P2, P3) | 2.85, 3.55, 4.25 | 2.55, 3.0, 3.45 | verify 전압 |
| Kλ | 4e-4 | 서베이에 없음(**미확인**) | RTN 크기 |
| γy, γxy 평균 | 0.08, 0.0048 | 0.08s, 0.006s | 수직/대각 결합비(bounded Gaussian) |
| γ 분포 폭 | wc = 0.1μc, σc = 0.4μc | **미확인** | bounded Gaussian의 범위와 표준편차 |
| Ks, x0' | 0.333, 1.4 | - | retention |
| Kd, Km | 4e-4, 2e-6 | - | retention 평균, 분산 계수 |
| t0 | 1 h | - | retention 기준 시간 |
| s | - | CCI 강도 인자 | [R4]의 knob |

- 기본 parameter 세트는 [R3](retention 식이 있음). [R4]는 CCI 강도 s 실험과 LLR 식(20) 대조용.
- [R3]의 상수는 그 문헌 [30],[31]의 측정에 fit한 값이다(서베이 1.2(a)).

### 2.3 CCI
- [R3]: all-bit-line 구조 가정, `F = Σ ΔVt(k) γ(k)`. ΔVt(k)는 이웃 셀 k가 (victim 이후에) 프로그램될 때의 Vth 변화량이다 [추정: 일반적인 정의]. 어느 이웃(같은 word-line 좌우, 다음 word-line 위, 대각)을 넣는지, 프로그램 순서는 서베이에 없음 → **미확인**.
- v1 처리 [추정]: 셀 독립 가정이므로 이웃 state를 독립 균등 random으로 뽑아 F를 더한다(C 참조 모델). 이웃 셀 간 상관은 모델링하지 않는다.

### 2.4 read reference
- MLC 기준 전압 값은 서베이에 없음 → **미확인**. N2에서 각 (N, t)마다 인접 state 분포의 교점(수치 계산)을 "최적 hard reference"로 [계산]하고, 기본 기준 전압(새 칩 조건, N = 0, t = 0에서의 교점)을 고정 reference로 둔다. read retry는 이 둘의 차이를 offset 표로 근사한다(3.3절).

## 3. 모델 B: 3D TLC fit 표 ([R5] 부록 Table A1~A3)

### 3.1 식
```
Vth | state s, (P/E, retention)  ~  N(μ_s(PE, t), (α · σ_s(PE, t))²)
```
- α = sigma scale. **이 프로젝트가 넣는 knob**이며 문헌 값이 아니다. α = 1이 문헌 fit 그대로.

### 3.2 parameter (서베이에서 원문 확인된 것만)

| state | P0 | P1 | P2 | P3 | P4 | P5 | P6 | P7 |
|---|---|---|---|---|---|---|---|---|
| μ (P/E 500, 15일) | −85 | 64.5 | 121.9 | 181.6 | 236.4 | 289.5 | 341.2 | 401.5 |
| σ (P/E 500, 15일) | 18.2 | 9.1 | 8.9 | 9.1 | 7.5 | 7.8 | 7.6 | 9.0 |

- P/E 5000에서 σ는 19.3~9.8 범위로 증가한다(state별 값은 서베이에 없음).
- 나머지 격자(P/E 500~5000, retention 15/30/90일)의 μ, σ는 **미확인**: 서베이가 표 위치(부록 A1~A3)만 확인했다. N2에서 원문에서 옮겨 적고 출처 표 번호를 단다(저장 방식은 열린 결정 H5).
- 주의 [R5]: 값은 정규화되고 "어느 정도 확대"됐으며 P0 평균은 가정값이다. 측정 환경은 85°C 13시간 bake = 25°C 1개월 가정.

### 3.3 예: P/E 500, 15일 [계산, `s1calc.txt` 7절]
- hard reference = 인접 Gaussian 교점(같은 사전확률): R0..R6 = 13.90, 93.49, 151.45, 211.40, 262.47, 315.66, 369.00.
- page별 raw BER:

| α | LSB | CSB | MSB | 평균 |
|---|---|---|---|---|
| 1.00 | 1.197e-4 | 2.769e-4 | 2.137e-4 | 2.035e-4 |
| 1.25 | 1.029e-3 | 2.247e-3 | 2.140e-3 | 1.805e-3 |
| 1.50 | 3.456e-3 | 7.340e-3 | 7.920e-3 | 6.239e-3 |
| 2.00 | 1.232e-2 | 2.551e-2 | 3.189e-2 | 2.324e-2 |

- 문헌 RBER 범위(25nm MLC 10K P/E + 1개월에서 0.004~0.013 [R7])와 같은 자릿수를 α 1.5~2.0에서 얻는다. 이 대응은 자릿수 비교일 뿐 같은 칩 조건이라는 뜻이 아니다.

## 4. 감지(sense)와 read retry

### 4.1 감지 레벨
- page의 hard 경계 B개(LSB 1, CSB 2, MSB 4, MLC lower 1, upper 2) 각각에 감지 레벨 L개를 둔다.

| 이름 | 레벨/경계 L | 위치 (경계 R 기준) | 구간 수/경계 | 경계당 정보 |
|---|---|---|---|---|
| hard | 1 | R | 2 | 1 bit |
| +2 | 3 | R, R ± δ | 4 | 2 bit |
| +4 | 5 | R, R ± δ, R ± 2δ | 6 | |
| +6 | 7 | R, R ± δ, R ± 2δ, R ± 3δ | 8 | 3 bit |

- +6(hard 1 + soft 6 = 7레벨)은 [R7]이 인용한 21nm MLC 칩의 7 양자화 레벨과 같은 개수다. soft 기준 전압은 hard 주변 2~4개에서 오류율이 포화된다는 보고가 있다 [R5].
- page의 전체 구간 수 = B · L + 1(구간 index 폭: LSB +6 → 8구간 3 bit, MSB +6 → 29구간 5 bit). LUT 항목 수는 [R4]의 Nb(Ks + 1)과 같은 형태.
- δ는 균일 간격 knob(정규화 전압 단위, 또는 인접 σ의 배수). 비균일 배치 [R4], MMI 양자화 [R10]는 N2b의 비교 후보로만 둔다.
- 감지 비용(문헌 값, 25nm MLC): hard read 55 µs(upper)/41 µs(lower), 추가 레벨당 약 14 µs, 7레벨 약 125 µs [R7]. read 지연 모델에 쓴다(`scope.md` 8절).

### 4.2 read retry (기준 전압 offset)
- retry k(k = 1..K)는 page의 각 경계 R_b를 `R_b + Δ_{b,k}`로 옮겨 hard read를 다시 한다. Δ 표는 C에서 각 (P/E, retention) 조건의 최적 교점과 기본 기준 전압의 차이로 [계산]해 만든다.
- 문헌의 retry 정책(ROR [R8], PR²/AR² [R11])은 원리 참고용이다. 그 논문들의 offset 값은 서베이에 없음 → **미확인**.

## 5. LLR 생성 (LUT)

### 5.1 식
page 비트 b, 감지 구간 q(경계값 e_q < Vth ≤ e_{q+1}):
```
P(q | s) = CDF_s(e_{q+1}) − CDF_s(e_q)
LLR(q)   = ln( Σ_{s: bit_b(s)=0} P(q | s) / Σ_{s: bit_b(s)=1} P(q | s) )      (state 사전확률 균등)
LLR_q(q) = sat( round(LLR(q) · scale), ±(2^(w−1) − 1) ),   w = 4, 5, 6
```
- 부호 규약: 양수 = 비트 0. [R4] 식(20)과 같은 적분 형태(서베이 1.2(b)). [R5]는 6 bit LLR을 [−31, 31]로 부호 양자화.
- scale은 knob(N2b에서 FER로 고른다). hard 모드는 구간 2개라 LLR = ±A 하나(A도 knob).
- LUT는 C에서 double로 계산해 정수 표로 저장하고, C decoder와 PL `llr_gen`은 같은 정수 표를 쓴다(bit-exact 기준은 정수 표).
- **불일치 실험**: decoder가 쓰는 LUT는 "공칭 조건"(예: P/E 3000, 30일)에서 만들고 채널은 다른 조건에서 뽑는 경우를 N2b에 포함한다. 실제 컨트롤러는 셀의 정확한 나이를 모른다.
- 모델 A의 분포는 닫힌 식이 아니라 C에서 수치 convolution(격자 PDF) 또는 대량 Monte Carlo histogram으로 CDF를 만든다.

### 5.2 예 [계산, `s1calc.txt` 7절]
TLC LSB page, P/E 500 15일 표, α = 1.5, +6 레벨(R3 + jδ, j = −3..3, δ = 4):
구간 0..7의 LLR = −8.96, −3.55, −2.06, −0.60, 0.82, 2.20, 3.53, 8.17. 양 끝 구간은 크기가 커서 scale에 따라 포화된다.

## 6. raw BER knob

| 모델 | knob | 연속 여부 |
|---|---|---|
| A (MLC) | N(P/E), t(retention h), CCI 강도 s([R4]식) | 연속. 식이 N, t의 함수 |
| B (TLC) | 표 격자(P/E, retention) + α(σ scale) + 선택: 평균 이동 β(이웃 격자 사이 선형 보간) | 격자 + α 연속 |
- FER 곡선의 x축은 knob 자체가 아니라 **그 조건의 hard read raw BER**(해석적 계산값, C에서 Monte Carlo로 교차 확인)로 둔다. 모델과 page가 달라도 같은 축에서 비교할 수 있다.
- α와 β는 이 프로젝트가 만든 보간 knob이라 문헌 조건이 아니다. 문서와 그림에 "α = 1.5 (문헌 격자 밖)"처럼 표시한다.

## 7. 난수 발생기 (C와 PL bit-exact)

요구: C golden, ARM baseline, PL 에뮬레이터가 같은 seed에서 **같은 셀 감지 결과**를 내야 한다(G4 비교와 보드 mismatch 0 기준). 부동소수점 함수(log, sqrt, cos)는 C 라이브러리와 PL에서 bit-exact를 보장하기 어렵다.

### 7.1 uniform 발생기 후보

| 후보 | HW 비용 [추정] | 비고 |
|---|---|---|
| **xoshiro128\*\*** [R50] | 상태 128 FF, 갱신은 XOR/shift/rotate, 출력 `rotl(s1 · 5, 7) · 9`의 상수 곱은 shift + add 두 번 | 주기 2^128 − 1, 32 bit 출력, public domain 참조 C 코드 [R50]. C와 RTL 한 줄씩 대응 |
| LFSR(예: 64 bit) | 가장 작음 | 선형이라 통계 품질이 약하다(일반론). 여러 비트를 한 번에 뽑으면 상관 |
| PCG32 | 64 bit 곱셈(DSP 여러 개) | 비용 대비 이득 없음 [추정] |

- lane별 seed는 C가 만들어 AXI-Lite로 넣는다. lane 간 독립성은 seed를 별도 발생기(예: splitmix64 계열)로 만든 값에 의존한다[추정]. jump 함수는 PL에 넣지 않는다.

### 7.2 Gaussian/감지 구간 생성 후보

| 후보 | 방법 | bit-exact | 정확도 | PL 비용 [추정] |
|---|---|---|---|---|
| G1 Box-Muller(double) | `sqrt(−2 ln u1) cos(2π u2)` | C 내부에서만. PL과 맞추기 어려움 | 정확 | 큼(log, sqrt, cos 근사) |
| G2 CLT(Irwin-Hall) | K개 uniform 합을 정규화 | 정수라 쉬움 | **tail 부족** [계산, 아래 표] | 작음 |
| G3 ICDF LUT | 32 bit uniform → 구간별 다항식으로 Φ⁻¹ | 정수 표와 고정소수점으로 가능 | 표 정밀도에 따름 | 중간(BRAM, 곱셈기) |
| **G4 이산 역CDF(권고)** | state s마다 감지 구간 경계의 누적확률을 32 bit 정수 표 T_s[j] = round(2^32 · P(Vth ≤ e_j \| s))로 저장. uniform u(32 bit)에 대해 구간 = #{j : u ≥ T_s[j]} | 비교만 하므로 자명하게 bit-exact | 구간 확률이 2^−32(= 2.33e−10) 단위로 양자화되는 것 외에는 분포 그대로 | 작음(비교기, 이진 탐색 6단) |

CLT tail [계산, `s1calc.txt` 6절]: P(X > xσ)의 Gaussian 대비 비

| x | Gaussian | K = 4 | K = 8 | K = 12 |
|---|---|---|---|---|
| 2 | 2.275e−2 | 0.935 | 0.968 | 0.979 |
| 3 | 1.350e−3 | 0.159 | 0.612 | 0.746 |
| 4 | 3.167e−5 | 0 | 0.066 | 0.269 |
| 5 | 2.867e−7 | 0 | 0 | 0.007 |

raw BER 1e−3~1e−2는 state 경계가 평균에서 약 2.5~3σ 떨어진 곳이라, CLT(K ≤ 12)는 오류 확률을 25~85% 과소평가한다. G2는 쓰지 않는다.

**권고 G4 + xoshiro128\*\*** 근거:
1. 정확도: 감지 결과만 필요하므로 연속 Vth를 만들 필요가 없다. 어떤 분포(Gaussian, 모델 A의 비Gaussian 주변분포, 나중의 Student's t [R2])든 같은 하드웨어로 뽑는다.
2. bit-exact: 표는 C가 double로 한 번 계산해 정수 파일로 내보내고, C 샘플러와 PL은 그 정수 표만 쓴다. double 계산이 플랫폼마다 조금 달라도 교환 형식은 정수라 비교에 영향이 없다.
3. 비용: 격자 경계를 page당 63개 이하(구간 64개, MSB 4경계 x 15점 = 60, 아래)로 두면 이진 탐색 6단, 표는 state 8 x 63 x 32 bit = 16,128 bit [계산].
- 감지 격자: 한 셀의 감지 결과는 hard, retry, soft 읽기 사이에 서로 모순이 없어야 한다(같은 셀을 다시 읽음). 그래서 표의 구간 경계는 "그 page의 모든 read 설정(hard, retry offset, ±jδ)의 합집합"인 고정 격자로 만들고, 각 read 설정은 격자 index를 자기 구간으로 묶는 작은 표로 처리한다. 경계당 격자 15점(R과 R ± 1..7 step)이면 retry offset과 soft 레벨(±3δ까지)은 격자 위에서만 고를 수 있다(열린 결정 H3).
- 한계: (1) 셀 사이 상관(CCI의 이웃 의존, 같은 word-line 효과)을 표현하지 못한다. v1 가정(1절 셀 독립)과 같다. (2) 확률 2^−32 미만인 구간은 절대 나오지 않는다. RBER 1e−6 이상 영역에는 영향이 없다 [추정]. (3) read disturb 같은 읽기 횟수 의존 효과는 표를 바꿔야 한다.
- G1(Box-Muller, double)은 C 안에서 G4 표를 Monte Carlo로 검증하는 참조로만 둔다(같은 조건에서 구간 histogram 비교).

## 8. C 모듈 경계 (N2 초안)
```
chan_table_build(model, cond, grid)  -> T[state][j] (uint32), 격자 e[j]          // double, 오프라인
chan_sample(T, page_bits[], rng)     -> grid_idx[] (uint8)                          // 정수, bit-exact 기준
sense_read(grid_idx[], read_cfg)     -> region[] (uint8)                            // hard/retry/soft 묶음
llr_lut_build(model, cond_nominal, read_cfg, w, scale) -> lut[region] (int8)        // double -> 정수
llr_map(region[], lut)               -> llr[] (int8)                                // = PL llr_gen
rber_analytic(model, cond, read_cfg) -> page별 raw BER                              // FER x축
```

## 9. 미확인 목록
- MLC Gray 매핑에서 upper/lower 비트 순서, [R3]의 효과 합성 순서와 retention 부호, x < x0' 처리, CCI의 이웃 범위와 ΔVt 정의, [R4]의 Kλ와 γ 분포 폭.
- MLC와 TLC의 read reference 실제 값(문헌), retry offset 표(문헌).
- [R5] 부록 Table A1~A3 중 P/E 500·15일 외 모든 격자 값.
- 공개 raw NAND 측정 데이터셋(서베이 1.5, 찾지 못함).
