# S0 서베이: 소형 LLM 추론의 C 참조 구현, 양자화, Zynq-7000 가속, DRAM PIM

- 작성일: 2026-11-18
- 범위: (1) 순수 C 소형 transformer와 checkpoint, (2) kernel별 연산 비중, (3) 정수 양자화, (4) 소형 FPGA의 transformer/LLM 가속과 PS-PL 데이터 이동, (5) DRAM PIM 구조와 FPGA 에뮬레이션, (6) Zybo Z7-20 자원 예산, (7) ARM 측정 방법
- 확인 표기: **[확인]** = 원문(소스 코드, 초록 페이지, HTML 본문, PDF 본문 중 하나)을 직접 열어 확인. **[재인용]** = 직접 연 다른 자료가 인용한 것만 확인(1차 원문 미열람). **[미확인]** = 검색 결과 요약으로만 접했고 원문을 열지 못함. 미확인 수치는 결정 근거로 쓰지 말 것.
- **[계산]** = 확인된 수치에서 이 문서가 직접 계산한 값. **[추정]** = 가정이 들어간 값(가정을 같이 적음). 측정값이 아니다.
- 출처 번호 [Sn]은 문서 끝 출처 목록을 가리킨다.

## 1. 요약

1. 순수 C로 추론 전체가 구현된 소형 공개 모델은 사실상 Karpathy의 `llama2.c`(코드 MIT)와 `tinyllamas` checkpoint(HF 저장소 MIT 표기) 조합이 표준이다. 크기는 260K / 15M / 42M / 110M 네 가지이며, 같은 `run.c`(float32)와 `runq.c`(int8 Q8_0)가 모두를 실행한다 [S1][S2][S3][S6].
2. `runq.c`의 int8은 matmul 가중치만 group-wise 대칭 int8(그룹당 float scale 1개)이고 활성값도 실행 중에 같은 방식으로 양자화한다. RMSNorm, softmax, SiLU, RoPE는 float32로 남는다. 즉 "정수 전용" 추론이 아니며, 비선형 함수의 고정소수점화는 이 프로젝트가 새로 해야 한다 [S2].
3. MAC 수로 보면 stories15M은 **분류기(32000 x 288)가 matmul의 60% 안팎**을 차지하고, stories260K는 vocab이 512라 분류기 비중이 작은 대신 **context가 길어지면 attention이 matmul을 넘어선다**(T=512에서 MAC의 약 56%) [계산]. 두 모델은 kernel 비중 구조가 정반대여서 Amdahl 비교 재료로 유용하다.
4. XC7Z020의 BRAM은 140 x 36 Kb(4.9 Mb), 데이터 비트만 세면 560 KiB다 [S16][계산]. stories260K의 int8 가중치(약 269 KiB)는 BRAM에 전부 들어가고, stories15M(약 16.3 MiB int8)은 30배 넘게 크다 [계산]. 즉 **"가중치를 bank(BRAM)에 상주시키는 PIM형"은 260K에서만 성립**하고, 15M은 DDR 스트리밍형이 필수다.
5. Zynq-7000 DDR3 x32 1066 MT/s의 이론 대역폭은 4,264 MB/s, Xilinx 튜토리얼의 HP 4포트 실측 합계는 3,254 MB/s(이론의 76%, ZC702)다 [S18]. stories15M int8 가중치를 매 토큰 DDR에서 읽으면 HP 1포트(64 bit x 150 MHz 가정, 1.2 GB/s)로 약 14 ms/token이 하한이다 [계산]. GEMV는 연산이 아니라 대역폭에 묶인다.
6. Cortex-A9에서 llama2.c를 돌린 공개 실측은 찾지 못했다. LlamaF(ZCU102, Cortex-A53, TinyLlama 1.1B)의 PS 단독 프로파일에서 matmul이 97.6~99.0%였다 [S13]. 작은 모델에서는 이 비중이 낮아질 수 있으므로 S3에서 직접 재야 한다.
7. Zynq-7000(XC7Z020)에서 LLM/GPT 디코더 전체를 가속한 동료 심사 논문은 찾지 못했다. 같은 칩의 가장 가까운 사례는 PYNQ-Z2의 int16 128-MAC matmul HLS 코어(41,429 LUT, 142 DSP, 학부 capstone)와 ViT softmax 근사 유닛(1,444 LUT, 77 DSP)이다 [S15][S32]. 이 공백은 이 프로젝트의 위치를 정하는 데 유리하다(성능 경쟁 아님, 측정 방법론 중심).
8. DRAM PIM 두 상용 계열은 구조가 공개되어 있다. Samsung HBM-PIM(Aquabolt-XL): bank 2개당 PIM unit 1개, 16-lane FP16 SIMD, 32-entry CRF에 미리 넣은 마이크로커널을 DRAM column 명령이 한 단계씩 진행 [S20]. SK hynix GDDR6-AiM: bank당 PU 1개(16 BF16 MAC), 2 KB global buffer가 벡터를 방송, `MACAB`/`WRGB`/`RDMAC` 같은 확장 DRAM 명령으로 호스트가 제어 [S19]. 이 프로젝트의 축소판은 AiM 쪽(bank당 MAC, 벡터 방송, 명령 기반)을 따르는 것이 자연스럽다.

## 2. 모델과 C 참조 구현 후보

### 2.1 llama2.c / tinyllamas 계열 구성

| 모델 | dim | n_layers | n_heads | n_kv_heads | hidden_dim | vocab | max context | params | val loss | 파일(fp32 .bin) | 확인 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| stories260K | 64 | 5 | 8 | 4 | 172 [계산] | 512 (custom `tok512`) | 512 | 260K | 1.297 | 1.06 MB | [확인] README 표 [S1], 260K readme [S9], HF 파일 크기 [S8] |
| stories15M | 288 | 6 | 6 | 6 | 768 [계산] | 32000 (Llama 2 tokenizer) | 256 | 15M | 1.072 | 60.8 MB | [확인] [S1][S7] |
| stories42M | 512 | 8 | 8 | 8 | 1376 [계산] | 32000 | 1024 | 42M | 0.847 | 167 MB | [확인] [S1][S7] |
| stories110M | 768 | 12 | 12 | 12 | 2048 [계산, HLSTransform의 `matmul_768_2048` 모듈 이름과 일치] | 32000 | 1024 | 110M | 0.760 | 438 MB | [확인] [S1][S7] |

- hidden_dim 계산: `model.py`의 `hidden_dim = 4*dim; int(2*hidden_dim/3); multiple_of 배수로 올림` [S5]. 260K는 readme의 `multiple_of: 4`로 170 -> 172. 15M과 42M은 `multiple_of=32`를 가정(학습 스크립트 기본값은 직접 확인하지 않음)해 768, 1376. 아래 parameter 합계가 HF 파일 크기와 일치하므로 이 값으로 본다 [계산].
  - 15M: 임베딩/분류기 공유 32000 x 288 = 9,216,000, layer당 4 x 288^2 + 3 x 288 x 768 = 995,328, 6 layer 5,971,968, 합 15,187,968(+norm, freq_cis) x 4 B = 약 60.8 MB.
  - 260K: kv_dim = 64 x 4/8 = 32. layer당 wq 4096 + wk 2048 + wv 2048 + wo 4096 + FFN 3 x 64 x 172 = 45,312, 5 layer 226,560, 임베딩 512 x 64 = 32,768, 합 259,328.
- 출력 분류기는 임베딩과 가중치를 공유한다(`self.tok_embeddings.weight = self.output.weight`) [S5].
- 260K는 2배 multi-query(GQA, kv head 4개) [S9]. 다른 셋은 MHA.

### 2.2 C 구현의 연산 순서 (`run.c`) [확인] [S3]

layer마다: RMSNorm -> `wq`(dim x dim), `wk`, `wv`(kv_dim x dim) matmul -> RoPE(`cosf`/`sinf`를 매번 계산) -> head별 QK score, `softmax(att, pos+1)`, V 가중합 -> `wo` matmul -> residual -> RMSNorm -> `w1`, `w3`(hidden x dim) -> SwiGLU(`val *= 1/(1+expf(-val))`, `*= w3 출력`) -> `w2`(dim x hidden) -> residual. 마지막에 RMSNorm과 분류기(vocab x dim). sampling은 temperature, argmax(t=0), top-p(기본 0.9). 체크포인트는 `mmap`으로 읽는다. 시간은 `clock_gettime(CLOCK_REALTIME)`로 재서 `achieved tok/s`를 출력한다.

- bare-metal 이식 시 걸리는 것: `mmap`, `clock_gettime`, OpenMP pragma, 파일 I/O. 모두 교체가 쉬운 부분이다(소스가 단일 파일) [추정].

### 2.3 int8 판 (`runq.c`, `export.py --version 2`) [확인] [S2][S4]

| 항목 | 내용 |
|---|---|
| 형식 | Q8_0(llama.cpp 용어). 대칭, 범위 [-127, 127], 그룹당 scale = max\|w\| / 127 (float32), `round()` 후 int8 |
| 그룹 크기 | `export.py` 기본 `group_size=64`, `dim`이 나누어떨어지지 않으면 절반씩 줄임. 파일 헤더(magic `0x616b3432`, version 2)에 기록 |
| int8 대상 | `wq wk wv wo w1 w2 w3`, 토큰 임베딩, 분류기(공유 시 같은 저장소) |
| float32 유지 | RMSNorm 가중치 3종, 임베딩 조회용 dequantized 사본 |
| matmul | 행마다 GS개씩 int8 x int8을 int32에 누적, 그룹 끝에서 float로 바꿔 (가중치 scale x 활성 scale) 곱해 float 합에 더함 |
| 활성 양자화 | 각 matmul 입력을 실행 중에 같은 GS로 양자화 |
| 비선형 | rmsnorm, softmax, SiLU, RoPE 모두 float32 |
| 보고된 효과 | Llama 2 7B: 26 GB -> 6.7 GB, 64 thread에서 4.6 -> 14 tok/s(약 3배) [S1]. 작은 tinyllamas에 대한 int8 정확도 보고는 README에 없다 |

- [계산] stories15M은 dim 288이 64로 나누어지지 않아 GS = 32가 된다. int8 가중치 15,187,968 B + scale 15,187,968/32 x 4 B = 1,898,496 B, 합 약 17.1 MB(16.3 MiB).
- [계산] stories260K는 GS = 64. 259,328 B + 16,208 B = 약 275.5 KB(269 KiB).
- **주의(미검증 의심)**: `export.py`의 GS 축소는 `dim`만 검사한다 [S4]. `runq.c` matmul은 입력 길이 n을 GS 단위로 나누는데, `w2`의 n = hidden_dim은 260K에서 172, 42M에서 1376으로 64의 배수가 아니다. 이 두 모델을 `runq.c`로 그대로 돌리면 `w2`의 그룹 경계가 맞지 않을 가능성이 있다. 코드 동작을 실행해 확인하지 않았다. S2에서 우리 int8 형식을 정할 때 GS를 dim과 hidden_dim의 공약수(260K: 4, 15M: 32)로 잡거나 행 단위 scale로 바꾸면 피할 수 있다.

### 2.4 그 외 C 후보

| 후보 | 내용 | 판단 | 확인 |
|---|---|---|---|
| `llm.c` (GPT-2 124M) | CPU fp32 참조 `train_gpt2.c` 약 1,000줄, MIT. 124,439,808 params, fp32와 bf16만, 양자화 없음 | fp32 약 500 MB, 1 GB DDR에 들어가긴 하나 A9에서 매우 느리고 BRAM PIM과 무관. 비추천 | [확인] [S11] |
| TinyStories-1M 등 GPT-Neo 계열 (roneneldan) | HF Transformers 모델 | C 구현이 없어 새로 써야 함. 구조와 라이선스를 모델 카드에서 확인하지 못함 | [확인] 모델 카드(구조 정보 없음) [S36] |
| llama.cpp / ggml | C/C++, stories 모델 변환 가능 | 코드 규모가 커서 golden으로 부적합 | 이 서베이에서 열어보지 않음 |
| ESP32-S3의 28.9M TinyStories (esp32-ai) | 240 MHz MCU에서 22.59 tok/s(int8/int4 SIMD) | 임베디드 속도 참고치. A9와 직접 비교 불가 | [확인] 2차 기사 [S37] |

### 2.5 라이선스와 재배포

| 대상 | 라이선스 | 재배포 판단 | 확인 |
|---|---|---|---|
| llama2.c 코드 (`run.c`, `runq.c`, `export.py`, `model.py`) | MIT | 가능(저작권 고지 유지) | [확인] [S1] |
| tinyllamas checkpoint (HF `karpathy/tinyllamas`) | HF 메타데이터 MIT | 가능. 다만 크기 때문에 15M(60.8 MB)은 다운로드 스크립트 + SHA-256만 둔다. 260K(1.06 MB)도 같은 방식 권장 | [확인] [S6] |
| `tok512` (260K용 custom tokenizer) | 같은 HF 저장소(MIT) | 가능 | [확인] 파일 존재 [S8] |
| Llama 2 tokenizer (`tokenizer.bin`, vocab 32000, 15M/42M/110M용) | Meta의 Llama 2 tokenizer에서 유래. 별도 라이선스 조항을 확인하지 못함 | **미확인**. 저장소에 넣지 말고 llama2.c 저장소에서 받게 한다 | [미확인] |
| TinyStories 데이터셋 | CDLA-Sharing-1.0, GPT-3.5/GPT-4 생성 | 프롬프트 몇 줄 인용은 문제 소지 작음. 대량 재배포는 하지 않는다 | [확인] [S10] |

### 2.6 ARM Cortex-A9 속도

- 공개 실측: Cortex-A9(Zynq-7000)에서 llama2.c 계열을 CPU만으로 돌린 수치는 **찾지 못했다**. 검색 요약에 PYNQ-Z1(Zynq-7000) + int8 systolic array로 17.7 tok/s라는 LinkedIn 게시물이 있었으나 원문을 열지 않았고 가속기 포함 수치다 [미확인]. Milk-V Duo(RISC-V)에서 stories15M 0.19~0.35 tok/s라는 포럼 글도 사이트 접속 실패로 미확인.
- 다른 플랫폼 참고: M1 MacBook Air에서 stories15M 약 110 tok/s [확인] [S1].
- [추정] stories15M fp32: 토큰당 matmul 약 15.2M MAC, 가중치 60.8 MB를 매번 읽는다. A9의 cached 읽기/복사가 0.6~1.0 GB/s 수준이라는 2차 수치[미확인]를 쓰면 메모리만으로 60~100 ms/token, 즉 **10~16 tok/s 이하**. int8(17.1 MB)이면 메모리 하한은 20~30 ms 수준이고 연산(int8 dot product, A9 NEON 처리율 미확인)이 지배할 수 있다. 실측 전에는 "1~20 tok/s 범위"로만 본다.
- [추정] stories260K: T=256에서 토큰당 약 0.42M MAC(4.1절). int8 가중치 269 KiB는 L2(512 KB) 안에 들어간다. MAC당 2 cycle을 가정하면 약 1.3 ms/token, 수백 tok/s. **baseline이 이렇게 빠르면 PL 호출 오버헤드(AXI-Lite 왕복, cache flush)가 kernel 시간과 같은 자릿수가 될 수 있다**. 이것이 Amdahl 추정과 실측이 갈라지는 지점이며 이 프로젝트의 측정 대상이다.

## 3. 연산 비중

### 3.1 보고된 수치

| 출처 | 모델 / 플랫폼 | 측정 | 결과 | 확인 |
|---|---|---|---|---|
| LlamaF, arXiv 2409.11424 | TinyLlama 1.1B, ZCU102 PS(Cortex-A53) 단독 | 위치 63/127/255 | matrix 계산 98.98% / 98.53% / 97.64%, MHA 0.47% / 0.92% / 1.82%, SwiGLU, RoPE, RMSNorm 각 0.15% 미만 | [확인] [S13] |
| HLSTransform, arXiv 2405.00738 | stories110M, VU9P(HLS 합성 추정치) | 모듈별 latency | forward 17.510 ms 중 `matmul_768_32000`(분류기) 3.457 ms(약 20%). 모듈 호출 횟수가 없어 비중 합계는 계산 불가 | [확인] [S12] |
| SK hynix HC34 포스터 | GPT 계열, CPU | 실행 시간 비중 | FC layer 등 AiM offload 가능 부분 96%, 나머지(softmax 등) 4% | [확인] 포스터 그림 [S19] |
| arXiv 2505.06461 | llama.cpp, 모바일 CPU | 연산자 프로파일 | MUL_MAT 87.6% | [미확인] 검색 요약 |

llama2.c 소형 모델(15M 이하)의 kernel별 시간 프로파일은 찾지 못했다.

### 3.2 MAC 수로 본 추정 [계산]

토큰 위치 T(=pos+1)에서 토큰 1개당. attention MAC = layer당 QK와 AV 각각 n_heads x head_size x T.

**stories15M** (layer matmul 5,971,968, 분류기 9,216,000, attention 3,456 x T)

| T | layer matmul | 분류기 | attention | 합계 MAC |
|---|---|---|---|---|
| 1 | 39.3% | 60.7% | 0.02% | 15.19M |
| 128 | 38.2% | 59.0% | 2.8% | 15.63M |
| 256 (최대) | 37.2% | 57.3% | 5.5% | 16.07M |

**stories260K** (layer matmul 226,560, 분류기 32,768, attention 640 x T)

| T | layer matmul | 분류기 | attention | 합계 MAC |
|---|---|---|---|---|
| 1 | 87.1% | 12.6% | 0.25% | 0.26M |
| 256 | 53.5% | 7.7% | 38.7% | 0.42M |
| 512 (최대) | 38.6% | 5.6% | 55.8% | 0.59M |

비선형 연산 개수(stories15M, T=256, 토큰당): softmax `expf` 6 head x 256 x 6 layer = 9,216, sampling softmax 32,000, SiLU `expf` 768 x 6 = 4,608, RMSNorm 13회(각 288원소, `sqrtf` 1회), RoPE `cosf/sinf` layer당 144쌍 x 6 [계산]. MAC 대비 개수는 작지만 `expf` 한 번이 수십 cycle이면 **vocab 32000의 sampling softmax와 top-p 정렬이 무시할 수 없는 비중**이 될 수 있다 [추정]. 260K는 vocab 512라 이 항목이 작다. 둘 다 S3 실측으로 확정한다.

## 4. 양자화

| 방식 | 핵심 | 정확도 보고 | HW 관련성 | 확인 |
|---|---|---|---|---|
| llama2.c Q8_0 (`runq.c`) | group-wise 대칭 int8, 그룹당 float scale, 활성도 동적 group 양자화, int32 그룹 누적 | 7B에서 속도 3배, 정확도 수치 없음 | GEMV 내부는 순수 int8 x int8 -> int32. 그룹 경계의 float scale 곱이 남는다 | [확인] [S1][S2] |
| HLSTransform | 110M을 Q8_0 방식 int8로 | perplexity 2.9667 -> 2.9679(+0.04%) | 같은 계열 모델에서의 int8 영향이 작다는 근거 | [확인] [S12] |
| LlamaF | W8A8, group size 256 | WikiText-2 ppl 7.05 -> 7.09(약 +0.57%), TinyLlama 1.1B | 그룹 GEMV를 PL에, 나머지 PS | [확인] [S13] |
| I-BERT (ICML 2021) | 정수 전용. i-GELU(2차 다항식 erf 근사, L2 0.0082, Linf 0.018 on [-4,4]), i-exp(x = -z ln2 + p 분해 후 2차 다항식 + shift, 최대 오차 1.9e-3), 정수 softmax, i-sqrt(정수 Newton, INT32에서 최대 4회). INT8 입력 + INT32 누적, 비선형은 INT32 후 INT8 재양자화, 정적 scale | RoBERTa-Base GLUE 평균 86.0 -> 86.3, Large 89.0 -> 89.5 | softmax, norm, 활성함수의 고정소수점 HW 근사 설계 기준으로 그대로 쓸 수 있다. SiLU = x * sigmoid(x)는 i-exp로 만들 수 있다 | [확인] [S27] |
| I-LLM (arXiv 2405.17849) | LLM 정수 전용, DI-ClippedSoftmax, DI-Exp, DI-Normalization(shift 기반) | W4A4에서 FP와 비슷하다고 주장. 동료 심사 학회 표기 없음 | RMSNorm/SiLU 정수화의 최근 사례 | [확인] 초록 [S30] |
| LLM.int8() (NeurIPS 2022) | vector-wise 양자화 + outlier 차원을 16-bit로 분리 | 175B까지 성능 저하 없음. outlier 출현 규모 임계값은 초록에서 확인하지 못함 | 소형 모델에서는 outlier 처리가 필요 없을 가능성이 크나 미검증 | [확인] 초록 [S28] |
| SmoothQuant (ICML 2023) | 활성의 양자화 난이도를 가중치로 옮기는 등가 변환, W8A8 | "negligible loss", 1.56배 속도, 메모리 2배 절감 | 활성 per-tensor 정적 scale이 필요할 때 참고 | [확인] 초록 [S29] |
| Softermax (DAC 2021) | base 교체, 저정밀 softmax, online normalization | 2.35배 에너지 효율, 0.90배 면적, 정확도 영향 미미 | softmax HW에서 max 선계산 패스를 없애는 online 방식 | [확인] 초록 [S31] |

### 비트폭 선택 근거 [계산 + 추정]

- DSP48E1은 18 x 25 signed 곱셈과 48-bit 누산기를 가진다 [확인] [S16]. int8 x int8 MAC 하나가 DSP 하나에 여유 있게 들어간다.
- 누산 폭: GS=32 그룹 하나의 최대 |합| = 32 x 127 x 127 = 516,128 < 2^20. 가장 긴 행(15M `w2`, n=768)을 그룹 없이 누적해도 768 x 16,129 = 12.4M < 2^24. **int32 누산이면 어떤 조합도 넘치지 않는다**.
- 그룹 scale: `runq.c`는 float scale을 쓴다. HW로 옮기면 그룹마다 float 곱이 생기므로, (a) 그룹 결과(int32)를 PS로 돌려 float로 처리, (b) scale을 고정소수점(예: 16-bit 가수 + shift)으로 바꿔 PL에서 처리, (c) 행 단위 scale로 그룹을 없애는 세 가지 선택지가 있다. 정확도 영향은 S2에서 C로 먼저 정량화한다.
- 비선형(softmax, RMSNorm, SiLU)은 I-BERT 방식 INT32 다항식 근사가 공개 근거가 가장 탄탄하다.

## 5. FPGA 선행 연구

### 5.1 소형/임베디드 FPGA의 transformer/LLM 가속

| 논문 | 디바이스 | 모델 / 정밀도 | 분할 | 자원 / 클럭 | 성능 | 확인 |
|---|---|---|---|---|---|---|
| LlamaF, arXiv 2409.11424 | ZCU102 (XCZU9EG, Cortex-A53, DDR4 4 GB) | TinyLlama 1.1B, W8A8 GS=256 | PL: group-wise 양자화 GEMV(kernel 2개). PS: 제어, KV cache, MHA(OpenMP) | LUT 59.72% / FF 31.31% / BRAM 24.45% / DSP 20.95%, 205 MHz (Vitis HLS 2022.2) | PS 단독 0.0928~0.0935 tok/s -> 1.328~1.478 tok/s (14.3~15.8배). GQMV 0.201 -> 4.696 GOPS. 비동기 스케줄로 55.6~57.9% 개선(가중치 전송과 연산 겹침). layer 단위 가중치 로딩으로 버퍼 111.5 MB | [확인] [S13] |
| Li et al., DATE 2025, arXiv 2502.10659 | KV260 (Zynq US+, DDR4 64-bit 2400 Mbps, 4 GB) | LLaMA2-7B 4-bit(약 3.5 GB) | bare-metal, 연산자 융합, 데이터 배치 | 미기재(초록) | 약 5 tok/s, 메모리 용량 93.3% 사용, 이론 대역폭의 약 85% 활용 | [확인] 초록 [S14] |
| HLSTransform, arXiv 2405.00738 | VU9P (AWS F1) | stories110M int8 | forward 전체 FPGA, 호스트는 토큰/위치 전달과 sampling | 200~300 MHz, 자원 미보고 | 57.11 tok/s (CPU 23.21, GPU 107.00), 토큰당 에너지 CPU 대비 12.75배 절감 | [확인] [S12] |
| WashU capstone 2026 (학부) | PYNQ-Z2 (XC7Z020) | 일반 matmul, int16 고정소수점(Q7.8), 48-bit 누산 | 128-MAC broadcast 배열, 256-bit AXI, double-buffered LUTRAM | 41,429 LUT (77%), 61,575 FF (57%), 142 DSP (64%), 34 BRAM_18K (12%) | 내부 루프 최고 약 5.1 GMAC/s. 종단 지연은 연산이 아니라 직렬화/통신이 지배(M3에서 타일당 통신 43%, 연산 41%) | [확인] PDF 본문 [S15] |
| Usman et al., arXiv 2607.01798 | Zynq-7020 | ViT softmax(16구간 PWL exp) | attention weighting 유닛만 | 1,444 LUT, 77 DSP, BRAM 0 | top-1 차이 0.20% 이내 | [확인] 초록 [S32] |
| FlexViT (Glasgow) | PYNQ-Z2 | ViT INT8 | FC/CONV 오프로드 | 미확인 | 오프로드 layer 1.77~2.74배, 종단 최대 1.40배 | [미확인] 검색 요약 |

### 5.2 PS-PL 데이터 이동

| 항목 | 내용 | 확인 |
|---|---|---|
| PS-PL 포트 | 2x AXI 32b master GP, 2x AXI 32b slave GP, **4x AXI 64/32b HP**, 1x AXI 64b ACP, 16 interrupt. PS DMA 8채널(4채널 PL 전용) | [확인] DS190 [S16] |
| DDR 이론 대역폭 | 1066 MT/s x 4 B = 4,264 MB/s | [확인] Xilinx SPA 튜토리얼 [S18] |
| HP 4포트 실측(ZC702) | 4포트 각 376 MB/s 요청 시 모두 달성, 합 1,510 MB/s(DDR의 35%). 4포트 x 읽기/쓰기 각 512 MB/s(합 4,096 MB/s, 이론의 95.9%) 요청 시 실측 3,254.4 MB/s(이론의 76%), DDR 컨트롤러 포화로 latency 증가 | [확인] [S18] |
| HP 포트 이론 | 64-bit x 150 MHz = 1,200 MB/s(방향당). 150 MHz는 2차 자료의 가정이고 UG585 표 본문은 열지 못함 | [미확인] UG585 표, 숫자는 [계산] |
| HP 포트와 DDR 포트 대응 | HP0/HP1이 DDR 포트 하나, HP2/HP3이 다른 하나를 공유 | [미확인] 검색 요약(UG585) |
| CPU cached 복사 | 약 620~978 MiB/s 수준의 2차 수치 | [미확인] |
| HP vs ACP | HEVC 연구: XC7Z045에서 HP 4포트 병렬 3,440 MiB/s @214 MHz, ACP 최대 159 MiB/s | [미확인] core.ac.uk 403 |
| PS-PL 전송 특성 연구 (UviDTE, IEEE TII 2021) | Zedboard, GP1 경유 CPU(memcpy, loop) vs PL330 DMAC, OS vs bare-metal, cache on/off, 2 B~2 MB. bare-metal에서 작은 크기는 CPU, 큰 크기는 DMAC가 유리. 32 kB(L1), 512 kB(L2) 넘으면 속도 저하. 절대 MB/s는 저장소의 xlsx에 있음(열지 않음) | [확인] README [S33] |

정리: 이 칩에서 transformer 가속의 병목이 연산이 아니라 데이터 이동이라는 점은 LlamaF(가중치 전송과 연산 겹침이 55~58% 개선), WashU(통신이 종단 지연 지배), Xilinx 튜토리얼(DDR 포화) 세 자료가 같은 방향을 가리킨다.

## 6. PIM

### 6.1 상용 DRAM PIM 구조

| 항목 | Samsung HBM-PIM (Aquabolt-XL, FIMDRAM) | SK hynix GDDR6-AiM |
|---|---|---|
| 연산기 배치 | bank 2개(even/odd)당 PIM unit 1개, bank I/O 경계에 삽입. pseudo-channel당 bank 16개, PIM unit 8개. HBM 스택 8 die 중 4 die가 PIM die [S20] | bank당 PU 1개, die당 16 PU, 칩당 32 PU(2 채널) [S19] |
| 연산 폭과 형식 | 16-lane FP16 SIMD(lane마다 곱셈기+덧셈기, 5단 파이프라인). FP16만 지원, cross-lane reduction 명령 없음 [S20] | 16 BF16 MAC(DRAM column 1회 32 B와 대응), 결과는 `MAC_REG` [S19] |
| 레지스터/버퍼 | CRF 32 x 32 bit, GRF 256-bit x 16(GRF_A/GRF_B), SRF 2 x 8 [S20] | 채널당 2 KB global buffer(벡터 방송), `MAC_REG`, `AF_REG` [S19] |
| 명령 방식 | 모드 3개: SB(일반), AB(한 column 명령이 모든 bank의 같은 행/열), AB-PIM(column 명령마다 CRF 마이크로커널의 PC가 한 단계 진행, lock-step). 모드 전환은 예약 주소 영역에 대한 정해진 DRAM 명령 패턴. JEDEC 컨트롤러 무수정 호환 [S20] | 확장 DRAM 명령: `ACT4/ACT16`, `MACSB/MAC4B/MACAB`(1/4/16 bank MAC), `AF`, `EWMUL`, `RDCP/WRCP`, `WRGB`(GB에 벡터 쓰기), `RDMAC`, `RDAF`, `WRMAC/WRBIAS`, `WRBK`. 일부는 mode register 설정 필요 [S19] |
| ISA | ADD, MUL, MAD, MAC / MOV, FILL / NOP, JUMP(zero-cycle, 고정 반복), EXIT. 32-bit 고정 명령 [S20][S21] | 호스트 측 ISR 명령(256-bit 패킷, 예: `ISR_MAC_ABK` opcode 0x0C, OPSIZE, CH_MASK, BK, ROW, COL)이 FPGA의 AiM DMA에서 저수준 AiM 명령열로 풀림. `ISR_MAC_ABK` 1개 -> `MAC_ABK` 64개 [S19] |
| 활성함수 | MOV 중 ReLU 정도 [S20] | LUT + 선형 보간(sigmoid, tanh, GELU, ReLU, Leaky ReLU) [S19] |
| 클럭/처리율 | DRAM core 클럭 250~300 MHz [S20] | 1 GHz, 칩당 1 TFLOPS, I/O 16 Gb/s/pin, 64 GB/s [S19](ISSCC 2022 논문 수치를 포스터가 인용: [재인용]) |
| 호스트 역할 | 데이터 배치(행을 even bank에 분산, 열 우선), 마이크로커널을 AB 모드로 CRF에 방송, AB-PIM에서 column 명령 발행 [S20] | 런타임이 행렬을 재배치해 AiM에 저장, ISR 명령열 생성, softmax/norm 등은 CPU. 타일링은 column-major(벡터를 GB에 유지)와 row-major(부분합을 MAC_REG에 유지) 두 방식 [S19] |
| 보고된 효과 | ISCA 2021: 메모리 바운드 NN kernel 11.2배, 응용 3.5배, 비트당 에너지 3.5배 절감, 시스템 에너지 효율 3.2배 [S22]. AME-PIM: 실제 Aquabolt-XL pseudo-channel 하나에서 14.9 GFLOP/s(59.4 FLOP/cycle) [S20] | GPT-3 13B 구성 FC: CPU FP32 대비 실측 6.73배(4 채널 @2 Gb/s/pin, PCIe 경유), 16 Gb/s/pin 투영 16.64~18.05배. 분석 모델이 실측과 5% 이내 [S19] |
| 확인 | [확인] AME-PIM 본문, PIMSimulator README, ISCA 초록 | [확인] HC34 포스터 본문 |

### 6.2 LLM과 PIM

| 연구 | 내용 | 확인 |
|---|---|---|
| NeuPIMs (ASPLOS 2024) | 배치 추론에서 QKV/FFN은 GEMM(NPU), attention은 GEMV(PIM). bank에 row buffer 2개를 둬 NPU와 PIM 동시 동작. GPU 단독 대비 3배, NPU 단독 2.4배, 단순 NPU+PIM 1.6배 | [확인] 초록 [S23] |
| PIM-GPT (arXiv 2310.09385) | DRAM PIM이 MAC, ASIC이 비선형과 통신. GPT 8종(최대 1.4B), GPU 대비 41~137배 | [확인] 초록 [S26] |
| AttAcc (ASPLOS 2024) | attention 전용 PIM + xPU 이종 시스템 | 서지만 [미확인], 수치 미확인 |
| AiM (HC34) | GPT 계열에서 offload 가능 부분 96% | [확인] [S19] |

공통점: 배치 1 디코딩의 GEMV는 가중치 재사용이 없어 대역폭이 전부이고, PIM은 bank 내부 대역폭으로 이를 푼다. 비선형(softmax, norm)은 호스트나 별도 로직에 남긴다. 이 프로젝트의 HW/SW 분할 초안과 일치한다.

### 6.3 FPGA로 PIM을 에뮬레이션한 연구

| 연구 | 내용 | 확인 |
|---|---|---|
| PiMulator (DATE 2022, UVA) | SystemVerilog soft PiM 모델(공유 데이터 버스, row buffer, subarray, bank 상태, refresh, interleaving), LiteX/RISC-V 호환. Alveo U280에서 BRAM 100%, FF/LUT 1% 사용. 시뮬레이션 대비 28배. 주로 bitwise PiM | [확인] 초록 [S24] |
| AiM FPGA 플랫폼 (SK hynix) | VCU118 + AiM FMC 카드 2장. AiM 컨트롤러(FR-FCFS + AiM 엔진 + refresh), multicasting interconnect(unicast/multicast/broadcast), 512 KB GPR SRAM, ISR FSM이 FPGA 안에 있음 | [확인] [S19] |
| IMAGine (FPL 2024) | BRAM을 PIM 타일로 쓰는 GEMV overlay, bit-serial MAC, BRAM 최대 클럭으로 동작. Alveo U55에서 737 MHz, 64K bit-serial MAC. 기존 FPGA PIM GEMV 대비 2.65~3.2배 클럭 | [확인] PDF 초록 [S25] |
| PIMSimulator (Samsung SAIT) | DRAMSim2 기반 HBM2-PIM 시뮬레이터. GEMV, add, mul, relu | [확인] README [S21] |

### 6.4 BRAM bank + MAC으로 축소할 때 따를 것과 단순화할 것 (S1 결정 재료)

| 원형의 요소 | 따른다 | 단순화/생략 | 근거 |
|---|---|---|---|
| bank 옆 연산기, bank 내부 대역폭 활용 | BRAM bank마다(또는 bank 묶음마다) int8 MAC lane | DRAM timing(ACT/PRE/refresh), row buffer는 없음. BRAM은 1 cycle 읽기 | BRAM은 DRAM이 아니며 timing 모델은 연구 대상 밖. PiMulator처럼 timing을 넣는 것은 선택 사항 |
| 벡터 방송(AiM global buffer, HBM-PIM의 bank->GRF broadcast) | 입력 활성 벡터를 global buffer에 한 번 쓰고 모든 bank에 방송 | | 호스트 개입 횟수 비교 지표의 핵심 |
| all-bank 명령(`MACAB`, AB-PIM) | 명령 1개로 전 bank 동시 MAC | 4-bank/single-bank 변형은 선택 | 명령 수 = 호스트 개입 횟수 |
| 명령 기반 제어(AiM ISR -> 저수준 명령, HBM-PIM CRF 마이크로커널) | AXI-Lite 또는 명령 FIFO로 고수준 명령(`WRGB`, `MAC_ALL`, `RDMAC` 유사)을 받아 컨트롤러 FSM이 펼침 | CRF 프로그래밍(마이크로커널)은 생략 가능. 고정 GEMV 명령만 | brief의 "명령 컨트롤러와 bank wrapper는 RTL" |
| 결과 레지스터(`MAC_REG`) | bank별 int32 누산 레지스터와 읽기 명령 | 활성함수 LUT(`AF_REG`)는 2단계 확장 후보 | 비선형은 PS 또는 별도 IP |
| 숫자 형식 FP16/BF16 | | int8 x int8 -> int32로 바꿈 | DSP48E1과 BRAM 용량에 맞춤. 원형과 다르다는 점을 문서에 명시 |
| 데이터 배치(행을 bank에 분산, column/row-major 타일링) | 행렬 행을 bank에 interleave, 두 타일링을 파라미터로 | | AiM 포스터가 두 방식의 성능 차이를 언급 |
| 메모리 용량(Gb 단위) | | BRAM 560 KiB로 축소 -> 260K 모델만 전부 상주 | 2.6절, 7절 계산 |

## 7. Zybo Z7-20 자원 예산

### 7.1 공식 수치

| 항목 | 값 | 확인 |
|---|---|---|
| 디바이스 | XC7Z020 (Zybo Z7-20, -1 speed grade, CLG400) | 보드 사양은 CLAUDE.md 기준 |
| Logic cells / LUT / FF | 85K / 53,200 / 106,400 | [확인] DS190 v1.11.1 Table 1 [S16] |
| Block RAM | 4.9 Mb (36 Kb x 140) | [확인] [S16] |
| DSP | 220 (DSP48E1: 18 x 25 곱셈, 48-bit 누산, 25-bit pre-adder), peak 276 GMACs(대칭 FIR 기준) | [확인] [S16] |
| CPU | 듀얼 Cortex-A9, -1에서 최대 667 MHz, NEON + 단/배정밀 VFP | [확인] [S16], Zybo RM "667 MHz dual-core" [S17] |
| 캐시 / OCM | L1 32 KB I + 32 KB D (CPU당), L2 512 KB 공유, OCM 256 KB | [확인] [S16] |
| DDR | 1 GiB DDR3L, 32-bit, MT41K256M16HA-125 x 2, 최대 533 MHz / 1066 Mbps | [확인] Zybo Z7 RM rev B [S17] |
| PS-PL 포트 | 4 HP(64/32b), 1 ACP(64b), 2+2 GP(32b) | [확인] [S16] |

### 7.2 BRAM에 들어가는 양 [계산]

BRAM 데이터 비트 기준 36 Kb 블록 = 32 Kb 데이터 + 4 Kb parity -> 4,096 B/블록, 140블록 = 573,440 B(560 KiB). parity 비트까지 쓰면(x9 폭) 645,120 B.

| 대상 | 크기 | BRAM36 블록(4 KiB 기준, 꽉 채운다고 가정) | 판단 |
|---|---|---|---|
| stories260K int8 가중치 + GS64 scale | 약 269 KiB | 약 68 (49%) | 상주 가능. bank 분할 손실 감안해도 여유 |
| stories260K int16/FP16 가중치 | 약 507 KiB | 약 127 (91%) | 사실상 불가(버퍼 공간 없음) |
| stories260K KV cache (5 layer x K,V x 512 x 32) | fp32 640 KiB, int8 160 KiB | int8 40 | int8 KV를 BRAM에 둘 수 있으나 가중치와 합치면 빡빡함. KV는 DDR/PS 쪽이 현실적 |
| stories15M int8 가중치 전체 | 약 16.3 MiB | 약 4,170 | 불가(30배 초과) |
| stories15M layer 1개(int8) | 972 KiB | 243 | 불가 |
| stories15M 행렬 1개: `wq` 288x288 / `w1` 768x288 / 분류기 32000x288 | 81 KiB / 216 KiB / 8.8 MiB | 21 / 54 / 2,250 | 단일 행렬 일부만 상주 가능. 분류기는 불가 |

### 7.3 DDR 스트리밍 GEMV의 대역폭 한계 [계산]

| 경우 | 토큰당 가중치 바이트 | HP 1포트 1.2 GB/s (64b@150 MHz 가정) | HP 4포트 실측 합 3.25 GB/s (ZC702) | DDR 이론 4.26 GB/s |
|---|---|---|---|---|
| stories15M int8 | 17.1 MB | 14.2 ms (70 tok/s 상한) | 5.3 ms (190 tok/s) | 4.0 ms |
| stories15M fp32 | 60.8 MB | 50.7 ms | 18.7 ms | 14.3 ms |
| stories260K int8 | 0.28 MB | 0.23 ms | 0.08 ms | 0.06 ms |

- int8 GEMV는 가중치 1 B당 MAC 1회이므로 1.2 GB/s는 1.2 GMAC/s다. 150 MHz에서 **MAC lane 8개면 HP 1포트를 다 쓴다**. DSP 220개 중 대부분은 DDR 스트리밍형에서 놀게 된다.
- PIM형(BRAM 상주)의 내부 대역폭: 140블록 x 2포트 x 64 bit = 2,240 B/cycle, 150 MHz에서 336 GB/s. HP 1포트의 약 280배. 이 경우 한계는 DSP 수(220 MAC/cycle, 150 MHz에서 33 GMAC/s)다. 두 구조의 차이를 "데이터 이동량"과 "자원"으로 비교하는 brief의 목표에 맞는 구도다.
- 실제 Zybo의 HP 실측과 PL 동작 클럭은 S6에서 사용자가 측정한다. 150 MHz는 가정이다.

## 8. 측정 방법 (ARM)

| 방법 | 내용 | 확인 |
|---|---|---|
| Global timer (`XTime_GetTime`) | 64-bit global counter, `COUNTS_PER_SECOND = CPU 클럭 / 2`(667 MHz면 333.3 MHz). 두 코어 공용이라 구간 측정의 기본 | [확인] Xilinx `xtime_l.h` [S34] |
| PMU cycle counter | `Xpm_ReadCycleCounterVal()`(CP15 cycle counter). event counter 6개, `XPM_EVENT_CLOCKCYCLES`(0x11), `XPM_EVENT_DATA_CACHEREFILL`(0x03), `XPM_EVENT_DATA_CACHEACCESS`(0x04) 등. 파일 주석: cycle counter는 시간 측정용이라 이 API가 다루지 않음 | [확인] `xpm_counter.h` [S35] |
| cache 유지 비용 | `Xil_DCacheFlushRange`는 32 B line마다 L1 clean+invalidate, 이어서 line마다 L2(PL310) clean+invalidate와 `Xil_L2CacheSync()`. `Xil_DCacheInvalidateRange`는 정렬 안 된 양끝 line을 먼저 flush. **비용이 크기에 비례**하므로 오프로드 오버헤드 측정 항목으로 분리해야 한다 | [확인] `xil_cache.c` [S36b] |
| Linux에서의 cache 비용 | `dma_sync_single_for_cpu`가 느려 HP 600 MB/s의 절반 정도로 떨어졌다는 보고 | [미확인] 메일링 리스트 검색 요약 |
| llama2.c 내장 측정 | `clock_gettime` 기반 tok/s 출력 [S3]. bare-metal에서는 global timer로 교체 | [확인] |

### 측정 설계 권장 [추정, S3에서 확정]

- kernel 경계마다 global timer로 시작/끝을 재고, kernel별 누적 cycle과 호출 횟수를 표로 남긴다. 한 토큰 시간 = kernel 합 + 기타로 닫히는지 확인한다.
- 오프로드 1회의 시간을 (a) 입력 cache flush, (b) 레지스터 설정/시작(AXI-Lite), (c) PL 실행(PL 쪽 cycle counter로 별도 측정), (d) 완료 대기(polling/interrupt), (e) 출력 invalidate로 나눠 잰다. Amdahl 추정은 (c)만 쓴 값과 (a)~(e) 전체를 쓴 값을 둘 다 계산해 실측 end-to-end와 비교한다.
- Amdahl: 전체 가속 = 1 / ((1 - f) + f / s). f는 ARM 프로파일의 kernel 비중, s는 kernel 단독 가속비. 비중 f가 위치 T에 따라 변하므로(3.2절) 생성 길이를 고정한 평균으로 정의한다.
- bare-metal에서 한 코어만 쓴다(llama2.c의 OpenMP 제거). 두 번째 코어 사용은 별도 실험.

## 9. S1 결정을 위한 선택지

### 9.1 모델 후보

| 후보 | 장점 | 단점 |
|---|---|---|
| **A. stories260K** (dim 64, 5 layer, vocab 512, ctx 512) | int8 가중치 269 KiB가 BRAM에 전부 상주해 PIM형이 원형 그대로 성립. tokenizer도 MIT 저장소의 `tok512`. 행렬이 작아(최대 172 x 64, 64 x 172, 512 x 64) RTL 시뮬레이션이 빠르고 exhaustive에 가까운 검증 가능. 긴 context에서 attention 비중이 커서(최대 56%) attention/softmax IP의 의미가 큼 | 출력 품질이 낮음(val loss 1.297). ARM baseline이 매우 빨라(추정 ms 이하/token) 오프로드 오버헤드가 kernel 시간을 압도할 위험. `runq.c`의 `w2` 그룹 경계 의심(2.3절) |
| **B. stories15M** (dim 288, 6 layer, vocab 32000, ctx 256) | 가장 많이 쓰이는 llama2.c 기준 모델, 비교 자료가 많음. 가중치가 DDR에 있어야 하므로 DDR 스트리밍 GEMV와 AXI HP 병목을 현실적으로 다룸. baseline이 수~수십 ms/token(추정)이라 가속 효과를 재기 좋음. GS=32로 `runq.c` 그룹 경계 문제 없음 | BRAM에 layer 하나도 안 들어가 PIM형은 "타일을 BRAM에 올려 두고 재사용"하는 변형이 되어 원형과 거리가 생김. 분류기(32000 x 288)가 MAC의 약 60%. Llama 2 tokenizer 라이선스 미확인 |
| C. stories42M 이상 / llm.c GPT-2 124M | 품질 높음 | int8도 40 MB 이상, BRAM PIM과 무관, A9에서 느림. `runq.c` 그룹 경계 의심(42M). brief 범위(15M 이하) 밖 |

### 9.2 권장안

**한 C 코드베이스(llama2.c 구조, config로 크기 선택)로 A와 B를 모두 지원하고, IP 개발과 PIM형 비교는 A(260K), DDR 스트리밍형과 end-to-end 측정의 주 대상은 B(15M)로 한다.**

근거:
1. 두 모델은 구조가 같아(llama2 아키텍처, 같은 연산 순서) C golden과 kernel IP를 공유한다. 크기만 parameter다.
2. brief의 핵심 비교인 "가속기형(DDR 스트림) 대 PIM형(bank 상주)"은 가중치가 BRAM에 다 들어가는 모델이 있어야 공정하다. 그것이 260K뿐이다(7.2절).
3. Amdahl 추정과 실측 차이 분석은 baseline이 충분히 느리고 kernel 비중 구조가 다른 두 점이 있을 때 설득력이 있다. 15M(분류기 지배, DDR 병목)과 260K(attention 비중 큼, 오버헤드 지배)가 대조적이다(3.2절).
4. 라이선스: 260K + `tok512`는 MIT 저장소만으로 닫힌다. 15M은 Llama 2 tokenizer 라이선스를 S1에서 확인하고, 저장소에는 다운로드 스크립트와 체크섬만 둔다.

S1에서 정할 형식 초안: 가중치 int8 대칭, 그룹 크기는 dim과 hidden_dim의 공약수(260K: 4 또는 행 단위, 15M: 32), 활성 int8, 누산 int32, 그룹 scale은 고정소수점(가수 + shift)으로 PL 처리 여부를 S2 정확도 결과로 결정. 비선형은 I-BERT 방식 정수 근사를 C에서 먼저 평가.

kernel 목록 초안: (1) GEMV 가속기형(DDR, AXI HP), (2) GEMV PIM형(BRAM bank + 명령 컨트롤러), (3) attention score + softmax, (4) RMSNorm, (5) SiLU/SwiGLU, (6) 분류기 후처리(argmax/top-k). 우선순위는 S3 프로파일로 정한다.

### 9.3 가장 큰 위험 3개

1. **오프로드 오버헤드가 kernel 이득을 삼킴**: 260K는 행렬이 작아 GEMV 1회가 수천 MAC이고, A9 baseline이 이미 빠를 수 있다(추정). AXI-Lite 왕복, `Xil_DCacheFlushRange`의 line 단위 L2 sync, polling이 kernel 시간보다 클 수 있다. 대응: layer 또는 토큰 단위로 명령을 묶는 PIM 명령 큐, 측정 항목 (a)~(e) 분리. 이 현상 자체를 결과로 보고하는 것도 연구 목표에 맞다.
2. **DDR 대역폭과 HP 포트 실측이 계산보다 낮음**: 15M의 DDR 스트리밍 GEMV는 대역폭에 묶이고(7.3절), Zybo의 HP 실측 수치는 아직 없다(ZC702 튜토리얼 값과 150 MHz 가정에 의존). PS의 동시 DDR 접근(KV cache, 활성)과 경쟁하면 더 떨어진다. 대응: S5에서 HP 대역폭 측정용 단순 DMA 빌드를 먼저 사용자에게 돌려 받는다.
3. **int8 정확도와 비선형 고정소수점의 오차 전파**: 소형 tinyllamas의 int8 정확도 공개 보고가 없다(110M +0.04%, 1.1B +0.57%만 확인). 260K는 dim이 작아 그룹당 원소가 적고 오차에 민감할 수 있다. `runq.c`의 그룹 경계 의심도 있다. 대응: S2에서 float 대 int8 대 정수 비선형의 logits 차이, top-1 일치율, perplexity를 C로 먼저 정량화하고, 기준을 통과한 형식만 HW로 옮긴다.

## 10. 조사하지 못한 것

- Cortex-A9(Zynq-7000)에서 llama2.c의 실측 tok/s와 kernel별 프로파일: 공개 자료 없음. S3에서 직접 측정.
- UG585의 Theoretical Bandwidth 표(HP 포트 최대 클럭, 포트별 대역폭): 페이지가 너무 커서 표 부분을 읽지 못함.
- Zybo Z7-20에서의 HP 포트 실측 대역폭.
- Cortex-A9 NEON의 int8 dot product 처리율(cycle당 MAC 수): 공식 자료를 열지 않음.
- Llama 2 tokenizer(`tokenizer.bin`)의 재배포 조건.
- Samsung ISSCC 2021 FIMDRAM, SK hynix ISSCC 2022 AiM 논문 본문(유료). 구조는 AME-PIM 본문과 HC34 포스터로 대신 확인.
- AttAcc, IANUS 본문 수치, FlexViT 수치, HEVC 연구의 HP/ACP 실측(403).
- UviDTE 측정 저장소의 절대 MB/s 값(xlsx).
- tinyllamas 학습 스크립트의 `multiple_of` 기본값(15M, 42M hidden_dim은 파일 크기 일치로 역산).

## 11. 출처

| 번호 | 출처 | URL | 상태 |
|---|---|---|---|
| S1 | karpathy/llama2.c README | https://github.com/karpathy/llama2.c | [확인] |
| S2 | llama2.c `runq.c` | https://raw.githubusercontent.com/karpathy/llama2.c/master/runq.c | [확인] |
| S3 | llama2.c `run.c` | https://raw.githubusercontent.com/karpathy/llama2.c/master/run.c | [확인] |
| S4 | llama2.c `export.py` | https://raw.githubusercontent.com/karpathy/llama2.c/master/export.py | [확인] |
| S5 | llama2.c `model.py` | https://raw.githubusercontent.com/karpathy/llama2.c/master/model.py | [확인] |
| S6 | HF karpathy/tinyllamas 모델 카드(MIT) | https://huggingface.co/karpathy/tinyllamas | [확인] |
| S7 | HF tinyllamas 파일 목록 | https://huggingface.co/karpathy/tinyllamas/tree/main | [확인] |
| S8 | HF stories260K 파일 목록 | https://huggingface.co/karpathy/tinyllamas/tree/main/stories260K | [확인] |
| S9 | stories260K readme | https://huggingface.co/karpathy/tinyllamas/blob/main/stories260K/readme.md | [확인] |
| S10 | HF roneneldan/TinyStories 데이터셋 | https://huggingface.co/datasets/roneneldan/TinyStories | [확인] |
| S11 | karpathy/llm.c README | https://github.com/karpathy/llm.c | [확인] |
| S12 | HLSTransform, arXiv 2405.00738 | https://arxiv.org/html/2405.00738v1 | [확인] |
| S13 | LlamaF, arXiv 2409.11424 | https://arxiv.org/html/2409.11424v1 | [확인] |
| S14 | Li et al., DATE 2025, arXiv 2502.10659 | https://arxiv.org/abs/2502.10659 | [확인] 초록 |
| S15 | WashU CSE 4602 capstone, FPGA-Accelerated Matrix Multiplication (PYNQ-Z2), 2026 | https://ese.washu.edu/documents/report-sp26-fpga-matrix-multiplication.pdf | [확인] PDF 본문 |
| S16 | Xilinx DS190 v1.11.1 Zynq-7000 SoC Data Sheet: Overview (2018-07-02) | https://ranger.uta.edu/~jlosh/Xilinx/Zynq-7000_SoC_Overview.pdf (사본) | [확인] PDF 본문 |
| S17 | Digilent Zybo Z7 Board Reference Manual rev B (2018-02-21) | https://www.secs.oakland.edu/~llamocca/Courses/ECE5736/ZYBO_Z7/zybo-z7_rm.pdf (사본; 원본 digilent.com은 403) | [확인] PDF 본문 |
| S18 | Xilinx SPA tutorial, Evaluating High-Performance Ports | https://xilinx.github.io/Embedded-Design-Tutorials/docs/2020.2/build/html/docs/SPA-UG/docs/6-evaluating-high-performance-ports.html | [확인] |
| S19 | Kwon et al., System Architecture and Software Stack for GDDR6-AiM, Hot Chips 34 포스터 | https://hc34.hotchips.org/assets/program/posters/hc34.SKhynix.YongkeeKwon.v03.pdf | [확인] PDF 본문 |
| S20 | Venieri et al., AME-PIM, CF 2026, arXiv 2604.27808 (Aquabolt-XL 배경 절) | https://arxiv.org/pdf/2604.27808 | [확인] PDF 본문 |
| S21 | SAITPublic/PIMSimulator README | https://github.com/SAITPublic/PIMSimulator | [확인] |
| S22 | Lee et al., ISCA 2021 HBM-PIM 초록 (Semiconductor Engineering 게재본) | https://semiengineering.com/hardware-architecture-and-software-stack-for-pim-based-on-commercial-dram-technology | [확인] 초록 |
| S23 | NeuPIMs, arXiv 2403.00579 | https://arxiv.org/abs/2403.00579 | [확인] 초록 |
| S24 | PiMulator, DATE 2022 | https://past.date-conference.com/proceedings-archive/2022/html/0038.html | [확인] 초록 |
| S25 | IMAGine, FPL 2024 | https://cse.sc.edu/~jbakos/assets/papers/fpl24_paper.pdf | [확인] PDF 초록과 서론 |
| S26 | PIM-GPT, arXiv 2310.09385 | https://arxiv.org/abs/2310.09385 | [확인] 초록 |
| S27 | I-BERT, ICML 2021, arXiv 2101.01321 | https://arxiv.org/html/2101.01321 | [확인] 본문 |
| S28 | LLM.int8(), arXiv 2208.07339 | https://arxiv.org/abs/2208.07339 | [확인] 초록 |
| S29 | SmoothQuant, arXiv 2211.10438 | https://arxiv.org/abs/2211.10438 | [확인] 초록 |
| S30 | I-LLM, arXiv 2405.17849 | https://arxiv.org/abs/2405.17849 | [확인] 초록 |
| S31 | Softermax, DAC 2021, arXiv 2103.09301 | https://arxiv.org/abs/2103.09301 | [확인] 초록 |
| S32 | Usman et al., Approximate Attention Weighting (Zynq-7020), arXiv 2607.01798 | https://arxiv.org/abs/2607.01798 | [확인] 초록 |
| S33 | UviDTE-FPSoC/Zynq7000-time-measurements README (IEEE TII 2021 보조 자료) | https://github.com/UviDTE-FPSoC/Zynq7000-time-measurements | [확인] |
| S34 | Xilinx embeddedsw `xtime_l.h` (Cortex-A9) | https://raw.githubusercontent.com/Xilinx/embeddedsw/master/lib/bsp/standalone/src/arm/cortexa9/xtime_l.h | [확인] |
| S35 | Xilinx embeddedsw `xpm_counter.h` | https://raw.githubusercontent.com/Xilinx/embeddedsw/master/lib/bsp/standalone/src/arm/cortexa9/xpm_counter.h | [확인] |
| S36b | Xilinx embeddedsw `xil_cache.c` | https://raw.githubusercontent.com/Xilinx/embeddedsw/master/lib/bsp/standalone/src/arm/cortexa9/xil_cache.c | [확인] |
| S36 | HF roneneldan/TinyStories-1M 모델 카드 | https://huggingface.co/roneneldan/TinyStories-1M | [확인] (구조 정보 없음) |
| S37 | InsiderLLM, LLM on a Microcontroller: ESP32-S3 at 22.6 tok/s | https://insiderllm.com/guides/llm-on-microcontroller-esp32-s3/ | [확인] 2차 기사 |
| U1 | PYNQ-Z1 int8 systolic array 17.7 tok/s (LinkedIn) | https://tw.linkedin.com/in/jhlee1224 | [미확인] |
| U2 | Milk-V Duo stories15M 0.19~0.35 tok/s | https://forum.sophgo.com/t/milk-v-duo-achieves-baby-llama-2-at-0-5-tok-s/357 | [미확인] 접속 실패 |
| U3 | llama.cpp 모바일 프로파일 MUL_MAT 87.6%, arXiv 2505.06461 | https://arxiv.org/pdf/2505.06461v1 | [미확인] |
| U4 | HEVC MC 연구, Zynq HP 4포트 3,440 MiB/s, ACP 159 MiB/s, cached SW 978 MiB/s | https://core.ac.uk/download/80494064.pdf | [미확인] 403 |
| U5 | Zynq memcpy 620~720 MB/s (Stack Overflow) | https://kiwix.lema.org/stackoverflow.com_en_all_2023-11/questions/34888683/arm-neon-memcpy-optimized-for-uncached-memory | [미확인] |
| U6 | Linux `dma_sync_single_for_cpu` 비용 | https://lists.infradead.org/pipermail/linux-arm-kernel/2015-June/352877.html | [미확인] |
| U7 | UG585 Theoretical Bandwidth, HP0/1와 HP2/3의 DDR 포트 공유 | https://docs.amd.com/r/en-US/ug585-zynq-7000-SoC-TRM/Theoretical-Bandwidth | [미확인] 표 본문 미열람 |
| U8 | FlexViT (PYNQ-Z2) | https://eprints.gla.ac.uk/388568/1/388568.pdf | [미확인] |
| U9 | AttAcc, ASPLOS 2024, DOI 10.1145/3620665.3640422 | https://www.bibsonomy.org/bibtex/1abd4413d521c206bbe60dc96386d8550 | [미확인] |
| U10 | Aquabolt-XL Hot Chips 33 (Alveo U280 2.5~2.9배 등) | https://www.servethehome.com/samsung-hbm2-pim-and-aquabolt-xl-at-hot-chips-33/ | [미확인] |
