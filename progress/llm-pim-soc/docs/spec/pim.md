# GEMV PIM형 IP: `pim_top` (S4-5)

상태: RTL 시뮬레이션 통과(2026-11-19, `sim/tests/pim_gb.cfg`, `pim_bank.cfg`, `pim_ctrl.cfg`, `pim_core.cfg`, `pim_csr.cfg`, `pim_top.cfg`), FPGA 미구성(G5 전). 구조 결정은 `arch.md` 3절(D4 NB 4 x LB 16, D5 BANK_ROW, D6 행 가수를 첫 word의 tag(parity) 16비트에), 공통 레지스터 틀은 `arch.md` 7.2, engine 규칙은 `hierarchy.md` 3.6이 원본이다. 이 문서는 명령 형식, 레지스터 맵, 실행 규칙, 내부 구성, cycle 식을 확정한다.

- RTL: `rtl/l1/pim_gb.sv`, `rtl/l1/pim_bank.sv`, `rtl/l1/pim_ctrl.sv`, `rtl/l2/pim_core.sv`, `rtl/l3/pim_csr.sv`, `rtl/l3/pim_top.sv`. 재사용(수정 없음): `ram_sdp`, `sync_fifo`, `dotp`, `mac_row`(LANES 16), `gemv_scale`, `rshr_sat`, `axil_slave`, `axi_rd_eng`, `axi_wr_eng`.
- golden: `model/src/bank.c`의 `bank_pack`/`bank_gemv`(BANK_ROW, nbank 4), `bimg_pack`(bank RAM image), `bank_stat_t`(명령 수), `k_gemv`(K_GEMV 레코드). TB 쪽 DPI는 `tb/dpi/kdpi.c`의 `kd_rec_bank`, `kd_bank_syn`(이번에 추가, 연산은 모두 `bank.c`).
- 표기: cycle 수는 Questa 시뮬레이션(`axi_mem_slave` 모델, stall 없음, read/B latency 1)의 값이며 보드 값이 아니다.

## 1. 연산

`MACAB` 명령 하나가 행렬 하나(rows x n, gs = n)에 대해

`y[r] = sat32(rshr(dot8(W[r], x) * wm[r] * xm, we + xe - fo))`, r = 0 .. rows - 1

을 계산한다(golden `k_gemv`, 레코드 K_GEMV). W와 wm은 미리 `LDW`로 bank에 적재한 image, x는 `WRGB`로 global buffer에 적재한 벡터다.

- bank 배치(BANK_ROW, `bimg_pack`): 행 r은 bank r mod 4의 word `base + (r div 4) nw + w`(nw = ceil(n/16), w < nw)에 있다. word = 144비트: [8i+7:8i] = lane i(열 16w + i의 int8, 열 >= n은 0), [143:128] = tag(w = 0이면 wm, 아니면 0). 마지막 round의 빈 slot(rows가 4의 배수가 아닐 때 bank rows mod 4 .. 3)은 0 word다.
- 출력: `Y_ADDR`(명령의 addr)에 int32 y[rows], little-endian, y[2k]는 64비트 beat의 [31:0]. rows가 홀수면 마지막 beat의 4 byte만 쓴다(WSTRB 0x0F).

## 2. 명령 형식

호스트는 CMD0..CMD3에 명령을 만들고 CMD_PUSH에 쓰면 명령 FIFO에 들어간다.

| 단어 | 비트 | 필드 | 쓰는 명령 |
|---|---|---|---|
| CMD0 | [3:0] | op: 1 = LDW, 2 = WRGB, 3 = MACAB (그 외 BAD_CMD. 4 = RDROW는 구현하지 않았다) | 모두 |
| CMD0 | [15:4] | n (1 .. NMAX) | 모두 |
| CMD0 | [31:16] | rows (1 .. 65535) | LDW, MACAB |
| CMD1 | [16:0] | xm (활성 scale 가수) | MACAB |
| CMD1 | [31:17] | base (bank word 주소) | LDW, MACAB |
| CMD2 | [31:0] | DDR 주소: LDW 행 레코드(`arch.md` 2.2), WRGB x(int8 [n]), MACAB y | 모두 |
| CMD3 | [7:0], [15:8], [23:16] | we, xe, fo (각 signed 8비트), [31:24] 무시 | MACAB |

- 쓰지 않는 필드는 무시한다(검사하지 않음).
- `LDW`: 행 레코드(header 8 B의 [15:0] = wm, 나머지 무시 + 가중치 ceil(n/8) x 8 B, 열 >= n의 byte는 무시하고 0으로 적재)를 `rows x 8 (1 + ceil(n/8))` byte 읽어 bank에 쓴다. 초기화 때 행렬마다 1회.
- `WRGB`: x를 n byte 읽어 global buffer에 적재한다. 마지막 beat의 n 밖 byte는 무시하고, global buffer의 n 밖은 0으로 읽힌다.
- `MACAB`: 1절의 연산. global buffer는 바꾸지 않으므로 같은 x를 쓰는 행렬은 `WRGB` 1회 뒤 `MACAB`를 여러 번 낸다(`arch.md` 3.3: layer당 WRGB 4회, MACAB 7회).

## 3. 레지스터 맵 (32비트, offset은 byte)

| offset | 이름 | 접근 | reset | 내용 |
|---|---|---|---|---|
| 0x00 | ID | R | 0x50490001 | [31:16] 0x5049("PI"), [15:0] 버전 1 |
| 0x04 | CONFIG | R | | [7:0] `FCLK_MHZ`, [11:8] NB(4), [15:12] log2(LB) = 4, [31:16] `NMAX`(1024) |
| 0x08 | CTRL | W | | bit0 start, [7:4] op(1 = RUN, 2 = FLUSH). 읽으면 0 |
| 0x0C | STATUS | R | 0 | bit0 busy, bit1 done_sticky, bit2 err_any(ERR != 0), [23:8] 명령 FIFO에 있는 명령 수 |
| 0x10 | ERR | R/W1C | 0 | bit0 START_BUSY, bit1 BAD_OP, bit2 BAD_CMD, bit3 BAD_DESC, bit4 MISALIGN, bit5 RD_RESP, bit6 WR_RESP, bit7 FIFO_OVF |
| 0x14 | CYCLES | R | 0 | 마지막 run의 cycle 수(4절) |
| 0x18 | RD_STALL | R | 0 | 같은 구간에서 core가 read beat를 받을 수 있는데 없던 cycle 수 |
| 0x1C | WR_STALL | R | 0 | 같은 구간에서 packer의 beat를 `axi_wr_eng`가 받지 못한 cycle 수 |
| 0x20 | OPS | R | 0 | reset 이후 끝난 명령 수(LDW + WRGB + MACAB) |
| 0x24 | CONFIG2 | R | | [15:0] DEPTH(bank word 수, 4096), [31:16] CMD_DEPTH(명령 FIFO 깊이, 32) |
| 0x40..0x4C | CMD0..CMD3 | RW | 0 | 만들고 있는 명령(32비트 그대로 저장) |
| 0x50 | CMD_PUSH | W | | 쓰면 {CMD3, CMD2, CMD1, CMD0}을 검사해 FIFO에 넣는다(쓴 값은 무시). 읽으면 0 |
| 0x60 | ST_WRGB | R | 0 | `bank_stat_t.wrgb`: WRGB의 32 B 단위 수(WRGB마다 ceil(n/32)) |
| 0x64 | ST_MAC | R | 0 | `bank_stat_t.mac`: 전 bank MAC step 수(MACAB마다 ceil(rows/4) x ceil(n/16)) |
| 0x68 | ST_RDMAC | R | 0 | `bank_stat_t.rdmac`: gather한 결과 수(MACAB마다 rows) |
| 0x6C, 0x70, 0x74 | N_LDW, N_WRGB, N_MACAB | R | 0 | 종류별 끝난 명령 수 |

- 정의되지 않은 주소는 0을 읽고 쓰기는 무시한다. 주소 bit[1:0]과 WSTRB는 무시한다. 응답은 항상 OKAY(`axil_slave`). `gemv_acc.md`와 같은 규칙이다.
- 0x20과 0x60..0x74는 reset 이후 누적이며 2^32에서 wrap한다. 호스트는 차이로 쓴다.
- 명령 수 카운터는 하드웨어 사건을 센다: ST_MAC은 MAC read cycle(전 bank lock-step 한 번), ST_WRGB는 global buffer beat 0, 4, 8, ...(= 32 B 단위), ST_RDMAC은 gather 1회. `bank_gemv`는 호출마다 wrgb를 세므로(호출 = WRGB + MACAB), 레코드마다 WRGB를 내는 순서에서는 세 값이 `bank_stat_t` 합과 같고, layer 순서(같은 x에 WRGB 1회)에서는 wrgb만 WRGB 명령 수에 맞게 줄어든다. mac과 rdmac은 순서와 무관하게 같다.

## 4. 실행 규칙

### 4.1 CMD_PUSH 검사 (push가 수행되는 cycle의 CMD0..CMD3)
| 조건 | 결과 |
|---|---|
| op가 1..3이 아님 | BAD_CMD만. FIFO에 넣지 않음 |
| BAD_DESC: n이 0 또는 > NMAX; LDW/MACAB에서 rows = 0 또는 base + ceil(rows/4) ceil(n/16) > DEPTH; DDR 범위가 2^32를 넘음(LDW addr + rows 8 (1 + ceil(n/8)), WRGB addr + n, MACAB addr + 4 rows) | BAD_DESC. FIFO에 넣지 않음 |
| MISALIGN: addr[2:0] != 0 | MISALIGN(BAD_DESC와 독립). FIFO에 넣지 않음 |
| 정상, FIFO 가득 참 | FIFO_OVF. FIFO에 넣지 않음 |
| 정상 | FIFO에 넣음(run 중이어도 됨) |

이 검사로 engine이 거절할 명령(정렬, 길이 0, 2^32 넘김)과 bank 범위를 넘는 명령은 core에 가지 않는다(시뮬레이션 검사 `L3_ENGCMD`, `PIM_RANGE`).

### 4.2 CTRL
CTRL 쓰기가 수행되는 cycle을 s라 한다. "idle"은 busy가 아니거나 그 cycle이 run이 끝나는 cycle(e)인 경우다.

| 조건 (CTRL 쓰기) | 결과 |
|---|---|
| idle, start = 1, op = 1 (RUN) | run 시작. done_sticky clear, CYCLES/RD_STALL/WR_STALL = 0. s + 1부터 FIFO의 명령을 차례로 실행 |
| idle, start = 1, op = 2 (FLUSH) | FIFO의 명령을 실행하지 않고 한 cycle에 하나씩 버림 |
| idle, start = 1, op가 1, 2가 아님 | BAD_OP만. done_sticky 불변 |
| idle, start = 0 | done_sticky clear만 |
| busy(끝나는 cycle 아님), start = 1 | START_BUSY(op가 틀리면 BAD_OP도). 무시 |
| busy, start = 0 | 영향 없음 |

- run 종료 e (RUN): busy인 첫 cycle 중 명령 FIFO가 비었고, `pim_core`에 진행 중인 것이 없고(컨트롤러 idle, y가 모두 core를 떠남, 마지막 write 명령이 engine에 넘어감), `axi_wr_eng`에 남은 명령이 없는(마지막 B를 받은 다음 cycle) cycle. run 중에 push한 명령도 같은 run이 실행한다. 빈 FIFO로 RUN하면 CYCLES = 1.
- FLUSH의 e: busy인 첫 cycle 중 FIFO가 빈 cycle(CYCLES = 버린 명령 수 + 1).
- done_sticky: e에 set(e + 1부터 보임), 같은 cycle의 CTRL clear가 이긴다. ERR: W1C, 같은 bit의 set과 clear가 겹치면 set이 남는다. RD_RESP/WR_RESP는 RRESP[1]/BRESP[1]인 beat/응답마다 set되고 데이터는 그대로 쓰인다(run은 끝까지 간다).
- 카운터: CYCLES = e - s. RD_STALL, WR_STALL은 busy cycle 중 조건이 참인 cycle만 센다.

### 4.3 PS 호출 순서
1. (초기화 1회) 행 레코드를 DDR에 만들고 flush. 행렬마다 LDW를 push(36개, FIFO가 차면 RUN 후 STATUS[23:8]을 보며 나머지를 push), `CTRL = 0x11`, done_sticky polling.
2. token마다: x를 쓰고 flush, WRGB/MACAB를 push(layer 하나 11개 또는 token 전체 57개를 FIFO 여유를 보며), `CTRL = 0x11`, done_sticky polling.
3. `ERR`(0이 아니면 W1C), `CYCLES`, `RD_STALL`, `WR_STALL`, 카운터. y를 invalidate.
- 잘못 넣은 명령은 `CTRL = 0x21`(FLUSH)로 버린다.

## 5. 구성

```
s_axi -> axil_slave -> pim_csr --(push)--> sync_fifo(32 x 128) --(cmd)--> pim_core
                            |                                    |  rd_cmd -> axi_rd_eng -> d stream -> pim_core
                            +-- start/busy/done, events -------- |  wr_cmd -> axi_wr_eng <- packer <- y stream
pim_core:
  pim_ctrl --- bank write port (LDW word, bank r mod 4) ---> pim_bank x 4 (ram_sdp 144 x 4096 + mac_row 16 lane + MAC_REG)
           --- MAC read (lock-step word, bank mask) -------> pim_bank x 4
           --- gb load / gb read --------------------------> pim_gb (2 x ram_sdp 64 x 64)  --x word--> 모든 bank
           --- gather (bank, xm, sh, last) --> mux(MAC_REG) --> gemv_scale --> y FIFO(sync_fifo 32 x 33)
```

- 읽기와 쓰기는 HP 포트 하나의 read/write 채널(`arch.md` 7.1).
- `pim_ctrl` 일정 규칙(MACAB):
  - round(행 4개, bank당 1행)의 nw word를 연속 cycle에 읽는다. 읽은 cycle t의 bank 데이터와 같은 cycle의 global buffer word가 t + 1에 `mac_row`에 들어간다.
  - round의 결과는 마지막 word를 읽은 cycle + `L_BANK`(= `pim_bank` LATENCY = 3 + DOT_PIPE, 기본 5)에 각 bank의 MAC_REG에 있고, 그 cycle부터 bank 0, 1, 2, 3 순서로 한 cycle에 하나씩 `gemv_scale`에 들어간다(gather).
  - 두 round의 마지막 word는 4(NB) cycle 이상 떨어진다(명령 경계 포함). 그래서 gather가 끝나기 전에 다음 round 결과가 MAC_REG를 덮지 않는다. nw >= 4면 round가 빈틈 없이 이어지고, nw < 4(n <= 48)면 round 하나가 4 cycle이다.
  - round 시작 때 그 round의 행 수만큼 y FIFO credit을 잡는다(잡은 수 - y FIFO에서 나간 수 + round 행 수 <= Y_DEPTH). y 쪽 backpressure는 이것으로만 처리하고 bank pipeline에는 backpressure가 없다.
  - MACAB는 앞 MACAB의 write 명령이 engine에 넘어간 뒤에 받는다. 컨트롤러는 MACAB의 마지막 word를 읽은 다음 cycle에 다음 명령을 받을 수 있다(gather와 scale은 뒤에서 이어진다. xm과 sh는 round마다 gather 쪽에 함께 넘어간다).
- `LDW`: 행 레코드 beat를 둘씩 묶어 word를 만든다(header beat의 wm, 열 >= n은 0, tag는 첫 word만). 마지막 행 뒤에 빈 slot을 0 word로 채운다(ceil(rows/4) x 4 - rows 행 x nw word, 한 cycle에 하나). 컨트롤러는 마지막 bank 쓰기의 다음 cycle에 idle.
- MAC_REG("double buffer", `arch.md` 3.2): `mac_row`의 누산기(다음 행을 바로 시작)와 그 뒤의 MAC_REG(행 끝에 latch, gather가 읽을 때까지 유지)의 두 단이다. 위의 round 간격 규칙이 있어 bank당 레지스터 하나로 충분하다.
- y 출력 FIFO는 `hierarchy.md` 1절의 "ram_sdp y buffer" 대신 `sync_fifo`(32 x 33: y + 명령의 마지막 표시)다. 깊이 32는 n = 64 행렬에서 credit이 처리율을 막지 않는 값이다(아래 측정에서 stall 없는 run의 credit 대기 0 cycle).
- 하위 모듈은 수정 없이 인스턴스만 했다.

## 6. cycle 식

### 6.1 `pim_core` (MACAB, 측정으로 확정)
기호: R = ceil(rows/4), nw = ceil(n/16), P = max(nw, 4), nvl = rows - 4 (R - 1)(마지막 round의 행 수), `L_BANK` = 3 + DOT_PIPE, `L_S` = SCALE_PIPE. 명령 handshake cycle을 0, 이전 round의 마지막 word cycle을 t_p라 하면

- 첫 word: t0 = max(1, t_p + 4 - (nw - 1))
- 마지막 word: t_l = t0 + (R - 1) P + nw - 1 (`done_mac`)
- 마지막 y가 core 출력에 valid: **C = t_l + L_BANK + nvl + L_S**
- 앞 MACAB에서 충분히 떨어진 경우(t0 = 1): **C_mac = (R - 1) P + nw + L_BANK + nvl + L_S**, nw >= 4이고 rows가 4의 배수이면 **C_mac = ceil(rows/4) x ceil(n/16) + 12**(기본 PIPE: L_BANK 5 + gather 4 + L_S 3). `arch.md` 3.4의 `L_rd + L_pipe + NB`가 이 12이다(read 1, mac_row 3, MAC_REG 1, scale 3, gather 4).
- 컨트롤러 점유(handshake부터 다음 명령을 받을 수 있는 cycle까지): (R - 1) P + nw + 1.

검증: `pim_core` TB(STALL=0)가 모든 MACAB의 마지막 y cycle을 위 식과 비교한다(260K 레코드 432개를 3 run: layer 순서, 레코드 순서, PIPE (0,0); 합성 838개: PIPE (2,3), (4,4)). `pim_ctrl` TB가 `done_mac` cycle을 같은 식으로 비교한다(NB 2, 4, 8, L_BANK 2, 5, 9).

### 6.2 token 합 [측정, Questa, 260K, 12 위치]
| 항목 | 값 | 비고 |
|---|---|---|
| sum ceil(rows/4) x ceil(n/16) | 4,072 / token | `arch.md` 3.4의 4,072와 같음 |
| 컨트롤러 MACAB 점유 합 | 4,108 / token | 4,072 + MACAB 36회 x 1 |
| `pim_top` run CYCLES 합, token 하나를 한 run(57 명령) | 4,501 ~ 4,506 | `axi_mem_slave` latency 1, stall 없음 |
| 같은 것, layer마다 한 run(6 run: layer 5 + cls) | 4,658 ~ 4,676 | run 시작/종료(마지막 B) 오버헤드가 run마다 붙음 |
| 같은 것, 레코드마다 WRGB + MACAB 한 run(36 run) | 약 6,950 | |
| LDW 36개(가중치 전체 적재) 한 run | 36,305 | 행 레코드 288,704 B = 36,088 beat + 오버헤드, 초기화 1회 |

- GEMV 가속기형 P = 1의 같은 260K token은 37,596 CYCLES(`gemv_acc.md` 5절, 같은 메모리 모델)다. 비율: MAC cycle만 36,446 / 4,072 = 8.95배(`arch.md` 3.4 [계산]), run CYCLES 37,596 / 4,504 = **8.35배**(token 한 run), 37,596 / 4,670 = 8.05배(layer마다 run) [측정, 시뮬레이션].
- 호출당 고정 항: token 한 run에서 MAC 외 432 cycle / token(WRGB 21회의 x 적재(8~22 beat + engine 왕복)와 MACAB 36회의 1 cycle, run 종료의 y 쓰기 꼬리). 보드의 DDR latency와 ARM 쪽 비용(push 4~5회 AXI-Lite 쓰기 x 57)은 포함되지 않았다.

### 6.3 `pim_top` MACAB 하나의 run (stall 없음, latency 1)
s 기준으로 행 r(round i = r div 4, bank b = r mod 4)의 y가 core 출력에 valid인 cycle은 `ty(r) = 2 + i P + nw - 1 + L_BANK + b + L_S + 1`(명령은 s + 1에 pop). y 쓰기는 `gemv_acc.md` 5절과 같은 규칙: beat j(행 2j, 2j+1)가 write buffer에 들어가는 시각 h_j = ty(min(2j + 1, rows - 1)) + 1, burst k(16 beat와 4 KiB로 나눔)의 첫 W = max(h_jk + 3, we_(k-1) + 1), 마지막 W = we_k. **CYCLES = we_last + 3**(마지막 B는 we_last + 2, write engine이 idle이 되는 다음 cycle이 e). TB(`+CYC`)가 단일 MACAB run 180개(PIPE 3종)에서 모두 일치를 확인했다.

## 7. 시뮬레이션 검증 (2026-11-19)
| test | 내용 | run |
|---|---|---|
| `pim_gb` | load 200~400회(n 1..NMAX, 경계값), 마지막 beat의 n 밖 garbage, beat gap, 모든 word를 random 순서로 읽어 x + 0과 비교, 작은 load가 이전 내용을 가림, busy/ready/done 시점, NMAX 1024/64/48, 진행 중 load(PIM_GB_LOAD) | 7 |
| `pim_bank` | 260K K_GEMV 레코드 432개 x bank 4개 image(`kd_rec_bimg`)를 random base에 쓰고 RAM == image(밖은 prefill 유지), bank의 모든 행 MAC: 행 합 == `k_dot8`, wm == m[r], 결과 cycle == 마지막 word + LATENCY. 합성(n 1..1024, 비첫 word tag와 n 밖 lane garbage, -128 x -127), DOT_PIPE 0/2/5, word gap | 7 |
| `pim_ctrl` | 참조 모델로 engine 명령, gb load, bank 쓰기(word, lane mask, tag, 빈 slot 0), MAC read(mask, word, first/last), gather(순서, last, xm, sh), 사건 수, busy/idle 비교; round 간격, gather 시점, y FIFO 모델 <= Y_DEPTH. LDW 36개 후 shadow bank == bank<b>.hex(bimg_pack, 4,072 word), 위 word 불변. STALL=0에서 `done_mac` cycle 식. NB 2/4/8, Y_DEPTH 4/8/32, L_BANK 2/5/9, YBLK(credit 대기 도달 요구), 잘못된 op(PIM_RANGE) | 14 |
| `pim_core` | 스트림 경계: LDW 36개 후 bank RAM == bank<b>.hex(위 word prefill 유지), 260K K_GEMV 432개 y mismatch 0(layer 순서: 같은 x 묶음 확인, 레코드 순서), 명령별 사건 수 == `bank_stat_t`(DPI `kd_rec_bank`), 합성(LDW/WRGB/MACAB 묶음, `kd_bank_syn`과 `kd_gemv1` 교차), read gap, wr_cmd 지연, y_ready random + YBLK(credit 도달), STALL=0 cycle 식, PIPE (0,0)/(4,4), Y_DEPTH 8 | 12 |
| `pim_csr` | 매 cycle random 쓰기/읽기와 사건을 spec 모델과 비교(읽기, start/busy/flush, push와 push data). coverage 요구: ERR 모든 bit, BAD_DESC 이유별 단독, LDW/WRGB/MACAB의 2^32 경계와 DEPTH 경계 수락, START_BUSY(bad op 포함), done cycle의 CTRL, W1C vs set, FLUSH. NB 8/DEPTH 1024, CMD_DEPTH 1 | 5 |
| `pim_top` | AXI-Lite BFM + `axi_mem_slave`. LDW run(FIFO를 채우고 run 중 push) 후 bank == image, 260K 432 레코드 y mismatch 0(MODE 0 layer별 run, 1 token별 run, 2 레코드별 run), y guard 16 B 불변, 카운터 == `bank_stat_t` 합, 매 cycle CSR 참조 모델(읽기, start, push 수락, FIFO level, pop된 명령 word, run 종료), CYCLES = e - s, RD_STALL/WR_STALL, AR/AW 범위. 합성 묶음(4 KiB 경계 주소), 단일 MACAB run의 CYCLES 식, ERR 원인별(BAD_CMD op 0/4/15, BAD_DESC 이유별, MISALIGN, BAD_OP, FIFO_OVF, FLUSH 후 실행 안 됨, START_BUSY, SLVERR/DECERR와 복구), CTRL in done cycle sweep, W1C vs set, WBLK/RBLK(write buffer full, y credit, read outstanding 한도 도달 요구), CMD_DEPTH 4, PIPE 3종, Y_DEPTH 8 + MAX_BURST 8 + OUTS 2 | 16 |

- mutation 29개(`sim/.mut5/m.py`): `pim_gb` 2, `pim_bank` 2, `pim_ctrl` 10, `pim_core` 3, `pim_csr` 3, `pim_top` 9. 동치가 아닌 28개 모두 검출(`sim/.mut5/res_first.txt`, `res.txt`). 살아남은 1개(`top_flush`: FIFO pop을 `core_cmd_ready`로만 함)는 동치다: FLUSH는 run이 끝난(core idle) 뒤에만 시작하므로 FLUSH 중 `core_cmd_ready`가 항상 1이다. 대신 FLUSH가 명령을 실행하게 하는 mutant(`top_flushexec`)를 추가해 검출했다.
- lint: `vlog -lint=full`, `vopt -lint=full`(6개 모듈 + `pim_top` PIPE (0,0), (4,4)) 경고 0.

## 8. 자원 관점 [계산, 합성 안 함]
- 곱셈기: bank당 int8 x int8 16개(`dotp` LANES 16) x 4 = 64, `gemv_scale` 3(25x17, 41x17을 24+17로 나눔) = 67개(`arch.md` 8절 67과 같음). int8 곱을 LUT로 두면 DSP는 3개다(Vivado의 판단 [미확인]).
- BRAM: bank 하나 = 144비트 x 4096 word = 589,824 비트 = BRAM36(512 x 72) 2개 폭 x 8개 깊이 = 16개, 4 bank 64개(`arch.md` 3.1). 144비트 중 tag 16비트가 두 BRAM36의 parity 비트(각 8비트)에 들어가야 64개가 된다. 추론형 `ram_sdp`가 parity를 데이터로 쓰도록 매핑되는지는 [미확인](`arch.md` D6, 안 되면 `fpga/` wrapper에서 RAMB36E1).
- 그 밖: `pim_gb` 64비트 x 64 word 두 개(1 KiB, LUTRAM 예상), 명령 FIFO 32 x 128(`sync_fifo`는 레지스터 배열 4,096비트; LUTRAM 추론 여부 [미확인]), y FIFO 32 x 33, AXI engine FIFO(rd 64 x 65, wr 32 x 64).
- 깊이 방향 mux: bank RAM 8개 깊이의 출력 mux와 gather 4:1 mux(41비트)가 `gemv_scale` 첫 곱셈 앞에 조합으로 있다. 100 MHz 타이밍 위험 [추정, 미측정].

## 9. 정한 세부와 확인하지 못한 것
- 이번에 정한 것: 명령 형식(2절), push 시점 검사와 FIFO_OVF, CTRL op 2 FLUSH, run 중 push 허용, 빈 FIFO RUN, ERR bit 배치, 누적 카운터와 CONFIG2, round 간격 규칙(nw < 4이면 round 4 cycle), y credit(Y_DEPTH 32), gather를 `pim_ctrl`이 순서 짓는 것, LDW zero-fill과 lane mask, gb의 n 밖 0, run 종료에 마지막 B 포함, y FIFO는 `sync_fifo`.
- RDROW(embedding 행 읽기)는 구현하지 않았다(op 4는 BAD_CMD). embedding은 ARM에 남는다.
- 보드: HP 포트 실측 latency, 100 MHz 타이밍, LUT 수, parity 비트 추론. 6.2절의 token cycle은 latency 1 메모리 모델 값이다.
- ARM 쪽 호출 비용(push 57회 x AXI-Lite 5회 쓰기)은 재지 않았다. 명령 FIFO가 이 비용을 없애지는 않는다(묶음으로 기다림만 줄인다).
