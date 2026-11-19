# 계층 구조: llm-pim-soc (S4)

상태: **초안** (2026-11-19, S4-0). 오케스트레이터 검토 전이며, `arch.md` 끝의 "열린 결정"이 확정되면 해당 부분을 고친다. 이 문서의 구성과 포트는 열린 결정의 **권고안**을 기준으로 적었다. 구조 결정과 수치 근거는 `arch.md`가 원본이다.

- golden: `model/src/kern.c`(kernel 함수), `model/src/bank.c`(PIM bank 분할 GEMV), `model/src/fwd_h.c`(호출 순서와 KV cache 배치). RTL은 kernel 경계에서 bit-exact여야 한다.
- 형식: K12V8(`spec/numeric.md` 4절). 행 단위 가중치 scale(gs = n), MANT 활성 scale, q/K 12비트(int16 container), V 8비트, LUT 8비트(257항목).
- 표기: [계산] = 구성에서 식으로 구한 값, [추정] = 가정이 들어간 값. 이 문서의 어떤 수치도 합성이나 시뮬레이션으로 잰 것이 아니다.

## 1. 트리

L0 = 하위 모듈이 없는 leaf, L1 = L0 조합, L2 = kernel core(로컬 인터페이스, AXI 없음), L3 = AXI가 붙은 IP top, L4 = 시스템(S5).

```
L4  sys_p_top        (S5) 260K PIM형 시스템: pim_top + attn(KV는 BRAM) + vec_top              RTL
L4  sys_a_top        (S5) 15M 가속기형 시스템: gemv_acc_top + attn_top(KV는 DDR) + vec_top     RTL

L3  gemv_acc_top     GEMV 가속기형 IP. AXI-Lite CSR + HP read/write master + gemv_core x P       RTL
      L1  axil_slave       AXI4-Lite 5채널 -> 레지스터 strobe (pqc-ntt-ip에서 복사)                RTL
      L3  gemv_acc_csr     레지스터 맵, done_sticky, ERR, CYCLES/STALL 카운터                       RTL
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
      L2  pim_core         NB개 bank + global buffer + 명령 컨트롤러 + 결과 gather                    RTL
            L1  pim_ctrl         명령 FSM: LDW, WRGB, MACAB, RDROW. bank 주소와 lock-step 스케줄     RTL
            L1  pim_gb           global buffer(활성 벡터 1개), 방송 read                           RTL
            L1  pim_bank         bank 하나: 가중치 RAM + mac_row + mantissa 추출 + MAC_REG           RTL
                  L0  ram_sdp    가중치 image (2 x BRAM36 폭, 8 깊이)                               RTL
                  L1  mac_row    (위와 같은 모듈, LANES = 16)
            L1  gemv_scale       (위와 같은 모듈) bank 결과를 순서대로 1개/cycle 처리                 RTL
            L0  ram_sdp          y buffer                                                            RTL

L3  attn_top         attention IP. CSR + HP master + attn_core + KV source                            RTL
      L3  attn_csr
      L2  attn_core        head 하나의 score, softmax, V 가중합 (q/K/V 폭 8/12/16, 16b container)   RTL
            L1  attn_ctrl        pass FSM(P1 score, P2 exp, DIV, P3 V), head 반복                    RTL
            L1  attn_score       dotp(12x12, KL lane) + c = qm*km + 곱 + rshr_sat, running max       RTL
            L1  exp_unit         d = s - max, w = rshr(d*log2e, 15), lut_lerp(EXP2N)                RTL (HLS 비교 후보)
                  L0  lut_lerp   257항목 표 + 선형 보간 (EXP2N | SIGM)                              RTL
            L0  udiv_seq         순차 나눗셈 (R = 2^48 / sum)                                       RTL
            L1  attn_vacc        pn = p*R 정규화, w = rshr(pn*vm, ...), V MAC(VL lane), 출력 shift   RTL
            L0  ram_sdp          p buffer (T_MAX x 32)                                              RTL
      L2  kv_store         (sys_p) 260K KV cache: kv head마다 216b x 2560 SDP RAM, 쓰기 + pass read  RTL
      L2  kv_rd            (sys_a) DDR KV reader: axi_rd_eng 위에서 K/V/scale 레코드를 pass 스트림으로 RTL

L3  vec_top          벡터 IP. CSR + HP master + vec_core                                              RTL
      L2  vec_core         op 선택(RMSNORM, SWIGLU, ACTQ, ARGMAX), actq_core 하나 공유               RTL
            L1  rms_front        amax, k, sum(xs^2), rsqrt_nr, y = xs*g*rm 계산                      RTL
                  L0  rsqrt_nr   48항목 seed + Newton 2회 (순차)                                    RTL
            L1  swi_front        sigmoid(lut_lerp SIGM), silu, g = silu*h3                            RTL
            L1  actq_core        int32 벡터 저장 + amax + (M, R) 계산(udiv_seq) + 양자화 lane         RTL
                  L0  udiv_seq, rshr_sat, ram_sdp
            L0  argmax_red
```

- HLS(Catapult) 병행은 선택 사항이다. 후보는 `exp_unit`과 `gemv_core`의 데이터패스(같은 포트, 같은 벡터). v1에서는 하지 않는 것을 권고한다(`arch.md` 열린 결정 D13).
- `embed`, `rope`, `add`는 v1에서 ARM에 남긴다(`spec/measure.md` 7절). PIM형에서 embedding 행 읽기는 `pim_core`의 `RDROW` 명령으로 선택 지원한다.
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
| S4-6 | `exp_unit`, `attn_score`, `attn_vacc`, `attn_ctrl`, `attn_core` | L1, L2 | RTL | stage 덤프(A3) + K_ATTN2 레코드(T = 1..512 분포, kb/vb = 12/8 기본, 8/8과 16/16 추가), KV stream random stall | p와 o 모두 mismatch 0 |
| S4-6 | `kv_store`, `kv_rd`, `attn_csr`, `attn_top` | L2, L3 | RTL | K_ACTQ(K/V) 출력으로 쓰기, K_ATTN2 레코드로 읽기. AXI BFM | mismatch 0 |
| S4-7 | `rsqrt_nr`, `lut_lerp`(SIGM) | L0 | RTL | rsqrt: `make test`의 248,002 입력 + random, golden `k_rsqrt`. SIGM: a 전수 [-2^20, 2^20] + 포화 구간 random, golden `k_sigmoid` | mismatch 0 |
| S4-7 | `actq_core` | L1 | RTL | K_ACTQ 레코드 전부(qmax 127, 2047) + DPI random(amax 0, 1, 2^31-1 포함) | mismatch 0 |
| S4-7 | `rms_front`, `swi_front`, `vec_core`, `vec_top` | L1~L3 | RTL | K_RMSNORM, K_SWIGLU, K_ACTQ, K_ARGMAX 레코드 + stage 덤프(A4, A5) | mismatch 0 |
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
| `udiv_seq` | `NUM_W`, `DEN_W`, `Q_W` | `start_i`, `num_i[NUM_W]`, `den_i[DEN_W]` (den > 0, 몫 < 2^Q_W 전제) | `q_o[Q_W]`, `done_o`(1 cycle pulse), `busy_o` | `CYCLES = Q_W + 2` | C `/` (`aq_setup`의 M, R; attention의 `2^48 / sum`) |
| `lut_lerp` | `FUNC`(EXP2N, SIGM), `PIPE` | EXP2N: `u_i[32]`(Q16 지수, >= 0). SIGM: `a_i[32]` signed Q16. `valid_i` | `y_o[17]` Q16 unsigned, `valid_o` | `PIPE` (1..3, 표 read가 동기라 1 이상) | `k_exp2neg(u, 8, lut)`, `k_sigmoid(a, 8, lut)`. 표는 `tabs.c`에서 생성한 SV package |
| `rsqrt_nr` | - | `start_i`, `u_i[42]` | `rm_o[32]`, `re_o[E_W]`, `done_o` | `CYCLES` 고정 (곱셈기 1개 순차, 약 12~20 [추정]) | `k_rsqrt` |
| `argmax_red` | `IDX_W` | `v_i[32]` signed, `valid_i`, `first_i`, `last_i` | `idx_o[IDX_W]`, `done_o` | 1 | `k_argmax` (같은 값이면 앞 index: 엄격한 `>`만 갱신) |
| `sync_fifo` | `W`, `DEPTH` | `in_valid_i`, `in_data_i`, `out_ready_i` | `in_ready_o`, `out_valid_o`, `out_data_o`, `level_o` | - | (control) |
| `ram_sdp` | `W`, `DEPTH`, `RD_LAT`(1) | `we_i`, `waddr_i`, `wdata_i`, `re_i`, `raddr_i` | `rdata_o` (re일 때만 갱신) | `RD_LAT` | (memory) 추론형, FPGA/ASIC 교체 지점. 72비트 폭은 parity bit까지 데이터로 쓴다 |

### 3.3 L1

| 모듈 | parameter | 포트 요약 | latency | golden |
|---|---|---|---|---|
| `mac_row` | `LANES`, `AW`, `BW`, `ACC_W` | in: `valid_i`, `first_i`, `last_i`(행 첫/끝 beat), `a_i`, `b_i`. out: `acc_o[ACC_W]` signed, `acc_valid_o`(행 끝에서 1 cycle) | `LATENCY = dotp.LATENCY + 1` | 행의 int32 `acc` (A1). gemv: `ACC_W = 15 + clog2(N_MAX) = 25` [계산: 1024 x 127^2 < 2^24] |
| `gemv_scale` | `ACC_W`, `PIPE` | in: `acc_i[ACC_W]`, `wm_i[16]`, `xm_i[17]`, `sh_i[SH_W]`, `valid_i`. out: `y_o[32]`, `valid_o` | 고정 `LATENCY` (곱 2단 + shift) | `k_gemv`의 `y = sat32(rshr(acc*m*xm, sh))` (A2). `S = acc*m`은 41비트, `S*xm`은 58비트 [계산] |
| `actq_core` | `N_MAX`, `IN_W` = 32 | cfg: `n_i`, `f_i[E_W]`, `qmax_i[16]`(127, 2047, 32767), `start_i`. in stream: `v_valid_i/v_ready_o`, `v_i[32]`. out stream: `q_valid_o/q_ready_i`, `q_o[16]`(int8은 sign-extend). scale: `m_o[17]`, `e_o[E_W]`, `done_o` | 가변(2n + 약 90 cycle) | K_ACTQ 레코드. MANT만 지원(POW2는 ERR) |
| `exp_unit` | `PIPE` | in: `s_i[32]`, `mx_i[32]`, `valid_i`. out: `e_o[17]`, `valid_o` | 고정 | `attn_core`의 d clamp, `w = rshr(d * 47274, 15)`, `k_exp2neg` (A3) |
| `attn_score` | `KL`, `HS_MAX` | in: K beat(`KL x 16b`), `last`, `km`, `ke`; cfg `q`(레지스터), `qm`, `qe`, `d0`. out: score `s_o[32]`, `s_valid_o`, running `mx_o` | 고정 | A3의 score |
| `attn_vacc` | `VL`, `HS_MAX`, `T_MAX`, `ACC_W` | in: `e_i`(p buffer), `R_i[33]`, V beat, `vm`, `ve`, `emin`, `G`. out: `p_o[32]`(정규화 확률 스트림), 끝에 `o_o`(hs x 32) | 고정 + hs/VL | K_ATTN2의 p와 o. V 누산 `ACC_W = 35 + 16 + clog2(T_MAX) = 60` [계산, vb = 16까지] |
| `axi_rd_eng` | `DW` = 64, `AW` = 32, `MAX_BURST` = 16, `OUTS` = 4 | cmd: `cmd_valid_i/ready_o`, `addr_i`, `bytes_i`. data: `d_valid_o/ready_i`, `d_o[64]`, `d_last_o`. AXI AR/R | - | 없음(프로토콜). AXI3 호환 burst(LEN <= 15), ID 0, in-order |
| `axi_wr_eng` | 같음 | cmd + data in stream. AXI AW/W/B. `done_o`(모든 B 응답 수신) | - | 없음 |
| `pim_bank` | `LB` = 16, `DEPTH` = 4096 | 가중치 쓰기(`we`, `waddr`, `wdata[144]`), lock-step 입력(`addr`, `gb_word[128]`, `first`, `last`, `en`), 출력 `acc_o`, `wm_o`, `acc_valid_o` (MAC_REG, double buffer) | `mac_row.LATENCY + RD_LAT` | `bank_gemv` BANK_ROW의 bank 하나 |
| `pim_gb` | `N_MAX` | 쓰기 스트림(64b), read `word_o[128]` | 1 | `bank_gemv`의 `gbuf` |
| `pim_ctrl` | `NB`, `LB` | 명령 스트림 in, bank 주소/enable, gather 순서, 상태 | - | `bank_stat_t`(명령 수), 4절 A6 |
| `rms_front` | `N_MAX` | x stream + g stream in, cfg(`ge`, `epsc`, `fy`) -> y stream out(32b) to `actq_core` | 가변(3n + rsqrt) | A4 (k, u, rm, re, y) |
| `swi_front` | - | h1, h3 stream in -> g stream out(32b) | 고정 | A5 (g) |

### 3.4 L2 (kernel core)

| 모듈 | 주요 parameter | 입력 | 출력 | cycle 식 [계산] | golden 레코드 |
|---|---|---|---|---|---|
| `gemv_core` | `LANES` = 8, `N_MAX` | cfg: `rows`, `n`, `we`, `xm`, `xe`, `fo`, `start`. x stream(`ceil(n/8)` beat), 행 레코드 stream(header beat + `ceil(n/8)` beat) | y stream(32b), `done` | `ceil(n/8) + rows x (1 + ceil(n/8)) + L_pipe` (입력이 매 cycle 올 때) | K_GEMV (gs = n) |
| `pim_core` | `NB` = 4, `LB` = 16, `DEPTH` = 4096 | 명령 stream(LDW, WRGB, MACAB, RDROW), 데이터 stream(64b) | y stream(32b), 상태 | MACAB: `ceil(rows/NB) x ceil(n/16) + L_pipe + NB` | K_GEMV + `bank_gemv` |
| `attn_core` | `KL` = 8, `VL` = 8, `HS_MAX`, `T_MAX` | cfg(`T`, `hs`, `kb`, `vb`, `qm`, `qe`), q(hs x 16b), KV pass stream(K beat + ks + vs / V beat + vs) | p stream(T x 32b), o(hs x 32b), `done` | `T x ceil(hs/KL) + T + T x ceil(hs/VL) + C_div + L_pipe` (KV가 매 cycle 올 때) | K_ATTN2 |
| `kv_store` | `NKV`, `L`, `SEQ`, `HS` | 쓰기(layer, kv head, pos, K/V 행, scale), pass read 요청 | KV pass stream | 1 위치/cycle | `fwd_h.c`의 `kc/vc/kcs/vcs` slot 배치 |
| `kv_rd` | - | pass 요청 + DDR 주소 | KV pass stream | DDR beat 수에 묶임(`arch.md` 4.4) | 같음 |
| `vec_core` | `N_MAX` | op + cfg, 입력 stream(들) | q stream + scale, 또는 idx | RMSNORM `4n + C`, SWIGLU `2n + C`, ACTQ `2n + C`, ARGMAX `n` | K_RMSNORM, K_SWIGLU, K_ACTQ, K_ARGMAX |

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

## 4. golden에 경계가 없어 `model/`에 추가해야 하는 것

kernel 단위(K_GEMV, K_ACTQ, K_RMSNORM, K_ATTN2, K_SWIGLU, K_ARGMAX)는 기존 덤프 레코드로 검증할 수 있다. 아래는 leaf와 L1 단위의 경계가 없거나, kernel 덤프만으로는 부족한 것이다. 원칙: **kern.c의 kernel 함수가 스스로 호출하는 stage 함수로 쪼개서 export한다**(별도 재구현 금지). 바꾼 뒤 `make test` PASS와 기존 덤프 `cmp` 동일로 golden이 변하지 않았음을 확인한다.

| ID | 대상 leaf/모듈 | 필요한 것 | 현재 상태 (2026-11-19 S4-1) |
|---|---|---|---|
| A1 | `dotp`, `mac_row` | 행별 int32 `acc`(scale 전). `k_gemv`를 `k_gemv_acc`(행 하나의 그룹 합) + `k_gemv_out`으로 분리 | **완료**. `k_dot8`(그룹 합), `k_gemv_row`(행의 S), `k_gemv_st`(행별 S trace). `k_gemv`가 이 함수들로 계산 |
| A2 | `gemv_scale` | `(acc, wm, xm, sh) -> y` | **완료**. `k_gemv_out(S, xm, sh)`, S = acc x wm (gs = n). DPI `kd_gemv_out` |
| A3 | `attn_score`, `exp_unit`, `attn_vacc` | score 배열(softmax 전), `mx`, 분자 배열, `sum`, `R`, `emin`, `mmax`, `G`, 위치별 `w` | **완료**. `k_attn2_st`(`k_attn_st_t`: dot, s, e, w, acc 배열과 d0, mx, sum, R, emin, mmax, G). DPI 노출은 S4-6에서 |
| A4 | `rms_front`, `rsqrt_nr` 연결 | `k`, `ss`, `u`, `rm`, `re`, `sh`, 양자화 전 y 배열, `ymax` | **완료**. `k_rmsnorm_st`(`k_rms_st_t`). DPI 노출은 S4-7에서 |
| A5 | `swi_front` | 양자화 전 `g` 배열과 `amax` | **완료**. `k_swiglu_st`(`k_swi_st_t`). DPI 노출은 S4-7에서 |
| A6 | `pim_core` bank image | bank RAM의 144비트 word image 생성기(가중치 + parity bit의 행 가수, `arch.md` 3.3)와 그 image로 `bank_gemv`를 돌려 `k_gemv`와 같음을 보이는 시험 | **완료**. `bimg_pack`/`bimg_unpack`(`src/bank.c`), `vt` job bimg -> `build/vec/pim/bank0..3.hex`(word = tag 16 + lane 128, 4,072/4,096 word). `make test` `m1 PIM bank image`, DPI `kd_rec_bimg` |
| A7 | `actq_core` 내부(선택) | `aq_setup`(amax, mode, qmax -> M, R, e)과 `aq_one` export | **완료**. `k_aq_setup`, `k_aq_one`(`k_aq_t`), `k_actq_st`. DPI 노출은 S4-7에서 |
| A8 | leaf 벡터 생성 | `rshr_sat`, `udiv_seq`, `lut_lerp`, `rsqrt_nr`용 random/전수 벡터. DPI-C로 kern.c를 TB에 직접 링크하는 방식을 권고(파일 없이 random 생성) | **S4-2 분 완료**: DPI-C(`tb/dpi/kdpi.c`)로 `kd_rshr`, `kd_sat32`, `kd_dot8`, `kd_gemv_out`, `kd_exp2neg`, `kd_sigmoid`, `kd_rsqrt`. `udiv_seq`는 C `/` 그대로라 DPI 함수 미작성(S4-6) |
| A9 | 덤프 설정 | K12V8 덤프(260K `d3`, 15M `d4`). 위치 필터(예: 0..7, 63, 127, 255, 511)로 attention의 긴 T를 포함하되 파일 크기 제한 | **완료**. `cfg/d3.cfg`(260K 위치 0..7, 63, 127, 255, 511, 2,388 레코드), `cfg/d4.cfg`(15M 위치 0..3, 127, 255, 1,428 레코드), 키 `pos`, `noeos` |
| A10 | 범위 집계 | 덤프 전체의 지수(`we`, `e`), shift, `T`, `n`의 최소/최대 표 -> `E_W`, `SH_W` 확정 | **집계 완료**(`model/results/range_k12v8.txt`). 지수 0..33(signed 7비트), shift -1..40(signed 7비트). 확정은 오케스트레이터(3.1 표의 비고) |
| A11 | 덤프 -> TB 변환 | kernel 레코드를 TB가 읽는 형식(kernel별 파일 + manifest)으로 나누는 도구. 인자 대신 환경변수 설정(`process-privacy.md`) | **완료**. `vt` job split -> `build/vec/m1`, `m2/<kernel>.bin` + `manifest.txt`(같은 레코드 형식, DPI `kd_rec_*`로 읽음). 행 레코드 `rrec.bin`(`vt` job rrec) |
