# 진행 로그: pqc-ntt-ip

## 2026-11-18: P5-1 L4 AXI wrapper 통과 (G4의 L4 부분)  [notion: pending]
- 단계: P5
- 한 일: `rtl/l4/`(`axil_slave`, `pqc_ntt_csr`, `pqc_ntt_axi_top`), `tb/l4/`(AXI BFM, 매 cycle CSR 참조 모델, 프로토콜 검사), L4 cfg 4개. `fpga/sw` 헤더, 드라이버, 호스트 모델을 확정 스펙(`bad_op`, `din_range`, CONFIG)에 맞춤. RTL 접근 trace를 호스트 레지스터 모델로 재생하는 대조(`fpga/sw/test/replay.c`). HLS 실행 스크립트를 환경변수와 `catapult -shell -f run.tcl` 방식으로 변경.
- 결과(수퍼바이저 재실행): L4 36 run(ALGO 4종 x 9) 전부 PASS. full run은 외부 벡터 NTT 855, INTT 450, basemul 2145 전부를 AXI 경유로 mismatch 0. 호스트 테스트 PASS, trace 재생 8개 mismatch 0.
- agent 보고(재실행 안 함): 변이 23종 전부 검출, quick 131 run fail 0, CYCLES가 L = 0, 3, 5에서 식과 일치, Catapult 구성 1개 재실행 결과가 기존과 같음.
- 결정: 구현 중 확정한 세부 6건을 `l4_axi.md` "L4 구현 결과 반영"에 기록.
- 한계: `axil_slave`, `pqc_ntt_csr`의 단독 TB 없음(top TB에서 양쪽 경계 대조). Vivado Tcl과 SV top의 module reference는 미실행. agent의 초기 실행에서 명령행에 TB 이름이 약 3분 노출(이후 job 파일 방식).
- 다음: 사용자에게 1차 Vivado 빌드 요청(P5-2). 단독 TB 보강(P5-1b).

## 2026-11-17: P3-3 L3 `ntt_core` 통합 통과, P3-4 회귀 스크립트 정리  [notion: synced]
- 단계: P3 (G3/G4의 코어 부분)
- 한 일: `rtl/l3/ntt_core.sv`(L2/L1 인스턴스 + operand/임시 레지스터와 mux), `tb/l3/tb_ntt_core.sv`, L3 cfg 4개. `sim/run.sh`에 `quick`/`all` 등급, `assert:TAG=n` 기대 형식, 인자 파일 실행(`vlog -f c.f`, `vsim -f r.f`), 테스트 이름은 환경변수 `T`.
- 결과(수퍼바이저 재실행): `./sim/run.sh all` 443 run, fail 0, wall 6739 s(Questa 라이선스 대기 포함). L3는 59 run. full run 하나는 외부 벡터 NTT 855, INTT 450, basemul 2145 전부 + random 연산당 1000 + 방향성 + round trip + 다항식 곱 체인 138, 계수 mismatch 0. cycle은 식(NTT/INTT 897 + 7(1 + L), BASEMUL 128 * n * (L + 1) + 3)과 전 구성 일치. quick은 107 run, fail 0, 약 6분(agent 실행).
- 변이 테스트(agent 보고, 재실행 안 함): `ntt_core` 결함 14종 전부 검출.
- 실행 중 명령행 확인: `vsim -f r.f`, `bash ./sim/run.sh all`만 보임.
- 결정: bank 2개로는 계수 도메인 피연산자 두 개를 연달아 NTT할 수 없다. v1은 bank를 늘리지 않는다. 한쪽이 NTT 도메인이면 왕복 없음, 둘 다 계수 도메인이면 호스트 왕복 1회(515 cycle). `arch.md` "L3 결과 반영".
- 한계: latency 대조 검사는 시뮬레이션 전용. bfu 공유 충돌(`L1_SHARE`) run은 TB에 기대 모드가 없어 회귀에 없음. irun 교차 확인, 면적과 타이밍은 미측정.
- 다음: P5-1 L4 AXI wrapper(진행 중), 다이어그램(L3), Notion 정리.

## 2026-11-17: P5-0 FPGA 검증 환경 준비, L4 레지스터 동작 확정  [notion: synced]
- 단계: P5 (준비)
- 한 일: `fpga/vivado/`(프로젝트 생성, 빌드, 리포트 저장 Tcl, module reference용 Verilog shell), `fpga/sw/`(레지스터 헤더, HAL, 드라이버, 테스트 프로그램, 벡터 헤더와 생성기, UART 로그 파서, XSCT 스크립트), 호스트 테스트(레지스터 수준 소프트웨어 모델 + golden model), `fpga/README.md`.
- 결과: 수퍼바이저가 호스트 테스트 재실행, 전 항목 통과: 12 구성(ALGO 4 x BFU_LATENCY 0/2/5) 각각 100 케이스 mismatch 0과 cycle 일치(agent 보고), 결함 주입 4종 검출, 음성 테스트 26/26, Tcl 스텁 검사 20/20.
- 한계: 호스트 테스트는 PS 소프트웨어와 스펙 문서의 일치만 보증한다. RTL도 보드도 아니다. Vivado/XSCT Tcl은 실행한 적이 없고 문법과 분기만 스텁으로 확인. ARM 크로스 컴파일도 하지 않음. README에 미검증 13항목.
- 결정: agent가 정리한 가정 25개를 검토해 `docs/spec/l4_axi.md`에 레지스터 동작을 확정. ERR에 `bad_op`, `din_range` 추가, 빌드 구성을 구별하는 CONFIG 레지스터 추가, WSTRB 무시, CYCLES 정의 명시, v1에 abort 없음. v1은 AXI4-Lite만(hierarchy.md 갱신).
- 다음: P3-3 통과 후 P5-1(L4 RTL과 AXI BFM 검증).

## 2026-11-17: P3-2 L2 `zeta_rom`, `coef_ram`, `ntt_ctrl` 통과  [notion: synced]
- 단계: P3
- 한 일: `rtl/l2/`에 `zeta_rom`(생성된 상수 테이블), `coef_ram`(256 x 12b TDP wrapper, 포트별 en), `ntt_ctrl`(순수 control: 스케줄 FSM, 주소 생성, basemul micro-op 시퀀서, LOAD/UNLOAD 스트림 제어), 공용 패키지 `ntt_l2_pkg`. TB 3개와 cfg 3개.
- 결과: 수퍼바이저가 세 cfg 재실행: `l2_zeta_rom` 9 run, `l2_coef_ram` 2 run, `l2_ntt_ctrl` 51 run(ALGO 4 x BFU_LATENCY 0..5 x ROM_LAT 0/1 + elab_fail 3), 실패 0, mismatch 0. `ntt_ctrl` run당: 스케줄(주소, zeta 주소, mode, bank) 516,240건이 golden `hw_sched`와 순서까지 일치, basemul program, 타이밍, hazard, 스트림 검사, 그리고 behavioral datapath로 계산한 최종 bank가 golden `hw_ntt`/`hw_intt`/`hw_basemul`과 일치(36 case). Questa 2024.2.
- 실측 cycle(behavioral datapath, L = BFU_LATENCY): NTT/INTT 897 + 7(1 + L), BASEMUL 128 n (L + 1) + 3 (n = 5 또는 7), LOAD 257, UNLOAD 258.
- agent 보고(수퍼바이저 미재현): 변이 17종. 2종은 일부 설정에서 원본과 동치라 통과(그 외 설정에서는 검출). 검증 중 UNLOAD가 포트 B도 읽던 RTL 결함 1건을 TB가 잡아 수정. `coef_ram` 충돌 assertion run은 수동 실행.
- 결정: op 인코딩과 타이밍, cycle 식, RAM_LAT = 1 제약, UNLOAD의 read data hold 의존을 arch.md에 반영. 초안의 cycle 근사식과 layer 경계 대기 길이는 틀렸음(RAM read latency 누락).
- 미확인: 실제 `bfu`, `coef_ram`, `zeta_rom` RTL과 결합한 검증(P3-3), BRAM/ROM 추론과 합성 가능성, irun.

## 2026-11-16: P2-4 L0 Catapult HLS판 통과  [notion: synced]
- 단계: P2
- 한 일: `hls/l0/`에 `mod_red` 4종과 `mod_mul` 4종의 Catapult C++(ac_int, golden과 단계와 폭 1:1), Tcl 흐름, 순차 실행 스크립트, hand RTL과 같은 모듈 이름과 포트를 가진 어댑터, 리포트 요약. 8 블록 x 라이브러리 2종(Zynq-7000 xc7z020, Nangate 45 nm) x 구성 3종(latency 0/1/2) = 48개 생성.
- 결과: 수퍼바이저가 C 수준 테스트 재실행, 8 항목 정의역 전체 mismatch 0. 수퍼바이저가 cfg 3개(`mod_mul` MONT12 asic, `mod_red` BARRETT fpga, `mod_mul` SHIFTADD asic) 시뮬레이션 재실행, 전 run 통과, 데이터 exhaustive mismatch 0. 나머지 13 cfg는 agent 보고(48개 전부 통과, 실제 latency == 요청 latency). TB는 hand RTL 것을 수정 없이 사용. Catapult 2026.3_1, Questa 2024.2.
- Catapult 추정치(합성 결과 아님)는 `hls/l0/report/summary.md`. hand RTL 수치가 없어 비교 결론은 없음.
- 공정성 쟁점: (1) HLS는 `OPT_CONST_MULTS full`이라 Barrett `x*5039`가 가산기 트리, hand RTL은 `*`. (2) 클럭이 느슨해(fpga 40 ns, asic 6 ns) p2가 출력 레지스터 추가에 그친 경우가 많음. (3) FPGA 면적 추정에 FF 미포함. P2-5에서 정리.
- 어댑터가 추가하는 것: valid 지연 플롭 LATENCY개(hand RTL과 같은 수)뿐, 데이터패스 로직 없음.
- 머신 부하: 다른 세션의 Catapult가 동시에 돌고 있어 계정 전체로는 3개가 겹친 구간이 있었음. 한도의 범위를 사용자에게 질의.
- 미확인: SCVerify, irun, 다른 클럭에서의 결과, asic area score의 물리 단위.

## 2026-11-16: P3-1 L1 `bfu` RTL 통과, add/sub 공유 스펙 정정  [notion: synced]
- 단계: P3
- 한 일: `rtl/l1/bfu.sv`(L0 인스턴스 + mux, 지연선, 단 레지스터), `tb/l1/tb_bfu.sv`, cfg 4개. parameter `PRE_REG`, `MUL_REG`, `RED_PIPE`, `OUT_REG`, `SHARE_ADDSUB`.
- 결과: 수퍼바이저가 MONT12, K2RED의 전체 구성을 재실행, 각 34 run 실패 0. run당 경계 686, ROM z 1,028,000, random 4,000,000, mode 혼합 스트림 2,000,000, golden trace 재생 2,688(NTT 896 + INTT 896 + BASEMUL 896, 재실행한 두 변형 기준. BARRETT와 SHIFTADD는 BASEMUL 640이라 2,432) 검사에서 mismatch 0 (golden DPI 대비, Questa 2024.2). BARRETT, SHIFTADD는 agent 보고로 각 34 run 통과(수퍼바이저 미재실행).
- 발견: 오케스트레이터 스펙의 "add/sub 한 쌍 공유"는 무조건 성립하지 않음. CT 입력 뒤 정확히 D cycle 후 GS 입력이 오면 충돌, D = 0이면 조합 루프. 기본을 분리 구현(`SHARE_ADDSUB = 0`)으로, 공유는 선택 옵션(op 경계에서 LATENCY 이상 대기 필요)으로 정정.
- agent 보고(수퍼바이저 미재현): 변이 12종 모두 검출. 공유 구성에 mode 혼합 입력을 넣으면 `L1_SHARE` assertion 8,644회, mismatch 8,639건으로 FAIL. 범위 밖 입력 run은 `run.sh`의 집계가 `L0_RANGE`만 세어 cfg에 넣지 못하고 수동 실행(P3-4에서 정리).
- 미확인: irun, 합성, 면적과 타이밍, 공유 구성의 나머지 파이프라인 조합.
- 다음: P3-2 L2(`zeta_rom`, `coef_ram`, `ntt_ctrl`), P2-4 HLS(진행 중).

## 2026-11-16: V-2 계층과 L0 다이어그램 (Mermaid)  [notion: synced]
- 단계: 시각 자료
- 한 일: `docs/diagrams/00_hierarchy.md`(인스턴스 트리와 상태, 인터페이스, bfu와 L0 연결, LOAD~UNLOAD 데이터 흐름), `l0_modules.md`(L0 9개 모듈의 data flow, 비트폭, PIPE 절단 위치, 4변형 비교 표), `l0_valid_timing.md`(PIPE 0/1/2 valid 타이밍). 다이어그램 16개.
- 결과: 수퍼바이저가 `l0_modules.md`의 신호 이름 38개를 RTL 식별자와 대조, 불일치 0. 일부 원문을 읽어 확인.
- 미확인: 실제 Mermaid 파서로의 문법 검사와 GitHub 렌더링. agent는 따옴표/괄호 균형, 노드 ID, 간선 끝점을 스크립트로만 점검. 수퍼바이저의 headless 브라우저 파싱 시도는 권한 정책으로 차단되어 실행하지 못함.
- 주의: L1 이상은 "계획(arch.md 기준)" 표시. 타이밍 문서는 RTL 구조에서 도출한 것이며 시뮬레이션 파형이 아님.

## 2026-11-16: P2-3 L0 `mod_mul` RTL 통과, L0 hand RTL 완료  [notion: synced]
- 단계: P2
- 한 일: `mod_mul`(12b x 12b 곱셈기 + `mod_red`, `MUL_REG` 0..1, `RED_PIPE` 0..2), `tb_mod_mul`, cfg 4개.
- 결과: 수퍼바이저가 4개 변형의 cfg를 재실행, 36 run 실패 0. 변형마다 파이프라인 6개 조합 각각 q^2 = 11,082,241 쌍 exhaustive mismatch 0 (golden DPI 대비, Questa 2024.2, 시드 1). agent의 전체 회귀는 68 run 실패 0, 약 450초(agent 보고).
- agent 보고(수퍼바이저 미재현): 변이 7종 중 검출 5, 통과가 정상인 대조군 2(피연산자 교환, 상시 enable).
- 결정: `mod_mul`은 단일 `PIPE` 대신 `MUL_REG`/`RED_PIPE`(hierarchy.md 갱신). bfu 파이프라인 규칙(`PRE_REG`, `MUL_REG`, `RED_PIPE`, `OUT_REG`, CT/GS 동일 LATENCY)과 회귀 구성(`quick`/`all`)을 arch.md에 추가.
- 다음: P2-4 Catapult HLS판(진행 중), V-2 다이어그램(진행 중), 이후 P3 bfu.

## 2026-11-16: V-1 NTT Schedule Player (interactive viewer)  [notion: synced]
- 단계: 시각 자료
- 한 일: `docs/viewer/ntt_player.html` (단일 HTML, 약 243 KB, 외부 의존성 없음). NTT/INTT/BASEMUL x 4 ALGO x 입력 2종의 golden model trace를 재생. player(재생, step, 속도, scrubber, 단축키), 2-bank 메모리 격자, bfu 데이터 경로와 수식, layer별 주소 패턴, basemul micro-op 표. 생성과 검사 스크립트는 `docs/viewer/tools/`.
- 결과: 수퍼바이저가 `check_viewer.py` 재실행, 140,054건 불일치 0 (내장 데이터 == 원본 trace, 독립 Python 재생, viewer 상태 재구성 엔진, 마지막 bank == golden, 외부 참조 없음). 수퍼바이저가 소스 전체와 스크린샷 1장 확인. Artifact로 게시: https://claude.ai/artifact/5F5nzds9zbxzuMcZDcnGrr
- agent 보고(수퍼바이저 미재현): headless Chrome 렌더 검사 8,573건 불일치 0, 390 px 폭과 라이트/다크 확인.
- 한계: 1 step = bfu 호출 1회(cycle 단위 아님). Firefox, Safari, 실제 휴대폰은 미확인.
- 개선 제안(반영 예정): golden trace에 bfu 내부값(t, s, d, m)과 basemul의 write 주소를 선택 필드로 추가하면 `ntt_ctrl` 검증과 viewer 양쪽에 쓰인다.

## 2026-11-16: P2-2 L0 `mod_red` 4종 RTL 통과, GitHub 연결, 시각 자료 규칙  [notion: synced]
- 단계: P2
- 한 일: `mod_red_barrett`, `mod_red_mont12`, `mod_red_shiftadd`, `mod_red_k2red`와 래퍼 `mod_red`(PIPE 0~2), 공용 TB `tb_mod_red`. `mlkem_pkg`에 ALGO/mode enum, DPI 패키지 갱신, `mod_half` TB를 golden DPI 대조로 교체.
- 결과: 수퍼바이저가 `./sim/run.sh all` 재실행, 7 cfg 32 run 실패 0. 변형별 정의역 전체 exhaustive: BARRETT, SHIFTADD, K2RED는 2^24 = 16,777,216 입력, MONT12는 q*2^12 = 13,635,584 입력, 각각 PIPE 0/1/2에서 mismatch 0 (golden DPI 대비, Questa 2024.2, 시드 1). `mod_half`는 q개 입력 golden DPI 대비 mismatch 0.
- 구조(RTL, 측정값 아님): BARRETT만 넓은 상수 곱(x*5039, 24b x 13b)을 `*`로 두어 FPGA에서 DSP 사용 가능. 나머지 상수 곱은 shift-add. PIPE=2 절단 위치는 BARRETT qhat 뒤, MONT12 t 뒤, SHIFTADD fold 3 뒤, K2RED 두 단계 사이.
- agent 보고(수퍼바이저 미재현): 변이 30여 종 중 4종이 통과했는데 모두 golden 선언 폭에 여유가 있는 경우(Barrett r/d, MONT12 d, SHIFTADD y5/d1/d2)로 전 정의역 실측과 일치.
- 결정: 선언 폭 여유와 MONT12 축약은 QoR 측정 전에 golden, RTL, HLS에 동일하게 정리(P2-5). 래퍼는 스케일 S를 제거하지 않음(hierarchy.md 문구 정정).
- 기타: GitHub 저장소 연결(개인용 SSH 키, noreply 작성자), 첫 push 430b4dc. 시각 자료 규칙(`visual-docs.md`) 추가, viewer 작업(V-1) 시작.
- 미확인: irun 교차 확인, 합성 가능성, 면적과 타이밍.
- 다음: P2-3 `mod_mul`, V-1 viewer, V-2 다이어그램.

## 2026-11-16: P2-0 golden model 확장, GS 정의 정정  [notion: synced]
- 단계: P2
- 한 일: golden model에 `mod_half`, `bfu`(4 ALGO x CT/GS), ALGO별 ROM, 하드웨어 스케줄 NTT/INTT(2-bank ping-pong, trace), basemul micro-op 시퀀스, DPI 함수 17개 추가. 기존 함수는 유지.
- 결과: 수퍼바이저가 `make test` 재실행, 66개 항목(기존 38 + 신규 28) mismatch 0. 하드웨어 스케줄 NTT/INTT/basemul이 4 ALGO 모두 기준 구현 및 외부 벡터(NTT 855, INTT 450, basemul 2,145 다항식)와 일치. model 변경 뒤 L0 회귀 12 run 재실행, 실패 0.
- 발견: 오케스트레이터가 쓴 `arch.md`의 GS 정의 `(a - b)*z/2`가 틀림(올바른 것은 `(b - a)*z/2`). agent가 임의로 맞추지 않고 보고했고, 스펙을 정정함. basemul 5/7 op 시퀀스는 맞음. basemul에 operand latch가 필요하다는 점도 스펙에 추가.
- agent 보고(수퍼바이저 미재현): 변이 18종 모두 검출.
- 참고: 앞서 15초 걸렸던 `mod_sub` oor run은 재실행에서 0초. 재현되지 않음.
- 다음: P2-2 `mod_red` 4종 RTL.

## 2026-11-16: P2-1 L0 `mod_add`, `mod_sub`, `mod_half` RTL 통과 (G3, G4)  [notion: synced]
- 단계: P2
- 한 일: L0 RTL 3개(`rtl/l0/`), 공통 패키지, self-checking TB, 회귀 스크립트 `sim/run.sh`(순차 실행, flock). golden model을 DPI-C로 Questa에서 직접 호출하는 흐름 확립.
- 결과: 수퍼바이저가 `./sim/run.sh all` 재실행, 12 run 실패 0. `mod_add`, `mod_sub`는 PIPE 0/1 각각 q^2 = 11,082,241 쌍 exhaustive mismatch 0 (DPI golden 대비). `mod_half`는 q개 입력 전체, 정의식(2h mod q == x, h < q) 검사 mismatch 0 (golden 함수는 P2-0에서 추가 후 DPI로 교체). 범위 밖 입력 assertion과 잘못된 PIPE elaboration 에러도 run으로 확인. Questa 2024.2, 시드 1, 경고 0.
- agent 보고(수퍼바이저 미재현): 변이 10종 주입 모두 FAIL 검출. 과정에서 TB가 입력 변경과 검사를 같은 negedge에 두어 조합 통과 버그를 놓치는 결함을 찾아 수정.
- 결정: datapath 레지스터는 reset 없이 valid로 한정, control만 reset. TB는 posedge 구동, negedge 검사. 규칙에 추가.
- 미확인: irun 교차 확인, DC에서의 `SYNTHESIS` 매크로와 generate `$error` 처리.
- 다음: P2-0 golden model 확장, P2-2 `mod_red` 4종.

## 2026-11-16: P1-d test data 확보, P1 완료 (G2 통과)  [notion: synced]
- 단계: P1
- 한 일: NIST ACVP ML-KEM 벡터(ACVP-Server commit 975de31e)와 pq-crystals/kyber ref(commit 3edd5af5)를 받아, ref가 ACVP를 통과함을 확인한 뒤 KEM 실행 중의 다항식 단위 중간값을 추출해 canonical 표현으로 변환. `data/` (README, 받기/생성 스크립트, 체크섬, `vectors/ext/`).
- 결과: ref의 ACVP 240/240 통과(agent 보고, 로그 확인). 외부 벡터 NTT 855, INTT 450, basemul 2,145 다항식. 독립 Python FIPS 203 구현 대비 계수 218,880 / 115,200 / 549,120개 mismatch 0 (수퍼바이저 재실행). golden model 대비 mismatch 0 (로그 확인). 체크섬 일치.
- 한계: NTT 외부 입력 855개 중 765개는 작은 값(CBD 잡음)이고 전 범위 입력은 90개. NTT 전 범위는 golden model random 벡터로 보완한다. 외부 다항식 벡터는 NIST가 직접 준 값이 아니라 ACVP를 통과한 ref의 중간값이다.
- 결정: RTL sim(G4)의 다항식 단위 벡터 세트 = 외부 벡터 전부 + golden random(전 범위) + 방향성(경계) 벡터.
- 다음: P2-1 L0 RTL(진행 중), P2-0 golden model 확장.

## 2026-11-16: P1-b golden model 완료, P1-c 아키텍처 스펙 확정  [notion: synced]
- 단계: P1 (G1 통과)
- 한 일: C++ golden model(`model/`, 약 1,650줄), 자체 테스트, 벡터 생성기, DPI-C wrapper. `docs/spec/arch.md`, `docs/spec/agent-metrics.md` 작성.
- 결과: 수퍼바이저가 `make test` 재실행, 38개 항목 mismatch 0. 모듈러 연산과 reduction 5종은 정의역 전체 exhaustive(q^2 = 11,082,241 쌍, 2^24 입력 등). zeta/gamma 테이블은 FIPS 203 Appendix A와 128개씩 일치. pq-crystals/kyber ref(commit 3edd5af5)와 ntt/invntt/basemul 각 1,006개 다항식 일치. DPI wrapper는 Questa에서 아직 미확인.
- 결정: v1은 single butterfly, TDP RAM 2개 ping-pong, GS에 halving 내장(INTT 스케일 pass 제거), basemul은 `bfu` CT 모드 micro-op 재사용. IP 계약은 모든 reduction 변형에서 FIPS 203과 bit-exact. Montgomery와 K2-RED는 basemul에서 보정 op 2개(5 대 7 op)를 추가로 치르며 이 비용을 비교 결과로 보고한다. Montgomery는 R=2^12 채택(q^-1 mod 2^12 = 769 = 2^9+2^8+1 이라 곱셈기 없이 가산으로 구현 가능).
- 다음: P1-d test data 대조, P1-e Notion 서베이 정리, 이후 P2-0부터.

## 2026-11-16: P1-a 선행 연구 서베이 완료  [notion: synced]
- 단계: P1
- 한 일: 문헌 58건 조사(직접 확인 32, 재인용 12, 미확인 14). `docs/survey/survey.md`.
- 결과: Kyber NTT FPGA 구현과 ML-KEM+ML-DSA 통합 NTT는 포화. 같은 구조의 RTL 대 HLS 통제 비교는 2019~2020년 Vivado HLS FPGA 결과뿐이며, ML-KEM + Catapult + ASIC 조합은 찾지 못함(찾지 못했다는 것이지 없다는 증거는 아님). 같은 칩(XC7Z020)의 Vitis HLS ML-KEM 사례가 있어 비교 기준선 후보.
- 결정: 논문 주 방향을 RTL 대 Catapult HLS 통제 비교(reduction 4종 sweep, FPGA + ASIC)로, agent 설계 흐름 정량 기록을 결합 방향으로 확정. 성능 경쟁과 통합 butterfly는 하지 않음.
- 다음: P1-b golden model 검수, P1-d test data(진행 중), P1-c 스펙과 agent 지표, P1-e Notion 서베이 정리.

## 2026-11-16: 워크스페이스 세팅과 프로젝트 시작  [notion: synced]
- 단계: P0
- 한 일: CLAUDE.md, `.claude/rules` 4개, skills 3개(`eda-tools`, `research-log`, `milestone-cycle`), agents 2개(`hw-worker`=Opus, `doc-writer`=Sonnet), 권한 설정(vivado deny, dc_shell ask) 작성. todo/progress/done 보드 구성.
- 결과: 툴 확인. Questa 2024.2, Catapult 2026.3_1, irun(IC152), dc_shell W-2024.09-SP5-2, Rise V-2026.11.11 환경 스크립트 존재. 실행 확인은 Questa와 Catapult 버전 출력까지.
- 결정: 첫 프로젝트로 ML-KEM 다항식 연산 IP 선정(근거는 `brief.md`). 후보 3개는 `todo/`에 보관.
- 추가(같은 날): 표준 흐름(gate G0~G7)과 test data 규칙, bottom-up 계층 설계 규칙 추가. `docs/spec/hierarchy.md` 초안과 L0 인터페이스 고정. Notion에 프로젝트 페이지와 Process 항목 2개 생성, 후보 3개는 To Do로 등록.
- 다음: P1-a 서베이, P1-b golden model(진행 중), P1-d test data, P1-c 아키텍처 스펙.
