# 계층 구조: llm-pim-soc (S4)

상태: **초안** (2026-11-19, S4-0). attention 부분(1절 트리, 2절 S4-6 행, 3.2~3.4 표의 attention 모듈, 3.9절, 4절 A3)은 S4-6 구현에 맞춰 갱신했다(2026-11-19). S4-7(2026-11-20)에서 vec 부분(1절 트리, 2절 S4-7 행, 3.2~3.4 표의 vec 모듈, 3.11절, 4절 A4, A5, A7)을 구현에 맞춰 갱신했다. 오케스트레이터 검토 전이며, `arch.md` 끝의 "열린 결정"이 확정되면 해당 부분을 고친다. 이 문서의 구성과 포트는 열린 결정의 **권고안**을 기준으로 적었다. 구조 결정과 수치 근거는 `arch.md`가 원본이다.

- golden: `model/src/kern.c`(kernel 함수), `model/src/bank.c`(PIM bank 분할 GEMV), `model/src/fwd_h.c`(호출 순서와 KV cache 배치). RTL은 kernel 경계에서 bit-exact여야 한다.
- 형식: K12V8(`spec/numeric.md` 4절). 행 단위 가중치 scale(gs = n), MANT 활성 scale, q/K 12비트(int16 container), V 8비트, LUT 8비트(257항목).
- 표기: [계산] = 구성에서 식으로 구한 값, [추정] = 가정이 들어간 값. 이 문서의 어떤 수치도 합성이나 시뮬레이션으로 잰 것이 아니다.

## 1. 트리

L0 = 하위 모듈이 없는 leaf, L1 = L0 조합, L2 = kernel core(로컬 인터페이스, AXI 없음), L3 = AXI가 붙은 IP top, L4 = 시스템(S5).

```
L4  sys_a_top        (S5-2) 빌드 A: axil_xbar + gemv_acc_top(slot 0) + attn_top KV DDR(slot 2) + vec_top(slot 3). 인스턴스와 배선만   RTL
      L4  axil_xbar        AXI4-Lite 1 -> N(4 KiB slot, addr[15:12]), 없는 slot은 읽기 0/OKAY, 경로마다 1 outstanding, REG 0/1   RTL
      L3  gemv_acc_top, attn_top, vec_top (아래와 같은 모듈, 수정 없음)
L4  sys_p_top        (S5-2) 빌드 P: axil_xbar + pim_top(slot 1) + attn_top KV BRAM H_PAR 2(slot 2) + vec_top(slot 3). 인스턴스와 배선만   RTL
      L4  axil_xbar
      L3  pim_top, attn_top, vec_top (아래와 같은 모듈, 수정 없음)

L3  bw_top           HP 대역폭 측정 top (S4-3, 측정 도구). axil_slave + CSR + axi_rd_eng/axi_wr_eng x P   RTL
      L1  axil_slave, axi_rd_eng, axi_wr_eng, L0 sync_fifo (아래와 같은 모듈)

L3  gemv_acc_top     GEMV 가속기형 IP. AXI-Lite CSR + HP read/write master + gemv_core x P       RTL
      L1  axil_slave       AXI4-Lite 5채널 -> 레지스터 strobe (pqc-ntt-ip에서 복사)                RTL
      L3  gemv_acc_csr     레지스터 맵, done_sticky, ERR, CYCLES/STALL 카운터                       RTL
            L0  umul_seq   descriptor 검사의 W 범위 곱 ROWS x (1 + ceil(N/8)) (S4-6b)             RTL
      L1  axi_rd_eng       AXI4 read master: (addr, bytes) 명령 -> 64b beat 스트림, 4 KiB 분할      RTL
      L1  axi_wr_eng       AXI4 write master: (addr, bytes) 명령 + 스트림 -> burst 쓰기             RTL
      L2  gemv_core        행 레코드 스트림 x 활성 벡터 -> y 스트림 (lane 8)                          RTL
            L1  mac_row          lane 내적 + 행 누산                                                RTL
                  L0  dotp       LANES개 곱 + adder tree                                           RTL
            L1  gemv_scale       y = sat32(rshr(acc * m * xm, sh))                                  RTL
                  L0  rshr_sat   round-half-up 산술 shift(음수면 포화 좌shift) + 포화               RTL
            L0  ram_sdp          x buffer (추론형 RAM wrapper)                                      RTL
      L0  argmax_red       y 스트림의 argmax (분류기에서 선택적으로 융합)                           RTL
      L0  sync_fifo        valid/ready FIFO                                                         RTL

L3  pim_top          GEMV PIM형 IP. CSR + 명령 FIFO + HP master + pim_core                           RTL
      L1  axil_slave, axi_rd_eng, axi_wr_eng, sync_fifo (위와 같은 모듈)
      L3  pim_csr          레지스터 맵, 명령 FIFO 입구                                              RTL
            L0  umul_seq x 2   push 검사의 bank 범위 곱, LDW 길이 곱 (S4-6b)                       RTL
      L2  pim_core         NB개 bank + global buffer + 명령 컨트롤러 + 결과 gather                    RTL
            L1  pim_ctrl         명령 FSM: LDW, WRGB, MACAB(RDROW 미구현). bank 주소, lock-step 스케줄, gather 순서  RTL
                  L0  umul_seq   LDW 읽기 길이 rows x 8 (1 + ceil(n/8)) (S4-6b)                     RTL
            L1  pim_gb           global buffer(활성 벡터 1개), 방송 read                           RTL
            L1  pim_bank         bank 하나: 가중치 RAM + mac_row + mantissa 추출 + MAC_REG           RTL
                  L0  ram_sdp    가중치 image (2 x BRAM36 폭, 8 깊이)                               RTL
                  L1  mac_row    (위와 같은 모듈, LANES = 16)
            L1  gemv_scale       (위와 같은 모듈) bank 결과를 순서대로 1개/cycle 처리                 RTL
            L0  sync_fifo        y FIFO (S4-5: ram_sdp y buffer 대신, 32 x 33)                       RTL

L3  attn_top         attention IP. CSR + read port per engine + attn_core x H_PAR + KV source + write arbiter  RTL
      L1  axil_slave, axi_rd_eng (x H_PAR), axi_wr_eng (위와 같은 모듈)
      L3  attn_csr         레지스터 맵, descriptor 검사, start/done, descriptor latch (S4-6)          RTL
            L0  umul_seq, udiv_seq   순차 descriptor 검사와 top용 곱(SEQ hs, T hs, KVH0 SEQ + POS) (S4-6b)  RTL
      L2  attn_core        head 하나의 score, softmax, V 가중합 (q/K/V 폭 8/12/16, 16b container). pass FSM(Q, P1, P2, DIV, P3, O)은 attn_core 자신의 control (S4-6에서 attn_ctrl을 따로 두지 않음)  RTL
            L1  attn_score       dotp(16x16, KL lane) + c = qm*km + 곱 + rshr_sat, running max, emin/mmax/have  RTL
                  L0  dotp, rshr_sat
            L1  exp_unit         d = s - max (clamp), w = rshr(d*log2e, 15), lut_lerp(EXP2N)          RTL (HLS 비교 후보)
                  L0  lut_lerp   257항목 표 + 선형 보간 (FUNC EXP2N; SIGM은 S4-7에서 추가)            RTL
                  L0  rshr_sat
            L0  udiv_seq         순차 나눗셈 (R = 2^48 / sum, Q_W 33)                               RTL
            L1  attn_vacc        p = e*R 정규화, w = rshr(p*vm, ...), V MAC(VL lane), o 출력 shift     RTL
                  L0  rshr_sat
            L0  ram_sdp          p buffer (T_MAX x 32), vs buffer (T_MAX x 25)                       RTL
            L0  sync_fifo        출력 FIFO (p, o)                                                   RTL
      L2  kv_store         (KV_SRC 0, sys_p) 260K KV cache: kv head마다 210b x 2560 ram_sdp, 쓰기 + 포트별 pass read  RTL
            L0  ram_sdp, sync_fifo
      L2  kv_rd            (KV_SRC 1, sys_a) DDR KV reader: axi_rd_eng 명령/데이터 -> pass 스트림 (engine마다)  RTL

L3  vec_top          벡터 IP (S4-7). axil_slave + vec_csr + axi_rd_eng + axi_wr_eng + vec_core + 명령 순서기 + packer   RTL
      L1  axil_slave, axi_rd_eng, axi_wr_eng (위와 같은 모듈)
      L3  vec_csr          레지스터 맵, 1 cycle descriptor 검사(shift와 덧셈만), start/done, latch    RTL
      L2  vec_core         op 선택(RMSNORM, SWIGLU, ACTQ, ARGMAX), unpacker, 공유 front buffer, actq_core 하나 공유   RTL
            L1  rms_front        amax, k, sum(xs^2), rsqrt_nr, y = sat32(rshr(xs*g*rm, sh))          RTL
                  L0  rsqrt_nr   48항목 seed + Newton 2회 (17x35 곱셈기 1개 순차, CYCLES 15)        RTL
                  L0  rshr_sat
            L1  swi_front        sigmoid(lut_lerp SIGM), silu -> buffer, g = sat32(rshr(silu*h3, 16))   RTL
                  L0  lut_lerp (FUNC SIGM), rshr_sat
            L1  actq_core        int32 buffer + amax + (M, R)(udiv_seq 하나 두 번) + 양자화 + q FIFO   RTL
                  L0  udiv_seq, rshr_sat, ram_sdp, sync_fifo
            L0  ram_sdp          공유 front buffer (rms_front: x, swi_front: silu)
            L0  argmax_red
```

- HLS(Catapult) 병행은 선택 사항이다. 후보는 `exp_unit`과 `gemv_core`의 데이터패스(같은 포트, 같은 벡터). v1에서는 하지 않는 것을 권고한다(`arch.md` 열린 결정 D13).
- `embed`, `rope`, `add`는 v1에서 ARM에 남긴다(`spec/measure.md` 7절). PIM형에서 embedding 행 읽기(`RDROW`)는 S4-5에서 구현하지 않았다(op 4는 BAD_CMD, `spec/pim.md`).
- 디렉토리: `rtl/l0/`, `rtl/l1/`, `rtl/l2/`, `rtl/l3/`, `rtl/l4/`, `rtl/pkg/llm_pkg.sv`. `tb/<module>/`, `sim/<module>/`. 회귀 스크립트는 pqc-ntt-ip의 `sim/run.sh`를 복사해 이 프로젝트 것으로 둔다.

## 2. 진행 순서 (bottom-up)

leaf는 처음 쓰이는 단계에서 만든다(`arch.md` 9절). "S4 단계"는 `docs/plan.md`의 하위 단계 표와 같다.

| S4 단계 | 모듈 | 계층 | 구현 | 검증 방식과 벡터 출처 | 통과 기준 |
|---|---|---|---|---|---|
| S4-1 | 검증 기반: model 보강(4절 A1~A11), 덤프 변환, DPI-C golden, `sim/run.sh`, AXI slave memory model(TB) | - | C, SV | `make test` 재실행과 기존 덤프 `cmp` 동일, AXI memory model self-test | `make test` PASS, 기존 덤프 불변, 지수와 shift 범위 집계 보고 |
| S4-2 | `rshr_sat`, `dotp`, `sync_fifo`, `ram_sdp` | L0 | RTL | `rshr_sat`: random 10^6 + 경계(shift -64..70, 최대/최소 입력), golden `k_rshr`(+ `sat32`) DPI. `dotp`: random + 전부 +-127, -128 | mismatch 0 |
| S4-2 | `mac_row`, `gemv_scale` | L1 | RTL | 행 단위 stage 덤프(A1, A2) + DPI random(n = 8..1024, 전부 127 포함) | mismatch 0 |
| S4-2 | `gemv_core` | L2 | RTL | K_GEMV 레코드 전부(260K, 15M, K12V8 덤프), stream valid/ready random stall | mismatch 0, cycle 수가 `arch.md` 2.4 식과 일치 |
| S4-3 | `axi_rd_eng`, `axi_wr_eng` | L1 | RTL | AXI slave memory model(random latency, RVALID/WREADY/BVALID 지연 random), 4 KiB 경계, 길이 1..N | 데이터 mismatch 0, 프로토콜 assertion 0 |
| S4-3 | HP 대역폭 측정 top(측정 도구, 선택) | L3 | RTL + Tcl | AXI BFM | 시뮬레이션 PASS 후 사용자 보드 실행 요청 |
| S4-4 | `argmax_red`, `gemv_acc_csr`, `gemv_acc_top` | L0, L3 | RTL | `argmax_red`: random + 동일값 경계, golden `k_argmax`. top: AXI-Lite BFM + memory model, PS 프로그램과 같은 순서. K_GEMV 레코드(분류기 포함) + 이어지는 K_ARGMAX | mismatch 0, CSR 참조 모델 대조, ERR 비트별 run |
| S4-5 | `pim_bank`, `pim_gb`, `pim_ctrl`, `pim_core`, `pim_csr`, `pim_top` | L1~L3 | RTL | 260K 모든 행렬의 K_GEMV 레코드 + `bank.c` BANK_ROW(nbank = 4) 결과와 명령 수(`bank_stat_t`). bank image는 A6 생성기. top은 LDW로 전 가중치 적재 후 한 위치의 GEMV 36회 | mismatch 0, 명령 수 일치 |
| S4-6 | `udiv_seq`, `lut_lerp`(EXP2N) | L0 | RTL | `udiv_seq`: random + 몫 경계, golden C `/`. EXP2N: u 전수 [0, 2^21) + I >= 32 random, golden `k_exp2neg` | mismatch 0 |
| S4-6 | `exp_unit`, `attn_score`, `attn_vacc`, `attn_core` (pass FSM은 `attn_core` 안) | L1, L2 | RTL | stage trace(A3) + K_ATTN2 레코드(T = 1..512, K12V8) + K_ATTN 레코드(HB = K8V8, HD = K16V16 덤프), KV stream random stall | p와 o 모두 mismatch 0 (완료 2026-11-19, `spec/attn.md`) |
| S4-6 | `kv_store`, `kv_rd`, `attn_csr`, `attn_top` | L2, L3 | RTL | KVW(golden 배치의 K/V 버퍼)로 쓰기, K_ATTN2 레코드로 읽기. AXI BFM | mismatch 0 (완료 2026-11-19) |
| S4-7 | `rsqrt_nr`, `lut_lerp`(SIGM) | L0 | RTL | rsqrt: 비트 길이마다 4,000(make test 방식) + seed 경계 + random 10^6, golden `k_rsqrt`(rm 범위는 C 전수). SIGM: a 전수 [-2^20, 2^20] + 포화 구간 random, golden `k_sigmoid` | mismatch 0 (완료 2026-11-20, `spec/vec.md`) |
| S4-7 | `actq_core` | L1 | RTL | K_ACTQ 레코드 전부(qmax 127, 2047) + DPI random(amax 0, 1, 2^31-1 포함, qmax 32767) + stage(amax, L, e, num, M, R) | mismatch 0 (완료 2026-11-20) |
| S4-7 | `rms_front`, `swi_front`, `vec_core`, `vec_csr`, `vec_top` | L1~L3 | RTL | K_RMSNORM, K_SWIGLU, K_ACTQ, K_ARGMAX 레코드 전부(두 모델) + stage(A4, A5), `vec_csr` 단독 TB, AXI BFM | mismatch 0 (완료 2026-11-20) |
| S4-8 | 전체 회귀, irun 교차, 다이어그램, viewer 확장 | - | - | `sim/run.sh all` | 전 run PASS, 로그 보관 |

- S4-2~S4-4가 GEMV 가속기형, S4-5가 PIM형, S4-6이 attention, S4-7이 나머지다. 오케스트레이터 순서와 다른 점과 근거는 `arch.md` 9절.
- 모든 TB는 posedge에서 non-blocking으로 입력을 넣고 negedge에서 검사한다(`design-methodology.md`). 끝에 mismatch 수와 `TB_RESULT: PASS/FAIL`.
- 상위 검증에서 하위를 고치면 하위 TB를 다시 돌린다.

## 3. 모듈 경계 인터페이스

### 3.1 공통 (`rtl/pkg/llm_pkg.sv`)
| 이름 | 값 | 의미 |
|---|---|---|
| `E_W` | 8 (signed) | 지수(`we`, 활성 `e`, `fo`, `qe`, `ke`, `ve`). S4-1 집계(K12V8 두 모델 덤프, `model/results/range_k12v8.txt`): 0..33 [측정, PC], signed 7비트면 충분. 8은 1비트 여유 (확정 2026-11-19, `rtl/pkg/llm_pkg.sv`) |
| `SH_W` | 10 (signed) | 지수 합으로 만든 shift(`sh = we + xe - fo` 등). S4-1 집계: -1..40 [측정, PC] (음수는 attention V 정렬 `ve - emin - G`만), signed 7비트. 10은 E_W 8비트 값 세 개의 합/차가 넘치지 않는 폭 (확정 2026-11-19, `rtl/pkg/llm_pkg.sv`) |
| `AM_W` | 17 | 활성 scale 가수 `m` (`m < 2^17`) |
| `WM_W` | 16 | 가중치 행 가수 `wm` |
| `N_MAX` | 1024 | gemv 행 길이, 벡터 길이 상한(두 모델 최대 768). golden `K_NMAX`(16384)보다 작다. 넘는 descriptor는 ERR |
| `T_MAX` | 512 | attention 길이 상한 |
| `HS_MAX` | 64 | head size 상한(260K 8, 15M 48) |
| `IDX_W` | 16 | argmax index (vocab 32000) |

- 모든 모듈: `clk`, `rst_n`(active-low, 비동기 assert, 동기 deassert). control 레지스터만 reset, datapath는 enable로 받는다.
- L0 산술 leaf는 `valid_i`/`valid_o`와 고정 `LATENCY`(`localparam`, `PIPE` parameter로 결정)만 갖고 backpressure가 없다. 순차 leaf(`udiv_seq`, `rsqrt_nr`)는 `start_i`/`done_o`와 고정 cycle 수(`localparam CYCLES`)를 갖는다.
- L2 core의 데이터 포트는 valid/ready 스트림. L2 이하에는 AXI가 없다.
- 잘못된 parameter(예: `LANES`가 2의 거듭제곱이 아님, `N_MAX`가 `ACC_W`를 넘는 누산을 허용)는 elaboration에서 실패시킨다.

### 3.2 L0

| 모듈 | parameter | 입력 | 출력 | latency | golden |
|---|---|---|---|---|---|
| `rshr_sat` | `IN_W`, `OUT_W`, `SAT_MODE`(0: OUT_W 포화, 1: 64비트 `I64MAX` 규칙), `PIPE` | `x_i[IN_W]` signed, `sh_i[SH_W]` signed, `valid_i` | `y_o[OUT_W]` signed, `valid_o` | `PIPE` (0..2) | `sat32(k_rshr(x, s))` 또는 `k_rshr` 단독. sh >= IN_W이면 0(golden의 s >= 62 규칙과 같음), sh < 0이면 포화 좌shift(음수 쪽 포화값은 golden이 `-I64MAX`, sat32는 `I32MIN`으로 서로 다르다. `SAT_MODE`로 구분) |
| `dotp` | `LANES`, `AW`, `BW`, `PIPE` | `a_i[LANES*AW]`, `b_i[LANES*BW]` signed, `valid_i` | `sum_o[AW+BW+clog2(LANES)]` signed, `valid_o` | `PIPE` (0..clog2(LANES)+1) | `k_gemv` 내부 곱합, `attn_core`의 dot (stage 덤프 A1, A3) |
| `udiv_seq` | `NUM_W`, `DEN_W`, `Q_W` | `start_i`, `num_i[NUM_W]`, `den_i[DEN_W]` (den > 0, 몫 < 2^Q_W 전제) | `q_o[Q_W]`, `done_o`(1 cycle pulse), `busy_o` | `CYCLES = Q_W + 1` (S4-6 확정: start cycle c, done c + Q_W + 1) | C `/` (`aq_setup`의 M, R; attention의 `2^48 / sum`) |
| `umul_seq` | `A_W`, `B_W` (각 1..64) | `start_i`, `a_i[A_W]`, `b_i[B_W]` | `p_o[A_W+B_W]`(정확한 곱), `done_o`(1 cycle pulse), `busy_o` | `CYCLES = B_W + 1` (start cycle c, busy c+1 .. c+B_W, done c + B_W + 1, `udiv_seq`와 같은 handshake. S4-6b) | 정수 곱 (TB의 128비트 곱) |
| `lut_lerp` | `FUNC`(0 = EXP2N, 1 = SIGM; 다른 값은 elaboration 실패), `PIPE` | EXP2N: `u_i[32]`(Q16 지수, >= 0). SIGM: 같은 `u_i[32]` 포트를 signed Q16 a로 읽는다(S4-7). `valid_i` | `y_o[17]` Q16 unsigned, `valid_o` | `PIPE` (1..3, 표 read가 동기라 1 이상) | `k_exp2neg(u, 8, lut)`, `k_sigmoid(a, 8, lut)`. 표는 `tabs.c`에서 생성한 SV package(`rtl/pkg/lut_pkg.sv`의 EXP2N_TAB, SIGM_TAB, `model/tools/lutsv.py`) |
| `rsqrt_nr` | `U_W`(1..62, 기본 42) | `start_i`, `u_i[U_W]` | `rm_o[17]`(전수 확인: rm <= 65535), `re_o[E_W]` signed, `done_o`, `busy_o` | `CYCLES = 15`(start c, done c + 15, udiv_seq와 같은 handshake; 17x35 곱셈기 1개를 cycle마다 한 번) | `k_rsqrt` (seed 표 `lut_pkg::RSQ_TAB`) |
| `argmax_red` | `IDX_W` | `v_i[32]` signed, `valid_i`, `first_i`, `last_i` | `idx_o[IDX_W]`, `max_o[32]` signed, `done_o` | 1 (`done_o` 1 cycle pulse, `idx_o`/`max_o`는 done cycle부터 다음 valid_i까지 유지) | `k_argmax` (같은 값이면 앞 index: 엄격한 `>`만 갱신) |
| `sync_fifo` | `W`, `DEPTH` | `in_valid_i`, `in_data_i`, `out_ready_i` | `in_ready_o`, `out_valid_o`, `out_data_o`, `level_o` | - | (control) |
| `ram_sdp` | `W`, `DEPTH`, `RD_LAT`(1) | `we_i`, `waddr_i`, `wdata_i`, `re_i`, `raddr_i` | `rdata_o` (re일 때만 갱신) | `RD_LAT` | (memory) 추론형, FPGA/ASIC 교체 지점. 72비트 폭은 parity bit까지 데이터로 쓴다 |

### 3.3 L1

| 모듈 | parameter | 포트 요약 | latency | golden |
|---|---|---|---|---|
| `mac_row` | `LANES`, `AW`, `BW`, `ACC_W` | in: `valid_i`, `first_i`, `last_i`(행 첫/끝 beat), `a_i`, `b_i`. out: `acc_o[ACC_W]` signed, `acc_valid_o`(행 끝에서 1 cycle) | `LATENCY = dotp.LATENCY + 1` | 행의 int32 `acc` (A1). gemv: `ACC_W = 15 + clog2(N_MAX) = 25` [계산: 1024 x 127^2 < 2^24] |
| `gemv_scale` | `ACC_W`, `PIPE` | in: `acc_i[ACC_W]`, `wm_i[16]`, `xm_i[17]`, `sh_i[SH_W]`, `valid_i`. out: `y_o[32]`, `valid_o` | 고정 `LATENCY` (곱 2단 + shift) | `k_gemv`의 `y = sat32(rshr(acc*m*xm, sh))` (A2). `S = acc*m`은 41비트, `S*xm`은 58비트 [계산] |
| `actq_core` | `N_MAX`, `Q_DEPTH`(>= 5) | cfg: `n_i`, `f_i[E_W]`, `qmax_i[16]`(127, 2047, 32767), `start_i`. in: `v_valid_i/v_ready_o`(LOAD 동안 항상 1), `v_i[32]`. out: `q_valid_o/q_ready_i`, `q_o[16]`(int8은 sign-extend). scale: `m_o[17]`, `e_o[SH_W]`(e + f, amax 0이면 0), `scl_valid_o`, `busy_o`, `done_o` | 마지막 입력 원소 cycle t에서 done = t + n + 59(amax 0이면 t + n + 6) | K_ACTQ 레코드. MANT만 |
| `exp_unit` | `RS_PIPE`, `LUT_PIPE` | in: `s_i[32]`, `mx_i[32]`, `valid_i`. out: `e_o[17]`, `valid_o` | `1 + RS_PIPE + LUT_PIPE` | `k_attn_exp` (S4-6 export) |
| `attn_score` | `KL`, `HS_MAX`, `DOT_PIPE`, `SH_PIPE` | cfg `hs`, `d0`, `qm`, `qe`, `clr_i`; q 적재(`q_we_i`, group, `KL x 16b`); K beat(`k_valid_i`, `KL x 16b`, 위치의 마지막 beat에서 `km`, `ke`, `vm`, `ve`). out: `s_valid_o`, `s_o[32]`, `s_vm_o`, `s_ve_o`, `mx_o`, `emin_o`, `mmax_o`, `have_o` | `DOT_PIPE + 3 + SH_PIPE` (마지막 beat -> s) | `k_attn_score` + P1 trace |
| `attn_vacc` | `VL`, `HS_MAX`, `T_MAX`, `ACC_W` | cfg `R`, `emin`, `G`, `clr_i`; V beat(`b_valid_i`, `b_first_i`, group, `VL x 16b`, 첫 beat에 `e`, `vm`, `ve`). out: `p_valid_o`/`p_o`(첫 beat + 2), o 읽기(`o_rd_i`, `o_idx_i` -> `o_valid_o`, `o_o`, + 2) | p 2, 누산 6, o 2 | `k_attn_pn`, `k_attn_w`, `k_attn_out`. `ACC_W` 60 (>= 50 + log2 T_MAX) |
| `axi_rd_eng` | `DW` = 64, `AW` = 32, `MAX_BURST` = 16, `OUTS` = 4 | cmd: `cmd_valid_i/ready_o`, `addr_i`, `bytes_i`. data: `d_valid_o/ready_i`, `d_o[64]`, `d_last_o`. AXI AR/R | - | 없음(프로토콜). AXI3 호환 burst(LEN <= 15), ID 0, in-order |
| `axi_wr_eng` | 같음 | cmd + data in stream. AXI AW/W/B. `done_o`(모든 B 응답 수신) | - | 없음 |
| `pim_bank` | `LB` = 16, `DEPTH` = 4096, `NMAX`, `DOT_PIPE` | 가중치 쓰기(`we_i`, `waddr_i`, `wdata_i[144]`), lock-step 입력(`re_i`, `raddr_i`, `first_i`, `last_i`, `x_i[128]`은 read 1 cycle 뒤), 출력 `res_valid_o`(1 cycle), `res_acc_o[25]`, `res_wm_o[16]` (MAC_REG) | `LATENCY = 3 + DOT_PIPE`(마지막 word read -> res_valid) | `bank_gemv` BANK_ROW의 bank 하나(행 합 `k_dot8`, wm) |
| `pim_gb` | `NMAX`, `LB` = 16 | `load_i` + `n_i`, 쓰기 스트림(64b, `wr_ready_o` = busy), `done_o`, read `rd_en_i`/`rd_addr_i` -> `rd_word_o[128]`(n 밖 0) | 1 | `bank_gemv`의 `gbuf` |
| `pim_ctrl` | `NB`, `LB`, `DEPTH`, `NMAX`, `Y_DEPTH`, `L_BANK` | 명령 스트림 in, rd/wr 명령, LDW 스트림, gb load/read, bank write port, MAC read(mask, word, first/last), gather(`g_sel`, `g_last`, xm, sh), `y_pop_i`, 사건 펄스 | - | `bimg_pack`(bank 쓰기), `bank_stat_t`(사건 수) |
| `rms_front` | `N_MAX` | cfg(`n`, `ge`, `epsc`, `fy`); 원소 스트림(x n개, g n개, valid/ready); buffer 포트(RAM은 vec_core); y 스트림(valid만) -> `actq_core` | 마지막 y = start + 3n + 28 | A4 (amax, k, ss, u, rm, re, sh, y) |
| `swi_front` | `N_MAX`, `LUT_PIPE` | `n`; 원소 스트림(h1 n개, h3 n개); buffer 포트(silu 저장); g 스트림(valid만) | 마지막 g = start + 2n + 8 | A5 (g) |

### 3.4 L2 (kernel core)

| 모듈 | 주요 parameter | 입력 | 출력 | cycle 식 [계산] | golden 레코드 |
|---|---|---|---|---|---|
| `gemv_core` | `LANES` = 8, `N_MAX` | cfg: `rows`, `n`, `we`, `xm`, `xe`, `fo`, `start`. x stream(`ceil(n/8)` beat), 행 레코드 stream(header beat + `ceil(n/8)` beat) | y stream(32b), `done` | `ceil(n/8) + rows x (1 + ceil(n/8)) + L_pipe` (입력이 매 cycle 올 때) | K_GEMV (gs = n) |
| `pim_core` | `NB` = 4, `LB` = 16, `DEPTH` = 4096, `DOT_PIPE`, `SCALE_PIPE`, `Y_DEPTH` = 32 | 명령 stream(LDW, WRGB, MACAB), rd 명령 + 데이터 stream(64b) | wr 명령, y stream(32b + `y_last_o`), `busy_o`, `rd_stall_o`, 사건 | MACAB(앞 round에서 떨어진 경우): `(R-1) max(nw,4) + nw + L_BANK + nvl + L_S`, 기본 `ceil(rows/4) x ceil(n/16) + 12` (nw >= 4, rows % 4 = 0; S4-5 측정으로 확정) | K_GEMV + `bank_gemv` |
| `attn_core` | `KL` = `VL` = 8, `HS_MAX`, `TMAX`, PIPE 4개, `OUT_DEPTH` | start + cfg(`T`, `hs`, `kb`, `qm`, `qe`, `p_en`), q stream(ceil(hs/8) beat), KV pass 요청(`kvreq`, 0 K / 1 V) + KV stream(K beat + 위치 마지막 beat의 ks, vs / V beat) | 출력 stream(p[T] (p_en), o[hs], `last`, `is_o`), `done`, `kv_stall_o` | `(T+1) ceil(hs/8) + T + T ceil(hs/8) + hs + C0`, `C0 = 54 + DOT + SH + RS + LUT PIPE` (기본 60, S4-6 측정으로 확정) | K_ATTN2 |
| `kv_store` | `NKV`, `NL`, `SEQ`, `KL`, `KW`, `VW`, `H_PAR`, `FIFO_D` | 쓰기(kv head, layer, pos, K/V 16b lane, ks, vs), 포트 p의 pass 요청(kv head j mod H_PAR = p, layer, T) | 포트별 KV pass stream | 1 위치/cycle (요청 후 T + 3 이내) | `fwd_h.c`의 `kc/vc/kcs/vcs` 배치를 KVW로 옮긴 것 |
| `kv_rd` | `KL` = 8, `HS_MAX`, `TMAX`, `CH` | pass 요청(pass, T, hs, ths = T x hs(요청자가 계산, S4-6b), ek, ev, kv head의 K/V/KS/VS base) | `axi_rd_eng` 명령, KV pass stream | DDR beat 수에 묶임: K pass 위치당 hs ek / 8 + 2 beat, V pass hs ev / 8 beat | 같음 (golden 배치 그대로) |
| `vec_core` | `N_MAX`, `IDX_W`, `LUT_PIPE`, `Q_DEPTH` | op + cfg, read beat 스트림(명령 IN0, IN1 순서) | q stream + scale, 또는 idx/max | RMSNORM `4n + 87`, SWIGLU `3n + 67`, ACTQ `2n + 59`, ARGMAX `n + 1`(S4-7 측정, `vec.md` 6.1) | K_RMSNORM, K_SWIGLU, K_ACTQ, K_ARGMAX |

L3의 레지스터 맵과 kernel 호출 순서는 `arch.md` 7절.

### 3.5 S4-2 구현에서 고정한 세부 (2026-11-19, 위 표의 보완)
위 표에 없던 것을 구현하면서 정했다. 표와 충돌하는 변경은 없고, parameter 이름 하나(`gemv_core`의 `NMAX`)만 다르다.

| 모듈 | 보완 |
|---|---|
| 공통 | 모든 모듈에 `clk`, `rst_n`(`ram_sdp` 포함). `LATENCY`는 `localparam`. 시뮬레이션 전용 검사(`ifndef SYNTHESIS`)의 메시지는 tag로 시작한다: `VR_X`/`VR_HOLD`/`VR_STABLE`(valid/ready 입력 규칙), `RAM_X`/`RAM_ADDR`, `L1_RANGE`, `L2_RANGE`/`L2_START`/`L2_OVF` |
| `rshr_sat` | `IN_W` 2..62(golden 전제 `|x| < 2^61`), `SH_W` = 10. 우shift는 `sh >= IN_W`이면 0. `SAT_MODE 0`: `OUT_W` 2..63, OUT_W 범위로 포화(OUT_W 32 = `sat32(k_rshr)`). `SAT_MODE 1`: `OUT_W` = 64 필수, `k_rshr` 그대로(대칭 `+-I64MAX`, `sh <= -62`이면 0이 아닌 x는 모두 포화). `PIPE` 0..2: 1 = 출력 레지스터, 2 = shift 단 뒤에도 레지스터 |
| `dotp` | lane i = `[i*AW +: AW]`. `sum_o` 폭 `AW+BW+log2(LANES)`(전부 최소값 곱의 합까지 정확). `PIPE` 0..log2(LANES)+1: 1 = 출력, 2 = 곱 뒤 추가, j+2 = adder 단 j 뒤 추가. `LANES`는 2 이상의 2의 거듭제곱 |
| `sync_fifo` | first-word fall-through. `in_ready_o = level != DEPTH`(`out_ready_i`와 조합 경로 없음, full에서 같은 cycle pop이 있어도 push는 기다린다). `DEPTH` >= 1이면 2의 거듭제곱이 아니어도 된다. `level_o` 폭 `clog2(DEPTH+1)` |
| `ram_sdp` | 같은 cycle 같은 주소의 read/write는 이전 값(read-first). `RD_LAT` 1 또는 2. `DEPTH` >= 2, 주소 폭 `clog2(DEPTH)`. 내용 초기화 없음 |
| `mac_row` | parameter 추가: `N_MAX`(누산 폭 검사용), `DOT_PIPE`(dotp의 PIPE). 검사 `ACC_W >= AW+BW-1+clog2(N_MAX)`(gemv 25): 한쪽 피연산자가 최소값(-128)이 아니라는 전제(활성 x는 actq 출력 `|x| <= 127`). -128 x -128이 N_MAX개면 1비트 넘치며 시뮬레이션에서 `L1_RANGE`로 보고한다. `acc_o`는 `acc_valid_o` cycle에만 유효 |
| `gemv_scale` | `PIPE` 0..4(`LATENCY = PIPE`): 1 = rshr_sat 출력, 2 = `acc*wm` 뒤, 3 = `S*xm` 뒤, 4 = rshr_sat 중간. 내부 폭 S 41비트, P 58비트(ACC_W 25). `ACC_W` <= 29 |
| `gemv_core` | parameter: `LANES`(8 고정, 다른 값은 elaboration 실패: 64비트 beat = int8 8개), `NMAX`(= `llm_pkg::N_MAX`, 8의 배수), `ROWS_W`(16), `DOT_PIPE`, `SCALE_PIPE`, `Y_DEPTH`(16). 포트: `start_i`, `rows_i[ROWS_W]`, `n_i[clog2(NMAX+1)]`, `we_i`/`xe_i`/`fo_i[E_W]` signed, `xm_i[AM_W]`, `busy_o`, `done_o`(마지막 y 수락 다음 cycle의 1 cycle pulse), x stream(`x_valid_i/x_ready_o/x_data_i[64]`, LOADX 단계에서만 수락, 마지막 beat의 lane >= n은 무시하고 0으로 마스크), 행 레코드 stream(`w_valid_i/w_ready_o/w_data_i[64]`, header beat는 `[15:0]`만 사용, x를 다 받은 뒤 수락), y stream(`y_valid_o/y_ready_i/y_data_o[32]`). y 쪽 backpressure는 credit으로 처리: header 수락부터 y 수락까지의 행 수가 `Y_DEPTH` 미만일 때만 header를 받는다. `Y_DEPTH >= (L_PIPE+3)/2 + 1`을 elaboration에서 검사 |
| `gemv_core` cycle 식 | `start_i`가 1인 cycle을 0, `done_o`가 1인 cycle을 C라 하면, 모든 입력 beat가 바로 오고 `y_ready_i`가 1일 때 `C = ceil(n/8) + rows x (1 + ceil(n/8)) + L_PIPE`, `L_PIPE = 3 + mac_row.LATENCY + gemv_scale.LATENCY = 4 + DOT_PIPE + SCALE_PIPE`(기본 2, 3이면 9). 3 = x buffer read 단 1 + y FIFO 1 + done 레지스터 1. `arch.md` 2.4의 식에서 `L_dram`을 뺀 것과 같다(S4-2 시뮬레이션으로 확인, `sim/tests/gemv_core.cfg`) |

### 3.6 S4-3 구현에서 고정한 세부 (2026-11-19, 3.3 표의 보완)
3.3 표의 `axi_rd_eng`/`axi_wr_eng` 행과 충돌하는 변경은 없다. parameter와 포트가 늘었다(`IDW`, `LEN_W`, `FIFO_DEPTH`, `AXCACHE`, 런타임 한도 `cfg_burst_i`/`cfg_outs_i`, 상태 출력). 검증: `sim/tests/axi_rd_eng.cfg`, `axi_wr_eng.cfg`, `axil_slave.cfg`, `bw_top.cfg`.

공통 규칙 (두 engine):

| 항목 | 규칙 |
|---|---|
| parameter | `DW` = 64 고정(다른 값은 elaboration 실패), `AW` 12..64, `IDW` 1..16, `LEN_W` 4..40(`cmd_bytes_i` 폭), `MAX_BURST` 1..256(16 = AXI3/HP 한도), `OUTS` 1..64, `FIFO_DEPTH` >= `MAX_BURST`(rd 기본 `MAX_BURST x OUTS`, wr 기본 `2 x MAX_BURST`), `AXCACHE` 기본 4'b0011 |
| 명령 | `cmd_valid_i/cmd_ready_o`, `cmd_addr_i[AW]`, `cmd_bytes_i[LEN_W]`. beat 수 = `ceil(bytes/8)` |
| 비정렬 | **지원하지 않는다.** `addr[2:0] != 0`, `bytes == 0`, `addr + bytes > 2^AW`인 명령은 거절: engine이 idle(`busy_o` = 0)일 때만 수락되고(busy 중에는 `cmd_ready_o` = 0으로 기다림), AXI 트래픽과 데이터 없이 `err_cmd_o`(sticky)를 세우고 handshake cycle에 `done_o` 1 cycle. 시뮬레이션 메시지 `ENG_CMD`. 길이는 8의 배수가 아니어도 된다(아래 마지막 beat 규칙) |
| burst 분할 | INCR, SIZE 8 B, ID 0, beat 수 = `min(남은 beat, burst 한도, 다음 4 KiB 경계까지 beat)`. 시작 주소를 burst 크기에 정렬하지 않는다(첫 burst만 4 KiB 경계에서 짧아질 수 있음) |
| 런타임 한도 | `cfg_burst_i[8:0]`(1..`MAX_BURST`, 0 또는 초과 값은 `MAX_BURST`), `cfg_outs_i[6:0]`(1..`OUTS`, 0 또는 초과는 `OUTS`). 명령 handshake에서 latch |
| outstanding | 제시한 burst(AxVALID를 올린 것) - 완료(RLAST 또는 B) <= 한도 |
| 오류 응답 | `err_resp_o` = RRESP[1] 또는 BRESP[1](SLVERR, DECERR)를 본 뒤 sticky. 데이터는 그대로 전달/기록. `err_clr_i`로 `err_resp_o`, `err_cmd_o`를 지운다. 같은 cycle의 새 오류가 이긴다 |
| control reset | 명령/AR/AW 상태, 카운터, FIFO 포인터, sticky 오류만 `rst_n`. 주소, 길이, 데이터 레지스터는 reset 없음 |

| 모듈 | 보완 |
|---|---|
| `axi_rd_eng` | 출력 스트림 `d_valid_o/d_ready_i/d_data_o[64]/d_last_o`(명령의 마지막 beat). 마지막 beat의 길이 밖 byte는 메모리 내용 그대로(소비자가 무시). R 버퍼 = `sync_fifo`(`FIFO_DEPTH` x 65). **AR은 버퍼 여유가 burst 전체를 덮을 때만 제시**(space 카운터 = `FIFO_DEPTH` - 버퍼 beat - 요청했지만 아직 안 온 beat). 그래서 `RREADY`(= 버퍼 not full)는 RVALID가 올 때 항상 1이고 R 채널은 하류 backpressure와 무관하게 멈추지 않는다(위반 시 `ENG_RSTALL`). burst 경계는 RLAST로 정한다(burst 정보 FIFO `OUTS` 깊이; RLAST 위치가 길이와 다르면 `ENG_RLAST`, 요청 없는 R은 `ENG_RUNEXP`). `busy_o` = 수락된 명령의 마지막 beat가 아직 안 나감, `done_o` = 마지막 beat handshake(또는 거절 명령), `stall_o` = `busy_o && d_ready_i && !d_valid_o`(소비자가 데이터를 기다린 cycle, CSR `RD_STALL`의 원천). latency: 명령 handshake c -> ARVALID c+2(`act_q`, `arvalid_q` 두 단. TB로 재지 않은 값, RTL 구조에서 도출). 처리율: stall 없는 메모리(latency 1)에서 burst 16 x outstanding 2 이상이면 1 beat/cycle(측정, 아래) |
| `axi_wr_eng` | 입력 스트림 `in_valid_i/in_ready_o/in_data_i[64]`, 명령마다 `ceil(bytes/8)` beat, 명령 순서대로(byte i는 beat i/8의 lane i mod 8). 데이터가 명령보다 먼저 와도 된다(버퍼에서 기다림). 거절된 명령의 데이터는 보내지 않는다(호출자 책임). **32비트 y 스트림은 호출자가 두 개씩 64비트 beat로 묶는다**(S4-4 `gemv_acc_top`). WSTRB = 8'hFF, 단 길이가 8의 배수가 아닌 명령의 마지막 beat는 `(1 << (bytes mod 8)) - 1`. **burst 단위 store-and-forward**: burst의 모든 beat가 버퍼에 있을 때만 AW를 제시하고(uncommitted-beat 카운터), W는 그 burst의 AW handshake 뒤에 시작해 burst 안에서 WVALID가 끊기지 않는다. `FIFO_DEPTH >= 2 x MAX_BURST`면 다음 burst가 채워지는 동안 현재 burst가 나가 1 beat/cycle(`FIFO_DEPTH` = `MAX_BURST`면 0.842 beat/cycle 측정). BREADY = 1 고정(요청 없는 B는 `ENG_BUNEXP`). `busy_o` = 마지막 B 전, `done_o` = 명령의 마지막 burst의 B handshake(또는 거절 명령), `stall_o` = `in_valid_i && !in_ready_o` |
| `axil_slave` | pqc-ntt-ip `rtl/l4/axil_slave.sv`를 그대로 복사(헤더 주석만 다름, 시뮬레이션 tag `L4_AXI_*` 유지). TB도 복사(`tb/axil_slave/`), 같은 7 run |
| `bw_top` | 레지스터 맵과 동작은 `spec/bwtest.md`. parameter `P`(1, 2), `MAX_BURST`, `OUTS`, `RD_FIFO`, `WR_FIFO`, `IDW`, `FCLK_MHZ`, `ADDR_W`(8..32). AXI master 포트는 `[P-1:0][...]` packed 배열(포트 p = HP0, HP2). engine 명령이 거절될 조건(정렬, 2^32 넘김)을 descriptor 검사에서 먼저 막는다(`BAD_DESC`): 거절된 쓰기 명령은 pattern 생성기가 이미 넣은 beat를 engine 버퍼에 남겨 다음 op의 데이터를 밀기 때문이다(S4-3 TB에서 발견, 수정) |

처리율 측정 [측정, Questa, `axi_mem_slave` 모델, 보드 아님]: 64 KiB(8,192 beat) 명령 하나, 메모리 stall 없음. 첫 beat부터 마지막 beat까지 cycle.

| engine | burst | outs | 메모리 latency (rd: AR->R, wr: 마지막 W->B) | cycle | beat/cycle |
|---|---|---|---|---|---|
| rd | 16 | 1 | 1 | 9,725 | 0.842 |
| rd | 16 | 2, 4 | 1 | 8,192 | 1.000 |
| rd | 16 | 2 | 33 | 13,037 | 0.628 |
| rd | 16 | 4 | 33 | 8,192 | 1.000 |
| rd | 256 | 1 | 1 / 33 | 8,285 / 9,277 | 0.989 / 0.883 |
| rd | 256 | 2 | 33 | 8,192 | 1.000 |
| rd | 1 | 1 / 4 | 1 | 40,956 / 10,239 | 0.200 / 0.800 |
| wr | 16 | 1 | 1 | 10,236 | 0.800 |
| wr | 16 | 2, 4 | 1 | 8,192 | 1.000 |
| wr | 16 | 4 | 33 | 8,192 | 1.000 |
| wr | 16 (FIFO 16) | 4 | 1 | 9,725 | 0.842 |
| wr | 1 | 4 | 1 | 16,382 | 0.500 |

- outstanding 1에서 burst 사이 빈 cycle은 왕복 지연(AR 제시 1 + 모델 latency + 버퍼 1 + 다음 AR 판단)이다. 실제 HP 포트의 latency는 보드 측정(`spec/bwtest.md`) 전까지 모른다.
- `bw_top`(P = 1, 2) 64 KiB RD op의 CYCLES는 8,197(P = 1과 2 모두, stall 없는 모델), 즉 8,192 beat + 5 cycle의 시작/종료 지연이다.

### 3.7 S4-4에서 고정한 세부 (2026-11-19)
`argmax_red`, `gemv_acc_csr`, `gemv_acc_top`(상태: 시뮬레이션 통과, `./sim/run.sh all` 201 run fails 0). 레지스터 맵, 호출 규칙, CYCLES 식, 검증 내용은 `spec/gemv_acc.md`가 원본이고 아래는 계층 관점의 요약이다. 시뮬레이션 모델의 값이며 보드 값이 아니다.

- 구성: `axil_slave`(`u_axil`) + `gemv_acc_csr`(`u_csr`) + slice p(p < P)마다 `axi_rd_eng`(`u_rd`) + `gemv_core`(`u_core`) + y merge + `argmax_red`(`u_am`) + packer + `axi_wr_eng`(`u_wr`, 포트 0). 하위 모듈은 수정 없이 인스턴스만 했고 top이 직접 하는 것은 명령 순서기, read stream router, merge, packer, 종료 판정, 오류/stall event다.
- 행 분배: P = 2이면 slice p가 행 r (r mod P = p)을 계산한다. P = 1은 행 레코드 명령 1개(`W_ADDR`, ROWS x RB), P = 2는 행마다 read 명령 1개(`W_ADDR + r RB`, RB). 두 포트가 행을 교대로 가져가 주소가 2 RB 간격이라 한 명령으로 묶을 수 없기 때문이다. 명령 순서는 x 명령 다음 행 레코드 명령이고, read stream은 x 명령의 마지막 beat까지 core의 x 포트(`xph_q`), 그 뒤 w 포트로 간다. 행이 없는 slice(P = 2, ROWS = 1의 slice 1)는 시작하지 않는다.
- y merge: 행 순서대로 slice (r mod P)에서 하나씩 받는다(`sel_q`). `y_en = 0`이면 merge가 기다리지 않고 y를 버린다.
- packer: y 2개를 64비트 beat로 묶는다(y[2k]는 [31:0]). 홀수 ROWS의 마지막 beat는 y 하나이고 [63:32]는 0이며, 쓰기 명령 길이가 4 ROWS byte라 `axi_wr_eng`가 그 beat의 WSTRB를 0x0F로 낸다(3.6). y 뒤 4 byte는 바뀌지 않는다.
- RD_STALL 정의: 어떤 slice의 core가 read beat를 받을 수 있는데(x 포트는 LOADX, w 포트는 RUN) beat가 없는 cycle. engine 경계가 아니라 core 경계에서 센다. WR_STALL은 packer의 beat를 `axi_wr_eng`가 받지 못한 cycle(`stall_o`).
- 오류 비트(ERR, W1C): bit0 START_BUSY, bit1 BAD_OP, bit2 BAD_DESC, bit3 MISALIGN, bit4 RD_RESP, bit5 WR_RESP. RD_RESP/WR_RESP는 RRESP[1]/BRESP[1]인 AXI handshake마다 set한다. descriptor 검사가 engine의 거절 조건(정렬, 길이 0, 2^32 넘김)을 막아 engine은 명령을 거절하지 않는다(시뮬레이션 검사 `L3_ENGCMD`). `FLAGS[1:0] = 0`(y_en, argmax_en 모두 0)은 BAD_DESC.
- 시간 정의: CTRL 쓰기가 수행되는 cycle이 s, 호출 종료 cycle이 e(모든 시작한 core의 `done_o`, `y_en`이면 마지막 B handshake, `argmax_en`이면 `argmax_red`의 `done_o`). `CYCLES = e - s`(busy cycle 수). descriptor는 s + 1에 latch되고 core start와 명령 순서기 적재도 s + 1, 명령 제시는 s + 2부터다.
- `argmax_red`의 `max_o`는 3.2절 표에 반영했다(`gemv_acc_csr`의 `ARGMAX_VAL`로 간다).

### 3.8 S4-5에서 고정한 세부 (2026-11-19)
`pim_gb`, `pim_bank`, `pim_ctrl`, `pim_core`, `pim_csr`, `pim_top`(상태: 시뮬레이션 통과). 명령 형식, 레지스터 맵, 실행 규칙, cycle 식, 검증 내용은 `spec/pim.md`가 원본이고 아래는 계층 관점의 요약이다. 시뮬레이션 모델의 값이며 보드 값이 아니다.

- 구성: `pim_top` = `axil_slave` + `pim_csr` + `sync_fifo`(명령 FIFO, `CMD_DEPTH` 32 x 128) + `pim_core` + `axi_rd_eng` + packer + `axi_wr_eng`(HP 포트 하나의 read/write 채널). `pim_core` = `pim_ctrl` + `pim_gb` + `pim_bank` x 4 + gather mux + `gemv_scale` + `sync_fifo`(y FIFO). 하위 모듈(`mac_row`, `gemv_scale`, engine, `ram_sdp`, `sync_fifo`, `axil_slave`)은 수정 없이 인스턴스만 했다.
- 명령은 CSR의 CMD_PUSH 때 검사한다(BAD_CMD, BAD_DESC, MISALIGN, FIFO_OVF). 그래서 core에는 합법 명령만 가고 engine은 명령을 거절하지 않는다(`L3_ENGCMD`, `PIM_RANGE`). CTRL op 1 RUN(FIFO가 빌 때까지, run 중 push 허용), op 2 FLUSH.
- MAC_REG: bank마다 `mac_row` 누산기 뒤 레지스터 하나. round(행 4개)의 마지막 word read에서 `L_BANK` = 3 + DOT_PIPE 뒤에 4 bank의 결과가 동시에 MAC_REG에 있고, `pim_ctrl`이 bank 0..3 순서로 한 cycle에 하나씩 gather한다. round 마지막 word 사이 간격 >= NB(nw < 4이면 round 4 cycle)라 MAC_REG 하나로 충분하다. y 쪽 backpressure는 round 단위 y FIFO credit(Y_DEPTH)으로 처리한다.
- LDW: 행 레코드 beat 둘 -> word 하나(열 >= n은 0, tag는 첫 word의 wm), 마지막 round의 빈 slot은 0 word로 채운다(`bimg_pack`과 같은 image). WRGB: `pim_gb`가 n 밖을 0으로 읽는다.
- 사건 카운터(`bank_stat_t` 정의): ST_MAC = MAC read cycle, ST_WRGB = gb beat 0, 4, 8, ..., ST_RDMAC = gather 수. 레코드마다 WRGB를 내는 순서에서는 `bank_gemv`의 합과 같고, layer 순서에서는 wrgb만 WRGB 명령 수에 맞게 줄어든다.
- run 종료: FIFO가 비고, core에 진행 중인 것이 없고, write engine이 마지막 B를 받은 다음 cycle. CYCLES = e - s.
- 260K token(stall 없는 메모리 모델, latency 1): MAC 4,072 cycle(식과 같음), 컨트롤러 점유 4,108, `pim_top` run CYCLES 합 4,501~4,506(token 한 run), 4,658~4,676(layer마다 run). 같은 모델의 가속기형 P = 1은 37,596.
- RDROW는 구현하지 않았다.

### 3.9 S4-6에서 고정한 세부 (2026-11-19)
`udiv_seq`, `lut_lerp`, `exp_unit`, `attn_score`, `attn_vacc`, `attn_core`, `kv_store`, `kv_rd`, `attn_csr`, `attn_top`(상태: 시뮬레이션 통과). 데이터 배치, 레지스터 맵, 실행 규칙, cycle 식, 검증 내용은 `spec/attn.md`가 원본이고 아래는 계층 관점의 요약이다. 시뮬레이션 모델의 값이며 보드 값이 아니다.

- 구성: `attn_top` = `axil_slave` + `attn_csr` + engine e < H_PAR(head 순서기 + `axi_rd_eng` 읽기 포트 e + q 조립 + `attn_core`) + KV source(`kv_store` 하나, 또는 `kv_rd` x H_PAR, parameter `KV_SRC`) + write 중재 + packer + `axi_wr_eng`. `attn_core` = `attn_score` + `ram_sdp` 2개(p buffer, vs buffer) + `exp_unit` + `udiv_seq` + `attn_vacc` + `sync_fifo`(출력). 기존 모듈은 수정 없이 인스턴스만 했다.
- 초안과 다른 점: `attn_ctrl`을 따로 두지 않고 pass FSM을 `attn_core`에 두었다. `attn_core`가 vs buffer를 가져 V pass 스트림은 V만 싣는다(engine당 BRAM18 하나 추가, `attn.md` 8절). `udiv_seq` CYCLES는 Q_W + 1. `lut_lerp`는 EXP2N만(SIGM은 S4-7).
- 호출: op ATTN(layer 하나의 head 범위, D9)과 op KVW(KV_SRC 0, 위치 하나의 kv head 범위). 명령 FIFO는 없다. head h는 engine (h / KVMUL) mod H_PAR가 맡고, `kv_store` 읽기 포트 p는 kv head j mod H_PAR = p만 읽는다.
- 배치: q 레코드 `{qm, qe}` + q int16 [hs], o는 golden `att + h hs`, p는 head마다 8 ceil(T/2) B 간격(write engine의 8 B 정렬), DDR KV는 golden `kc/vc/kcs/vcs` slot 배치 그대로. top은 hs % 8 == 0만 받는다.
- cycle(`attn.md` 6절): core `C = (T+1) ceil(hs/8) + T + T ceil(hs/8) + hs + 60`(기본 PIPE). 260K token(H_PAR 2, KV BRAM, T 512) ATTN 합 32,420(arch.md 4.4 계산 32,320), 15M token(H_PAR 1, KV DDR, T 256) 198,294(계산 196,416).

### 3.10 S4-6b에서 바뀐 세부 (2026-11-20, 합성 품질 정리)
L3 top/CSR과 `pim_ctrl`, `kv_rd`의 runtime 곱셈(주소 계산, descriptor 범위 검사)을 없앴다. 기능(판정 결과, 주소, 데이터)은 같고, 순차 계산이 들어간 곳만 timing이 바뀌었다. 원본은 `spec/attn.md` 4절, `spec/gemv_acc.md` 3절, `spec/pim.md` 4절.

- 새 leaf `umul_seq`(L0, 3.2절 표): 부호 없는 shift-add 곱셈기, multiplier 1비트/cycle, `CYCLES = B_W + 1`. 단독 TB `tb/umul_seq`(경계 쌍, random 10^6, 크기 6종, 소형 전수, 부정 시험, elaboration 실패).
- `attn_csr`: CTRL 수락(s) 뒤 s + 1 .. v에 `umul_seq`/`udiv_seq`로 검사, v = s + CHK_CYC에 `start_o` 또는 BAD_DESC/MISALIGN. CHK_CYC = 10(KV_SRC 0 기본), 18(KV_SRC 1). top용 곱 출력 `seqhs_o`, `ths_o`, `kw0_o` 추가.
- `gemv_acc_csr`: 같은 방식, CHK_CYC = NBW + 1(NMAX 1024에서 9). `op_wbytes_o`는 판정 cycle부터 유효.
- `pim_csr`: CMD_PUSH 검사가 PCHK_CYC(NMAX 1024에서 9) cycle. 검사 중 CMD_PUSH는 ERR bit8 PUSH_BUSY, STATUS bit3 push_busy. 출력 `push_busy_o`로 `pim_top`의 run 종료를 막는다.
- `pim_ctrl`: LDW 읽기 길이를 `umul_seq`로 구해 LDW 읽기 명령이 LDW_CYC(NMAX 1024에서 9) cycle 늦다. MACAB와 WRGB는 그대로.
- `attn_top`: head/kv head/KVW slot 주소를 base + stride 누적(카운터가 증가할 때 더함)으로 바꿨다. stride는 descriptor의 shift와 `attn_csr`의 곱. cycle은 바뀌지 않는다(CSR 검사 cycle만 앞에 붙음).
- `kv_rd`: 요청에 `ths`(T x hs) 입력 추가. K 행 명령 주소는 chunk마다 CH hs ek를 더하고, 마지막 chunk 길이는 T hs ek - 누적 offset, V pass 길이는 T hs ev. cycle은 그대로.
- `kv_store`(layer x SEQ, SEQ parameter)와 `gemv_acc_top`(P x RB, P parameter)은 상수 곱이라 폭만 정리하거나 그대로 두었다.

### 3.11 S4-7에서 고정한 세부 (2026-11-20)
`rsqrt_nr`, `lut_lerp`(SIGM), `actq_core`, `rms_front`, `swi_front`, `vec_core`, `vec_csr`, `vec_top`(상태: 시뮬레이션 통과). 데이터 배치, 레지스터 맵, 실행 규칙, cycle 식, 검증 내용은 `spec/vec.md`가 원본이고 아래는 계층 관점의 요약이다. 시뮬레이션 모델의 값이며 보드 값이 아니다.

- 구성: `vec_top` = `axil_slave` + `vec_csr` + 읽기 명령 순서기(IN0, IN1) + `axi_rd_eng` + `vec_core` + 쓰기 명령 순서기(OUT, SCL) + packer + `axi_wr_eng`(HP 포트 하나). `vec_core` = unpacker(int32 2개/beat, int16 4개/beat) + `rms_front` + `swi_front` + 공유 front buffer(`ram_sdp` N_MAX x 32) + `actq_core` + `argmax_red`. 기존 모듈은 수정 없이 인스턴스만 했고, `lut_lerp`에 SIGM을 추가했다(EXP2N 동작 불변, 회귀 확인).
- 초안과 다른 점: front의 buffer를 `vec_core`에 하나 두고 op에 따라 `rms_front`(x)나 `swi_front`(silu)가 쓴다(front마다 하나 두는 것보다 BRAM36 1개 적음). `swi_front`는 h1을 받는 동안 silu까지 계산해 buffer에 둔다(HP 포트 하나라 h1 명령 뒤에 h3 명령이 온다). `rsqrt_nr`의 rm은 17비트(초안 32비트; 전수 확인 rm <= 65535). `actq_core`의 `e_o`는 e + f를 SH_W 폭으로 낸다(초안 E_W: f가 8비트 signed 전체 범위면 넘친다).
- 호출: op RMSNORM, SWIGLU, ACTQ, ARGMAX(D10). descriptor 검사는 shift와 덧셈뿐이라 1 cycle(v = s + 1). runtime 곱셈기와 나눗셈기는 control에 없다(leaf 데이터패스의 곱만).
- cycle: core `RMSNORM 4n + 87`, `SWIGLU 3n + 67`, `ACTQ 2n + 59`, `ARGMAX n + 1`. top CYCLES는 core + 1 + 쓰기 꼬리(보통 11 + max(L_last, 2), ARGMAX 13). token당 합(stall 없는 모델): 260K 약 15,680(RMSNORM 3,993, SWIGLU 3,005, ACTQ 8,155(85 호출), ARGMAX 527), 15M 약 85,741(16,321, 14,386, 23,019(114 호출), 32,015).

### 3.12 S5-2에서 고정한 세부 (2026-11-20)
`axil_xbar`, `sys_a_top`, `sys_p_top`(상태: 시뮬레이션 통과). 주소 맵, slot 표, HP 포트 배정, latency, 포트 이름 규칙은 `spec/system.md` 1.7절 "S5-2에서 확정한 세부"가 원본이고 아래는 계층 관점의 요약이다.

| 모듈 | parameter | 포트 요약 | latency | 검증 |
|---|---|---|---|---|
| `axil_xbar` (L4, control) | `N` 1..2^SLOT_W, `SLOT_W` 1..4, `S_ADDR_W` 12 + SLOT_W..32, `SLOT_EN`[15:0], `REG` 0/1 | `s_axi_*`(AXI4-Lite slave, `S_ADDR_W` 비트), `m_axi_*[N]`(AXI4-Lite master, 주소 12비트 = slot offset) | `localparam LAT_REQ = LAT_RSP = REG`: REG 1은 요청과 응답 각 1 cycle의 register slice(조합 경로 없음), REG 0은 조합 통과 | 단독 TB `tb/axil_xbar`(reference decode, 도착 slave/offset/data/WSTRB/PROT/응답 대조, cycle 규칙, valid 유지, 음성 시험), `sim/tests/axil_xbar.cfg` |
| `sys_a_top` (L4) | `S_ADDR_W`, `XB_REG`, `IDW`, `MAX_BURST`, `OUTS`, `FCLK_MHZ`, `GA_*`, `AT_*`, `VE_*`(기본 = 빌드 A) | `clk`, `rst_n`, `s_axi_*`, `m_hp0..3_axi_*`(AXI4 master 64비트, read 묶음과 write 묶음) | xbar `REG` 따름. IP latency는 각 IP 문서 | smoke `tb/sys_top`(BUILD 0), `sim/tests/sys_a_top.cfg` |
| `sys_p_top` (L4) | 같은 공통 parameter, `PI_*`, `AT_*`, `VE_*`(기본 = 빌드 P) | 같은 포트 목록 | 같음 | smoke `tb/sys_top`(BUILD 1), `sim/tests/sys_p_top.cfg` |

- 두 top은 인스턴스, 배선, 상수 tie-off만 갖는다(xbar의 없는 slot 입력, 쓰지 않는 HP 채널 묶음). HP2 read 채널의 선택(A2의 gemv_acc slice 1, A'/P의 attn engine 1, 그 밖 tie-off)은 parameter에 따른 generate다.
- 하위 L3 모듈(`gemv_acc_top`, `pim_top`, `attn_top`, `vec_top`)은 수정하지 않았다. 각 IP의 `ADDR_W`는 12(slot 4 KiB)로 고정해 연결한다.
- HP 포트마다 독립 메모리 모델이라, 포트 사이 공유 버퍼가 필요한 시험은 S5-3(`axi_mem_slave` EXT_STORE)에서 한다.

### 3.13 S5-3/S5-4 시스템 TB (2026-11-23)
| TB | DUT | 구동 | 메모리 | 회귀 |
|---|---|---|---|---|
| `tb/sys_top/tb_sys_fwd.sv` | `sys_a_top` / `sys_p_top` (VAR 1: A2, PD; VAR 2: XB_REG 0) | `fpga/sys/sw` 시스템 프로그램(수정 없음)을 DPI-C context task로 실행, HAL `tb/sys_top/hal_dpi.c`가 `axil_bfm`의 exported task로 레지스터 접근 | HP 포트 4개의 `axi_mem_slave`(EXT_STORE 1)가 C cache 모사(`fpga/sys/test/hal_cache.c`)의 DDR 이미지 하나를 공유 | `sim/tests/sys_smoke.cfg`(S5-3), `sys_fwd.cfg`(S5-4) |

- L4 top과 L3 IP는 S5-3/S5-4에서 수정하지 않았다. 판정과 시나리오는 `spec/system.md` 3.2절 "S5-3/S5-4 구현".
- `axi_mem_slave`는 TB 공통 모듈이라 EXT_STORE 기본 0에서 기존 동작이 같음을 전체 회귀로 확인했다(465 run).

## 4. golden에 경계가 없어 `model/`에 추가해야 하는 것

kernel 단위(K_GEMV, K_ACTQ, K_RMSNORM, K_ATTN2, K_SWIGLU, K_ARGMAX)는 기존 덤프 레코드로 검증할 수 있다. 아래는 leaf와 L1 단위의 경계가 없거나, kernel 덤프만으로는 부족한 것이다. 원칙: **kern.c의 kernel 함수가 스스로 호출하는 stage 함수로 쪼개서 export한다**(별도 재구현 금지). 바꾼 뒤 `make test` PASS와 기존 덤프 `cmp` 동일로 golden이 변하지 않았음을 확인한다.

| ID | 대상 leaf/모듈 | 필요한 것 | 현재 상태 (2026-11-19 S4-1) |
|---|---|---|---|
| A1 | `dotp`, `mac_row` | 행별 int32 `acc`(scale 전). `k_gemv`를 `k_gemv_acc`(행 하나의 그룹 합) + `k_gemv_out`으로 분리 | **완료**. `k_dot8`(그룹 합), `k_gemv_row`(행의 S), `k_gemv_st`(행별 S trace). `k_gemv`가 이 함수들로 계산 |
| A2 | `gemv_scale` | `(acc, wm, xm, sh) -> y` | **완료**. `k_gemv_out(S, xm, sh)`, S = acc x wm (gs = n). DPI `kd_gemv_out` |
| A3 | `attn_score`, `exp_unit`, `attn_vacc` | score 배열(softmax 전), `mx`, 분자 배열, `sum`, `R`, `emin`, `mmax`, `G`, 위치별 `w` | **완료**. `k_attn2_st`(`k_attn_st_t`: dot, s, e, w, acc 배열과 d0, mx, sum, R, emin, mmax, G). S4-6: stage 함수 `k_attn_score`, `k_attn_exp`, `k_attn_pn`, `k_attn_w`, `k_attn_out` export(`attn_core`가 이 함수로 계산, 기존 덤프 4종 `cmp` 동일, `make test` mismatch 0), DPI `kd_attn_*`, `kd_att_*` |
| A4 | `rms_front`, `rsqrt_nr` 연결 | `k`, `ss`, `u`, `rm`, `re`, `sh`, 양자화 전 y 배열, `ymax` | **완료**. `k_rmsnorm_st`(`k_rms_st_t`). DPI `kd_vec_*`(S4-7) |
| A5 | `swi_front` | 양자화 전 `g` 배열과 `amax` | **완료**. `k_swiglu_st`(`k_swi_st_t`). DPI `kd_vec_*`(S4-7) |
| A6 | `pim_core` bank image | bank RAM의 144비트 word image 생성기(가중치 + parity bit의 행 가수, `arch.md` 3.3)와 그 image로 `bank_gemv`를 돌려 `k_gemv`와 같음을 보이는 시험 | **완료**. `bimg_pack`/`bimg_unpack`(`src/bank.c`), `vt` job bimg -> `build/vec/pim/bank0..3.hex`(word = tag 16 + lane 128, 4,072/4,096 word). `make test` `m1 PIM bank image`, DPI `kd_rec_bimg` |
| A7 | `actq_core` 내부(선택) | `aq_setup`(amax, mode, qmax -> M, R, e)과 `aq_one` export | **완료**. `k_aq_setup`, `k_aq_one`(`k_aq_t`), `k_actq_st`. DPI `kd_aq_setup`, `kd_aq_one`, `kd_vec_*`(S4-7) |
| A8 | leaf 벡터 생성 | `rshr_sat`, `udiv_seq`, `lut_lerp`, `rsqrt_nr`용 random/전수 벡터. DPI-C로 kern.c를 TB에 직접 링크하는 방식을 권고(파일 없이 random 생성) | **S4-2 분 완료**: DPI-C(`tb/dpi/kdpi.c`)로 `kd_rshr`, `kd_sat32`, `kd_dot8`, `kd_gemv_out`, `kd_exp2neg`, `kd_sigmoid`, `kd_rsqrt`. `udiv_seq`는 C `/` 그대로라 DPI 함수 없이 TB의 64비트 `/`로 대조(S4-6) |
| A9 | 덤프 설정 | K12V8 덤프(260K `d3`, 15M `d4`). 위치 필터(예: 0..7, 63, 127, 255, 511)로 attention의 긴 T를 포함하되 파일 크기 제한 | **완료**. `cfg/d3.cfg`(260K 위치 0..7, 63, 127, 255, 511, 2,388 레코드), `cfg/d4.cfg`(15M 위치 0..3, 127, 255, 1,428 레코드), 키 `pos`, `noeos` |
| A10 | 범위 집계 | 덤프 전체의 지수(`we`, `e`), shift, `T`, `n`의 최소/최대 표 -> `E_W`, `SH_W` 확정 | **집계 완료**(`model/results/range_k12v8.txt`). 지수 0..33(signed 7비트), shift -1..40(signed 7비트). 확정은 오케스트레이터(3.1 표의 비고) |
| A11 | 덤프 -> TB 변환 | kernel 레코드를 TB가 읽는 형식(kernel별 파일 + manifest)으로 나누는 도구. 인자 대신 환경변수 설정(`process-privacy.md`) | **완료**. `vt` job split -> `build/vec/m1`, `m2/<kernel>.bin` + `manifest.txt`(같은 레코드 형식, DPI `kd_rec_*`로 읽음). 행 레코드 `rrec.bin`(`vt` job rrec) |
