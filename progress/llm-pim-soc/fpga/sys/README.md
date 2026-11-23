# fpga/sys: 시스템 프로그램과 호스트 검증 (S5-1)

ARM에서 도는 H판(K12V8) forward의 kernel 호출을 런타임 오프로드 mask에 따라 PL IP 4개(`gemv_acc_top`, `pim_top`, `attn_top`, `vec_top`)로 보내는 bare-metal 프로그램과, 보드 없이 이 서버에서 그 흐름을 검사하는 호스트 테스트다. 설계 원본은 `docs/spec/system.md` 2절(SW 구조), 3.1절(호스트 검증), 2.6절(측정과 로그). 보드 실행 절차(Vivado BD Tcl, XSCT 빌드, 측정 순서, 돌려받을 것)는 4절(S5-5).

- 이 디렉토리의 수치는 전부 호스트(PC x86) 실행이다. 호스트 로그의 시간은 PC 시간이고, `pl`은 IP C 모델이 spec 문서의 CYCLES 식(latency 1 메모리 모델)으로 채운 값이라 측정값이 아니다(`call`이 음수가 될 수 있다). 보드 측정은 S6.
- `fpga/sw/`(ARM baseline)는 바꾸지 않았다. 재사용: `plat.h`/`plat_host.c`/`plat_xil.c`(시간, UART, DDR 이미지), `out.c`(로그 한 줄), `lmhash.c`, `exp.c`와 `fpga/sw/expect/exp_m*.h`(PC 기대값), `prof.c`(lap probe, 행렬 구분), `gen/m1_data.c`(260K 내장 배열). 파서 `fpga/sw/tools/parse_log.py`는 `LMSYS` 블록을 읽도록 확장했다(baseline 경로는 그대로).

## 1. 구성
```
sw/  sys_main.c   BEGIN/END, BUILD/CLK/PLAT/SYS 줄, 모델마다 sbench
     sbench.c/h   H판 하나: 초기화, run 목록(mask, opt) x run 종류 E/T/P/K/W, KERN/KSPLIT/KCMP/CHECK
     sx_exec.c    실행기 sx_exec (k_exec_fn): mask, 보호 조건, 지연 실행과 barrier, cache 규칙,
                  x 세대와 WRGB 생략, 호출 단위 시간 분해, run K 그림자 비교
     sysmem.c     IP 탐지(ID slot, SYS), 행렬 표, 행 레코드(rrec_pack), PIM bank base, LDW,
                  사용 가능 여부(AVAIL), 실행기 버퍼(q 레코드, p 버퍼, 그림자), sx_kv_sync
     drv_com.c    레지스터 shadow(바뀐 것만 쓰기), CTRL + STATUS polling(시간 한도), ERR W1C, IPERR
     drv_ga.c drv_pi.c drv_at.c drv_ve.c   IP별 호출 순서
     ipregs.h     offset과 bit (원본: gemv_acc.md 2, pim.md 2-3, attn.md 3, vec.md 3)
     hal.h        보드/호스트 계층: io32, pa, flush/invalidate, arena, (호스트) 일관성 검사
     hal_xil.c    보드용 (Xilinx BSP, UNVERIFIED)
     scfg.h       빌드 옵션: SYS_MASK_LIST, SYS_RUN_MASK, SYS_STEPS, SYS_FCLK_HZ, SX_FAULT_INJ
create_project.tcl build.tcl filelist.tcl zybo_z7_20.xdc src/sys_a_bd.v src/sys_p_bd.v
                  Vivado 빌드 A/P (4절, S5-5)
sw/xsct_build.tcl Vitis classic platform + app, JTAG 실행 (4절)
test/ hal_host.c  호스트용 hal: slot 16개에 IP 모델, cache 모사, 결함 주입(IP 쪽)
      ipm.h ipm_ga.c ipm_pi.c ipm_at.c ipm_ve.c   IP C 레지스터 모델 (spec 문서로 작성)
      Makefile run.sh xilstub/ stub_check.tcl(4절)
```
`model/src`는 `lm_h_forward_x`(실행기 끼움점, `model/README.md`)만 추가했다.

### 실행기 규칙 (system.md 2.2, 구현에서 정한 세부)
- 분류: K_GEMV는 가중치 포인터로 행렬을 찾고(cls면 C, 아니면 G), K_ACTQ는 출력이 `a8`이면 Qa, 아니면 Qh, K_ATTN2는 A, K_RMSNORM R, K_SWIGLU S, K_ARGMAX M. K_EMBED/K_ROPE/K_ADD는 항상 ARM.
- IP로 보내는 조건: mask 비트, 모델의 사용 가능 여부(`AVAIL`), IP가 죽지 않음(timeout 뒤), 보호 조건. 보호 조건 실패와 죽은 IP는 ARM으로 실행하고 `fb`로 센다(0이 아니면 run FAIL). 사용 가능하지 않은 비트를 요구하는 (mask, opt)는 `SKIP`(예: 빌드 P의 15M은 PIM depth 237,312 > 4,096, BRAM KV hs 48 > KL 8이라 G, C, A를 못 쓴다).
- 보호 조건(system.md 2.2 표 + 이번에 더한 것): GEMV는 행렬이 표에 있고 gs = n, n <= NMAX, rows <= 65535, xm < 2^17, we/xe/fo가 signed 8비트(EXP 필드 폭). ATTN은 K_ATTN2, kb/vb/hs가 모델과 같고 hs % 8 = 0, hs <= HS_MAX, T <= TMAX, T <= seq, exp_bits 8, 창 없음(첫 위치 0), kv head = j / KVMUL(포인터에서 계산한 배치와 일치), BRAM이면 hs <= KL, kb <= KW, vb <= VW, layer < NL, kv head < NKV. vec는 MANT, n <= N_MAX, f/fy/ge가 signed 8비트, epsc >= 0, SWIGLU sb = 8, ACTQ qmax in {127, 2047, 32767}, ARGMAX n <= 2^IDX_W.
- 지연 실행: `DEFER_AT`는 head j의 q를 q 레코드 j에 복사하고 마지막 head(j = nh - 1)에서 ATTN op 하나(HEAD0, NHEAD)를 낸다. `PIM_BATCH`는 x 주소와 x 세대가 같은 K_GEMV의 MACAB를 쌓아 두고 barrier에서 RUN 한 번. 쌓인 일이 있을 때 들어갈 수 없는 호출(ATTN 묶음: K_ATTN2와 q head ACTQ만, PIM 묶음: 같은 x의 IP GEMV만)이 오면 먼저 실행하고 완료를 기다린다. forward의 마지막 호출(ARGMAX)도 그래서 barrier다.
- BRAM KV: layer l의 첫 ATTN 호출 때 (l, pos) KVW를 낸다. run W(warm start)는 `sx_kv_sync`로 지난 위치를 몰아 낸다.
- cache: run 시작과 초기화 끝에 전체 flush. mask != 0이면 ARM이 실행한 kernel의 출력과 드라이버가 쓴 메모리(q 레코드, ARGMAX index)를 곧바로 flush. IP 출력은 ARM이 이 run에서 읽을 때만 invalidate: q, k, o, w2의 y(rope, add), v는 Qh가 ARM일 때, w1/w3은 S가 ARM일 때, cls는 run T/P/K(hash) 또는 ARGMAX가 ARM일 때, `as`/`qh`/`qhs`(fwd_h.c와 q 레코드 복사가 읽음)는 항상, a8은 다음 GEMV가 ARM일 때, K/V slot은 A가 ARM일 때, att는 Qa가 ARM일 때. run K는 모든 IP 출력을 invalidate한다(그림자 계산이 읽음).
- 시간 분해(run P만): `pl` = (CYCLES - RD_STALL - WR_STALL) / f_PL, `mv` = 입력 준비(q 레코드 복사, push) + invalidate + stall / f_PL + ARM kernel의 생산자 flush, `call` = 나머지(레지스터 쓰기, 시작, polling, 카운터 읽기에서 CYCLES / f_PL을 뺀 것), `arm` = ARM `k_exec`. PIM 묶음은 첫 행렬 범주에, KVW는 attn에 들어간다(KERN lap도 같은 범주가 되도록 run P hook이 barrier를 따로 lap한다).

### 로그 (system.md 2.6 표 + 구현에서 정한 것)
`LMSYS BEGIN fmt=1` .. `LMSYS END`. baseline과 같은 `KEY name=value` 형식. mask와 opt는 `0x` 8자리.

| KEY | 필드 |
|---|---|
| `BUILD` | prog=sys plat hal opt optimize ptr_bits run_mask steps fault_inj cc |
| `CLK` | tps |
| `SYS` | build(A, P, -) hal ga pi at ve id_* cfg_* cfg2_pi cfg2_at cfg3_at ga_p pi_depth kv_src h_par tmax hs_max n_max idx_w fclk_mhz(IP CONFIG) fclk_hz(빌드 상수) other_slots |
| `AVAIL` | m v avail(mask 비트) build why rrec_bytes bank_words |
| `INIT` | m kind=rrec ticks bytes mats / kind=ldw ticks bytes cyc st_wrgb st_mac st_rdmac words rc |
| `SKIP` | m v mask opt avail |
| `KERN` | m v run mask opt k calls ticks us_tok pct (run P, baseline 범주) |
| `KSPLIT` | m v run mask opt k calls_ip calls_arm calls_fb arm pl mv call cyc rd_stall wr_stall ops (ticks; k는 KERN 범주에서 actq를 actq_h, actq_a로 나눈 것) |
| `KCMP` | m v run mask opt k calls mis first_pos first_call first_idx exp got (mis = 다른 원소 수) |
| `RUN` | m v run mask opt steps ticks ms ms_tok tok_s (P: probes) ip_ops |
| `COH` | m v run mask opt n old kind what k pos addr (호스트만; 첫 오류) |
| `IPERR` | m v run mask opt ip kind(timeout, err, nodone) err pos op (run당 16줄까지, 수는 정확) |
| `CHECK` | m v run mask opt n tok_mis hash_mis hash_req kmis coh fb iperr result |
| `MSUM`, `RESULT` | baseline과 같음(MSUM에 runs, skipped) |

## 2. 호스트 테스트
```sh
make -C fpga/sw/test data        # 처음 한 번: fpga/sw/gen/m1_data.c (baseline과 공유)
make -C fpga/sys/test test       # 마지막 줄 SYSHOST RESULT: PASS|FAIL, 로그 fpga/sys/test/build/logs/
```
공용 서버에서는 job 파일로 돌린다(`.claude/rules/process-privacy.md`). 설정은 환경변수로만 준다: `SX_BUILD`(A | P | 0), `SX_LIST`("mask:opt,..." hex), `SX_RUNS`(ETPKW 중), `SX_STEPS`, `SX_MODELS`(1, 2, 12), 결함 주입 `SX_FAULT`(1..7, 10, 11), `SX_IPFAULT`(rdresp | hang) + `SX_IPFAULT_OP`, 모델 구성 `SX_VE_NMAX`, `SX_AT_HSMAX`.

- **IP 모델**(`test/ipm_*.c`): spec 문서의 레지스터 맵, descriptor 검사(BAD_DESC, MISALIGN), BAD_OP/START_BUSY, ERR W1C, STATUS, PIM 명령 FIFO와 push 검사, CTRL 쓰기 안에서 op 완료. 결과는 IP가 받는 배치에서 `model/src` 함수로 계산한다: 가속기형 `rrec_unpack` + `k_gemv`, PIM `rrec_unpack` + `bimg_pack`(LDW), `bimg_unpack` + `bank_gemv`(MACAB), attention q 레코드 + DDR 배치 또는 KVW로 채운 모델 안의 KV 표 + `k_attn2_st`, vec `k_rmsnorm`/`k_swiglu`/`k_actq`/`k_argmax`. CYCLES는 gemv_acc 5절과 vec 6.2절의 닫힌 식, attention과 PIM은 문서의 식과 측정 직선으로 만든 추정(파일 머리 주석). RTL을 보지 않고 썼다.
- **cache 모사**(`test/hal_cache.c`, S5-3에서 `hal_host.c`에서 분리): CPU 메모리(arena 자체), DDR 이미지, 마지막 동기 값(syn), ARM 쓰기 표시의 네 배열. flush는 32 B line 단위로 ARM이 쓴 line을 통째로 DDR로 쓰고(IP가 쓴 byte를 덮으면 `flush_clobber`), invalidate는 범위 안의 line을 DDR에서 다시 읽는다(ARM이 쓰고 flush하지 않은 byte가 있으면 `inval_discard`, 범위 끝의 부분 line은 flush로 처리). 검사: ARM이 IP가 쓰고 invalidate하지 않은 byte를 읽음(`arm_rd_stale`), IP가 ARM이 쓰고 flush하지 않은 byte를 읽음(`ip_rd_dirty`) 또는 그런 line에 씀(`ip_wr_dirty`). 모든 line이 늘 cache에 있다고 보는 보수적 모델이다. 전체 flush에서 이전 run의 IP 데이터를 덮는 것은 오류가 아니라 `old`로 센다.
- **검사 항목**(`test/run.sh`): 아래 표. 각 matrix case는 rc 0, RESULT PASS, 파서 PASS, 기대 run 수, 모든 CHECK PASS(token, logits hash, KCMP, COH, fallback, IPERR 모두 0)를 요구한다.

| 구분 | case | 내용 |
|---|---|---|
| 1 | xilsyntax | `hal_xil.c`, `fpga/sw/src/plat_xil.c`, `sw/*.c` 전부를 보드 구성(HAL_HOST, 결함 hook 없음)으로 stub BSP 헤더에 `-fsyntax-only -Werror` |
| 2 | 64비트 matrix | mask/opt 21개(system.md 4.1 표 + DEFER_AT 끔, PIM_BATCH 켬, WRGB_SKIP 끔, COH_STRICT, FUSE_AM 끔, G+C PIM_BATCH) x run E/T/P/K/W. 260K 빌드 A, P 전 위치(512). 15M 빌드 A 24 위치, 15M 빌드 A 전 위치(256)는 mask 0, ff의 E/T/K와 9개 mask의 E. 15M 빌드 P 24 위치(사용 가능한 7개, 나머지 SKIP) |
| 3 | -m32 matrix | 260K 빌드 A, P 64 위치, 15M 빌드 A 16 위치, 15M mask 0/ff E/K 전 위치 |
| 4 | 결함 주입 | 아래 표. 각각 FAIL과 고유 증거 |
| 5 | 그 밖 | 보호 조건 fallback(N_MAX 32에서 Qa n = 64가 ARM으로 가고 fb로 FAIL), IP 없는 빌드(SYS 빈 slot, mask ff SKIP, mask 0 PASS), 파서(잘림, CHECK/KSPLIT/KCMP 변조, boot noise, CSV 행 수, Amdahl 표) |

| 결함 (system.md 3.1) | 주입 | 기대 증거 |
|---|---|---|
| (1) 생산자 flush 누락 | run의 첫 ARM 출력 flush 생략(K_EMBED x) | `COH kind=ip_rd_dirty`(RMSNORM IP가 x를 읽음) |
| (2) 소비자 invalidate 누락 | run의 첫 invalidate 생략(RMSNORM의 `as`) | `COH kind=arm_rd_stale`(fwd_h.c가 gemv descriptor를 만들며 `as`를 읽음) |
| (3) q 레코드 qm/qe 순서 | 드라이버가 {qe, qm}로 씀 | `KCMP k=attn mis>0` |
| (4) DDR KV layer base 한 layer 어긋남 | layer (l + 1) mod L의 base | `KCMP k=attn mis>0` |
| (5) PIM bank base 겹침 | 행렬 1을 행렬 0의 base에 LDW | `KCMP k=gemv_q mis>0` |
| (6) 세대가 바뀌었는데 WRGB 생략 | 첫 WRGB 뒤 모두 생략 | `KCMP k=gemv_* mis>0` |
| (7) barrier 위반 | 마지막 head를 미루고 ACTQ(att)를 묶음에 넣음 | token 불일치 |
| (8) RD_RESP | IP 모델의 50번째 op에 RD_RESP | `IPERR kind=err` |
| (9) IP가 끝나지 않음 | 50번째 op에서 busy 유지 | `IPERR kind=timeout`, 그 IP를 끄고 ARM으로 |
| (10) 보호 조건 우회 | vec N_MAX 32 + guard 무시 | `IPERR err=0x4`(BAD_DESC) |
| (추가) 레지스터 순서 | vec N을 CTRL 뒤에 씀 | FAIL(BAD_DESC 또는 결과 불일치) |

### RTL 시스템 TB (S5-3/S5-4)
같은 `sw/*.c`가 Questa에서 RTL(`sys_a_top`, `sys_p_top`)을 구동한다: `tb/sys_top/hal_dpi.c`(hal.h: AXI-Lite BFM task, 공유 DDR 이미지), `tb/sys_top/plat_dpi.c`(plat.h: 시간 = 시뮬레이션 cycle, 15M 이미지는 `+DDR_CK`/`+DDR_TK`), `tb/sys_top/sys_tb.c`(로그 판정). cache 모사는 `test/hal_cache.c`(호스트와 공유). 설정은 plusarg로 호스트 환경변수와 같은 이름(`+SX_LIST` 등). 실행: `export T=sys_smoke`(또는 `sys_fwd`)`; ./sim/run.sh`. 시나리오와 결과는 `docs/spec/system.md` 3.2절.
- 호스트 trace: `SX_CYCTRACE=<file>`이면 `hal_host.c`가 CYCLES 읽기마다 "slot ctrl cycles"를 쓴다. RTL TB의 `+CYCTRACE`와 같은 형식이고 `tb/sys_top/cyc_cmp.py`(환경변수 `CC_HOST`, `CC_RTL`, `CC_TAG`)가 op별로 비교한다. `SX_GA_P=2`는 빌드 A2의 CYCLES 추정용.
- 결함 주입 표의 (8), (9)에 더해 `f08b_rdresp_data`, `f09b_timeout_data`: 오류 뒤에도 token, hash, KCMP, COH가 0인지(S5-4에서 timeout 뒤 cache 재동기 누락을 찾은 뒤 추가). 호스트 테스트 항목 36개.
- 드라이버 수정(S5-4): timeout으로 IP를 끄면 `drv_go`가 `hal_flush_all()`을 부른다(그 IP의 소비 대상이던 데이터를 ARM이 cache의 옛 값으로 읽는 것을 막음, `docs/spec/system.md` 3.2).

## 3. UNVERIFIED (보드, ARM 컴파일러, Xilinx BSP 없이 준비한 것)
- `sw/hal_xil.c` 전부: `Xil_In32/Out32`로 0x43C0_0000 + slot 4 KiB 접근, `Xil_DCacheFlushRange`/`InvalidateRange`/`Xil_DCacheFlush`의 L1 + L2(PL310) 동작과 부분 line 처리, `dsb` inline assembly, arena = 물리 주소 = HP 주소. 호스트에서는 stub 헤더에 대한 `-fsyntax-only`만 했다.
- `fpga/sw/src/plat_xil.c`(baseline 그대로 재사용, baseline README의 UNVERIFIED 항목과 같음).
- 32비트 ARM에서의 컴파일과 실행(호스트 `-m32`로 32비트 포인터와 long만 확인), 컴파일러 경고, 스택과 정적 메모리 크기(`sx_t`는 static, 32비트 호스트 빌드에서 39,516 B: kcall 사본 72개, head별 q 사본 64개 포함).
- 보드의 polling 한도(10 ms 또는 예상 PL 시간 x 100)와 실제 PL 시간의 관계, IP 탐지 시 빈 slot이 0과 OKAY를 내는 것(`axil_xbar`, S5-2에서 RTL로 확인 예정).
- IP 모델 자체: RTL이 아니다. 통과는 SW의 흐름, 배치 변환, 일관성 규칙, 로그 형식이 spec 문서와 맞는다는 것만 보인다. RTL과의 대조는 S5-3/S5-4 시스템 TB.

## 4. 보드 실행 (S5-5, 사용자 실행용)

빌드 A(`rtl/l4/sys_a_top.sv`, 15M 주 대상 + 260K)와 빌드 P(`rtl/l4/sys_p_top.sv`, 260K)를 Zybo Z7-20 (XC7Z020-1CLG400C)에 올리고 이 디렉토리의 시스템 프로그램을 실행한다. 구성 원본은 `docs/spec/system.md` 1.2(빌드 표), 1.3(HP 배정), 1.4/1.7(주소, slot), 4.1(측정 mask).

이 절의 Tcl, XSCT 스크립트는 **준비 머신에서 Vivado, Vitis, XSCT로 실행하지 않았다(UNVERIFIED)**. 확인한 것은 RTL 시뮬레이션(`sys_a_top.cfg`, `sys_p_top.cfg`, `sys_smoke.cfg`, `sys_fwd.cfg`)과 4.8절의 검사뿐이다.

### 4.1 파일
| 경로 | 내용 |
|---|---|
| `create_project.tcl` | 프로젝트 + block design. `BUILD=A|P`(변형 `A2`, `PD`). PS7(GP0, 빌드가 쓰는 HP 포트 64비트, FCLK0, UART1), `proc_sys_reset`, interconnect(제어 1 + HP 포트마다 1), module reference `sys_0`, 주소(GP0 0x43C0_0000 64 KiB, HP DDR segment가 arena 0x1800_0000~0x3FF0_0000을 덮는지 검사), validate, `sys_build_config.txt` |
| `filelist.tcl` | 빌드별 RTL 목록: `sim/tests/sys_smoke.cfg`의 `RTL_FILES`(42개)에서 그 빌드가 쓰지 않는 모듈을 뺀 것(A 35개, P 38개) + shell |
| `build.tcl` | 합성, 구현, bitstream, XSA, 리포트(4.6절), `summary.txt` |
| `zybo_z7_20.xdc` | 제약(PS 핀만 쓰므로 비어 있음, 이유는 파일 주석) |
| `src/sys_a_bd.v`, `src/sys_p_bd.v` | module reference용 Verilog shell. L4 top의 parameter(이름, 기본값 동일)와 포트(169개)를 1:1로 연결. 인터페이스 이름 `s_axi`, `m00_axi`~`m03_axi`(번호 = HP 번호), `aclk`, `aresetn` |
| `sw/xsct_build.tcl` | Vitis classic platform + app 빌드, JTAG로 PL 프로그래밍, PS 초기화, ELF와 15M 이미지 다운로드, 실행 |
| `test/stub_check.tcl` | Vivado/XSCT 명령 stub으로 세 스크립트를 실행하는 검사(`make -C fpga/sys/test stub`) |

block design (빌드별 HP 포트, `system.md` 1.3):

| 빌드 | `sys_0` | HP0 | HP1 | HP2 | HP3 | 비고 |
|---|---|---|---|---|---|---|
| `A` | `sys_a_bd` | gemv_acc R/W | attn R/W | 꺼짐(`m02_axi` 미연결) | vec R/W | 기본 |
| `A2` | `sys_a_bd` (`GA_P` 2) | gemv_acc slice 0 R/W | attn R/W | gemv_acc slice 1 R | vec R/W | O12 조건 충족 시만 |
| `P` | `sys_p_bd` | pim R/W | attn engine 0 R/W | attn engine 1 R | vec R/W | 기본 |
| `PD` | `sys_p_bd` (`AT_KV_SRC` 1) | 같음 | 같음 | 같음 | 같음 | P의 BRAM이 넘칠 때(1.6절) |

module reference에 주는 parameter(나머지는 top 기본값):

| 빌드 | parameter |
|---|---|
| 공통 | `S_ADDR_W` 16, `XB_REG` 1, `IDW` 1, `MAX_BURST` 16, `OUTS` 4, `FCLK_MHZ` = round(요청 FCLK) |
| A | `GA_P` 1, `GA_NMAX` 1024, `GA_IDX_W` 16, `AT_H_PAR` 1, `AT_KV_SRC` 1, `AT_HS_MAX` 64, `AT_TMAX` 512, `VE_N_MAX` 1024, `VE_IDX_W` 16 |
| A2 | A에서 `GA_P` 2 |
| P | `PI_NB` 4, `PI_LB` 16, `PI_DEPTH` 4096, `AT_H_PAR` 2, `AT_KV_SRC` 0, `AT_HS_MAX` 8, `AT_TMAX` 512, `AT_NKV` 4, `AT_NL` 5, `AT_KW` 12, `AT_VW` 8, `VE_N_MAX` 1024, `VE_IDX_W` 16 |
| PD | P에서 `AT_KV_SRC` 1 |
| `VE_NMAX=256` 인자 | `VE_N_MAX` 256(O7의 첫 대안, BRAM 절약) |

### 4.2 준비물
- Vivado / Vitis 2019.2 이상(`write_hw_platform`). `sw/xsct_build.tcl`은 Vitis classic(2019.2 ~ 2023.2) 명령이다. 2024.1 이후는 4.7절의 수동 절차.
- Digilent board files 권장(`fpga/bw/README.md`와 같음). 없으면 PS7을 수동 설정하는데 DDR 보드 지연값이 없어 불안정할 수 있다.
- 데이터: `sh data/scripts/fetch.sh`(15M checkpoint, tokenizer), `make -C fpga/sw/test data`(260K 배열 `fpga/sw/gen/m1_data.c`). `fpga/README.md` 실행 순서 1과 같다.
- 보드: Zybo Z7-20, micro USB(PROG/UART), 부팅 모드 점퍼 JTAG. 터미널 115200 8N1. 출력 전체를 파일로 저장(예: `picocom -b 115200 --logfile uart.log /dev/ttyUSB1`).
- 권장 선행: `fpga/bw/`(HP 대역폭 빌드) 보드 결과. AXI4 -> AXI3 interconnect 경로가 같아서 실패 원인을 bw에서 먼저 가릴 수 있다(`system.md` 1.6).

### 4.3 실행 순서
`<repo>`는 프로젝트 최상위(`progress/llm-pim-soc`). 빌드 A와 P 각각 1~4단계를 한다.

**1. 프로젝트와 block design**
```
vivado -mode batch -source <repo>/fpga/sys/create_project.tcl -tclargs BUILD=A
vivado -mode batch -source <repo>/fpga/sys/create_project.tcl -tclargs BUILD=P
```
| 인자 | 값 | 기본 |
|---|---|---|
| `BUILD` | `A`, `P` (변형 `A2`, `PD`는 요청이 있을 때만) | 필수 |
| `VE_NMAX` | `1024`, `256` (256은 요청이 있을 때만) | `1024` |
| `FCLK_MHZ` | FCLK_CLK0 요청값. 실제 값은 끝에 출력되고 `sys_build_config.txt`의 `fclk_mhz_actual`에 남는다 | `100` |
| `BOARD` | `auto`, `yes`, `no` | `auto` |
| `INTC` | `smartconnect`, `axi_interconnect` | `smartconnect` |
| `NAME`, `DIR`, `PART` | | `sys_<a|p|a2|pd>[_ve256]_<fclk>m`, `fpga/sys/build/<NAME>`, `xc7z020clg400-1` |

끝에 `INFO: sys_0/m0k_axi (HPk) DDR segment ...`와 `FCLK_CLK0 requested 100 MHz, actual ... MHz`가 출력된다.

**2. 합성, 구현, bitstream, XSA**
```
vivado -mode batch -source <repo>/fpga/sys/build.tcl -tclargs PROJ=<repo>/fpga/sys/build/sys_a_100m/sys_a_100m.xpr
vivado -mode batch -source <repo>/fpga/sys/build.tcl -tclargs PROJ=<repo>/fpga/sys/build/sys_p_100m/sys_p_100m.xpr
```
- `JOBS=<n>`(기본 4)로 병렬 run 수와 스레드를 정한다. 사용자 머신이라 제한 없음(Vivado 자체 상한 8).
- `reports/summary.txt`를 먼저 본다: `timing_met yes`(WNS >= 0, WHS >= 0)여야 3단계로 간다. **`timing_met no`면 측정하지 말고 4.5절대로 리포트만 보낸다.**
- 빌드 P는 BRAM이 빡빡하다([계산] 128~129 / 140, `system.md` 1.5). 구현이 BRAM 부족으로 실패하면 `STEP=synth`로 다시 돌려 합성 리포트(`synth_util*.rpt`, `synth_ram_util.rpt`, `synth_ram_cells.txt`)를 보낸다. 대안 빌드(`VE_NMAX=256`, `BUILD=PD`)는 리포트를 본 뒤 요청한다.

**3. PS 프로그램 빌드**
```
xsct <repo>/fpga/sys/sw/xsct_build.tcl XSA=<reports>/sys_bd_wrapper.xsa FCLK_HZ=<실제 FCLK Hz> [인자]
```
| 인자 | 값 | 기본 |
|---|---|---|
| `XSA` | 2단계의 `reports/sys_bd_wrapper.xsa`(bitstream 포함) | 필수 |
| `FCLK_HZ` | 1단계의 실제 FCLK(Hz, 정수). C 심볼 `SYS_FCLK_HZ`: CYCLES를 시간으로 바꾸는 데 쓴다 | `100000000` |
| `RUNS` | run 종류 글자(E end-to-end, T 위치별 + hash, P 분해, K kernel 비교, W warm start) -> `SYS_RUN_MASK` | `ETPK` |
| `STEPS` | run마다 위치 수, 0 = 전부 -> `SYS_STEPS` | `0` |
| `MODELS` | `1`(260K), `2`(15M), `12` -> `SYS_RUN_M1/M2` | `12` |
| `LIST` | mask 목록 `mask[:opt],...`(hex, opt 생략 시 0d = DEFER_AT + WRGB_SKIP + FUSE_AM). 비우면 `sw/scfg.h`의 `SYS_MASK_LIST`(4.4절 표) | 비움 |
| `OPT`, `FPU` | 최적화 `O0..O3, Os`, `-mfpu` `neon`/`vfpv3` | `O2`, `neon` |
| `STACK`, `HEAP`, `DDRLEN` | 링커 스크립트 값(`fpga/sw/xsct_build.tcl`과 같음, 프로그램은 0x1000_0000 아래) | `0x10000`, `0x10000`, `0x0FF00000` |
| `WS`, `APP` | workspace, app 이름 | XSA 옆 `vitis_ws_sys/`, `lmsys` |
| `RUN` | 1이면 4단계까지 | `0` |
| `BIT` | RUN=1 때 프로그래밍할 bitstream | platform 안의 것 |
| `CK`, `TK` | 15M checkpoint, tokenizer(`MODELS`에 2가 있고 RUN=1일 때 DDR 0x1000_0000, 0x1400_0000에 적재) | `data/third_party/models/` |

컴파일 옵션은 baseline과 같다: Release, `-O2`, `-mfpu=neon -mfloat-abi=hard -ffp-contract=off`, `BUILD_OPT=2`, `-lm`. 소스: `fpga/sys/sw/*.c *.h`, `fpga/sw/src/`의 `out.c lmhash.c exp.c plat_xil.c prof.c`와 헤더 전부, `fpga/sw/expect/exp_m*.h`, `fpga/sw/gen/m1_data.c`, `model/src/*.c *.h`(호스트 테스트 `test/Makefile`과 같은 집합, 보드 파일로).

**4. 다운로드와 실행**: 같은 명령에 `RUN=1`. 터미널을 먼저 연다.
순서: `rst -system`, `fpga -file <bit>`(PL 프로그래밍 필수: IP가 PL에 있다), `loadhw`, `ps7_init`, `ps7_post_config`, ELF, (15M) `dow -data` 두 개, `con`. 로그는 `LMSYS END`로 끝난다. 리셋하면 15M 이미지를 다시 올린다.

### 4.4 측정 순서 (`system.md` 4.1)
ARM에서의 실행 시간은 아직 모른다(S3 baseline 보드 결과 전). 그래서 짧은 확인 -> 시간 파악 -> 본 측정 순서로 ELF를 다시 빌드해 실행한다. 각 실행의 UART 출력은 따로 저장한다.

| 순서 | 빌드 | 인자 (3, 4단계에 더함) | 목적 | 저장 이름 |
|---|---|---|---|---|
| 1 | A, P | `RUNS=K STEPS=4 LIST=0,ff` | 연결 확인: SYS 줄(slot, ID), 모든 IP 호출이 ARM 결과와 같은지(KCMP), token/hash | `uart_smoke.log` |
| 2 | A, P | `RUNS=E LIST=0` | mask 0 run E의 위치당 시간 파악(본 측정 길이 판단) | `uart_pilot.log` |
| 3 | A (`MODELS=12`), P (`MODELS=1`) | (기본) `RUNS=ETPK`, 기본 mask 목록 | 본 측정. 너무 길면 둘로 나눈다: `RUNS=E` 전 위치 + `RUNS=TPK STEPS=64` | `uart.log` (나누면 `uart_e.log`, `uart_tpk.log`) |

기본 mask 목록(`sw/scfg.h` `SYS_MASK_LIST`, opt 기본 0x0d):

| mask(hex) | 켜는 것 | opt |
|---|---|---|
| 00 | 없음(이 빌드의 ARM baseline) | 0d |
| 01, 02, 82, 03 | G, C, C+M, G+C | 0d |
| 04 | A(attention, P는 KVW 포함) | 0d |
| 08, 10, 20, 40, 80 | R, S, Qh, Qa, M 각각 | 0d |
| f8 | vec 전부 | 0d |
| 07 | G+C+A | 0d |
| ff | 전부 | 0d |
| df | 전부 - Qh | 0d |
| ff | 전부, DEFER_AT 끔 / PIM_BATCH 켬 / WRGB_SKIP 끔 | 0c / 0f / 09 |

- 15M은 빌드 A, 260K는 빌드 P와 A 둘 다(가속기형 대 PIM형 GEMV 비교는 두 빌드의 mask 03 또는 01). 빌드 P에서 15M은 G, C, A를 쓸 수 없어 그 조합이 `SKIP`이므로 P는 `MODELS=1`로 둔다.
- 위치 수: E는 전 위치(baseline과 같은 조건). P와 K가 길면 위 3의 분할처럼 줄이고 결과에 적힌 `steps`로 구분한다.

### 4.5 돌려받을 것
`fpga/results/<날짜>_sys_<빌드이름>/` 아래(빌드마다 하나, 예: `2026-12-01_sys_p_100m/`):
1. `uart_smoke.log`, `uart_pilot.log`, `uart.log`(또는 나눈 것): UART 출력 전체(가공하지 않은 원본).
2. `reports/`: `summary.txt`, `sys_build_config.txt`, `impl_util.rpt`, `impl_util_hier.rpt`, `impl_ram_util.rpt`(생겼으면), `impl_ram_cells.txt`, `impl_dsp_cells.txt`, `impl_timing_summary.rpt`, `impl_timing_paths.rpt`, `impl_drc.rpt`, `impl_methodology.rpt`, `synth_ram_cells.txt`.
3. `notes.txt`: Vivado/Vitis 버전, board files 사용 여부, 각 UART 로그를 만든 xsct 인자, 실행 중 경고나 이상, 걸린 시간(대략).

**timing 미달(`timing_met no`, WNS < 0) 또는 구현 실패일 때**: bitstream으로 측정하지 않는다. `reports/`(위 2, 특히 `summary.txt`, `impl_timing_summary.rpt`, `impl_timing_paths.rpt`, `impl_util_hier.rpt`)와 `notes.txt`만 보낸다. 대책은 리포트를 보고 정한다(`system.md` 1.6: IP의 PIPE parameter 추가가 먼저, RTL 수정과 재검증은 이쪽에서 한다). FCLK를 낮춘 빌드를 요청받으면:
```
vivado -mode batch -source <repo>/fpga/sys/create_project.tcl -tclargs BUILD=P FCLK_MHZ=75
vivado -mode batch -source <repo>/fpga/sys/build.tcl -tclargs PROJ=<repo>/fpga/sys/build/sys_p_75m/sys_p_75m.xpr
xsct <repo>/fpga/sys/sw/xsct_build.tcl XSA=<reports>/sys_bd_wrapper.xsa FCLK_HZ=<그 빌드의 실제 FCLK Hz> RUN=1
```
FCLK는 PS PLL이 가까운 값을 고르므로 `FCLK_HZ`에는 반드시 그 빌드의 `fclk_mhz_actual`을 Hz로 넣는다(IP CONFIG의 `FCLK_MHZ`는 요청값을 반올림한 표시용).

### 4.6 리포트로 확인할 것 (S5-6)
| 항목 | 어디서 | 기준 |
|---|---|---|
| timing | `summary.txt` `wns`, `whs`, `timing_met` | WNS >= 0, WHS >= 0 |
| BRAM | `bram_tile`, `ramb36`, `ramb18`, `bram36_calc` | <= 140. P [계산] 128~129, A 3~3.5 |
| parity 매핑 | `impl_ram_cells.txt`(`RAMB36E1 SDP 72 72 <cell>`), `ram_cells width72=`, `ram_cells_ip u_pi`, `u_at` | `pim_bank`(144비트)과 `kv_store`(210비트)가 512 x 72 SDP로 parity 비트까지 쓰면 pim 64, KV 60 근처 |
| DSP | `dsp`, `dsp_cells`, `dsp_calc`, `ip u_* dsp` | [계산] A 60, P 149(상한 쪽 가정, `system.md` 1.5) |
| IP별 | `ip u_ga|u_pi|u_at|u_ve lut reg dsp bram_tile`, `impl_util_hier.rpt` | arch.md 8절 범위와 비교 |

### 4.7 Vitis Unified (2024.1 이후, 확인하지 않음)
1. Platform component: XSA, standalone, ps7_cortexa9_0, BSP stdin/stdout ps7_uart_1.
2. Application component(빈 C), `src/`에 4.3절 3단계의 소스 목록.
3. 옵션: `-O2`, `-mfpu=neon -mfloat-abi=hard -ffp-contract=off`, 심볼 `BUILD_OPT=2`, `SYS_FCLK_HZ=<Hz>u`(필요하면 `SYS_RUN_MASK`, `SYS_STEPS`, `SYS_RUN_M1/M2`, `SYS_MASK_LIST`), 라이브러리 `m`. `lscript.ld`: `_STACK_SIZE` 0x10000, `_HEAP_SIZE` 0x10000, `ps7_ddr_0` LENGTH 0x0FF00000.
4. 실행: FPGA 프로그래밍과 ps7_init을 켠 하드웨어 실행 설정, 또는 XSDB 콘솔에서 4.3절 4단계 순서(`fpga/README.md`의 "수동으로 할 때"에 `fpga -file <bit>`를 `rst -system` 뒤에 더한 것).

### 4.8 기대 UART 출력 (형식, 값은 예시가 아님)
```
LMSYS BEGIN fmt=1
BUILD prog=sys plat=xil hal=xil opt=2 optimize=1 ptr_bits=32 run_mask=15 steps=0 fault_inj=0 cc=...
CLK tps=...
PLAT ...
SYS build=P hal=xil ga=0 pi=1 at=1 ve=1 id_ga=0x00000000 id_pi=0x50490001 id_at=0x41540001 id_ve=0x56450001 cfg_pi=0x04004464 ... fclk_mhz=100 fclk_hz=<FCLK_HZ> other_slots=...
MODEL m=260K ...            DATA m=260K src=embedded ... status=ok
ARENA ... / VAR ... wmis=0 / ROPE ...
INIT m=260K kind=rrec ...   INIT m=260K kind=ldw ... rc=0          (P만 ldw)
AVAIL m=260K v=K12V8 avail=0x000000ff build=P why=- ...
RUN m=260K v=K12V8 run=E mask=0x00000000 opt=0x0000000d steps=512 ticks=... ms_tok=... ip_ops=0
CHECK m=260K v=K12V8 run=E mask=0x00000000 opt=0x0000000d n=512 tok_mis=0 hash_mis=0 ... kmis=0 coh=0 fb=0 iperr=0 result=PASS
KERN ... / KSPLIT ... (run P)   KCMP ... mis=0 (run K)   SKIP ... (쓸 수 없는 mask)
MSUM m=260K v=K12V8 runs=... skipped=... mismatches=0 errors=0 result=PASS
(빌드 A: 15M 블록 m=15M ... src=ddr)
RESULT models_run=... models_skipped=0 mismatches=0 errors=0 result=PASS
LMSYS END
```
- `SYS`의 ID/CONFIG 기대값(`system.md` 1.7): A는 `id_ga=0x47410001 cfg_ga=0x04003164`, `cfg_at=0x02003964`, `cfg_ve=0x04001064`, pi 0. P는 위와 같이 `cfg_at=0x02003264 cfg2_at=0x00050408`, ga 0. 다르면 bitstream과 빌드가 맞지 않는 것이다.
- `CHECK ... result=FAIL`, `IPERR`, `RESULT ... FAIL`이 있으면 그대로 보낸다(원인 분석은 이쪽에서, 키 정의는 1절 표).

### 4.9 준비 머신에서 한 검사 (2026-11-23)
| 검사 | 명령(프로젝트 최상위 기준, 실제로는 작업 파일로 실행) | 결과 |
|---|---|---|
| Tcl/XSCT stub | `make -C fpga/sys/test stub`: 세 스크립트를 BUILD A/A2/P/PD, 인자 변형, 오류 인자로 실행(parameter가 system.md 1.2 값이고 기본 빌드는 RTL top 기본값과 같음, HP 포트와 배선, 주소, 생성 파일 목록, 리포트 파싱, XSCT 소스 목록/심볼/JTAG 순서) + 정적 대조 4개(GP0 base/arena = `ipregs.h`/`bcfg.h`, filelist = `sys_smoke.cfg`, shell parameter/포트 = top, HP 표) | STUBCHECK runs=43 fail=0 (시나리오 39 + 정적 대조 4) |
| stub 검사의 검출력 | create_project.tcl에 값 오류 4종(AT_HS_MAX, P의 HP 목록, GP0 base, arena 하한)을 하나씩 넣음 | 4/4 FAIL로 검출 |
| shell elaboration | Questa `vlog -lint=full`(빌드별 filelist의 RTL `-sv`, shell은 Verilog) + `vopt -lint=full`: `sys_a_bd` 기본/`GA_P=2`/`AT_H_PAR=2`/`VE_N_MAX=256`/`XB_REG=0`+`FCLK_MHZ=125`, `sys_p_bd` 기본/`AT_KV_SRC=1`/`VE_N_MAX=256`/`AT_H_PAR=1` (`sim/.lint9`) | vlog 4회, vopt 9구성 경고 0, 오류 0 |
| lint의 검출력 | shell에서 포트 연결 하나를 지운 사본 | `vopt-2685`/`vopt-2718` 경고 2개로 검출 |
| 호스트 테스트 | `make -C fpga/sys/test test`(1~3절, 바뀐 것 없음) | SYSHOST items=36 fail=0 (S5-5 전과 같음) |

### 4.10 미검증 사항 (UNVERIFIED)
- Vivado: `processing_system7` 속성 이름(`PCW_USE_S_AXI_HPn`, `PCW_S_AXI_HPn_DATA_WIDTH`, `PCW_ACT_FPGA0_PERIPHERAL_FREQMHZ`), PS7 automation 규칙, SystemVerilog 하위 모듈을 가진 Verilog shell의 module reference와 `CONFIG.<parameter>` 설정, 포트 이름으로 `m00_axi`~`m03_axi`, `s_axi`(주소 16비트)가 추론되는지, 빌드 A에서 `m02_axi`를 연결하지 않은 채의 validate(입력은 0으로 묶일 것으로 봄), 주소 segment 이름(`*sys_0*`, `*DDR*`)과 HP DDR 범위, interconnect의 AXI4(ID 1비트) -> AXI3(ID 6비트) 변환과 burst, 계층 셀 이름(`*/u_top/u_pi` 등)과 RAM 셀 속성(`RAM_MODE`, `READ_WIDTH_A`, `WRITE_WIDTH_B`), `report_ram_utilization`의 존재와 옵션, `report_utilization` 표의 행 이름(`RAMB36/FIFO*`, `RAMB18`).
- 합성 결과 전부: 100 MHz timing(`system.md` 1.6의 경로들, IP 4개가 한 FPGA에서 배치를 다툼), BRAM parity 매핑(빌드 P 성립 조건, 안 되면 [계산] 180/140), DSP와 LUT 수, interconnect가 쓰는 BRAM.
- XSCT/Vitis: platform/app 명령, `define-compiler-symbols`/`compiler-misc`(쉼표가 든 `-DSYS_MASK_LIST=...` 값이 gcc에 인자 하나로 가는지), `lscript.ld` 패턴, JTAG target 필터, `ps7_init.tcl` 위치, `dow -data` 속도.
- 보드: 1~3절 UNVERIFIED 항목(`hal_xil.c`, cache 유지 함수, ARM 컴파일), 실행 시간, 스택 64 KB의 충분성(`sx_t`는 static), 빈 slot 읽기 0/OKAY가 실제 GP0 경로에서도 data abort 없이 되는지(RTL 시뮬레이션에서는 확인).
