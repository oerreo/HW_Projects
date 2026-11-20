# 벡터 IP: `vec_top` (S4-7)

상태: RTL 시뮬레이션 통과(2026-11-20, `sim/tests/rsqrt_nr.cfg`, `lut_lerp.cfg`, `actq_core.cfg`, `rms_front.cfg`, `swi_front.cfg`, `vec_core.cfg`, `vec_csr.cfg`, `vec_top.cfg`), FPGA 미구성(G5 전). 구조 결정은 `arch.md` 5절(actq_core 공유, MANT만, rsqrt seed + Newton 2회)과 12절 D10(op 4개를 IP 하나로), 공통 레지스터 틀은 `arch.md` 7.2, engine 규칙은 `hierarchy.md` 3.6이 원본이다. 이 문서는 데이터 배치, 레지스터 맵, 실행 규칙, 내부 구성, cycle 식, 검증 내용을 확정한다.

- RTL: `rtl/l0/rsqrt_nr.sv`, `rtl/l0/lut_lerp.sv`(FUNC 1 SIGM 추가, EXP2N 부분은 동작 불변), `rtl/pkg/lut_pkg.sv`(SIGM_TAB, RSQ_TAB 추가, `model/tools/lutsv.py`로 `tabs.c`에서 생성), `rtl/l1/actq_core.sv`, `rtl/l1/rms_front.sv`, `rtl/l1/swi_front.sv`, `rtl/l2/vec_core.sv`, `rtl/l3/vec_csr.sv`, `rtl/l3/vec_top.sv`. 재사용(수정 없음): `rshr_sat`, `udiv_seq`, `ram_sdp`, `sync_fifo`, `argmax_red`, `axil_slave`, `axi_rd_eng`, `axi_wr_eng`.
- golden: `model/src/kern.c`의 `k_rmsnorm_st`, `k_swiglu_st`, `k_actq_st`, `k_aq_setup`/`k_aq_one`, `k_argmax`, `k_rsqrt`, `k_sigmoid`(model/src 변경 없음). TB 쪽 DPI는 `tb/dpi/kdpi.c`의 `kd_vec_*`, `kd_aq_*`, `kd_sig_lut8`, `kd_rsq_lut`(연산은 모두 `kern.c`), 호출 하나의 SV 표현은 `tb/common/vec_tb_pkg.sv`.
- 표기: cycle 수는 Questa 시뮬레이션(`axi_mem_slave` 모델, stall 없음, read/B latency 1)의 값이며 보드 값이 아니다. 자원은 [계산](구조에서 센 값, 합성 안 함).

## 1. 연산

| op | golden | 입력 | 출력 |
|---|---|---|---|
| 1 RMSNORM | `k_rmsnorm(x, n, fx, g, ge, epsc, fy, MANT)` | x int32 [n], g int16 [n] | q int8 [n], scale {m, e} |
| 2 SWIGLU | `k_swiglu(h1, h3, n, 8, k_sig_lut(8), MANT)` | h1 int32 [n], h3 int32 [n] | q int8 [n], scale |
| 3 ACTQ | `k_actq(v, n, f, MANT, qmax)`, qmax 127 / 2047 / 32767 | v int32 [n] | q int8 (qmax 127) 또는 int16 [n], scale |
| 4 ARGMAX | `k_argmax(v, n)` | v int32 [n] | idx int32 (메모리), ARGMAX_IDX / ARGMAX_VAL 레지스터 |

단계별 계산(모두 golden 식 그대로, 폭은 모두 넘침 없음을 확인한 값):

| 모듈 | 계산 | 폭 |
|---|---|---|
| `actq_core` | amax = max \|v\|(\|-2^31\| = 2^31), amax = 0이면 q = 0, {0, 0}. 아니면 L = bitlen(amax), e = 16 + bitlen(qmax) - L, num = rshr(amax, -e), M = (num + qmax/2) / qmax, R = (2^40 + M/2) / M, q = clamp(rshr(v R, 40 - e), qmax), scale {M, e + f} | num <= 2^31(33비트 signed), M in (2^15, 2^17), R < 2^25, v R 57비트, shift 10..49. `udiv_seq`(41/17/25) 하나를 두 번 |
| `rms_front` | k = max(bitlen(amax) - 15, 0), xs = clamp(rshr(x, k), 32767), ss = sum xs^2, u = ss + rshr(epsc, 2k), (rm, re) = k_rsqrt(u), sh = ge + re - fy, y = sat32(rshr(xs g rm, sh)) | ss < N_MAX 2^30(40비트), u 41비트, xs g 31비트, xs g rm 48비트 |
| `rsqrt_nr` | 정규화 mn in [2^30, 2^32), seed `k_rsq_lut`, Newton 2회 | y < 2^17(아래), z 34, mn (z >> 2) 64, 3 2^32 - p 34, y (3 2^32 - p) 51비트 |
| `swi_front` | s = k_sigmoid(h1)(lut_lerp SIGM), silu = rshr(h1 s, 16), g = sat32(rshr(silu h3, 16)) | h1 s 50비트, silu는 int32 안(2^31 - 1, -2^31이 극값), silu h3 64비트(최대 2^62)를 62비트로 clamp한 뒤 rshr_sat(clamp된 값은 \|rshr\| >= 2^45라 같은 sat32 값) |
| `lut_lerp` SIGM | ua = \|a\|, ua >= 2^20이면 T[256], 아니면 T[idx] + (((T[idx+1] - T[idx]) fr + 2048) >> 12), a < 0이면 65536 - s | (B - A) <= 1024, 곱 < 2^22 |

- `rsqrt_nr`의 y 폭: seed <= 64535 < 2^16, Newton 한 단계는 y' <= 2^31/sqrt(mn) + 1 <= 2^16 + 1(y(3 - a y^2)/2의 최대가 1/sqrt(a), 절삭으로 p가 최대 17 작아져 y'가 1 미만 커짐). RTL은 17비트 레지스터이고 시뮬레이션 검사 `L0_RANGE`로 매 단계 확인한다. 최종 rm은 전수 확인했다: mn in [2^30, 2^32) 전체 3 x 2^30개에서 rm 최소 32,767, 최대 65,535(`tb/rsqrt_nr/bound.c`, PC 실행 [측정]). 출력은 16비트에도 들어가지만 RTL은 중간값의 해석적 상한(2^16 + 1)에 맞춰 17비트로 두었다.
- actq_core 공유: rmsnorm과 swiglu의 양자화는 `actq_core`에 front의 y/g 스트림을 넣고 f = fy, f = K_FX = 16, qmax = 127로 한다. `arch.md` 5.1의 "코드 대조로 확인, 실행 안 함" 판단은 S4-7 TB(`rms_front`, `swi_front`, `vec_core`, `vec_top`)에서 두 모델의 K_RMSNORM, K_SWIGLU 레코드 전부의 q와 scale이 golden과 일치하는 것으로 **실행 확인**했다.

## 2. 데이터 배치 (DDR, little-endian, golden 버퍼 그대로)

| 버퍼 | 주소 | 형식 |
|---|---|---|
| x / h1 / v | `IN0_ADDR` | int32 [N] |
| g (RMSNORM) | `IN1_ADDR` | int16 [N] |
| h3 (SWIGLU) | `IN1_ADDR` | int32 [N] |
| q | `OUT_ADDR` | int8 [N](ACTQ qmax 2047/32767이면 int16 [N]). 마지막 beat의 N 밖 byte는 쓰지 않는다(WSTRB) |
| scale | `SCL_ADDR` | {int32 m, int32 e}(8 B) |
| idx (ARGMAX) | `OUT_ADDR` | int32 1개(4 B, 뒤 4 B는 쓰지 않는다) |

모든 주소는 8 B 정렬(`axi_wr_eng`/`axi_rd_eng`의 규칙, MISALIGN). 길이는 8의 배수가 아니어도 된다.

## 3. 레지스터 맵 (32비트, offset은 byte)

| offset | 이름 | 접근 | reset | 내용 |
|---|---|---|---|---|
| 0x00 | ID | R | 0x56450001 | [31:16] 0x5645("VE"), [15:0] 버전 1 |
| 0x04 | CONFIG | R | | [7:0] FCLK_MHZ, [15:8] IDX_W, [31:16] N_MAX |
| 0x08 | CTRL | W | | bit0 start, [7:4] op(1 RMSNORM, 2 SWIGLU, 3 ACTQ, 4 ARGMAX). 읽으면 0 |
| 0x0C | STATUS | R | 0 | bit0 busy(검사 중 또는 op 중), bit1 done_sticky, bit2 err_any |
| 0x10 | ERR | R/W1C | 0 | bit0 START_BUSY, bit1 BAD_OP, bit2 BAD_DESC, bit3 MISALIGN, bit4 RD_RESP, bit5 WR_RESP |
| 0x14 | CYCLES | R | 0 | 마지막으로 수락된 호출의 cycle 수(e - s, 검사 1 cycle 포함. 검사에서 거절되면 1) |
| 0x18 | RD_STALL | R | 0 | 같은 구간에서 `axi_rd_eng.stall_o`(core가 read 데이터를 기다림)인 cycle 수 |
| 0x1C | WR_STALL | R | 0 | 같은 구간에서 packer의 beat를 `axi_wr_eng`가 받지 못한 cycle 수 |
| 0x20 | OPS | R | 0 | reset 이후 끝난 op 수, 2^32 wrap |
| 0x24 | ARGMAX_IDX | R | 0 | [IDX_W-1:0] 마지막 ARGMAX 호출의 index |
| 0x28 | ARGMAX_VAL | R | 0 | 그 최댓값(int32) |
| 0x40 | IN0_ADDR | RW | 0 | 2절 |
| 0x44 | IN1_ADDR | RW | 0 | RMSNORM g, SWIGLU h3 |
| 0x48 | OUT_ADDR | RW | 0 | q 또는 idx |
| 0x4C | SCL_ADDR | RW | 0 | scale(ARGMAX는 사용 안 함) |
| 0x50 | N | RW | 0 | 32비트 그대로 저장(aliasing 없음). 유효 1..N_MAX, ARGMAX 1..2^IDX_W |
| 0x54 | FMT | RW | 0x0801007F | [15:0] qmax(ACTQ), [16] mode(1 = MANT), [27:24] sb(SWIGLU LUT 비트 수, 8만) |
| 0x58 | EXP | RW | 0 | [7:0] f(signed, ACTQ의 f, RMSNORM의 fy), [15:8] ge(signed, RMSNORM) |
| 0x5C | EPSC | RW | 0 | RMSNORM epsc(int32, >= 0) |

- 정의되지 않은 주소는 0을 읽고 쓰기는 무시한다. 주소 bit[1:0]과 WSTRB는 무시한다. 응답은 항상 OKAY(`axil_slave`). 같은 cycle의 읽기는 쓰기 전 값을 본다(`attn.md`, `gemv_acc.md`와 같은 규칙). descriptor 레지스터는 필드 비트만 저장한다.
- golden의 `fx`(K_RMSNORM prm)는 golden이 쓰지 않으므로(`epsc`에 접힘) 레지스터가 없다. SWIGLU의 출력 지수 오프셋은 K_FX = 16 고정이다. mode POW2와 sb != 8은 BAD_DESC다(K12V8 형식, MANT만).

## 4. 실행 규칙

### 4.1 CTRL (쓰기가 수행되는 cycle s, idle = 검사 중도 op 중도 아니거나 op가 끝나는 cycle e)
descriptor 검사는 곱셈이 없다(바이트 수 4N, 2N, N qb는 shift). 그래서 검사는 1 cycle이고 판정 cycle은 **v = s + 1**(CHK_CYC = 1)이다.

| 조건 | 결과 |
|---|---|
| idle, start, op 1..4 | 수락(cycle s). descriptor를 latch(s + 1부터 유효, 이후의 레지스터 쓰기는 이 호출에 영향 없음), done_sticky clear, CYCLES/RD_STALL/WR_STALL = 0, STATUS.busy = 1(s + 1부터). 검사는 s + 1 |
| (수락된 호출의 v) descriptor 정상 | 시작(`start_o`, cycle v). op는 v + 1부터 |
| (수락된 호출의 v) descriptor 오류 | 시작 안 함. BAD_DESC 그리고/또는 MISALIGN(독립, v + 1부터 보임), STATUS.busy = 0(v + 1부터). done 없음, OPS 불변, CYCLES = 1 |
| idle, start, op가 1..4가 아님 | BAD_OP만(cycle s). done_sticky 불변 |
| idle, start = 0 | done_sticky clear만 |
| busy(검사 중 또는 op 중, e가 아님. 판정 cycle v 포함), start = 1 | START_BUSY(op가 틀리면 BAD_OP도). 무시 |

- done_sticky는 e에 set(e + 1부터 보임), 같은 cycle의 clear가 이긴다. ERR는 W1C, 같은 bit의 set이 clear를 이긴다. RD_RESP/WR_RESP는 RRESP[1]/BRESP[1]인 handshake마다 set되고 데이터는 그대로 쓰인다(op는 끝까지 간다).
- ARGMAX_IDX/VAL은 ARGMAX 호출의 e에 갱신된다(e + 1부터 보임).

### 4.2 descriptor 검사 (`vec_csr`, latch한 값으로, TB의 독립 모델과 매 cycle 대조)
- 모든 op: 1 <= N <= N_MAX(ARGMAX는 N <= 2^IDX_W), `IN0_ADDR + 4N`, `OUT_ADDR + (ARGMAX 4, ACTQ qmax != 127이면 2N, 그 밖은 N)`이 2^32 이하.
- RMSNORM, SWIGLU, ACTQ: mode = 1, `SCL_ADDR + 8` <= 2^32. ACTQ: qmax in {127, 2047, 32767}. SWIGLU: sb = 8. RMSNORM: EPSC >= 0.
- RMSNORM: `IN1_ADDR + 2N`, SWIGLU: `IN1_ADDR + 4N` <= 2^32.
- MISALIGN: IN0_ADDR, OUT_ADDR, (RMSNORM, SWIGLU) IN1_ADDR, (ARGMAX 외) SCL_ADDR의 [2:0] != 0. 쓰지 않는 주소와 필드(ACTQ의 IN1, ARGMAX의 SCL, RMSNORM의 qmax 등)는 검사하지 않는다.
- 이 검사로 engine이 거절할 명령(정렬, 길이 0, 2^32 넘김)은 생기지 않는다(시뮬레이션 검사 `L3_ENGCMD`).

### 4.3 op 종료 e
vec_core의 done(ops 1..3은 `actq_core` done, ARGMAX는 `argmax_red` done)을 본 뒤, packer가 마지막 beat(scale 또는 idx)를 write engine에 넘겼고, write 명령이 모두 나갔고, `axi_wr_eng`가 마지막 B를 받은 첫 cycle. CYCLES = e - s.

### 4.4 PS 호출 순서
1. 입력 버퍼를 golden 형식으로 쓰고 flush. 2. `IN0_ADDR`, (`IN1_ADDR`), `OUT_ADDR`, (`SCL_ADDR`), `N`, `FMT`, `EXP`, (`EPSC`) 중 바뀐 것을 쓴다(진행 중인 호출 중에 써도 된다). 3. `CTRL = op << 4 | 1`. 4. STATUS polling: busy = 0이 될 때까지(검사 1 cycle 포함), 그 뒤 done_sticky = 1이면 정상, 아니면 ERR. 5. `ERR`, `CYCLES`, (ARGMAX) `ARGMAX_IDX`. 6. q, scale을 invalidate.

## 5. 구성

```
s_axi -> axil_slave -> vec_csr (registers, 1-cycle descriptor check, start/done, latched descriptor)
start (v): read sequencer: IN0 (4N B), then IN1 (RMSNORM 2N B, SWIGLU 4N B) -> axi_rd_eng
           write sequencer: OUT (N qb B; ARGMAX 4 B), then SCL (8 B)          -> axi_wr_eng
axi_rd_eng --64-bit beats--> vec_core:
    unpacker (int32: 2 lanes/beat, int16: 4 lanes/beat, sign-extended; the rest of a command's last
              beat ignored) --element stream (1/cycle)--> rms_front | swi_front | actq_core | argmax_red
    shared front buffer ram_sdp N_MAX x 32 (rms_front: x; swi_front: silu), port selected by op
    rms_front --y--> actq_core <--g-- swi_front;  ACTQ: elements --> actq_core
    actq_core: buffer ram_sdp N_MAX x 32, udiv_seq, rshr_sat, q FIFO (sync_fifo Q_DEPTH x 16)
vec_core --q stream--> packer (int8 8 / int16 4 per beat, last beat partial; then {e, m}; ARGMAX {0, idx})
       --> axi_wr_eng
```

- 모듈 경계(새로 고정한 것):

| 모듈 | parameter | 포트 요약 | latency / cycle |
|---|---|---|---|
| `rsqrt_nr` | `U_W`(1..62, 기본 42; vec는 rms_front의 U_W = 41) | `start_i`, `u_i[U_W]`, `rm_o[17]`, `re_o[E_W]` signed, `done_o`, `busy_o` | `CYCLES = 15`(start c, done c + 15, busy c+1..c+14, udiv_seq와 같은 handshake) |
| `lut_lerp` | `FUNC` 0 EXP2N / 1 SIGM(2 이상 elaboration 실패), `PIPE` 1..3 | SIGM은 같은 `u_i[32]` 포트를 signed a로 읽는다 | `PIPE` |
| `actq_core` | `N_MAX`, `Q_DEPTH`(>= 5) | cfg `n_i`, `f_i[E_W]`, `qmax_i[16]`, `start_i`; in `v_valid_i/v_ready_o/v_i[32]`(LOAD 동안 항상 ready); out `q_valid_o/q_ready_i/q_o[16]`; `m_o[17]`, `e_o[SH_W]`(e + f, amax 0이면 0), `scl_valid_o`, `busy_o`, `done_o` | 입력 마지막 원소 cycle t에서 done = t + n + 59(amax != 0) / t + n + 6, q_ready = 1일 때 |
| `rms_front` | `N_MAX` | cfg `n_i`, `ge_i`, `epsc_i`, `fy_i`; 원소 스트림(x n개 다음 g n개, P1과 P4에서만 ready); buffer 포트(we/waddr/wdata/re/raddr/rdata, read latency 1); y 스트림(valid만) | 마지막 y = start + 3n + 28 |
| `swi_front` | `N_MAX`, `LUT_PIPE` | `n_i`; 원소 스트림(h1 n개 다음 h3 n개); buffer 포트; g 스트림(valid만) | 마지막 g = start + 2n + 8(LUT_PIPE 2) |
| `vec_core` | `N_MAX`, `IDX_W`, `LUT_PIPE`, `Q_DEPTH` | `start_i`, `op_i[2]`(0 RMS, 1 SWI, 2 ACTQ, 3 ARGMAX), `n_i[IDX_W+1]`, `f_i`, `qmax_i`, `ge_i`, `epsc_i`; beat 입력 `d_valid/d_ready/d_data[64]/d_last`; q 스트림; `m_o`, `e_o`, `scl_valid_o`, `am_idx_o`, `am_max_o`, `busy_o`, `done_o` | 6.1절 |
| `vec_csr` | `ADDR_W`, `N_MAX`, `IDX_W`, `FCLK_MHZ` | strobe 인터페이스, `start_o`, `busy_o`, `done_i`, latch된 descriptor, ARGMAX 결과 입력, 사건 4개 | CHK_CYC = 1 |
| `vec_top` | `N_MAX`, `IDX_W`, `LUT_PIPE`, `Q_DEPTH`, `MAX_BURST`, `OUTS`, `RD_FIFO`, `WR_FIFO`, `IDW`, `FCLK_MHZ`, `ADDR_W` | AXI-Lite slave, AXI4 read master 1, write master 1 | 6.2절 |

- backpressure: 원소 스트림은 valid/ready(rms_front는 P2/P3 동안 받지 않아 g beat는 read engine FIFO에서 기다린다). front의 y/g 출력과 actq 입력은 backpressure가 없다(actq_core가 LOAD에서 매 cycle 받는다). q 쪽은 actq_core의 q FIFO credit(FIFO level + 읽는 중 원소 < Q_DEPTH일 때만 buffer를 읽음)으로 처리하고, packer는 write engine의 `in_ready`로 멈춘다.
- 하위 모듈은 수정 없이 인스턴스만 했다(`lut_lerp`는 SIGM 기능을 추가했고 EXP2N은 회귀로 불변 확인).

## 6. cycle 식 [측정, Questa]

### 6.1 `vec_core` (start 수락 cycle 0, `done_o` cycle C, beat가 매 cycle 오고 q_ready = 1)
| op | C | 0 출력(양자화 전 최대 \|.\| = 0) |
|---|---|---|
| RMSNORM | **4n + 87** | 4n + 34 |
| SWIGLU | **3n + 67** | 3n + 14 |
| ACTQ | **2n + 59** | 2n + 6 |
| ARGMAX | **n + 1** | - |

- 항: 원소 1개/cycle이 기준이다. RMSNORM = P1 n + P2 n + (P2 drain 4, u 2, rsqrt 15, sh 1) + P4 n + y 지연 5 + actq(SETUP 55 + QUANT n + 4). SWIGLU = A n + (silu 지연 4, AW 1) + B n + g 지연 3 + actq. actq: 마지막 입력 원소 t에서 SET0 t+1, SET1 t+2(나눗셈 1 시작), 나눗셈 26 cycle 두 번(두 번째는 첫째의 done cycle에 시작), QUANT 첫 read t + 55, 마지막 q handshake t + n + 58, done t + n + 59.
- `tb_actq_core`, `tb_rms_front`, `tb_swi_front`, `tb_vec_core`의 `CYC=1` run에서 모든 호출(레코드 전부 + 합성)이 식과 일치했다.
- `arch.md` 5절의 추정과 비교: ACTQ `2n + 2 x 27 + L` [추정] -> 측정 `2n + 59`(L = 5와 같음). RMSNORM 약 `4n + 130` [추정] -> `4n + 87`(43 적음: rsqrt가 15 cycle, 추정은 C_rsqrt 약 30~50). SWIGLU 약 `2n + 110` [추정] -> `3n + 67`: 추정은 h1과 h3를 동시에 받는다고 보았으나, HP 포트 하나의 read engine이 h1 명령 뒤에 h3 명령을 순서대로 받아 h1을 buffer(silu로)에 두는 단계(n)가 따로 든다. DDR 대역폭 기준으로도 h1과 h3를 합해 n beat가 들어 2n보다 짧게 할 수 없다(int32 2개/beat).

### 6.2 `vec_top` CYCLES (메모리 stall 없음, latency 1, MAX_BURST 16, OUTS 4)
s = CTRL 쓰기 cycle, D = s + 1 + C(6.1의 core 식, core는 s + 1에 시작). 
- ARGMAX: **CYCLES = C + 14 = n + 15**.
- RMSNORM, SWIGLU, ACTQ: q 값 i가 packer에 들어가는 cycle은 D - n + i이고, q beat j(P = 8 / qb 값)는 h_j = D - n + min(P j + P - 1, n - 1)에 완성된다. q 쓰기 명령은 OUT_ADDR에서 16 beat와 4 KiB 경계로 burst k(L_k beat)로 나뉘고, burst k의 W는 ws_k = max(h_(k의 마지막 beat) + 10, we_(k-1) + 1)부터 we_k = ws_k + L_k - 1까지다. scale beat의 W는 ws = max(D + 11, we_last + 1), 종료 e = ws + 2. **CYCLES = e - s**.
  - 앞 burst에 막히지 않는 보통의 경우 닫힌 식: **CYCLES = 1 + C + 11 + max(L_last, 2)**(L_last = q의 마지막 burst beat 수). 막히는 예: 마지막 q burst가 1~3 beat이고 바로 앞 16 beat burst의 W가 아직 나가는 중이면 +3..+13(측정 사례).
  - 이 모델은 `tb_vec_top`의 `top_cyc`가 호출마다 계산해 CYCLES와 비교한다(`CYC=1` run: 두 모델 forward 전 레코드와 합성 1,500 호출, 모두 일치).

### 6.3 token당 op별 합 [측정, `vec_top` forward 순서, `m1_fwd`/`m2_fwd` run]
두 모델의 덤프(K12V8, 260K 12 위치, 15M 6 위치)의 vec kernel 레코드 전부를 manifest 순서대로 `vec_top` 호출 하나씩으로 실행해 CYCLES를 위치별, op별로 더했다(stall 없는 메모리 모델, latency 1, 무작위 8 B 정렬 주소). 모든 호출에서 CYCLES == 6.2 모델.

| 모델 | op | token당 호출 | n | token당 CYCLES(위치 평균) |
|---|---|---|---|---|
| 260K | RMSNORM | 11 | 64 | 3,993 |
| 260K | SWIGLU | 5 | 172 | 3,005 |
| 260K | ACTQ | 85 | 8 (80), 64 (5) | 8,155 |
| 260K | ARGMAX | 1 | 512 | 527 |
| 260K | 합 | 102 | | **15,680** |
| 15M | RMSNORM | 13 | 288 | 16,321 |
| 15M | SWIGLU | 6 | 768 | 14,386 |
| 15M | ACTQ | 114 | 48 (108), 288 (6) | 23,019 |
| 15M | ARGMAX | 1 | 32,000 | 32,015 |
| 15M | 합 | 134 | | **85,741** |

- 위치마다 값이 몇 cycle 다른 것(15M RMSNORM 16,315..16,321)은 TB의 무작위 OUT 주소에 따라 q 쓰기 burst의 4 KiB 분할이 달라지는 6.2절의 쓰기 꼬리 차이다.
- head별 ACTQ(n 8 또는 48, q/K/V 양자화)가 호출 수의 대부분이다. 호출 하나가 2n + 59 + 13 이상(n 8에서 88 cycle)이라 나눗셈 두 번(52 cycle)이 지배한다. `arch.md` 5.1의 권고대로 head별 actq는 ARM에 두는 쪽이 유리할 수 있으나, ARM 호출 비용과 비교는 보드 측정(S6) 전이라 판단하지 않는다.
- 같은 model 값으로 비교하면 15M ARGMAX(32,015)는 `gemv_acc_top`의 분류기 융합 argmax(`gemv_acc.md` 2절)로 대신할 수 있다.

## 7. 시뮬레이션 검증 (2026-11-20)

| test | 내용 | run |
|---|---|---|
| `lut_lerp` | 기존 EXP2N 6 run(불변) + SIGM: 표 257항목 == `k_sig_lut(8)`, a 전수 [-2^20, 2^20](2,097,153 + index/fraction 경계 3,072 + int32 극값), \|a\| > 2^20 random 10^6, PIPE 1/2/3, FUNC 2 elaboration 실패 | 10 |
| `rsqrt_nr` | 표 48항목 == `k_rsq_lut`, 경계(0, 1, 2, 3, max, 모든 비트 길이의 2^k, 2^k - 1), seed index 경계 x 모든 짝수 정규화 shift, 비트 길이마다 4,000 random(make test 방식), random 10^6, handshake(busy 창, done 시점, 결과 유지, done cycle의 start), U_W 42/20/62, 부정 시험(busy 중 start, U_W 63) | 6 |
| `actq_core` | 두 모델 K_ACTQ 레코드 전부(1,704 호출), 합성(n 1..N_MAX, qmax 127/2047/32767, f random, amax 0, 1, 2^31 - 1, 2^31, 같은 크기, 포화), q, scale, stage(amax, L, e, num, M, R), cycle 식, 입력 gap, q_ready stall, 긴 q_ready 차단(q FIFO full과 credit 정지 도달 요구), done cycle의 start, N_MAX 64/Q_DEPTH 5, Q_DEPTH 4 elaboration 실패 | 8 |
| `rms_front` | + buffer + `actq_core`. 두 모델 K_RMSNORM 레코드 전부(210 호출), 합성(n 1..N_MAX, k 0..17, x 0/-2^31/2^31 - 1, g 극값, ge/epsc/fy random), stage(amax, k, ss, u, rm, re, sh), y, q, scale, actq M/R/e, cycle 식, 원소 gap, q 차단(FIFO full 요구), N_MAX 64 | 6 |
| `swi_front` | + buffer + `actq_core`. 두 모델 K_SWIGLU 레코드 전부(96 호출, LUT == `k_sig_lut(8)` 확인), 합성(sigmoid 포화, h1/h3 = -2^31, 2^31 - 1로 62비트 clamp 구간), buffer의 silu(white-box, `kd_sigmoid`/`kd_rshr`), g, q, scale, actq M/R/e, cycle 식, gap, 차단, N_MAX 64 | 6 |
| `vec_core` | TB가 read engine 역할. 네 kernel 레코드 전부(두 모델, op를 번갈아), 합성(ARGMAX n 65,536과 tie 포함), q, scale, argmax index와 값, op별 cycle 식, beat gap, q 차단(FIFO full 요구), done cycle의 start, N_MAX 64/IDX_W 8/Q_DEPTH 5, IDX_W 9 elaboration 실패 | 8 |
| `vec_csr` | 단독. spec 참조 모델과 매 cycle 대조(임의 주소 읽기 값, start_o, busy_o, latch된 출력, 내부 상태). 방향성: op마다 정상, BAD_DESC 이유 하나씩(첫 오류 값과 마지막 정상 값), 범위 끝이 정확히 2^32(수락)와 + 8(거절), 쓰지 않는 필드/주소(오류 없음), MISALIGN 각각, BAD_DESC + MISALIGN, BAD_OP, 판정 cycle과 op 중의 START_BUSY, done cycle의 CTRL(start 1/0), 판정 cycle의 descriptor 쓰기, W1C와 set 충돌. 이어서 random 3 x 10^5 ~ 2 x 10^6 cycle. N_MAX 64/IDX_W 8, N_MAX 1000/IDX_W 10, IDX_W 9 elaboration 실패. 요구에서 뺀 것: SCL 범위 단독(정렬된 SCL은 끝이 2^32를 넘을 수 없어 MISALIGN과 함께만 남) | 6 |
| `vec_top` | AXI-Lite BFM + memory model. 두 모델 forward 순서 전 레코드(260K 1,224 호출, 15M 804 호출), 합성 1,500, q/scale/idx 메모리와 ARGMAX 레지스터, guard 16 B, 매 cycle CSR 참조 모델(독립 descriptor 검사), CYCLES == 6.2 모델, ERR 원인별과 복구(BAD_OP, BAD_DESC 이유별, MISALIGN, 둘 다, START_BUSY, SLVERR/DECERR 읽기와 쓰기), random 레지스터 traffic, memory stall, 긴 write 차단(write buffer full, packer 대기, q FIFO full 요구), MAX_BURST 8/OUTS 2/Q_DEPTH 5, N_MAX 64/IDX_W 8 | 12 |

- quick tier: 각 test의 `q_` run(축소판: 15M은 1 위치).
- 회귀: `./sim/run.sh all` **424 run, fails 0**(기존 368 + `lut_lerp` SIGM 4 + 신규 52, `sim/regression_all.log`, wall 1,553 s).
- mutation 35개(`sim/.mut7/m.py`, `res_round1.txt`, `res.txt`): `rsqrt_nr` 3, `lut_lerp` SIGM 3, `actq_core` 6, `rms_front` 3, `swi_front` 3, `vec_core` 5, `vec_csr` 6, `vec_top` 6. **33개 검출, 2개 동치**. 첫 회차 생존 4개 중 2개는 TB 공백이었다: `aq_clamp`(음수 clamp를 -qmax - 1로)는 rshr(-amax R, 40 - e)가 -qmax보다 작아지는 경우가 qmax 32767, amax 67,126,271에서만 있어(C 탐색: 무작위 amax 2 x 10^8개 중 1개, amax < 2^26 전수에서는 0) 그 값을 합성 mode 9로 추가해 검출. `rms_clamp`(xs clamp를 -32768로)는 x = -(2^(15+k) - 1)에서만 rshr(x, k)가 -32768이 되어 합성 mode 8로 추가해 검출. 동치 2개: `vc_ek`(ARGMAX 호출이 원소 스트림을 닫지 않음: read engine은 명령의 beat만 보내므로 마지막 원소 뒤에 beat가 없다. 차이는 규칙 위반 입력의 `L2_SEQ` 검사뿐), `csr_live`(IN0 범위를 latch 대신 live 레지스터로: CHK_CYC = 1이라 판정 cycle v = s + 1의 live 값은 s의 값과 같다. v에 쓴 값은 v가 끝난 뒤 반영된다). 오류 범람으로 멈춘 mutant 2개(`vc_buf`, `top_in1`)는 log 크기 한도 뒤 수동 종료했고 오류 수십만 건으로 FAIL이다. RTL 원본 불변(sha256 대조).
- lint: `sim/.lint7`(S4-7 RTL 전부와 의존 모듈 `vlog -lint=full`, `vopt -lint=full` 12개 구성: `rsqrt_nr` U_W 42/20, `lut_lerp` FUNC 0/1, `exp_unit`, `actq_core`, `rms_front`, `swi_front`, `vec_core`, `vec_csr`, `vec_top` 기본과 N_MAX 64/IDX_W 8) 경고 0.

## 8. 자원 [계산, 합성 안 함]
DSP48E1(25 x 18 signed) 타일 수: 크기 비트(부호 제외) a x b의 곱을 ceil(a/24) x ceil(b/17)로 셌다.

| 모듈 | 곱 | DSP48E1 |
|---|---|---|
| `rsqrt_nr` | 17 x 35 unsigned 1개(순차 공유) | 2 |
| `lut_lerp` SIGM | (B - A) 11비트 x fr 12비트 | 1 (또는 LUT) |
| `swi_front` | h1 s 31 x 17, silu h3 31 x 31 | 2 + 4 = 6 (+ lut 1) |
| `rms_front` | xs (xs 또는 g) 15 x 16(P2와 P4가 공유), (xs g) rm 30 x 17 | 1 + 2 = 3 (+ rsqrt 2) |
| `actq_core` | v R 31 x 25 | 4 |
| `vec_core` 계 | | **16** (`arch.md` 8절 추정 14) |

- 메모리: `actq_core` buffer N_MAX x 32(1024: BRAM36 1), 공유 front buffer N_MAX x 32(BRAM36 1), q FIFO 8 x 16(FF), `axi_rd_eng` R 버퍼 64 x 65, `axi_wr_eng` 버퍼 32 x 64(LUTRAM 또는 BRAM18), 표 ROM SIGM 쌍 256 x 34, RSQ 48 x 16(LUT). `arch.md` 8절의 vec BRAM 0.5~1보다 많은 BRAM36 2개(+ engine FIFO)다. 260K 시스템(N_MAX 256)이면 두 buffer가 각각 8 Kb(BRAM18 또는 LUTRAM). 시스템 P BRAM 합계는 127 + 2 = 129/140 [계산, N_MAX 1024 기준].
- runtime 곱셈기/나눗셈기: control(`vec_csr`, `vec_top`, `vec_core` unpacker, packer, front/actq FSM)에는 없다. 바이트 수는 4N, 2N, N qb의 shift이고 descriptor 검사는 36비트 덧셈과 비교다. 남은 `*`는 leaf 데이터패스의 위 표와 상수 곱(part-select의 `16 * lane`, parameter 식)뿐이다(`grep` 결과, 9절).
- 줄일 수 있는 곳(관찰, 구현 안 함): rms_front와 swi_front의 곱셈기는 동시에 쓰이지 않고, actq_core의 v R(QUANT)도 front의 곱과 시간이 겹치지 않는다. 32 x 32 곱 하나를 공유하면 DSP 약 6개를 줄일 수 있다 [추정]. 100 MHz 타이밍 위험 [추정, 미측정]: actq SET1의 rshr_sat(33비트) + 41비트 덧셈이 udiv 입력으로 가는 경로, rsqrt의 65비트 덧셈 + 비교 + 뺄셈(D 단계), swi의 32 x 32 곱(1 단).

## 9. 정한 세부와 확인하지 못한 것
- 이번에 정한 것: op 번호(1 RMSNORM, 2 SWIGLU, 3 ACTQ, 4 ARGMAX), 레지스터 맵(FMT reset 0x0801007F, N 32비트 저장), CHK_CYC 1, ARGMAX는 idx를 OUT_ADDR에 int32로도 쓴다, scale은 SCL_ADDR에 {m, e} 8 B, 쓰기 순서 q 다음 scale, 공유 front buffer, swi_front가 silu를 buffer에 둠, `rsqrt_nr` CYCLES 15와 rm 17비트, `actq_core` e_o 폭 SH_W, SIGM은 `lut_lerp`의 같은 포트를 signed로 읽음, `lut_pkg`에 SIGM_TAB과 RSQ_TAB 추가(`lutsv.py`로 생성, EXP2N_TAB 불변).
- golden(`model/src`)은 바꾸지 않았다(trace 판 `k_*_st`가 이미 있어 DPI wrapper만 추가).
- 남은 runtime 곱셈 grep(S4-7 RTL 8개 파일, `*`): `rsqrt_nr` `ma * mb`, `lut_lerp` 보간 2개(EXP2N, SIGM), `actq_core` v R, `rms_front` xs g, (xs g) rm, `swi_front` h1 s, silu h3, `vec_top` `16 * lane_q`/`8 * lane_q`(상수 part-select)와 parameter 기본값 식, `vec_core` `16*lane_q`/`32*lane_q`(상수 part-select). `/`, `%`는 elaboration 검사 식 하나(`rsqrt_nr`)뿐.
- 확인하지 못한 것: 보드(HP latency, 100 MHz 타이밍, LUT 수, DSP 실제 매핑), CYCLES의 DDR latency 의존(6.2는 latency 1 모델), stall 있는 run의 CYCLES는 결과 일치만 확인. ARGMAX의 n 32,000은 레코드로, 65,536은 `vec_core`/`vec_top` 합성 호출로만 실행했다. irun 교차는 라이선스 정책상 하지 않았다.
