# tiny-llm-inference-soc: 작은 LLM 추론 시스템의 kernel별 오프로드

상태: 후보 (2026-11-18, 사용자 제안 "AI 반도체, 굵직한 시스템 프로젝트"). 기존 `transformer-attention-accel.md`를 포함하는 상위 프로젝트.

## 분야
AI 가속기 (transformer 추론). 시스템 수준: C 참조 구현 전체 + kernel 단위 IP + HW/SW 분할.

## 방식 (시스템 프로젝트 공통)
1. 전체를 C로 구현해 PC와 Zybo의 ARM(Cortex-A9)에서 그대로 돌린다. 이것이 golden이자 baseline.
2. ARM에서 프로파일해 kernel별 시간 비중을 잰다.
3. Zybo Z7-20(XC7Z020)에 들어가는 크기로 kernel을 IP로 만든다(각각 golden 대비 mismatch 0).
4. kernel을 하나씩 PL로 오프로드해 kernel 단독 가속비와 end-to-end 시간을 잰다.
5. 측정한 kernel 가속비와 비중으로 전체 가속을 추정(Amdahl)하고, 실제 end-to-end 측정과 비교한다. 차이(데이터 이동, 호출 오버헤드)를 분석한다.

## 범위
- 모델: 공개된 소형 transformer(TinyStories 계열 수백 K ~ 15 M parameter), int8 또는 고정소수점 양자화. 양자화 전후 출력 차이를 C에서 먼저 정량화.
- 후보 IP: GEMV/matmul(가중치는 DDR, AXI HP로 읽음), attention score + softmax, RMSNorm/LayerNorm, 활성함수(SiLU/GELU 근사), sampling(top-k).
- 비범위: 학습, 대형 모델, 성능 경쟁.

## 가치
- 실무: AI 반도체 직무의 핵심인 HW/SW 분할, 양자화 정밀도, 메모리 대역폭 병목을 숫자로 다룬다.
- 연구: "kernel별 측정에서 추정한 가속"과 "실제 end-to-end"의 차이를 통제해 보고. RTL 대 HLS 비교를 kernel별로 이어갈 수 있다.

## RTL / HLS 분담
- RTL: AXI 인터페이스, DMA/메모리 접근 컨트롤러, 스케줄러, top.
- HLS(Catapult) 가능: matmul datapath, softmax, norm, 활성함수.

## Test data 후보
- 공개 모델 checkpoint와 tokenizer(라이선스 확인), 공개 프롬프트 세트. 참조 구현의 layer별 중간값 덤프.
- 방향성(포화, 0, 최대값), random tensor.

## 위험
- Z7-20 자원(LUT 53,200, DSP 220, BRAM 4.9 Mb)과 PS-PL 대역폭. 가중치가 BRAM에 안 들어가므로 메모리 접근 구조가 설계의 중심이 된다.
