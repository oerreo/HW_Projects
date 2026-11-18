# memory-subsystem-ip: 메모리 제품 쪽 디지털 설계 (컨트롤러 외)

상태: 후보 (2026-11-18, 사용자 제안). 아래 중 하나를 골라 시스템 프로젝트 방식(`tiny-llm-inference-soc.md`의 "방식")으로 진행.

## 메모리 회사의 디지털 설계 영역 (컨트롤러만이 아니다)
| 영역 | 내용 | 이 워크스페이스에서의 실현성 |
|---|---|---|
| A. NAND/SSD ECC | LDPC(soft decision), BCH, read retry. SSD 컨트롤러의 면적과 전력의 큰 부분 | 높음. C 채널 모델 + decoder IP. 기존 `ldpc-decoder-5g.md`와 구조 공유 |
| B. PIM (processing in memory) | 메모리 bank 옆 MAC 연산기로 GEMV 수행(HBM-PIM, GDDR6-AiM 계열) | 높음. BRAM bank + bank별 연산기로 축소 에뮬레이션. AI 프로젝트와 직접 연결 |
| C. DRAM on-die ECC / RAS | SEC, SEC-DED, symbol 기반(RS) 정정, scrubbing | 높음. 크기가 작아 단독으로는 약함. 다른 항목의 부속으로 적합 |
| D. MBIST / repair | March 알고리즘, 고장 bitmap, 여분 row/column 배정(BIRA) | 중간. 고장 모델을 C로 만들어야 함 |
| E. DDR/NAND 인터페이스 | DFI, training, ONFI/Toggle | 낮음. PHY와 실제 소자 의존 |
| F. CXL 메모리 / 압축 | tiering, 메모리 압축(LZ 계열), 체크섬 | 중간. 기존 `rans-entropy-codec.md`와 연결 |
| G. 보안과 신뢰성 | rowhammer 완화(카운터 기반), 메모리 암호화 | 중간 |

## 추천 후보
1. **B. PIM 축소 에뮬레이션**: C로 LLM의 GEMV를 bank 분할해 모델링, PL에 bank(BRAM) + MAC 연산기 + 명령 컨트롤러(RTL). 호스트(ARM)가 명령을 내리고 GEMV를 오프로드. `tiny-llm-inference-soc`의 GEMV IP를 "가속기형"과 "PIM형" 두 구조로 비교할 수 있어 AI와 메모리 두 주제를 한 시스템으로 묶는다.
2. **A. NAND ECC 서브시스템**: C로 NAND 채널(P/E cycle, retention에 따른 threshold 분포), LDPC encoder/decoder, read retry 정책. decoder를 IP로 오프로드해 throughput과 정정 성능(FER) 측정.

## RTL / HLS 분담
- RTL: 명령 디코더와 컨트롤러, 메모리 bank wrapper, 버스 인터페이스, 스케줄.
- HLS 가능: MAC datapath, LDPC check/variable node 연산.

## Test data 후보
- B: 공개 모델 가중치와 입력 activation 덤프, random, 경계.
- A: 공개 LDPC 코드 행렬(표준 문서), 문헌의 NAND 오류 모델 parameter(출처 확인 필요), random.

## 미확인
- 각 제품의 실제 구조 세부는 공개 논문 수준에서만 확인 가능. 시작 전 서베이(G0)에서 출처를 확인한다.
