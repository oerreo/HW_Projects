# GEMV 가속기형 IP: `gemv_acc_top` (S4-4)

상태: RTL 시뮬레이션 통과(2026-11-19, `sim/tests/gemv_acc_top.cfg`, `gemv_acc_csr.cfg`, `argmax_red.cfg`), FPGA 미구성(G5 전). 구조 결정은 `arch.md` 2절(가중치 경로 D1, 행 레코드 D3, 병렬도 D2), 공통 레지스터 틀은 `arch.md` 7.2, engine 규칙은 `hierarchy.md` 3.6이 원본이다. 이 문서는 레지스터 맵, 호출 규칙, 내부 구성, cycle 식을 확정한다.

- RTL: `rtl/l3/gemv_acc_top.sv`(인스턴스, 배선, 호출 control), `rtl/l3/gemv_acc_csr.sv`(레지스터), `rtl/l0/argmax_red.sv`. 하위: `axil_slave`, `axi_rd_eng` x P, `axi_wr_eng`, `gemv_core` x P(S4-2, S4-3에서 단독 G4 통과, 이번에 수정 없음).
- 표기: cycle 수는 Questa 시뮬레이션(`axi_mem_slave` 모델)의 값이며 보드 값이 아니다.

## 1. 연산

한 번의 호출(call)은 descriptor(`W_ADDR`, `X_ADDR`, `Y_ADDR`, `ROWS`, `N`, `XM`, `EXP`, `FLAGS`)로

`y[r] = sat32(rshr(dot8(W[r], x) * wm[r] * xm, we + xe - fo))`, r = 0 .. ROWS - 1

을 계산한다(golden `k_gemv`, gs = n, 레코드 K_GEMV).

- 입력: `W_ADDR`의 행 레코드 배열(`arch.md` 2.2: 행 r은 `W_ADDR + r x RB`, `RB = 8 (1 + ceil(N/8))`, header beat의 [15:0] = wm, 가중치 padding은 0), `X_ADDR`의 int8 x[N](마지막 beat의 N 밖 byte는 무시).
- 출력: `FLAGS.y_en`이면 `Y_ADDR`에 int32 y[ROWS](little-endian, y[2k]는 64비트 beat의 [31:0]). `FLAGS.argmax_en`이면 y의 첫 최댓값의 index와 값(`ARGMAX_IDX`, `ARGMAX_VAL`, golden `k_argmax`: 엄격한 `>`일 때만 갱신). 둘 다 켤 수 있다. `y_en = 0`이면 y를 쓰지 않는다(분류기 융합, `arch.md` 2.5).

## 2. 레지스터 맵 (32비트, offset은 byte)

| offset | 이름 | 접근 | reset | 내용 |
|---|---|---|---|---|
| 0x00 | ID | R | 0x47410001 | [31:16] 0x4741("GA"), [15:0] 버전 1 |
| 0x04 | CONFIG | R | | [7:0] `FCLK_MHZ`, [11:8] `P`, [15:12] log2(LANES) = 3, [31:16] `NMAX`(1024) |
| 0x08 | CTRL | W | | bit0 start, [7:4] op(1 = GEMV). 읽으면 0 |
| 0x0C | STATUS | R | 0 | bit0 busy, bit1 done_sticky, bit2 err_any(ERR != 0) |
| 0x10 | ERR | R/W1C | 0 | bit0 START_BUSY, bit1 BAD_OP, bit2 BAD_DESC, bit3 MISALIGN, bit4 RD_RESP, bit5 WR_RESP |
| 0x14 | CYCLES | R | 0 | 마지막 호출의 cycle 수(4절) |
| 0x18 | RD_STALL | R | 0 | 같은 구간에서 어떤 slice의 core가 read beat를 받을 수 있는데 없던 cycle 수 |
| 0x1C | WR_STALL | R | 0 | 같은 구간에서 packer의 beat를 `axi_wr_eng`가 받지 못한 cycle 수(`axi_wr_eng` `stall_o`) |
| 0x20 | OPS | R | 0 | 끝난 호출 수 |
| 0x40 | W_ADDR | RW | 0 | 행 레코드 시작(8 B 정렬) |
| 0x44 | X_ADDR | RW | 0 | x 시작(8 B 정렬) |
| 0x48 | Y_ADDR | RW | 0 | y 시작(8 B 정렬, `y_en`일 때만 사용) |
| 0x4C | ROWS | RW | 0 | 32비트 그대로 저장. 유효 1 .. 2^`ROWS_W` - 1 (65535) |
| 0x50 | N | RW | 0 | 32비트 그대로 저장. 유효 1 .. `NMAX` |
| 0x54 | XM | RW | 0 | [16:0] 활성 scale 가수 |
| 0x58 | EXP | RW | 0 | [7:0] `we`, [15:8] `xe`, [23:16] `fo` (각 signed 8비트), [31:24] 읽으면 0 |
| 0x5C | FLAGS | RW | 0x2 | bit0 `argmax_en`, bit1 `y_en` |
| 0x60 | ARGMAX_IDX | R | 0 | [15:0] 마지막 argmax 호출의 index |
| 0x64 | ARGMAX_VAL | R | 0 | 그 최댓값(int32) |

- 정의되지 않은 주소(0x24..0x3C, 0x68..0xFC, 0x100 이상)는 0을 읽고 쓰기는 무시한다. 주소 bit[1:0]은 무시한다. WSTRB는 무시한다(모든 쓰기는 32비트 전체). 응답은 항상 OKAY(`axil_slave`). pqc-ntt-ip `l4_axi.md`의 확정 동작과 같다.
- ROWS와 N을 32비트 그대로 두는 이유: 필드 폭으로 잘라 저장하면 65536이 0으로, 0x10400이 1024로 보이는 aliasing이 생긴다. 범위 밖 값은 BAD_DESC로 거절한다.
- 읽기는 같은 cycle의 쓰기 전 상태를 본다.

## 3. 호출 규칙

CTRL 쓰기가 `axil_slave`에서 수행되는 cycle을 s라 한다. "idle"은 busy(검사 중 또는 호출 중)가 아니거나, 그 cycle이 호출이 끝나는 cycle(e)인 경우다(끝나는 cycle에 쓴 start는 수락된다, pqc 규칙).

S4-6b부터 descriptor 검사는 순차 계산이다(`W_ADDR + ROWS x RB`의 곱을 `umul_seq`로 구한다. 조합 곱셈기 없음). 판정 cycle은 **v = s + C_CHK**, `C_CHK = NBW + 1`, `NBW = bits(NMAX/8 + 2)`(곱셈기의 multiplier 폭, 기본 NMAX 1024에서 8, 그래서 **C_CHK = 9**). 판정 결과(어떤 descriptor가 BAD_DESC/MISALIGN인지)는 S4-4의 조합 검사와 bit 단위로 같고, 시점만 v로 옮겨졌다.

| 조건 (CTRL 쓰기) | 결과 |
|---|---|
| idle, start = 1, op = 1 | 수락. descriptor를 latch(s + 1부터 유효, 이후의 레지스터 쓰기는 이 호출에 영향 없음), done_sticky clear, CYCLES/RD_STALL/WR_STALL = 0, STATUS.busy = 1(s + 1부터). 검사는 s + 1 .. v |
| (수락된 호출의 v) descriptor 정상 | 시작. `start_o` = 1(cycle v), 호출은 v + 1부터 |
| (수락된 호출의 v) descriptor 오류 | 시작 안 함. BAD_DESC 그리고/또는 MISALIGN(독립적으로 set, v + 1부터 보임). STATUS.busy = 0(v + 1부터), done 없음, OPS 불변, CYCLES = C_CHK |
| idle, start = 1, op != 1 | BAD_OP만(cycle s). done_sticky 불변(pqc 규칙: 정의되지 않은 op는 아무것도 바꾸지 않음) |
| idle, start = 0 | done_sticky clear만 |
| busy(검사 중 또는 호출 중, 끝나는 cycle 아님), start = 1 | START_BUSY(op != 1이면 BAD_OP도). 무시. 판정 cycle v도 busy다 |
| busy, start = 0 | 영향 없음 |

- descriptor 오류: BAD_DESC = ROWS 0 또는 > 65535, N 0 또는 > NMAX, FLAGS[1:0] = 0, 쓰이는 버퍼가 2^32를 넘음(`W_ADDR + ROWS x RB`, `X_ADDR + N`, `y_en`이면 `Y_ADDR + 4 ROWS`). MISALIGN = `W_ADDR`, `X_ADDR`, (`y_en`이면) `Y_ADDR`의 [2:0] != 0. `y_en = 0`이면 `Y_ADDR`은 검사하지 않는다. 이 검사로 engine이 거절할 명령(정렬, 길이 0, 2^32 넘김)은 생기지 않는다(시뮬레이션 검사 `L3_ENGCMD`).
- done_sticky: 호출이 끝난 cycle e에 set(그 다음 cycle부터 보임), 위 표의 clear가 같은 cycle이면 clear가 이긴다.
- ERR: W1C. 같은 cycle에 같은 bit의 set과 clear가 겹치면 set이 남는다. RD_RESP/WR_RESP는 RRESP[1] 또는 BRESP[1]인 beat/응답마다 set(engine의 sticky가 아니라 AXI 포트의 handshake로 직접). 오류 응답이 있어도 데이터는 그대로 쓰이고 호출은 끝까지 간다.
- 호출 종료 e: 시작한 모든 slice의 `gemv_core`가 `done_o`(마지막 y 수락 다음 cycle)를 냈고, `y_en`이면 y 쓰기의 마지막 B handshake가 있었고, `argmax_en`이면 `argmax_red`가 `done_o`를 낸 첫 cycle. STATUS.busy = 1은 s + 1 .. e(검사 포함), `busy_o`(top으로 가는 호출 상태)는 v + 1 .. e, done_sticky와 OPS 증가는 e + 1부터 보인다.
- 카운터: CYCLES는 수락(s)부터 센 busy cycle 수 = e - s(검사 C_CHK 포함). RD_STALL, WR_STALL도 같은 구간에서 조건이 참인 cycle만 센다. 검사에서 거절된 호출은 CYCLES = C_CHK. 32비트에서 wrap.

### PS 호출 순서 (`arch.md` 7.3)
1. x를 쓰고 `Xil_DCacheFlushRange(x, N)`. (행 레코드는 초기화 때 한 번.)
2. `X_ADDR`, `W_ADDR`, `Y_ADDR`, `ROWS`, `N`, `XM`, `EXP`, `FLAGS` 중 바뀐 것을 쓴다. 이전 호출이 도는 중에 써도 된다(진행 중인 호출은 latch한 값을 쓴다).
3. `CTRL = 0x11`.
4. `STATUS` polling: busy = 0이 될 때까지(검사 C_CHK cycle을 포함). 그 뒤 done_sticky = 1이면 정상 종료, 아니면 ERR(BAD_DESC/MISALIGN)을 본다. 검사 판정은 s + C_CHK + 1부터 보이므로 CTRL 직후의 ERR 읽기로 판단하지 않는다.
5. `ERR`(0이 아니면 W1C), `CYCLES`, `RD_STALL`, `WR_STALL`, (`argmax_en`이면) `ARGMAX_IDX`, `ARGMAX_VAL`.
6. `y_en`이면 `Xil_DCacheInvalidateRange(y, 4 ROWS)`.

## 4. 구성

```
s_axi -> axil_slave -> gemv_acc_csr --(start, latched descriptor, done)--+
                                                                         |
slice p (p < P, HP 포트 p, read 전용):                                   |
  명령 순서기: x (X_ADDR, N B) -> 행 레코드                               |
     P = 1: 명령 1개 (W_ADDR, ROWS x RB)                                   |
     P = 2: 행마다 명령 1개 (W_ADDR + r RB, RB), r = p, p + 2, ...         |
  axi_rd_eng -> router (x 명령의 마지막 beat까지 x 포트, 그 뒤 w 포트) -> gemv_core
y merge (행 순서: 행 r은 slice r mod P) -> argmax_red (argmax_en)
                                       -> packer (y 2개 -> 64비트) -> axi_wr_eng (포트 0, Y_ADDR, 4 ROWS B)
```

- P = 2이면 slice p는 ceil((ROWS - p)/2)행을 계산한다. 행이 없는 slice(ROWS = 1의 slice 1)는 시작하지 않는다. x는 두 포트가 각자 읽는다(N B, 무시할 만한 중복).
- P = 2의 행 단위 명령: 두 포트가 행 레코드를 교대로 가져가려면 주소가 `2 RB` 간격으로 띄엄띄엄이다. 한 명령으로 묶을 수 없어 행마다 명령을 낸다. `axi_rd_eng`는 명령 하나에 (burst 수 + 1) cycle의 AR 발행 시간이 들어, `ceil(N/8) = 1`(행 2 beat)이고 행 레코드가 4 KiB 경계에 걸쳐 burst 2개가 되면 그 slice가 1 cycle 늦어진다(5절 식에 포함).
- packer: 홀수 ROWS의 마지막 beat는 y 하나([31:0], [63:32]는 0)이고, 쓰기 명령 길이가 4 ROWS라 engine이 그 beat의 WSTRB를 0x0F로 낸다(`hierarchy.md` 3.6). y 뒤 4 byte는 바뀌지 않는다(TB guard로 확인).
- `y_en = 0`이면 merge가 기다리지 않고 y를 버린다(argmax만).
- 하위 모듈은 수정 없이 인스턴스만 했다. top이 직접 하는 것은 명령 순서기, router, merge, packer, 종료 판정, 오류/stall event다.

## 5. CYCLES 식 (메모리 stall 없음, read latency 1, B latency 1, `MAX_BURST` = 16, `OUTS` = 4, 기본 PIPE)

기호: `nb = ceil(N/8)`, `R = 1 + nb`(행 레코드 beat 수). 아래 1~6의 시각은 판정 cycle v 기준이고(S4-4의 s 기준 식과 같다), **CYCLES = C_CHK + (v 기준 식)**이다(C_CHK = 9, NMAX 1024). S4-6b의 측정값은 모든 호출에서 S4-4 값 + 9였다(아래 표).

1. read 쪽. engine 명령 하나는 (burst 수 + 1) cycle의 AR 발행 시간이 들고 데이터는 1 beat/cycle로 온다.
   - x 명령이 `mx` burst(보통 1, x가 4 KiB에 걸치면 2)이면 행 레코드 데이터가 `Xd = max(0, mx + 1 - nb)` cycle 늦게 시작한다(nb = 1이면 항상 1).
   - P = 2: slice의 행 명령이 `mr` burst이면 그 slice의 다음 행들이 `max(0, mr - nb)` 늦어진다.
2. y 준비 시각: slice p의 k번째 행 = `Y0 + k R + (그 slice의 앞선 지연 합)`, `Y0 = nb + R + 14 + Xd`. 14 = start 등록 1 + 명령 제시 1 + AR/R 왕복과 engine FIFO + `gemv_core`의 `L_PIPE`(기본 9) 등이다(분해는 측정에서 확인하지 않았다).
3. merge: `t(r) = max(준비(r), t(r - 1) + 1)`(P = 1이면 `t(r) = Y0 + r R`).
4. `y_en = 0`: `CYCLES = C_CHK + t(ROWS - 1) + 1`. P = 1이면 닫힌 식 `CYCLES = nb + ROWS x (1 + nb) + 15 + Xd + C_CHK`.
5. `y_en = 1`: beat j(행 2j, 2j + 1)가 write buffer에 들어가는 시각 `h_j = t(min(2j + 1, ROWS - 1)) + 1`. y 쓰기 burst k(L_k beat, `Y_ADDR`에서 16 beat와 4 KiB로 나눔, 마지막 beat j_k)의 첫 W = `ws_k = max(h_jk + 3, we_(k-1) + 1)`, 마지막 W = `we_k = ws_k + L_k - 1`. `CYCLES = C_CHK + we_last + 2`.
   - 마지막 burst가 앞 burst의 W에 막히지 않으면(보통) `CYCLES = C_CHK + t(ROWS - 1) + 5 + L_last`. P = 1이면 `nb + ROWS x (1 + nb) + 19 + Xd + L_last + C_CHK`.
   - 막히는 예: 16 beat burst 바로 뒤에 4 KiB 경계로 1 beat burst가 남으면 마지막 W가 앞 burst의 16 beat 뒤로 밀린다(측정에서 +8 cycle 사례).
6. P = 2: ROWS가 짝수이면 마지막 행이 slice 1에서 나와 merge가 1 cycle 뒤에 받는다(3번 식에 포함). 닫힌 식은 `ceil(ROWS/2)`를 쓴다.

이 식은 TB(`tb_gemv_acc_top.sv`의 `cyc_formula`)가 호출마다 계산해 CYCLES와 비교한다(`+CYC=1` run, 아래 6절). `arch.md` 2.4의 `C_gemv = ceil(n/8) + ceil(rows/P) x (1 + ceil(n/8)) + L_dram + L_pipe`와 비교하면 고정 항 15(또는 19 + L_last)가 `L_dram + L_pipe`에 해당하고, 여기에 x 명령 전환(Xd)과 y 쓰기 꼬리가 더해진다.

### 측정값 [측정, Questa, `axi_mem_slave` stall 없음 latency 1, P = 1, 보드 아님]
| 호출 | CYCLES | 비고 |
|---|---|---|
| 15M 분류기 32000 x 288, y_en = 1, argmax_en = 1 | 1,184,069 ~ 1,184,077 (S4-6: 1,184,061 ~ 1,184,064) | `arch.md` 2.4 표의 1,184,000 + 고정 항 + 꼬리 + C_CHK |
| 같은 호출 y_en = 0 | 1,184,060 (S4-6: 1,184,051) | 정확히 + 9 |
| 15M token 하나(43 호출 합) | 1,951,992 (`q_p1_m2tok`, 1 위치; S4-6 같은 run 1,951,620) | `arch.md` 2.4 표 1,950,260 + 호출당 약 40 |
| 260K token 하나(36 호출 합, 12 위치) | P = 1: 37,903 ~ 37,938 (S4-6: 37,560 ~ 37,616), P = 2: 19,895 ~ 19,930 (S4-6: 19,565 ~ 19,603) | 표 36,446 / 18,402 + 호출당 고정 항 |

- S4-6b 차이: 호출마다 C_CHK = 9가 붙어 y_en = 0 호출은 정확히 +9, token(36 호출)은 +324가 기준이다. y_en = 1 호출은 TB의 무작위 Y_ADDR(AXI-Lite BFM과 같은 난수열을 써서 polling 횟수가 바뀌면 값이 밀림)에 따라 y burst의 4 KiB/16 beat 분할이 달라져 호출당 몇 cycle씩 다르다. 모든 호출에서 CYCLES == 5절 식(C_CHK 포함)을 `+CYC=1` run이 확인했다(P = 1, 2 각 444 호출).

- 호출당 고정 항(15 + Xd, y_en이면 19 + Xd + L_last)이 `arch.md` 2.4의 `L_dram + L_pipe`에 해당하고 latency 1 모델 기준이다. 실제 DDR latency와 대역폭(eta)은 `bwtest.md`의 보드 측정 전까지 모른다.
- RD_STALL: stall 없는 모델에서 호출당 5(x를 기다리는 시작 구간), P = 2 + stall 프로파일 1에서는 15M 분류기 268,510 cycle(메모리 stall이 그대로 보임).

## 6. 시뮬레이션 검증 (2026-11-19)

| test | 내용 | run |
|---|---|---|
| `argmax_red` | K_ARGMAX 레코드 전부(260K 12, 15M 6, 기록 idx와 kd_argmax 둘 다), random 스트림(n = 1, 2, 3, 2^IDX_W 포함, 동일값/극값/단조/양끝 tie), valid gap, 연속 스트림, 끝나지 않은 스트림의 재시작, IDX_W 16/4/1, L0_SEQ/L0_RANGE 부정 시험, 잘못된 parameter | 9 |
| `gemv_acc_csr` | 단독. 매 cycle random 쓰기/읽기 strobe와 random event를 spec 모델과 매 cycle 비교(읽기 값, start, busy, latch된 op 출력, 판정 cycle부터 `op_wbytes_o`). START_BUSY(잘못된 op 포함, S4-6b: 검사 중 포함), done cycle의 CTRL(start 0/1), W1C와 set 충돌, ERR 모든 bit, 2^32에 딱 맞는 버퍼(W/X/Y)와 8 B 넘는 버퍼(S4-6b), 검사 중 descriptor 쓰기로 레지스터 판정이 달라진 경우(S4-6b) 발생을 세어 요구 | 5 |
| `gemv_acc_top` | AXI-Lite BFM + 포트별 `axi_mem_slave`. 두 모델 K_GEMV 레코드 전부(분류기 포함, 분류기는 y_en = 0으로 한 번 더, K_ARGMAX 레코드와 index 대조), 합성 호출 random(n 1..1024, rows 1..600, 홀수, tie, 4 KiB 경계 직전 주소, FLAGS 조합, 이전 호출 중 descriptor 쓰기), y 메모리와 guard, AW/AR 주소 범위(P = 2는 slice별 행), 포트별 R beat 수, CYCLES = e - s(버스 관측), `+CYC=1`에서 5절 식, RD_STALL/WR_STALL(TB 독립 계수), 매 cycle CSR 참조 모델, ERR 원인별과 복구, done cycle 충돌, 긴 write/read 차단(write buffer full, `gemv_core` credit, read space, read buffer full 도달 요구), P = 1/2, PIPE (0,0)/(4,4), MAX_BURST 8 / OUTS 2 | 22 |

- mutation 24개(`sim/.mut4/m.py`): `argmax_red` 3, `gemv_acc_csr` 8, top 13(홀수 ROWS 마지막 beat WSTRB, 마지막 반쪽 beat 누락, argmax tie, y 주소, 포트 1 RRESP, merge slice 순서, slice 행 주소, 행 분배, router, RD_STALL 정의, done 시점, argmax_en gating, 행 없는 slice 시작). 24개 모두 검출. 처음 실행에서 살아남은 2개는 TB 공백이었다: 2^32에 딱 맞는 버퍼(CSR TB에 경계 주소 추가), 포트 1에만 있는 read 오류(top TB에 호출 추가).
- lint: `vlog -lint=full`, `vopt -lint=full`(top P = 1, 2, csr, argmax_red) 경고 0.
- S4-6b(2026-11-20): `gemv_acc_csr`의 W 범위 곱을 `umul_seq`로 바꾼 뒤 `gemv_acc_csr` 5 run, `gemv_acc_top` 23 run을 다시 통과했다(CSR 참조 모델과 `cyc_formula`는 3, 5절의 새 규칙으로 고침). mutation 5개(`sim/.mut6b/m.py`의 `gcsr_*`)와 lint는 `attn.md` 7절의 S4-6b 항목.

## 6b. 자원 관찰 (S4-6b) [계산, 합성 안 함]
- runtime 곱셈기: S4-4의 `wbytes = ROWS x (1 + ceil(N/8)) x 8`(16 x 8비트 조합 곱)을 `umul_seq`(A 16, B 8: 16비트 덧셈기 하나 + 약 40 FF + 4비트 카운터)로 바꿨다. 남은 곱은 `gemv_acc_top`의 `P x RB`(P는 parameter 1 또는 2, 상수 곱 = shift)뿐이다.
- 대가: 호출마다 C_CHK = 9 cycle(3절). 260K token(36 호출)에서 324 cycle, 37,596의 0.9% [계산].

## 7. 확인하지 못한 것
- 보드: HP 포트 실측 latency와 대역폭, 100 MHz 타이밍, LUT 수. FPGA 준비물(`fpga/`)은 이 단계 범위 밖이다.
- 5절 식은 stall 없는 모델(latency 1)과 기본 parameter(MAX_BURST 16, OUTS 4, 기본 PIPE)에서만 확인했다. 다른 PIPE에서는 `L_PIPE`만큼 상수가 바뀐다고 추정하나 식 검사는 하지 않았다.
- P = 2의 15M 전체 레코드는 stall 프로파일 1에서만 돌려 stall 없는 CYCLES는 재지 않았다.
- `y_en`과 `argmax_en`이 모두 0인 호출은 BAD_DESC로 막았다(읽기 대역폭만 재는 용도는 `bw_top`).
