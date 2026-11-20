# L2 pim_core: block, data flow, control flow, cycle 식

- 원본과 확인일: 확인일 2026-11-19. `rtl/l2/pim_core.sv`(포트, 인스턴스, router, gather mux), `rtl/l1/pim_ctrl.sv`(FSM `state_t`, round 발행, gather delay line), `rtl/l1/pim_bank.sv`, `rtl/l1/pim_gb.sv`, `docs/spec/pim.md` 5, 6절. 신호 이름, 비트폭, 전이 조건은 RTL 선언 그대로다.
- 상태: S4-5에서 단독 G4 통과(260K K_GEMV 레코드 432개 42,144행 y mismatch 0, `log.md` S4-5, `./sim/run.sh all` 262 run, fails 0 [측정, 수퍼바이저 재실행]). 합성, 타이밍, 보드는 미확인.
- 기준 parameter: `NB` 4, `LB` 16, `DEPTH` 4096(bank당 word), `NMAX` 1024, `DOT_PIPE` 2, `SCALE_PIPE` 3, `Y_DEPTH` 32, `ROWS_W` 16. 이때 `AA` = 12, `NW` = 11, `GA` = 6, `BI_W` = 2, `ACC_W` = 25, `W_WORD` = 144, `L_BANK` = 5. 다른 parameter 값의 폭은 같은 식으로 달라진다.
- **이 문서는 RTL을 읽어서 그린 것이다. 시뮬레이션 파형이 아니고, 파형은 그리지 않았다.** cycle 식만 `pim.md` 6.1의 시뮬레이션 확인(stall 없는 모든 MACAB에서 일치)을 따른다.

## 1. block diagram

```mermaid
flowchart LR
    subgraph IN["입력 포트"]
        cmd["cmd stream<br/>cmd_valid_i, cmd_ready_o<br/>cmd_op_i 4b, cmd_rows_i 16b, cmd_n_i 11b<br/>cmd_base_i 12b, cmd_addr_i 32b, cmd_xm_i 17b<br/>cmd_we_i, cmd_xe_i, cmd_fo_i 각 8b signed"]
        dd["read data<br/>d_valid_i, d_ready_o<br/>d_data_i 64b"]
        rdyy["y_ready_i"]
    end

    subgraph CORE["pim_core"]
        ctrl["u_ctrl : pim_ctrl<br/>FSM S_IDLE, S_LDATA, S_LFILL, S_XDATA, S_MAC<br/>bank write port, MAC read port,<br/>gather delay line (L_BANK - 1 = 4단)"]
        router["read stream router<br/>d_ready_o = gb_sel ? gb_ready : ld_ready<br/>ld_valid = d_valid_i and not gb_sel"]
        gb["u_gb : pim_gb<br/>2 x ram_sdp 64b x 64, RD_LAT 1<br/>rd_word_o xw 128b"]
        subgraph BANKS["g_bank[0..3]"]
            b0["u_bank : pim_bank (bank b)<br/>ram_sdp W 144, DEPTH 4096, RD_LAT 1<br/>mac_row LANES 16, ACC_W 25, DOT_PIPE 2 (LATENCY 3)<br/>MAC_REG: res_acc 25b, res_wm 16b<br/>LATENCY = 3 + DOT_PIPE = 5"]
        end
        gmux["gather mux (4:1)<br/>r_acc[g_sel] 25b, r_wm[g_sel] 16b"]
        scale["u_scale : gemv_scale<br/>ACC_W 25, PIPE 3<br/>xm_i 17b = g_xm, sh_i 10b = g_sh"]
        lastdl["ldl_q: g_last를 SCALE_PIPE 단 지연 (s_last)"]
        yfifo["u_yfifo : sync_fifo<br/>W 33 = {s_last, sy 32b}, DEPTH Y_DEPTH 32"]
    end

    subgraph OUT["출력 포트"]
        rdc["rd_cmd_valid_o, rd_cmd_ready_i<br/>rd_cmd_addr_o 32b, rd_cmd_bytes_o 32b"]
        wrc["wr_cmd_valid_o, wr_cmd_ready_i<br/>wr_cmd_addr_o 32b, wr_cmd_bytes_o 32b"]
        ys["y stream<br/>y_valid_o, y_data_o 32b, y_last_o"]
        ev["busy_o, rd_stall_o<br/>ev_mac_o, ev_wrgb_o, ev_rdmac_o<br/>done_ldw_o, done_wrgb_o, done_mac_o"]
    end

    cmd --> ctrl
    ctrl --> rdc
    ctrl --> wrc
    dd --> router
    router -->|"ld_data_i 64b (LDW)"| ctrl
    router -->|"wr_data_i 64b (WRGB)"| gb
    ctrl -->|"gb_sel, gb_load, gb_n 11b"| gb
    gb -->|"gb_beat, gb_done"| ctrl
    ctrl -->|"bw_en 4b, bw_addr 12b, bw_data 144b"| b0
    ctrl -->|"mr_en 4b, mr_addr 12b, mr_first, mr_last"| b0
    ctrl -->|"gb_rd_en, gb_rd_addr 6b"| gb
    gb -->|"xw 128b (모든 bank에 방송)"| b0
    b0 -->|"r_acc[b], r_wm[b]"| gmux
    ctrl -->|"g_valid, g_sel 2b, g_xm, g_sh"| gmux
    gmux --> scale
    ctrl -->|"g_last"| lastdl
    scale -->|"sy 32b, sv"| yfifo
    lastdl -->|"s_last"| yfifo
    yfifo --> ys
    rdyy --> yfifo
    yfifo -->|"y_pop = y_valid_o and y_ready_i"| ctrl
    ctrl --> ev
```

포트와 인스턴스 요약:

| 항목 | RTL 확인 내용 |
|---|---|
| 입력 | `cmd_*`(위 그림), `rd_cmd_ready_i`, `d_valid_i`/`d_data_i[63:0]`, `wr_cmd_ready_i`, `y_ready_i` |
| 출력 | `cmd_ready_o`, `rd_cmd_*`, `d_ready_o`, `wr_cmd_*`, y stream(`y_valid_o`, `y_data_o[31:0]`, `y_last_o`), `busy_o`(= `!idle`, `idle` = `pim_ctrl.idle_o`), `rd_stall_o`(= `d_ready_o && !d_valid_i`), 사건 pulse 6개 |
| `u_ctrl` | `pim_ctrl #(NB, LB, DEPTH, NMAX, Y_DEPTH, L_BANK, ROWS_W)`. `cmd_ready_o = (state_q == S_IDLE) && !rd_cmd_valid_o && !(cmd_op_i == OP_MACAB && wr_cmd_valid_o)` |
| `u_gb` | `pim_gb #(NMAX, LB)`. 내부 `u_lo`, `u_hi`: `ram_sdp #(W 64, DEPTH NMAX/16 = 64, RD_LAT 1)`. 읽기 latency 1(`LATENCY` 1) |
| `g_bank[b].u_bank` | `pim_bank #(LB 16, DEPTH 4096, NMAX, DOT_PIPE 2)` x `NB`. 내부 `u_ram`(ram_sdp, W = `W_WORD` 144), `u_mac`(`mac_row`, 그 안에 `dotp`). bank마다 쓰기 enable `bw_en[b]`와 읽기 enable `mr_en[b]`가 따로이고 주소, 데이터, first/last, x는 공통 |
| `u_scale` | `gemv_scale #(ACC_W 25, PIPE 3)`. 입력은 `r_acc[g_sel]`, `r_wm[g_sel]`, `g_xm`, `g_sh` |
| `u_yfifo` | `sync_fifo #(W 33, DEPTH Y_DEPTH)`. `in_ready_o`는 `PIM_YOVF` assertion에만 쓴다(credit이 넘침을 막는다) |
| 사용하지 않는 출력 | `pim_bank.res_valid_o`는 `pim_core`에서 연결하지 않는다(gather 시점은 `pim_ctrl`이 정함) |

## 2. data flow

### 2.1 LDW: 행 레코드 -> bank

행 레코드는 header 1 beat(`[15:0]` = wm) + 가중치 `nb8 = ceil(n/8)` beat(64비트 = int8 8개)다. 한 word = 144비트 = `{tag 16b, hi 64b, lo 64b}`.

```mermaid
flowchart LR
    ld["d_data_i 64b<br/>(ld_valid_i, S_LDATA)"]:::io
    hdr["lbeat_q = 0: header<br/>lwm_q <= ld_data_i[15:0]"]:::st
    msk["l_dm: 행의 마지막 beat에서<br/>lane >= n은 8'h00 (lmask_q)"]:::logic
    lo["lbeat 홀수: llo_q <= l_dm<br/>(word의 하위 64b 보관)"]:::st
    asm["lbeat 짝수, 또는 마지막 beat: word 완성<br/>bw_data_o 144b =<br/>{tag, hi, lo}<br/>tag = (l_w == 0) ? lwm_q : 0<br/>마지막 beat가 홀수면 hi = 0"]:::logic
    sel["bw_en_o[lrow_q mod 4] = 1<br/>bw_addr_o = rbase_q + l_w<br/>l_w = (lbeat_q - 1) >> 1"]:::logic
    bk["pim_bank[r mod 4].u_ram<br/>word base + (r div 4) nw + w<br/>nw = ceil(n/16)"]:::mod
    fill["S_LFILL: 마지막 round의 빈 slot<br/>(rows mod 4 != 0일 때)<br/>bw_data_o = 0 word, nw개씩"]:::logic

    ld --> hdr
    ld --> msk
    msk --> lo
    msk --> asm
    hdr --> asm
    lo --> asm
    asm --> sel
    sel --> bk
    fill --> bk

    classDef io fill:#ffffff,stroke:#333333,color:#000
    classDef st fill:#fff3c4,stroke:#b58900,stroke-width:2px,color:#000
    classDef logic fill:#e3eefc,stroke:#3b6aa0,stroke-width:2px,color:#000
    classDef mod fill:#d8f0d8,stroke:#2e7d32,stroke-width:2px,color:#000
```

- 행 r의 bank는 `lrow_q[BI_W-1:0]`(= r mod 4), word 주소는 `rbase_q + l_w`. `rbase_q`는 `lrow_q mod 4 == NB - 1`인 행의 마지막 beat에서 `nw_q`만큼 증가한다(round 하나가 끝날 때).
- 읽기 길이 `rd_cmd_bytes_o`는 `rows x (nb8 + 1) x 8` byte(`rdc_bytes_q`)다.

### 2.2 WRGB: x -> global buffer

```mermaid
flowchart LR
    d["d_data_i 64b<br/>(gb_sel_o = 1, S_XDATA)"]:::io
    rt["router: d_ready_o = gb_ready<br/>gb_beat = d_valid_i and gb_sel and gb_ready"]:::logic
    gb["pim_gb<br/>beat 2j -> u_lo[j], beat 2j+1 -> u_hi[j]<br/>마지막 beat의 lane >= n은 0<br/>읽기 때 쓰지 않은 반 word는 0"]:::mod
    out["rd_word_o xw 128b<br/>{vhi ? hi : 0, vlo ? lo : 0}"]:::st

    d --> rt
    rt --> gb
    gb --> out

    classDef io fill:#ffffff,stroke:#333333,color:#000
    classDef st fill:#fff3c4,stroke:#b58900,stroke-width:2px,color:#000
    classDef logic fill:#e3eefc,stroke:#3b6aa0,stroke-width:2px,color:#000
    classDef mod fill:#d8f0d8,stroke:#2e7d32,stroke-width:2px,color:#000
```

- WRGB 명령 handshake에서 `gb_load_o = cmd_hs && op == WRGB`(n을 `gb_n_o`로 전달). 읽기 길이는 n byte. 완료는 `pim_gb.done_o`(마지막 beat handshake)로 `S_XDATA -> S_IDLE`.

### 2.3 MACAB: 방송 word + bank word -> 행 합 -> gather -> scale -> y

```mermaid
flowchart LR
    gbw["pim_gb<br/>gb_rd_en_o = m_issue, 주소 w_q 6b<br/>-> xw 128b (1 cycle 뒤)"]:::mod
    bw["pim_bank 0..3<br/>mr_en_o[b], 주소 abase_q + w_q 12b<br/>u_ram -> 144b (1 cycle 뒤)"]:::mod
    dot["u_mac (mac_row): 16 lane int8 x int8<br/>dotp -> 누산 acc 25b<br/>행 끝(last)에서 완성"]:::st
    mreg["MAC_REG[b]<br/>res_acc 25b, res_wm 16b<br/>(wm = 행 첫 word의 tag)"]:::st
    gm["gather mux<br/>g_sel 2b = 0, 1, 2, 3 순서, 한 cycle에 하나<br/>r_acc[g_sel], r_wm[g_sel]"]:::logic
    sc["gemv_scale<br/>acc x wm -> x xm -> rshr_sat(sh)<br/>sy 32b"]:::mod
    yf["y FIFO 32 x 33"]:::st
    y["y stream 32b<br/>행 순서 (row 4i + b)"]:::io

    gbw -->|"방송, 모든 bank 같은 word"| dot
    bw --> dot
    dot --> mreg
    mreg --> gm
    gm --> sc
    sc --> yf
    yf --> y

    classDef io fill:#ffffff,stroke:#333333,color:#000
    classDef st fill:#fff3c4,stroke:#b58900,stroke-width:2px,color:#000
    classDef logic fill:#e3eefc,stroke:#3b6aa0,stroke-width:2px,color:#000
    classDef mod fill:#d8f0d8,stroke:#2e7d32,stroke-width:2px,color:#000
```

- 행 r(round i = r div 4, bank b = r mod 4)은 bank b 안에서 끝난다. bank 사이 reduction은 없다(BANK_ROW). 마지막 round의 행이 4개보다 적으면(rows mod 4 != 0) `mr_en_o` mask(`m_mask[b] = b < m_nv`)로 앞 `m_nv`개 bank만 읽는다.
- gather 한 cycle당 `gemv_scale`에 하나가 들어가며(`g_valid_o`, `g_sel_o`), round의 `xm`, `sh = we + xe - fo`는 gather delay line을 거쳐 같이 온다.

단별 latency (RTL의 레지스터 수에서 센 값, 기준 parameter):

| 단 | 단 수 | 근거 |
|---|---|---|
| bank RAM read | 1 | `ram_sdp` `RD_LAT` 1. global buffer read도 1이라 같은 cycle에 맞는다 |
| `mac_row` | `DOT_PIPE + 1` = 3 | `pim_bank` `LAT_M` |
| MAC_REG | 1 | `res_v_q`, `res_acc_q` |
| 합 (`L_BANK`, `pim_bank.LATENCY`) | 3 + `DOT_PIPE` = **5** | round의 마지막 word `re_i`가 cycle t이면 `res_valid_o`는 t + 5 |
| `gemv_scale` | `SCALE_PIPE` = 3 | `LATENCY = PIPE` |
| y FIFO 쓰기 | 1 | `sync_fifo`는 push 다음 cycle에 `out_valid_o` |

## 3. control flow

### 3.1 `pim_ctrl` FSM

state는 5개(`state_t`): `S_IDLE`, `S_LDATA`, `S_LFILL`, `S_XDATA`, `S_MAC`. `default` 분기는 `S_IDLE`로 돌아간다.

```mermaid
stateDiagram-v2
    [*] --> S_IDLE : reset

    S_IDLE : S_IDLE
    S_LDATA : S_LDATA, ld_ready_o = 1
    S_LFILL : S_LFILL, 빈 slot에 0 word 쓰기
    S_XDATA : S_XDATA, gb_sel_o = 1
    S_MAC : S_MAC, round 발행

    S_IDLE --> S_LDATA : cmd_hs and op = LDW
    S_IDLE --> S_XDATA : cmd_hs and op = WRGB
    S_IDLE --> S_MAC : cmd_hs and op = MACAB
    S_LDATA --> S_LDATA : ld_hs, 마지막 행이 아니거나 마지막 beat가 아님
    S_LDATA --> S_IDLE : ld_hs and 마지막 beat and 마지막 행 and rows mod 4 = 0
    S_LDATA --> S_LFILL : ld_hs and 마지막 beat and 마지막 행 and rows mod 4 != 0
    S_LFILL --> S_LFILL : fw_q 증가, fw_q = nw_q - 1이면 fb_q 증가
    S_LFILL --> S_IDLE : fw_q = nw_q - 1 and fb_q = NB - 1
    S_XDATA --> S_IDLE : gb_done_i
    S_MAC --> S_MAC : m_issue, word 또는 round 증가
    S_MAC --> S_IDLE : m_issue and m_lastw and m_lastrnd
```

전이 조건 (RTL 정의):

| 항목 | 정의 |
|---|---|
| `cmd_hs` | `cmd_valid_i && cmd_ready_o` |
| `ld_hs` | `ld_valid_i && ld_ready_o`, `ld_ready_o = (state_q == S_LDATA)` |
| 행의 마지막 beat | `l_lastbeat = (lbeat_q == nb8_q)` (`lbeat_q` 0 = header, 1 .. `nb8_q` = weight beat) |
| 마지막 행 | `l_lastrow = (lrow_q == rows_q - 1)` |
| `m_issue` | `(state_q == S_MAC) && m_ok` |
| `m_lastw`, `m_lastrnd` | `w_q == nw_q - 1`, `rnd_q == nrnd_q - 1` (`nrnd_q` = ceil(rows/4)) |
| 사건 | `done_mac_o = m_issue && m_lastw && m_lastrnd`, `done_wrgb_o = (state_q == S_XDATA) && gb_done_i`, `done_ldw_o`는 LDW의 마지막 쓰기 cycle |

- 컨트롤러는 마지막 word read(MACAB), 마지막 bank 쓰기(LDW), 마지막 gb beat(WRGB) 다음 cycle에 idle이고 다음 명령을 받을 수 있다.

### 3.2 round 발행 조건 `m_ok`

round의 첫 word(`m_first = (w_q == 0)`)를 읽을 때만 조건이 있고, round 중간 word(`!m_first`)는 항상 발행한다.

```
m_ok = !m_first
       || ( (since_q + nw_q - 1 >= NB)            // 간격 조건
            && (yres_q + m_nv <= Y_DEPTH) )       // y credit 조건
```

```mermaid
flowchart TD
    st["state_q == S_MAC"]:::logic
    f{"m_first ?<br/>(w_q == 0)"}:::logic
    gap{"간격: since_q + nw_q - 1 >= NB ?<br/>(이 round의 마지막 word가<br/>앞 round 마지막 word보다 NB cycle 이상 뒤)"}:::logic
    cr{"credit: yres_q + m_nv <= Y_DEPTH ?"}:::logic
    iss["m_issue = 1<br/>mr_en_o, gb_rd_en_o"]:::cut
    wait["대기 (m_issue = 0)"]:::cut

    st --> f
    f -->|"아니오 (round 중간)"| iss
    f -->|"예"| gap
    gap -->|"아니오"| wait
    gap -->|"예"| cr
    cr -->|"아니오"| wait
    cr -->|"예"| iss

    classDef logic fill:#e3eefc,stroke:#3b6aa0,stroke-width:2px,color:#000
    classDef cut fill:#fff3c4,stroke:#b58900,stroke-width:2px,color:#000
```

- `since_q`: 마지막 round의 마지막 word read 이후 cycle 수(`m_issue && m_lastw`에서 1로, 이후 `NB`까지 증가해 포화). 명령 경계를 넘어 유지된다.
- `yres_q`: y FIFO에 잡아 둔 행 수. round 첫 word 발행에서 `m_nv`(그 round의 행 수)만큼 늘고 `y_pop_i`마다 1 줄어든다. y 쪽 backpressure는 이 credit으로만 처리하고 bank pipeline에는 backpressure가 없다(`PIM_YOVF`).
- 간격 조건 덕에 gather(`NB` cycle)가 끝나기 전에 다음 round 결과가 MAC_REG를 덮지 않는다(`PIM_GATHER`). `nw >= 4`면 round가 빈틈 없이 이어지고, `nw < 4`(n <= 48)면 round 하나가 4 cycle이다(`pim.md` 5절).
- 명령 수락 조건: MACAB는 앞 MACAB의 write 명령(`wr_cmd_valid_o`)이 engine에 넘어간 뒤에 받는다.

### 3.3 gather delay line

round의 마지막 word를 읽는 cycle t에 `dlv_in = m_issue && m_lastw`로 항목 `gent_t {cl, nv, xm, sh}`(`cl` = 명령의 마지막 round, `nv` = round의 행 수 3b, `xm` 17b, `sh` 10b)를 push한다.

```mermaid
flowchart LR
    p["t: dlv_in = m_issue and m_lastw<br/>dld_in = {cl: m_lastrnd, nv: m_nv, xm: xm_q, sh: sh_q}"]:::cut
    d0["dlv_q[0], dld_q[0]<br/>t + 1"]:::cut
    d1["dlv_q[1], dld_q[1]<br/>t + 2"]:::cut
    d2["dlv_q[2], dld_q[2]<br/>t + 3"]:::cut
    d3["dlv_q[LD-1 = 3], dld_q[3]<br/>t + 4"]:::cut
    g["ga_q = 1, gd_q <= dld_q[LD-1]<br/>t + 5 = t + L_BANK<br/>g_valid_o, g_sel_o = gcnt_q = 0 .. nv - 1"]:::logic
    e["g_end: gcnt_q = nv - 1 -> ga_q = 0<br/>g_last_o = gd_q.cl and g_end"]:::logic

    p --> d0 --> d1 --> d2 --> d3 --> g --> e

    classDef logic fill:#e3eefc,stroke:#3b6aa0,stroke-width:2px,color:#000
    classDef cut fill:#fff3c4,stroke:#b58900,stroke-width:2px,color:#000
```

- 단 수 `LD = L_BANK - 1` = 4. 위 cycle 표기(t + 1 .. t + 5)는 레지스터 단 수를 센 것이다. gather의 첫 cycle(t + `L_BANK`)에 bank 0의 MAC_REG가 유효하고, 이후 bank 1, 2, 3이 한 cycle씩 뒤따른다. 이것은 `pim_bank.LATENCY`(마지막 word `re_i`에서 `res_valid_o`까지)와 같은 값이어야 하는 정렬이며 RTL 주석의 정의다.
- `g_last_o`는 `gemv_scale`을 지나는 동안 `ldl_q`(`SCALE_PIPE` 단)로 같이 지연되어 y FIFO에 `{s_last, sy}`로 들어간다.

## 4. cycle 식

기호: `R` = ceil(rows/4), `nw` = ceil(n/16), `P` = max(nw, 4), `nvl` = rows - 4 (R - 1)(마지막 round의 행 수), `L_BANK` = 3 + `DOT_PIPE`, `L_S` = `SCALE_PIPE`. 명령 handshake cycle을 0, 이전 round의 마지막 word cycle을 `t_p`라 하면(`pim.md` 6.1, 시뮬레이션으로 확정):

```
t0  = max(1, t_p + 4 - (nw - 1))              // 첫 word
t_l = t0 + (R - 1) P + nw - 1                  // 마지막 word (done_mac)
C   = t_l + L_BANK + nvl + L_S                 // 마지막 y가 core 출력에 valid
```

앞 MACAB에서 충분히 떨어져 `t0 = 1`이고 `nw >= 4`, rows가 4의 배수(`nvl` = 4)이면

```
C_mac = ceil(rows/4) x ceil(n/16) + 12        (기본 PIPE)
```

상수 12의 구성(기본 parameter, `t_l`의 `+ 1`은 첫 word가 cycle 1이라 `t_l = R nw`에 이미 들어 있다):

| 항 | cycle | RTL 근거 |
|---|---|---|
| `L_BANK` | 5 | RAM read 1 + `mac_row` 3 + MAC_REG 1 (`pim_bank.LATENCY`) |
| gather | 4 | `nvl`. 마지막 round의 행 4개가 한 cycle에 하나씩 `gemv_scale`에 들어간다. y FIFO 쓰기 1단을 이 항에 묶었다(아래 참고) |
| `L_S` | 3 | `gemv_scale` `SCALE_PIPE` |
| 합 | **12** | |

- 참고: `pim.md` 6.1의 구성(read 1, mac_row 3, MAC_REG 1, scale 3, gather 4)과 같은 분해다. 다만 RTL 레지스터 수에서 따로 세면 `nvl` 항 4는 "마지막 bank(b = 3)가 gather 시작보다 3 cycle 늦음 + y FIFO 쓰기 1단"과 같은 값이다(이 분해는 RTL에서 센 것이고 `pim.md`에는 이 구분이 없다). 합 12는 시뮬레이션으로 확인된 값이다.
- 확인: `pim_core` TB(STALL = 0)가 모든 MACAB의 마지막 y cycle을 식과 비교(260K 레코드 432개 3 run, 합성 838개), `pim_ctrl` TB가 `done_mac` cycle을 같은 식으로 비교(`log.md` S4-5, `pim.md` 6.1). 식은 stall 없는 경우의 값이다.
- 컨트롤러 점유(handshake부터 다음 명령을 받을 수 있는 cycle까지): `(R - 1) P + nw + 1`(`pim.md` 6.1).
- 260K token 합 [측정, 시뮬레이션]: `sum ceil(rows/4) x ceil(n/16)` = 4,072 cycle, 컨트롤러 MACAB 점유 합 4,108(`pim.md` 6.2).
