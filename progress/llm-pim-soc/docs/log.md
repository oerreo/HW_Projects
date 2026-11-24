# Log: llm-pim-soc

## 2026-11-18: 프로젝트 시작  [notion: synced]
- 결정(사용자): 다음 프로젝트를 "LLM 추론 + PIM"으로, 그 다음을 NAND ECC로 한다. `pqc-ntt-ip`는 보드 검증까지만.
- 한 일: brief와 plan 작성, 서베이(S0) 착수.
- S0 결과: `survey/survey.md`(직접 확인 38, 재인용 1, 미확인 10). S1 결정: 두 모델(260K, 15M) 지원, C 구현 3단계(F, Q, H), kernel 6종 초안. `spec/scope.md`.

## 2026-11-18: S2 C golden model (G1)  [notion: synced]
- 한 일: `model/`(F float 참조판, Q int8 matmul판, H 전체 정수판과 kernel 경계 함수, bank 분할 GEMV), `data/`(받는 스크립트, 체크섬, 프롬프트 32개), `docs/spec/numeric.md`.
- 결과(수퍼바이저 재실행): `make test` 14,190,666 항목, mismatch 0, PASS. 포함: F판이 공개 참조 구현과 두 모델에서 생성 token과 logits 일치, H판 추론 경로에 float 없음(13항목), bank 분할 GEMV bit-exact, 덤프 재생.
- agent 보고(재실행 안 함): 정확도 표(F 대비 cross-entropy 증가. 260K: Qg +0.0014, HD +0.0011. 15M: Qg +0.0030, HD +0.0053 nats/token), PC 시간 비중(260K gemv 43%, attn 49%. 15M gemv 94.6%. x86 수치이며 ARM 아님).
- 발견: 공개 양자화 구현(runq.c)은 행 길이가 그룹 크기의 배수가 아니면 행 끝 입력을 버리고 scale 인덱스가 어긋난다. 260K에서 재현(top-1 일치 42.0%). 단 시험 파일은 export 규칙을 C로 재현해 만든 것이라 원본 export 결과와 bit 일치는 미확인.
- 미정: H판 형식. 권장 HD(q/k/v int16)는 260K에서 KV cache 320 KiB(추정)라 가중치와 함께 BRAM에 안 들어간다. 후보 간 차이가 표본(프롬프트 32, story 32) 잡음 수준이라 평가를 늘려 다시 잰다(S2b).
- 한계: ARM 컴파일 미확인(cross compiler 없음). 15M tokenizer 라이선스 미확인.
- 다음: S2b(평가 확대와 형식 확정), S3(ARM baseline 프로그램).

## 2026-11-18: S2b 정수 형식 평가와 H판 형식 확정  [notion: synced]
- 한 일(hw-worker): `k_attn2`(K 비트 kb, V 비트 vb 각 8/12/16)와 descriptor `K_ATTN2`, `lm_hfmt_t`의 `kbits`, `vbits`, `win`(0이면 기존 동작), `job ceval`, `tools/ci.py`, `tools/cost.py`, 평가 설정 `cfg/g1~g4`, `h1~h3` 추가. 평가 텍스트를 TinyStories valid 처음 1 MiB로 확대(260K 1,320 story 482,940 token F CE 1.41128, 15M 300 story 59,041 token F CE 0.87401, 15M은 시간 때문에 축소). 구간은 story 단위 paired bootstrap 95%(B=4000, seed 20261118).
- 결과 [측정, PC x86-64]: dCE(F 대비 cross-entropy 증가, nats/token) 260K K12V8 +0.00186 [+0.00169, +0.00204]. HD(K16V16)와 구분되지 않음(HD - K12V8 -0.00006 [-0.00023, +0.00012]). HB(K8V8)보다 0.00163 [0.00136, 0.00190] 좋음. K 폭이 결정적, V 폭 8/12/16은 구분되지 않음. 15M K12V8 +0.00295 [+0.00229, +0.00364], HB와 구분되지 않음(HB - K12V8 -0.00015 [-0.00094, +0.00060]). 300 story로는 MANT 형식 사이 거의 모든 쌍이 구분되지 않음. window 축소와 POW2 활성 scale(HA)은 확실히 나쁨. 전체 표는 `spec/numeric.md` 2.5절.
- 메모리 [계산, `model/results/cost.txt`]: 260K 가중치 270.6 KiB + KV 260 KiB = 530.6 KiB, 560 KiB 이하, BRAM36 하한 127.7/140. HD(K16V16)는 KV 380 KiB로 합계 650.6 KiB라 넘침. 15M KV 1134 KiB는 DDR. 기존 numeric.md의 KV 160/320 KiB는 scale(위치, 층, head, K/V마다 24비트, 260K ctx512에서 60 KiB)이 빠져 있어 고침.
- 곱셈기 [계산, 합성 안 함]: score MAC 12x12는 DSP48E1 하나. V MAC은 위치 가중치(최대 34비트) x V라 vb와 무관하게 DSP 2개. V 누산은 약 vb+42비트로 48비트를 넘어 확장 필요.
- 결정(오케스트레이터): H판 형식을 두 모델 모두 **K12V8**로 확정(이전 권고 HD를 대체). 이유: (1) 위 측정, (2) 메모리 한도, (3) 두 모델이 attention IP와 LUT 하나를 공유. agent 권고는 260K K12V8s(작은 LUT, +0.00175, K12V8과 구분되지 않음)와 15M HB였으나, LUT 차이 약 8 Kb와 15M KV 트래픽 차이(가중치 트래픽 대비 7.6% 대 6.2% [계산])보다 IP 통일의 이득을 택함. 15M에서 작은 LUT가 약간 나쁜 경향(HD - HG -0.00071 [-0.00144, +0.00000], 경계선)도 이유. 기각: context window 축소(128은 260K에서 K12V12 대비 +0.0104, 15M에서 K12V8 대비 +0.0133 악화, 256은 260K에서 HD 대비 +0.0005 악화), POW2 활성 scale(HA).
- 이전 32 표본 결론 수정: 260K의 "int16이 크게 좋다"는 K 쪽 효과였고 12비트면 충분, V는 8비트. 15M에서 HD가 HB보다 나쁘고 HH가 좋아 보인 것은 잡음.
- 검증: `make test` TOTAL items 15,489,337, mismatches 0, PASS(clean build 후, 오케스트레이터 재실행 [측정]). 기존 8형식 x 2모델 kernel 덤프 16개는 변경 전후 `cmp` 동일(agent 보고, 재확인 안 함).
- 한계: 15M K12V8s 미실행. 15M 300 story는 표본 부족(구간 폭 약 +-0.0007). 처음 32 story가 S2 선정과 겹침. BRAM/DSP는 전부 계산(포트, 깊이 단위, 버퍼 미포함, 12비트와 24비트 packing은 가정). ring buffer 배치는 직접 돌려 보지 않음.
- 다음: S3 호스트 테스트 재실행 결과 반영(오케스트레이터), ARM baseline.

## 2026-11-18: S3 ARM baseline 프로그램 준비 (G2 test data, 보드 실행 대기)  [notion: synced]
- 한 일(hw-worker): `data/`(받는 스크립트 `data/scripts/fetch.sh`, 체크섬), `fpga/sw/`(bare-metal baseline 프로그램: 플랫폼 계층 `plat_xil.c`/`plat_host.c`, 측정 `bench.c`, probe `prof.c`, `fq_prof.c`, 로그 파서 `parse_log.py`, 기대값 생성기, `xsct_build.tcl`), 호스트 테스트 `fpga/sw/test/`, 문서 `fpga/README.md`, `docs/spec/measure.md`. 모델 260K(배열 내장)와 15M(JTAG로 DDR 적재), 판 F, Qg, H, 실행 E(계측 없음), T(위치별), P(kernel별 lap probe).
- S2b 결정 반영(오케스트레이터): H판 형식을 HD에서 K12V8로 바꿨다. `fpga/sw/tools/m1.cfg`, `m2.cfg`의 `vars`는 `F,Qg,K12V8`, 기대값 헤더 `fpga/sw/expect/exp_m1.h`, `exp_m2.h`를 다시 생성, `fpga/sw/test/run.sh`의 형식 이름 고정 3곳도 K12V8로 수정. K12V8의 KV는 K int16 container(12비트), V int8.
- 검수 [측정, 오케스트레이터 재실행, PC x86-64]: `make -C fpga/sw/test gen` 후 `make test`: HOSTTEST items=23 fail=0, RESULT PASS. 첫 재실행은 21/23이었고 실패 2건(td_ok run selection, parser tamper)은 `run.sh`에 `v=HD`가 고정돼 있던 것이 원인이었다(프로그램의 token/hash 비교는 그때도 64비트와 `-m32` 빌드 모두 mismatch 0). 수정 후 23/23. 로그는 `fpga/sw/test/build/logs/`(`t.log` 64비트, `t32.log` `-m32`, `stack.txt`).
- 로그 값 [측정, PC x86 `-m32`, gcc 8.5 `-O2`, ARM 아님]: 모델 메모리(`ARENA need`) 260K 2,466,496 B, 15M 78,198,848 B. H판(K12V8) `VAR bytes` 260K 694,864 B, 15M 16,942,400 B. 15M K12V8 run E 6.650 ms/token(1702.294 ms, 256 위치), 150.385 tok/s. 64비트 빌드는 포인터 폭 때문에 값이 다르다(260K `ARENA need` 2,469,568 B).
- 참고용 PC 프로파일 [측정, x86 `-m32`, ARM 아님, run P 비중]: 260K K12V8(512 위치)은 attn 70.5%, gemv 합계 약 18.9%, swiglu 4.1%, rmsnorm 3.1%. 15M K12V8(256 위치)은 gemv_cls 52.0%, gemv_w1/w2/w3 합 22.1%, gemv_q/k/v/o 합 11.3%, attn 9.7%. 260K K12V8 token당 시간은 0.571 ms(`t32.log` run E). 직전 실행의 같은 항목은 0.552 ms였다(공용 서버의 실행 간 변동, 로그는 덮어씀). 이전 S2의 PC 프로파일(260K attn 49%, 15M gemv 94.6%)은 F/Q판 기준이고 H판 K12V8과 비교할 수 없다.
- 이 서버에서 한 번도 실행하지 않은 것: ARM 컴파일, Xilinx API(`plat_xil.c`, CP15 PMU, global timer 포함), XSCT 스크립트(stub 문법 검사만), Vitis 동작, 보드 실행 시간과 UART 출력량, 스택 64 KB 충분성(호스트 `-m32` 측정 약 2.3 KB). Qg판의 보드 bit 일치는 newlib libm이 glibc와 같은 결과를 내야 성립한다(미확인, 다르면 Q hash FAIL). H판은 float를 쓰지 않는다. 15M `tokenizer.bin` 라이선스는 미확인이라 저장소와 ELF에 넣지 않았다.
- 결정: ARM 측정값 없이는 kernel 우선순위를 정하지 않는다(PC 비중은 참고만). 보드 실행은 사용자가 한다.
- 사용자 실행 순서: (1) `sh data/scripts/fetch.sh` (2) `make -C fpga/sw/test data` (3) `xsct fpga/sw/xsct_build.tcl XSA=<file.xsa>` (4) 같은 명령에 `RUN=1` (5) `RUN=1 RUNOPT=O3`. 돌려받을 것: `fpga/results/<date>_<o2|o3>/uart.log`(원본)와 `notes.txt`(Vitis 버전, XSA, CPU 클럭, 경고).
- 다음: 사용자 보드 실행 결과 분석(kernel 우선순위, Amdahl 추정 입력), 그동안 S4 kernel IP 계획 준비.

## 2026-11-19: S4-0 kernel IP 계층과 구조 스펙  [notion: synced]
- 한 일(hw-worker): `spec/hierarchy.md`(계층, 진행 순서, 모듈 인터페이스, golden 대응), `spec/arch.md`(GEMV 가속기형과 PIM형, attention, vec, HW/SW 인터페이스, 자원 예산), `spec/s4calc.py`([계산] 값 재현), plan의 S4-1~S4-8.
- 구조 요약 [계산, 측정 아님]: 가속기형 GEMV는 HP 포트당 8 lane(포트 하나의 대역폭이 한도), 15M token당 1,950,260 cycle(P = 1, 대역폭 효율 1 가정의 하한). PIM형은 bank 4 x 16 lane, 가중치 BRAM36 64개, 260K token당 MAC 4,072 cycle(가속기형 P = 1의 36,446 대비 8.95배). attention은 3 pass + 나눗셈 1회, 260K KV는 BRAM36 60개. vec IP 하나가 rmsnorm, swiglu, actq, argmax를 맡는다.
- 자원 [계산, LUT는 추정]: 260K PIM형 시스템 DSP 147/220, BRAM36 126/140. 15M 가속기형 DSP 58, BRAM36 약 3.
- 결정(오케스트레이터): 열린 결정 D1~D14를 권고대로 확정(`spec/arch.md` 12절). 수퍼바이저 확인: `s4calc.py` 재실행 값이 문서 표와 일치.
- 미확인: HP 실측 대역폭, 100 MHz 타이밍, LUT 수, Vivado의 parity bit 추론, 지수와 shift 범위. ARM baseline이 없어 가속비는 추정하지 않음.
- 다음: S4-1 검증 기반(model 덤프 보강, DPI-C golden, 회귀 스크립트, AXI memory model).

## 2026-11-19: S4-1 kernel IP 검증 기반  [notion: synced]
- 한 일(hw-worker): model에 leaf 경계 stage 함수(`k_sat32`, `k_dot8`, `k_gemv_row`, `k_gemv_out`, `k_aq_*`)와 trace 판, PIM bank image(`bimg_*`)와 가속기형 행 레코드(`rrec_*`) 생성기, K12V8 덤프와 위치 필터(`cfg/d3`, `d4`), 벡터 도구 `tools/vt.c`. DPI-C wrapper(`tb/dpi/`), AXI4 slave memory model(`tb/common/axi_mem_slave.sv`), 회귀 스크립트(`sim/run.sh`).
- 결과 [측정, 수퍼바이저 재실행]: `make test` TOTAL 16,669,793 항목, mismatch 0. `sim/run.sh all` 18 run, fails 0(DPI smoke 2, AXI memory model 정상 4, negative 10, 잘못된 parameter 2). negative run은 각각 기대한 assertion 태그 1개.
- agent 보고(재실행 안 함): 기존 형식 덤프 4종이 변경 전과 `cmp` 동일. 벡터: 260K 2,388 레코드(12 위치, T 최대 512), 15M 1,428 레코드(6 위치, T 최대 256). PIM bank image 4,072/4,096 word.
- 결정: `E_W` = 8, `SH_W` = 10. 근거: K12V8 덤프 집계에서 지수 0..33, shift -1..40(`model/results/range_k12v8.txt`). 프롬프트 1개의 일부 위치 값이라 상한 증명은 아니며, TB의 range assertion으로 범위 밖을 표시한다.
- 수정: KV word는 210비트가 맞다(scale = 가수 17 + 지수 8). `s4calc.py`를 고쳤고 BRAM36 60개는 그대로. S2b의 `cost.py`는 scale 24비트 가정이라 260K KV가 2.5 KiB 작게 나와 있다(530.6 -> 533.1 KiB, 한도 560 KiB 안). 문서 수치 정리는 남은 일.
- 발견(프로세스 노출): vsim이 자동으로 띄우는 vopt가 top 이름을, vlog의 DPI 자동 컴파일이 gcc에 work 라이브러리 절대 경로를 명령행에 드러낸다. 이 프로젝트의 `run.sh`는 명시적 `vopt -f o.f`(-j 1)와 `gcc @g.f`로 막았다(실행 중 cmdline 샘플 4,138건에서 이름 0건, agent 보고). `pqc-ntt-ip`의 `run.sh`에도 vopt 쪽 문제가 있을 수 있어 확인 필요.
- 한계: AXI memory model TB의 데이터 오류 검출 mutation 시험 안 함. DPI smoke 15M은 kernel 파일마다 첫 50 레코드. attention, rmsnorm, swiglu, actq의 DPI trace는 S4-6, S4-7 직전으로 미룸.
- 다음: S4-2(GEMV leaf와 `gemv_core`).

## 2026-11-19: S4-2 GEMV leaf와 gemv_core  [notion: synced]
- 한 일(hw-worker): `rtl/pkg/llm_pkg.sv`, L0 `rshr_sat`, `dotp`, `sync_fifo`, `ram_sdp`, L1 `mac_row`, `gemv_scale`, L2 `gemv_core`(직접 작성 RTL, 813줄)와 모듈별 TB, 회귀 cfg 7개.
- 결과 [측정, 수퍼바이저 재실행]: `./sim/run.sh all` 97 run, fails 0. `gemv_core`는 260K K_GEMV 레코드 432개(42,144행)와 15M 258개(299,136행, 분류기 32000 x 288 포함)에서 y mismatch 0, stall 있는 run과 없는 run 모두.
- agent 보고(재실행 안 함): 모듈별 CHECKS 합계(rshr_sat 16.6M, dotp 20.4M, gemv_scale 16.4M 등), mutation 18개 전부 FAIL로 검출, `vlog`/`vopt -lint=full` 경고 0, `make test` 16,669,793 항목 mismatch 0.
- cycle 식 확정 [측정으로 확인]: `C = ceil(n/8) + rows x (1 + ceil(n/8)) + L_PIPE`, `L_PIPE = 4 + DOT_PIPE + SCALE_PIPE`(기본 9). stall 없는 run의 모든 호출에서 일치. token 단위 합(L_PIPE 제외)은 260K 36,446, 15M 1,950,260 cycle로 arch.md 2.4와 같다.
- 검증 공백 발견과 수정: 첫 mutation 회차에서 `gemv_core` mutant 3개가 살아남았다. 2개는 실제 레코드에서 결과가 같은 mutant(가중치 padding 0, 동시 처리 행 2개)라 합성 호출 run으로 잡았고, 1개(credit 초과)는 y stall이 짧아 FIFO가 차지 않던 실제 공백이라 긴 y 차단 구간(`+YBLK`)과 credit 한도 도달 검사를 TB에 넣었다.
- 스펙 대비 변경(hierarchy.md 3.5): `gemv_core`의 LANES는 8 고정(64비트 beat), `mac_row` 누산 25비트는 |x| <= 127 전제(위반은 `L1_RANGE`), `ram_sdp`는 read-first, y backpressure는 header credit.
- 한계: 합성과 타이밍 미확인(41 x 17 곱의 DSP 분할 포함). irun 교차는 S4-8. 15M credit 경로 coverage는 약함(주 coverage는 260K와 합성 호출 run).
- 프로세스 노출: 작업 초반 몇 번 job 파일 수정과 실행을 한 명령으로 묶어 모듈 이름이 최대 약 90초 보였다(agent 보고). 이후 분리.
- 다음: S4-3(`axi_rd_eng`, `axi_wr_eng`, HP 대역폭 측정 top).

## 2026-11-19: S4-3 AXI engine과 HP 대역폭 측정 빌드  [notion: synced]
- 한 일(hw-worker): `rtl/l1/axi_rd_eng.sv`, `axi_wr_eng.sv`, `axil_slave.sv`(pqc-ntt-ip에서 복사), `rtl/l3/bw_top.sv`(측정 top)와 TB, AXI-Lite BFM(`tb/common/axil_bfm.sv`), memory model에 SLVERR/DECERR 주입. `docs/spec/bwtest.md`(레지스터 맵), `fpga/bw/`(Vivado Tcl, bare-metal 측정 프로그램, README).
- 결과 [측정, 수퍼바이저 재실행]: `./sim/run.sh all` 164 run, fails 0(기존 97 + axi_mem 2, rd 23, wr 25, axil 7, bw_top 10).
- agent 보고(재실행 안 함): mutation 31개 중 30개 검출, 1개는 동치(engine의 RREADY가 RVALID 때 항상 1). lint 경고 0. 호스트 검사 HOSTTEST 11/11, Tcl stub 17/17.
- 처리율 [측정, 시뮬레이션 모델, 64 KiB, stall 없음]: rd는 burst 16, outstanding 2 이상에서 1 beat/cycle, outstanding 1에서 0.842. wr는 burst 16, outstanding 2 이상, FIFO 32에서 1.000, FIFO 16에서 0.842(burst 단위로 모은 뒤 보내므로 버퍼가 burst의 2배 필요). 보드의 HP latency와는 무관한 값이다.
- 정한 규칙(hierarchy.md 3.6): 시작 주소는 8 B 정렬만 지원(위반 명령은 거절, sticky 오류), 길이는 임의 byte. burst = min(남은 beat, burst 한도, 4 KiB 경계까지). rd는 buffer 여유가 burst 전체를 덮을 때만 AR을 내 R이 멈추지 않는다. wr는 burst 데이터를 모두 받은 뒤 AW. 응답 오류는 sticky, 같은 cycle의 clear보다 새 오류가 우선.
- 검증 공백 발견과 수정: 오류와 clear가 같은 cycle에 겹치는 경우를 TB가 만들지 않아 우선순위 mutant 2개가 살아남았다. 겹침 구간과 coverage 검사를 추가해 검출. `bw_top`에서 실제 버그 1건(engine이 쓰기 명령을 거절하면 pattern beat가 남아 다음 op를 오염)을 찾아 descriptor 검사로 막았다.
- UNVERIFIED: `fpga/bw/`의 Vivado Tcl(PS7 속성 이름, module reference, HP DDR segment), XSCT 스크립트, Xilinx BSP 호출, 100 MHz timing. PS 프로그램의 checksum은 스펙 문서로 쓴 C 호스트 모델로만 확인(RTL trace 대조 안 함).
- 프로세스 노출: agent가 프로젝트 경로가 든 `cd` 명령으로 job을 실행해 경로가 job마다 수 초에서 약 5분 보였다. 발견 후 비공개 포인터 파일 방식으로 바꿨고 `process-privacy.md`에 규칙으로 추가.
- 다음: 사용자 보드 실행 요청(대역폭 측정), S4-4(GEMV 가속기형 IP top).

## 2026-11-19: S4-4 GEMV 가속기형 IP  [notion: synced]
- 한 일(hw-worker): `rtl/l0/argmax_red.sv`, `rtl/l3/gemv_acc_csr.sv`, `rtl/l3/gemv_acc_top.sv`(axil_slave + CSR + slice P개(`axi_rd_eng` + `gemv_core`) + y merge + argmax + packer + `axi_wr_eng`)와 TB 3개, `docs/spec/gemv_acc.md`(레지스터 맵, 호출 규칙, CYCLES 식).
- 결과 [측정, 수퍼바이저 재실행]: `./sim/run.sh all` 201 run, fails 0(기존 164 + 신규 37).
- agent 보고(재실행 안 함): 두 모델의 K_GEMV 레코드 전부(15M 분류기 포함, y 299,136개)와 K_ARGMAX 레코드에서 mismatch 0, P = 1과 2. y 영역 앞뒤 guard 불변, 매 cycle CSR 참조 모델 대조, 오류 경로(BAD_OP, BAD_DESC, MISALIGN, START_BUSY, SLVERR/DECERR)와 복구. mutation 24/24 검출(첫 회차 생존 2개는 TB 공백이라 보강). lint 경고 0.
- CYCLES [측정, 시뮬레이션, stall 없음]: 15M token당 1,951,575~1,951,644(S4-0 계산 1,950,260), 260K token당 P = 1 37,596 / P = 2 19,597(계산 36,446 / 18,402). 차이는 호출당 고정 항 15~35 cycle. 식은 `gemv_acc.md` 5절. 보드의 HP latency가 반영되지 않은 값이다.
- 스펙 대비 확정(gemv_acc.md): ERR 비트 배치, RD_RESP/WR_RESP는 AXI handshake마다 set, RD_STALL은 core 경계에서 정의, `argmax_red`에 `max_o` 추가, FLAGS = 0은 BAD_DESC, P = 2는 행마다 read 명령 하나(slice별 HP 포트), y는 포트 0으로 씀.
- 수정(오케스트레이터): `axi_rd_eng` 헤더 주석과 문서의 latency를 "명령 handshake c -> ARVALID c+2"로 정정(로직 변경 없음, TB로 잰 값 아님).
- 한계: 100 MHz 타이밍, LUT 수 미확인. CYCLES 식은 기본 parameter와 stall 없는 모델에서만 확인. P = 2의 15M 전체는 stall 있는 run만. irun 교차는 S4-8. hierarchy.md에 `argmax_red`의 `max_o`와 S4-4 세부 반영 필요.
- 다음: S4-5(GEMV PIM형 IP).

## 2026-11-19: S4-5 GEMV PIM형 IP  [notion: synced]
- 한 일(hw-worker): `rtl/l1/pim_gb.sv`, `pim_bank.sv`, `pim_ctrl.sv`, `rtl/l2/pim_core.sv`, `rtl/l3/pim_csr.sv`, `pim_top.sv`(직접 작성 RTL)와 모듈별 TB, `docs/spec/pim.md`(명령 형식, 레지스터 맵, 실행 규칙, cycle 식). 기존 RTL은 수정 없음.
- 결과 [측정, 수퍼바이저 재실행]: `./sim/run.sh all` 262 run, fails 0(기존 201 + 신규 61).
- agent 보고(재실행 안 함): 260K K_GEMV 레코드 432개(42,144행) 전부 y mismatch 0(layer 순서 실행, token 한 run, 레코드별 run). LDW 뒤 bank 메모리 == `bimg_pack` image. 명령 수 카운터 == `bank_stat_t`. mutation 29개 중 28개 검출, 1개는 동치(FLUSH는 core가 idle일 때만 시작). lint 경고 0.
- cycle [측정, 시뮬레이션, stall 없는 latency 1 메모리 모델]: MACAB `C_mac = ceil(rows/4) x ceil(n/16) + 12`(기본 조건), 모든 MACAB에서 식과 일치. 260K token당 MAC cycle 4,072(S4-0 계산과 같음), `pim_top` CYCLES는 token 한 run(57 명령) 4,501~4,506, layer마다 run 4,658~4,676, 레코드별 run 약 6,950. 초기 적재 LDW 36개 36,305 cycle.
- 가속기형 대비 [측정, 시뮬레이션]: 같은 260K에서 가속기형 P = 1의 37,596 cycle 대비 PIM형 token 한 run이 8.35배, layer마다 run이 8.05배 적다(MAC만 비교한 계산값은 8.95배). 보드의 HP latency와 ARM 호출 비용(명령 push 57회)은 포함되지 않았다.
- 정한 세부(pim.md): 명령은 CMD_PUSH 시점에 검사하고 오류 명령은 FIFO에 넣지 않음, CTRL op RUN/FLUSH, ERR 비트 8개, 두 round의 마지막 word 간격 4 cycle 이상(n <= 48이면 round가 4 cycle), y는 credit(`Y_DEPTH` 32)과 `sync_fifo`, HP 포트 하나의 read/write 채널 사용.
- RDROW: 구현하지 않음(op 4는 BAD_CMD). embedding은 ARM에 남는다.
- 자원 [계산, 합성 안 함]: 8x8 곱 64개 + scale 3 = 67, bank BRAM36 64개(tag 16비트가 parity에 들어간다는 전제, Vivado 추론 미확인). 관찰(오케스트레이터): `pim_ctrl`이 LDW 읽기 길이를 `rows x 레코드 크기` 곱으로 구해 합성 시 곱셈기 하나가 더 들 수 있다.
- 한계: 100 MHz 타이밍(bank 깊이 mux와 gather mux가 scale 앞 조합), LUT 수, parity 추론 미확인. `pim_top`은 NB = 4만 실행(NB 2/8은 `pim_ctrl`에서만). mutation 실행 방식의 cmdline 샘플 확인은 이번에 하지 않음(agent 보고).
- 다음: S4-6(attention IP).

## 2026-11-20: S4-6 attention IP  [notion: synced]
- 한 일(hw-worker): `rtl/pkg/lut_pkg.sv`, L0 `udiv_seq`, `lut_lerp`(EXP2N), L1 `exp_unit`, `attn_score`, `attn_vacc`, L2 `attn_core`, `kv_store`(BRAM KV), `kv_rd`(DDR KV), L3 `attn_csr`, `attn_top`와 TB, `docs/spec/attn.md`. golden에 attention stage 함수 5개 export(`k_attn_score`, `k_attn_exp`, `k_attn_pn`, `k_attn_w`, `k_attn_out`), `attn_core`가 이 함수들로 계산.
- 결과 [측정, 수퍼바이저 재실행]: `make test` TOTAL 16,669,793 항목 mismatch 0. `./sim/run.sh all` 345 run, fails 0(기존 262 + 신규 83).
- agent 보고(재실행 안 함): K_ATTN2 레코드 260K 480개(T 1..512, hs 8)와 15M 216개(hs 48) 전부에서 p, o mismatch 0, stage trace 대조. 추가 형식 HB(K8V8), HD(K16V16) 덤프도 벡터로 사용. `attn_top`은 260K forward 순서(위치마다 layer 0..4에 KVW 후 ATTN, KVW 2,560개), KV_SRC 0/1, H_PAR 1/2. 기존 덤프 4종은 golden 변경 전과 `cmp` 동일. mutation 42/42 검출(첫 회차 생존 3개는 TB 공백이라 방향성 벡터 추가). lint 경고 0.
- cycle [측정, 시뮬레이션, stall 없는 latency 1 모델]: head 하나 `C = (T+1) x ceil(hs/8) + T + T x ceil(hs/8) + hs + C0`, `C0` 기본 60. 260K(hs 8)는 3T + 69(S4-0 추정 3T + 80). token당 ATTN CYCLES: 260K H_PAR 2, T 512에서 32,420(계산 32,320), H_PAR 1은 64,685. 15M DDR KV, T 256에서 H_PAR 1 198,294(계산 196,416), H_PAR 2 99,496. KVW는 260K token당 190 cycle. `p_en` = 1이면 260K T 512에서 34,983.
- 정한 세부(attn.md): op ATTN과 KVW 두 가지(명령 FIFO 없음), q 레코드 형식, p의 head 간격은 8 x ceil(T/2) B(write engine이 8 B 정렬 주소만 받음), top은 hs가 8의 배수만, `attn_ctrl`을 두지 않고 pass FSM을 `attn_core` 안에 둠, vs buffer 추가, `lut_lerp`는 EXP2N만(SIGM은 S4-7).
- 자원 [계산, 합성 안 함]: DSP engine당 33(H_PAR 2면 66), kv_store BRAM36 60, engine당 BRAM18 2개(vs buffer로 arch.md보다 engine당 0.5 증가). 260K PIM형 시스템 BRAM36 합계 126 -> 127/140.
- 문제(오케스트레이터 확인): `attn_csr`의 descriptor 범위 검사와 `attn_top`, `kv_rd`의 주소 계산이 조합 곱셈이다(일부 64비트 폭 표현). `pim_ctrl`, `pim_csr`, `gemv_acc_csr`, `gemv_acc_top`, `kv_store`에도 소수 있다. 기능은 맞지만 합성 시 DSP 추가 사용과 100 MHz 타이밍 위험이 있어 S4-6b로 정리한다. `attn_csr` 단독 TB가 없는 것(방법론 일탈)도 S4-6b에서 보완.
- 한계: 100 MHz 타이밍, LUT 수, 210비트 word의 BRAM 추론 미확인. CYCLES는 latency 1 모델 값. irun 교차는 라이선스 정책상 하지 않음.
- 프로세스 노출(agent 보고): mutant 번호(숫자)를 명령행 환경 대입으로 넣은 것, 1초 미만의 패치 명령에 TB 경로가 보인 것 두 건.
- 다음: S4-6b, 이어서 S4-7(vec IP).

## 2026-11-20: S4-6b 합성 품질 정리(runtime 곱셈 제거)  [notion: synced]
- 한 일(hw-worker): L0 `umul_seq`(순차 shift-add 곱셈기) 추가. `attn_csr`, `attn_top`, `kv_rd`, `kv_store`, `pim_ctrl`, `pim_csr`, `pim_top`, `gemv_acc_csr`의 주소 계산과 descriptor 범위 검사를 상수 shift, 증분 덧셈, 순차 계산으로 교체. `attn_csr`의 runtime 나눗셈(`kvmax`)도 상수 곱 비교 또는 `udiv_seq`로 교체. `attn_csr` 단독 TB 추가. spec 문서(`attn.md`, `gemv_acc.md`, `pim.md`, `hierarchy.md` 3.10) 갱신.
- 결과 [측정, 수퍼바이저 재실행]: `./sim/run.sh all` 368 run, fails 0(기존 345 + `umul_seq` 13 + `attn_csr` 10). RTL 재검색에서 top과 CSR에 남은 곱셈은 상수 곱과 시뮬레이션 전용 검사뿐(수퍼바이저 확인).
- agent 보고(재실행 안 함): 판정(ERR 조건), 주소, 데이터는 그대로. mutation 42/42 검출, lint 경고 0. 순차 유닛 수: `attn_csr` umul 5개(BRAM KV) 또는 6개 + udiv 1(DDR KV), `gemv_acc_csr` 1, `pim_csr` 2, `pim_ctrl` 1.
- 바뀐 timing(spec 문서에 명시): CTRL 수락 뒤 descriptor 검사 구간이 생겼다. `attn_csr` 10 cycle(BRAM KV) / 18(DDR KV), `gemv_acc_csr` 9, `pim_csr`의 CMD_PUSH 검사 9(검사 중 push는 새 ERR 비트 PUSH_BUSY), `pim_ctrl`의 LDW 읽기 명령 +9. busy는 검사 구간을 포함하고 CYCLES = e - s에 검사 cycle이 들어간다. 오류 호출은 done 없이 ERR만 선다.
- CYCLES 재측정 [측정, 시뮬레이션, latency 1 모델]: 260K attention token당(H_PAR 2, T 512) 32,420 -> 32,470. 15M attention(DDR, H_PAR 1, T 256) 198,294 -> 198,403. gemv_acc 260K token P = 1 37,903~37,938(이전 37,560~37,616), 15M token 1,951,992. PIM token run 4,499~4,506(변화 없음), LDW 36개 36,629. 가속기형 대비 PIM형 비율은 약 8.4배로 유지.
- 문서 정정: `attn.md`의 dot 누산 폭을 RTL 식(HS_MAX 64에서 39비트)으로. `exp_unit`의 곱 레지스터 49비트는 필요 폭(47비트)보다 2비트 넓게 잡은 것.
- 한계: 합성하지 않았으므로 DSP 감소와 100 MHz 타이밍 효과는 [계산]/[추정]. 무작위 주소 run의 CYCLES 차이가 정확히 검사 cycle만큼이 아닌 경우는 BFM 난수열 밀림으로 판단(호출 단위 대조는 안 함).
- 프로세스 노출(agent 보고): 대기용 감시 명령에 프로젝트 경로가 들어가 약 15분씩 두 번 보였다. `process-privacy.md`에 대기 명령 규칙 추가.
- 다음: S4-7(vec IP).

## 2026-11-20: S4-7 vec IP  [notion: synced]
- 한 일(hw-worker): L0 `rsqrt_nr`, `lut_lerp`에 SIGM 모드, L1 `actq_core`, `rms_front`, `swi_front`, L2 `vec_core`, L3 `vec_csr`, `vec_top`과 TB, `docs/spec/vec.md`. `lut_pkg.sv`에 SIGM, RSQ 표 추가(EXP2N 표는 불변). `model/src`는 변경 없음.
- 결과 [측정, 수퍼바이저 재실행]: `./sim/run.sh all` 424 run, fails 0(기존 368 + `lut_lerp` SIGM 4 + 신규 52).
- agent 보고(재실행 안 함): 두 모델의 K_RMSNORM, K_SWIGLU, K_ACTQ, K_ARGMAX 레코드 전부에서 mismatch 0(`vec_top`은 forward 순서로 260K 1,224 호출, 15M 804 호출). `actq_core`를 rmsnorm, swiglu가 공유해도 bit-exact임을 실행으로 확인(S4-0의 코드 대조 판단). mutation 35개 중 33개 검출, 2개 동치. 첫 회차 생존 중 2개는 TB 공백(특정 amax에서만 드러나는 clamp)이라 방향성 벡터 추가. lint 경고 0. top과 CSR에 runtime 곱셈 없음(descriptor 검사는 shift와 덧셈, 검사 1 cycle).
- cycle [측정, 시뮬레이션, latency 1 모델]: `vec_core` RMSNORM 4n + 87, SWIGLU 3n + 67, ACTQ 2n + 59, ARGMAX n + 1(S4-0 추정: 4n + 130, 2n + 110, 2n + 54 + L). SWIGLU가 3n인 것은 HP 포트 하나로 h1, h3를 차례로 읽기 때문.
- token당 합 [측정, 시뮬레이션]: 260K RMSNORM 3,993 / SWIGLU 3,005 / ACTQ 8,155(85 호출) / ARGMAX 527, 합 약 15,680. 15M 16,321 / 14,386 / 23,019(114 호출) / 32,015, 합 약 85,741. head별 ACTQ가 호출 수의 대부분이고 호출마다 나눗셈 두 번(약 52 cycle)이 지배한다.
- 자원 [계산, 합성 안 함]: DSP 약 16(S4-0 추정 14), BRAM36 2(추정 0.5~1). 260K PIM형 시스템 BRAM36 합계 127 -> 129/140.
- 관찰(오케스트레이터): 260K 시스템의 token당 cycle(시뮬레이션)은 PIM형 GEMV 약 4,500, attention 위치 512에서 약 32,500, vec 약 15,700이다. GEMV를 PIM으로 줄이면 병목이 attention과 양자화로 옮겨 간다. head별 ACTQ를 attention 앞단에 융합하는 것은 S5의 검토 대상(arch.md 5.1의 권고와 같은 방향).
- 수정(오케스트레이터): `attn_csr` 헤더 주석의 CONFIG3 필드 이름을 코드와 같게(TMAX). `pim.md`의 가속기형 대비 비율 문장을 S4-6b 재측정값으로.
- 한계: 100 MHz 타이밍, LUT 수, DSP 매핑 미확인. CYCLES는 latency 1 모델 값. `rsqrt_nr`의 Newton 중간값 폭은 해석적 상한과 시뮬레이션 검사로만 확인.
- 프로세스 노출(agent 보고): 1초 미만 명령 두 건에 테스트 이름과 경로가 보임. TB 버그로 4.8 GB 로그가 생겨 즉시 중단하고 삭제, 이후 job에 파일 크기 제한을 넣음.
- 다음: S4-8(전체 정리, viewer), S5(시스템 통합) 계획.

## 2026-11-20: S5-0 시스템 통합 스펙  [notion: synced]
- 한 일(hw-worker): `spec/system.md`(빌드 목록, HP/GP 배정과 주소 맵, 자원, SW 실행기와 오프로드 mask, 드라이버, golden 배치와 IP 배치의 차이, 호스트와 RTL 검증 방안, 측정과 추정 계획, 융합 후보), `spec/s5calc.py`, plan의 S5-1~S5-6.
- 구조: bitstream 2개. A = `gemv_acc` P 1 + `attn`(DDR KV, H_PAR 1) + `vec`, 15M 주 대상이고 260K도 실행 가능(가속기형 대 PIM 비교를 같은 빌드로). P = `pim` + `attn`(BRAM KV, H_PAR 2) + `vec`, 260K. kernel별 오프로드는 한 bitstream 안에서 SW의 런타임 mask로 켜고 끈다(kernel 경계가 DDR 버퍼이고 forward가 순차라서 가능).
- 자원 [계산, LUT는 추정]: A는 DSP 60/220, BRAM36 약 3. P는 DSP 149/220, BRAM36 128/140(S4-7 로그의 129는 이중 계산, 정정). P의 BRAM은 bank(144비트)와 kv_store(210비트)가 parity 비트를 데이터로 쓰는 매핑을 전제로 하며, 안 되면 180/140으로 넘친다. 대안 순서: primitive wrapper, vec N_MAX 256, KV를 DDR로 옮긴 빌드, 빌드 분할.
- PL 시간 [계산, 100 MHz 가정, 입력은 latency 1 시뮬레이션 cycle, ARM 쪽 비용 제외]: 빌드 P 전부 오프로드 375.6~400.1 us/token(위치 평균). 빌드 A(15M) 21.08 ms/token, 그중 GEMV 92.6%, HP 포트 하나의 이론 대역폭 하한 19.48 ms.
- 검증 방안: (i) C 수준: spec 기반 IP 레지스터 모델과 cache 모사(flush/invalidate 누락 검출), 결함 주입 10종. (ii) RTL 수준: 시스템 top + 공유 메모리에 같은 드라이버 C 코드를 DPI로 연결해 forward를 돌리고 token과 logits hash를 PC 기대값과 비교(G5 기준).
- 결정(오케스트레이터): 열린 결정 O1~O13을 권고대로 확정(`spec/system.md` 10절). 융합은 v1에 분류기 + argmax만.
- 미확인: 보드 수치 전부(ARM baseline, HP 대역폭, 호출 비용, timing, LUT), parity 매핑, Questa에서 시간을 쓰는 DPI exported task, 빌드 A 구성의 260K attention과 vec N_MAX 256 구성(시뮬레이션 안 함), Xilinx cache 관련 세부.
- 다음: S5-1(시스템 SW와 호스트 모델), S5-2(`axil_xbar`, 시스템 top).

## 2026-11-20: S5-1 시스템 SW와 호스트 검증  [notion: synced]
- 한 일(hw-worker): `model/src`에 실행기 끼움점 `lm_h_forward_x`(kernel 호출을 실행기 포인터로 넘김, 기존 `lm_h_forward`는 불변). `fpga/sys/sw/`: 실행기 `sx_exec`(오프로드 mask 8비트, opt 비트, fallback 계수, 지연 실행과 barrier, WRGB 생략, KVW 발행), IP 드라이버 4개, 초기화(행 레코드 재배치, bank 적재, KV 관리), 측정 분해와 로그, K 모드(kernel 단위 그림자 비교), 보드용 HAL(`hal_xil.c`). `fpga/sys/test/`: spec 문서 기반 호스트 IP 레지스터 모델 4개와 cache 모사, 호스트 테스트.
- 결과 [측정, 수퍼바이저 재실행, PC x86-64]: `make test` TOTAL 16,686,497 항목 mismatch 0(새 그룹 `forward_x executor` 포함). 시스템 호스트 테스트 `SYSHOST items=34 fail=0`, PASS. baseline `HOSTTEST items=23 fail=0`, PASS.
- agent 보고(재실행한 테스트의 내부 수치, 개별 확인 안 함): 684 run(빌드 A/P, 두 모델, mask와 opt 21종, run 종류 E/T/P/K/W, 64비트와 `-m32`)에서 token, logits hash, KCMP, COH, fallback, IPERR 모두 0. KCMP 2,029,960 호출 mismatch 0. 결함 주입 12종(flush 누락, invalidate 누락, q 레코드 순서, KV layer base, bank base 겹침, WRGB 생략 오류, barrier 위반, 응답 오류, timeout, 보호 조건 우회, 레지스터 순서)이 각각 고유한 증거로 검출됨. 덤프 4종은 변경 전과 `cmp` 동일.
- 줄인 것: 15M은 mask 전체 조합을 24 위치로, 전 위치(256)는 mask 0/ff와 9개 mask의 E run만. `-m32`는 260K 64 위치, 15M 16 위치.
- spec 보완 대상(agent가 가정으로 정한 것, RTL은 보지 않음): cache 일관성 검사를 읽는 쪽별로 나눈 규칙(system.md 3.1에 기록), vec RMSNORM의 fx, attention q 레코드의 kb = 8 container, 응답 오류 때 STATUS의 done과 err 동시 표시, ARGMAX의 OUT_ADDR, 닫힌 CYCLES 식이 없는 경우(PIM 여러 명령 run, attention op 단위, gemv_acc P = 2)의 추정. S5-3/S5-4에서 RTL과 대조해 확정한다.
- UNVERIFIED: `hal_xil.c`(Xilinx API, cache L1/L2 동작, 물리 주소 가정), ARM 컴파일과 실행, 부분 cache line invalidate 동작. 호스트의 시간과 Amdahl 표는 측정값이 아니다.
- 프로세스 노출(agent 보고): 초기 몇 번 명령 문자열에 `model`, `fpga/sys/test` 경로 조각이 최장 약 2.5분 보임(프로젝트 이름은 아님). 이후 루트의 job 파일로 변경.
- 다음: S5-2 검수, S5-3(시스템 TB 기반: 공유 메모리, 드라이버 C 코드의 DPI 연결).

## 2026-11-23: S5-2 axil_xbar와 시스템 top  [notion: synced]
- 한 일(hw-worker, 2026-11-20 작업): `rtl/l4/axil_xbar.sv`(AXI4-Lite 1 -> N, slot 4 KiB, 빈 slot은 읽기 0과 OKAY, register slice parameter), `rtl/l4/sys_a_top.sv`, `sys_p_top.sv`(인스턴스와 배선만)와 TB(`tb_axil_xbar`, 두 top 공용 `tb_sys_top`). system.md 1.7절과 hierarchy.md 3.12절에 확정 세부.
- 결과 [측정, 수퍼바이저 재실행]: `./sim/run.sh all` 465 run, fails 0(기존 424 + axil_xbar 30, sys_a_top 6, sys_p_top 5).
- agent 보고(재실행 안 함): xbar mutation 8/8, top 배선 mutation 9/9 검출(slot 교환, HP 포트 교환, parameter 값, reset 누락, tie-off, SLOT_EN). lint 경고 0. smoke는 slot별 ID/CONFIG 대조, 빈 slot 0, IP마다 호출 하나를 golden(DPI)과 대조, 호출마다 burst가 나간 HP 포트 집합이 기대와 같은지 검사.
- xbar latency [측정, 시뮬레이션, TB slave 모델]: register slice 켬(기본)에서 단일 읽기와 쓰기 3 cycle, back-to-back 주기 4 cycle. 실제 GP0 왕복 시간은 보드 측정 전.
- 배정: GP0 0x43C0_0000, slot = addr[15:12]. 빌드 A는 slot 0 gemv_acc, 2 attn, 3 vec. 빌드 P는 slot 1 pim, 2 attn, 3 vec. HP0 gemv_acc 또는 pim, HP1 attn engine 0(쓰기 포함), HP2 attn engine 1 read(P) 또는 gemv slice 1(A2), HP3 vec.
- 미룬 것(S5-3): 두 HP 포트가 같은 버퍼를 봐야 하는 kernel 연쇄와 forward, 드라이버 C 구동, smoke에서의 CYCLES 식 대조.
- 한계: A의 attention H_PAR 2 구성과 P의 H_PAR 1 구성은 elaboration과 lint만. 합성, timing, 보드 동작 미확인.
- 다음: S5-3(시스템 TB 기반), S5-4(forward G5).

## 2026-11-23: S5-3, S5-4 시스템 TB와 forward 검증 (G5 시뮬레이션 부분)  [notion: synced]
- 한 일(hw-worker): `axi_mem_slave`에 `EXT_STORE`(HP 포트 4개가 C 쪽 DDR 이미지 하나를 공유)와 `inj_hang`. DPI HAL(`tb/sys_top/hal_dpi.c`, `plat_dpi.c`): `fpga/sys/sw`의 실행기와 드라이버를 수정 없이 컴파일해 `hal_rd`/`hal_wr`가 exported task로 AXI-Lite 트랜잭션을 내고 시뮬레이션 시간을 쓴다. S5-1의 cache 모사를 `hal_cache.c`로 분리해 RTL의 beat마다 일관성 검사가 돈다. 시스템 TB `tb_sys_fwd`, 테스트 `sys_smoke`(2 run), `sys_fwd`(21 run).
- 결과 [측정, 수퍼바이저 재실행]: `./sim/run.sh all` 488 run, fails 0(기존 465 + 23). 시스템 호스트 테스트 `SYSHOST items=36 fail=0`, baseline `HOSTTEST items=23 fail=0`. 로그 확인: 15M 위치 0..3 run은 tok_mis 0, hash_mis 0, coh 0, fb 0, iperr 0, CYCLES 식 대조 704건 불일치 0.
- 범위(agent 보고): 빌드 P 260K(초기화 LDW, 위치 0..3, 위치 511 warm, mask 비트 단독 8종, mask 6종, opt 5종, XB_REG 0, 변형 PD), 빌드 A 260K(위치 0..3, 비트 단독, 위치 511, 변형 A2)와 15M(위치 0..3, K 모드 0..1, 위치 255 warm), 오류 주입 6종(읽기 응답, 쓰기 응답, 무응답을 빌드마다). 모든 정상 run에서 token, logits hash, K 비교, COH, fallback, IPERR 0.
- 버그: (1) SW `drv_com.c`: IP timeout으로 그 IP를 끈 뒤 cache를 맞추지 않아 ARM 대체 실행이 옛 값을 읽음(빌드 A에서 logits hash 2 위치 불일치). timeout 시 `hal_flush_all()` 호출로 수정. 호스트 테스트의 결함 주입 case가 기대 FAIL에 COH를 가려 놓쳤던 것이라 오류 뒤 데이터를 보는 2항목(f08b, f09b) 추가. (2) 호스트 IP 모델 `ipm_ga.c`: P = 2, 짝수 ROWS의 +1 cycle 누락. (3) RTL 버그 없음.
- S5-1 가정 판정(agent 보고): cache 검사 규칙, RMSNORM fx, 응답 오류 때 STATUS 0x6, ARGMAX의 4 B 쓰기는 RTL과 일치. kb 8 q 레코드는 코드 대조만(실행 안 함).
- 호스트 모델 CYCLES 대 RTL(agent 보고): gemv_acc P = 1, vec 4 op, attn KVW 전부 일치. PIM run +0.02~+0.35%, attention BRAM 묶음 +0.26%, head 단위 -5.8%, DDR KV -2.6~-4.9%(추정식으로 남김).
- CYCLES [측정, 시뮬레이션, latency 1, stall 없음, token당]: 빌드 P 260K 23,501(PIM 5,681, vec 15,680, attention 2,140), AXI-Lite 포함 31,688. 빌드 A 260K 57,198, 포함 63,819. 빌드 A 15M 2,012,535(GEMV 1,952,048), 포함 2,021,290. 위치 255 warm 2,209,722.
- mutation(agent 보고): 드라이버 4종, top 배선 1종, IP 내부 2종, fault hook 7종 검출. 동치 mutant 2개(이유 기록).
- 미확인: 메모리 stall과 random latency 아래의 시스템 TB(전부 latency 1), kb 8 실행, PIM "레코드마다 run"의 단독 측정(약 6,950) 대 시스템 TB(5,846) 차이의 원인, timeout 뒤 PL reset 경로, 보드 동작 전부.
- 프로세스 노출(agent 보고): DPI 컴파일 중 cc1 인자에 상대 경로 소스 이름이 파일당 1초 미만 보임. 초기 1초 미만 명령 몇 개에 프로젝트 경로.

## 2026-11-23: S5-5 Vivado/XSCT 스크립트  [notion: synced]
- 한 일(hw-worker): `fpga/sys/`에 `create_project.tcl`(BUILD=A|P, 변형 A2/PD, PS7 + interconnect + module reference, 주소와 DDR segment 검사, `sys_build_config.txt`), shell `src/sys_a_bd.v`, `sys_p_bd.v`, `filelist.tcl`, `build.tcl`(utilization 계층, RAM/DSP 셀 목록, timing, `summary.txt`), `sw/xsct_build.tcl`(PL 프로그래밍, 15M 이미지 DDR 적재 포함), `test/stub_check.tcl`, README 4절(실행 순서, 측정 순서, 돌려받을 것, UNVERIFIED).
- 결과: stub 검사 `STUBCHECK runs=43 fail=0` [수퍼바이저 재실행]. shell lint 9구성 경고 0, 오류 4종 주입 시 stub 검출 4/4 [agent 보고]. 스크립트와 system.md 사이 불일치 없음.
- UNVERIFIED: Vivado와 XSCT에서 한 번도 실행하지 않음(속성 이름, module reference의 인터페이스 추론, 연결하지 않은 m02_axi의 validate, 합성 결과 전부, 100 MHz timing, BRAM parity 매핑).
- 다음: 사용자 빌드(S5-6 리포트 분석), S4-8 정리.

## 2026-11-23: S5-4 보완: stall 아래 forward, PIM cycle 수치 정정, vec RD_STALL 수정  [notion: synced]
- PIM "레코드마다 run" cycle 차이의 원인(hw-worker): `system.md` 4.4절의 "약 6,950"은 `pim_top` TB의 random stall run(20% stall, R latency 1~30) 값(평균 6,974)이었다. stall 없이 같은 TB를 다시 돌리면 위치 0..3에서 5,822~5,852이고 시스템 TB의 5,846과 맞는다. RTL 차이 없음. `system.md`, `pim.md`, `s5calc.py`와 다이어그램 두 곳을 고침. 빌드 P의 PL 시간 [계산, 100 MHz 가정]은 375.6~389.1 us/token(이전 상한 400.1). 이 로그의 이전 항목에 적힌 6,950과 400.1은 이 항목으로 대체한다.
- stall 아래 시스템 forward(hw-worker): `tb_sys_fwd`에 `+PROF`(HP 메모리 모델의 random stall과 latency), run 3개 추가(`p_stall` 빌드 P 260K, `a_stall` 빌드 A 260K, `a_m2_stall` 빌드 A 15M 위치 0). token, logits hash, K 비교, COH, fallback, IPERR, AXI 위반 모두 0. stall run에서는 CYCLES 닫힌 식을 하한으로 검사.
- RTL 버그(성능 계수기, 데이터 영향 없음): `vec_top`의 RD_STALL이 구조상 항상 0이었다(`vec_core`의 `d_ready_o`가 `d_valid_i`를 포함해 `axi_rd_eng.stall_o` 조건이 성립하지 않음). `vec_core`에 `d_want_o`를 추가하고 `vec_top`이 `rd_busy && d_want && !d_valid`로 세게 수정. `d_ready_o`와 cycle 수는 불변. unit TB가 DUT 내부 event를 그대로 세어 놓쳤던 것이라 `tb_vec_top`, `tb_vec_core`, `tb_attn_top`, 시스템 TB에 기대값과 "> 0" 검사 추가. 호스트 모델 `ipm_ve.c`도 맞춤(latency 1에서 op당 4).
- 결과 [측정, 수퍼바이저 재실행]: `./sim/run.sh all` 491 run, fails 0. 시스템 호스트 테스트 `SYSHOST items=36 fail=0`. stall run 로그: vec RD_STALL 합 7,381(p_stall, HP3 R stall 8,493), 2,662(a_m2_stall, 2,742). gemv_acc RD_STALL 488,213(a_m2_stall), pim 39,860(p_stall).
- agent 보고(재실행 안 함): 수정 전 RTL로 `tb_vec_top` 12 run 중 11 FAIL, 시스템 stall run 3개 FAIL. mutation 3종 검출. lint 경고 0. 다른 IP(gemv_acc, pim, attn)는 ready가 valid에 의존하지 않아 같은 문제 없음.
- stall run의 RUN ticks/token [측정, 시뮬레이션, TB random 모델이라 보드 값 아님]: p_stall 43,613(stall 없음 31,688), a_stall 85,953(63,819), a_m2_stall 2,514,750(2,021,290).
- 미확인: 메모리 모델의 random 패턴은 `+SEED`로 바뀌지 않음(시뮬레이터 기본 seed). stall 아래 오류 주입 조합, 변형 빌드의 stall run, gemv_acc WR_STALL이 시스템 run에서 0인 이유, vec N_MAX 256 구성의 시뮬레이션.
