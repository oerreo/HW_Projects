# fpga/sys: 시스템 프로그램과 호스트 검증 (S5-1)

ARM에서 도는 H판(K12V8) forward의 kernel 호출을 런타임 오프로드 mask에 따라 PL IP 4개(`gemv_acc_top`, `pim_top`, `attn_top`, `vec_top`)로 보내는 bare-metal 프로그램과, 보드 없이 이 서버에서 그 흐름을 검사하는 호스트 테스트다. 설계 원본은 `docs/spec/system.md` 2절(SW 구조), 3.1절(호스트 검증), 2.6절(측정과 로그). 보드 실행 절차(Vivado BD, XSCT 빌드, 돌려받을 것)는 **S5-5에서 채운다**(아직 없음).

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
test/ hal_host.c  호스트용 hal: slot 16개에 IP 모델, cache 모사, 결함 주입(IP 쪽)
      ipm.h ipm_ga.c ipm_pi.c ipm_at.c ipm_ve.c   IP C 레지스터 모델 (spec 문서로 작성)
      Makefile run.sh xilstub/
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
- **cache 모사**(`test/hal_host.c`): CPU 메모리(arena 자체), DDR 이미지, 마지막 동기 값(syn), ARM 쓰기 표시의 네 배열. flush는 32 B line 단위로 ARM이 쓴 line을 통째로 DDR로 쓰고(IP가 쓴 byte를 덮으면 `flush_clobber`), invalidate는 범위 안의 line을 DDR에서 다시 읽는다(ARM이 쓰고 flush하지 않은 byte가 있으면 `inval_discard`, 범위 끝의 부분 line은 flush로 처리). 검사: ARM이 IP가 쓰고 invalidate하지 않은 byte를 읽음(`arm_rd_stale`), IP가 ARM이 쓰고 flush하지 않은 byte를 읽음(`ip_rd_dirty`) 또는 그런 line에 씀(`ip_wr_dirty`). 모든 line이 늘 cache에 있다고 보는 보수적 모델이다. 전체 flush에서 이전 run의 IP 데이터를 덮는 것은 오류가 아니라 `old`로 센다.
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

## 3. UNVERIFIED (보드, ARM 컴파일러, Xilinx BSP 없이 준비한 것)
- `sw/hal_xil.c` 전부: `Xil_In32/Out32`로 0x43C0_0000 + slot 4 KiB 접근, `Xil_DCacheFlushRange`/`InvalidateRange`/`Xil_DCacheFlush`의 L1 + L2(PL310) 동작과 부분 line 처리, `dsb` inline assembly, arena = 물리 주소 = HP 주소. 호스트에서는 stub 헤더에 대한 `-fsyntax-only`만 했다.
- `fpga/sw/src/plat_xil.c`(baseline 그대로 재사용, baseline README의 UNVERIFIED 항목과 같음).
- 32비트 ARM에서의 컴파일과 실행(호스트 `-m32`로 32비트 포인터와 long만 확인), 컴파일러 경고, 스택과 정적 메모리 크기(`sx_t`는 static, 32비트 호스트 빌드에서 39,516 B: kcall 사본 72개, head별 q 사본 64개 포함).
- 보드의 polling 한도(10 ms 또는 예상 PL 시간 x 100)와 실제 PL 시간의 관계, IP 탐지 시 빈 slot이 0과 OKAY를 내는 것(`axil_xbar`, S5-2에서 RTL로 확인 예정).
- IP 모델 자체: RTL이 아니다. 통과는 SW의 흐름, 배치 변환, 일관성 규칙, 로그 형식이 spec 문서와 맞는다는 것만 보인다. RTL과의 대조는 S5-3/S5-4 시스템 TB.

## 4. 보드 실행 (S5-5에서 채움)
Vivado BD Tcl(`BUILD=A|P`), XSCT 빌드 스크립트, 실행 순서, 돌려받을 것(UART 로그, utilization/timing 리포트)은 S5-5에서 이 절에 적는다. 보드 ELF는 `SYS_MASK_LIST`, `SYS_RUN_MASK`, `SYS_STEPS`, `SYS_FCLK_HZ`(Vivado가 보고한 실제 FCLK)를 컴파일 시점에 정한다(`sw/scfg.h`).
