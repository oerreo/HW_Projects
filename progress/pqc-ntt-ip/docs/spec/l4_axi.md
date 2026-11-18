# L4 스펙: pqc_ntt_axi_top와 FPGA 검증 환경

상태: 레지스터 동작 확정 (2026-11-17, P5 준비 작업의 `fpga/sw/ASSUMPTIONS.md` A1~A25를 검토해 반영). RTL은 `ntt_core`(P3-3) 통과 후 작성한다. 표준 흐름의 G5, G6에 해당한다.

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
| 0x18 | ERR | R/W1C | bit0 `start_busy` busy 중 start, bit1 `din_notready` `in_ready` 아닐 때 DIN 쓰기, bit2 `dout_notvalid` `out_valid` 아닐 때 DOUT 읽기, bit3 `bad_op` 정의되지 않은 op로 start, bit4 `din_range` DIN 값이 q 이상 |
| 0x1C | CONFIG | R | 빌드 구성: bit0 `impl`(0 hand RTL, 1 HLS), bit1 `share_addsub`, bit2 `rom_out_reg`, bit3 `pre_reg`, bit4 `mul_reg`, bit[6:5] `red_pipe`, bit7 `out_reg`, bit[23:16] `fclk_mhz`(빌드 parameter) |

- DIN 쓰기와 DOUT 읽기를 스트림 handshake로 바꾸는 방식(쓰기 채널을 `in_ready`까지 잡아 둘지, ERR만 세울지)은 구현 전에 확정한다. v1 기본은 "잡아 두지 않고 ERR". PS 프로그램이 STATUS를 보고 쓴다.
- CYCLES는 시뮬레이션 실측값(`arch.md`의 식)과 보드에서 같아야 한다. 보드 검증 항목에 포함한다.

## 확정한 동작 (ASSUMPTIONS 검토 결과)
- 순서: CTRL에 start(op = LOAD)를 쓴 뒤 DIN을 쓴다. `in_ready`가 아닐 때의 DIN 쓰기는 버리고 `din_notready`를 세운다. DIN 쓰기 한 번이 스트림 handshake 한 번이다.
- `in_ready`는 LOAD가 진행 중이고 코어가 받을 수 있는 동안 1, `out_valid`는 UNLOAD 중 읽을 계수가 있는 동안 1. `out_valid`가 아닐 때 DOUT 읽기는 0을 돌려주고 `dout_notvalid`를 세운다.
- `done_sticky`는 op 완료 시 세워지고 CTRL 쓰기마다 clear된다. 완료 판정은 `busy`가 아니라 `done_sticky`로 한다. 완료와 CTRL 쓰기가 같은 cycle에 겹치면 CTRL 쓰기(clear)가 우선하고, 그 start는 `busy`가 내려간 cycle이므로 수락된다.
- busy 중 start: 무시하고 `start_busy`. 정의되지 않은 op: 아무 동작 없이 `bad_op`(`busy`도 `done_sticky`도 변하지 않음).
- DIN 값이 q 이상: 하위 12비트를 그대로 넣고 `din_range`를 세운다(하드웨어는 값을 고치지 않는다. 드라이버가 사전 검사).
- WSTRB는 무시한다(AXI4-Lite slave는 strobe를 무시할 수 있다). 모든 쓰기는 32비트 전체로 취급.
- 정의되지 않은 주소: 읽기 0, 쓰기 무시, 응답은 OKAY. 쓰기 전용 레지스터(CTRL, DIN) 읽기는 0.
- CYCLES 정의: `ntt_core`가 `start_i`를 수락한 cycle부터 `done_o`가 1인 cycle까지의 clock 수. `arch.md` "L2 결과 반영"의 실측식과 같아야 한다. CSR이 start pulse를 레지스터로 한 번 거치더라도 카운터는 코어의 수락 시점에서 시작하므로 식과 차이가 없어야 하며, L4 TB가 이를 검사한다. LOAD와 UNLOAD의 CYCLES는 PS의 접근 속도에 의존하므로 비교 대상이 아니다.
- abort와 soft reset은 v1에 없다. 모든 op는 유한 시간에 끝나고, 중단된 LOAD/UNLOAD는 드라이버가 남은 계수를 채우거나 읽어 끝낸다.
- reset 값: 모든 레지스터 0(VERSION, CONFIG 제외), RAM 내용은 정의하지 않는다.
- top 모듈: `pqc_ntt_axi_top`(SystemVerilog, 프로젝트 명명 규칙의 `_i`/`_o` 포트, int parameter). Vivado block design에는 표준 AXI 포트 이름을 가진 Verilog shell(`fpga/vivado/src/pqc_ntt_axi_bd.v`)로 넣는다.
- 이 절과 `fpga/sw/pqc_ntt_regs.h`, `fpga/sw/ASSUMPTIONS.md`가 다르면 이 문서가 기준이다. L4 RTL 작업에서 헤더와 호스트 모델에 `bad_op`, `din_range`, CONFIG를 반영한다.

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

## L4 구현 결과 반영 (2026-11-18, P5-1)
- 모듈: `axil_slave`(AXI4-Lite 채널 처리, 레지스터 맵을 모름), `pqc_ntt_csr`(레지스터와 스트림 변환), `pqc_ntt_axi_top`(인스턴스와 배선). AXI 입력에서 코어로 가는 조합 경로는 없다.
- 타이밍: handshake cycle c, 레지스터 접근 c+1, 응답 c+2. DOUT pop은 읽기 수행 cycle에 한 번만 일어나고 R 채널이 막혀도 반복되지 않는다. 같은 cycle의 읽기는 그 cycle의 쓰기 전 상태를 본다.
- 구현 중 확정한 세부(위 "확정한 동작"의 보충):
  - 정의되지 않은 op로 start한 CTRL 쓰기는 `done_sticky`를 지우지 않는다. busy 중이면 `start_busy`와 `bad_op`가 함께 선다.
  - `din_range`는 받아들여진 DIN만 대상이다(bit[11:0] 기준). 버려진 쓰기는 `din_notready`만 세운다.
  - 같은 cycle에 같은 ERR 비트의 set과 W1C가 겹치면 set이 남는다.
  - `done_sticky`와 CYCLES는 done 다음 cycle부터, `result_bank`는 done cycle부터 보인다.
  - 주소 bit[1:0]은 무시한다. CONFIG의 `fclk_mhz`는 정수(1..255).
- 실측 CYCLES는 `arch.md`의 식과 모든 구성에서 일치(L = 0: NTT/INTT 904, BASEMUL 643 또는 899).
