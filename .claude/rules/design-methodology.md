# 설계 방법론

## RTL / HLS 분담
- **RTL로 직접 작성**: FSM/컨트롤러, 스케줄러, top wrapper, AXI 등 버스 인터페이스, CDC/reset, 메모리 wrapper, handshake glue. control이 품질을 좌우하는 모듈은 전부 RTL.
- **HLS(Catapult) 사용 가능**: 산술 데이터패스, 변환, 필터처럼 알고리즘이 본체이고 스케줄 탐색의 이득이 있는 블록. 난이도가 낮아 RTL이 더 명확하면 RTL로 쓴다.
- 같은 블록을 RTL과 HLS 양쪽으로 만들어 QoR을 비교하는 것은 연구 목적상 권장한다. 이때 인터페이스와 검증 벡터는 동일하게 유지한다.

## RTL 코딩 (SystemVerilog)
- 합성 가능한 subset만. `always_ff` / `always_comb`, `logic`, non-blocking은 순차 로직에만.
- 클럭 `clk`, 리셋 `rst_n`(active-low, 비동기 assert·동기 deassert 기준). 입출력은 `_i` / `_o`, 레지스터 next는 `_d` / `_q`.
- 파라미터화하고 잘못된 파라미터는 elaboration에서 실패시킨다.
- 스트림 인터페이스는 valid/ready. backpressure를 무시하는 블록은 그 사실을 포트 주석에 적는다.
- latch 추론, 조합 루프, 초기값 의존(`initial`)을 만들지 않는다. FPGA 전용 primitive는 `fpga/` wrapper 안에서만 쓴다.

## HLS 코딩 (Catapult)
- `ac_int` / `ac_fixed`, `ac_channel`로 비트 정밀도를 명시한다. 계층은 `#pragma hls_design`으로 나눈다.
- 타깃 클럭, 인터페이스, 루프 제약은 Tcl에 두고 소스에는 넣지 않는다.

## 검증
- 모든 블록은 `model/`의 bit-accurate golden model과 비교한다. 순서는 golden model 자체 검증(공인 테스트 벡터) -> RTL/HLS 시뮬레이션 비교.
- 입력 공간이 작으면(대략 2^28 이하) exhaustive, 크면 corner + constrained random. 시드와 벡터 수를 로그에 남긴다.
- TB는 self-checking이며 마지막에 mismatch 수와 `PASS`/`FAIL`을 출력한다. 0 mismatch만 통과다.
- backpressure와 stall은 random으로 흔들어 본다.
- 기본 시뮬레이터는 Questa. 릴리스 시점에 irun으로 교차 확인한다.

## Hierarchical design (bottom-up)
- 설계는 계층으로 나누고 작은 leaf 모듈부터 올라간다. 계층과 모듈 목록은 프로젝트의 `docs/spec/hierarchy.md`가 원본이다.
- 한 모듈 = 한 파일 = 한 가지 책임. 모듈마다 전용 TB와 golden model의 대응 함수(같은 경계에서 입출력 덤프)가 있어야 한다.
- 각 모듈은 단독으로 G3(RTL)와 G4(golden 대비 mismatch 0)를 통과한 뒤에만 상위 모듈에 인스턴스한다. 상위 모듈 검증에서 하위 모듈을 다시 고쳤으면 하위 TB를 다시 돌린다.
- 상위 모듈은 하위 모듈을 인스턴스와 배선, 그리고 자기 계층의 control로만 구성한다. 하위 모듈의 로직을 상위에 복제하지 않는다.
- 모듈 경계의 인터페이스(포트, 타이밍, latency, valid/ready 여부)는 구현 전에 `hierarchy.md`에 고정한다. latency가 있는 모듈은 parameter 또는 localparam으로 드러낸다.
- RTL/HLS 양쪽으로 만드는 블록은 같은 계층 위치와 같은 포트를 가져, 상위에서 parameter 하나로 교체할 수 있게 한다.
- 디렉토리는 계층을 따른다: `rtl/<level 또는 block>/`, `tb/<module>/`, `sim/<module>/`.
- 회귀: 프로젝트에 모듈 TB 전체를 순차로 돌리는 스크립트를 두고, 상위 계층을 통과시킬 때마다 실행한다.

## 레지스터 reset 규칙
- control 레지스터(valid, FSM state, counter, handshake)는 `rst_n`으로 reset한다.
- datapath 레지스터는 reset 없이 enable로 받고, 대응하는 valid로 의미를 한정한다. valid가 0일 때의 data 값에 의존하는 로직을 만들지 않는다.
- TB는 입력을 posedge에서 non-blocking으로 넣고 negedge에서 검사한다(입력 변경과 검사를 같은 시점에 두면 조합 통과 버그를 놓친다. 2026-11-16 P2-1에서 확인).
