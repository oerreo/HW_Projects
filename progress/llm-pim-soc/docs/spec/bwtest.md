# HP 대역폭 측정 빌드: `bw_top` (S4-3)

상태: RTL 시뮬레이션 통과(2026-11-19, `sim/tests/bw_top.cfg`), 보드 미실행. 목적은 `arch.md` 9절 3번: Zybo Z7-20의 HP 포트 실측 대역폭(eta), outstanding과 burst 길이의 효과, 포트 2개 동시 사용을 재서 D2(가속기형 포트 수)와 `OUTS` 기본값을 정한다. 이 빌드는 GEMV IP의 G5가 아니라 측정 도구다.

- RTL: `rtl/l3/bw_top.sv` = `axil_slave` + CSR + 포트마다 `axi_rd_eng`(데이터는 checksum으로) + `axi_wr_eng`(pattern 생성기가 공급). engine 규칙은 `hierarchy.md` 3.6.
- FPGA: `fpga/bw/`(block design Tcl, 빌드 Tcl, Verilog shell, PS 프로그램, 실행 순서는 `fpga/bw/README.md`).
- 표기: 이 문서의 cycle 수와 MB/s는 시뮬레이션 모델 값이며 보드 값이 아니다. 보드 값은 사용자 실행 후 채운다.

## 1. 구성
```
PS7 M_AXI_GP0 -> interconnect -> bw_top s_axi (CSR, 0x43C00000, 4 KiB)
bw_top m_axi[0] -> interconnect -> S_AXI_HP0 (64 bit)
bw_top m_axi[1] -> interconnect -> S_AXI_HP2 (64 bit, P = 2)
FCLK_CLK0 (기본 100 MHz) 단일 클럭
```
- parameter: `P`(1, 2), `MAX_BURST`(engine burst 한도, 기본 16), `OUTS`(outstanding 한도, 기본 4), `RD_FIFO`(기본 `MAX_BURST x OUTS`), `WR_FIFO`(기본 `2 x MAX_BURST`), `FCLK_MHZ`(CONFIG 표시용).
- 런타임: burst 길이(`BURST`)와 outstanding 수(`OUTS`)를 op마다 레지스터로 바꾼다(빌드 한도 이하). bitstream 하나로 sweep한다.
- interconnect가 AXI4 master를 AXI3 HP 포트로 바꾼다. `MAX_BURST` > 16이면 거기서 burst가 쪼개진다.

## 2. op
CTRL 쓰기로 시작한다. 켜진 포트(`PORTS` mask)의 engine이 동시에 돈다.

| op | 동작 (켜진 포트 p마다) |
|---|---|
| 1 RD | `RD_ADDRp`에서 `LEN` byte 읽기. 64비트 beat를 버리면서 XOR와 SUM(mod 2^64) checksum. 마지막 beat의 `LEN` 밖 byte는 0으로 마스크 |
| 2 WR | `WR_ADDRp`에 `LEN` byte 쓰기. beat k = `PAT_p(k)`, `PAT_p(0) = {SEED_HI ^ p, SEED_LO}`, `PAT_p(k+1) = PAT_p(k) + 0x9E3779B97F4A7C15`(mod 2^64). byte i는 beat i/8의 lane i mod 8(little-endian). 마지막 beat는 WSTRB로 `LEN`까지만 |
| 3 RW | 1과 2를 같은 포트에서 동시에 |

## 3. 레지스터 맵 (32비트, offset은 byte, 공통 틀은 `arch.md` 7.2)

| offset | 이름 | 접근 | reset | 내용 |
|---|---|---|---|---|
| 0x00 | ID | R | 0x42570001 | [31:16] 0x4257("BW"), [15:0] 버전 1 |
| 0x04 | CONFIG | R | | [7:0] `FCLK_MHZ`, [11:8] `P`, [19:12] `OUTS`, [28:20] `MAX_BURST` |
| 0x08 | CTRL | W | | bit0 start, [5:4] op. 읽으면 0 |
| 0x0C | STATUS | R | 0 | bit0 busy, bit1 done_sticky, bit2 err_any(ERR != 0) |
| 0x10 | ERR | R/W1C | 0 | bit0 START_BUSY, bit1 BAD_OP, bit2 BAD_DESC, bit3 RD_RESP, bit4 WR_RESP, bit5 ENG_CMD |
| 0x14 | CYCLES | R | 0 | 마지막 op의 cycle 수 (4절) |
| 0x18 | RD_STALL | R | 0 | 포트 0의 RD_STALL과 같음(공통 틀 호환) |
| 0x1C | WR_STALL | R | 0 | 포트 0의 WR_STALL과 같음 |
| 0x20 | OPS | R | 0 | 끝난 op 수 |
| 0x40 | LEN | RW | 0 | 포트당 byte 수 (1..2^32-1) |
| 0x44 | BURST | RW | MAX_BURST | [8:0] burst당 beat (1..MAX_BURST) |
| 0x48 | OUTS | RW | OUTS | [6:0] outstanding burst (1..OUTS) |
| 0x4C | PORTS | RW | 1 | [1:0] 포트 enable mask |
| 0x50, 0x54 | SEED_LO, SEED_HI | RW | 0 | pattern seed |
| 0x60, 0x64 | RD_ADDR0, RD_ADDR1 | RW | 0 | read 시작 주소 (8 B 정렬) |
| 0x68, 0x6C | WR_ADDR0, WR_ADDR1 | RW | 0 | write 시작 주소 (8 B 정렬) |
| 0x80 + 0x20p | XOR_LO, XOR_HI, SUM_LO, SUM_HI, RD_CYC, WR_CYC, RD_STALL, WR_STALL | R | 0 | 포트 p 결과 (+0x00 .. +0x1C) |
| 0xC0 + 8p | RD_BEATS | R | 0 | 포트 p R handshake 수 |
| 0xC4 + 8p | WR_BEATS | R | 0 | 포트 p W handshake 수 |

- 정의되지 않은 주소(0x100 이상 포함, P = 1의 포트 1 결과)는 0을 읽고 쓰기는 무시한다. WSTRB는 무시한다(모든 쓰기는 32비트 전체). 응답은 항상 OKAY(`axil_slave`).
- 결과 레지스터는 op 시작 때 0이 되고 op 동안 갱신된다. 설정 레지스터는 op 중에도 쓸 수 있으나 진행 중인 op에는 영향이 없다(시작 때 latch).

## 4. 시작, 종료, 오류
- CTRL 쓰기가 `axil_slave`에서 수행되는 cycle을 s라 한다.
- busy 중의 CTRL 쓰기: start bit가 1이면 `START_BUSY`, 그 외 무시(진행 중인 op에 영향 없음).
- idle 중의 CTRL 쓰기: `done_sticky`를 지운다. start bit가 1이면 검사: op == 0이면 `BAD_OP`. 다음 중 하나면 `BAD_DESC`: `LEN` == 0, `BURST` 0 또는 > `MAX_BURST`, `OUTS` 0 또는 > `OUTS` parameter, `PORTS` == 0, `P` = 1인데 포트 1 enable, 쓰이는 engine의 주소가 8 B 정렬이 아님, 쓰이는 engine의 `주소 + LEN` > 2^32. 오류면 시작하지 않는다(done_sticky는 지워진 채, 결과 레지스터는 이전 값).
- 시작: busy = 1(s+1부터), engine 명령은 s+1에 수락된다. engine의 sticky 오류는 s에 지운다.
- 종료: 모든 쓰이는 engine이 done을 낸 cycle e에 busy = 0, done_sticky = 1, OPS + 1.
- `RD_RESP`/`WR_RESP`: op 중 RRESP/BRESP가 SLVERR/DECERR이면 set. 데이터는 그대로 처리되고 op는 끝까지 간다. `ENG_CMD`: engine이 명령을 거절하면 set. descriptor 검사가 거절 조건을 먼저 막으므로 도달하지 않는다(방어용).
- ERR는 W1C이고 같은 cycle의 새 오류가 이긴다. STATUS.err_any = ERR != 0.

### 시간 정의
- `CYCLES` = e - s (e = 마지막으로 끝난 engine의 done cycle). busy인 cycle 수와 같다.
- 포트 p read의 끝 e_rd = 마지막 beat가 engine을 떠난 cycle = 마지막 R handshake + 1(sink는 항상 ready). `RD_CYCp` = e_rd - s.
- 포트 p write의 끝 e_wr = 마지막 B handshake cycle. `WR_CYCp` = e_wr - s.
- `RD_STALLp` = read engine이 busy인데 beat가 없던 cycle 수. sink가 항상 ready라 `RD_STALLp = RD_CYCp - 1 - beats`(engine busy는 s+2부터).
- `WR_STALLp` = pattern 생성기에 beat가 있는데 write engine이 받지 않은 cycle 수.
- 대역폭: `MB/s = 옮긴 byte x f_PL / CYCLES`(MB = 10^6 B). RD/WR은 `LEN x 포트 수`, RW는 그 2배. 방향별 대역폭은 `RD_CYCp`, `WR_CYCp`로 따로 낸다. f_PL은 실제 FCLK_CLK0(Vivado가 보고한 값)이다.

## 5. PS 프로그램 (`fpga/bw/sw/bw_main.c`)
1. ID/CONFIG 확인, 오류 경로 4건(LEN 0, op 0, BURST 초과, 비정렬: 해당 ERR 비트만 서고 W1C로 지워짐).
2. 포트마다 읽기 버퍼(`0x10000000 + 0x02000000 p`, 8 MiB + 4 KiB)를 xorshift로 채우고 cache flush.
3. sweep A: 1 MiB, op RD/WR/RW x burst {1, 2, 4, ..., MAX_BURST} x outstanding {1, 2, 4, ..., OUTS} x 포트 mask {1, (3)}.
4. sweep B: burst = MAX_BURST, outstanding = OUTS, 길이 {8, 64, 4096, 4097, 65536, 1000003, 1 MiB, 8 MiB} x op x 포트 mask {1, (2, 3)}.
5. run마다 검사: ERR = 0, 끝남, RD는 ARM이 메모리에서 계산한 XOR/SUM과 일치, WR는 쓰기 버퍼(`0x14000000 + 0x02000000 p`)가 pattern과 같고 앞뒤 8 B guard 불변(쓰기 전 flush, 뒤 invalidate), beat 수 = ceil(LEN/8). 시작 주소는 run마다 버퍼 시작 + {0, 8, 16, 24}.
6. UART 출력 (115200 8N1):
```
BWTEST START plat=xil fclk_hz=100000000 quick=0
BWCFG id=0x42570001 config=0x01004164 p=1 outs=4 max_burst=16 fclk_mhz_cfg=100
BWNEG case=len0 err=0x04 exp=0x04 chk=OK
BW run=1 op=RD ports=1 len=1048576 burst=1 outs=1 cyc=... rcyc0=... rcyc1=0 wcyc0=0 wcyc1=0 rst0=... rst1=0 wst0=0 wst1=0 mbps10=... t_us=... err=0x00 chk=OK
...
BWTEST summary runs=... fails=0 ops=...
BWTEST RESULT: PASS
BWTEST END
```
`mbps10`은 MB/s x 10(정수). `t_us`는 ARM global timer로 잰 start 쓰기부터 polling 끝까지(AXI-Lite polling 포함). `chk`가 OK가 아니면 원인(`csum`, `wr_data`, `wr_guard`, `rd_beats`, `wr_beats`, `err`, `timeout`, `not_done`).

## 6. 시뮬레이션 검증 (2026-11-19)
- `tb/bw_top/tb_bw_top.sv`: AXI-Lite BFM(`tb/common/axil_bfm.sv`) + 포트마다 `axi_mem_slave`. op마다 TB가 독립 계산한 값과 비교: checksum(메모리 backdoor), 쓰인 메모리(pattern 식, guard), CYCLES/RD_CYC/WR_CYC(버스 handshake 시각), RD_STALL 항등식, beat 수, STATUS/ERR/OPS. CSR reset값과 read-back, 미사용 주소, BAD_DESC 규칙마다, BAD_OP, START_BUSY, 2^32 넘김, 주입한 SLVERR/DECERR.
- run: P = 1, 2 x 메모리 stall 프로파일 0/1/2, MAX_BURST/OUTS (16, 4), (256, 2), (1, 1), (8, 8). 9 run + 잘못된 parameter 1 run.
- 모델 값 [측정, 시뮬레이션]: stall 없는 메모리(latency 1)에서 64 KiB RD CYCLES 8,197(P = 1, 2 동일, 8,192 beat + 5), WR 8,212.

## 7. 보드 결과 (사용자 실행 후)
- 채울 것: 포트 1개와 2개의 RD/WR/RW MB/s(burst x outstanding 표), 8 MiB에서의 eta = 측정 MB/s / 800, RD_STALL 비율, ARM `t_us`와 `CYCLES / f_PL`의 차이(호출 오버헤드).
- 결정: D2(가속기형 포트 수), `OUTS` 기본값, `axi_rd_eng`의 `FIFO_DEPTH`.
