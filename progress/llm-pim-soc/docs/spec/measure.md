# 측정 정의: ARM baseline과 오프로드 비교 (S3, S6)

- 작성: 2026-11-18, S3. 코드: `fpga/sw/`(측정 프로그램), `fpga/sw/tools/parse_log.py`(로그 해석). 실행 절차는 `fpga/README.md`.
- 이 문서에는 ARM 측정값이 없다. 보드 실행 전이다. 호스트(x86) 실행은 프로그램 로직 확인용이며 수치를 baseline으로 쓰지 않는다.
- 참고용 PC 프로파일(`fpga/sw/test/build/logs/t32.log`, PC x86 `-m32`, gcc 8.5 `-O2`, H판 K12V8, run P 비중, **ARM 아님**): 260K(512 위치)는 attn 70.5%, gemv(q, k, v, o, w1, w2, w3, cls) 합계 약 18.9%, swiglu 4.1%, rmsnorm 3.1%. 15M(256 위치)은 gemv_cls 52.0%, gemv_w1/w2/w3 합 22.1%, gemv_q/k/v/o 합 11.3%, attn 9.7%, run E 6.650 ms/token. ARM에서는 비중이 다를 수 있다(cache, DDR 대역폭).
- 표기: [정의] = 이 프로그램이 재는 방식. [추정] = 가정이 들어간 식이나 판단.

## 1. 측정 대상과 조건 [정의]
| 항목 | 값 |
|---|---|
| 모델 | stories260K(프로그램에 배열로 내장), stories15M(JTAG로 DDR 고정 주소에 적재) |
| 판 | 기대값 헤더(`fpga/sw/expect/exp_m*.h`)가 정한 판. 기본 F, Qg, H(K12V8, S2b 결정. K는 12비트를 담는 int16 container, V는 int8). 생성 설정 `fpga/sw/tools/m1.cfg`, `m2.cfg`의 `vars` |
| 입력 | `data/prompts/prompts.txt`의 1번 줄 "Once upon a time"(BOS 포함 5 token), greedy |
| 길이 | 모델의 seq_len 전체: 260K 512 위치, 15M 256 위치. BOS가 나와도 멈추지 않는다(실행마다 forward 횟수가 같도록) |
| CPU | Cortex-A9 core 0 하나, bare-metal(Xilinx standalone), 인터럽트 사용 안 함. core 1은 쓰지 않는다 |
| 캐시 | BSP 기본(L1 I/D, L2 PL310 켜짐, DDR 전체 cacheable). 각 실행 직전 `Xil_DCacheFlush`(전체 write back + invalidate) |
| 컴파일 | `-O2`와 `-O3` 두 빌드, `-mfpu=neon -mfloat-abi=hard -ffp-contract=off`, `-ffast-math` 없음 |

## 2. 시간 기준 [정의]
- 구간 측정은 Cortex-A9 global timer(`XTime_GetTime`, 64비트)로 한다. 단위 tick, 초당 tick은 `COUNTS_PER_SECOND`(BSP 값, CPU 클럭의 1/2)이며 로그의 `CLK tps`에 찍힌다.
- PMU cycle counter(CP15 PMCCNTR, 32비트)는 두 곳에만 쓴다: (1) global timer 0.1초 동안의 cycle 수로 실제 CPU 클럭 확인(`CLK cyc_per_100ms`), (2) probe 오버헤드의 cycle 단위 값(`OVH avg_cyc`). 32비트라 667 MHz에서 약 6.4초마다 넘친다 [계산]. 긴 구간에는 쓰지 않는다.
- 시간 기준 값 자체의 읽기 비용은 `OVH kind=timer_pair`(연속 두 번 읽은 차의 최소와 평균).

## 3. 구간 정의 [정의]
한 token = 위치 하나의 forward 한 번 + argmax(다음 token 선택). H는 argmax가 forward 안의 kernel(`K_ARGMAX`)이고, F와 Q는 forward가 돌려준 logits에 프로그램이 `argmax_f`(첫 최대값 index)를 적용한다. 정합성 확인용 hash 계산과 UART 출력은 어느 구간에도 들어가지 않는다.

| 실행 | 측정 방식 | 계측 코드 | 결과 키 |
|---|---|---|---|
| E | 전체 위치 앞뒤에 time stamp 한 쌍 | 없음. `model/src`의 `lm_f_forward`, `lm_q_forward`, `lm_h_forward(hook = NULL)` 그대로 | `RUN run=E`: ticks, ms_tok, tok_s |
| T | 위치마다 forward + argmax 앞뒤에 time stamp 한 쌍 | 위치당 timer 읽기 2회 | `RUN run=T`, `POS`(위치별), `TOKPOS` |
| P | kernel 경계마다 lap probe | F, Q: `fq_prof.c`(아래 4절). H: `k_hook_t`(model/src 그대로) | `KERN`(범주별 ticks, 호출 수), `RUN run=P` |
| init | 판 하나의 준비(양자화, 표 생성) | 판마다 앞뒤 한 쌍 | `VAR init_ticks`, `bytes` |
| 데이터 검사 | checkpoint와 tokenizer 이미지의 FNV-1a hash | 앞뒤 한 쌍 | `DATA hash_ticks` |

- end-to-end(token당) = E의 ticks / 위치 수. 이것이 "계측을 끈" baseline이다. tokens/s = 위치 수 / E 시간.
- 위치별: T의 `POS`. 요약 `TOKPOS`: `first`(위치 0, flush 직후라 cache가 비어 있음), `first8`(0~7 평균), `mid`, `mid8`(steps/2 앞뒤 4개 평균), `last`, `last8`(마지막 8개 평균). 앞의 5개 위치는 prompt token을 넣는 위치(teacher forcing)이지만 연산은 생성 위치와 같다.
- 계측 오버헤드: (P의 합 - E) / E를 `P vs E %`로 보고한다. 같은 값을 probe 비용 측정으로도 추정한다: probe 수 x 1회 비용(`OVH kind=lap`, H는 `hook_pair`/2) / P의 합(`probe est %`, 파서가 계산). 두 값이 크게 다르면 계측이 코드 배치나 cache 동작을 바꾼 것이다.

## 4. kernel 범주 [정의]
lap 방식: probe마다 timer를 한 번 읽고 직전 probe 이후의 시간을 한 범주에 더한다. 따라서 한 token의 범주 합은 그 token의 P 시간과 정확히 같다(빠지는 시간이 없다). 파서가 `KERN` 합과 `RUN run=P`가 같은지 다시 확인한다.

| 범주 (`KERN k=`) | F | Q | H |
|---|---|---|---|
| embed | 임베딩 행 복사 | 역양자화된 float 표의 행 복사 | `K_EMBED` |
| rmsnorm | float RMSNorm | 같음 | `K_RMSNORM`(gemv 입력의 활성 양자화 포함) |
| gemv_q, gemv_k, gemv_v, gemv_o | float matmul | int8 MAC + 그룹 scale 결합(float). 입력 양자화는 actq | `K_GEMV`, 가중치 포인터로 행렬 구분 |
| gemv_w1, gemv_w2, gemv_w3 | 같음 | 같음 | 같음 |
| gemv_cls | 분류기 matmul | 같음 | 같음 |
| rope | 위치마다 `powf`, `cosf`, `sinf` 계산 포함 | 같음 | `K_ROPE`(표 조회), q와 k 각각 호출 |
| actq | 없음 | gemv 입력의 그룹 양자화(행렬마다) | `K_ACTQ`: K, V cache 쓰기, head별 q, attention 출력 |
| attn | head마다 score, softmax(`expf`), 가중합 | 같음 | `K_ATTN` 또는 `K_ATTN2`(형식에 따라), head마다 |
| swiglu | float SiLU x h3 | 같음 | `K_SWIGLU`(활성 양자화 포함) |
| add | residual 덧셈 | 같음 | `K_ADD` |
| argmax | `argmax_f` | 같음 | `K_ARGMAX` |
| other | forward 반환 등 나머지 | 같음 | descriptor 구성(`kc0`, `kp`, `kb`), hook 분류, kernel 사이 glue |

- H의 kernel 시간에는 `k_exec`의 descriptor 검사와 hook 진입/복귀 비용 절반 정도가 들어간다 [추정]. 이 glue는 오프로드에서 "호출 오버헤드"에 대응하는 ARM 쪽 비용이다.
- F와 Q의 P 실행은 `model/src`의 forward 함수를 쓰지 못한다(한 함수 안에서 모든 단계를 계산하고 hook이 없다). `fpga/sw/src/fq_prof.c`가 같은 연산을 같은 순서로 옮겨 적고 단계 사이에 probe를 넣었다. 매 실행에서 P의 logits hash를 같은 판 T 실행(`model/src` 함수)의 hash와 위치마다 비교한다(`CHECK run=P self_mis`). 0이 아니면 옮겨 적은 코드가 `model/src`와 달라진 것이다. E와 T는 `model/src` 함수를 그대로 쓴다.
- 이 차이 때문에 F와 Q는 P의 합과 E가 계측 비용 외의 이유(코드 배치)로도 다를 수 있다. 판 사이 비교에는 E를, 판 안의 비중에는 P를 쓴다.

## 5. 정합성 기준 [정의]
| 비교 | F | Q | H |
|---|---|---|---|
| token(위치마다 argmax) 대 PC 기대값 | 필수 | 필수 | 필수 |
| logits hash(위치마다) 대 PC 기대값 | 참고(플랫폼 libm 차이 허용) | 필수 | 필수 |
| P logits hash 대 T logits hash | 필수 | 필수 | 필수 |
| 양자화 가중치 hash 대 PC | - | 필수 | 필수 |
| prompt 인코딩 대 PC | 필수 | 필수 | 필수 |
| 데이터 이미지 hash | 필수(모델 단위) | | |

- H의 RoPE 표는 초기화 때 `cos`/`sin`으로 만들므로 플랫폼 libm에 따라 1 LSB 다를 수 있다(numeric.md 10절). 다르면 `ROPE diff`에 개수를 찍고 PC 표(헤더에 내장)로 바꾼다(`ROPE_FROM_PC=1`, HW ROM도 PC 표를 쓴다는 규칙). 이 경우는 mismatch로 세지 않는다.
- Q는 비선형에 `expf`, `powf`, `cosf`, `sinf`를 쓴다. newlib과 PC glibc의 결과가 다르면 Q의 hash가 다를 수 있다. 이때 FAIL이 나며, 원인이 libm인지(F의 hash도 같이 다를 것) 확인한 뒤 기준을 사용자와 정한다 [추정, 미확인].

## 6. Amdahl 추정식 [정의]
run P에서 판 하나에 대해, 위치 수 S, 범주 k의 누적 시간 T_k, 호출 수 N_k:

- token당 시간 t = sum_k T_k / S, 범주 비중 f_k = T_k / sum_j T_j.
- token당 호출 수 n_k = N_k / S. 1회 평균 t_k = T_k / N_k.
- probe 보정(선택): T_k' = T_k - N_k x c. c는 F, Q에서 `OVH lap`, H에서 `OVH hook_pair`/2 [추정]. 보정 전과 후를 함께 보고한다.

오프로드 집합 O(PL로 옮기는 범주들), 범주 k의 kernel 단독 가속비 s_k = t_k(ARM) / t_k(PL 순수 연산):

1. 이상적 추정(순수 연산만): S_ideal = 1 / ((1 - sum_{k in O} f_k) + sum_{k in O} f_k / s_k)
2. 비용 포함 추정: t' = t - sum_{k in O} n_k t_k + sum_{k in O} n_k (a_k + b_k + c_k), S_cost = t / t'.
   - a_k: PL 순수 연산 시간(PL 쪽 cycle counter)
   - b_k: 데이터 이동(입력 cache flush, DMA 또는 HP 전송 중 연산과 겹치지 않는 부분, 출력 invalidate)
   - c_k: 호출 오버헤드(AXI-Lite 레지스터 설정과 시작, 완료 대기 polling 또는 interrupt)
3. 실측: 오프로드 빌드의 run E. 표에는 1, 2, 3을 나란히 적는다(scope.md 측정 계획).

- 비중 f_k는 위치에 따라 변한다(attention은 길이 T에 비례, numeric.md 3.1절). 위 식의 f_k는 "고정 prompt, 위치 0..S-1 전체 평균"으로 정의한다. 위치별 추정이 필요하면 run T의 위치별 시간을 t(pos) = c0 + c1 x pos로 맞춰 c1을 attention 증가분으로 해석한다 [추정, kernel별 위치 분해는 재지 않음].
- 여러 kernel을 PL에서 연달아 실행해 중간 결과가 PL 안에 머무르면 b_k가 줄어든다. 이때는 kernel 묶음을 하나의 범주로 보고 같은 식을 쓴다.

## 7. 오프로드 때 분리해서 잴 항목과 baseline의 대응
| kernel 후보 (scope.md) | baseline 범주 (run P) | 오프로드 후 (a) 순수 연산 | (b) 데이터 이동 | (c) 호출 오버헤드 |
|---|---|---|---|---|
| GEMV 가속기형 | gemv_q..gemv_cls (행렬별) | PL cycle counter(첫 가중치 요청부터 마지막 결과까지) | 가중치 HP 읽기 중 연산과 겹치지 않는 부분, 입력 벡터 쓰기, 출력 읽기, cache 유지(`Xil_DCacheFlushRange`/`InvalidateRange`, 크기 비례) | AXI-Lite 설정(주소, 크기, scale), 시작, 완료 대기 |
| GEMV PIM형 | 같음 | bank MAC 명령 실행 cycle | 가중치 bank 적재(초기 1회, token당 시간과 분리해 보고), 벡터 방송, 결과 레지스터 읽기 | 명령 큐 쓰기, 완료 대기 |
| attention + softmax | attn(H는 q/k/v 양자화 actq 일부 포함 여부를 범주 정의와 맞춤) | head 단위 또는 layer 단위 cycle | K/V cache 위치(DDR이면 읽기 대역폭, BRAM이면 쓰기만) | 위치마다 head 수만큼 호출되면 c_k가 크다. 호출 단위를 layer로 묶을지 판단 근거 |
| rmsnorm | rmsnorm | | 벡터 길이 dim | |
| swiglu | swiglu | | 길이 hidden 두 벡터 | |
| argmax / top-k | argmax | | logits 전체(15M 32000개) | |
| ARM에 남는 것 | embed, rope, add, actq 일부, other | - | - | - |

- baseline의 H `other`(descriptor 구성과 glue)는 오프로드 뒤에도 ARM에 남는 드라이버 비용의 하한 참고값이다.
- 오프로드 빌드에서도 같은 프로그램 구조(E, T, P와 같은 키)를 써서 표를 그대로 비교한다. P의 범주는 오프로드된 kernel에 대해 (a)(b)(c)로 나뉜 하위 범주를 추가한다(예: `gemv_cls.pl`, `gemv_cls.mv`, `gemv_cls.call`) [계획].

## 8. 보고 형식
- 파서(`parse_log.py`) 표: 판별 token당 시간(E, T, P), 위치별 요약, kernel 범주별 호출 수/token, us/token, 비중, 정합성 표. `--csv`로 여러 빌드(-O2, -O3)를 한 CSV로 모은다.
- 문서에는 보드에서 측정한 값만 쓴다. 각 수치에 빌드(-O2/-O3, FPU 옵션), CPU 클럭(`CLK`에서 확인한 값), 위치 수를 함께 적는다.

## 9. 재지 않는 것과 한계
- 실행 간 편차: 프로그램은 각 실행을 한 번씩만 한다. 편차가 필요하면 보드에서 같은 ELF를 여러 번 실행해 로그를 모은다(파서가 파일 여러 개를 받는다).
- 두 번째 core, Linux 환경, DDR 클럭 변경, L2 prefetch 설정 변경은 범위 밖이다. L2 설정은 `PLAT l2c_ctrl`, `l2c_aux`로 기록만 한다.
- kernel별 위치 분해(위치마다 범주 시간)는 재지 않는다. 필요하면 P 실행을 위치 구간별로 나누는 옵션을 추가한다 [계획].
