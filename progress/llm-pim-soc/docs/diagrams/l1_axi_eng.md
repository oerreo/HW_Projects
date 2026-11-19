# L1 AXI engine: axi_rd_eng, axi_wr_eng

- 원본과 확인일: 확인일 2026-11-19. `rtl/l1/axi_rd_eng.sv`, `rtl/l1/axi_wr_eng.sv`, `rtl/l0/sync_fifo.sv`(FIFO 인스턴스 폭과 깊이), 스펙 `docs/spec/hierarchy.md` 3.6. 신호 이름, 폭, 조건식은 RTL에서 읽은 것이다.
- 상태: 두 모듈 모두 S4-3에서 단독 G4 통과(`log.md` S4-3: `./sim/run.sh all` 164 run, fails 0 [측정, 수퍼바이저 재실행]).
- 폭 표기: 기본 parameter(`DW` 64, `AW` 32, `LEN_W` 32, `IDW` 1, `MAX_BURST` 16, `OUTS` 4) 기준이고, 식이 있는 폭은 식을 같이 적었다. `DW`는 64만 허용(elaboration `$error`).
- 파형은 그리지 않았다. 4절의 처리율 표만 시뮬레이션 측정값이다.
- 두 engine은 AR/AW 생성부(명령, burst 계산)가 같은 구조이고, 데이터 쪽(R 버퍼 대 W 버퍼)만 다르다.

## 1. axi_rd_eng

### (a) block diagram

```mermaid
flowchart LR
    cmd["명령<br/>cmd_valid_i, cmd_ready_o<br/>cmd_addr_i AW b, cmd_bytes_i LEN_W b<br/>cfg_burst_i 9b, cfg_outs_i 7b"]:::io
    chk["명령 검사<br/>cmd_bad = addr[2:0] != 0<br/>또는 bytes == 0<br/>또는 addr + bytes > 2^AW"]:::logic
    creg["명령 레지스터<br/>act_q, wa_q AW-3 b (addr / 8)<br/>rem_q LEN_W-2 b (남은 beat)<br/>blim_q 9b, olim_q 7b"]:::cut
    calc["burst 계산 (조합)<br/>blen 10b = min(rem_q, blim_q, to4k)<br/>to4k = 512 - wa_q[8:0]<br/>last_burst = (blen == rem_q)"]:::logic
    go["ar_go<br/>act_q, ar_free,<br/>outs_q < olim_q,<br/>space_q >= blen"]:::logic
    ar["AR 레지스터<br/>arvalid_q, araddr_q AW b,<br/>arlen_q 8b = blen - 1"]:::cut
    axiar["m_axi_ar*<br/>ARID 0, ARSIZE 3, ARBURST INCR,<br/>ARCACHE = AXCACHE, ARLOCK/PROT/QOS 0"]:::io
    binfo["u_binfo: sync_fifo<br/>W = 9, DEPTH = OUTS<br/>{last_burst, blen - 1}<br/>push ar_go, pop rlast_hs"]:::cut
    cnt["카운터<br/>outs_q (제시한 burst - RLAST),<br/>space_q (FIFO 약속 안 된 beat),<br/>pend_q (수락, 미전달 명령)"]:::cut
    axir["m_axi_r*<br/>RDATA 64b, RRESP 2b,<br/>RLAST, RVALID, RREADY"]:::io
    rbuf["u_rbuf: sync_fifo<br/>W = 65 ({RLAST and bi_last, RDATA})<br/>DEPTH = FIFO_DEPTH"]:::cut
    data["데이터 스트림<br/>d_valid_o, d_ready_i,<br/>d_data_o 64b, d_last_o"]:::io
    st["상태<br/>busy_o (pend_q != 0), done_o,<br/>stall_o, err_resp_o, err_cmd_o,<br/>err_clr_i"]:::io

    cmd --> chk
    chk -->|"cmd_ok"| creg
    chk -->|"거절: err_cmd_q 세트, done_o 1 cycle"| st
    creg --> calc
    calc --> go
    go -->|"ar_go"| ar
    go -->|"ar_go"| binfo
    go -->|"ar_go: space_q -= blen"| cnt
    ar --> axiar
    axir -->|"RVALID, RLAST"| rbuf
    binfo -->|"bi_last"| rbuf
    rbuf --> data
    axir -->|"r_hs, RRESP[1]"| st
    rbuf -->|"d_hs: space_q += 1"| cnt
    cnt --> go
    cnt --> st

    classDef io fill:#ffffff,stroke:#333333,color:#000
    classDef logic fill:#d8f0d8,stroke:#2e7d32,stroke-width:2px,color:#000
    classDef cut fill:#fff3c4,stroke:#b58900,stroke-width:2px,color:#000
```

- `RREADY` = `u_rbuf`의 `in_ready_o`(버퍼가 차지 않음). AR을 낼 때 버퍼 여유(`space_q`)가 burst 전체를 덮는지 확인하므로, RVALID가 올 때 버퍼는 항상 비어 있다. 어기면 시뮬레이션 tag `ENG_RSTALL`.
- `RID`는 무시한다(ID 0 하나, 순서대로).
- 명령 handshake가 cycle c이면 `ARVALID`는 c + 2이다(handshake가 `act_q`를 세우고 다음 cycle에 `arvalid_q`가 등록된다. RTL 구조에서 도출, TB로 재지 않음).
- 마지막 beat의 길이 밖 byte는 메모리 내용 그대로 나가고, 소비자가 무시한다.
- `ar_free` = `!arvalid_q || m_axi_arready_i`.

### (b) control flow

```mermaid
flowchart TD
    s0(["cmd_valid_i"]):::io
    q0{"cmd_bad ?<br/>addr[2:0] != 0, bytes == 0,<br/>addr + bytes > 2^AW"}:::logic
    q1{"busy_o ?"}:::logic
    rej["거절 명령 수락 (idle일 때만)<br/>AXI 트래픽 없음, 데이터 없음<br/>err_cmd_q = 1 (sticky)<br/>done_o 1 cycle<br/>시뮬레이션 tag ENG_CMD"]:::bad
    wait0["cmd_ready_o = 0<br/>idle이 될 때까지 대기"]:::wait
    q2{"act_q ?<br/>(이전 명령의 burst를 아직 다 요청하지 않음)"}:::logic
    wait1["cmd_ready_o = 0 대기"]:::wait
    acc["cmd_ok: act_q = 1<br/>wa_q, rem_q, blim_q, olim_q latch<br/>blim_q, olim_q: 0 또는 초과 값은 MAX_BURST, OUTS로 대체"]:::logic

    b0["burst 계산<br/>blen = min(rem_q, blim_q, 512 - wa_q[8:0])"]:::logic
    q3{"ar_free ?<br/>!arvalid_q 또는 arready"}:::logic
    q4{"outs_q < olim_q ?<br/>outstanding 한도"}:::logic
    q5{"space_q >= blen ?<br/>R 버퍼 여유가 burst 전체를 덮음"}:::logic
    hold["이번 cycle은 AR을 내지 않음"]:::wait
    issue["ar_go<br/>araddr_q = wa_q x 8, arlen_q = blen - 1<br/>wa_q += blen, rem_q -= blen<br/>outs_q += 1, space_q -= blen<br/>burst 정보 push"]:::logic
    q6{"last_burst ?"}:::logic
    fin["act_q = 0<br/>다음 명령 수락 가능<br/>(데이터 전달은 계속)"]:::logic

    s0 --> q0
    q0 -->|"예"| q1
    q1 -->|"예"| wait0
    q1 -->|"아니오"| rej
    q0 -->|"아니오"| q2
    q2 -->|"예"| wait1
    q2 -->|"아니오"| acc
    acc --> b0
    b0 --> q3
    q3 -->|"아니오"| hold
    q3 -->|"예"| q4
    q4 -->|"아니오"| hold
    q4 -->|"예"| q5
    q5 -->|"아니오"| hold
    q5 -->|"예"| issue
    hold --> b0
    issue --> q6
    q6 -->|"아니오"| b0
    q6 -->|"예"| fin

    classDef io fill:#ffffff,stroke:#333333,color:#000
    classDef logic fill:#d8f0d8,stroke:#2e7d32,stroke-width:2px,color:#000
    classDef wait fill:#fff3c4,stroke:#b58900,stroke-width:2px,color:#000
    classDef bad fill:#f8d7da,stroke:#b02a37,stroke-width:2px,color:#000
```

규칙 요약(RTL 식에서 읽은 것):

| 항목 | 규칙 | RTL |
|---|---|---|
| burst 길이 | `blen = min(rem_q, blim_q, to4k)`. `rem_q`는 512로 포화시켜 비교. `to4k` = 4 KiB 안의 남은 8 B word 수(1..512). 시작 주소를 burst 크기에 정렬하지 않으므로 첫 burst만 4 KiB 경계에서 짧아질 수 있다 | `rem_c`, `to4k`, `blen` |
| AR 발행 | `act_q && ar_free && outs_q < olim_q && space_q >= blen` 네 조건이 모두 참인 cycle | `ar_go` |
| space 회계 | `space_q`는 reset 때 `FIFO_DEPTH`. `ar_go`에서 `blen`만큼 줄고 `d_hs`(버퍼에서 beat 하나가 나갈 때)마다 1 늘어난다 | `space_q` |
| outstanding | `outs_q`는 `ar_go`에서 +1, `rlast_hs`에서 -1. 한도는 명령 handshake 때 latch한 `olim_q` | `outs_q`, `olim_q` |
| 명령 거절 | 조건 3개(비정렬, 0 byte, 2^AW 초과) 중 하나. idle(`busy_o` = 0)일 때만 수락. 수락한 cycle에 `done_o` 1 cycle과 `err_cmd_q` 세트. 같은 cycle에 `cmd_ok`는 0이라 AXI 동작 없음 | `cmd_bad`, `cmd_ready_o` |
| 명령 대기 | `cmd_ready_o = !act_q && !(cmd_valid_i && cmd_bad && busy_o)`. 정상 명령은 `act_q`(이전 명령의 AR을 다 내기 전)에만 막히고, 이전 명령의 데이터 전달이 끝나기 전에도 수락된다 | `cmd_ready_o`, `pend_q` |
| 오류 sticky | `err_resp_q`는 `r_hs && RRESP[1]`(SLVERR 또는 DECERR)에서 세트, `err_cmd_q`는 거절 명령 handshake에서 세트. 둘 다 `err_clr_i`로 지움. **같은 cycle에 세트와 clear가 겹치면 세트가 이긴다**(코드에서 `if (세트) ... else if (err_clr_i)` 순서). 오류가 나도 데이터는 그대로 전달 | `err_resp_q`, `err_cmd_q` |
| reset | `act_q`, `arvalid_q`, `outs_q`, `space_q`, `pend_q`, sticky 오류만 `rst_n`. 주소, 길이, AR payload는 reset 없음 | |

## 2. axi_wr_eng

### (a) block diagram

```mermaid
flowchart LR
    cmd["명령<br/>cmd_valid_i, cmd_ready_o<br/>cmd_addr_i AW b, cmd_bytes_i LEN_W b<br/>cfg_burst_i 9b, cfg_outs_i 7b"]:::io
    din["데이터 입력<br/>in_valid_i, in_ready_o,<br/>in_data_i 64b"]:::io
    chk["명령 검사<br/>cmd_bad (rd와 같은 3조건)"]:::logic
    creg["명령 레지스터<br/>act_q, wa_q AW-3 b, rem_q LEN_W-2 b<br/>blim_q 9b, olim_q 7b<br/>lstrb_q 8b (명령 마지막 beat의 WSTRB)"]:::cut
    calc["burst 계산 (조합)<br/>blen 10b = min(rem_q, blim_q, to4k)<br/>last_burst"]:::logic
    wbuf["u_wbuf: sync_fifo<br/>W = 64, DEPTH = FIFO_DEPTH<br/>(기본 2 x MAX_BURST)"]:::cut
    go["aw_go<br/>act_q, aw_free,<br/>outs_q < olim_q,<br/>unc_q >= blen"]:::logic
    aw["AW 레지스터<br/>awvalid_q, awaddr_q AW b,<br/>awlen_q 8b, aw_lastc_q, aw_strb_q 8b"]:::cut
    axiaw["m_axi_aw*<br/>AWID 0, AWSIZE 3, AWBURST INCR,<br/>AWCACHE = AXCACHE"]:::io
    wq["u_wq: sync_fifo<br/>W = 16 {awlen_q, aw_strb_q}<br/>DEPTH = OUTS<br/>push aw_hs, pop wlast_hs"]:::cut
    bq["u_bq: sync_fifo<br/>W = 1 (aw_lastc_q)<br/>DEPTH = OUTS<br/>push aw_hs, pop b_hs"]:::cut
    wch["W 채널<br/>wvalid = f_valid && wq_valid<br/>wbeat_q 8b, wlast = (wbeat_q == wq_len)<br/>wstrb = wlast ? wq_strb : FF"]:::logic
    axiw["m_axi_w*<br/>WDATA 64b, WSTRB 8b,<br/>WLAST, WVALID, WREADY"]:::io
    axib["m_axi_b*<br/>BRESP 2b, BVALID<br/>BREADY = 1 고정"]:::io
    cnt["카운터<br/>unc_q (버퍼에 있고 AW를 못 받은 beat),<br/>outs_q (AW 제시 - B 수신),<br/>pend_q"]:::cut
    st["상태<br/>busy_o, done_o, stall_o,<br/>err_resp_o, err_cmd_o, err_clr_i"]:::io

    cmd --> chk
    chk -->|"cmd_ok"| creg
    chk -->|"거절: err_cmd_q 세트, done_o 1 cycle"| st
    creg --> calc
    calc --> go
    din --> wbuf
    din -->|"in_hs: unc_q += 1"| cnt
    cnt --> go
    go -->|"aw_go"| aw
    go -->|"aw_go: unc_q -= blen"| cnt
    aw --> axiaw
    aw -->|"aw_hs"| wq
    aw -->|"aw_hs"| bq
    wbuf --> wch
    wq --> wch
    wch --> axiw
    axib -->|"b_hs, BRESP[1]"| st
    axib -->|"b_hs"| bq
    bq -->|"bq_last"| st

    classDef io fill:#ffffff,stroke:#333333,color:#000
    classDef logic fill:#d8f0d8,stroke:#2e7d32,stroke-width:2px,color:#000
    classDef cut fill:#fff3c4,stroke:#b58900,stroke-width:2px,color:#000
```

- W 채널은 AW handshake가 끝난 burst(`u_wq`에 있는 것)만 보낸다. `wvalid`는 `f_valid && wq_valid`.
- `done_o` = `b_hs && bq_last`(명령의 마지막 burst의 B) 또는 거절 명령의 handshake cycle.
- `stall_o` = `in_valid_i && !in_ready_o`.
- `BID`는 무시한다.
- `u_wbuf`는 FIFO이므로 데이터가 명령보다 먼저 들어와도 기다린다(`unc_q`가 이를 센다). 호출자는 정상 명령마다 정확히 `ceil(bytes / 8)` beat를 보내야 하고, 거절된 명령에는 보내지 않는다(포트 주석).

### (b) control flow

```mermaid
flowchart TD
    s0(["cmd_valid_i"]):::io
    q0{"cmd_bad ?<br/>addr[2:0] != 0, bytes == 0,<br/>addr + bytes > 2^AW"}:::logic
    q1{"busy_o ?"}:::logic
    rej["거절 명령 수락 (idle일 때만)<br/>AXI 트래픽 없음, 데이터 소비 없음<br/>err_cmd_q = 1 (sticky), done_o 1 cycle<br/>시뮬레이션 tag ENG_CMD"]:::bad
    wait0["cmd_ready_o = 0 대기"]:::wait
    q2{"act_q ?"}:::logic
    wait1["cmd_ready_o = 0 대기"]:::wait
    acc["cmd_ok: act_q = 1<br/>wa_q, rem_q, blim_q, olim_q latch<br/>lstrb_q = FF 또는 (1 << bytes[2:0]) - 1"]:::logic

    b0["burst 계산<br/>blen = min(rem_q, blim_q, 512 - wa_q[8:0])"]:::logic
    q3{"aw_free ?<br/>!awvalid_q 또는 awready"}:::logic
    q4{"outs_q < olim_q ?"}:::logic
    q5{"unc_q >= blen ?<br/>burst의 모든 beat가 이미 버퍼에 있음"}:::logic
    hold["이번 cycle은 AW를 내지 않음"]:::wait
    issue["aw_go<br/>awaddr_q = wa_q x 8, awlen_q = blen - 1<br/>aw_strb_q = last_burst ? lstrb_q : FF<br/>wa_q += blen, rem_q -= blen<br/>outs_q += 1, unc_q -= blen"]:::logic
    q6{"last_burst ?"}:::logic
    fin["act_q = 0<br/>다음 명령 수락 가능"]:::logic
    wsend["AW handshake 뒤 u_wq에 burst 등록<br/>W beat 전송 (WLAST는 wbeat_q == wq_len)<br/>B 수신: outs_q -= 1<br/>명령의 마지막 burst의 B에서 done_o"]:::logic

    s0 --> q0
    q0 -->|"예"| q1
    q1 -->|"예"| wait0
    q1 -->|"아니오"| rej
    q0 -->|"아니오"| q2
    q2 -->|"예"| wait1
    q2 -->|"아니오"| acc
    acc --> b0
    b0 --> q3
    q3 -->|"아니오"| hold
    q3 -->|"예"| q4
    q4 -->|"아니오"| hold
    q4 -->|"예"| q5
    q5 -->|"아니오"| hold
    q5 -->|"예"| issue
    hold --> b0
    issue --> q6
    issue -.->|"aw_hs"| wsend
    q6 -->|"아니오"| b0
    q6 -->|"예"| fin

    classDef io fill:#ffffff,stroke:#333333,color:#000
    classDef logic fill:#d8f0d8,stroke:#2e7d32,stroke-width:2px,color:#000
    classDef wait fill:#fff3c4,stroke:#b58900,stroke-width:2px,color:#000
    classDef bad fill:#f8d7da,stroke:#b02a37,stroke-width:2px,color:#000
```

rd와 다른 규칙(RTL 식에서 읽은 것):

| 항목 | 규칙 | RTL |
|---|---|---|
| AW 발행 조건 | `act_q && aw_free && outs_q < olim_q && unc_q >= blen`. rd의 `space_q`(R 버퍼 여유) 대신 `unc_q`(버퍼에 이미 있는 beat)가 burst를 덮어야 한다. burst 단위 store-and-forward | `aw_go` |
| `unc_q` | `in_hs`마다 +1, `aw_go`마다 `blen`만큼 -1 | `unc_q` |
| WSTRB | 기본 8'hFF. 명령의 마지막 burst의 마지막 beat만 `lstrb_q`(길이가 8의 배수면 FF, 아니면 `(1 << (bytes mod 8)) - 1`) | `lstrb_q`, `aw_strb_q`, `m_axi_wstrb_o` |
| 오류 sticky | `err_resp_q`는 `b_hs && BRESP[1]`에서 세트. `err_cmd_q`는 거절 명령 handshake. `err_clr_i`와 같은 cycle이면 세트가 이긴다(rd와 같은 코드 순서). 데이터는 그대로 기록 | `err_resp_q`, `err_cmd_q` |
| 응답 | `BREADY` = 1 고정. 요청 없는 B는 tag `ENG_BUNEXP` | `m_axi_bready_o` |
| 버퍼 크기 | 기본 `FIFO_DEPTH` = `2 x MAX_BURST`. 이보다 작으면(`MAX_BURST`까지 허용) 처리율이 떨어진다(4절) | parameter |

## 3. 두 engine이 공유하는 하위 모듈

| 인스턴스 | 모듈 | rd | wr |
|---|---|---|---|
| `u_rbuf` | `sync_fifo` W = 65, DEPTH = `FIFO_DEPTH`(기본 `MAX_BURST x OUTS` = 64) | R beat와 last 표시 | - |
| `u_binfo` | `sync_fifo` W = 9, DEPTH = `OUTS` | burst 정보 {last_burst, blen - 1} | - |
| `u_wbuf` | `sync_fifo` W = 64, DEPTH = `FIFO_DEPTH`(기본 32) | - | 입력 beat |
| `u_wq` | `sync_fifo` W = 16, DEPTH = `OUTS` | - | AW를 낸 burst의 {awlen, strb} |
| `u_bq` | `sync_fifo` W = 1, DEPTH = `OUTS` | - | burst가 명령의 마지막인지 |

`sync_fifo`는 `in_ready_o`가 `out_ready_i`에 조합으로 의존하지 않는다(가득 찬 FIFO는 같은 cycle에 pop이 있어도 push를 받지 않는다).

## 4. 처리율 [측정, 시뮬레이션 모델, 보드 값 아님]

- 조건: Questa(버전은 `log.md`에 없음), `axi_mem_slave` 모델, 64 KiB(8,192 beat) 명령 하나, 메모리 stall 없음. 첫 beat부터 마지막 beat까지의 cycle. 출처: `docs/spec/hierarchy.md` 3.6(에이전트 측정값, 이 문서에서 재측정하지 않음).
- **이 표는 시뮬레이션 모델의 값이며 보드(HP 포트) 값이 아니다.** 실제 HP 포트의 latency와 대역폭은 `docs/spec/bwtest.md` 7절의 보드 측정 전까지 모른다. 메모리 latency 항목은 모델의 설정값이다(rd: AR에서 R까지, wr: 마지막 W에서 B까지).

| engine | burst | outs | 메모리 latency | cycle | beat/cycle |
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
| wr | 16 (`FIFO_DEPTH` 16) | 4 | 1 | 9,725 | 0.842 |
| wr | 1 | 4 | 1 | 16,382 | 0.500 |

- wr의 `FIFO_DEPTH` 32 행(burst 16, outs 2 이상)은 1.000이다. `FIFO_DEPTH` 16(= `MAX_BURST`)에서 0.842로 떨어지는 것은 burst 단위로 모은 뒤 AW를 내므로 다음 burst를 채울 자리가 없기 때문이라고 스펙이 설명한다(코드의 `aw_go` 조건 `unc_q >= blen`과 일치).
- outstanding 1에서 burst 사이의 빈 cycle은 왕복 지연(AR 제시 1 + 모델 latency + 버퍼 1 + 다음 AR 판단)이라고 스펙이 적었다.
- `bw_top`(P = 1, 2)의 64 KiB RD op `CYCLES`는 8,197(8,192 beat + 5 cycle의 시작과 종료 지연, 같은 모델).
