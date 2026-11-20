# L3 gemv_acc_top: GEMV 가속기형 IP

- 원본과 확인일: 확인일 2026-11-19, S4-6b 반영 2026-11-20(검사 구간, 호출 timeline, CYCLES). `rtl/l3/gemv_acc_top.sv`, `rtl/l3/gemv_acc_csr.sv`, `rtl/l0/argmax_red.sv`, `rtl/l0/umul_seq.sv`. 레지스터 맵, 호출 규칙, CYCLES 식의 원본은 `docs/spec/gemv_acc.md`(이 문서는 요약이고 충돌하면 gemv_acc.md와 RTL이 우선), 계층 관점의 고정 사항은 `docs/spec/hierarchy.md` 3.7.
- 상태: RTL 시뮬레이션 통과(`log.md` S4-4: `./sim/run.sh all` 201 run, fails 0 [측정, 수퍼바이저 재실행]). S4-6b에서 `gemv_acc_csr`의 W 범위 곱을 `umul_seq`로 바꾼 뒤 재통과(`./sim/run.sh all` 368 run, fails 0 [측정, 수퍼바이저 재실행]). **보드는 미실행**이고 100 MHz 타이밍, LUT 수는 확인하지 않았다.
- 폭 표기: 기본 parameter(`P` 1 또는 2, `MAX_BURST` 16, `OUTS` 4, `RD_FIFO` 64, `WR_FIFO` 32, `NMAX` 1024, `ROWS_W` 16, `IDX_W` 16, `ADDR_W` 12, `DOT_PIPE` 2, `SCALE_PIPE` 3, `Y_DEPTH` 16). AXI master 주소 32비트, 데이터 64비트.
- 파형은 그리지 않았다(호출 timeline은 RTL 헤더 주석과 코드의 cycle 정의를 옮긴 표).
- **S4-6b 변경(이 문서의 갱신 범위)**: CTRL 수락(s) 뒤에 descriptor 검사 구간이 생겼다. `gemv_acc_csr`가 `umul_seq`(`u_wmul`, `ROWS` x (1 + ceil(`N`/8)))로 W 범위를 순차 계산해 판정 cycle v = s + `C_CHK`(`C_CHK` = `NBW` + 1, `NMAX` 1024에서 9)에 `start_o`를 낸다. 그 밖의 구조(slice, merge, packer, 종료 판정)는 바뀌지 않았다.
- 이 모듈은 인스턴스, 배선, 호출 control(명령 순서기, router, merge, packer, 종료 판정)이다. 연산은 `gemv_core`, AXI 동작은 engine이 한다.

## 1. block diagram

```mermaid
flowchart LR
    ps["PS7 M_AXI_GP0<br/>AXI4-Lite (ADDR_W 12, 32b)"]:::ext
    axil["u_axil: axil_slave<br/>wr_en, wr_addr, wr_data<br/>rd_en, rd_addr, rd_data"]:::mod
    csr["u_csr: gemv_acc_csr<br/>start_o (cycle v = s + C_CHK), busy_o, done_i<br/>u_wmul: umul_seq (ROWS_W 16 x NBW 8) -> wprod<br/>latched op_*: w_addr, x_addr, y_addr 32b,<br/>rows ROWS_W 16b, n NW 11b, xm AM_W 17b,<br/>we, xe, fo E_W 8b signed, am_en, y_en, wbytes WB_W"]:::mod

    subgraph sl["slice p (p < P, generate g_slice[p])"]
        seq["명령 순서기<br/>xpend_q, wleft_q ROWS_W, wa_q 32b,<br/>xph_q, fin_q"]:::cut
        rd["u_rd: axi_rd_eng<br/>AW 32, LEN_W 32, IDW, FIFO_DEPTH = RD_FIFO<br/>cfg_burst_i, cfg_outs_i = 0 (기본 한도)"]:::mod
        rt["router<br/>x_valid = d_valid && xph_q<br/>w_valid = d_valid && !xph_q"]:::logic
        core["u_core: gemv_core<br/>LANES 8, NMAX, ROWS_W<br/>start_i = start_q && act_p<br/>x port / w port 64b, y stream 32b"]:::mod
    end

    hp_r["m_axi_ar/r[p]<br/>HP 포트 p (read 전용)"]:::ext

    mg["y merge<br/>sel_q SW, yrow_q ROWS_W<br/>m_valid, m_data 32b, m_first, m_last"]:::cut
    am["u_am: argmax_red<br/>IDX_W 16<br/>valid_i = m_hs && am_en"]:::mod
    pk["packer<br/>half_q, lo_q 32b,<br/>pk_valid_q, pk_data_q 64b"]:::cut
    wr["u_wr: axi_wr_eng<br/>AW 32, LEN_W 32, FIFO_DEPTH = WR_FIFO<br/>cmd_bytes = {rows, 2'b00}"]:::mod
    hp_w["m_axi_aw/w/b<br/>포트 0 (y 쓰기 전용)"]:::ext
    done["종료 판정<br/>all_done = busy && (&core_fin_now)<br/>&& (wr_fin_q || wr_done)<br/>&& (am_fin_q || am_done)"]:::logic

    ps --> axil
    axil -->|"wr_en, wr_addr, wr_data"| csr
    csr -->|"rd_data"| axil
    csr -->|"start (cycle v), op_* (s + 1부터), op_wbytes (v부터)"| seq
    csr -->|"op_*, start_q (v + 1)"| core
    seq -->|"cmd_valid, cmd_addr 32b, cmd_bytes 32b"| rd
    rd <--> hp_r
    rd -->|"d_valid, d_data 64b, d_last"| rt
    rt -->|"x_valid / w_valid, d_data"| core
    core -->|"y_valid, y_data 32b"| mg
    mg -->|"m_data 32b"| am
    mg -->|"m_data 32b"| pk
    pk -->|"in_valid, in_data 64b"| wr
    wr <--> hp_w
    am -->|"am_done, am_idx 16b, am_max 32b signed"| csr
    core -->|"core_done"| done
    wr -->|"wr_done"| done
    am -->|"am_done"| done
    done -->|"all_done -> done_i"| csr
    rd -.->|"rd_err_ev (RRESP[1]), rd_stall_ev"| csr
    wr -.->|"wr_err_ev (BRESP[1]), wr_stall_ev"| csr

    classDef ext fill:#ffffff,stroke:#333333,color:#000
    classDef mod fill:#d8f0d8,stroke:#2e7d32,stroke-width:2px,color:#000
    classDef logic fill:#e3eefc,stroke:#3b6aa0,stroke-width:2px,color:#000
    classDef cut fill:#fff3c4,stroke:#b58900,stroke-width:2px,color:#000
```

- 초록 = 하위 모듈 인스턴스, 파랑 = 조합 논리, 노랑 = 레지스터.
- `P` parameter: 1 또는 2(그 밖은 elaboration `$error`). `IDX_W >= ROWS_W`도 elaboration에서 검사한다. 이 외의 parameter는 하위 인스턴스가 검사한다.
- slice는 `generate for (p < P)`로 `u_rd`, `u_core`, 순서기를 복제한다. AXI read master 포트는 `[P-1:0]` packed 배열(`m_axi_ar*_o[p]`)이고 write master는 하나(포트 0)다.
- `u_rd`, `u_wr`의 `err_clr_i`는 `start`에 묶여 있다. `cfg_burst_i`/`cfg_outs_i`는 0이라 engine의 `MAX_BURST`/`OUTS`가 그대로 한도다.
- 행 레코드 크기 `rb = 8 (1 + ceil(N/8))` byte는 top의 조합 논리로 계산한다(폭 `NBW + 3`, `NBW = clog2(NMAX/8 + 2)`).
- 이 문서에 확인하지 않은 구조는 그리지 않았다. `axil_slave`, `axi_rd_eng`, `axi_wr_eng`, `gemv_core` 내부는 각각 `l1_axi_eng.md`, `l2_gemv_core.md`를 본다.

## 2. data flow

### 2.1 read 쪽: x와 행 레코드가 core로 가는 경로

```mermaid
flowchart LR
    c1["x 명령<br/>addr = X_ADDR, bytes = N"]:::cut
    c2["행 레코드 명령<br/>P = 1: (W_ADDR, wbytes = ROWS x RB) 1개<br/>P = 2: (wa_q, RB), wa_q += P x RB, rows_p개"]:::cut
    rde["axi_rd_eng<br/>d_data 64b, d_last"]:::mod
    xph{"xph_q ?"}:::logic
    xp["gemv_core x port<br/>x_data_i 64b<br/>(LOADX 단계만 수락)"]:::mod
    wp["gemv_core w port<br/>w_data_i 64b<br/>(header beat + ceil(N/8) beat)"]:::mod

    c1 -->|"먼저"| rde
    c2 -->|"x 명령 다음"| rde
    rde --> xph
    xph -->|"1: x_valid = d_valid"| xp
    xph -->|"0: w_valid = d_valid"| wp
    xp -.->|"x_ready"| rde
    wp -.->|"w_ready"| rde

    classDef mod fill:#d8f0d8,stroke:#2e7d32,stroke-width:2px,color:#000
    classDef logic fill:#e3eefc,stroke:#3b6aa0,stroke-width:2px,color:#000
    classDef cut fill:#fff3c4,stroke:#b58900,stroke-width:2px,color:#000
```

- `xph_q`: `start_q`에서 `act_p`로 set, `d_hs && d_last && xph_q`(x 명령의 마지막 beat 수락)에서 clear. `d_ready = xph_q ? x_ready : w_ready`. 즉 x 명령의 데이터가 끝난 뒤에 오는 모든 beat는 w port로 간다.
- P = 2의 행 분배: slice p는 `rows_p = (rows + (P - 1 - p)) >> 1`행을 맡는다(행 r, r mod 2 = p). `wa_q`의 초기값은 `w_addr + (p == 0 ? 0 : rb)`이고 명령마다 `P x rb`씩 증가한다. 행이 없는 slice(`rows_p = 0`, ROWS = 1의 slice 1)는 `act_p = 0`이라 core를 시작하지 않고 `fin_q`가 바로 1이다.
- P = 1은 `wleft_q`가 1이고 `cmd_bytes = wbytes`, P = 2는 `wleft_q = rows_p`이고 `cmd_bytes = rb`.

### 2.2 y 쪽: merge, packer, write

```mermaid
flowchart LR
    y0["slice 0 y_data 32b"]:::mod
    y1["slice 1 y_data 32b<br/>(P = 2만)"]:::mod
    mg{"sel_q: 다음 행의 slice<br/>(행 r은 slice r mod P)"}:::logic
    mh["m_hs = m_valid && m_ready<br/>yrow_q += 1, sel_q 순환<br/>m_first = (yrow_q == 0)<br/>m_last = (yrow_q == rows - 1)"]:::cut
    am["argmax_red (am_en)<br/>idx_o 16b, max_o 32b"]:::mod
    half{"half_q ?"}:::logic
    lo["lo_q <= m_data<br/>(m_hs && !half_q)"]:::cut
    emit["emit = m_hs && y_en<br/>&& (half_q || m_last)<br/>pk_data_q <= half_q ? {m_data, lo_q}<br/>: {32'd0, m_data}"]:::cut
    wr["axi_wr_eng<br/>in_data 64b, cmd_bytes = 4 x ROWS<br/>y[2k] = [31:0], y[2k+1] = [63:32]"]:::mod

    y0 --> mg
    y1 --> mg
    mg --> mh
    mh -->|"m_data 32b"| am
    mh --> half
    half -->|"0: 앞 반쪽 보관"| lo
    half -->|"1 또는 m_last: beat 완성"| emit
    lo --> emit
    emit -->|"pk_valid_q"| wr
    wr -.->|"in_ready -> pk_ready -> m_ready"| mh

    classDef mod fill:#d8f0d8,stroke:#2e7d32,stroke-width:2px,color:#000
    classDef logic fill:#e3eefc,stroke:#3b6aa0,stroke-width:2px,color:#000
    classDef cut fill:#fff3c4,stroke:#b58900,stroke-width:2px,color:#000
```

- `m_ready = !y_en || pk_ready`: `y_en = 0`이면 merge가 기다리지 않고 y를 버린다(argmax만).
- `pk_ready = !pk_valid_q || wr_in_ready`. packer는 beat 하나를 레지스터에 두고 engine이 받으면 비운다.
- `half_q`는 `m_hs && y_en`마다 `!half_q && !m_last`로 갱신된다(홀수 ROWS의 마지막 행이면 `m_last`로 emit하고 half_q는 0으로 남는다). 이때 beat는 `{32'd0, m_data}`이고 write 명령 길이가 `4 ROWS` byte라 `axi_wr_eng`가 그 beat의 WSTRB를 0x0F로 낸다(`hierarchy.md` 3.6).
- `argmax_red`는 `valid_i = m_hs && am_en`으로 merge된 y 스트림(행 순서)을 받는다. `ARGMAX_IDX`/`ARGMAX_VAL`은 `am_done`에서 CSR이 받는다.

## 3. control flow

### 3.1 호출 timeline (RTL 헤더 주석과 코드의 cycle 정의, S4-6b)

CTRL 쓰기가 수행되는 cycle을 s, 판정 cycle을 v = s + `C_CHK`라 한다(`C_CHK` = `NBW` + 1, `NBW` = clog2(`NMAX`/8 + 2), `NMAX` 1024에서 8이라 9). 표는 RTL의 레지스터 갱신 조건에서 도출한 것이며 파형을 그린 것이 아니다.

| cycle | 일어나는 일 | 근거 |
|---|---|---|
| s | `u_csr`의 `acc` = start && idle && op 1. descriptor가 `op_*`로 latch됨(유효는 s + 1부터). `u_wmul` 시작(`start_i(acc)`), `chk_q` <= 1, done_sticky clear, CYCLES/RD_STALL/WR_STALL clear. 레지스터의 값으로 정한 항(`pre_ok`: ROWS, N, FLAGS, X/Y 범위)과 정렬(`align_ok`)은 s에 구해 보관 | `gemv_acc_csr.sv` `acc` |
| s + 1 .. v - 1 | 검사 구간. STATUS.busy = 1(s + 1부터), 이 구간의 CTRL start는 START_BUSY | `chk_q`, `idle` |
| v | `verdict`. 정상이면 `start_o` = `start` = 1, 오류면 start 없이 BAD_DESC 그리고/또는 MISALIGN(v + 1부터 보임), STATUS.busy = 0(v + 1부터), CYCLES = `C_CHK`. 정상이면 `gemv_acc_top`의 순서기와 종료 flag 초기화(`if (start)`: `xpend_q`, `wleft_q`, `xph_q`, `wcmd_q` = 0, `fin_q`, `wr_fin_q`, `am_fin_q` = 0). `op_wbytes_o`가 이 cycle부터 유효. engine의 `err_clr_i` = `start` | `gemv_acc_top.sv` `if (start)` |
| v + 1 (`start_q` = 1) | `gemv_core`에 `start_i = start_q && act_p`. 순서기 적재: `xpend_q <= act_p`, `wleft_q <= (P == 1) ? act_p : rows_p`, `xph_q <= act_p`, `fin_q <= !act_p`. 쓰기 쪽: `wcmd_q <= y_en`, `wr_fin_q <= !y_en`, `am_fin_q <= !am_en`. merge의 `sel_q`, `yrow_q`, packer의 `half_q` 초기화. `wa_q <= w_addr + (p == 0 ? 0 : rb)`. `busy_o` = 1(v + 1부터) | `start_q` 분기 |
| v + 2 이후 | read 명령 제시(`cmd_valid`): x 명령, 이어서 행 레코드 명령. `axi_rd_eng`가 AR을 낸다(명령 handshake c -> ARVALID c + 2). write 명령(`wcmd_q`)은 `y_addr`, `4 ROWS`로 제시 | RTL 헤더 "read and write commands are presented from v + 2" |
| 진행 | read stream -> router -> core, y -> merge -> (argmax, packer) -> `axi_wr_eng` | 2절 |
| e | `all_done` = 1. STATUS.busy = 1은 s + 1 .. e(검사 포함), `busy_o`(top으로 가는 호출 상태)는 v + 1 .. e. `done_sticky`와 OPS 증가는 e + 1부터 보임 | `gemv_acc.md` 3절 |

CYCLES = e - s(`u_csr`가 `chk_q || busy_q`인 cycle을 센다). 검사에서 거절된 호출은 CYCLES = `C_CHK`.

### 3.2 명령 순서기와 read stream 단계 (slice p)

```mermaid
stateDiagram-v2
    [*] --> IDLE: rst_n (fin_q = 1)
    IDLE --> LOAD: start (cycle v, fin_q = 0)
    LOAD --> XCMD: start_q && act_p<br/>(xpend_q = 1, wleft_q, xph_q = 1)
    LOAD --> FIN: start_q && !act_p<br/>(fin_q = 1, 행 없는 slice)
    XCMD --> WCMD: x 명령 handshake<br/>(xpend_q = 0)
    WCMD --> WCMD: 행 레코드 명령 handshake<br/>(wleft_q -= 1)
    WCMD --> RUNW: wleft_q = 0
    RUNW --> FIN: core_done<br/>(fin_q = 1)
    FIN --> [*]
```

- 이 그림은 레지스터 조합(`xpend_q`, `wleft_q`, `xph_q`, `fin_q`)을 단계 이름으로 묶은 것이다. RTL에 FSM state 레지스터는 없다. CTRL 수락 s부터 판정 v까지는 `u_csr`의 검사 구간이고 순서기는 `start`(cycle v)에서 시작한다.
- read stream 쪽 `xph_q`는 x 명령의 마지막 beat 수락에서 내려가며 명령 순서기의 진행과 독립이다. 두 흐름은 병행해서 진행한다(x 데이터가 core로 가는 동안 행 레코드 명령도 제시될 수 있다). 그림의 단계 이름(`XCMD`, `WCMD`, `RUNW`)은 설명용이고 RTL 신호 이름이 아니다.

### 3.3 완료 조건

```mermaid
flowchart TD
    c1["core_fin_now[p] = fin_q[p] || core_done[p]<br/>모든 slice 만족 (&core_fin_now)"]:::logic
    c2["wr_fin_q || wr_done<br/>(y_en = 0이면 wr_fin_q = 1로 시작)"]:::logic
    c3["am_fin_q || am_done<br/>(am_en = 0이면 am_fin_q = 1로 시작)"]:::logic
    b["busy"]:::logic
    ad["all_done -> u_csr done_i (cycle e)"]:::cut

    b --> ad
    c1 --> ad
    c2 --> ad
    c3 --> ad

    classDef logic fill:#e3eefc,stroke:#3b6aa0,stroke-width:2px,color:#000
    classDef cut fill:#fff3c4,stroke:#b58900,stroke-width:2px,color:#000
```

- 네 조건의 AND(`busy && (&core_fin_now) && (wr_fin_q || wr_done) && (am_fin_q || am_done)`)가 처음 참인 cycle이 e.
- `gemv_core`의 `done_o`는 마지막 y 수락 다음 cycle의 1 cycle pulse(`hierarchy.md` 3.5), `wr_done`은 y 쓰기 명령의 마지막 B handshake, `am_done`은 마지막 y 다음 cycle의 pulse(latency 1).

## 4. 레지스터 요약 (32비트, byte offset)

전체 표와 비트 정의, 호출 규칙(CTRL 쓰기 조건표, PS 호출 순서)은 `docs/spec/gemv_acc.md` 2절과 3절. 아래는 RTL `gemv_acc_csr.sv` 헤더 주석과 대조한 요약이다.

| offset | 이름 | 접근 | 내용 |
|---|---|---|---|
| 0x00 | ID | R | 0x47410001 ("GA", 버전 1) |
| 0x04 | CONFIG | R | [7:0] `FCLK_MHZ`, [11:8] `P`, [15:12] log2(LANES) = 3, [31:16] `NMAX` |
| 0x08 | CTRL | W | bit0 start, [7:4] op(1 = GEMV). 읽으면 0 |
| 0x0C | STATUS | R | bit0 busy(검사 중 또는 호출 중), bit1 done_sticky, bit2 err_any |
| 0x10 | ERR | R/W1C | bit0 START_BUSY, 1 BAD_OP, 2 BAD_DESC, 3 MISALIGN, 4 RD_RESP, 5 WR_RESP |
| 0x14 | CYCLES | R | 마지막 호출의 cycle 수 (= e - s, 검사 `C_CHK` 포함) |
| 0x18, 0x1C | RD_STALL, WR_STALL | R | 마지막 호출의 stall cycle |
| 0x20 | OPS | R | 끝난 호출 수 |
| 0x40 .. 0x58 | W_ADDR, X_ADDR, Y_ADDR, ROWS, N, XM, EXP | RW | descriptor (ROWS와 N은 32비트 그대로 저장) |
| 0x5C | FLAGS | RW | bit0 `argmax_en`, bit1 `y_en`, reset 0x2 |
| 0x60, 0x64 | ARGMAX_IDX, ARGMAX_VAL | R | 마지막 argmax 호출의 index와 값 |

## 5. CYCLES 식과 시뮬레이션 측정값

기호: `nb = ceil(N/8)`, `R = 1 + nb`, `C_CHK` = 9(`NMAX` 1024). 조건: 메모리 stall 없음, read latency 1, B latency 1, `MAX_BURST` 16, `OUTS` 4, 기본 PIPE. 식의 유도와 P = 2 일반식은 `gemv_acc.md` 5절. S4-6b부터 **CYCLES = `C_CHK` + (판정 cycle v 기준 식)**이다(v 기준 식은 S4-4의 s 기준 식과 같다).

- P = 1, `y_en = 0`: `CYCLES = nb + ROWS x (1 + nb) + 15 + Xd + C_CHK`, `Xd = max(0, mx + 1 - nb)`(`mx` = x 명령의 burst 수. nb = 1이면 항상 1).
- P = 1, `y_en = 1`: 막힘이 없으면 `CYCLES = nb + ROWS x (1 + nb) + 19 + Xd + L_last + C_CHK`(`L_last` = 마지막 y 쓰기 burst의 beat 수).
- 고정 항 15(또는 19 + `L_last`)가 `arch.md` 2.4의 `L_dram + L_pipe`에 해당하고, S4-6b의 `C_CHK`가 호출마다 따로 붙는다.

측정값 [측정, 시뮬레이션 모델(Questa, `axi_mem_slave` stall 없음 latency 1), 보드 값 아님. S4-6b 재측정, 괄호는 S4-6 값. 출처 `gemv_acc.md` 5절, agent 보고이며 이 문서에서 재실행하지 않음]:

| 호출 | P | CYCLES | 근거 |
|---|---|---|---|
| 15M 분류기 32000 x 288, `y_en` = 1, `argmax_en` = 1 | 1 | 1,184,069 ~ 1,184,077 (1,184,061 ~ 1,184,064) | `gemv_acc.md` 5절 |
| 같은 호출, `y_en` = 0 | 1 | 1,184,060 (1,184,051) | 같음. 정확히 + 9 |
| 15M token 하나(43 호출 합) | 1 | 1,951,992 (`q_p1_m2tok`, 1 위치; S4-6 같은 run 1,951,620) | 같음 |
| 260K token 하나(36 호출 합, 12 위치) | 1 | 37,903 ~ 37,938 (37,560 ~ 37,616) | 같음 |
| 260K token 하나(36 호출 합, 12 위치) | 2 | 19,895 ~ 19,930 (19,565 ~ 19,603) | 같음 |

- S4-6b 차이: 호출마다 `C_CHK` = 9가 붙어 `y_en = 0` 호출은 정확히 +9, 36 호출의 token은 +324가 기준이다. `y_en = 1` 호출은 TB의 무작위 `Y_ADDR`(AXI-Lite BFM과 같은 난수열을 써서 polling 횟수가 바뀌면 값이 밀림)에 따라 y burst의 4 KiB/16 beat 분할이 달라져 호출당 몇 cycle씩 다르다. 모든 호출에서 CYCLES == `gemv_acc.md` 5절 식(`C_CHK` 포함)을 `+CYC=1` run이 확인했다(P = 1, 2 각 444 호출, `gemv_acc.md` 5절).
- 비교 기준(`arch.md` 2.4의 계산값, 시뮬레이션 아님): 15M token 1,950,260, 260K P = 1 36,446, P = 2 18,402. 차이는 호출당 고정 항과 `C_CHK`다.
- 분류기 `y_en = 0`의 1,184,060은 위 닫힌 식 `36 + 32000 x 37 + 15 + 9`(`nb` = 36, `Xd` = 0)와 같다[계산으로 확인].
- RD_STALL: stall 없는 모델에서 호출당 5(x를 기다리는 시작 구간)라고 S4-4에서 기록했다. S4-6b 뒤의 값은 이 문서에서 확인하지 않았다.
- 보드의 HP latency와 대역폭 효율은 `bwtest.md` 측정 전까지 모른다. 식은 기본 parameter와 stall 없는 모델에서만 확인했다(`gemv_acc.md` 7절).
- 호출당 검사 비용: 260K token(36 호출)에서 324 cycle, 37,596의 0.9% [계산, `gemv_acc.md` 6b절].

## 6. 확인하지 못한 것
- 보드 실측(HP 포트 latency, 대역폭), 100 MHz 타이밍, LUT 수.
- 다른 `DOT_PIPE`/`SCALE_PIPE`에서의 CYCLES 식(검사하지 않음).
- P = 2의 15M 전체 레코드의 stall 없는 CYCLES(stall 프로파일 1에서만 실행).
