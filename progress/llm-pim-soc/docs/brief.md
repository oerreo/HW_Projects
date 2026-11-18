# llm-pim-soc: 작은 LLM 추론 시스템의 kernel별 오프로드와 PIM형 GEMV

상태: 진행 (2026-11-18 사용자 결정 "LLM 추론 + PIM"). 기존 후보 `transformer-attention-accel`을 흡수했다. 다음 프로젝트는 `todo/nand-ecc-subsystem.md`.

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

## PIM (메모리 쪽)
- GEMV를 두 구조로 구현해 비교한다: (1) 가속기형(가중치를 DDR에서 스트림으로 읽어 연산), (2) PIM형(가중치를 bank(BRAM)에 두고 bank 옆 MAC 연산기가 연산, 호스트는 명령만 보냄. HBM-PIM, GDDR6-AiM 계열의 축소 에뮬레이션).
- 비교 지표: 데이터 이동량, 호스트 개입 횟수, kernel 가속비, 자원. 명령 컨트롤러와 bank wrapper는 RTL.
- 흡수한 brief의 내용: 비선형 함수(softmax, GELU, 역제곱근)의 하드웨어 근사와 오차 해석, 양자화 오차 전파. 경쟁 연구가 많아 성능 경쟁은 하지 않는다.

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
