# Plan: nand-ecc-subsystem

## 목표
NAND/SSD용 ECC 서브시스템 전체(채널 모델, LLR 생성, LDPC encoder/decoder, BCH 비교, read retry 정책)를 C로 구현해 golden이자 SW baseline으로 삼고, Zybo Z7-20의 ARM에서 프로파일한 뒤 모듈을 IP로 만들어 하나씩 오프로드해 측정한다. 정정 성능(FER 대 raw BER)과 throughput, ARM 대비 가속, 추정(Amdahl)과 end-to-end 실측의 차이를 낸다. 상세는 `brief.md`, 조사는 `survey/survey.md`.

## 로드맵
| 단계 | 내용 | 통과 기준 | 상태 |
|---|---|---|---|
| N0 | 서베이(G0): 오류 모델, SSD ECC, 공개 code 행렬, decoder 구조와 FPGA 사례, 범위 제안 | `survey/survey.md`, 출처 확인 구분 | 완료 (2026-11-24) |
| N1 | 범위와 시스템 스펙(G0): code 구성(QC-LDPC, 구성 알고리즘과 girth/rank 검증), 채널 모델과 LLR 형식, decoder 알고리즘과 고정소수점 형식의 후보, IP 분할과 자원 계산, HW/SW 인터페이스 초안, test data 계획, 측정 계획 | `spec/scope.md`, `spec/code.md`, `spec/channel.md`, 열린 결정 목록과 권고. 오케스트레이터 검토 후 확정 | 진행 중 |
| N2 | C 전체 구현(G1): code 생성기, encoder, 채널 모델(MLC 해석, TLC fit), LLR 생성, decoder(float BP/min-sum 참조, 고정소수점 layered min-sum), BCH, FER 시뮬레이터 | 외부 기준(CCSDS C2, 802.3an 행렬과 오픈소스 참조 구현)과 교차 검증, 자체 code의 FER 곡선, 단위 테스트 | 대기 |
| N2b | 형식 평가: LLR 비트폭 4/5/6, 감지 레벨 수, normalized/offset min-sum 계수, iteration 수, 조기 종료 | 형식 결정과 근거(FER 손실 대 비용) | 대기 |
| N3 | Test data(G2)와 ARM baseline 프로그램, 프로파일 방법 | `data/README.md`, baseline 실행 파일(사용자 보드 실행) | 대기 |
| N4 | IP(G3/G4): bottom-up, 모듈마다 golden 대비 mismatch 0. decoder(스케줄러와 메모리는 RTL, node datapath는 RTL 또는 HLS 비교), LLR 생성, encoder | 모듈별 회귀 통과 | 대기 |
| N5 | 시스템 통합(G5): AXI wrapper, 드라이버, 시스템 TB, Vivado/XSCT 스크립트 | 시스템 TB에서 golden과 일치, 사용자 빌드 요청 | 대기 |
| N6 | 보드 측정(G6, 사용자) | mismatch 0, 측정 표 | 대기 |
| N7 | 정리 | 문서, 다이어그램, viewer, `done/` 이동 | 대기 |

## 방침
- 라이선스는 eval 환경과 bm06만. Questa만 사용. Vivado는 사용자 실행.
- 외부 행렬과 데이터는 저장소에 넣지 않는다(받는 스크립트와 checksum만).
- 컨트롤러, 스케줄러, top, 버스 인터페이스는 RTL 직접 작성.
