# S1 범위 결정: llm-pim-soc

상태: 결정 (2026-11-18, 오케스트레이터). 사용자 검토 대상. 근거는 `docs/survey/survey.md` 9절. 숫자 형식의 최종 확정은 S2의 정확도 측정 뒤.

## 모델
- 구조: llama2.c 계열(RMSNorm, RoPE, multi-head attention, SwiGLU FFN, 가중치 공유 분류기). C 코드베이스 하나가 config로 크기를 고른다.
- **stories260K**(dim 64, 5 layer, vocab 512, ctx 512): IP 개발과 검증, PIM형 GEMV(가중치가 BRAM에 전부 상주), attention/softmax IP의 주 대상.
- **stories15M**(dim 288, 6 layer, vocab 32000, ctx 256): DDR 스트리밍 GEMV와 end-to-end 측정의 주 대상.
- checkpoint와 tokenizer는 저장소에 넣지 않고 받는 스크립트와 체크섬만 둔다. 15M의 tokenizer 라이선스는 S3 전에 확인한다.

## C 구현의 세 단계 (S2)
| 판 | 내용 | 기준 |
|---|---|---|
| F (float) | 참조 구현과 같은 연산 | 공개 참조 구현의 출력 token과 일치(temperature 0) |
| Q (int8 matmul) | 가중치와 활성 int8, 누산 int32, 그룹 scale. 비선형은 float | F 대비 logits 오차, top-1 일치율, 평균 loss 차이 보고 |
| H (HW형, 전체 정수) | Q + 비선형(RMSNorm, softmax, SiLU, RoPE)의 정수 근사, scale은 가수 + shift. PL이 실제로 하는 연산과 bit-exact. kernel 경계 함수로 분리 | Q 대비 같은 지표. 이 판이 RTL의 golden |

- H판의 형식(비트폭, 근사 방식)은 S2에서 후보를 비교해 고른다. 통과 기준(잠정): 검증 프롬프트 세트에서 F 대비 평균 loss 증가와 top-1 일치율을 보고하고, 수치는 사용자 검토로 확정.
- 서베이가 제기한 의심(공개 양자화 구현에서 hidden_dim이 그룹 크기의 배수가 아닐 때의 그룹 경계)은 S2에서 실행으로 확인한다. 우리 구현은 행 단위 또는 행 길이의 약수로 그룹을 잡는다.

## kernel 목록 (초안, 우선순위는 S3 프로파일로)
1. GEMV 가속기형: 가중치를 DDR에서 AXI HP로 읽어 연산.
2. GEMV PIM형: bank(BRAM) + bank별 MAC + 명령 컨트롤러. 공개 문헌의 GDDR6-AiM 방식을 축소(전 bank 동시 MAC 명령, 벡터 방송, 결과 레지스터). 숫자는 int8 x int8, int32 누산. DRAM 타이밍은 모델링하지 않는다.
3. attention score + softmax.
4. RMSNorm.
5. SiLU / SwiGLU.
6. 분류기 후처리(argmax, top-k).

## 측정 계획 (S3, S6)
- baseline: Zybo ARM bare-metal, kernel별 시간(타이머 또는 PMU cycle counter), token당 시간.
- 오프로드: kernel별로 (a) 순수 연산 시간, (b) 데이터 이동, (c) 호출 오버헤드를 분리 측정.
- 추정(Amdahl)과 end-to-end 실측을 구분해 표로 낸다.
- DDR 스트리밍 구조를 정하기 전에 AXI HP 대역폭 측정용 단순 빌드를 먼저 사용자에게 요청한다.

## 비범위
학습, 15M 초과 모델, 성능 경쟁, DRAM 물리 타이밍 모델.
