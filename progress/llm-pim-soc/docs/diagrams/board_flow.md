# 사용자 보드 절차 (S5-5, 빌드 A/P)

- 원본과 확인일: 2026-11-23. `fpga/sys/README.md` 4절(4.3 실행 순서, 4.4 측정 순서, 4.5 돌려받을 것), `fpga/sys/create_project.tcl`, `build.tcl`, `sw/xsct_build.tcl`.
- **UNVERIFIED: `create_project.tcl`, `build.tcl`, `xsct_build.tcl`은 Vivado와 XSCT에서 한 번도 실행하지 않았다.** 확인한 것은 Tcl stub 검사(`STUBCHECK runs=43 fail=0`, [측정, 수퍼바이저 재실행])와 shell lint 9구성 경고 0(agent 보고)뿐이다. 속성 이름, module reference 추론, 합성 결과, 100 MHz timing, BRAM parity 매핑은 전부 미확인이다(README 4.10절).
- 이 절차는 사용자가 Vivado와 보드로 수행한다. 이 서버에서는 Vivado를 실행하지 않는다.

```mermaid
flowchart TD
    start(["사용자 보드 절차<br/>빌드 A와 P 각각 1~4단계 (UNVERIFIED: 스크립트 미실행)"]):::unv
    prep["준비물: Vivado/Vitis 2019.2 이상, Digilent board files 권장<br/>데이터 fetch.sh, 260K 배열 (make -C fpga/sw/test data)<br/>보드 Zybo Z7-20, JTAG 점퍼, UART 115200 8N1"]
    s1["1. create_project.tcl<br/>-tclargs BUILD=A 또는 BUILD=P<br/>프로젝트 + block design, 주소 / DDR segment 검사<br/>출력: sys_build_config.txt, 실제 FCLK"]:::unv
    s2["2. build.tcl<br/>-tclargs PROJ=...xpr<br/>합성, 구현, bitstream, XSA, 리포트"]:::unv
    judge{"3. reports/summary.txt<br/>timing_met yes ?<br/>(WNS >= 0 그리고 WHS >= 0)"}
    fail["timing 미달 또는 구현 실패<br/>측정하지 않는다<br/>reports/ 와 notes.txt만 반환"]:::stop
    impl_fail["BRAM 부족 등 구현 실패이면<br/>STEP=synth 로 합성 리포트만 (synth_util*.rpt, synth_ram_cells.txt)"]:::stop
    s3["4. sw/xsct_build.tcl<br/>XSA=reports/sys_bd_wrapper.xsa<br/>FCLK_HZ = 실제 FCLK (Hz)<br/>RUNS, STEPS, MODELS, LIST"]:::unv
    smoke["측정 1. smoke (A, P)<br/>RUNS=K STEPS=4 LIST=0,ff<br/>-> uart_smoke.log<br/>SYS 줄(slot, ID/CONFIG), KCMP, token/hash"]
    pilot["측정 2. pilot (A, P)<br/>RUNS=E LIST=0<br/>-> uart_pilot.log<br/>mask 0 위치당 시간으로 본 측정 길이 판단"]
    main["측정 3. 본 측정<br/>A: MODELS=12, P: MODELS=1<br/>기본 RUNS=ETPK, 기본 mask 목록<br/>-> uart.log (길면 uart_e.log + uart_tpk.log)"]
    ret["돌려받을 것 (빌드마다 fpga/results/날짜_sys_빌드이름/)<br/>1. uart 로그 원본 (smoke, pilot, 본 측정)<br/>2. reports/: summary.txt, sys_build_config.txt,<br/>impl_util*.rpt, impl_ram_cells.txt, impl_dsp_cells.txt,<br/>impl_timing_*.rpt, impl_drc.rpt, impl_methodology.rpt, synth_ram_cells.txt<br/>3. notes.txt: 툴 버전, board files, xsct 인자, 경고, 걸린 시간"]
    next(["S5-6 리포트 분석 -> S6 보드 측정 정리"])

    start --> prep --> s1 --> s2 --> judge
    judge -- "yes" --> s3 --> smoke --> pilot --> main --> ret --> next
    judge -- "no" --> fail --> next
    s2 -. "구현 실패" .-> impl_fail --> next

    classDef unv stroke-dasharray: 5 5,fill:#fff4d6,stroke:#b08900,color:#333;
    classDef stop fill:#fde4e4,stroke:#b03030,color:#333;
```

- 점선 노랑 박스는 스크립트를 한 번도 실행하지 않은 단계(UNVERIFIED), 빨강 박스는 측정을 하지 않고 리포트만 돌려보내는 경로다.
- 3단계(`xsct_build.tcl`)는 같은 명령에 `RUN=1`을 더하면 4단계(PL 프로그래밍, PS 초기화, ELF와 15M 이미지 다운로드, 실행)까지 한다. 15M 이미지는 DDR 0x1000_0000(checkpoint), 0x1400_0000(tokenizer)에 올리고 리셋하면 다시 올린다(README 4.3절).
- FCLK는 PS PLL이 가까운 값을 고르므로 `FCLK_HZ`에는 그 빌드의 실제 값(`fclk_mhz_actual`)을 Hz로 넣는다.
- timing 미달일 때 대책(IP의 PIPE parameter 추가가 먼저, 낮은 FCLK 빌드는 `FCLK_MHZ=75` 등)은 리포트를 본 뒤 오케스트레이터가 정한다(README 4.5절, `system.md` 1.6).
- 리포트 판정 항목(S5-6): `summary.txt`의 `wns`, `whs`, `timing_met`, BRAM36 <= 140([계산] P 128~129, A 3~3.5), DSP([계산] A 60, P 149), parity 매핑(README 4.6절).
