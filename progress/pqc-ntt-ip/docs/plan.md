# pqc-ntt-ip: ML-KEM 다항식 연산 가속 IP (HLS/RTL 하이브리드)

## 목표
NIST FIPS 203 (ML-KEM) 의 다항식 연산(NTT, INTT, pointwise multiply)을 가속하는 재사용 가능한 IP를 만들고,
같은 마이크로아키텍처를 hand RTL과 Catapult HLS 양쪽으로 구현해 QoR과 생산성을 정량 비교한다.

- 설계 산출물: AXI4-Lite(제어) + AXI4-Stream(데이터) IP, Zybo Z7-20에서 PS와 연동해 동작
- 연구 산출물: (a) 모듈러 연산기의 exhaustive 검증, (b) RTL vs HLS QoR 비교(FPGA + ASIC), (c) AI agent 기반 설계 흐름의 기록과 평가
- 논문 방향(2026-11-16 서베이 `docs/survey/survey.md` 기준으로 확정):
  1. 주 방향: ML-KEM 다항식 연산의 RTL 대 Catapult HLS 통제 비교. RTL 컨트롤러는 고정하고 데이터패스만 교체, q=3329 reduction 4종 sweep, FPGA(XC7Z020)와 ASIC(DC) 양쪽 수치.
  2. 결합 방향: agent 보조 설계 흐름의 정량 기록(작업 유형별 성공 여부, 재작업 횟수, 사람 개입 횟수). 지표는 P2 시작 전에 `docs/spec/agent-metrics.md`로 고정.
  - 하지 않는 것: Kyber NTT 단독 구현의 성능 경쟁(포화), ML-KEM+ML-DSA 통합 butterfly 단독(포화), exhaustive 검증 자체를 기여로 주장하는 것.
  - 현실적 목표 수준은 short paper 또는 저널(서베이의 평가). 서베이의 재인용/미확인 문헌 수치는 논문에 쓰기 전에 원문 확인이 필요하다.

## 고정된 결정
| 항목 | 결정 | 근거 |
|---|---|---|
| 알고리즘 | ML-KEM, q=3329, n=256, 7-layer incomplete NTT (FIPS 203 Alg. 9~12) | 표준 확정, 공인 벡터 존재 |
| 수 표현 | canonical unsigned 12-bit, [0, q) | HW에서 표준적, exhaustive 검증 가능(입력 공간 2^24) |
| RTL 담당 | NTT 스케줄 컨트롤러, 주소 생성, 메모리 wrapper, AXI wrapper, top | control 중심 |
| RTL + HLS 양쪽 | modular reduction, butterfly(CT/GS), basemul 데이터패스 | QoR 비교 대상 |
| 확장(선택) | Keccak/샘플링을 붙여 ML-KEM-768 전체, 또는 ML-DSA(q=8380417) 통합 butterfly | P4 이후 서베이 결과로 결정 |

## 계층
bottom-up으로 진행한다. 모듈 트리, 진행 순서, L0 인터페이스는 `docs/spec/hierarchy.md`.

## 로드맵
| 단계 | 내용 | 통과 기준 | 상태 |
|---|---|---|---|
| P0 | 워크스페이스 세팅(CLAUDE.md, rules, skills, agents), 툴 확인 | 툴 버전 확인 | 완료 (2026-11-16) |
| P1 | 서베이 + golden model + test data + 스펙 (G0, G1, G2) | 아래 참조 | 완료 (2026-11-16) |
| P2 | 모듈러 연산기: reduction 후보(Barrett, Montgomery, K-RED, 시프트-가산) RTL/HLS | q^2 전 입력 exhaustive, mismatch 0 | 진행 중 |
| P3 | NTT 코어: butterfly + RTL 컨트롤러 + 메모리, NTT/INTT/basemul 모드 | golden model 대비 random 다항식 10^4개 이상 mismatch 0, backpressure random | 대기 |
| P4 | 범위 확장 결정과 구현(Keccak 포함 전체 KEM 또는 ML-DSA 통합) | 공인 벡터 통과 | 대기 |
| P5 | AXI wrapper, PS 드라이버, Vivado Tcl 준비. 합성과 보드 실행은 사용자 | 보드에서 SW 참조 결과와 일치 | 대기 |
| P6 | DC 합성(사용자 승인 시), RTL vs HLS QoR 표 | 리포트 확보 | 대기 |
| P7 | 논문 원고 | 사용자 검토 | 대기 |

## P1 sub job
| ID | 담당 | 내용 | 산출물 | 통과 기준 |
|---|---|---|---|---|
| P1-a (완료) | Opus | 선행 연구 서베이: ML-KEM/Kyber NTT HW, HLS 기반 PQC, RTL vs HLS 비교 연구, 최근 2년 동향과 빈 곳 | `docs/survey/survey.md` | 모든 항목에 확인 가능한 출처, 수치는 원문 조건과 함께 |
| P1-b (완료) | Opus | C++ golden model: 모듈러 연산, NTT/INTT/basemul (FIPS 203 Alg. 9~12), 벡터 생성기 | `model/` | 자체 테스트 통과(역변환 항등, schoolbook 곱과 일치), 가능하면 외부 참조 구현과 교차 확인 |
| P1-d (완료) | Opus | Test data 확보: NIST ACVP ML-KEM 벡터, 공개 참조 구현(pq-crystals) 출력에서 다항식 단위 중간값 추출, 방향성/random 벡터 정리 | `data/`, `data/README.md` | 출처와 라이선스 기록, golden model이 외부 데이터와 일치 |
| P1-c (완료) | Fable | 서베이를 반영해 마이크로아키텍처 스펙 확정, agent 지표 고정 | `docs/spec/arch.md`, `docs/spec/agent-metrics.md` | - |
| P1-e (완료) | Sonnet | 서베이 요약을 Notion `논문 및 알고리즘 정리`로 정리 | Notion Process 항목 | 수치는 survey.md의 확인 문헌 것만 |

## P2 sub job (L0, bottom-up. P1-d 완료 후 시작)
| ID | 담당 | 내용 | 산출물 | 통과 기준 |
|---|---|---|---|---|
| P2-0 (완료) | Opus | golden model에 `arch.md`의 basemul micro-op 시퀀스(MONT12, K2RED 7 op / BARRETT, SHIFTADD 5 op)와 `mod_half`, halving GS butterfly를 추가 | `model/` | 모든 ALGO에서 multiply_ntts와 INTT가 기준 구현, pq-crystals 교차 확인과 일치. 기존 38개 항목 유지 |
| P2-1 (완료) | Opus | `mod_add`, `mod_sub`, `mod_half` RTL + TB (DPI-C 또는 벡터) | `rtl/l0/`, `tb/` | Questa, 정의역 전체 exhaustive, mismatch 0 |
| P2-2 (완료) | Opus | `mod_red` 4종 RTL + TB, `mlkem_dpi_pkg.sv` 갱신, `mod_half` TB를 DPI 대조로 교체 | `rtl/l0/` | 변형별 정의역 전체 exhaustive, mismatch 0 |
| P2-3 (완료) | Opus | `mod_mul` RTL + TB | `rtl/l0/` | q^2 쌍 exhaustive x 4종, mismatch 0 |
| P2-4 (진행 중) | Opus | `mod_red`, `mod_mul` Catapult HLS판 | `hls/` | 같은 TB와 벡터로 mismatch 0, Catapult 리포트 보관 |
| P2-5 | Opus | QoR 측정 전 정리: golden 선언 폭을 실측 폭으로 조정(Barrett r/d 13b, MONT12 d s13, SHIFTADD y5 13b와 d1/d2), MONT12 `s` 하위 12b 생략 축약. golden과 RTL, HLS에 동일 적용 | `model/`, `rtl/l0/`, `hls/` | exhaustive 재통과, width 검사 위반 0 |
P2-5는 비교의 공정성을 위한 것이다(hand RTL이 불필요하게 넓은 폭을 쓰면 RTL 쪽이 불리해진다). P6 측정 전에 반드시 끝낸다.
각 sub job의 결과는 `docs/agent-log.csv`에 기록한다(`docs/spec/agent-metrics.md`).

## P3 sub job (L1~L3)
| ID | 담당 | 내용 | 산출물 | 통과 기준 |
|---|---|---|---|---|
| P3-1 (완료) | Opus | `bfu` RTL + TB | `rtl/l1/`, `tb/l1/` | golden DPI 대비 경계, ROM z, random, mode 혼합, trace 재생 mismatch 0 |
| P3-2 (진행 중) | Opus | `zeta_rom`(ALGO별 ROM 3종), `coef_ram`, `ntt_ctrl`(NTT/INTT 스케줄, basemul micro-op 시퀀서) | `rtl/l2/` | 주소와 제어 시퀀스가 golden trace와 일치 |
| P3-3 | Opus | `ntt_core` 통합 | `rtl/l3/` | 다항식 단위 벡터(외부 전부 + random + 경계) mismatch 0, stall random |
| P3-4 | Opus | `sim/run.sh` 정리: `quick`/`all`, `L[01]_RANGE` 집계 | `sim/` | 전체 회귀 통과 |

## 시각 자료 (`.claude/rules/visual-docs.md`)
| ID | 담당 | 내용 | 산출물 | 상태 |
|---|---|---|---|---|
| V-1 | Opus | NTT/INTT/basemul 스케줄 interactive viewer (golden model trace 기반 player) | `docs/viewer/` | 완료 (Artifact: https://claude.ai/artifact/5F5nzds9zbxzuMcZDcnGrr) |
| V-2 | Sonnet | 계층 block diagram, L0 모듈 data flow (Mermaid) | `docs/diagrams/`, 스펙 문서 | 완료 (GitHub 렌더링 확인 필요) |
| V-3 | Sonnet | `bfu` 데이터패스(draw.io), `ntt_ctrl` control flow | `docs/diagrams/` | P3 해당 모듈 통과 후 |
| V-4 | Opus | viewer 확장: RTL 시뮬레이션 trace, AXI 트랜잭션 | `docs/viewer/` | P3, P5 |

## Gate 대응 (`.claude/rules/project-flow.md`)
G0/G1/G2 = P1, G3/G4 = P2~P4 (블록별로 반복), G5/G6 = P5, G7 = P6~P7.
P5의 FPGA 검증은 Zynq PS(ARM) bare-metal 프로그램이 벡터를 넣고 golden과 비교하는 구조로 한다.

## 사용자 승인 대기 항목
- (없음)
