# L4 스펙: pqc_ntt_axi_top와 FPGA 검증 환경

상태: 초안 (2026-11-17). `ntt_core`(P3-3) 통과 후 확정한다. 표준 흐름의 G5, G6에 해당한다.

## 목적
`ntt_core`를 Zynq PS(ARM Cortex-A9)에서 구동할 수 있게 감싼다. PS의 bare-metal 프로그램이 다항식을 넣고 결과를 읽어 golden과 비교한다.

## 구조
```
PS (ARM)  --AXI4-Lite-->  pqc_ntt_axi_top
                             csr          레지스터 맵, start/done, 상태        RTL
                             ntt_core     (ALGO와 파이프라인 구성은 parameter)
```
- v1은 AXI4-Lite만 쓴다. 계수 입출력도 CSR의 데이터 레지스터로 한다(쓰기 한 번 = 계수 하나를 입력 스트림으로, 읽기 한 번 = 출력 스트림에서 계수 하나).
  - 이유: block design이 PS + IP 하나로 끝나 보드 검증의 변수가 줄어든다. 256 계수 전송이 AXI4-Lite로도 충분히 빠르다(검증 목적).
  - AXI4-Stream + AXI DMA는 처리량 측정이 필요해지면 v2로 추가한다(`ntt_core`의 스트림 포트는 그대로 노출 가능).
- 클럭은 PS의 FCLK_CLK0 하나, reset은 `proc_sys_reset`의 peripheral aresetn. CDC 없음.

## 레지스터 맵 (32-bit, offset은 byte)
| offset | 이름 | 접근 | 내용 |
|---|---|---|---|
| 0x00 | CTRL | W | bit0 `start`(1 쓰면 1 cycle pulse), bit[3:1] `op`(`ntt_l2_pkg`의 op 인코딩), bit4 `bank` |
| 0x04 | STATUS | R | bit0 `busy`, bit1 `done_sticky`(CTRL 쓰기 때 clear), bit2 `result_bank`, bit3 `in_ready`, bit4 `out_valid` |
| 0x08 | DIN | W | bit[11:0] 계수. LOAD 중 `in_ready`일 때의 쓰기만 받아들인다 |
| 0x0C | DOUT | R | bit[11:0] 계수. UNLOAD 중 `out_valid`일 때 읽으면 다음 계수로 넘어간다 |
| 0x10 | CYCLES | R | 마지막 op의 start에서 done까지의 cycle 수(하드웨어 카운터) |
| 0x14 | VERSION | R | bit[7:0] ALGO, bit[15:8] BFU_LATENCY, bit[31:16] 고정 ID |
| 0x18 | ERR | R/W1C | bit0 busy 중 start, bit1 `in_ready` 아닐 때 DIN 쓰기, bit2 `out_valid` 아닐 때 DOUT 읽기 |

- DIN 쓰기와 DOUT 읽기를 스트림 handshake로 바꾸는 방식(쓰기 채널을 `in_ready`까지 잡아 둘지, ERR만 세울지)은 구현 전에 확정한다. v1 기본은 "잡아 두지 않고 ERR". PS 프로그램이 STATUS를 보고 쓴다.
- CYCLES는 시뮬레이션 실측값(`arch.md`의 식)과 보드에서 같아야 한다. 보드 검증 항목에 포함한다.

## 검증 (RTL sim, G4의 L4 부분)
- AXI4-Lite BFM(TB 내 task)으로 PS 프로그램과 같은 순서를 수행: LOAD, op, UNLOAD. 벡터와 기대값은 `ntt_core` TB와 같은 세트의 부분집합(외부 벡터 포함).
- AXI 프로토콜 검사: valid가 ready 전에 내려가지 않음, 응답 채널 순서, 동시 read/write, backpressure(ready 지연 random).
- ERR 비트 각각을 유발하는 run.

## FPGA 검증 환경 (G5, G6)
Claude가 준비하고 사용자가 실행한다(이 머신에서 Vivado 실행 금지).
- `fpga/vivado/create_project.tcl`: Zybo Z7-20(xc7z020clg400-1) 프로젝트, RTL 추가, IP 패키징 없이 RTL module reference로 block design에 넣는다. PS7 preset, FCLK 주파수는 parameter(기본값은 P5에서 결정), UART1 사용.
- `fpga/vivado/build.tcl`: 합성, 구현, bitstream, XSA export, utilization과 timing 리포트 저장.
- `fpga/sw/`: bare-metal C. 드라이버(`pqc_ntt.h/.c`), 테스트(`main.c`): 내장 벡터(golden이 만든 C 배열 헤더, 외부 벡터의 부분집합 + random + 경계)를 넣고 결과와 CYCLES를 비교해 UART로 연산별 PASS/FAIL, mismatch 수, cycle 수를 출력.
- `fpga/README.md`: 사용자 실행 순서, 기대되는 UART 출력, 돌려받을 것(utilization, timing 리포트, UART 로그).
- ALGO 4종 x (hand RTL, HLS) 비교용 빌드는 Tcl 인자로 선택한다. 빌드 횟수가 많으므로 우선순위를 정해 사용자에게 요청한다.

## 미정
- FCLK 목표 주파수(`ntt_core` 파이프라인 구성과 함께 결정).
- HLS판 `bfu`를 `ntt_core`에 끼우는 방식(P4에서 결정).
