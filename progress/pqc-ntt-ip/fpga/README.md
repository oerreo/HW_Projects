# fpga/: Zybo Z7-20 검증 환경 (P5, G5/G6)

`pqc_ntt_axi_top`(AXI4-Lite 로 감싼 `ntt_core`)을 Digilent Zybo Z7-20 (XC7Z020-1CLG400C) 에 올리고, Zynq PS(ARM Cortex-A9)의 bare-metal 프로그램이 내장 벡터를 넣어 기대값과 비교한다.
이 디렉토리는 **사용자가 자기 환경에서 실행**하는 스크립트와 PS 소프트웨어다. 준비한 머신에서는 Vivado, Vitis, XSCT 를 실행하지 않았다.

## 현재 상태 (2026-11-18)
- RTL 준비 완료. `rtl/l4`(`axil_slave`, `pqc_ntt_csr`, `pqc_ntt_axi_top`)가 AXI BFM 시뮬레이션을 통과했다(ALGO 4종, 외부 벡터 전부 mismatch 0, CYCLES가 식과 일치). 레지스터 맵의 기준 `docs/spec/l4_axi.md`는 확정이다. RTL의 접근 trace를 호스트 레지스터 모델로 재생해 값이 같음을 확인했다.
- 확인한 것: PS 소프트웨어를 레지스터 수준 **소프트웨어 모델**에 대해 호스트(gcc)에서 돌린 결과(아래 "호스트 테스트"), 레지스터 맵 일치 검사(`check_regs.py`), Tcl 스크립트를 Vivado 명령 스텁으로 돌린 문법/변수 검사.
- 확인하지 않은 것: Vivado/Vitis 에서의 실제 동작, 보드 동작. 목록은 맨 아래 "미검증 사항".
- 레지스터 모델은 RTL 이 아니다. 호스트 테스트 통과는 "드라이버, 테스트 프로그램, 벡터, 로그 형식이 **스펙 문서(l4_axi.md + `sw/ASSUMPTIONS.md`)와** 맞는다"는 것만 보증한다. 하드웨어가 스펙대로인지는 L4 RTL 시뮬레이션(AXI BFM)과 보드 실행으로 확인한다.

## 디렉토리
| 경로 | 내용 |
|---|---|
| `vivado/create_project.tcl` | 프로젝트 생성 + block design (PS7, proc_sys_reset, SmartConnect 또는 AXI Interconnect, `pqc_ntt_axi_top` module reference) |
| `vivado/filelist.tcl` | RTL 파일 목록의 유일한 원본 (`rtl/` hand RTL, `IMPL=hls` 이면 L0 HLS 어댑터와 netlist) |
| `vivado/build.tcl` | 합성, 구현, bitstream, XSA, 리포트 |
| `vivado/zybo_z7_20.xdc` | 제약 (PS 만 쓰므로 사실상 비어 있음, 이유는 파일 주석) |
| `vivado/src/pqc_ntt_axi_bd.v` | module reference 용 Verilog shell (int parameter, 표준 AXI 포트 이름) |
| `vivado/test/stub_check.tcl` | tclsh 로 도는 스텁 검사 (동작 검증 아님) |
| `sw/pqc_ntt_regs.h` | 레지스터 offset, 비트 위치, op/ALGO 인코딩의 **유일한** 정의 |
| `sw/pqc_ntt_hal.h`, `sw/pqc_ntt_hal_xil.c` | 하드웨어 접근 2함수 (`reg_read32`, `reg_write32`). 보드는 `Xil_In32`/`Xil_Out32` |
| `sw/pqc_ntt.h`, `sw/pqc_ntt.c` | 드라이버 (load, run, unload, cycles, version, err, recover, 다항식 곱) |
| `sw/main.c` | 테스트 프로그램 (UART 출력) |
| `sw/vectors.h` | 생성된 벡터 헤더 (커밋 대상, 약 460 KB 텍스트, 바이너리로 약 120 KB) |
| `sw/pqc_platform.h` | 출력 함수(`xil_printf`/`printf`)와 base address 선택 |
| `sw/ASSUMPTIONS.md` | 스펙이 정하지 않아 드라이버가 가정한 동작 A1..A25 (L4 스펙 확정의 입력) |
| `sw/xsct_build.tcl` | Vitis(classic) platform, application 생성과 빌드, JTAG 다운로드/실행 |
| `sw/tools/gen_vectors_h.py` | `vectors.h` 생성기 |
| `sw/tools/check_regs.py` | 스펙 표, 헤더, `ntt_l2_pkg.sv`, `mlkem_pkg.sv`, Tcl base address 비교 |
| `sw/tools/parse_uart_log.py` | UART 로그를 결과 표로 |
| `sw/test/` | 호스트 테스트 (`reg_model.c`, `test_driver.c`, `Makefile`, `run.sh`) |
| `results/` | 사용자가 돌려준 리포트와 로그를 두는 곳 (아래 "돌려받을 것") |

## 준비물
- Vivado / Vitis 2019.2 이상 (XSA 와 `write_hw_platform` 이 있는 버전). `xsct_build.tcl` 은 Vitis classic(2019.2 ~ 2023.2)의 명령을 쓴다. 2024.1 이후의 Vitis Unified IDE 는 아래 "Vitis Unified (2024.1 이후)" 절차를 따른다.
- Digilent board files (권장): https://github.com/Digilent/vivado-boards 의 `new/board_files` 를 Vivado 의 `data/boards/board_files` 에 복사하거나 `Vivado_init.tcl` 에서 `set_param board.repoPaths` 로 지정한다. 없으면 스크립트가 part 만 지정하고 PS7 을 수동 설정하는데, DDR 보드 지연값을 넣지 않았으므로 DDR 이 불안정할 수 있다.
- 보드: Zybo Z7-20, micro USB 케이블 1개(PROG/UART 겸용 포트), 전원 선택 점퍼를 USB 또는 외부 전원에 맞게, 부팅 모드 점퍼를 **JTAG** 으로(위치는 Zybo Z7 레퍼런스 매뉴얼).
- 시리얼 터미널: 115200 baud, 8 data bits, no parity, 1 stop bit (8N1), flow control 없음.

## 실행 순서
아래 명령의 `<repo>` 는 이 프로젝트의 최상위(`progress/pqc-ntt-ip`)이다. Vivado 가 만드는 프로젝트는 기본으로 `fpga/vivado/build/<NAME>/` 에 생긴다(커밋 제외).

### 1. 프로젝트와 block design 생성
```
vivado -mode batch -source <repo>/fpga/vivado/create_project.tcl -tclargs ALGO=BARRETT CFG=l2 FCLK_MHZ=100
```
| 인자 | 값 | 기본 |
|---|---|---|
| `ALGO` | `BARRETT`, `MONT12`, `SHIFTADD`, `K2RED` 또는 0..3 | `BARRETT` |
| `IMPL` | `rtl`, `hls` (L0 `mod_mul`/`mod_red` 를 Catapult 결과로 교체, 잠정) | `rtl` |
| `CFG` | bfu 파이프라인 프리셋 (PRE_REG MUL_REG RED_PIPE OUT_REG): `l0` 0000, `l1` 0100, `l2` 0110, `l3` 0111, `l4` 1111, `l5` 1121 | `l0` |
| `PRE_REG`, `MUL_REG`, `RED_PIPE`, `OUT_REG` | 프리셋의 개별 값 덮어쓰기 (이름이 `custom` 이 됨) | |
| `SHARE_ADDSUB`, `ROM_OUT_REG` | 0 또는 1 | 0, 1 |
| `FCLK_MHZ` | FCLK_CLK0 요청값. PS PLL 이 도달 가능한 가장 가까운 값을 고르며 실제 값이 출력되고 `pqc_build_config.txt` 에 남는다 | 100 |
| `BOARD` | `auto`(board files 있으면 사용), `yes`(없으면 오류), `no` | `auto` |
| `INTC` | `smartconnect`, `axi_interconnect` | `smartconnect` |
| `REF_TOP` | `shell`(Verilog shell 을 module reference), `direct`(`pqc_ntt_axi_top` 직접) | `shell` |
| `NAME`, `DIR`, `PART` | 프로젝트 이름, 위치, part | `pqc_<algo>_<impl>_<cfg>_<fclk>m`, `fpga/vivado/build/<NAME>`, `xc7z020clg400-1` |

- `rtl/l4` 가 아직 없으면 소스만 넣은 프로젝트를 만들고 block design 은 건너뛴다(경고 출력). L4 RTL 이 생긴 뒤 다시 실행한다.
- PS7 은 board preset 을 적용한 뒤 UART1(MIO 48/49), M_AXI_GP0, FCLK_CLK0, FCLK_RESET0_N 을 켠다. IP 버전은 고정하지 않고 `get_ipdefs` 로 가장 높은 버전을 고른다.
- IP 의 주소는 0x43C0_0000, 범위 4 KB 로 고정한다(`sw/pqc_ntt_regs.h` 와 같은 값). 스크립트가 다시 읽어 확인한다.

### 2. 빌드와 리포트
```
vivado -mode batch -source <repo>/fpga/vivado/build.tcl -tclargs PROJ=<repo>/fpga/vivado/build/<NAME>/<NAME>.xpr JOBS=4
```
- `JOBS`: launch_runs 의 jobs 와 `general.maxThreads`(최대 8). 사용자 머신에 맞게 정한다.
- `STEP=synth` 이면 합성 리포트까지만 만든다(면적 비교용 빠른 빌드).
- 결과는 `<project dir>/reports/`: `synth_util*.rpt`, `impl_util.rpt`, `impl_util_hier.rpt`(계층별), `impl_timing_summary.rpt`, `impl_timing_paths.rpt`, `impl_power.rpt`, `impl_clocks.rpt`, `impl_drc.rpt`, `impl_methodology.rpt`, `pqc_bd_wrapper.bit`, `pqc_bd_wrapper.xsa`, `summary.txt`(WNS/TNS/WHS/THS, LUT/FF/DSP/BRAM, FCLK 주기), `pqc_build_config.txt`.
- WNS 가 음수이면 경고를 출력한다. 그 bitstream 은 G6 판정에 쓰지 않는다(FCLK 를 낮춰 다시 빌드).

### 3. 소프트웨어 빌드 (Vitis classic, XSCT)
```
xsct <repo>/fpga/sw/xsct_build.tcl XSA=<project dir>/reports/pqc_bd_wrapper.xsa
```
- workspace 는 기본으로 XSA 옆의 `vitis_ws/`. platform `pqc_plat`(standalone, ps7_cortexa9_0, stdin/stdout = ps7_uart_1), application `pqc_ntt_test`(빈 C 템플릿에 `fpga/sw/*.c *.h` 복사, Release, -O2).
- `tools/`, `test/` 아래 파일은 넣지 않는다(`reg_model.c` 는 호스트 전용).
- base address 는 `pqc_ntt_regs.h` 의 0x43C0_0000. 주소를 바꿨다면 컴파일 심볼 `PQC_NTT_BASEADDR=0x...` 로 덮어쓴다.

#### Vitis Unified (2024.1 이후)
XSCT 의 platform/app 명령이 없으므로 GUI 또는 Python API 로 같은 것을 만든다: XSA 로 platform(standalone, ps7_cortexa9_0, stdout ps7_uart_1) 생성, 빈 C application 생성, `fpga/sw/` 최상위의 `.c`, `.h` 를 전부 추가, 빌드. 이 절차는 확인하지 않았다.

### 4. 보드 연결과 실행
1. 부팅 모드 점퍼를 JTAG 으로 두고 PROG/UART USB 를 연결한 뒤 전원을 켠다.
2. 시리얼 터미널을 연다(Linux 는 보통 `/dev/ttyUSB1`, 115200 8N1). 출력 전체를 파일로 저장한다(예: `screen -L`, `minicom -C <file>`, `picocom --logfile <file>`).
3. 다운로드와 실행:
   ```
   xsct <repo>/fpga/sw/xsct_build.tcl XSA=<...>.xsa RUN=1
   ```
   PL 프로그래밍, `ps7_init`, ELF 다운로드, 실행 순서다. GUI 로 할 때는 Vitis 의 하드웨어 실행(Launch Hardware) 메뉴를 쓴다.
4. 로그가 `PQCNTT END` 로 끝나면 완료다. 전체 133줄 정도, 115200 baud 에서 수 초.

## UART 출력 형식
한 줄에 한 항목, `KEY k=v k=v ...` 형식이다. 값에는 공백이 없다. 줄 끝은 `\r\n`. `PQCNTT BEGIN` 과 `PQCNTT END` 사이만 해석한다(그 밖의 부팅 메시지는 무시). 숫자는 10진, `0x` 로 시작하면 16진.

| KEY | 필드 | 의미 |
|---|---|---|
| `PQCNTT BEGIN` | `fmt` | 로그 형식 버전 (현재 1) |
| `INFO` | 자유 | 참고값 (base, 벡터 수, 시작 시 ERR, 비활성 DOUT 읽기 값) |
| `VERSION` | `raw id id_ok algo algo_name bfu_latency` | VERSION 레지스터. `id_ok=0` 이면 `ABORT reason=version` 후 `RESULT: FAIL` |
| `EXPECT` | `op cycles` | VERSION 의 ALGO, BFU_LATENCY 로 계산한 기대 cycle (arch.md "L2 결과 반영"의 식). POLYMUL 은 NTT x2 + BASEMUL + INTT 의 합 |
| `CHECK` | `name result val` | 레지스터 수준 검사 (ERR 비트 3종, W1C, busy 중 start, done_sticky clear, bank 왕복) |
| `CASE` | `op idx name rc mismatch cycles exp_cycles cycles_ok` | 벡터 하나의 결과. `rc` 는 드라이버 반환값(`OK`, `ERR_TIMEOUT`, `ERR_HW`, `ERR_STATE`, `ERR_BUSY`, `ERR_ARG`) |
| `MISMATCH` | `op idx coef exp got` | 틀린 계수. 케이스당 처음 4개, 전체 64개까지만 출력 |
| `SUMMARY` | `op cases fail_cases mismatch cycle_bad errors result` | 연산별 합계. op 는 `CHECK`, `NTT`, `INTT`, `BASEMUL`, `POLYMUL` |
| `ABORT` | `reason` | 중단 (`version`, 드라이버 오류 8회 이상이면 `driver_errors`) |
| `RESULT:` | `PASS` 또는 `FAIL` | 최종 판정. 모든 SUMMARY 가 PASS 이고 VERSION ID 가 맞을 때만 PASS |
| `PQCNTT END` | | 로그 끝 |

- 케이스 실패 조건: 드라이버 오류, 계수 mismatch 1개 이상, 또는 CYCLES 가 기대값과 다름. **cycle 불일치도 FAIL** 이다(l4_axi.md "CYCLES 는 시뮬레이션 실측값과 보드에서 같아야 한다").
- 케이스 이름: `ext_<op>_<파일 인덱스>_<파라미터 셋>_<ACVP 함수>_tc<tcId>` (외부 벡터), `dir_<이름>` (방향성), `rnd_s<시드>_<번호>` (golden random).

### 기대 출력 예시
호스트 테스트(ALGO = MONT12, BFU_LATENCY = 2 로 설정한 레지스터 모델)의 실제 출력에서 발췌했다. 보드 출력이 아니다.
```
PQCNTT BEGIN fmt=1
INFO base=0x43c00000 vectors_ntt=30 vectors_intt=30 vectors_basemul=30 vectors_polymul=10
VERSION raw=0x4e540201 id=0x4e54 id_ok=1 algo=1 algo_name=MONT12 bfu_latency=2
EXPECT op=NTT cycles=918
EXPECT op=INTT cycles=918
EXPECT op=BASEMUL cycles=2691
EXPECT op=POLYMUL cycles=5445
INFO err_at_start=0x0
CHECK name=err_clear_all result=PASS val=0x0
CHECK name=idle_at_start result=PASS val=0x0
CHECK name=err_din_idle result=PASS val=0x2
...
CHECK name=err_zero_after_checks result=PASS val=0x0
SUMMARY op=CHECK cases=16 fail_cases=0 mismatch=0 cycle_bad=0 errors=0 result=PASS
CASE op=NTT idx=0 name=ext_ntt_0_mlkem512_keygen_tc1 rc=OK mismatch=0 cycles=918 exp_cycles=918 cycles_ok=1
CASE op=NTT idx=1 name=ext_ntt_95_mlkem512_keygen_tc24 rc=OK mismatch=0 cycles=918 exp_cycles=918 cycles_ok=1
...
SUMMARY op=NTT cases=30 fail_cases=0 mismatch=0 cycle_bad=0 errors=0 result=PASS
CASE op=INTT idx=0 name=ext_intt_0_mlkem512_encap_tc1 rc=OK mismatch=0 cycles=918 exp_cycles=918 cycles_ok=1
...
SUMMARY op=INTT cases=30 fail_cases=0 mismatch=0 cycle_bad=0 errors=0 result=PASS
CASE op=BASEMUL idx=0 name=ext_basemul_0_mlkem512_keygen_tc1 rc=OK mismatch=0 cycles=2691 exp_cycles=2691 cycles_ok=1
...
SUMMARY op=BASEMUL cases=30 fail_cases=0 mismatch=0 cycle_bad=0 errors=0 result=PASS
CASE op=POLYMUL idx=0 name=dir_all_zero rc=OK mismatch=0 cycles=5445 exp_cycles=5445 cycles_ok=1
...
SUMMARY op=POLYMUL cases=10 fail_cases=0 mismatch=0 cycle_bad=0 errors=0 result=PASS
RESULT: PASS
PQCNTT END
```
틀린 계수가 있으면 (호스트 테스트의 결함 주입 실행에서 발췌):
```
MISMATCH op=NTT idx=3 coef=17 exp=0x6b2 got=0x6b3
CASE op=NTT idx=3 name=ext_ntt_171_mlkem512_decap_tc81 rc=OK mismatch=1 cycles=918 exp_cycles=918 cycles_ok=1
```
VERSION ID 가 다르면(비트스트림 없음, 주소 틀림, 헤더와 RTL 불일치):
```
VERSION raw=0x4e550201 id=0x4e55 id_ok=0 algo=1 algo_name=MONT12 bfu_latency=2
ABORT reason=version
RESULT: FAIL
```

### 로그 해석
```
python3 <repo>/fpga/sw/tools/parse_uart_log.py uart.log            # Markdown 표
python3 <repo>/fpga/sw/tools/parse_uart_log.py --csv results/*/uart.log  # 여러 빌드를 CSV 로
```
파서는 CASE/CHECK 줄에서 SUMMARY 를 다시 계산해 프로그램의 합계와 맞는지 확인한다. 종료 코드: 0 PASS, 1 FAIL, 2 INCOMPLETE(END 나 RESULT 없음, 합계 불일치, 잘린 로그). 로그에 실행이 여러 번 있으면 마지막 실행을 쓴다.

## 돌려받을 것과 놓을 위치
빌드 하나마다 `fpga/results/<YYYY-MM-DD>_<NAME>/` (예: `2026-11-20_pqc_barrett_rtl_l2_100m/`) 에 아래를 넣어 준다.
| 파일 | 출처 | 필수 |
|---|---|---|
| `pqc_build_config.txt` | `reports/` | 필수 (구성, 실제 FCLK, Vivado 버전) |
| `summary.txt` | `reports/` | 필수 |
| `impl_timing_summary.rpt` | `reports/` | 필수 |
| `impl_util.rpt`, `impl_util_hier.rpt` | `reports/` | 필수 |
| `synth_util_hier.rpt` | `reports/` | 필수 |
| `impl_power.rpt` | `reports/` | 있으면 |
| `impl_drc.rpt`, `impl_methodology.rpt`, `impl_timing_paths.rpt` | `reports/` | 있으면 |
| `uart.log` | 시리얼 터미널 저장 파일 (가공하지 않은 원본) | 보드를 돌린 빌드는 필수 |
| `notes.txt` | Vivado/Vitis 버전, board files 사용 여부, 경고나 수동으로 바꾼 것 | 있으면 |

bitstream, XSA, 프로젝트 디렉토리는 넣지 않는다(용량, 재생성 가능).

## 비교 빌드와 우선순위 제안
전체 매트릭스(ALGO 4 x hand RTL/HLS x 파이프라인 6 프리셋 x SHARE_ADDSUB 2)는 96 빌드라 많다. 보드 실행이 필요한 빌드와 리포트만 필요한 빌드를 나눈다.

| 순위 | 빌드 | 개수 | 보드 실행 | 목적 |
|---|---|---|---|---|
| 1 | `ALGO=BARRETT IMPL=rtl CFG=l2 FCLK_MHZ=100` | 1 | 예 | bring-up. 통합 문제(주소, 클럭, reset, UART, 드라이버 가정 A1..A25)를 먼저 해결 |
| 2 | 나머지 3 ALGO, 같은 CFG, FCLK | 3 | 예 | G6: 4 ALGO 모두 mismatch 0, CYCLES 일치 |
| 3 | 4 ALGO x `CFG=l0`, `l4` (`STEP=synth` 후 timing 이 필요하면 전체) | 8 | 아니오 | 파이프라인 깊이에 따른 면적과 slack. Fmax 비교는 같은 FCLK 의 WNS 로 본다 |
| 4 | 4 ALGO x `IMPL=hls`, 순위 2 와 같은 CFG | 4 | 1개 이상 | hand RTL 대 HLS. P4 에서 HLS bfu 통합 방식이 정해진 뒤 (지금은 L0 교체만) |
| 5 | `SHARE_ADDSUB=1`, 나머지 프리셋, FCLK sweep | 필요 시 | 아니오 | 논문 표 보강 |

- 1차 요청은 순위 1 하나다. 그 결과로 FCLK 기본값과 CFG 기본값(l4_axi.md "미정")을 정한 뒤 순위 2, 3 을 한 번에 요청한다.
- FCLK 는 비교 빌드끼리 같게 둔다(PS PLL 이 정확히 맞추지 못하면 실제 값이 `pqc_build_config.txt` 에 남는다).

## 호스트 테스트 (이 머신에서 가능)
```
make -C fpga/sw/test test        # 빌드 + 전체 실행, 마지막 줄 HOSTTEST RESULT: PASS
make -C fpga/sw/test vectors-h   # vectors.h 재생성 (model/ make vectors 를 fpga/sw/build/model_vec 로)
```
`run.sh` 가 순서대로 실행하는 것:
1. `check_regs.py` 와 그 자체 검사(헤더를 9가지로 변형해 각각 검출되는지).
2. `t_main`(= `main.c` + 드라이버 + 레지스터 모델 + golden model)을 ALGO 4종 x BFU_LATENCY {0, 2, 5} = 12번. 모두 `RESULT: PASS`, 파서 PASS 여야 한다.
3. 결함 주입(`data`, `cycles`, `version`, `rbank`)으로 `t_main` 을 돌려 모두 FAIL 과 파서 FAIL 이 나오는지(비교가 헛돌지 않음을 확인).
4. 잘린 로그는 INCOMPLETE, CRLF 와 부팅 메시지가 섞인 로그는 PASS 인지.
5. `t_drv`: 음성/경계 테스트 26개(ERR 3비트와 W1C, busy 중 start, 오래된 ERR 보고, 인자 검사 시 레지스터 미접근, 잘못된 op 와 hang/stall 타임아웃, LOAD/UNLOAD 중간 복구, result_bank 검사, done_sticky clear, bank 왕복, NTT cycle, STATUS polling 이 실제로 not-ready 를 본 횟수).
6. `vivado/test/stub_check.tcl` (tclsh 가 있으면).

레지스터 모델(`test/reg_model.c`)은 l4_axi.md 와 `ASSUMPTIONS.md` 대로 동작하고, 연산 결과는 golden model 의 하드웨어 구조 함수(`mlkem_dpi_hw_ntt`/`_intt`/`_basemul`, ALGO 별)로 계산한다. 접근마다 1..10 cycle, `in_ready`/`out_valid` 는 임의 지연 후 1이 되게 해서 polling 경로를 탄다. CYCLES 는 arch.md 의 식을 드라이버와 별도로 다시 적어 계산하지만, 같은 식이므로 "보드 CYCLES 가 맞는지"는 이 테스트로 알 수 없다.

## 벡터 (`sw/vectors.h`)
- 연산당: 외부 벡터 16(`data/vectors/ext`, ACVP 에서 추출, 기대값은 파일의 FIPS 203 값) + 방향성 6(전부 0, 전부 q-1, 임펄스 3종, 전부 1) + golden random 8(시드 17, 전 범위). POLYMUL 은 방향성 6 + random 4(외부 데이터에 다항식 곱이 없음).
- NTT 외부 벡터는 절반을 전 범위 입력(decapsulation u')에서 고른다(나머지 대부분이 CBD 잡음 |x| <= 3 이라서).
- ALGO 와 무관하게 한 벌이다(IP 계약: 모든 ALGO 가 FIPS 203 과 bit-exact). 호스트 테스트가 이 기대값을 golden model 의 ALGO 4종 하드웨어 구조 계산과 대조했다(12 구성 x 100 케이스 mismatch 0).
- golden random 입력은 연산 사이에 같은 다항식을 쓴다(`make vectors` 의 random case 가 NTT/INTT/MultiplyNTTs/polymul 에서 같은 PRNG 순서를 쓰기 때문).
- 개수 조절: `make -C fpga/sw/test vectors-h VEC_ARGS="--n-ext 32 --n-random 16" VEC_COUNT=16`(VEC_COUNT 는 random 개수 이상).

## 레지스터 맵을 바꿀 때
1. `docs/spec/l4_axi.md` 의 표를 고친다(스펙이 원본).
2. `sw/pqc_ntt_regs.h` 만 고친다. 다른 파일에는 offset 이나 비트 위치가 없다(`pqc_ntt_expected_cycles()` 의 cycle 식은 arch.md 기준).
3. op 인코딩은 `rtl/l2/ntt_l2_pkg.sv`, ALGO 는 `rtl/pkg/mlkem_pkg.sv` 가 원본이다.
4. `python3 fpga/sw/tools/check_regs.py` 가 PASS 인지, `make -C fpga/sw/test test` 가 PASS 인지 확인한다. base address 를 바꾸면 `create_project.tcl` 의 `PQC_BASEADDR` 도 같이 바꾼다(검사 대상).
5. 동작 가정이 바뀌면 `sw/ASSUMPTIONS.md` 와 `sw/test/reg_model.c` 를 함께 고친다.

## 미검증 사항
Vivado, Vitis, 보드에서 한 번도 실행하지 않았다. 아래는 특히 실패 가능성이 있는 곳이며, 스크립트에는 `UNVERIFIED` 주석과 확인 방법이 있다.
1. module reference: SV top 을 직접 참조할 수 없다는 전제(그래서 Verilog shell 사용)와, shell 의 포트/파라미터 이름이 실제 `pqc_ntt_axi_top` 과 맞는지(A22). L4 RTL 이 생기면 shell 인스턴스를 맞춘다.
2. `s_axi_*` 포트에서 AXI4-Lite 인터페이스와 `aclk`/`aresetn` 연관이 자동 추론되는지.
3. board part 이름 패턴 `*zybo-z7-20*`, PS7 automation 의 옵션, PS7 CONFIG 속성 이름(`PCW_UART1_BAUD_RATE`, `PCW_ACT_FPGA0_PERIPHERAL_FREQMHZ` 등). 모르는 속성은 경고만 내고 진행한다.
4. board files 없는 경로의 PS7 수동 설정(DDR3L 파트, 버스 폭, 지연값 미설정). DDR 이 불안정하면 board files 를 설치한다.
5. 주소 segment 조회 방식(`get_bd_addr_segs` 필터)과 offset 설정. 스크립트가 읽어서 확인하므로 틀리면 오류로 멈춘다.
6. `write_hw_platform`(2019.2 이상), run 상태 문자열(`PROGRESS`, `STATUS`), `report_methodology`.
7. XSCT: 기본 domain 이름, 템플릿 이름(2022.1 전후), `bsp config stdout ps7_uart_1`, JTAG target 필터 문자열, `ps7_init.tcl` 위치. Vitis 2024.1 이후는 수동 절차.
8. `xil_printf` 로 출력한 형식(`%d %x %s` 만 사용)이 호스트 `printf` 와 같은지.
9. GP0 영역이 device 메모리로 매핑되어 DOUT 읽기가 정확히 한 번씩 나가는지(A18), 접근 순서(A25).
10. FCLK 100 MHz 에서 timing 이 맞는지(구성별로 다름, CFG 기본값 미정).
11. 보드 CYCLES 가 arch.md 의 식과 같은지(카운터 정의 A12). 다르면 RTL 정의와 드라이버 식 중 무엇을 고칠지 스펙에서 정한다.
12. `IMPL=hls` 의 L0 교체(어댑터 `.*` 연결, Catapult netlist)가 Vivado 합성에서 그대로 되는지. HLS bfu 통합 방식은 P4 결정 사항.
13. `ntt_core` 와 `pqc_ntt_axi_top` 의 RTL 시뮬레이션(AXI BFM, G4 의 L4 부분)이 아직 없다. 보드 전에 그것이 먼저다(project-flow.md).
