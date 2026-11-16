# 프로젝트 표준 흐름

이 워크스페이스는 한 분야(코덱)에 머물지 않고 여러 종류의 HW 가속기 프로젝트를 차례로 진행한다.
모든 프로젝트는 아래 gate를 순서대로 통과한다. 앞 gate를 통과하기 전에는 다음 단계의 구현을 시작하지 않는다
(다음 단계의 계획과 스크립트 준비는 가능).

| Gate | 단계 | 통과 기준 |
|---|---|---|
| G0 | 조사와 스펙 | 서베이, 인터페이스와 마이크로아키텍처 스펙, test data 확보 계획 |
| G1 | Golden model (Python 또는 C/C++) | 공인 또는 외부 기준 데이터와 일치. bit-accurate, 벡터 덤프 가능 |
| G2 | Test data 확보 | 아래 "Test data" 기준 충족, `data/`에 정리 |
| G3 | RTL (필요 시 HLS 병행) | lint 수준 경고 정리, 스펙과 일치 |
| G4 | RTL sim 대 golden model 비교 | 전체 test data에서 mismatch 0으로 시뮬레이션 종료. Questa 기준, 로그 보관 |
| G5 | FPGA 검증 환경 구성 | Zybo Z7-20, Zynq PS(ARM Cortex-A9)가 호스트. AXI wrapper, bare-metal 드라이버, Vivado Tcl 준비 |
| G6 | FPGA 검증 | 사용자가 Vivado로 생성하고 보드 실행. PS가 test data를 넣고 결과를 golden과 비교, mismatch 0 |
| G7 | 정리 | (승인 시) DC 합성 수치, 문서, 논문 원고, `done/` 이동 |

- G4에서 mismatch가 하나라도 있으면 G5로 넘어가지 않는다. 원인을 RTL, golden model, test data 중 어디인지 가려 기록한다.
- golden model 언어: 비트 연산과 속도가 중요하거나 DPI-C/HLS와 공유할 것이면 C++, 알고리즘 탐색과 데이터 분석 위주면 Python. 두 언어를 같이 쓰면 서로 교차 검증한다.

## FPGA 검증 환경 (G5, G6)
- 구조: PS(ARM)에서 AXI4-Lite로 제어, 데이터는 AXI4-Stream + AXI DMA 또는 AXI BRAM. PS의 bare-metal C 프로그램이 벡터를 넣고 결과를 비교해 UART로 PASS/FAIL과 mismatch 수를 출력한다.
- PS 쪽 기대값은 golden model이 만든 벡터 파일(C 배열 헤더로 변환) 또는 PS에서 golden model C 코드를 직접 실행한 결과를 쓴다.
- Claude가 준비하는 것: block design Tcl, XDC, 드라이버와 테스트 프로그램 소스, 실행 순서 문서. Vivado 실행과 보드 작업은 사용자가 한다. 사용자가 전달한 리포트(utilization, timing, UART 로그)를 받아 분석한다.
- RTL sim에서 AXI wrapper까지 포함한 top을 AXI BFM으로 먼저 검증해, 보드에서는 통합 문제만 남게 한다.

## Test data (G2)
프로젝트마다 `data/`를 두고 `data/README.md`에 출처, 라이선스, 받은 날짜, 생성 명령, 파일별 용도를 적는다.
세 종류를 모두 갖춘다.

1. **공인/외부 데이터**: 표준 기관의 테스트 벡터, 표준 참조 구현의 출력, 공개 벤치마크 데이터셋. golden model 자체를 검증하는 기준이다.
2. **방향성 벡터**: 경계값, 오버플로 직전, 전부 0, 전부 최대값, 임펄스, 스펙의 예제.
3. **random 벡터**: 시드와 개수를 기록해 재현 가능하게. golden model로 기대값 생성.

- 외부 데이터는 라이선스를 확인하고, 재배포가 불가하면 저장소에 넣지 않고 내려받는 스크립트만 둔다.
- 대용량 원본은 커밋하지 않는다(받는 스크립트와 체크섬만). 회사 데이터와 회사 테스트 스트림은 쓰지 않는다.
- 실제 응용 데이터가 있는 분야(영상, 음성, 통신 채널, 신경망 입력)는 합성 데이터만으로 끝내지 않고 공개 실제 데이터를 포함한다.
- 외부 데이터를 구하지 못했으면 그 사실과 대체 근거(독립 구현 간 교차 검증 등)를 `data/README.md`와 로그에 적는다.

## 프로젝트 선정
- `todo/`의 brief에는 분야, 수학적 또는 실무적 가치, RTL/HLS 분담, test data 출처 후보를 적는다.
- 연속된 프로젝트는 분야를 바꿔 포트폴리오 폭을 넓힌다(암호, 통신, 신호처리, 압축, ML, 프로세서 주변 IP 등).
