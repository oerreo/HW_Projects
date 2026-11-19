# L3 bw_top: HP 대역폭 측정 top

- 원본과 확인일: 확인일 2026-11-19. `rtl/l3/bw_top.sv`, `rtl/l1/axil_slave.sv`, `rtl/l1/axi_rd_eng.sv`, `rtl/l1/axi_wr_eng.sv`. 레지스터 맵과 시간 정의의 원본은 `docs/spec/bwtest.md`(이 문서는 요약이고 충돌하면 bwtest.md와 RTL이 우선).
- 상태: RTL 시뮬레이션 통과(`log.md` S4-3: `bw_top` 10 run 포함 `./sim/run.sh all` 164 run, fails 0 [측정, 수퍼바이저 재실행]). **보드는 미실행**이라 대역폭과 timing 값은 없다.
- 폭 표기: 기본 parameter(`P` 1, `MAX_BURST` 16, `OUTS` 4, `RD_FIFO` 64, `WR_FIFO` 32, `ADDR_W` 12). AXI master 주소는 32비트, 데이터는 64비트.
- 파형은 그리지 않았다.
- 이 모듈은 L3 control(CSR, op 순서, 카운터, checksum, pattern)이고 AXI 동작은 engine이 한다.

## 1. block diagram

```mermaid
flowchart LR
    ps["PS7 M_AXI_GP0<br/>AXI4-Lite"]:::ext
    axil["u_axil: axil_slave<br/>ADDR_W 12, DATA_W 32<br/>wr_en, wr_addr, wr_data<br/>rd_en, rd_addr, rd_data"]:::mod

    subgraph csr["CSR와 op 제어 (bw_top 본체)"]
        cfgr["설정 레지스터<br/>len_r 32b, burst_r 9b, outs_r 7b,<br/>ports_r 2b, seed_lo_r, seed_hi_r,<br/>rdaddr_r[2], wraddr_r[2]"]:::cut
        desc["start 판정<br/>start = start_req && !busy_q<br/>&& op != 0 && desc_ok"]:::logic
        opreg["op 레지스터 (start에서 latch)<br/>len_q 32b, burst_q 9b, outs_q 7b<br/>rd_a_q, wr_a_q 32b"]:::cut
        ctl["op 상태<br/>busy_q, done_q, err_q 6b,<br/>cnt_q 32b (CYCLES), ops_q 32b"]:::cut
        rmux["read mux<br/>ID, CONFIG, STATUS, ERR, CYCLES, OPS,<br/>설정 레지스터, 포트별 결과"]:::logic
    end

    subgraph port["포트 p (P개, g_port[p])"]
        rdeng["u_rd: axi_rd_eng<br/>AW 32, LEN_W 32, FIFO_DEPTH = RD_FIFO<br/>d_ready_i = 1 (sink 항상 ready)"]:::mod
        mask["last beat mask<br/>d_last && len_q[2:0] != 0:<br/>LEN 밖 byte를 0으로"]:::logic
        chk["checksum<br/>xor_q 64b, sum_q 64b (mod 2^64)"]:::cut
        pat["pattern 생성기<br/>src_d_q 64b, src_n_q 30b (남은 beat)<br/>seed: {seed_hi_r ^ p, seed_lo_r}<br/>+= 0x9E3779B97F4A7C15"]:::cut
        wreng["u_wr: axi_wr_eng<br/>AW 32, LEN_W 32, FIFO_DEPTH = WR_FIFO"]:::mod
        cnts["카운터 32b<br/>rdcyc_q, wrcyc_q, rdst_q, wrst_q,<br/>rdbt_q, wrbt_q"]:::cut
        flags["rd_fin_q, wr_fin_q<br/>rd_cmd_q, wr_cmd_q"]:::cut
    end

    hp["m_axi[p]<br/>AR, R, AW, W, B<br/>(HP 포트 p)"]:::ext

    ps --> axil
    axil -->|"wr_en, wr_addr, wr_data"| cfgr
    axil -->|"wr_en, wr_data"| desc
    cfgr --> desc
    desc -->|"start"| opreg
    desc -->|"start"| ctl
    cfgr --> opreg
    axil <-->|"rd_en, rd_addr / rd_data"| rmux
    ctl --> rmux
    cfgr --> rmux
    cnts --> rmux
    chk --> rmux

    opreg --> rdeng
    opreg --> wreng
    flags --> rdeng
    flags --> wreng
    rdeng -->|"d_valid, d_data 64b, d_last"| mask
    mask --> chk
    pat -->|"src_valid, src_d_q"| wreng
    wreng -->|"src_ready"| pat
    rdeng --> cnts
    wreng --> cnts
    rdeng <--> hp
    wreng <--> hp
    rdeng -->|"done, err_resp, err_cmd"| ctl
    wreng -->|"done, err_resp, err_cmd"| ctl

    classDef ext fill:#ffffff,stroke:#333333,color:#000
    classDef mod fill:#d8f0d8,stroke:#2e7d32,stroke-width:2px,color:#000
    classDef logic fill:#e3eefc,stroke:#3b6aa0,stroke-width:2px,color:#000
    classDef cut fill:#fff3c4,stroke:#b58900,stroke-width:2px,color:#000
```

- 초록 = 하위 모듈 인스턴스, 파랑 = 조합 논리, 노랑 = 레지스터.
- 두 engine의 `err_clr_i`는 `start`에 묶여 있다(op 시작 때 engine의 sticky 오류를 지움).
- `u_rd`의 `cfg_burst_i`/`cfg_outs_i`는 `burst_q`/`outs_q`, 명령은 `rd_cmd_q`, `rd_a_q`, `len_q`.
- `u_wr`의 데이터 입력은 pattern 생성기(`src_valid` = `src_n_q != 0`).
- AXI master 신호는 `[P-1:0]` packed 배열이고 포트 index가 맨 앞이다(`m_axi_*_o[p]`).
- `RD_STALL`(0x18)과 `WR_STALL`(0x1C)은 포트 0의 `rdst_q`, `wrst_q`와 같다.

## 2. op 흐름

CTRL 레지스터(0x08) 쓰기 하나가 op 하나를 시작한다. 아래는 RTL의 조건식(`start`, `desc_ok`, `all_done`, `err_set`)을 옮긴 것이다. 이 모듈에는 별도의 FSM state 레지스터가 없고 `busy_q`, `rd_fin_q`, `wr_fin_q`로 순서를 만든다.

```mermaid
flowchart TD
    w(["CTRL 쓰기<br/>wr_en, wr_w == R_CTRL<br/>wr_data[0] = start, [5:4] = op"]):::io
    q0{"busy_q ?"}:::logic
    sb["start bit = 1이면<br/>ERR.START_BUSY 세트<br/>그 외 무시, 진행 중인 op 영향 없음"]:::bad
    clr["done_q 지움 (idle 중 CTRL 쓰기)"]:::logic
    q1{"start bit = 1 ?"}:::logic
    q2{"op == 0 ?"}:::logic
    bo["ERR.BAD_OP 세트, 시작 안 함"]:::bad
    q3{"desc_ok ?<br/>LEN != 0, 1 <= BURST <= MAX_BURST,<br/>1 <= OUTS <= OUTS parameter,<br/>PORTS != 0, P = 1이면 포트 1 off,<br/>쓰이는 주소 8 B 정렬, 주소 + LEN <= 2^32"}:::logic
    bd["ERR.BAD_DESC 세트, 시작 안 함<br/>결과 레지스터는 이전 값"]:::bad
    st["start<br/>len_q, burst_q, outs_q, rd_a_q, wr_a_q latch<br/>busy_q = 1, cnt_q = 0<br/>결과 레지스터 0, pattern 시드 로드<br/>engine sticky 오류 지움<br/>rd_cmd_q / wr_cmd_q = use_rd / use_wr<br/>src_n_q = ceil(LEN / 8) (use_wr일 때)"]:::logic
    run["engine 동작 (켜진 포트 모두 동시에)<br/>cmd_ready에서 rd_cmd_q / wr_cmd_q 내림<br/>RD: beat를 checksum으로, WR: pattern beat 공급<br/>busy_q인 동안 cnt_q += 1"]:::logic
    q4{"모든 포트 p:<br/>(rd_fin_q || rd_done) && (wr_fin_q || wr_done) ?"}:::logic
    fin["all_done<br/>busy_q = 0, done_q = 1, ops_q += 1"]:::logic

    w --> q0
    q0 -->|"예"| sb
    q0 -->|"아니오"| clr
    clr --> q1
    q1 -->|"아니오"| e1(["끝: 레지스터 갱신 없음"]):::io
    q1 -->|"예"| q2
    q2 -->|"예"| bo
    q2 -->|"아니오"| q3
    q3 -->|"아니오"| bd
    q3 -->|"예"| st
    st --> run
    run --> q4
    q4 -->|"아니오"| run
    q4 -->|"예"| fin

    classDef io fill:#ffffff,stroke:#333333,color:#000
    classDef logic fill:#d8f0d8,stroke:#2e7d32,stroke-width:2px,color:#000
    classDef bad fill:#f8d7da,stroke:#b02a37,stroke-width:2px,color:#000
```

op 종류(CTRL[5:4]): 1 = RD, 2 = WR, 3 = RW. `op_rd_w` = `op[0]`, `op_wr_w` = `op[1]`. 포트 p는 `ports_r[p]`가 켜져 있을 때만 참여한다(`use_rd`, `use_wr`).

시간 정의(`bwtest.md` 4절과 RTL 코드가 같은 것을 확인):
- `CYCLES`(`cnt_q`) = busy인 cycle 수. `RD_CYCp` = `rd_done`이 `!rd_fin_q`인 cycle의 `cnt_q + 1`, `WR_CYCp`도 같은 식(`wr_done`).
- `RD_STALLp` = `rd_stall`(`axi_rd_eng`의 `stall_o`) cycle 수, `WR_STALLp` = `wr_stall`.
- `RD_BEATSp` = R handshake 수, `WR_BEATSp` = W handshake 수.

## 3. 레지스터 요약 (32비트, byte offset)

전체 표와 비트 정의는 `docs/spec/bwtest.md` 3절. 아래는 RTL의 `localparam` 이름과 읽기 mux(`rd_data`)로 교차 확인한 요약이다. 정의되지 않은 주소(0x100 이상 포함)는 0을 읽고 쓰기는 무시, WSTRB는 무시, 응답은 항상 OKAY.

| offset | 이름 | 접근 | 내용 |
|---|---|---|---|
| 0x00 | ID | R | 0x42570001 ("BW", 버전 1) |
| 0x04 | CONFIG | R | [7:0] `FCLK_MHZ`, [11:8] `P`, [19:12] `OUTS`, [28:20] `MAX_BURST` |
| 0x08 | CTRL | W | bit0 start, [5:4] op. 읽으면 0 |
| 0x0C | STATUS | R | bit0 busy, bit1 done_sticky, bit2 err_any(ERR != 0) |
| 0x10 | ERR | R/W1C | bit0 START_BUSY, 1 BAD_OP, 2 BAD_DESC, 3 RD_RESP, 4 WR_RESP, 5 ENG_CMD (6비트). 같은 cycle의 새 오류가 clear보다 우선 |
| 0x14 | CYCLES | R | 마지막 op의 cycle 수 |
| 0x18, 0x1C | RD_STALL, WR_STALL | R | 포트 0의 값 |
| 0x20 | OPS | R | 끝난 op 수 |
| 0x40 | LEN | RW | 포트당 byte 수 |
| 0x44 | BURST | RW | [8:0], reset = `MAX_BURST` |
| 0x48 | OUTS | RW | [6:0], reset = `OUTS` |
| 0x4C | PORTS | RW | [1:0] 포트 enable mask, reset 1 |
| 0x50, 0x54 | SEED_LO, SEED_HI | RW | pattern seed |
| 0x60, 0x64 | RD_ADDR0, RD_ADDR1 | RW | read 시작 주소 |
| 0x68, 0x6C | WR_ADDR0, WR_ADDR1 | RW | write 시작 주소 |
| 0x80 + 0x20p | XOR_LO, XOR_HI, SUM_LO, SUM_HI, RD_CYC, WR_CYC, RD_STALL, WR_STALL | R | 포트 p 결과(+0x00 .. +0x1C) |
| 0xC0 + 8p, 0xC4 + 8p | RD_BEATS, WR_BEATS | R | 포트 p의 R handshake 수, W handshake 수 |

- 설정 레지스터는 op 중에도 쓸 수 있지만 진행 중인 op에는 영향이 없다(`len_q` 등이 start에서 latch).
- 시스템 연결(`bwtest.md` 1절): PS7 `M_AXI_GP0` -> interconnect -> `bw_top` CSR(0x43C00000), `m_axi[0]` -> `S_AXI_HP0`, `m_axi[1]` -> `S_AXI_HP2`(P = 2), `FCLK_CLK0` 단일 클럭(기본 100 MHz). 이 연결은 `fpga/bw/`의 Vivado Tcl로 만들어지며 이 서버에서 확인하지 않았다(`log.md` S4-3 UNVERIFIED).
