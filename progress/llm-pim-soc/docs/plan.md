# Plan: llm-pim-soc

## 목표
소형 LLM 추론 전체를 C로 구현해 Zybo Z7-20의 ARM에서 baseline을 잡고, kernel을 IP로 만들어 하나씩 오프로드해 측정한다. GEMV는 가속기형과 PIM형 두 구조로 비교한다. kernel별 측정으로 추정한 전체 가속과 end-to-end 실측을 비교한다. 상세는 `brief.md`.

## 로드맵
| 단계 | 내용 | 통과 기준 | 상태 |
|---|---|---|---|
| S0 | 서베이(G0): 모델과 참조 구현 후보, 양자화 방식, PIM 공개 구조, Z7-20 자원 예산, 측정 방법 | `survey/survey.md`, 출처 확인 구분 | 완료 (2026-11-18) |
| S1 | 범위와 시스템 스펙(G0): 모델 선택, 고정소수점 형식, kernel 목록, HW/SW 인터페이스, 메모리 맵 | `spec/` 확정, 사용자 검토 | 결정 (`spec/scope.md`), 사용자 검토 대기 |
| S2 | C 전체 구현(G1): float 참조 대비 검증, 정수판과 정확도 차이 정량화, layer별 덤프 | 참조 구현과 일치, 정수판 오차 보고 | 진행 중 |
| S3 | Test data(G2)와 ARM baseline 프로그램, 프로파일 방법 | `data/README.md`, baseline 실행 파일(사용자 보드 실행) | 대기 |
| S4 | kernel IP(G3/G4): bottom-up, 각각 golden 대비 mismatch 0. GEMV 가속기형과 PIM형 | 모듈별 회귀 통과 | 대기 |
| S5 | 시스템 통합과 FPGA 환경(G5): kernel별 오프로드 빌드 | AXI BFM 시뮬레이션 통과 | 대기 |
| S6 | 보드 측정(G6, 사용자): kernel별 가속비, end-to-end, 추정과 실측 비교 | 결과 mismatch 0, 측정 표 | 대기 |
| S7 | 정리(G7) | 문서, `done/` 이동 | 대기 |

## 메모
- 이전 프로젝트(`pqc-ntt-ip`)가 보드 빌드 대기 중이라 S0를 먼저 시작했다(동시 1개 원칙의 예외, 구현은 겹치지 않음).
- 재사용: `pqc-ntt-ip`의 `axil_slave`, `sim/run.sh` 구조, FPGA Tcl과 호스트 테스트 방식.
