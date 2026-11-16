---
name: eda-tools
description: Use when running Questa, irun (NC), Catapult, Rise, or DC on this server. Covers environment setup, batch commands, and the limits to check before launching a tool.
---

# EDA 툴 실행

툴은 기본 PATH에 없다. 매 Bash 호출마다 환경을 source해야 한다(셸 상태는 호출 간에 유지되지 않음). `R=/home/theo/work/research`이고, 아래 상대 경로(`sim/`, `rtl/`, `hls/`, `syn/`)는 모두 프로젝트 디렉토리(`progress/<project>/`) 기준이다.

```bash
source $R/scripts/env.sh questa   # Questa 2024.2 (+ Catapult 2026.3_1)
source $R/scripts/env.sh hls      # questa와 동일 환경
source $R/scripts/env.sh nc       # Cadence irun / ncverilog
source $R/scripts/env.sh dc       # Synopsys dc_shell W-2024.09  (사용자 승인 후에만 실행)
source $R/scripts/env.sh rise     # Rise (RDA_HOME) + Questa 2025.3
```

`/Tools/env/` 아래 파일에는 라이선스와 계정 정보가 있다. 내용을 출력하거나 저장소·문서·Notion에 옮기지 않는다.

## 실행 전 확인
- 지금 돌고 있는 무거운 프로세스가 2개 미만인가 (`pgrep -u $USER -fa 'vsim|vopt|catapult|irun|dc_shell'`).
- Vivado는 실행하지 않는다. DC는 사용자 승인이 이번 실행에 대해 있었는가.

## Questa (기본 시뮬레이터)
```bash
mkdir -p sim/<name> && cd sim/<name>
source $R/scripts/env.sh questa
vlib work
vlog -sv -lint +incdir+../../rtl ../../rtl/<...>.sv ../../tb/<tb>.sv
vsim -c -voptargs=+acc=npr work.<tb_top> -do "run -all; quit -f" -l run.log
grep -E "PASS|FAIL|Error|mismatch" run.log
```
- C++ golden model과 직접 비교할 때는 DPI-C: `vlog -sv ... model.cpp -ccflags "-O2"`.
- wave는 디버그 때만: `-wlf` 대신 `vcd`/`+acc` 범위를 좁혀서.
- `vsim -c`가 에러로 멈춰 대기하지 않도록 `-do`에 `onerror {quit -f -code 1}`를 넣는다.

## irun (교차 확인)
```bash
source $R/scripts/env.sh nc
irun -64bit -sv -access +r <files> -top <tb_top> -l irun.log
```

## Catapult HLS
```bash
mkdir -p hls/<block>/run && cd hls/<block>/run
source $R/scripts/env.sh hls
catapult -shell -file ../go_hls.tcl 2>&1 | tee catapult.log
```
- Tcl 흐름: `solution file add` -> `go analyze` -> `go compile` -> 라이브러리/클럭 설정 -> `go libraries` -> `go assembly` -> `go architect` -> `go allocate` -> `go extract`.
- downstream 합성 flow(DC, Vivado 호출)는 켜지 않는다. 면적·타이밍은 Catapult 리포트(`rtl.rpt`, `cycle.rpt`) 기준 추정으로만 취급한다.
- 생성 RTL(`concat_rtl.v` / `concat_sim_rtl.v`)은 `hls/<block>/out/`에 복사해 Questa 검증에 쓴다. SCVerify를 쓸 때도 병렬도 제한을 지킨다.
- 코딩과 리뷰 기준은 전역 스킬 `catapult-hls-review`를 참고.

## Rise
- `source $R/scripts/env.sh rise` 후 `$RDA_HOME/bin` 의 도구 사용. 처음 쓸 때 `ls $RDA_HOME/bin`과 `$RDA_HOME`의 문서로 명령을 확인하고, 확인한 사용법을 이 스킬에 추가한다.

## DC
- 스크립트는 `syn/dc/`에 미리 작성해 둔다. 실행은 사용자가 승인한 그 건에 대해서만:
```bash
source $R/scripts/env.sh dc
cd syn/dc/<block> && dc_shell -f run.tcl | tee dc.log
```
- 승인 요청 시 대상 모듈, 라이브러리, 클럭 제약, 예상 소요 시간을 같이 알린다.
