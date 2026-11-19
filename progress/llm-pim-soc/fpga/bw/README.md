# fpga/bw: HP 포트 대역폭 측정 빌드 (S4-3, 사용자 실행용)

`rtl/l3/bw_top.sv`(AXI-Lite CSR + HP read/write engine x P)를 Zybo Z7-20 (XC7Z020-1CLG400C)에 올리고, PS(ARM)의 bare-metal 프로그램이 burst 길이, outstanding 수, 포트 수, 크기를 바꿔 가며 read/write 대역폭(MB/s)을 재고 checksum과 쓴 내용을 ARM 쪽 계산과 비교한다. 레지스터 맵과 시간 정의는 `docs/spec/bwtest.md`.

이 디렉토리의 Tcl과 PS 프로그램은 **준비한 머신에서 Vivado, Vitis, XSCT로 실행하지 않았다(UNVERIFIED)**. 확인한 것은 RTL 시뮬레이션(`sim/tests/bw_top.cfg` 등)과 아래 "준비 머신에서 한 검사"뿐이다.

## 파일
| 경로 | 내용 |
|---|---|
| `create_project.tcl` | 프로젝트 + block design: PS7(GP0, HP0, P = 2면 HP2, FCLK0), proc_sys_reset, interconnect 3개(제어 1, HP 포트마다 1), `bw_bd` module reference, 주소(CSR 0x43C00000, HP DDR segment 확인) |
| `filelist.tcl` | RTL 파일 목록(시뮬레이션과 같은 5개 + shell) |
| `build.tcl` | 합성, 구현, bitstream, XSA, 리포트(`reports/`), `summary.txt` |
| `zybo_z7_20.xdc` | 제약(PS 핀만 쓰므로 비어 있음, 이유는 파일 주석) |
| `src/bw_bd.v` | module reference용 Verilog shell(`s_axi`, `m00_axi`, `m01_axi`, `aclk`, `aresetn`) |
| `sw/bw_main.c` | 측정 프로그램(sweep, 검사, UART 출력) |
| `sw/bw_regs.h` | 레지스터 offset, 비트, 버퍼 주소(`bwtest.md`와 같은 값) |
| `sw/bw_hal.h`, `sw/bw_hal_xil.c` | 플랫폼 계층(보드: `Xil_In32/Out32`, cache, global timer, `outbyte`) |
| `sw/xsct_build.tcl` | Vitis classic platform + app 빌드, JTAG 다운로드/실행 |
| `test/` | 준비 머신용 검사(호스트 모델 `bw_hal_host.c`, stub 헤더, `Makefile`, `run.sh`, `stub_check.tcl`) |

## 준비물
- Vivado / Vitis 2019.2 이상(`write_hw_platform`). `xsct_build.tcl`은 Vitis classic(2019.2 ~ 2023.2) 명령이다. 2024.1 이후 Vitis Unified에서는 XSA로 platform(standalone, ps7_cortexa9_0, stdout ps7_uart_1)과 빈 C application을 만들고 `sw/*.c *.h`를 넣은 뒤 컴파일러 심볼 `FCLK_HZ=<실제 FCLK Hz>u`를 정의한다.
- Digilent board files 권장(pqc-ntt-ip `fpga/README.md`의 준비물과 같음). 없으면 PS7을 수동 설정하는데 DDR 보드 지연값이 없어 불안정할 수 있다.
- 보드: Zybo Z7-20, micro USB(PROG/UART), 부팅 모드 점퍼 JTAG. 터미널 115200 8N1.

## 실행 순서
`<repo>`는 프로젝트 최상위(`progress/llm-pim-soc`).

### 1. 프로젝트와 block design
권장 빌드 하나로 포트 1개/2개, burst 1..16, outstanding 1..8을 모두 잰다(포트 수와 한도는 런타임 레지스터).
```
vivado -mode batch -source <repo>/fpga/bw/create_project.tcl -tclargs P=2 MAX_BURST=16 OUTS=8
```
| 인자 | 값 | 기본 |
|---|---|---|
| `P` | 1, 2 (2면 HP0과 HP2) | 1 |
| `MAX_BURST` | 1..256 (16 초과는 interconnect가 AXI3 burst로 나눔) | 16 |
| `OUTS` | 1..64 | 4 |
| `FCLK_MHZ` | FCLK_CLK0 요청값. 실제 값은 끝에 출력되고 `bw_build_config.txt`에 남는다 | 100 |
| `BOARD` | `auto`, `yes`, `no` | `auto` |
| `INTC` | `smartconnect`, `axi_interconnect` | `smartconnect` |
| `NAME`, `DIR`, `PART` | | `bw_p<P>_b<MAX_BURST>_o<OUTS>_<fclk>m`, `fpga/bw/build/<NAME>`, `xc7z020clg400-1` |

선택 빌드(긴 AXI4 burst를 interconnect가 나눌 때의 효과): `P=2 MAX_BURST=256 OUTS=4`.

### 2. 합성, 구현, bitstream, XSA
```
vivado -mode batch -source <repo>/fpga/bw/build.tcl -tclargs PROJ=<repo>/fpga/bw/build/bw_p2_b16_o8_100m/bw_p2_b16_o8_100m.xpr
```
`reports/summary.txt`의 `wns`가 음수면 timing 미달이다. 그 bitstream으로 측정하지 말고 결과 파일만 보내 달라.

### 3. PS 프로그램 빌드와 실행
```
xsct <repo>/fpga/bw/sw/xsct_build.tcl XSA=<reports>/bw_bd_sys_wrapper.xsa FCLK_HZ=<실제 FCLK Hz> RUN=1
```
- `FCLK_HZ`: 1단계 끝의 "actual ... MHz" 값(Hz, 정수). MB/s 계산에만 쓰인다(CYCLES는 PL 클럭 기준).
- 터미널을 먼저 연다. 끝은 `BWTEST END`. 예상 시간: sweep A 120 run(1 MiB), sweep B 72 run(최대 8 MiB) [추정: 수 초 ~ 수십 초].

### 4. 기대 출력 (형식, 값은 예시가 아님)
```
BWTEST START plat=xil fclk_hz=100000000 quick=0
BWCFG id=0x42570001 config=0x01008264 p=2 outs=8 max_burst=16 fclk_mhz_cfg=100
BWNEG case=len0 err=0x04 exp=0x04 chk=OK          (4줄)
BW run=1 op=RD ports=1 len=1048576 burst=1 outs=1 cyc=... rcyc0=... ... mbps10=... t_us=... err=0x00 chk=OK
...
BWTEST summary runs=192 fails=0 ops=192
BWTEST RESULT: PASS
BWTEST END
```
`chk`가 OK가 아닌 run이 있으면 `RESULT: FAIL`이다. 원인 이름은 `docs/spec/bwtest.md` 5절.

## 돌려받을 것
`fpga/results/<날짜>_bw_<빌드이름>/` 아래:
1. `uart.log`: UART 출력 전체(가공하지 않은 원본).
2. `reports/summary.txt`, `impl_util.rpt`, `impl_util_hier.rpt`, `impl_timing_summary.rpt`, `bw_build_config.txt`.
3. `notes.txt`: Vivado/Vitis 버전, board files 사용 여부, 실행 중 경고나 이상, 다른 빌드 인자를 썼으면 그 값.

## 준비 머신에서 한 검사 (2026-11-19)
| 검사 | 명령(프로젝트 최상위에서, 실제로는 작업 파일로 실행) | 결과 |
|---|---|---|
| RTL 시뮬레이션 | `export T=bw_top; ./sim/run.sh` (engine은 `axi_rd_eng`, `axi_wr_eng`, `axil_slave`) | PASS(`sim/bw_top/`) |
| shell elaboration | Questa `vlog -lint=full` + `vopt -lint=full`, `bw_bd` P = 1, 2 | 경고 0 |
| PS 프로그램 | `cd fpga/bw/test && make test`: `bw_hal_xil.c`, `bw_main.c` stub 헤더 `-fsyntax-only`; 호스트 모델(`bw_hal_host.c`)로 축소 sweep 64비트/`-m32`, 결함 6종 주입 시 FAIL | HOSTTEST 11/11 |
| Tcl | `cd fpga/bw/test && make stub`: Vivado/XSCT 명령 stub으로 3개 스크립트 17 시나리오 | STUBCHECK 17/17 |

호스트 모델은 `bwtest.md`를 보고 C로 쓴 레지스터 동작이며 RTL이 아니다. 통과는 프로그램의 흐름, 검사, 출력 형식이 스펙 문서와 맞는다는 것만 보인다.

## 미검증 사항 (UNVERIFIED)
- Vivado: `processing_system7` 속성 이름(`PCW_USE_S_AXI_HP0/2`, `PCW_S_AXI_HPn_DATA_WIDTH`, `PCW_ACT_FPGA0_PERIPHERAL_FREQMHZ`), PS7 automation 규칙, SystemVerilog 하위 모듈을 가진 Verilog shell의 module reference, `m01_axi`를 연결하지 않은 P = 1 빌드의 validate 결과, HP DDR segment 이름(`*DDR*`)과 범위, interconnect의 AXI4->AXI3 변환과 burst 분할, 100 MHz timing.
- XSCT/Vitis: platform/app 명령, `define-compiler-symbols` 옵션 이름, JTAG target 필터, `ps7_init` 경로.
- Xilinx BSP: `Xil_DCacheFlushRange`/`Xil_DCacheInvalidateRange`의 L2 처리와 비정렬 범위 처리, `XTime_GetTime`, `outbyte`.
- 보드: DDR 버퍼 주소(0x10000000 ~ 0x17FFFFFF)가 프로그램 이미지와 겹치지 않는다는 가정(기본 링커 스크립트의 DDR 시작 0x00100000, 프로그램은 수십 KB [추정]).
- HP 포트의 실제 latency, outstanding 수용량, 포트 2개 동시 대역폭(측정 대상).
