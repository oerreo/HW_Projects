# Plan: llm-pim-soc

## 목표
소형 LLM 추론 전체를 C로 구현해 Zybo Z7-20의 ARM에서 baseline을 잡고, kernel을 IP로 만들어 하나씩 오프로드해 측정한다. GEMV는 가속기형과 PIM형 두 구조로 비교한다. kernel별 측정으로 추정한 전체 가속과 end-to-end 실측을 비교한다. 상세는 `brief.md`.

## 로드맵
| 단계 | 내용 | 통과 기준 | 상태 |
|---|---|---|---|
| S0 | 서베이(G0): 모델과 참조 구현 후보, 양자화 방식, PIM 공개 구조, Z7-20 자원 예산, 측정 방법 | `survey/survey.md`, 출처 확인 구분 | 완료 (2026-11-18) |
| S1 | 범위와 시스템 스펙(G0): 모델 선택, 고정소수점 형식, kernel 목록, HW/SW 인터페이스, 메모리 맵 | `spec/` 확정, 사용자 검토 | 결정 (`spec/scope.md`), 사용자 검토 대기 |
| S2 | C 전체 구현(G1): float 참조 대비 검증, 정수판과 정확도 차이 정량화, layer별 덤프 | 참조 구현과 일치, 정수판 오차 보고 | 구현 완료 (G1) |
| S2b | 정수 형식 평가 확대와 H판 형식 확정: 260K 1,320 story, 15M 300 story, K/V 폭, LUT, window 비교 | 형식 결정과 근거, 메모리 계산 | 완료 (2026-11-18). 결정: 두 모델 모두 K12V8(q/K 12비트, V 8비트, MANT 활성 scale, 행 단위 가중치 scale, 8비트 LUT, context 전체). `spec/numeric.md` 4절 |
| S3 | Test data(G2)와 ARM baseline 프로그램, 프로파일 방법 | `data/README.md`, baseline 실행 파일(사용자 보드 실행) | 준비 완료(호스트 테스트 23/23 PASS, PC x86-64 [측정, 오케스트레이터 재실행]), 사용자 보드 실행 대기. 실행 절차 `fpga/README.md`, 결과는 `fpga/results/<date>_<o2|o3>/` |
| S4 | kernel IP(G3/G4): bottom-up, 각각 golden 대비 mismatch 0. GEMV 가속기형과 PIM형 | 모듈별 회귀 통과 | 대기 |
| S4-0 | 계층과 마이크로아키텍처 스펙: `spec/hierarchy.md`, `spec/arch.md`. 아래 S4-1~S4-8은 S4-0의 제안(2026-11-19) | 오케스트레이터 검토, 열린 결정 D1~D14(`spec/arch.md` 11절) 확정 | 완료 (2026-11-19). D1~D14 권고대로 확정 (`spec/arch.md` 12절) |
| S4-1 | 검증 기반: model 보강(stage 함수 export, PIM bank image 생성기, K12V8 덤프와 위치 필터, 지수/shift 범위 집계, 덤프 변환), DPI-C golden, `sim/run.sh` 복사, AXI slave memory model | `make test` PASS, 기존 덤프 `cmp` 동일, memory model self-test | 완료 (2026-11-19). `make test` 16,669,793 항목 mismatch 0, `sim/run.sh all` 18 run PASS (수퍼바이저 재실행). `E_W` = 8, `SH_W` = 10 확정 |
| S4-2 | `rshr_sat`, `dotp`, `sync_fifo`, `ram_sdp` -> `mac_row`, `gemv_scale` -> `gemv_core` | leaf 벡터와 K_GEMV 레코드 전부(두 모델) mismatch 0, cycle 식 일치 | 완료 (2026-11-19). 7개 모듈 단독 G4, `sim/run.sh all` 97 run fails 0 (수퍼바이저 재실행), mutation 18/18 검출, cycle 식 일치 |
| S4-3 | `axi_rd_eng`, `axi_wr_eng` (+ HP 대역폭 측정 top, 사용자 보드 실행 요청) | AXI memory model에서 데이터 mismatch 0, 프로토콜 assertion 0 | RTL 완료 (2026-11-19). 4개 모듈 단독 G4, `sim/run.sh all` 164 run fails 0 (수퍼바이저 재실행), mutation 30/31 검출(1개 동치). HP 대역폭 측정 빌드(`fpga/bw/`)는 사용자 보드 실행 대기 |
| S4-4 | `argmax_red`, `gemv_acc_csr`, `gemv_acc_top` (GEMV 가속기형 IP) | AXI BFM으로 K_GEMV(분류기 포함)와 K_ARGMAX mismatch 0 | 완료 (2026-11-19). P = 1, 2 모두 G4, `sim/run.sh all` 201 run fails 0 (수퍼바이저 재실행), mutation 24/24 검출. 레지스터 맵 `spec/gemv_acc.md` |
| S4-5 | `pim_bank`, `pim_gb`, `pim_ctrl`, `pim_core`, `pim_top` (GEMV PIM형 IP) | 260K 전 행렬 K_GEMV mismatch 0, `bank.c` 명령 수 일치 | 대기 |
| S4-6 | `udiv_seq`, `lut_lerp`(EXP2N), `exp_unit`, `attn_score`, `attn_vacc`, `attn_core`, `kv_store`, `kv_rd`, `attn_top` | K_ATTN2(T 1..512, p와 o) mismatch 0 | 대기 |
| S4-7 | `rsqrt_nr`, `lut_lerp`(SIGM), `actq_core`, `rms_front`, `swi_front`, `vec_core`, `vec_top` | K_RMSNORM, K_SWIGLU, K_ACTQ, K_ARGMAX mismatch 0 | 대기 |
| S4-8 | 전체 회귀, irun 교차, 다이어그램(`visual-docs.md`), viewer 확장 | `sim/run.sh all` 전 run PASS, 로그 보관 | 대기 |
| S5 | 시스템 통합과 FPGA 환경(G5): kernel별 오프로드 빌드 | AXI BFM 시뮬레이션 통과 | 대기 |
| S6 | 보드 측정(G6, 사용자): kernel별 가속비, end-to-end, 추정과 실측 비교 | 결과 mismatch 0, 측정 표 | 대기 |
| S7 | 정리(G7) | 문서, `done/` 이동 | 대기 |

## 메모
- 이전 프로젝트(`pqc-ntt-ip`)가 보드 빌드 대기 중이라 S0를 먼저 시작했다(동시 1개 원칙의 예외, 구현은 겹치지 않음).
- 재사용: `pqc-ntt-ip`의 `axil_slave`, `sim/run.sh` 구조, FPGA Tcl과 호스트 테스트 방식.
