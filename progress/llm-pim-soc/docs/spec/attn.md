# Attention IP: `attn_top` (S4-6)

상태: RTL 시뮬레이션 통과(2026-11-19, `sim/tests/udiv_seq.cfg`, `lut_lerp.cfg`, `exp_unit.cfg`, `attn_score.cfg`, `attn_vacc.cfg`, `attn_core.cfg`, `kv_store.cfg`, `kv_rd.cfg`, `attn_top.cfg`), FPGA 미구성(G5 전). 구조 결정은 `arch.md` 4절(3 pass + 나눗셈, D7 260K KV는 BRAM, D8 H_PAR = 2, D9 layer 단위 명령, D14 kb/vb in {8, 12, 16}), 공통 레지스터 틀은 `arch.md` 7.2, engine 규칙은 `hierarchy.md` 3.6이 원본이다. 이 문서는 데이터 배치, 레지스터 맵, 실행 규칙, 내부 구성, cycle 식, 검증 내용을 확정한다.

- RTL: `rtl/l0/udiv_seq.sv`, `rtl/l0/lut_lerp.sv`(표 `rtl/pkg/lut_pkg.sv`, `model/tools/lutsv.py`로 `tabs.c`에서 생성), `rtl/l1/exp_unit.sv`, `rtl/l1/attn_score.sv`, `rtl/l1/attn_vacc.sv`, `rtl/l2/attn_core.sv`, `rtl/l2/kv_store.sv`, `rtl/l2/kv_rd.sv`, `rtl/l3/attn_csr.sv`, `rtl/l3/attn_top.sv`. 재사용(수정 없음): `rshr_sat`, `dotp`, `ram_sdp`, `sync_fifo`, `axil_slave`, `axi_rd_eng`, `axi_wr_eng`.
- golden: `model/src/kern.c`의 `k_attn2_st`(K_ATTN2, K_ATTN은 kb = vb = 8 또는 16과 같음)와 S4-6에서 export한 stage 함수 `k_attn_score`, `k_attn_exp`, `k_attn_pn`, `k_attn_w`, `k_attn_out`(`attn_core`가 이 함수들로 계산하도록 바꿨다. 기존 덤프 4종 `cmp` 동일, `make test` 16,669,793 항목 mismatch 0, `model/results/maketest_s4_6.txt`). TB 쪽 DPI는 `tb/dpi/kdpi.c`의 `kd_attn_*`, `kd_att_*`(연산은 모두 `kern.c`).
- 표기: cycle 수는 Questa 시뮬레이션(`axi_mem_slave` 모델, stall 없음, read/B latency 1)의 값이며 보드 값이 아니다. 자원은 [계산](구조에서 센 값, 합성 안 함).

## 1. 연산 (head 하나, golden `attn_core`)

| 단계 | 모듈 | 계산 (golden 함수) |
|---|---|---|
| P1 | `attn_score` | `dot = sum q_i K_ti`, `s = sat32(rshr(rshr(dot, d0) qm km, qe + ke - d0 - 16))` (`k_attn_score`), `d0 = k_attn_d0(kb)` = 0, 7, 15. running `mx`, vs.m != 0인 위치의 `emin` = min ve, `mmax` = max vm, `have` |
| P2 | `exp_unit` (+ `lut_lerp`) | `d = max(s - mx, -2^30)`, `w = rshr(d 47274, 15)`, `e = k_exp2neg(-w, 8)` (`k_attn_exp`), `sum += e` |
| DIV | `udiv_seq` | `R = 2^48 / sum` (몫 33비트), `G = 17 - bitlen(mmax)`. vs.m != 0인 위치가 없으면 `emin = G = 0` |
| P3 | `attn_vacc` | `p = (e R + 2^31) >> 32` (`k_attn_pn`), `w = rshr(p vm, ve - emin - G)` (`k_attn_w`, vm = 0이면 0), `acc_i += w V_ti` |
| O | `attn_vacc` | `o_i = sat32(rshr(acc_i, emin + G))` (`k_attn_out`) |

- 폭: dot 38비트(16x16 곱 8 lane 합 35비트 + beat 누산), `rshr(dot, d0)` 24비트(golden 전제 `|.| < 2^22`, 넘으면 `L1_RANGE`), `qm km` 34비트, score 곱 58비트, `d 47274` 49비트, `e R` 50비트, `p vm` 34비트, `w` 36비트 container(golden 상한 2^33), V 누산 `ACC_W` = 60(검사 `ACC_W >= 50 + log2 T_MAX`).
- q, K, V는 16비트 container. kb, vb in {8, 12, 16}은 golden의 값 범위를 전제로 한다(actq 출력). core는 vb를 쓰지 않는다(V는 sign-extend된 값으로 온다).
- hs: core는 1..HS_MAX 임의(마지막 beat의 lane >= hs는 무시). `attn_top`은 hs가 8의 배수인 것만 받는다(DDR 행이 8 B 단위, BAD_DESC).

## 2. 데이터 배치 (DDR, little-endian)

| 버퍼 | 주소 | 형식 |
|---|---|---|
| q 레코드 | `Q_ADDR + h QB`, `QB = 8 + 2 hs` | `{int32 qm, int32 qe}`(8 B) 뒤에 q int16 [hs]. ARM이 head마다 actq 결과(`qh`, `qhs`)를 이 형식으로 쓴다 |
| o | `O_ADDR + 4 hs h` | int32 [hs] (golden `att + h hs`와 같음) |
| p (`p_en`) | `P_ADDR + PS h`, `PS = 8 ceil(T/2)` | int32 [T]. head 사이 간격을 8 B로 올림한 것은 `axi_wr_eng`가 8 B 정렬 시작 주소만 받기 때문이다(S4-6 TB에서 발견) |
| KV (KV_SRC 1) | kv head j, 위치 t: `K_ADDR + (j SEQ + t) hs ek`, `V_ADDR + (j SEQ + t) hs ev`, `KS_ADDR + 8 (j SEQ + t)`, `VS_ADDR + 8 (j SEQ + t)` | golden `fwd_h.c`의 `kc`, `vc`, `kcs`, `vcs` slot 배치(`((l nkv + j) seq + pos)`)와 같다. 호스트는 layer l의 base(`kc + l nkv seq hs ek` 등)와 `SEQ = seq_len`을 준다. ek = 2(kb > 8) 또는 1, ev도 같음. scale = `{int32 m, int32 e}` |
| KVW 원본 (KV_SRC 0) | 위와 같은 식, t = `POS` | 같은 golden 배치를 읽어 kv_store에 쓴다 |

kv head of q head h = `h / KVMUL`(golden `j / kvmul`).

## 3. 레지스터 맵 (32비트, offset은 byte)

| offset | 이름 | 접근 | reset | 내용 |
|---|---|---|---|---|
| 0x00 | ID | R | 0x41540001 | [31:16] 0x4154("AT"), [15:0] 버전 1 |
| 0x04 | CONFIG | R | | [7:0] `FCLK_MHZ`, [10:8] H_PAR, [11] KV_SRC(0 BRAM, 1 DDR), [15:12] log2(KL) = 3, [31:16] TMAX |
| 0x08 | CTRL | W | | bit0 start, [7:4] op(1 = ATTN, 2 = KVW). 읽으면 0 |
| 0x0C | STATUS | R | 0 | bit0 busy, bit1 done_sticky, bit2 err_any |
| 0x10 | ERR | R/W1C | 0 | bit0 START_BUSY, bit1 BAD_OP, bit2 BAD_DESC, bit3 MISALIGN, bit4 RD_RESP, bit5 WR_RESP |
| 0x14 | CYCLES | R | 0 | 마지막 op의 cycle 수(e - s) |
| 0x18 | RD_STALL | R | 0 | 같은 구간에서 어떤 core가 KV beat를 기다린 cycle 수(`kv_stall_o`의 OR) |
| 0x1C | WR_STALL | R | 0 | 같은 구간에서 packer의 beat를 `axi_wr_eng`가 받지 못한 cycle 수 |
| 0x20 | OPS | R | 0 | reset 이후 끝난 op 수(ATTN + KVW), 2^32 wrap |
| 0x24 | CONFIG2 | R | | [7:0] HS_MAX, [15:8] NKV, [23:16] NL (KV_SRC 1이면 [31:8] = 0) |
| 0x28 | CONFIG3 | R | | [7:0] KW, [15:8] VW, [31:16] TMAX (KV_SRC 1이면 0) |
| 0x40..0x58 | Q_ADDR, O_ADDR, P_ADDR, K_ADDR, V_ADDR, KS_ADDR, VS_ADDR | RW | 0 | 2절 |
| 0x5C | T | RW | 0 | [15:0] 위치 수(ATTN) |
| 0x60 | HS | RW | 0 | [7:0] head size |
| 0x64 | FMT | RW | 0 | [4:0] kb, [12:8] vb, [16] p_en |
| 0x68 | HEAD | RW | 0 | [7:0] HEAD0, [15:8] NHEAD, [23:16] KVMUL |
| 0x6C | LAYER | RW | 0 | [7:0] layer (KV_SRC 0: kv_store 주소의 layer) |
| 0x70 | SEQ | RW | 0 | [15:0] DDR KV / KVW 원본에서 kv head 사이의 위치 간격(golden seq_len) |
| 0x74 | POS | RW | 0 | [15:0] KVW 위치 |
| 0x78 | KVH | RW | 0 | [7:0] KVH0, [15:8] NKVH (KVW kv head 범위) |

- 정의되지 않은 주소는 0을 읽고 쓰기는 무시한다. 주소 bit[1:0]과 WSTRB는 무시한다. 응답은 항상 OKAY(`axil_slave`). 같은 cycle의 읽기는 쓰기 전 값을 본다. `gemv_acc.md`, `pim.md`와 같은 규칙이다.
- descriptor 레지스터는 필드 비트만 저장하고 나머지는 0으로 읽힌다.

## 4. 실행 규칙

### 4.1 CTRL (쓰기가 수행되는 cycle s, idle = busy가 아니거나 op가 끝나는 cycle e)
| 조건 | 결과 |
|---|---|
| idle, start, op 1 (ATTN) 또는 op 2 (KVW, KV_SRC 0), descriptor 정상 | 시작. descriptor를 latch(s + 1부터 유효, 이후의 레지스터 쓰기는 진행 중인 op에 영향 없음), done_sticky clear, CYCLES/RD_STALL/WR_STALL = 0 |
| idle, start, op 1/2, descriptor 오류 | 시작 안 함. BAD_DESC 그리고/또는 MISALIGN(독립), done_sticky clear |
| idle, start, op가 1, 2가 아님 또는 op 2인데 KV_SRC 1 | BAD_OP만. done_sticky 불변 |
| idle, start = 0 | done_sticky clear만 |
| busy(e가 아님), start = 1 | START_BUSY(op가 틀리면 BAD_OP도). 무시 |

- done_sticky는 e에 set(e + 1부터 보임), 같은 cycle의 clear가 이긴다. ERR는 W1C, 같은 bit의 set이 clear를 이긴다. RD_RESP/WR_RESP는 RRESP[1]/BRESP[1]인 handshake마다 set되고 데이터는 그대로 쓰인다(op는 끝까지 간다).

### 4.2 descriptor 검사 (`attn_csr`, TB의 독립 모델과 매 cycle 대조)
- 공통(ATTN, KVW): kb, vb in {8, 12, 16}, hs != 0, hs % 8 == 0, hs <= HS_MAX.
- ATTN: 1 <= T <= TMAX, NHEAD >= 1, KVMUL >= 1, HEAD0 + NHEAD <= 256, 범위 `Q_ADDR + (HEAD0 + NHEAD) QB`, `O_ADDR + 4 hs (HEAD0 + NHEAD)`, (`p_en`) `P_ADDR + PS (HEAD0 + NHEAD)`가 2^32 이하. KV_SRC 0: hs <= KL(8), kb <= KW, vb <= VW, LAYER < NL, `(HEAD0 + NHEAD - 1) / KVMUL < NKV`. KV_SRC 1: T <= SEQ, 2절 KV 네 버퍼의 마지막 kv head(`(HEAD0 + NHEAD - 1) / KVMUL`) 위치 T - 1 끝이 2^32 이하.
- KVW: hs <= KL, kb <= KW, vb <= VW, NKVH >= 1, KVH0 + NKVH <= NKV, POS < TMAX, POS < SEQ, LAYER < NL, 네 원본 버퍼의 마지막 행 끝이 2^32 이하.
- MISALIGN: ATTN은 Q_ADDR, O_ADDR, (`p_en`) P_ADDR, (KV_SRC 1) K/V/KS/VS_ADDR의 [2:0] != 0. KVW는 K/V/KS/VS_ADDR.
- 이 검사로 engine이 거절할 명령(정렬, 길이 0, 2^32 넘김)은 생기지 않는다(시뮬레이션 검사 `L3_ENGCMD`).

### 4.3 op 종료 e
- ATTN: 모든 engine의 head 순서기가 끝났고, write 중재가 비었고(grant 없음, 남은 write 명령 없음), packer가 비었고, `axi_wr_eng`가 마지막 B를 받은 첫 cycle. KVW: 마지막 kv head의 word를 kv_store에 쓰는 cycle. CYCLES = e - s.

### 4.4 PS 호출 순서 (forward의 layer l, 위치 pos, T = pos + 1)
1. (KV_SRC 0) ARM의 K/V actq 결과가 golden 배치의 `kc/vc/kcs/vcs`에 있다. `K_ADDR` 등 = layer l base, `SEQ`, `LAYER = l`, `POS = pos`, `KVH = {NKV, 0}`, `HS`, `FMT`; flush; `CTRL = 0x21`(KVW); done_sticky polling.
2. head마다 q 레코드를 쓰고 flush. `Q_ADDR`, `O_ADDR`, (`P_ADDR`), `T`, `HEAD = {KVMUL, NHEAD, HEAD0}`, `FMT`(p_en). (KV_SRC 1) `K_ADDR`.. = layer base, `SEQ`. `CTRL = 0x11`; done_sticky polling; `ERR`, `CYCLES`; o를 invalidate.
- golden 순서(head마다 attention 호출, 260K token당 40회)를 layer당 KVW 1회 + ATTN 1회로 줄인다(D9).

## 5. 구성

```
s_axi -> axil_slave -> attn_csr (registers, descriptor check, start/done, latched descriptor)
engine e < H_PAR:
  head sequencer: h = 0.., kv head = h / KVMUL (counter, no divider); takes h >= HEAD0 with
                  (h / KVMUL) mod H_PAR = e; per head: q record read -> header (qm, qe) -> core start
  axi_rd_eng (read port e) --q beats (2 -> 1 q beat)--> attn_core --kvreq--> KV source
                           --KV beats (KV_SRC 1)----> kv_rd e --pass stream--> attn_core
  KV_SRC 0: kv_store read port e --pass stream--> attn_core
attn_core (P1/P2/DIV/P3/O) --p, o stream--> write arbiter (one engine's head at a time,
                                            p cmd + o cmd) --> packer (2 x 32 -> 64) --> axi_wr_eng
KVW (KV_SRC 0): read port 0 commands (K row, V row, ks, vs per kv head) -> word -> kv_store write
```

- `attn_core` 내부: `attn_score`(P1), `ram_sdp` p buffer(TMAX x 32: s, 이어서 e), `ram_sdp` vs buffer(TMAX x 25: P1에서 쓰고 P3에서 읽음), `exp_unit`(P2), `udiv_seq`(DIV), `attn_vacc`(P3, O), `sync_fifo` 출력 FIFO(`OUT_DEPTH` x 34: data, last, is_o). pass FSM은 `attn_core` 자신의 control이다(`hierarchy.md` 초안의 `attn_ctrl`을 별도 모듈로 두지 않았다).
- KV source 인터페이스(KV 위치와 무관): core가 pass를 요청(`kvreq`, 0 = K, 1 = V)하면 source가 T x ceil(hs/8) beat를 위치 순서로 보낸다. K pass beat는 K lane과, 위치의 마지막 beat에서 `(km, ke, vm, ve)`. V pass beat는 V lane만(scale은 core의 vs buffer에서). K 요청은 start 때, V 요청은 P2 시작 때 내서 source가 미리 읽을 수 있다.
- core의 backpressure: P1, P2는 멈추지 않는다. P3는 위치의 첫 beat를 출력 FIFO credit(level + 진행 중 p < OUT_DEPTH)이 있을 때만 받고, O는 빈 칸이 있을 때만 읽는다.
- `kv_store`: kv head마다 `ram_sdp` 하나, word = K 8 x KW + V 8 x VW + ks 25 + vs 25(KW 12, VW 8이면 210비트, `arch.md` 4.2), 주소 `layer x TMAX + t`. 읽기 포트 p는 kv head j (j mod H_PAR = p)만 읽는다(엔진 배정 규칙과 같아 RAM 하나를 두 포트가 읽는 일이 없다). 포트마다 출력 FIFO 4와 credit(read latency 1)로 1 위치/cycle.
- `kv_rd`: K pass는 CH(16) 위치 단위로 ks(CH x 8 B), vs(CH x 8 B), K 행(CH x hs x ek B) 명령 3개, V pass는 명령 1개(T x hs x ev B). 2 B 원소는 입력 beat 2개가 출력 beat 1개(lane 0..3, 4..7), 1 B 원소는 1개.
- write 중재: 출력이 있는 engine 중 번호가 낮은 쪽에 head 하나(p 다음 o)를 통째로 준다. grant 때 write 명령(p, o)을 낸다. 다른 engine은 자기 출력 FIFO credit이 찰 때까지 P3를 계속한다.
- 하위 모듈은 수정 없이 인스턴스만 했다(S4-6 안에서 새로 만든 모듈 사이의 배선과 각 계층의 control만).

## 6. cycle 식

### 6.1 `attn_core` (측정으로 확정, `tb_attn_core` STALL=0 runs에서 모든 호출이 일치)
start 수락 cycle을 0, `done_o` cycle을 C라 하면, q와 KV beat가 매 cycle 오고 출력이 항상 받아질 때

**C = (T + 1) ceil(hs/8) + T + T ceil(hs/8) + hs + C0**, **C0 = 54 + DOT_PIPE + SH_PIPE + RS_PIPE + LUT_PIPE** (기본 PIPE 2/1/1/2에서 60)

- 항: q 적재 ceil(hs/8), P1 T ceil(hs/8), P2 T, P3 T ceil(hs/8), O hs(출력 1개/cycle). C0 = P1 drain(DOT + SH + 5) + P2 drain과 DIV(RS + LUT + 3 + Q_W 33 + 2) + P3 drain(LAT_MAC + 1 = 7) + O drain(LAT_O + 2 = 4).
- `arch.md` 4.4의 `T ceil(hs/KL) + T + T ceil(hs/VL) + C_div + L_pipe`(C_div + L_pipe 약 80 [추정])와 비교하면 q 적재(ceil(hs/8))와 o 출력(hs) 항이 더 있고 상수는 60이다. 260K(hs 8): **C = 3T + 69**(arch 추정 3T + 80).
- `p_en`은 stall이 없으면 cycle에 영향이 없다(출력 FIFO credit만).

### 6.2 `attn_top` token 합 [측정, Questa, stall 없는 메모리 모델 latency 1, p_en = 0]
ATTN op CYCLES를 layer마다 한 op(head 전부)로 돌려 token(위치) 하나의 layer 합을 냈다(`attn_top.cfg`의 `*_tok` runs).

| 구성 | T = 1 | 8 | 64 | 128 | 256 | 512 | arch.md 4.4 [계산] |
|---|---|---|---|---|---|---|---|
| 260K, KV BRAM, H_PAR 2 | 1,760 | 2,180 | 5,540 | 9,380 | 17,060 | **32,420** | T 512에서 32,320 |
| 260K, KV BRAM, H_PAR 1 | 3,365 | 4,205 | 10,925 | 18,605 | 33,965 | 64,685 | - |
| 260K, KV BRAM, H_PAR 2, p_en = 1 | 1,745 | 2,198 | 5,874 | 10,032 | 18,360 | 34,983 | - |
| 15M, KV DDR, H_PAR 1 | 5,514 | - | - | 101,526 | 198,294 | - | T 256에서 196,416 |
| 15M, KV DDR, H_PAR 2 | 3,102 | - | - | 51,108 | 99,496 | - | - |

- 260K H_PAR 2: layer 하나 = engine당 head 4개 순차. T 256과 512의 차에서 layer당 12T(= 4 head x 3T), 절편 layer당 340 = 4 x 69(core) + 64. head당 q 레코드 읽기와 순서기 전환이 약 8 cycle, op 시작/종료(마지막 B)가 약 31 cycle이다(H_PAR 1과 2의 두 식에서 푼 값, engine 사이 write 중재가 겹쳐 정수로 나눠지지 않는다).
- 15M DDR H_PAR 1: head당 198,294 / 36 = 5,508 = 21T + 132(T 256). P1이 위치당 14 beat(K 12 + scale 2), P3가 6 beat라 `arch.md`의 `21T + 80` 식과 같은 꼴이고 상수가 52 크다(chunk 명령마다의 engine 왕복과 q 레코드 읽기).
- p_en = 1은 260K T 512에서 8% 늘었다(두 engine의 p가 write 포트 하나를 나눠 쓰고, 다른 engine의 출력이 grant를 기다리는 동안 credit에 걸린다).
- KVW: kv head 4개를 쓰는 op 하나가 38 CYCLES(2,560 op 평균, 4 x 4 read 명령). 260K token당 layer 5개 = 190 cycle.
- 보드의 DDR latency, ARM 쪽 비용(AXI-Lite 쓰기, cache flush/invalidate, polling)은 들어 있지 않다.

## 7. 시뮬레이션 검증 (2026-11-19)

| test | 내용 | run |
|---|---|---|
| `udiv_seq` | C `/` 대조. attention 크기(49/26/33) 경계(q 0, 1, 2^33 - 1, den 1, 2^26 - 1, 나머지 0/den - 1, 2^48 / 2^k +- 1, k = 16..25)와 random 10^6, actq 크기(41/25/25, 32/17/17), 작은 크기 전수(10/5/5: 15,872, 8/3/6), done 시점, busy, q 유지, done cycle의 start. negative: 0 나눗셈(UDIV_ZERO), 몫 넘침(UDIV_OVF), busy 중 start(UDIV_START) | 10 |
| `lut_lerp` | 표 257항목 == `k_exp_lut(8)`, u 전수 [0, 2^21)(2,097,152 + 경계 416), I >= 32 random 10^6, PIPE 1/2/3, valid gap | 6 |
| `exp_unit` | 모든 attention 레코드 trace의 (s, mx) -> e(trace e == `kd_attn_exp`도 확인), d 경계(0, 지수 단계, clamp -2^30 +-2), -w가 2^32를 넘어 wrap하는 구간(clamp가 없으면 틀리는 d), s > mx, random 10^6 | 9 |
| `attn_score` | 모든 attention 레코드(K12V8 260K 480, 15M 216, HB/HD 260K 280 + 15M 144)의 s[t], vm/ve, mx, emin, mmax, have, 정확한 latency. 합성 호출(gen_syn 6 mode), KL 4/HS_MAX 40, PIPE 0/0, 4/2 | 7 |
| `attn_vacc` | 같은 레코드와 합성의 p[t], w[t], acc[i](white-box), o[i](random 순서 읽기) | 8 |
| `attn_core` | 같은 레코드 전부(p와 o, p_en random), stage trace(s, mx, e, sum, R, G, emin, w, acc), STALL=0에서 모든 호출의 cycle 식 6.1, stall(q/KV gap, 요청 지연, out_ready, 긴 출력 차단: credit 도달 요구), 합성 900 x 2, OUT_DEPTH 4, HS_MAX 20/TMAX 64, PIPE 3종, negative(L2_START, KL != VL) | 13 |
| `kv_store` | shadow memory 대조: 모든 slot 쓰기 + random 재쓰기, 포트 동시 pass 요청, 긴 차단(FIFO full 도달 요구), 처리율(T + 3 cycle), H_PAR 1/2/4, K16V16 word, negative(잘못된 포트, KW 밖 값) | 8 |
| `kv_rd` | `axi_rd_eng` + `axi_mem_slave`, golden 배치(1/2 B 원소, scale), T의 chunk 경계, 4 KiB 걸침, memory stall/latency, 소비자 긴 차단(read buffer full 도달 요구), CH 1/5/16, burst 4 x outs 1 | 7 |
| `attn_top` | AXI-Lite BFM + memory model. 260K forward 순서(12 위치, 위치마다 layer 5개 x (새 위치 KVW + ATTN), KVW 2,560 op), 15M DDR KV(6 위치), 260K DDR KV(KVMUL 2). o, p == 레코드, guard, 매 cycle CSR 참조 모델(독립 descriptor 검사 포함), ERR 원인별과 복구, random 레지스터 traffic, memory stall, 긴 write 차단(write buffer full, packer 대기, core credit 도달 요구), H_PAR 1/2, KV_SRC 0/1, OUT_DEPTH 4, H_PAR 3 elaboration 실패 | 15 |

- mutation 42개(`sim/.mut6/m.py`): `udiv_seq` 3, `lut_lerp` 3, `exp_unit` 2, `attn_score` 5, `attn_vacc` 4, `attn_core` 8, `kv_store` 2, `kv_rd` 3, `attn_csr` 3, `attn_top` 9. **42개 모두 검출**(`sim/.mut6/summary.txt`). 첫 회차에서 살아남은 3개(`lut_zero`: u = 17 x 2^16에서만 다름, `exp_clamp`: -w wrap 구간, `csr_hs8`: BRAM 빌드에서 hs 12는 hs <= KL로도 거절됨)는 동치가 아니라 TB 공백이었고, 방향성 벡터(fraction 경계, wrap 구간, hs 4)를 추가해 검출했다. `kvs_credit`는 L2_OVF 13회 뒤 TB가 멈춰(beat 유실) 손으로 끝냈고, `tb_kv_store`/`tb_kv_rd`에 watchdog(`TB_TIMEOUT`)을 넣었다.
- lint: `vlog -lint=full`, `vopt -lint=full`(`sim/.lint6`: 9개 모듈 + `attn_top` KV_SRC 1/H_PAR 1 + `attn_core` PIPE 0) 경고 0.

## 8. 자원 [계산, 합성 안 함]

| 모듈 | DSP48E1 (25x18) | 메모리 |
|---|---|---|
| `attn_score` | 16x16 곱 8(lane당 1) + `qm km` 17x17 1 + `rshr(dot) x c` 24x34 2 = 11 | q 레지스터 HS_MAX x 16 FF |
| `exp_unit` | `d x 47274` 33x16 2 (상수곱이라 LUT로 갈 수 있음) | - |
| `lut_lerp` | `(a - b) fr` 8x8 1 (또는 LUT) | (a, b) 쌍 ROM 256 x 34 (LUT) |
| `attn_vacc` | `e R` 17x33 2 + `p vm` 17x17 1 + `w V` 36x16 x 8 lane 2개씩 16 = 19 | 누산기 HS_MAX x 60 FF(260K 빌드 HS_MAX 8: 480, 15M 64: 3,840) |
| `attn_core` 계 | **33** (arch.md 4.3의 33과 같음) | p buffer 512 x 32 (BRAM18) + vs buffer 512 x 25 (BRAM18) = BRAM36 1개 상당, 출력 FIFO 16 x 34 |
| `kv_store` (260K) | 0 | kv head마다 210비트 x 2,560 = BRAM36 3 폭 x 5 깊이 = 15, 4개 **60** |
| `kv_rd` | 0 | scale buffer CH x 25 x 2 (레지스터) |

- 260K 시스템 P(H_PAR 2): attention DSP 66, BRAM36 60 + 2 = 62. `arch.md` 8절 표(attention engine당 BRAM 0.5)보다 engine당 0.5 많다: P3에서 vm/ve를 다시 읽지 않으려고 vs buffer를 따로 둬서다(KV 스트림이 P3에서 V만 싣고, DDR KV의 P3 traffic이 위치당 V 행만 된다). 시스템 P 합계는 126 -> 127/140 [계산].
- 관찰: descriptor 검사(`attn_csr`)와 주소 계산(`attn_top`의 `kvh x SEQ x row`, `h x QB`, `h x 4 hs`, KVW slot)이 runtime 곱셈이다. 합성하면 곱셈기 10개 이상이 추론될 수 있다 [추정]. op 시작 때 한 번 계산되는 값이라 순차 계산이나 증분 덧셈으로 바꿀 수 있다(남은 일).
- 100 MHz 타이밍 위험 [추정, 미측정]: 24x34, 17x33 곱, 60비트 누산(lane 8개), `attn_vacc`의 o 읽기 mux(HS_MAX:1, 60비트), `rshr_sat` 58/60비트.

## 9. 정한 세부와 확인하지 못한 것
- 이번에 정한 것: q 레코드 형식(header 먼저), p head 간격 8 ceil(T/2) B, hs % 8 == 0(top), KV 스트림 인터페이스와 요청 시점, vs buffer, op 2개(ATTN, KVW, 명령 FIFO 없음), 엔진 배정 `(h / KVMUL) mod H_PAR`, kv_store 포트 배정 `j mod H_PAR`, KVW는 layer/위치 하나에 kv head 범위, write 중재는 head 단위, CONFIG2/CONFIG3, ERR 비트 6개, model의 stage 함수 5개 export.
- `udiv_seq` CYCLES = Q_W + 1(34)이다(`hierarchy.md` 초안의 Q_W + 2보다 1 짧다).
- 보드: HP 포트 latency, 100 MHz 타이밍, LUT 수, 72비트 BRAM 폭 추론(210비트 word가 BRAM36 3개 폭으로 매핑되는지) 미확인.
- 15M에서 kv_rd의 chunk 명령 왕복이 DDR latency에 따라 얼마나 늘어나는지는 latency 1 모델 값만 있다(`axi_mem_slave` latency 1..16 stall run은 결과 일치만 확인했고 cycle은 비교하지 않았다).
- `attn_csr`는 전용 TB 없이 `attn_top` TB의 매 cycle 참조 모델로만 검증했다.
