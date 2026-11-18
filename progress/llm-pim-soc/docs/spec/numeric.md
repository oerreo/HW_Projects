# 숫자 형식과 정확도 측정 (S2)

- 작성: 2026-11-18, S2(C golden model). 코드: `model/`, 데이터: `data/`.
- 표기: **[측정]** = 이 문서의 명령으로 실행해 얻은 값(PC x86-64, gcc 8.5 `-O2 -ffp-contract=off`). **[계산]** = 구성에서 식으로 구한 값. **[추정]** = 가정이 들어간 값. ARM 수치는 하나도 없다(S3에서 측정).

## 0. 요약
1. **F판은 참조 구현과 완전히 일치한다** [측정]: 두 모델, 프롬프트 32개 전부에서 temperature 0 생성 token 열이 같다(생성 token 260K 8,722개, 15M 6,160개). logits도 전부 bit-identical이다(최대 절대 오차 0, 260K 4,720,128개, 15M 205,888,000개). prompt 인코딩과 모든 token id의 decode도 일치한다.
2. **runq.c 그룹 경계 의심은 사실이다** [측정]: 260K(hidden 172, GS 64)에서 `w2` matmul은 입력 172개 중 앞 128개만 쓰고, 마지막 44개를 +-100으로 바꿔도 출력 64개 중 0개가 변한다. scale 인덱스도 (행, 그룹) 128단계 중 120단계가 평탄화된 그룹 중간에서 시작한다. 결과적으로 runq는 F 대비 top-1 일치 42.0%, logits 최대 오차 22.4로 무너진다. 15M(GS 32가 288과 768을 나눔)은 정상(top-1 98.7%)이다. 우리 Q판(행 안 그룹)은 260K에서 top-1 98.3%.
3. **H판 권장 형식은 HD**(잠정, 사용자 검토 대상): 활성 scale은 17비트 가수(벡터당 정수 나눗셈 1회), 가중치 scale은 행 단위 16비트 가수, exp/sigmoid LUT 257항목(8비트) + 선형 보간, attention의 q, k, v만 int16. 활성 scale을 shift만으로 하면(POW2) 두 모델 모두 dCE가 약 2배로 나빠지는 것이 가장 분명한 결과다. MANT 계열 후보끼리의 차이(15M dCE +0.003~0.006)는 작은 표본의 잡음 수준이다. 근거는 2.4절과 4절.
4. `make test`: 14,190,666 항목, mismatch 0, PASS [측정].

## 2. 정확도 [측정]

측정 방법(`model/tools/run.c`, job eval):
- 프롬프트 세트(`data/prompts/prompts.txt`, 32개)마다 F의 temperature 0 생성 열(260K 최대 512 위치, 15M 최대 256 위치, BOS가 나오면 종료)을 만들고, 각 판을 같은 token 열로 teacher forcing한다. 판의 forward는 결정적이고 앞 token에만 의존하므로, "판의 argmax가 F의 다음 token과 처음 달라지는 생성 위치"가 곧 그 판을 자유 생성했을 때 F와 갈라지는 위치다.
- logits 오차: 모든 위치, 모든 vocab의 `|l_v - l_F|`의 최대와 RMS. H의 logits는 Q16 정수 / 65536.
- top-1 일치율: 모든 위치(prompt 구간 포함)에서 argmax가 F와 같은 비율.
- loss: TinyStories validation 앞 32개 story를 BOS와 함께 인코딩해(최대 512/256 token) 다음 token cross-entropy(nats/token)의 평균. 260K 10,122 token, 15M 5,757 token. `dCE`는 F 대비 차이.
- 갈라짐 위치: 생성 구간의 0부터 센 위치. "평균(갈라진 것만)"과 "끝까지 같으면 생성 길이로 친 평균(하한)"을 같이 적는다.

### 2.1 stories260K (F loss 1.20361)
| 판 | logits 최대 | logits RMS | top-1 % | CE | dCE | 갈라짐/전체 | 평균 위치(갈라진 것) | 평균 위치(검열 포함) |
|---|---|---|---|---|---|---|---|---|
| Qr | 0.913 | 0.124 | 98.20 | 1.20565 | +0.00204 | 31/32 | 41.8 | 56.2 |
| Qg | 0.696 | 0.107 | 98.26 | 1.20504 | +0.00142 | 30/32 | 57.8 | 77.4 |
| HA | 2.650 | 0.261 | 96.30 | 1.21166 | +0.00805 | 32/32 | 27.9 | 27.9 |
| HB | 2.433 | 0.177 | 97.32 | 1.20749 | +0.00388 | 32/32 | 42.9 | 42.9 |
| HC | 1.910 | 0.175 | 97.42 | 1.20701 | +0.00340 | 32/32 | 58.3 | 58.3 |
| HD | 0.814 | 0.123 | 98.06 | 1.20467 | +0.00106 | 32/32 | 49.2 | 49.2 |
| HE | 3.367 | 0.261 | 96.55 | 1.21234 | +0.00873 | 32/32 | 27.3 | 27.3 |
| HF | 1.958 | 0.184 | 97.35 | 1.20741 | +0.00380 | 32/32 | 41.2 | 41.2 |
| HG | 0.969 | 0.127 | 98.15 | 1.20482 | +0.00121 | 31/32 | 54.1 | 56.8 |
| HH | 0.983 | 0.126 | 98.05 | 1.20403 | +0.00042 | 31/32 | 41.4 | 55.8 |
| runq.c (참고) | 22.36 | 2.81 | 42.02 | - | - | 32/32 | 0.7 | - |

### 2.2 stories15M (F loss 0.85498)
| 판 | logits 최대 | logits RMS | top-1 % | CE | dCE | 갈라짐/전체 | 평균 위치(갈라진 것) | 평균 위치(검열 포함) |
|---|---|---|---|---|---|---|---|---|
| Qr | 1.881 | 0.226 | 96.99 | 0.85956 | +0.00458 | 32/32 | 24.2 | 24.2 |
| Qg | 0.929 | 0.120 | 98.42 | 0.85799 | +0.00300 | 31/32 | 50.4 | 56.0 |
| HA | 2.113 | 0.293 | 95.46 | 0.86345 | +0.00847 | 32/32 | 17.7 | 17.7 |
| HB | 1.614 | 0.228 | 96.88 | 0.85803 | +0.00305 | 32/32 | 22.4 | 22.4 |
| HC | 1.806 | 0.203 | 96.50 | 0.85801 | +0.00303 | 32/32 | 19.2 | 19.2 |
| HD | 1.621 | 0.229 | 96.81 | 0.86032 | +0.00534 | 31/32 | 20.5 | 27.6 |
| HE | 2.160 | 0.305 | 95.70 | 0.86272 | +0.00774 | 32/32 | 17.2 | 17.2 |
| HF | 1.712 | 0.226 | 96.99 | 0.86078 | +0.00580 | 31/32 | 24.1 | 27.5 |
| HG | 1.597 | 0.223 | 96.69 | 0.86118 | +0.00620 | 32/32 | 16.0 | 16.0 |
| HH | 1.586 | 0.206 | 97.45 | 0.85895 | +0.00396 | 32/32 | 29.3 | 29.3 |
| runq.c (참고, 같은 프롬프트) | 0.801 | 0.103 | 98.68 | - | - | 27/32 | 58.6 | - |

### 2.3 후보 정의
| 이름 | 활성 scale | 가중치 그룹 | exp LUT (항목) | sigmoid LUT (항목) | q, k, v |
|---|---|---|---|---|---|
| HA | POW2 (shift만) | 행 | 4비트 (17) | 5비트 (33) | int8 |
| HB | MANT (17비트 가수) | 행 | 8비트 (257) | 8비트 (257) | int8 |
| HC | MANT | 64 이하 약수 | 8비트 | 8비트 | int8 |
| HD | MANT | 행 | 8비트 | 8비트 | int16 |
| HE | POW2 | 행 | 8비트 | 8비트 | int8 |
| HF | MANT | 행 | 4비트 | 5비트 | int8 |
| HG | MANT | 행 | 4비트 | 5비트 | int16 |
| HH | MANT | 64 이하 약수 | 4비트 | 5비트 | int16 |

HG와 HH는 HA~HF 결과를 본 뒤 추가로 측정한 조합이다(같은 실행 파일, 같은 데이터. HB를 같이 다시 돌려 이전 값과 같음을 확인했다).

### 2.4 해석
- **활성 scale이 가장 큰 요인**: POW2(HA, HE)는 MANT(HB, HF)보다 두 모델 모두에서 dCE가 약 2배(260K +0.0081~0.0087 대 +0.0038, 15M +0.0077~0.0085 대 +0.0031~0.0058), top-1이 1%p 이상 낮다. POW2는 max가 64~127 사이에 오므로 평균 약 반 비트를 잃는다.
- **LUT 크기는 260K에서는 영향이 없고 15M에서는 조금 있다**: 4/5비트로 줄이면 260K dCE 변화는 0.0001 이하(HB 대 HF, HD 대 HG)이나 15M에서는 +0.0028(HB 대 HF), +0.0009(HD 대 HG) 나빠진다. top-1은 섞여 있다. 8비트 LUT(257항목 x 17비트, 약 4.4 Kb)도 BRAM18 하나보다 작아 줄일 이유가 약하다.
- **q, k, v를 int16으로 하면 260K가 크게 좋아진다**: HD/HG는 260K에서 logits 최대 오차를 2.4에서 0.8~1.0으로, dCE를 +0.0039에서 +0.0011~0.0012로 줄여 Q판(Qg)과 같은 수준이 된다. head_size가 8인 260K는 head 벡터 하나의 int8 양자화 오차가 score에 그대로 들어간다. 15M(head_size 48)에서는 차이가 잡음 수준이다.
- **가중치 그룹(HC, HH)은 일관된 이득이 없다**: HC는 HB 대비 260K에서 logits 최대 오차만 줄고 15M에서는 dCE가 같으며 top-1이 0.4%p 낮다. HH는 HG 대비 15M에서 dCE -0.0022, top-1 +0.8%p로 좋아졌다. 방향이 섞여 있어 판단을 보류한다. Q판에서 Qg가 Qr보다 좋은 것(15M top-1 98.4 대 97.0)은 주로 활성의 그룹 scale 때문으로 보인다 [추정, 분리 실험 안 함]. H판은 활성 scale을 벡터당 하나로 둔다(gemv가 그룹마다 활성 scale을 곱하지 않아도 되게).
- **갈라짐 위치는 거의 모든 판에서 수십 token 안에 생긴다**: temperature 0 생성은 1~2위 logits 차이가 작은 위치에서 바로 갈라진다. F와 Q 사이에서도 평균 24~58 위치다. 이 지표만으로 형식을 고르지 않고 dCE와 top-1을 주 지표로 쓴다.
- 이 표의 차이는 한 번의 결정적 실행에서 나온 값이고, 프롬프트 32개와 story 32개라는 작은 표본이다. 0.001 nats 이하의 dCE 차이는 표본을 바꾸면 순서가 바뀔 수 있다 [추정].

## 3. 연산량

### 3.1 token당 MAC와 호출 횟수 [계산]
T = 현재 위치 + 1(attention 길이). gemv = 층의 7개 행렬 + 분류기. attention MAC = layer x head x 2 x head_size x T.

| 모델 | T | gemv MAC | attention MAC | 합계 | attention 비중 |
|---|---|---|---|---|---|
| 260K | 1 | 259,328 | 640 | 259,968 | 0.2% |
| 260K | 64 | 259,328 | 40,960 | 300,288 | 13.6% |
| 260K | 128 | 259,328 | 81,920 | 341,248 | 24.0% |
| 260K | 256 | 259,328 | 163,840 | 423,168 | 38.7% |
| 260K | 512 | 259,328 | 327,680 | 587,008 | 55.8% |
| 15M | 1 | 15,187,968 | 3,456 | 15,191,424 | 0.02% |
| 15M | 64 | 15,187,968 | 221,184 | 15,409,152 | 1.4% |
| 15M | 128 | 15,187,968 | 442,368 | 15,630,336 | 2.8% |
| 15M | 256 | 15,187,968 | 884,736 | 16,072,704 | 5.5% |

15M의 gemv 중 분류기(32000 x 288)가 9,216,000 MAC이다.

token당 kernel 호출 횟수 [계산, 프로파일에서 같은 값 측정]:

| kernel | 260K | 15M | 식 |
|---|---|---|---|
| embed | 1 | 1 | 1 |
| gemv | 36 | 43 | 7L + 1 |
| rmsnorm | 11 | 13 | 2L + 1 |
| rope | 10 | 12 | 2L (q, k) |
| actq | 85 | 114 | L (2 n_kv + n_heads + 1) |
| attn | 40 | 36 | L n_heads |
| swiglu | 5 | 6 | L |
| add | 10 | 12 | 2L |
| argmax | 1 | 1 | 1 |

### 3.2 PC에서의 kernel별 시간 비중 [측정, x86 PC, ARM 아님]
H판 HB, 프롬프트 8개 greedy 생성, 각 kernel 호출 앞뒤에서 `clock_gettime`(hook). `model/results/prof_m*.txt`.

| kernel | 260K: token당 MAC(평균) | 260K 시간 % | 15M: token당 MAC(평균) | 15M 시간 % |
|---|---|---|---|---|
| gemv | 259,328 | 43.0 | 15,187,968 | 94.6 |
| attn | 131,089 (평균 T 약 205) | 49.2 | 369,919 (평균 T 약 107) | 3.4 |
| swiglu | 1,720 | 3.1 | 9,216 | 0.5 |
| rmsnorm | 1,408 | 2.2 | 7,488 | 0.4 |
| actq | - | 1.5 | - | 0.3 |
| argmax | - | 0.4 | - | 0.8 |
| rope | 960 | 0.3 | 6,912 | 0.1 |
| add, embed | - | 0.2 | - | 0.04 |

- token당 시간(PC): 260K는 H 0.25 ms, F 0.18 ms; 15M은 H 5.36 ms, F 8.46 ms. ARM Cortex-A9에서의 값과 비중은 S3에서 잰다. 특히 260K에서 attention이 PC 시간의 절반인 것은 MAC 비중(평균 T에서 약 34%)보다 크다. int64 누산과 위치별 scale 곱이 MAC당 비용을 늘리기 때문으로 보인다 [추정].

## 4. H판 형식 권장: HD (잠정)

| 항목 | 권장 | 근거 (측정) | HW 비용 근거 (Z7-20: DSP48E1 220개, BRAM 4.9 Mb) |
|---|---|---|---|
| 활성 scale | 17비트 가수 + 지수 (MANT) | POW2 대비 dCE 절반, top-1 +1%p (2.4절) | 벡터당 정수 나눗셈 1회(순차 divider, 40/17비트, 수십 cycle로 벡터 길이 64~768에 숨김)와 원소당 32x25 곱 1회(DSP 2개)를 actq 한 곳에 둔다. gemv의 최종 `S * xm`은 행당 1회라 MAC lane 수와 무관 [추정] |
| 가중치 scale | 행 단위 16비트 가수, 행렬 공통 지수 | 그룹(HC, HH)은 일관된 이득 없음 | 행당 곱 1회. 그룹을 쓰면 64 MAC마다 int32 x 16비트 곱과 int64 덧셈이 추가되고 가수 저장이 약 3% 는다 [계산] |
| exp LUT | 8비트 인덱스 257항목 x 17비트 + 선형 보간 | 4비트로 줄이면 15M에서 dCE +0.001~0.003 | 약 4.4 Kb, BRAM18 1개 이하 또는 분산 ROM. 보간 곱 1개. 4비트(17항목)는 자원을 거의 줄이지 못한다 [추정] |
| sigmoid LUT | [0, 16) 구간 8비트 인덱스 257항목 + 보간 | 위와 같음 | 위와 같음 |
| rsqrt | 48항목 seed + Newton 2회 (고정) | 상대 오차 3.05e-5 이하 (단위 테스트) | rmsnorm 1회당 곱 6회, 벡터당 1회라 순차 처리 가능 |
| attention q, k, v | int16 | 260K에서 dCE +0.0039 -> +0.0011, logits 최대 2.4 -> 0.8 (HB 대 HD). 15M에서는 이득 없음(+0.0031 대 +0.0053, 잡음 수준) | 곱은 16x16이라 DSP 하나에 들어간다(int8 두 개를 DSP 하나에 packing하는 이득은 잃음). KV cache가 2배: 260K 160 KiB -> 320 KiB [계산]. 260K int8 가중치(약 269 KiB)와 int16 KV를 둘 다 BRAM(560 KiB)에 두면 589 KiB로 넘친다. KV cache는 DDR/PS 쪽 또는 짧은 context로 제한해야 한다 |
| gemv | int8 x int8, int32 누산 | Q판과 같은 구조 | DSP 하나에 int8 MAC 1개(또는 packing 2개). HP 1포트 대역폭으로 15M은 8 lane이면 포화(survey 7.3) |

- 대안: KV cache 용량이 문제가 되면 HB(q, k, v int8, 나머지는 HD와 같음)를 쓴다. 260K dCE +0.0039, 15M +0.0031. 15M만 대상이면 HB가 HD보다 나쁘지 않다.
- 측정하지 않은 조합: MANT + 그룹 + 8비트 LUT + int16 q, k, v(HH의 8비트 LUT판). HH가 15M에서 좋았으므로 다음 측정 후보다.
- MANT 후보 사이의 순위는 프롬프트 32개, story 32개로는 확정하기 어렵다. 확정 전에 평가 텍스트를 늘려(예: story 200개) 다시 재는 것을 권한다 [추정, 실행 시간 15M 기준 수십 분].
- 최종 확정은 사용자 검토 후. 이 권장은 PC 측정만 근거로 한다(자원 수치는 합성 결과가 아닌 추정).

## 5. runq.c 그룹 경계 확인 [측정 + 코드 분석]
`model/tools/rq.c`, 결과 `model/results/runq_m1.txt`, `runq_m2.txt`.

- 코드 분석: `export.py` version 2는 그룹 크기를 `dim`이 나누어질 때까지만 반으로 줄이고(`while model.params.dim % group_size != 0`), 그룹을 평탄화한 tensor 단위로 잡는다(`w.reshape(-1, group_size)`, `numel % group_size == 0`만 검사). `runq.c`의 `matmul`은 `for (j = 0; j <= n - GS; j += GS)`로 행 안에서 GS 단위만 돌고 scale은 `w->s[(in + j) / GS]`(in = i * n)로 찾는다. `quantize`도 `n / GS`개 그룹만 양자화한다. 따라서 n이 GS의 배수가 아니면 (1) 행의 마지막 `n % GS`개 입력이 버려지고, (2) i > 0인 행의 그룹이 평탄화 그룹 경계와 어긋나 다른 원소의 scale을 쓴다.
- 실행(260K, GS 64, w2의 n = 172): 사용되는 입력 128/172, 마지막 44개를 바꿔도 출력 변화 0/64, 어긋난 scale 단계 120/128, random 입력에서 w2 출력 오차 최대 1.55(출력 최대 2.51). 모델 전체: F 대비 logits 최대 22.4, RMS 2.81, top-1 42.0%, 32개 프롬프트 모두 생성 평균 0.7 위치에서 갈라짐.
- 대조(15M, GS 32, 288과 768 모두 배수): 버려지는 입력 0, 어긋난 단계 0, top-1 98.7%.
- 42M(hidden 1376, GS 64: 1376 % 64 = 32)도 같은 조건이라 같은 문제가 있을 것이다 [추정, 실행하지 않음].
- 우리 Q판과 H판은 그룹을 행 길이의 약수로 잡아 이 문제가 없다(Qg 260K top-1 98.3%).
- 주의: v2 파일은 PyTorch 대신 C로 export 규칙을 재현해 만들었다. scale은 float32 나눗셈, 반올림은 `rintf`(half to even, `torch.round`와 같은 규칙)이다. 원본 export.py로 만든 파일과 bit 단위로 같은지는 확인하지 않았다.

## 6. PIM형 bank 분할 GEMV (`model/src/bank.c`)
- 모델: 입력 벡터를 global buffer에 한 번 방송하고, bank마다 자기 가중치 image로 MAC한 뒤 controller가 결과를 모은다. ROW(행 r을 bank r mod N에 배치, bank가 완성 출력을 냄)와 COL(bank b가 모든 행의 열 구간을 가짐, int32 그룹 부분합을 controller가 더한 뒤 scale)의 두 배치.
- 명령 수 통계(`bank_stat_t`): global buffer 쓰기(32 B 단위), all-bank MAC 명령(bank당 16 lane 가정), 결과 읽기. 비교 지표의 모델일 뿐 timing은 없다.
- 시험 [측정]: 두 모델의 모든 층 행렬과 분류기, bank 수 1, 2, 3, 4, 5, 8, 16, 32, ROW/COL, 입력 3종(전부 127 포함)에서 `k_gemv`와 bit-exact. 260K HB 1,728건, HC 1,728건, 15M HB 2,064건, mismatch 0.

## 7. kernel 경계 덤프 (RTL TB 벡터)
- H forward의 모든 kernel 호출은 descriptor를 거치며, hook이 입력과 출력을 레코드로 쓴다(형식: `model/README.md`).
- 만든 파일 [측정]: `model/cfg/d1.cfg` 260K HB, 프롬프트 1번 8 위치, 1,592 레코드(3.1 MB, `model/build/vec_m1.bin`); `d2.cfg` 15M HB, kernel 종류마다 40개 제한, 296 레코드(7.4 MB). 커밋하지 않는다(재생성 명령만).
- 재생 시험 [측정]: 260K HB와 HD는 6 위치 전체(각 1,194 레코드), 15M HA는 종류당 24개(180 레코드)를 다시 읽어 `k_exec`로 실행한 출력이 기록과 bit 단위로 같다. 9종 kernel이 포함된다(topk는 forward에서 쓰지 않아 단위 테스트로만 검증).

## 8. 테스트 (`make test`) [측정]
| 묶음 | 항목 | mismatch | 기준 |
|---|---|---|---|
| rsqrt | 248,002 | 0 | 상대 오차 3.1e-5 이하 (관측 최대 3.05e-5) |
| exp2 LUT 4~8비트 (전 구간 전수) | 5 x 1,048,576 | 0 | 보간 한계 ln2^2 h^2 / 8 + 1.5 LSB |
| sigmoid LUT 4~8비트 | 5 x 873,814 | 0 | 0.0962 h^2 / 8 + 꼬리 + 1 LSB (5비트 관측 196 LSB, 한계 198) |
| actq | 2,435,303 | 0 | 반 step + 상대 1.2e-7, 범위 사용(MANT >= qmax-1, POW2 > qmax/2) |
| gemv | 12,753 | 0 | 정확값 대비 0.5 LSB (최대 길이 16,384, 전부 127, 포화 포함) |
| rmsnorm | 528,000 | 0 | 반 step + 16비트 축소와 rsqrt 오차 |
| rope | 195,296 | 0 | 표 반올림 + 0.5 LSB |
| attention | 104,000 | 0 | 2.4절 식(주석에 유도) |
| swiglu | 940,000 | 0 | 반 step + sigmoid 오차 x |ab| |
| add 포화, argmax, topk, descriptor 범위 거부 | 42,171 | 0 | 정확 일치 |
| decode 전 id (260K, 15M) | 1,024 + 64,000 | 0 | run.c `decode`와 문자열 일치 |
| F 대 참조 (프롬프트) | 32 + 32 | 0 | prompt token, 생성 token, decode, logits |
| 전 판 build + 실행 | 2 | 0 | 오류 없음 |
| bank == gemv | 5,520 | 0 | bit-exact |
| 덤프 재생 | 2,568 | 0 | bit-exact |
| 정수 경로 검사 | 13 | 0 | 1.4절 |
| 합계 | 14,190,666 | 0 | PASS |

seed 20261118. 로그는 `model/build/test.log`(커밋 제외).

## 9. 재현 명령
```sh
sh data/scripts/fetch.sh
cd model && make test
CFG=cfg/e1.cfg ./build/run; CFG=cfg/e2.cfg ./build/run   # 2.1, 2.2 (HA~HF, Q)
CFG=cfg/f1.cfg ./build/run; CFG=cfg/f2.cfg ./build/run   # HG, HH
CFG=cfg/p1.cfg ./build/run; CFG=cfg/p2.cfg ./build/run   # 3.2
CFG=cfg/r1.cfg ./build/rq;  CFG=cfg/r2.cfg ./build/rq    # 5절
CFG=cfg/d1.cfg ./build/run; CFG=cfg/d2.cfg ./build/run   # 7절
```
PC 실행 시간 [측정]: e1 31 s, e2 642 s, f1 17 s, f2 307 s, r2 129 s, p2 22 s, make test 수 분(측정하지 않음).

## 10. 확인하지 못한 것
- ARM(Cortex-A9) 컴파일과 실행: 이 서버에 ARM cross compiler가 없다. `-m32`(32비트 `long`)로 라이브러리 9개 파일이 경고 없이 컴파일되는 것만 확인했다(링크와 실행은 안 함).
- RoPE 표를 다른 플랫폼 libm으로 만들면 드물게 1 LSB 다를 수 있다. HW ROM은 PC 표를 쓴다.
- Llama 2 tokenizer(`tokenizer.bin`) 라이선스: 미확인(`data/README.md`).
- 자원 수치(DSP, BRAM)는 전부 추정이다. 합성하지 않았다.
- H판의 Q16 logits에서 15M 분류기 출력 범위 포화가 생겼는지 따로 세지 않았다(logits 오차에 반영되어 있음).

## 1. 세 판의 정의

| 판 | 행렬곱 | 비선형 | 쓰임 |
|---|---|---|---|
| F | float32, 참조 구현과 같은 연산 순서 | float32 (`expf`, `sqrtf`, `powf`, `cosf`, `sinf`) | 참조 일치 확인, 정확도 기준 |
| Q | int8 x int8, int32 그룹 누산, 그룹마다 float scale(가중치와 활성 각각), float 합 | float32 | 양자화만의 오차 분리 |
| H | int8 x int8, int32 그룹 누산, scale은 가수와 shift | 정수/고정소수점 | RTL golden. 후보 형식 비교 |

### 1.1 Q판
- 가중치: 행 안의 그룹마다 `s = max|w| / 127`(float), `q = round(w / s)`. 그룹 크기는 행 길이의 약수(`lm_group`: 목표 이하에서 가장 큰 약수). 그룹이 행 경계를 넘지 않는다.
  - `Qr`: 그룹 = 행 전체. `Qg`: 목표 64 -> 260K는 64(n=64), 43(n=172); 15M은 48(n=288), 64(n=768).
- 활성: 행렬곱 입력마다 같은 그룹 크기로 동적 양자화(`s = max|x| / 127`).
- 누산 한계 [계산]: 그룹 합 `|acc| <= gs * 127 * 127`. int32 한계 `2^31 - 1 = 2,147,483,647`에서 `gs <= 133,144`. 코드는 `gs <= K_NMAX = 16,384`(그룹 합 최대 264,257,536)를 `lm_q_build`에서 검사하고, 넘으면 초기화가 실패한다. 실제 최대 그룹은 15M `w2`의 행 전체 768: `768 * 16,129 = 12,387,072 < 2^24`.

### 1.2 H판의 고정 형식 (모든 후보 공통)
| 신호 | 형식 |
|---|---|
| residual x, gemv 출력(q, k, v, h1, h3, wo/w2 출력), logits, attention 출력 | int32, Q16 (`K_FX = 16`) |
| attention score | int32, Q16 (`K_FS = 16`) |
| softmax 분자, 확률 | uint, Q16 (최대 65536 = 1.0) |
| 가중치 | int8 대칭 [-127, 127], (행, 그룹)마다 16비트 가수 `m`, 행렬마다 공통 지수 `we`: scale = `m * 2^-we` |
| gemv 입력 활성 | int8 대칭, 벡터마다 scale `{m, e}` (`m < 2^17`) |
| rmsnorm gain | int16, `g * sqrt(n)`을 미리 곱함, 텐서마다 지수 `ge` |
| RoPE cos/sin | int16 Q14, 표 `[seq_len][head_size]` |
| q 가중치 | `1/sqrt(head_size)`를 양자화 전에 `wq`에 접어 넣음(RoPE가 선형이라 동치) |

반올림은 `rshr(x, s) = floor((x + 2^(s-1)) / 2^s)`(round half up, 산술 shift). 포화는 int32 경계.

### 1.3 H판 kernel 정의 (`model/src/kern.c`, bit-exact 원본)
| kernel | 입력 -> 출력 | 연산 |
|---|---|---|
| `embed` | int8 행, 가수 -> int32 Q16 | `rshr(q * m, we - 16)` |
| `gemv` | W int8, 가수, x int8 + `{xm, xe}` -> int32 Q16 | 그룹마다 int32 `acc`, `S = sum(acc * m_g)`(int64), `y = sat32(rshr(S * xm, we + xe - 16))` |
| `actq` | int32 Qf -> int8(또는 int16) + `{m, e}` | `amax` 한 번. POW2: 시프트 `k`를 `rshr(amax, k) <= qmax`인 최소값으로. MANT: `M = round(amax * 2^e / qmax)`(17비트), `R = round(2^40 / M)`(정수 나눗셈 1회/벡터), `q = rshr(v * R, 40 - e)` |
| `rmsnorm` | int32 Q16 + gain -> int8 + `{m, e}` | `max|x|`로 16비트까지 shift(`xs`), `u = sum(xs^2) + (epsc >> 2k)`, `1/sqrt(u)`(6비트 seed 48항목 LUT + Newton 2회, 16비트), `y = xs * g * rsqrt`를 Q16으로, 이어서 `actq` |
| `rope` | int32 Q16 + 표 한 행 -> int32 Q16 | `rshr(v0 c - v1 s, 14)` |
| `attn` (head 하나) | q, K, V(int8 또는 int16) + 위치별 scale -> 확률 Q16, 출력 Q16 | score = `rshr(rshr(dot, d0) * (qm * km_t), ...)`; `d = s - max`, `w = rshr(d * 47274, 15)`(log2 e, Q15); `2^-w`는 정수부 shift + 소수부 LUT(2^b+1 항목) 선형 보간; 합으로 정수 나눗셈 1회/head(`2^48 / sum`); V 가중합은 위치별 scale을 가장 거친 지수로 정렬(guard bit로 33비트 유지), int64 누산 |
| `swiglu` | h1, h3 Q16 -> int8 + `{m, e}` | `sigmoid(|a|)`를 [0, 16) 구간 LUT(2^b+1 항목) 보간, 음수는 `1 - s`; `silu = a * s`, `g = silu * h3`, 이어서 `actq` |
| `add` | int32 + int32 -> int32 | 포화 덧셈 |
| `argmax`, `topk` | int32 logits -> index | 같은 값이면 앞 index |

- 모든 kernel은 입력/출력 버퍼와 정수 parameter만으로 동작한다(전역 상태 없음). 같은 호출을 descriptor(`kcall_t`)로도 부를 수 있고(`k_exec`), H forward는 모든 연산을 descriptor로 호출해 hook이 입출력을 덤프한다.
- 누산 범위 [계산, 코드 주석과 `k_exec`의 범위 검사]: gemv 그룹 합 `< 2^31`(gs <= 16,384), `|S| < n * 2^14 * 2^16 <= 2^44`, `|S * xm| < 2^61`. attention dot int8 `< 48 * 127^2 < 2^21`, int16은 `d0 = 15`로 줄여 `< 2^21`, `c = qm * km < 2^34`, 곱 `< 2^55`; V 누산 `< 2^33 * 2^15 * 2^12 = 2^60`(T <= 4096). rmsnorm `xs^2` 합 `<= n * 2^30`, `xs * g * rsqrt < 2^47`.
- LUT 상수는 `model/tools/gentab.c`가 한 번 만들어 `src/tabs.c`로 고정한다(플랫폼마다 libm 결과가 달라도 같은 정수). RoPE 표만 초기화 때 `cos/sin`으로 만든다. HW의 RoPE ROM은 PC 빌드의 표(덤프에 포함)를 쓴다.

### 1.4 float 없음의 증명 (`make check-int`, `model/tools/chk.sh`)
- 대상: `kern.c`, `fwd_h.c`, `bank.c`, `tabs.c`(H 추론 경로 전체. 가중치 준비 `hq.c`와 tokenizer는 초기화/호스트 쪽이라 제외).
- 방법 3가지: (1) `-mgeneral-regs-only -Werror`로 컴파일(FP/SIMD 레지스터 사용 금지, float 연산이 있으면 컴파일 오류), (2) object의 미정의 심볼에 libm과 float 보조 함수가 없음(`nm -u`), (3) 주석을 제거한 소스에 `float`/`double` 토큰이 없음.
- 음성 대조: float 곱을 쓴 작은 파일이 같은 옵션에서 컴파일 오류가 나는지 확인한다(방법이 실제로 잡는다는 근거).
- 결과 [측정]: 13항목 mismatch 0. 미정의 심볼은 `k_rsq_lut`, `k_exec`, `lm_take`, `k_rshr`, `memcpy`뿐.
