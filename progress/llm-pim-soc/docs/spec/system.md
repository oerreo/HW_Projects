# 시스템 통합과 FPGA 검증 환경 스펙: llm-pim-soc (S5-0)

상태: **초안** (2026-11-20, S5-0). 오케스트레이터 검토 전. 열린 결정(9절)은 권고만 적었고 확정하지 않았다.

- 근거 문서: `spec/scope.md`, `spec/measure.md`(측정 정의, Amdahl 식), `spec/arch.md`(7절 HW/SW 인터페이스, 8절 자원, 12절 결정), `spec/hierarchy.md`, `spec/gemv_acc.md`, `spec/pim.md`, `spec/attn.md`, `spec/vec.md`, `spec/bwtest.md`, `model/src/fwd_h.c`(호출 순서), `model/src/kern.h`(kernel descriptor), `fpga/sw/`(ARM baseline), `fpga/bw/`(Vivado Tcl과 bare-metal 선례), `fpga/README.md`.
- 표기: **[측정, 시뮬레이션]** Questa에서 잰 값(`axi_mem_slave` latency 1, stall 없음, 보드 아님). **[계산]** 구성이나 시뮬레이션 값에서 식으로 구한 값(`docs/spec/s5calc.py`로 재현). **[추정]** 가정이 들어간 값. **[미확인]** 출처나 동작을 확인하지 못한 것. **[미측정]** 보드에서 잴 값(비어 있음).
- 이 문서에는 보드 측정값이 하나도 없다. ARM baseline(S3), HP 대역폭(`fpga/bw/`)은 사용자 실행 대기다. 100 MHz는 목표 클럭이며 timing 달성 여부, LUT 수, 실제 BRAM 매핑은 합성 전이다.
- 재현: `python3 -I docs/spec/s5calc.py`(표준 라이브러리만, 인자 없음).

## 0. 요약
- **bitstream 2개**: 빌드 A(15M 주 대상, 가속기형 GEMV + DDR KV attention + vec)와 빌드 P(260K, PIM형 GEMV + BRAM KV attention H_PAR 2 + vec). 빌드 A의 attention을 TMAX 512로 두면 260K도 돌아가므로, 260K의 가속기형과 PIM형 GEMV 비교(권장 후보 C)를 별도 bitstream 없이 A와 P로 얻는다(1.1절).
- **kernel 하나씩 오프로드는 SW mask로 얻는다**: kernel 경계가 DDR 버퍼(arch.md D11)이고 forward가 순차라 IP가 동시에 돌 일이 없다. 한 bitstream 안에서 kernel 범주마다 "ARM `k_exec`" 대 "IP 호출"을 런타임 mask로 고른다. 한 ELF가 mask 목록을 차례로 실행한다(2.2절).
- **SW**: `model/src`의 forward에 실행기(executor) 끼움점을 하나 추가하고(`lm_h_forward_x`, 열린 결정 O3), `fpga/sys/sw/`에 실행기, IP 드라이버 4개, 초기화(행 레코드, LDW), 측정과 로그를 둔다. baseline(`fpga/sw/`)의 플랫폼 계층, 로그 형식, 기대값 헤더, 파서를 재사용한다(2절).
- **호스트 검증**: (i) C 수준: spec 문서로 쓴 IP 레지스터 모델 + cache 일관성 모사(CPU 메모리와 DDR 이미지를 따로 두고 flush/invalidate 때만 복사)로 모든 mask 조합을 PC에서 기대값과 대조. (ii) RTL 수준: L4 top(`sys_a_top`, `sys_p_top`) + 공유 메모리 모델 + AXI-Lite BFM에, 같은 드라이버 C 코드를 DPI로 연결해 RTL을 구동하고 forward 위치를 token과 logits hash까지 PC 기대값과 대조(G5 기준, 3절).

## 1. 빌드 목록

### 1.1 한 bitstream + 오프로드 mask로 "kernel 하나씩"을 얻을 수 있는가
판단: **얻을 수 있다.** 근거와 한계는 아래와 같다.

| 근거 | 내용 |
|---|---|
| kernel 경계 = DDR 버퍼 (arch.md D11) | 모든 IP가 golden과 같은 버퍼(또는 초기화 때 만든 행 레코드, bank image)를 읽고 쓴다. ARM `k_exec`와 IP 호출이 같은 입력에서 같은 출력을 내므로(G4 bit-exact) kernel 단위로 섞어도 결과가 같다 |
| forward는 순차 | 한 시점에 kernel 하나만 실행된다. 여러 IP가 PL에 있어도 동시에 HP를 쓰지 않으므로, 켜지 않은 IP는 측정에 영향이 없다 [추정: idle IP가 DDR에 접근하지 않음은 RTL 구조상 참, 전력과 열은 보지 않음] |
| IP 상태 | PIM bank(초기화 1회 LDW)와 BRAM KV(위치마다 KVW)만 상태가 있다. bank는 mask와 무관하게 초기화에서 적재하고, BRAM KV는 "ATTN을 켠 실행은 위치 0부터"라는 규칙(2.2절)으로 처리한다 |

한계:
- parameter(H_PAR, P, KV_SRC, N_MAX)는 bitstream마다 고정이다. H_PAR 1 대 2, P 1 대 2 비교는 bitstream이 달라야 한다(9절 O2, O12).
- bitstream 사이의 비교는 "같은 kernel의 단독 시간"과 "같은 mask의 end-to-end"로 한다. ARM 코드는 같은 ELF 소스이며 PL 배치만 다르다.
- mask 0(전부 ARM) 실행을 각 빌드에서 다시 재서 S3 baseline(PL 없음)과 비교한다. 차이가 측정 오차 수준이면 PL이 ARM 측정에 영향을 주지 않는다는 근거가 된다.

### 1.2 빌드 표

| 빌드 | L4 top | IP와 parameter | 대상 모델 | 목적(얻는 측정) |
|---|---|---|---|---|
| **A** | `sys_a_top` | `gemv_acc_top` P 1 / `attn_top` H_PAR 1, KV_SRC 1(DDR), HS_MAX 64, TMAX 512 / `vec_top` N_MAX 1024, IDX_W 16 | 15M(주), 260K(비교) | 15M: kernel별 오프로드(GEMV, cls + argmax 융합, attention DDR, vec 4종)와 end-to-end. 260K: 가속기형 GEMV의 단독 시간과 GEMV만 켠 end-to-end(빌드 P의 PIM과 비교). DDR 스트리밍 IP의 eta 실측 |
| **P** | `sys_p_top` | `pim_top` NB 4, LB 16, DEPTH 4096 / `attn_top` H_PAR 2, KV_SRC 0(BRAM), HS_MAX 8, TMAX 512, NKV 4, NL 5, KW 12, VW 8 / `vec_top` N_MAX 1024 또는 256(9절 O7), IDX_W 16 | 260K | PIM형 GEMV(bank 상주)와 BRAM KV attention의 kernel별 오프로드, 전부 오프로드 end-to-end. PIM 호출 묶음 방식(호출 단위, 같은 x 묶음)에 따른 호출 오버헤드 |
| A2 (선택) | `sys_a_top` | A에서 `gemv_acc_top` P 2(HP0 + HP2) | 15M | D2(포트 수) 결정용. HP 대역폭 측정(`bwtest.md`)에서 포트 2개 동시 대역폭이 포트 하나의 1.5배 이상일 때만 만든다(9절 O12) |
| 대안 PD | `sys_p_top` | P에서 attention을 KV_SRC 1(DDR), H_PAR 2로 | 260K | 빌드 P가 BRAM 한도를 넘을 때(1.6절)의 대체. PIM GEMV 측정은 그대로 얻고 "KV 상주" 전제만 잃는다 |

- 권장 후보 C(260K 비교용 가속기형 GEMV)는 따로 만들지 않는다. 빌드 A의 IP가 260K를 그대로 받는다: `gemv_acc_top` NMAX 1024 >= 172, `attn_top` DDR 빌드는 HS_MAX 64 >= 8, TMAX 512 = 260K seq_len, KVMUL 2 지원, `vec_top` N_MAX 1024. A의 attention 구성(KV_SRC 1, HS_MAX 64, TMAX 512)은 `attn_top.cfg`의 `D2` 구성으로 이미 15M을 통과했고, 같은 구성의 260K(hs 8)는 S5-4 시스템 TB(`a_m1` 등, 3.2절)에서 실행했다.
- GEMV 두 구조의 공정한 비교: 두 빌드 모두 mask = GEMV만(그 밖은 ARM)으로 260K를 돌리면 ARM 쪽 일이 같고 GEMV만 다르다. attention까지 켠 비교는 attention 구성(BRAM 대 DDR, H_PAR)이 섞이므로 따로 표시한다.
- 병합안 PC(빌드 P에 `gemv_acc_top` P 1 추가, bitstream 1개로 비교)는 [계산] DSP 160/220, BRAM36 126~128.5/140이라 자원상 불가능하지 않으나, BRAM이 빡빡한 빌드에 IP와 HP 공유(read 채널 5개 > 포트 4개)를 더하는 위험에 비해 얻는 것(같은 bitstream)이 작아 권고하지 않는다(9절 O1).
- 15M을 빌드 P에서 돌리면 PIM(DEPTH 4096 < 15M 행렬), attention(BRAM KV NKV 4, HS_MAX 8)은 쓸 수 없다. vec는 N_MAX 1024이면 15M의 RMSNORM, SWIGLU, ACTQ를 받는다. 실행기는 초기화 때 CONFIG 레지스터로 IP별 사용 가능 여부를 정한다(2.3절).

### 1.3 HP/GP 포트 배정
HP 포트 하나는 read 채널과 write 채널이 독립이다. 그래서 IP 하나의 read master와 다른 IP의 write master를 한 HP 포트에 함께 둘 수 있고, 이때 interconnect에 중재가 필요 없다(L4 top 안에서 채널을 배선만 한다).

| 포트 | 빌드 A | 빌드 P | 폭 |
|---|---|---|---|
| M_AXI_GP0 | L4 top의 `s_axi`(AXI-Lite, 아래 주소 맵) | 같음 | 32 |
| S_AXI_HP0 | R: `gemv_acc` slice 0, W: `gemv_acc` | R: `pim`, W: `pim` | 64 |
| S_AXI_HP1 | R: `attn` engine 0, W: `attn` | R: `attn` engine 0, W: `attn` | 64 |
| S_AXI_HP2 | 사용 안 함(A2: R `gemv_acc` slice 1) | R: `attn` engine 1, W: 없음(tie-off) | 64 |
| S_AXI_HP3 | R: `vec`, W: `vec` | R: `vec`, W: `vec` | 64 |

- [계산, s5calc 3b] A: read master 3, write master 3. P: read master 4, write master 3. 모두 HP 4개 안.
- HP0/HP1과 HP2/HP3이 DDR 컨트롤러 포트를 공유한다는 자료는 [미확인](arch.md 7.1). kernel이 순차라 v1 측정에는 영향이 없고, 동시 사용이 생기는 A2(GEMV 두 포트)만 영향을 받는다. HP0과 HP2를 쓰는 이유가 이것이다(`fpga/bw/`와 같은 선택).
- 각 HP 포트 앞에는 AXI4 -> AXI3(HP) 변환용 interconnect를 하나씩 둔다(`fpga/bw/create_project.tcl`의 HP 포트마다 interconnect 하나와 같다). IP의 ID 폭(IDW 1)과 HP의 ID 폭(6) 차이도 여기서 맞춘다.
- interrupt: v1은 polling이다(arch.md 7.1). IP에는 done interrupt 출력이 없으므로 IRQ_F2P는 연결하지 않는다. interrupt가 필요하면 L4 top에서 STATUS.done 펄스를 내는 것을 S5 이후에 검토한다.
- 클럭과 리셋: FCLK_CLK0(요청 100 MHz) 하나, `proc_sys_reset`의 `peripheral_aresetn`을 모든 IP의 `rst_n`으로. CDC 없음(arch.md 전제).

### 1.4 주소 맵
**PL 레지스터 (GP0)**: L4 top 안의 `axil_xbar`(1 -> N, 9절 O4 권고안)가 `s_axi` 하나를 4 KiB slot으로 나눈다. 빌드와 무관하게 slot 번호를 IP 종류에 고정한다.

| 주소 | slot | IP | ID 레지스터(0x00) 값 | 빌드 A | 빌드 P |
|---|---|---|---|---|---|
| 0x43C0_0000 | 0 | `gemv_acc_top` | 0x47410001 ("GA") | 있음 | 없음 |
| 0x43C0_1000 | 1 | `pim_top` | 0x50490001 ("PI") | 없음 | 있음 |
| 0x43C0_2000 | 2 | `attn_top` | 0x41540001 ("AT") | 있음 | 있음 |
| 0x43C0_3000 | 3 | `vec_top` | 0x56450001 ("VE") | 있음 | 있음 |
| 0x43C0_4000 ~ 0x43C0_FFFF | 4~15 | 없음 | 0 | | |

- xbar는 빈 slot의 읽기에 0, 쓰기는 무시, 응답은 OKAY를 낸다(IP들의 "정의되지 않은 주소" 규칙과 같다). 그래서 SW가 모든 slot의 ID를 읽어 빌드 구성을 알아낼 수 있다(빈 slot이 DECERR이면 bare-metal에서 data abort가 난다).
- 범위: GP0 segment 0x43C0_0000, 64 KiB. IP의 `ADDR_W` 12(4 KiB)는 그대로.
- xbar를 두지 않는 안(O4 b)이면 BD interconnect가 IP마다 64 KiB segment(0x43C0_0000, 0x43C1_0000, ...)를 주고, 빌드 구성은 컴파일 시점 상수로 SW에 준다.

**DDR (HP와 ARM이 공유, 물리 주소 = HP 주소)**: baseline(`fpga/sw/src/bcfg.h`)의 배치를 그대로 쓴다.

| 영역 | 주소 | 크기 | IP 접근 |
|---|---|---|---|
| 프로그램(코드, 데이터, 스택) | 0x0010_0000 ~ | 상한 255 MiB | 없음 |
| 15M checkpoint, tokenizer | 0x1000_0000, 0x1400_0000 | 60,816,028 B, 433,869 B | 없음(ARM이 양자화 입력으로만) |
| arena(모델 메모리) | 0x1800_0000 ~ | 상한 639 MiB | **IP가 접근하는 모든 버퍼는 arena 안**: H판 가중치와 상태(`lm_h_build`, `lm_h_alloc`), 행 레코드, q 레코드, K 모드 그림자 버퍼 |

- 추가 메모리 [계산, s5calc 1]: 행 레코드 260K 288,704 B, 15M 15,586,816 B(H판 가중치 15,187,968 B는 ARM 경로용으로 그대로 둔다). q 레코드 nh x (8 + 2 hs) = 192 B / 624 B. K 모드 p 버퍼 nh x 8 ceil(seq/2) = 16 KiB / 6 KiB. arena 한도에 비해 작다.
- HP의 DDR segment가 0x1800_0000 이상 전체를 덮는지는 Vivado의 `assign_bd_address` 결과로 확인한다(`fpga/bw/create_project.tcl`의 검사와 같은 방식) [미확인].

### 1.5 자원 예산 (XC7Z020: DSP 220, BRAM36 140, LUT 53,200)
DSP는 S4 문서의 [계산](구조에서 센 곱셈기 타일, `gemv_acc.md` 6b, `pim.md` 8, `attn.md` 8, `vec.md` 8), BRAM36은 S4 문서의 메모리 목록을 다시 센 [계산], LUT는 arch.md 8절의 모듈별 범위에 xbar(0.1k~0.3k, 이 문서의 [추정])를 더한 [추정]이다. 합성은 하지 않았다.

모듈별 BRAM36 [계산]:

| 모듈 | 메모리 | BRAM36 (하한~상한) | 비고 |
|---|---|---|---|
| `gemv_acc_top` P 1 | x buffer 128 x 64 | 0 ~ 0.5 | LUTRAM 또는 BRAM18 |
| `pim_top` | bank 4 x (144 x 4096) + `pim_gb` 2 x (64 x 64) | 64 ~ 65 | bank는 512 x 72 두 개 폭 x 8 깊이, **parity 비트를 데이터로 쓸 때** |
| `attn_core` (engine마다) | p buffer 512 x 32 + vs buffer 512 x 25 | 1 | BRAM18 2개 |
| `kv_store` | kv head 4 x (210 x 2560) | 60 | 512 x 72 세 개 폭 x 5 깊이, **parity 사용 시** |
| `vec_top` N_MAX 1024 | `actq_core` buffer + 공유 front buffer, 각 1024 x 32 | 2 | |
| `vec_top` N_MAX 256 | 같은 것, 각 256 x 32 | 0 ~ 1 | LUTRAM 또는 BRAM18 |
| `sync_fifo`(engine FIFO, 명령 FIFO, y FIFO) | 비동기 읽기 레지스터 배열 | 0 | BRAM으로 추론될 수 없는 구조(`rtl/l0/sync_fifo.sv`의 조합 읽기) |

빌드별 합 [계산, s5calc 3; LUT는 추정]:

| 빌드 | DSP | BRAM36 | LUT [추정] |
|---|---|---|---|
| A (ga P1 + at H1 DDR + ve 1024) | 11 + 33 + 16 = **60 (27%)** | **3 ~ 3.5 (2%)** | 11.1k ~ 20.3k (21 ~ 38%) |
| A' (A에서 attention H_PAR 2, O2) | 93 (42%) | 4 ~ 4.5 | 14.6k ~ 26.3k |
| A2 (A에서 ga P 2) | 71 (32%) | 3 ~ 4 | 12.6k ~ 22.3k |
| **P** (pim + at H2 BRAM + ve 1024) | 67 + 66 + 16 = **149 (68%)** | 64 + 60 + 2 + 2 = **128 ~ 129 (91 ~ 92%)** | 14.4k ~ 25.8k (27 ~ 48%) |
| P (ve N_MAX 256, O7) | 149 (68%) | 126 ~ 128 (90 ~ 91%) | 같음 |
| PD (P에서 KV를 DDR로) | 149 (68%) | 66 ~ 68 (47 ~ 49%) | 15.1k ~ 27.3k |
| PC (P + ga P1, 병합안) | 160 (73%) | 126 ~ 128.5 | 16.9k ~ 29.8k |

- BRAM 수치 정리: arch.md 8절 126(vec 1, attention engine당 0.5), attn.md 8절 127(attention engine당 1), vec.md 8절 129다. 이번 재집계는 64 + 60 + 2 + 2 = **128**(vec N_MAX 1024)이다. vec.md의 129는 attn.md의 127에 들어 있던 vec 추정 1을 빼지 않고 2를 더한 것으로 보인다(이 문서는 128을 쓴다). 여기에 `pim_gb`와 gemv x buffer가 BRAM18로 가는 경우의 상한을 더해 범위로 적었다.
- 빌드 A의 attention은 HS_MAX 64라 V 누산기(64 x 60비트 FF)와 o 읽기 mux(64:1, 60비트)가 260K 구성(HS_MAX 8)보다 크다. arch.md의 engine당 LUT 3k~5k는 HS_MAX를 구분하지 않은 추정이라 A에서는 넘을 수 있다 [추정].
- DSP는 Vivado가 작은 곱(상수곱 `d x 47274`, LUT 보간 8x8, int8 x int8)을 LUT로 보내면 줄어든다. 위 값은 모두 DSP로 간다는 가정의 상한 쪽이다.

### 1.6 위험과 대안
| 위험 | 내용 | 대안 |
|---|---|---|
| **P의 BRAM (128~129/140)** | 남는 11~12개 안에 Vivado가 넣는 것(interconnect FIFO 설정에 따라)이 들어가야 한다. 더 큰 위험은 parity 비트: `pim_bank`(144비트)와 `kv_store`(210비트)가 512 x 72 폭의 parity 비트를 데이터로 써야 64 + 60이 된다. 추론형 `ram_sdp`가 그렇게 매핑되는지는 [미확인](arch.md D6, 12절 조건). 안 되면 bank 96 + KV 80 + 4 = **180/140** [계산]으로 넘친다 | (1) `fpga/` wrapper에서 RAMB36E1을 직접 인스턴스(72비트 SDP, design-methodology가 허용하는 위치). RTL `ram_sdp`와 같은 포트로 두고 parameter로 교체. (2) vec N_MAX 256(BRAM 최대 2 절약, O7). (3) 빌드 PD(KV를 DDR로, BRAM 66~68): PIM 측정은 그대로, attention은 DDR 대역폭에 묶인다. (4) 빌드 분할: P1 = pim + vec(attention은 ARM), P2 = attention BRAM KV + vec. kernel 단독 측정은 얻지만 "전부 오프로드" end-to-end를 260K에서 한 bitstream으로 잴 수 없다 |
| P의 DSP 149 (68%) | 여유는 있다. H_PAR 4는 215(98%)라 하지 않는다(arch.md D8) | - |
| 100 MHz timing | arch.md 8절, pim.md 8절, attn.md 8절, vec.md 8절의 경로(64비트 shifter, 58비트 곱 사슬, 60비트 누산, bank 깊이 mux + gather mux, 24x34 곱) [추정, 미측정]. 시스템에서는 IP 4개가 한 FPGA에서 배치를 다툰다 | 각 IP의 PIPE parameter로 단을 추가(`gemv_scale` PIPE, `pim` SCALE_PIPE/DOT_PIPE, `attn` 4개 PIPE). PIPE를 바꾸면 그 IP의 TB를 그 값으로 다시 돌린다(대부분의 TB에 PIPE 변형 run이 이미 있음). 그래도 안 되면 FCLK를 낮춘다(측정은 FCLK 실제값으로 환산) |
| AXI4 -> AXI3 변환 | HP 포트에 interconnect를 거쳐 붙이는 방식은 `fpga/bw/`와 같고 그 빌드도 보드 미실행이다 [미확인] | `fpga/bw/` 보드 결과를 먼저 받는다. 실패 원인을 bw 빌드에서 가린다 |
| 빌드 A의 LUT | HS_MAX 64 attention과 HP interconnect 3개 | A'(H_PAR 2)와 A2(P 2)는 A의 utilization을 본 뒤 정한다 |

### 1.7 L4 top과 block design
- `rtl/l4/axil_xbar.sv`(신규, control RTL): AXI4-Lite 1 -> N, 주소 [15:12]로 slot 선택, 트랜잭션 하나씩(읽기와 쓰기 각 1 outstanding), 빈 slot 읽기 0, 응답 OKAY. 단독 TB 필요(G3/G4).
- `rtl/l4/sys_a_top.sv`, `rtl/l4/sys_p_top.sv`(신규): `axil_xbar` + IP 3개의 인스턴스와 배선만(design-methodology의 상위 모듈 규칙). 포트: `s_axi`(AXI-Lite, 주소 16비트) 하나, `m_hp0_axi` ~ `m_hp3_axi`(AXI4 64비트, 1.3절 표대로 IP의 read 채널과 write 채널을 묶음; 쓰지 않는 채널은 valid 0, ready 1로 tie-off), `clk`, `rst_n`. parameter는 1.2절 표 값을 기본으로 하고 IP parameter를 그대로 내보낸다.

**S5-2에서 확정한 세부 (2026-11-20, 시뮬레이션 통과, 보드와 합성 전)**

`axil_xbar` (parameter `N` 1..2^SLOT_W, `SLOT_W` 1..4, `S_ADDR_W` 12 + SLOT_W..32, `SLOT_EN`(bit k = slot k 있음, N 이상 bit는 0), `REG` 0/1; 잘못된 값은 elaboration 실패):
- 주소: slot = addr[12 +: SLOT_W](SLOT_W 4: [15:12]), slave에는 addr[11:0]만 간다. slot >= N, SLOT_EN 0인 slot, addr[S_ADDR_W-1:12+SLOT_W] != 0(범위 밖)은 "없는 slot": slave에 가지 않고 읽기는 0, 쓰기는 무시, 응답 OKAY. 있는 slot의 BRESP/RRESP/RDATA는 그대로 전달한다(IP는 항상 OKAY이나 xbar는 SLVERR/DECERR도 통과시킨다).
- write(AW, W, B)와 read(AR, R) 경로는 독립. 경로마다 1 outstanding: 다음 AW/W(AR)는 앞 트랜잭션의 master 쪽 B(R) handshake 뒤에만 받는다. AW와 W는 어느 순서로, 어느 간격으로 와도 된다. WSTRB, AxPROT는 그대로 전달.
- `REG = 1`(기본, 시스템 top의 `XB_REG` 기본값): master 포트와 slave 포트 사이에 어느 방향으로도 조합 경로가 없다(모든 출력이 flip-flop 또는 상수). `localparam LAT_REQ = 1`, `LAT_RSP = 1`: slave AWVALID = master AW handshake + 1, slave WVALID = max(AW, W handshake) + 1(W는 slot을 안 뒤에 낸다), slave ARVALID = AR handshake + 1, master BVALID / RVALID = slave B / R handshake + 1(slave BREADY / RREADY는 요청을 낼 때부터 1). 없는 slot: BVALID = max(AW, W handshake) + 1, RVALID = AR handshake + 1.
- `REG = 0`: 조합 통과(`LAT_REQ = LAT_RSP = 0`). AW/AR VALID와 READY, B/R는 같은 cycle에 통과하고 W는 AW handshake 뒤에만 받는다. 없는 slot: BVALID = W handshake + 1, RVALID = AR handshake + 1.
- [측정, Questa, TB slave 모델: READY 항상 1, 요청 handshake 다음 cycle에 응답] 단일 트랜잭션: REG 1 읽기(AR handshake -> master RVALID) 3 cycle, 쓰기(마지막 AW/W handshake -> BVALID) 3 cycle; REG 0 각 1 cycle. back-to-back 주기(master가 응답 다음 cycle에 다음 요청): REG 1 있는 slot 읽기 4, 쓰기 4, 없는 slot 2, 2 cycle; REG 0 있는 slot 읽기 2, 쓰기 3(W가 AW 다음 cycle), 없는 slot 2, 3 cycle. IP의 `axil_slave`(요청 handshake c -> 응답 VALID c + 2)를 붙이면 그 지연이 더해진다. 실제 GP0 왕복 시간은 보드 측정 전이다 [미측정].
- 시뮬레이션 검사(`ifndef SYNTHESIS`, tag): `L4_XB_AW`/`L4_XB_W`/`L4_XB_AR`(master VALID/payload가 READY 전에 바뀜), `L4_XB_B`/`L4_XB_R`(slave 응답이 READY 전에 바뀜), `L4_XB_UNEXP`(요청 없는 slave 응답).

slot 표 (GP0 0x43C0_0000 기준, xbar `S_ADDR_W` 16, `N` 4, slot 4..15는 N 밖이라 없는 slot):

| slot | 주소 | 빌드 A (`SLOT_EN` 4'b1101) | 빌드 P (`SLOT_EN` 4'b1110) | ID / CONFIG (기본 parameter, TB 확인) |
|---|---|---|---|---|
| 0 | 0x43C0_0000 | `gemv_acc_top` (`u_ga`) | 없음(0) | 0x4741_0001 / 0x0400_3164 (A2: 0x0400_3264) |
| 1 | 0x43C0_1000 | 없음(0) | `pim_top` (`u_pi`) | 0x5049_0001 / 0x0400_4464, CONFIG2 0x0020_1000 |
| 2 | 0x43C0_2000 | `attn_top` (`u_at`) KV_SRC 1 | `attn_top` (`u_at`) KV_SRC 0 | 0x4154_0001 / A 0x0200_3964, P 0x0200_3264 (PD 0x0200_3A64); CONFIG2 A 0x0000_0040, P 0x0005_0408 (PD 0x0000_0008); CONFIG3 A 0, P 0x0200_080C (PD 0) |
| 3 | 0x43C0_3000 | `vec_top` (`u_ve`) | `vec_top` (`u_ve`) | 0x5645_0001 / 0x0400_1064 |
| 4..15 | 0x43C0_4000 ~ | 없음(0) | 없음(0) | 0 |

HP 포트 배정 (구현, 1.3절 표와 같음):

| 포트 | `sys_a_top` read / write | `sys_p_top` read / write |
|---|---|---|
| `m_hp0_axi_*` | `u_ga` slice 0 / `u_ga` | `u_pi` / `u_pi` |
| `m_hp1_axi_*` | `u_at` engine 0 / `u_at` | `u_at` engine 0 / `u_at` |
| `m_hp2_axi_*` | `GA_P` 2(A2)이면 `u_ga` slice 1, `AT_H_PAR` 2(A')이면 `u_at` engine 1, 아니면 tie-off / tie-off | `AT_H_PAR` 2(기본)이면 `u_at` engine 1, 1이면 tie-off / tie-off |
| `m_hp3_axi_*` | `u_ve` / `u_ve` | `u_ve` / `u_ve` |

- 포트 이름 규칙: `s_axi_<ch>_<i|o>`(AXI4-Lite, `S_ADDR_W` 비트 주소), `m_hp<k>_axi_<ch>_<i|o>`(k = 0..3, AXI4 master, 데이터 64비트, ID `IDW` 비트; 방향 접미사는 이 모듈 기준). HP 포트마다 read 채널 묶음(AR, R)과 write 채널 묶음(AW, W, B)을 모두 두고, 두 빌드의 포트 목록이 같다(block design shell 하나로 두 빌드를 받기 위함). 쓰지 않는 채널 묶음은 VALID 0, RREADY/BREADY 1, 그 밖의 출력 0이다. 한 HP 포트의 read 묶음과 write 묶음을 서로 다른 IP가 쓸 수 있는 구조이며(배선만), 현재 배정에서 그런 포트는 없다(HP2는 read만 쓴다).
- parameter 이름: 공통 `S_ADDR_W`(16), `XB_REG`(1), `IDW`(1), `MAX_BURST`(16), `OUTS`(4), `FCLK_MHZ`(100); IP별 접두사 `GA_*`(gemv_acc), `PI_*`(pim), `AT_*`(attn), `VE_*`(vec)로 IP parameter를 그대로 내보낸다. 기본값은 1.2절 표의 빌드 값. elaboration 검사: `sys_a_top` GA_P 1/2, AT_H_PAR 1/2, GA_P 2와 AT_H_PAR 2 동시 금지(HP2 read 중복); `sys_p_top` AT_H_PAR 1/2.
- 클럭과 리셋: `clk`, `rst_n` 하나를 xbar와 IP 3개에 그대로 준다(top 안의 로직 없음).
- 검증: `sim/tests/axil_xbar.cfg`(단독 TB, 30 run), `sim/tests/sys_a_top.cfg`, `sys_p_top.cfg`(smoke, `tb/sys_top/tb_sys_top.sv`: slot ID/CONFIG, IP마다 호출 하나를 golden(DPI)과 대조, 호출마다 traffic이 나간 HP 포트 확인, tie-off 매 cycle 확인). HP 포트마다 독립 메모리 모델이라, 두 HP 포트가 같은 버퍼를 봐야 하는 시험(IP 사이 kernel 연쇄, forward)은 S5-3의 공유 메모리 모델로 미룬다. lint: `sim/.lint8`(xbar 4개 구성, `sys_a_top` 기본/A2/A' + XB_REG 0, `sys_p_top` 기본/PD/H_PAR 1 + XB_REG 0, `vlog`/`vopt -lint=full`) 경고 0.
- Vivado block design(`fpga/sys/create_project.tcl BUILD=A|P`, `fpga/bw/create_project.tcl`을 바탕으로): PS7(GP0, 쓰는 HP 포트, FCLK0, board preset) + `proc_sys_reset` + ctrl interconnect(GP0 -> `s_axi`) + HP 포트마다 interconnect + module reference(Verilog shell `fpga/sys/src/sys_<a|p>_bd.v`, bw의 `bw_bd.v`와 같은 방식). L4 top은 SystemVerilog라 module reference가 Verilog shell을 요구하는 점도 bw와 같다 [미확인, bw와 같은 위험].

## 2. SW 구조

### 2.1 계층
```
sys_main.c          BEGIN/END, BUILD/PLAT/SYS 줄, 모델마다 sbench
  sbench.c          H판 하나를 mask 목록마다 run E / T / P / K (bench.c의 구조, 같은 KEY)
    lm_h_forward_x  model/src/fwd_h.c (kernel 호출 순서의 유일한 원본) + hook(probe) + exec(실행기)
      sx_exec       실행기: mask 판정, 보호 조건, ARM k_exec 또는 드라이버, 지연 실행과 barrier,
                    일관성(flush/invalidate) 규칙, 호출 단위 시간 분해, K 모드 비교
        drv_ga.c drv_pi.c drv_at.c drv_ve.c   IP별 드라이버 (레지스터 순서, polling, 오류)
          hal.h     plat.h 확장: io32 읽기/쓰기, flush/invalidate 범위, dsb, PL reset, FCLK
            hal_xil.c (보드) | hal_host.c (호스트: IP C 모델 + cache 모사) | hal_dpi.c (RTL 시스템 TB)
```
- 재사용(수정 없음): `fpga/sw/src/`의 `plat.h`/`plat_xil.c`/`plat_host.c`(시간, UART, DDR 이미지, arena), `out.c`(로그 한 줄), `lmhash.c`, `expect.h`/`exp.c`와 `fpga/sw/expect/exp_m*.h`(PC 기대값: 위치별 token, logits hash), `prof.c`(lap probe, 행렬 구분). baseline ELF(`fpga/sw/`)는 그대로 두어 S3 측정과 비교 기준을 유지한다.
- `model/src` 변경(O3 권고안): `fwd_h.c`의 `run()`이 `k_exec`를 부르는 자리를 실행기 함수 포인터로 바꿀 수 있게 `lm_h_forward_x(s, c, w, tok, pos, hook, exec)`를 추가하고, `lm_h_forward(...)`는 `exec = NULL`(지금과 같은 `k_exec`)로 그것을 부른다. 기존 호출자는 바뀌지 않는다. 바꾼 뒤 `make test` PASS와 기존 덤프 `cmp` 동일을 확인한다(hierarchy.md 4절 원칙).
- (S5-1 구현) 실행기 형식은 `k_exec_t { k_exec_fn fn; void *user; }`, `int k_exec_fn(void *user, const kcall_t *c)`(`model/src/llm.h`). 덤프 4종 `cmp` 동일, `make test` 16,686,497 항목 mismatch 0(새 그룹 `forward_x executor` 16,704 항목 포함, `model/results/maketest_s5_1.txt`). hal 계층은 `plat.h`를 확장하지 않고 별도 `fpga/sys/sw/hal.h`로 두었다(`hal_rd/wr(slot, off)`, `hal_pa`, `hal_flush/inval/flush_all`, `hal_dsb`, `hal_arena`, 호스트 전용 `hal_env`와 일관성 검사 `hal_arm_rd/wr`). arena는 hal이 준다(호스트는 4 KiB 정렬, 보드는 `ARENA_ADDR`). 드라이버 공통 코드는 `drv_com.c`.

### 2.2 실행기 (`sx_exec`)
kernel 호출마다 `kcall_t`(kid, prm, 버퍼 포인터)를 받는다. 버퍼 포인터와 초기화 때 등록한 `lm_hs_t`, `lm_hw_t`로 행렬(가중치 포인터), layer와 kv head(`kc` 안의 offset), 위치(T = prm[0])를 알아낸다. 행렬 구분은 `prof.c`의 `hprof_setup`과 같은 방식이다.

**mask 비트** (런타임, run마다 하나):

| 비트 | 이름 | kernel (kcall) | 빌드 A의 IP | 빌드 P의 IP |
|---|---|---|---|---|
| 0 | G | K_GEMV (q, k, v, o, w1, w3, w2) | `gemv_acc` | `pim` |
| 1 | C | K_GEMV (cls) | `gemv_acc` | `pim` |
| 2 | A | K_ATTN2 (head마다) | `attn` DDR KV | `attn` BRAM KV (+ KVW) |
| 3 | R | K_RMSNORM | `vec` | `vec` |
| 4 | S | K_SWIGLU | `vec` | `vec` |
| 5 | Qh | K_ACTQ (K, V cache, q head; n = hs) | `vec` | `vec` |
| 6 | Qa | K_ACTQ (attention 출력, n = D) | `vec` | `vec` |
| 7 | M | K_ARGMAX | `vec`, 또는 C와 함께 켜고 opt.FUSE_AM이면 `gemv_acc`의 `argmax_en`(별도 IP 호출 없음) | `vec` |

**opt 비트** (호출 방식, 9절 O9): `DEFER_AT`(attention을 layer 단위 op 하나로 묶음, 기본 1), `PIM_BATCH`(같은 x를 쓰는 연속 GEMV의 MACAB을 한 RUN으로, 기본 0), `WRGB_SKIP`(x의 세대가 같으면 WRGB 생략, 기본 1), `FUSE_AM`(빌드 A에서 cls + argmax 융합, 기본 1), `COH_STRICT`(IP 시작 전 출력 범위도 flush, 디버그용, 기본 0).

**보호 조건**: IP로 보내기 전에 descriptor가 IP의 지원 범위인지 확인하고, 아니면 ARM `k_exec`로 실행하고 `fallback` 수를 센다(K12V8 두 모델에서는 0이어야 한다. 0이 아니면 run FAIL).

| IP | 조건 (IP 문서의 BAD_DESC와 같거나 더 좁게) |
|---|---|
| GEMV (둘 다) | gs = n, n <= NMAX, rows <= 65535, 행렬이 초기화 표에 있음(행 레코드 또는 bank base) |
| ATTN | K_ATTN2, kb, vb in {8, 12, 16}, hs % 8 == 0, hs <= HS_MAX, T <= TMAX, 형식의 `win` = 0, `exp_bits` = 8(IP의 EXP2N 표), KV_SRC 0이면 hs <= KL, NKV, NL, KW >= kb, VW >= vb가 모델과 맞음 |
| RMSNORM, SWIGLU, ACTQ | mode = MANT, n <= N_MAX, SWIGLU `sig_bits` = 8, ACTQ qmax in {127, 2047, 32767} |
| ARGMAX | n <= 2^IDX_W |

**지연 실행과 barrier**: golden은 attention을 head마다, GEMV를 행렬마다 부른다. 그대로 IP를 부르면 (1) H_PAR 2 attention의 두 engine 중 하나만 일한다(op 하나가 head 하나면 engine `(h / KVMUL) mod H_PAR`이 하나뿐), (2) PIM은 레코드마다 run이라 token당 PL cycle이 5,822~5,852다(token 한 run 4,499~4,506 [측정, 시뮬레이션, latency 1, stall 없음]. 이전에 적은 약 6,950은 stall이 있는 run의 값이었다, 3.2절 끝). 그래서 실행기가 호출을 모았다가 한 번에 낸다.
- `DEFER_AT`: ATTN(head j) 호출 때 `qh`, `qhs`를 q 레코드 j에 복사하고, j < nh - 1이면 IP를 부르지 않고 돌아온다. 마지막 head(또는 barrier)에서 ATTN op 하나(HEAD0 0, NHEAD nh)를 낸다. golden에서 그 사이의 호출은 다음 head의 ACTQ(q)뿐이고 이것은 `qr`를 읽고 `qh`에 쓴다. `att`와 `p`를 읽는 호출은 layer의 모든 head 뒤에 온다.
- `PIM_BATCH`: x 포인터와 x 세대가 같은 연속 K_GEMV는 MACAB만 FIFO에 넣고 돌아온다(layer당 q/k/v, o, w1/w3, w2 묶음 4개 + cls = 260K 21 run [계산, s5calc 2]).
- **barrier 규칙**: 미뤄 둔 일이 있을 때, 다음 호출이 미뤄 둔 묶음에 들어갈 수 있는 종류(ATTN 묶음에는 ACTQ(q head)와 ATTN, PIM 묶음에는 같은 x의 K_GEMV)가 아니면 먼저 미뤄 둔 것을 실행하고 완료를 기다린다. forward 끝(argmax 뒤)도 barrier다. 이 규칙은 "미뤄 둔 호출의 출력을 읽는 호출은 반드시 barrier를 거친다"를 보장하므로 forward 순서의 세부 지식에 기대지 않는다.
- **x 세대**: `a8`/`as`에 쓰는 모든 호출(RMSNORM, SWIGLU, ACTQ(att), ARM이든 IP든)이 세대를 하나 올린다. WRGB 생략은 (x 포인터, 세대)가 마지막 WRGB와 같을 때만.
- **BRAM KV(KV_SRC 0)**: 위치 pos의 layer l에서 첫 ATTN을 낼 때 그 앞에 KVW(layer l, POS pos, kv head 0..NKV-1, 원본은 golden `kc/vc/kcs/vcs`의 layer base)를 낸다. ATTN을 켠 run은 위치 0부터 돈다(run 중간에 A를 켜지 않는다). 예외: 시스템 TB의 warm start는 `sx_kv_sync(upto)`로 지난 위치의 KVW를 몰아 낸다(3.2절).
- **(S5-1 구현에서 정한 세부)**
  - 사용 가능 여부(모델마다, `AVAIL` 줄): G, C는 `gemv_acc`가 있거나 `pim`이 있고 lane 16과 bank 깊이(누적 word <= DEPTH)가 맞을 때, A는 `attn`이 있고 모델이 K_ATTN2 형식(창 없음, exp_bits 8)이며 BRAM KV면 hs <= KL, hs <= HS_MAX, nkv <= NKV, L <= NL, kb <= KW, vb <= VW, seq <= TMAX일 때, vec 비트는 `vec`가 있을 때. 사용 가능하지 않은 비트를 요구하는 (mask, opt)는 run하지 않고 `SKIP`을 찍는다(fallback이 아님). 15M을 빌드 P에서 돌리면 PIM(237,312 word > 4,096)과 BRAM KV(hs 48 > KL 8) 때문에 G, C, A가 빠진다.
  - 보호 조건에 더한 것: GEMV xm < 2^17, we/xe/fo가 signed 8비트(EXP, CMD3 필드 폭), vec의 f/fy/ge가 signed 8비트와 epsc >= 0, ATTN은 descriptor의 kb/vb/hs가 모델과 같고 K 포인터에서 계산한 첫 위치가 0(창 없음), kv head = j / KVMUL, j < 64(실행기 표 크기). 실패하면 ARM으로 실행하고 `fb`. timeout으로 꺼진 IP의 호출도 `fb`로 센다.
  - IP 출력 invalidate(소비자 규칙 3의 구체화): y of q, k, o, w2는 항상(ARM rope, add), v는 Qh가 ARM일 때, w1/w3은 S가 ARM일 때, cls는 run T/P/K(hash)이거나 ARGMAX를 ARM이 할 때(FUSE_AM이면 제외), `as`, `qh`, `qhs`는 항상(`fwd_h.c`가 다음 descriptor를 만들며 읽고, q 레코드 복사가 읽는다), a8은 다음 GEMV(final rmsnorm 뒤는 C, 그 밖은 G)가 ARM일 때, K/V slot은 A가 ARM일 때, att는 Qa가 ARM일 때. run K는 모든 IP 출력을 invalidate한다. ARGMAX index는 레지스터에서 읽어 ARM이 `s->argmax[0]`에 쓰고 그 4 B를 flush한다(vec ARGMAX의 OUT_ADDR도 `s->argmax`).
  - barrier: 쌓인 ATTN 묶음에는 K_ATTN2(같은 layer, 같은 T, 다음 head)와 q head ACTQ만 들어가고, PIM 묶음에는 IP로 가는 같은 x 주소와 같은 x 세대의 K_GEMV만 들어간다. run P에서는 hook이 barrier 실행을 직전 lap과 분리해 묶음의 범주(ATTN: attn, PIM: 묶음 첫 행렬의 범주)에 넣는다. KVW는 attn 범주.
  - run 종류 W(warm start, 호스트와 시스템 TB용): 위치 0..S-2를 mask 0으로, 전체 flush, (BRAM KV면) `sx_kv_sync(S - 1)`, 위치 S-1을 mask로. token과 hash는 모든 위치에서 비교한다.

**cache 일관성 규칙** (ACP를 쓰지 않으므로 ARM이 유지한다, arch.md 7.1):
1. run 시작 때 전체 `Xil_DCacheFlush`(baseline과 같음). 초기화 끝에도 전체 flush(행 레코드, 가중치, g 배열이 DDR에 있게).
2. **생산자 flush**: mask가 0이 아닌 run에서, ARM이 실행한 kernel의 출력 버퍼(`kbuf_t.out`)는 실행 직후 `Xil_DCacheFlushRange`. 드라이버가 만든 q 레코드도 같다.
3. **소비자 invalidate**: IP 호출이 끝나면, 그 출력을 ARM이 읽을 일이 이 run에 있으면(아래 의존 표의 소비자 중 ARM이 실행하는 것이 있거나, run T/P/K의 logits hash) 출력 범위를 `Xil_DCacheInvalidateRange`.
4. IP 시작 전에 출력 범위를 flush할 필요는 없다: 규칙 1, 2로 IP가 쓰는 범위에는 dirty line이 없다(각 버퍼의 ARM 쪽 쓰기는 모두 규칙 2로 곧바로 clean). `COH_STRICT`는 이 불변식이 깨졌는지 보는 디버그 옵션이다.
5. IP 시작 쓰기(CTRL) 전에 `dsb`(flush 함수의 끝에 있다고 보나 [미확인] 드라이버가 명시적으로 넣는다).
- 같은 cache line(Cortex-A9 L1과 PL310 L2 모두 32 B로 알려져 있으나 이 작업에서 출처를 열지 않았다 [미확인])을 IP 출력과 ARM 데이터가 나눠 쓰는 경우(예: `kc`의 이웃 slot)도 규칙 2 덕분에 그 line은 clean이라 invalidate가 ARM 데이터를 잃지 않는다.

버퍼 의존 표 (`fwd_h.c`):

| 버퍼 | 생산자 | 소비자 |
|---|---|---|
| `x` (int32 D) | K_EMBED, K_ADD (ARM) | K_RMSNORM, K_ADD |
| `a8`, `as` | K_RMSNORM, K_ACTQ(att), K_SWIGLU | K_GEMV(다음 묶음), GEMV 드라이버가 `as`를 레지스터로 읽음 |
| `q`, `k`, `v` (int32) | K_GEMV q, k, v | K_ROPE(q, k, ARM), K_ACTQ(V) |
| `qr`, `kr` | K_ROPE (ARM) | K_ACTQ(q head), K_ACTQ(K) |
| `kc/vc/kcs/vcs` slot | K_ACTQ(K, V) | K_ATTN2(이후 모든 위치), KVW |
| `qh`, `qhs` | K_ACTQ(q head) | K_ATTN2(ARM) 또는 ATTN 드라이버의 q 레코드 복사 |
| `att` | K_ATTN2 | K_ACTQ(att) |
| `y` | K_GEMV o, w2 | K_ADD (ARM) |
| `h1`, `h3` | K_GEMV w1, w3 | K_SWIGLU |
| `logits` | K_GEMV cls | K_ARGMAX, run T/P/K의 hash(ARM) |
| `argmax` | K_ARGMAX | ARM(다음 token) |
| `p` | K_ATTN2 | 없음(K 모드 비교만) |

### 2.3 초기화
1. `lm_h_build`, `lm_h_alloc`(baseline과 같음, 64 B 정렬 arena), `VAR whash` 검사.
2. IP 탐지: slot마다 ID, CONFIG(, CONFIG2/3) 읽기. 로그 `SYS`. IP별, 모델별 사용 가능 여부를 정한다(예: 빌드 P의 attention은 CONFIG2의 NKV 4, NL 5, CONFIG의 TMAX 512, KV_SRC 0이라 260K만).
3. GEMV 가속기형(빌드 A): 행렬마다 `rrec_pack`(`model/src/bank.c`)으로 행 레코드를 arena에 만들고 표(가중치 포인터 -> W_ADDR, RB)에 등록. 시간과 byte를 `INIT kind=rrec`로.
4. PIM(빌드 P): 같은 행 레코드를 만들고, 행렬마다 bank base를 누적 배정(`sum ceil(rows/4) x ceil(n/16)` = 4,072 / 4,096 word [계산, s5calc 1]; 순서는 `vt` job bimg와 같게 해서 TB의 bank image 비교를 재사용한다, S5-1에서 확인), LDW 명령 36개를 push(FIFO 32라 여유를 보며 나눠서, pim.md 4.3), RUN, 완료 대기. ST_* 카운터와 CYCLES를 `INIT kind=ldw`로. bank를 다시 읽는 명령이 없으므로(RDROW 미구현) 적재 결과는 K 모드의 GEMV 비교와 token 일치로 확인한다.
5. 전체 `Xil_DCacheFlush`.
- BRAM KV는 초기화가 필요 없다(ATTN은 T 이하의 위치만 읽고, 위치 0부터 KVW로 쓴다).

### 2.4 IP별 드라이버
공통: 레지스터 쓰기는 바뀐 것만(드라이버가 쓴 값의 그림자를 둔다), `CTRL` 쓰기 뒤 STATUS를 busy = 0까지 polling(검사 cycle 포함), 그 뒤 done_sticky = 1이면 정상, 아니면 ERR. run P/K에서만 CYCLES, RD_STALL, WR_STALL, (PIM) ST_*를 읽는다(run E는 최소 드라이버).

| IP | 호출 순서 | flush/invalidate 범위 (2.2 규칙에 따른 것) |
|---|---|---|
| `gemv_acc` | W_ADDR(표), X_ADDR = `a8`, Y_ADDR = y, ROWS, N, XM = `as.m`, EXP = {we, `as.e`, 16}, FLAGS(y_en 1, cls이고 FUSE_AM이면 argmax_en 1), `CTRL = 0x11`, polling, (argmax_en) ARGMAX_IDX를 `s->argmax[0]`에 씀 | 입력: 없음(행 레코드는 초기화, `a8`는 생산자 규칙). `as`는 생산자가 IP면 그 호출 뒤에 이미 invalidate됨. 출력: y 4 x rows B(소비자가 ARM일 때). logits(128,000 B, 15M)는 run E에서 소비자가 없으면(FUSE_AM 또는 M이 IP) invalidate하지 않음 |
| `pim` | (x 세대가 바뀌었으면) WRGB push, MACAB push(base, rows, n, xm, we/xe/fo, y), PIM_BATCH가 아니면 `CTRL = 0x11` RUN과 polling. push마다 CMD0..3 + CMD_PUSH 5회 쓰기, FIFO 여유는 STATUS[23:8] + push_busy로 | 출력: MACAB마다 y. 묶음이면 barrier에서 묶음의 y 전부 |
| `attn` | (BRAM KV, layer의 첫 ATTN) KVW: K/V/KS/VS_ADDR = layer base, SEQ, LAYER, POS, KVH = {NKV, 0}, HS, FMT, `CTRL = 0x21`, polling. ATTN: Q_ADDR = q 레코드, O_ADDR = `att`, (K 모드) P_ADDR + p_en, T, HS, FMT{kb, vb}, HEAD = {KVMUL, NHEAD, HEAD0}, (DDR KV) K/V/KS/VS_ADDR = layer base, SEQ, LAYER, `CTRL = 0x11`, polling | 입력: q 레코드(드라이버가 만들고 flush). KV slot은 생산자 규칙. 출력: `att` 4 x hs x NHEAD B(ACTQ(att)가 ARM이면), (K 모드) p |
| `vec` | IN0, IN1, OUT, SCL, N, FMT, EXP, EPSC 중 바뀐 것, `CTRL = op << 4 | 1`, polling, (ARGMAX) ARGMAX_IDX를 `s->argmax[0]`에 | 출력: q(N qb B), scale 8 B(다음 GEMV 드라이버가 `as`를 읽으므로 IP 생산이면 항상 invalidate), ARGMAX는 레지스터로 읽어 메모리 invalidate 없음 |

**오류 처리**:
- polling 한도: global timer로 max(10 ms, 예상 PL 시간 x 100) [정의]. 넘으면 `IPERR kind=timeout`, 그 IP를 이 프로그램의 남은 run에서 끄고(그 비트를 ARM으로) run을 FAIL로 표시. PL reset(SLCR `FPGA_RST_CTRL`)으로 복구를 시도하는 것은 선택이다(주소와 잠금 해제 순서 [미확인], 9절 O11). reset 뒤에는 PIM bank를 다시 LDW해야 한다.
- ERR != 0: 원인별 비트를 `IPERR`로 찍고 W1C. BAD_OP/BAD_DESC/MISALIGN/BAD_CMD/FIFO_OVF/PUSH_BUSY/START_BUSY는 드라이버 버그(보호 조건과 순서로 막혀 있어야 함)라 run FAIL. RD_RESP/WR_RESP는 버스 오류라 run FAIL(데이터는 IP가 끝까지 쓰므로 프로그램은 계속).
- 오류 run의 시간은 표에서 뺀다(파서가 FAIL run을 표시).

### 2.5 golden 버퍼 배치 대 IP 배치
| kernel / IP | 버퍼 | golden 배치 | IP가 요구하는 배치 | 차이와 변환 | 비용이 드는 곳 [계산 또는 미측정] |
|---|---|---|---|---|---|
| GEMV 가속기형 | W, m | `lm_hm_t.q` int8 [rows x n] + `m` u16 [rows] | 행 레코드: 행마다 header 8 B(wm) + ceil(n/8) x 8 B(0 padding), 8 B 정렬 | 재배치(`rrec_pack`) | 초기화 1회(ARM 시간 [미측정], `INIT kind=rrec`). 메모리 260K 288,704 B, 15M 15,586,816 B [계산]. token마다 HP 트래픽: header가 pad8 대비 15M 2.63%, 260K 10.78%(arch.md 2.2 정의), header와 padding을 합해 int8 가중치 대비 15M 2.63%, 260K 11.33% [계산, s5calc 5 끝] |
| GEMV 둘 다 | x | `a8` int8 [n] | 같음, 8 B 정렬 | 없음(lm_take 64 B 정렬) | - |
| GEMV 둘 다 | xm, xe | `as` (kscl_t, 메모리) | 레지스터(XM, EXP) 또는 MACAB 명령 필드 | ARM이 `as`를 읽어 레지스터로 | 호출마다 `as` line invalidate(생산자가 IP일 때) + 레지스터 쓰기 [미측정]. 융합 후보 F2 |
| GEMV 둘 다 | y | int32 [rows] | 같음, 8 B 정렬. 홀수 rows는 마지막 beat WSTRB | 없음 | 소비자 invalidate 4 x rows B |
| GEMV PIM | W, m | 위와 같음 | bank image(BANK_ROW, 144비트 word, tag = wm) | 행 레코드 -> LDW(IP가 변환) | 초기화 1회: LDW 36,629 cycle = 366.3 us @100 MHz [계산, 입력은 시뮬레이션] + 행 레코드 생성 [미측정] |
| GEMV PIM | x | `a8` | global buffer(WRGB) | IP가 읽음 | WRGB 호출 수: 매번 36, 세대 생략 21(260K token당) [계산] |
| ATTN | q | `qh` int16 [hs] + `qhs` {m, e} 따로 | q 레코드 {int32 qm, int32 qe, int16 q[hs]}(QB = 8 + 2 hs = 24 B / 104 B), head마다 `Q_ADDR + h QB` | 드라이버가 복사(ARM) | head마다 24 B / 104 B 복사 + flush [미측정]. 융합 후보 F1, 또는 ACTQ(q)가 IP일 때 OUT_ADDR = 레코드 + 8, SCL_ADDR = 레코드로 직접 쓰게 하는 방식(F1a) |
| ATTN | K, V, scale | `kc` int16, `vc` int8, `kcs`/`vcs` {m, e}, slot `((l nkv + j) seq + pos)` | DDR KV: 같은 배치, layer base와 SEQ를 레지스터로. BRAM KV: KVW가 같은 배치에서 읽어 `kv_store`에 씀 | 없음(DDR) / 위치마다 KVW(BRAM) | BRAM: KVW layer당 1 op, 48 cycle(260K token당 240) [측정, 시뮬레이션] + 호출 비용 [미측정] |
| ATTN | o | `att + j hs` int32 | `O_ADDR + 4 hs h` | 같음 | 소비자 invalidate 4 D B |
| ATTN | p | `p` int32 [T] 하나를 head마다 덮어씀 | `P_ADDR + h 8 ceil(T/2)`(head 간격을 8 B로 올림) | K 모드에서만 별도 버퍼(nh x 8 ceil(seq/2) B) | K 모드만 |
| ATTN | LUT | `w->elut`(포인터로 전달) | IP 내부 ROM(`lut_pkg.sv`, `tabs.c`에서 생성) | 전달 없음. 보호 조건으로 exp_bits = 8 확인 | - |
| RMSNORM | x, g, q, scale | int32, int16(`w->ra[l].g`), int8, {m, e} | 같음 | 없음 | - |
| SWIGLU | h1, h3, LUT, q, scale | int32, int32, `w->slut`, int8, {m, e} | 같음, LUT는 IP ROM(sb = 8) | 없음 | - |
| ACTQ | v, q, scale | int32, int8(qmax 127) 또는 int16, {m, e}. K/V는 `kc/vc` slot 안 | 같음 | 없음 | - |
| ARGMAX | v, idx | int32 [n], int32 [1] | 같음 + ARGMAX_IDX 레지스터 | 레지스터로 읽음 | - |
| 전체 | 정렬 | `lm_take` 64 B 정렬, sub-buffer offset(slot 16/96 B, 8/48 B, 8 B, head 32/192 B, layer base) | 시작 주소 8 B 정렬(MISALIGN), 길이는 임의 | 모든 offset이 8의 배수 [계산, s5calc 1b] | 없음 |

- 결론: 변환이 실제로 일어나는 곳은 (1) 가중치 행 레코드(초기화 1회, 두 GEMV IP 공통), (2) PIM bank 적재(초기화 1회), (3) attention q 레코드(head마다 작은 복사), (4) BRAM KV의 KVW(위치와 layer마다 op 하나), (5) GEMV scale의 레지스터 전달이다. 나머지는 golden 버퍼를 그대로 쓴다(arch.md D11의 의도대로).

### 2.6 측정 항목과 로그 형식
measure.md의 a, b, c를 호출 하나에서 ARM global timer로 겹치지 않게 나눈다. 드라이버 안의 시각 t0(진입), t1(입력 쪽 준비 끝: q 레코드 복사, 입력 flush, push), t2(CTRL 쓰기 끝), t3(polling 끝), t4(출력 invalidate와 카운터 읽기 끝), PL 카운터 CYCLES, RD_STALL, WR_STALL, f_PL(Vivado가 보고한 실제 FCLK, 빌드 상수).

| 항목 | 정의 [정의] | measure.md |
|---|---|---|
| `pl` | (CYCLES - RD_STALL - WR_STALL) / f_PL | a: PL 순수 연산 |
| `mv` | (t1 - t0) + (t4 - t3의 invalidate 부분) + (RD_STALL + WR_STALL) / f_PL + 이 kernel이 ARM에서 실행될 때의 생산자 flush | b: 데이터 이동(cache 유지, 변환, PL이 데이터를 기다린 시간) |
| `call` | (t3 - t1) - CYCLES / f_PL + (t4 - t3의 레지스터 읽기 부분) | c: AXI-Lite 설정, 시작, polling, 완료 확인 |
| `arm` | ARM에서 실행된 `k_exec` 시간 | ARM 쪽 kernel 시간 |

- arch.md 7.3은 a = CYCLES / f_PL로 두고 b에 RD_STALL / f_PL을 더해 stall을 두 번 세었다. 이 문서는 a에서 stall을 빼서 a + b + c = 호출의 ARM 측 총 시간이 되게 한다(lap 방식처럼 겹침 없는 분할).
- 지연 실행된 호출은 복사와 판단만 하고 돌아오므로 시간 대부분이 묶음을 실제로 내는 호출(마지막 head 또는 barrier)에 잡힌다. 범주별 합은 그대로 맞다.
- run E는 분해하지 않는다(시각 읽기도 하지 않는 최소 드라이버). run P가 분해를 하고, P와 E의 차이로 분해 비용을 본다(measure.md 3절의 `P vs E %`와 같은 방식).

로그(baseline 형식에 추가. 한 줄 한 항목, `KEY name=value`):

| KEY | 필드 | 의미 |
|---|---|---|
| `SYS` | build slots(ga,pi,at,ve 있음 표시) id_* cfg_* (at) kv_src h_par tmax hs_max (ve) n_max fclk_hz | 빌드 구성과 IP 확인 |
| `INIT` | m kind(rrec, ldw) ticks bytes cyc (ldw) st_wrgb st_mac st_rdmac | 초기화 비용 |
| `RUN` | (기존) + mask opt | run 합계. mask와 opt로 run을 구분 |
| `KERN` | (기존) + mask | kernel 범주별 lap 시간. 기존 범주에 변화 없음 |
| `KSPLIT` | m v mask k calls_ip calls_arm calls_fb arm pl mv call cyc rd_stall wr_stall ops | 범주 k의 분해(ticks). `arm + pl + mv + call`과 `KERN` ticks의 차이가 hook과 분해 비용 |
| `KCMP` | m v mask k calls mis first_pos first_call first_idx exp got | run K: kernel 단위 출력 비교 |
| `IPERR` | m v mask ip kind(timeout, err) err pos call | IP 오류 |
| `CHECK` | (기존) + mask | token, logits hash(위치마다 PC 기대값), K 모드 mismatch |

- 파서(`fpga/sw/tools/parse_log.py`)를 확장해 (m, v, mask, opt)마다 표를 만들고, mask 0 대비 가속비, KSPLIT 합 검사, Amdahl 예측(4.2절)과 실측을 나란히 낸다.
- (S5-1 구현) 블록은 `LMSYS BEGIN fmt=1` .. `LMSYS END`. 더한 키: `CLK tps`, `AVAIL m v avail build why rrec_bytes bank_words`, `SKIP m v mask opt avail`, `COH`(호스트 cache 모사의 첫 오류와 수: `m v run mask opt n old kind what k pos addr`). 모든 run 줄(`RUN`, `KERN`, `KSPLIT`, `KCMP`, `CHECK`, `COH`, `IPERR`)에 `run mask opt`를 둔다. `KSPLIT`/`KCMP`의 k는 KERN 범주에서 actq를 `actq_h`(Qh), `actq_a`(Qa)로 나눈 것이다(KERN actq = 둘의 합). `KCMP mis`는 다른 원소 수, `CHECK`는 `kmis coh fb iperr`를 더해 요구 합이 0일 때만 PASS. `IPERR`는 run당 16줄까지 찍고 수는 `CHECK iperr`에 정확히 센다. 파서는 CHECK 요구 합, KCMP 합 = CHECK kmis, COH n = CHECK coh, KSPLIT(arm + pl + mv + call) <= KERN(범주마다), MSUM(실패 run 수 + 데이터 검사), RESULT를 다시 계산한다. 형식 전체는 `fpga/sys/README.md` 1절.

### 2.7 정합성 검사
| run | 내용 | 통과 |
|---|---|---|
| E | 계측 없음. 위치마다 token을 PC 기대값(`exp_m*.h`의 H판 K12V8)과 비교 | tok_mis = 0 |
| T | 위치마다 시간. token + logits hash(위치마다) | tok_mis = 0, hash_mis = 0 |
| P | lap probe + KSPLIT. token + hash | 같음 |
| K | IP 호출마다 같은 입력으로 ARM `k_exec`를 그림자 버퍼에 실행해 IP 출력과 byte 비교(묶음은 barrier 뒤 호출별로, attention은 p_en = 1로 head별 p도). 시간은 보고하지 않음 | KCMP mis = 0, tok/hash mismatch 0 |

- mask가 무엇이든 token과 logits hash는 mask 0과 같아야 한다(G4 bit-exact의 시스템 수준 확인). 다르면 K run이 어느 kernel, 어느 위치, 어느 원소인지 보여준다.
- `fallback` 수(보호 조건으로 ARM에 남은 호출)는 0이어야 한다.

### 2.8 파일 구성 (제안)
```
fpga/sys/
  create_project.tcl   BUILD=A|P (+ A2, PD 변형), bw의 구조 재사용: PS7, reset, ctrl/HP interconnect, module reference, 주소 검사
  build.tcl            bw의 build.tcl 재사용(합성, 구현, bitstream, XSA, 리포트, summary.txt)
  filelist.tcl, zybo_z7_20.xdc, src/sys_a_bd.v, src/sys_p_bd.v
  sw/  sys_main.c sbench.c sx_exec.c sx_exec.h drv_ga.c drv_pi.c drv_at.c drv_ve.c drv.h ipregs.h
       sysmem.c(행 레코드, bank base, q 레코드) hal.h hal_xil.c xsct_build.tcl
  test/ hal_host.c ipm_ga.c ipm_pi.c ipm_at.c ipm_ve.c(IP C 모델) Makefile run.sh stub_check.tcl
  README.md            실행 순서, 돌려받을 것
rtl/l4/  axil_xbar.sv sys_a_top.sv sys_p_top.sv
tb/axil_xbar/, tb/sys_top/ (tb_sys_top.sv, hal_dpi.c), sim/tests/axil_xbar.cfg, sys_top.cfg
```
- 보드 프로그램의 mask 목록과 위치 수는 컴파일 시점 상수(`MASK_LIST`, `RUN_MASK`, `STEPS`)다. 한 ELF가 목록을 차례로 실행한다(UART 입력 없음).
- (S5-1 구현) 실제 파일: `fpga/sys/sw/` sys_main.c, sbench.c/h, sx_exec.c, sx.h, sysmem.c, drv_com.c, drv_ga.c, drv_pi.c, drv_at.c, drv_ve.c, ipregs.h, hal.h, hal_xil.c, scfg.h(`SYS_MASK_LIST`, `SYS_RUN_MASK`, `SYS_STEPS`, `SYS_FCLK_HZ`, `SYS_POLL_MIN_US`, `SX_FAULT_INJ`). `fpga/sys/test/` hal_host.c, ipm.h, ipm_ga.c, ipm_pi.c, ipm_at.c, ipm_ve.c, Makefile, run.sh, xilstub/. Tcl, XDC, Verilog shell, XSCT 스크립트는 S5-5. 호스트 빌드는 같은 목록을 환경변수 `SX_LIST`, `SX_RUNS`, `SX_STEPS`, `SX_MODELS`로 바꿀 수 있다(보드 빌드의 `hal_env`는 항상 NULL).
- `ipregs.h`의 offset과 비트는 IP spec 문서(gemv_acc.md 2절, pim.md 2~3절, attn.md 3절, vec.md 3절)가 원본이다.

## 3. 호스트에서 검증하는 방법

### 3.1 C 수준: IP 레지스터 모델 + cache 모사 (보드 없이, 이 서버에서)
`fpga/bw/test/bw_hal_host.c` 선례를 따른다: spec 문서로 쓴 IP 레지스터 모델이 CTRL 쓰기 안에서 op를 끝낸다.
- **IP 모델**(`ipm_*.c`): 레지스터 맵, descriptor 검사(BAD_DESC/MISALIGN 규칙), 명령 FIFO(PIM), STATUS, ERR(W1C)를 spec대로 두고, 결과는 `model/src`의 kernel 함수를 IP의 입력 배치에서 계산한다: 가속기형은 행 레코드를 `rrec_unpack`해 `k_gemv`, PIM은 LDW로 받은 행 레코드에서 bank 배열을 만들고 MACAB에서 `bank_gemv`, attention은 q 레코드와 KV(DDR 배치 또는 KVW로 채운 모델 안의 KV 표)로 `k_attn2_st`, vec는 해당 kernel 함수. 따라서 드라이버의 배치 변환(행 레코드, base 배정, q 레코드, layer base, KVW 시점)이 틀리면 결과가 틀린다. CYCLES는 IP 문서의 닫힌 식(latency 1 모델)으로 채워 호스트 run이 "시뮬레이션 기준 PL 시간"을 함께 찍게 한다(보드 값이 아님을 로그에 표시).
- **cache 모사**(`hal_host.c`): CPU 메모리(프로그램이 포인터로 읽고 쓰는 것)와 DDR 이미지(IP 모델이 읽고 쓰는 것)를 따로 둔다. `flush(range)`는 32 B line 단위로 넓힌 범위를 CPU -> DDR로 복사, `invalidate(range)`는 DDR -> CPU로 복사, 전체 flush는 arena 전체 복사. 실행기는 호스트 빌드에서 매 kernel 시작 때 입력 범위의 CPU와 DDR 이미지가 같은지 검사한다(2.2 규칙에서는 항상 같아야 한다). 다르면 `COH` 오류(어느 버퍼, 어느 kernel)로 즉시 보고한다. flush 누락과 invalidate 누락을 token 불일치보다 먼저, 원인과 함께 잡는다.
- **검사 항목**: 두 모델 x mask 조합(4.1절 표 전부) x opt 조합(DEFER_AT, PIM_BATCH, WRGB_SKIP 켜고 끔) x run E/T/P/K. 빌드 A 구성과 빌드 P 구성(IP 모델의 CONFIG로 구분). 64비트와 `-m32`. 모든 비교 mismatch 0, COH 오류 0, fallback 0.
- **결함 주입**(각각 FAIL로 잡혀야 함): (1) 생산자 flush 하나 누락, (2) 소비자 invalidate 하나 누락, (3) q 레코드의 qm/qe 순서, (4) DDR KV layer base 한 layer 어긋남, (5) PIM bank base 겹침, (6) 세대가 바뀌었는데 WRGB 생략, (7) barrier 규칙 위반(미뤄 둔 ATTN 전에 ACTQ(att) 실행), (8) IP 모델이 RD_RESP를 냄, (9) IP가 끝나지 않음(timeout 경로), (10) 보호 조건 우회(지원 밖 descriptor를 IP로 보냄 -> BAD_DESC).
- 추가: `hal_xil.c`와 드라이버를 stub BSP 헤더(`fpga/sw/test/xilstub/` 재사용 + `Xil_DCacheFlushRange`/`InvalidateRange` 선언)로 `-fsyntax-only -Werror`, XSCT/Vivado Tcl stub 검사(bw의 `stub_check.tcl` 방식).
- 한계: IP 모델은 RTL이 아니다. 통과는 SW의 흐름, 배치 변환, 일관성 규칙, 로그 형식이 spec과 맞는다는 것만 보인다.
- (S5-1 구현에서 정한 것) "kernel 시작 때 입력 범위의 CPU와 DDR 이미지가 같다"는 위 문장은 IP -> IP 사슬에서는 성립하지 않는다(소비자가 IP면 규칙 3이 invalidate를 하지 않으므로 CPU 쪽은 옛 값이다. 예: Qh와 A가 모두 IP인 K slot). 그래서 검사를 읽는 쪽별로 나눴다. cache 모사는 CPU 메모리, DDR 이미지, 마지막 동기 값(syn), ARM 쓰기 표시(실행기가 `hal_arm_wr`로 kernel 출력, q 레코드, ARGMAX index를 표시, 표시하지 않은 쓰기는 CPU != syn으로 잡음)의 네 배열이다. 오류: ARM이 IP가 쓰고 invalidate하지 않은 byte를 읽음(`arm_rd_stale`, ARM kernel 입력, `fwd_h.c`가 읽는 `as`/`qhs`, q 레코드 복사, logits hash, run K 그림자 입력), IP가 ARM이 쓰고 flush하지 않은 byte를 읽음(`ip_rd_dirty`, IP 모델의 메모리 읽기), IP가 그런 byte가 있는 line에 씀(`ip_wr_dirty`, 규칙 4), flush가 IP가 쓴 byte를 ARM이 쓰지 않은 채로 덮음(`flush_clobber`), invalidate가 flush하지 않은 ARM byte를 버림(`inval_discard`). 모든 line이 늘 cache에 있다고 보는 보수적 모델이고, 범위 끝의 부분 line invalidate는 flush로 처리한다(BSP 동작 [미확인]). run 시작의 전체 flush가 이전 run의 IP 데이터를 덮는 것은 오류가 아니라 `old`로 센다.
- (S5-1 결과, 2026-11-20, 호스트 x86 [측정, 호스트 모델]) `make -C fpga/sys/test test` SYSHOST 34 항목 PASS. mask/opt 21개(4.1절 표 + DEFER_AT 끔, PIM_BATCH 켬, WRGB_SKIP 끔, COH_STRICT, FUSE_AM 끔, G+C PIM_BATCH) x run E/T/P/K/W: 260K 빌드 A, P 전 위치(512), 15M 빌드 A 24 위치와 일부 전 위치(256), 15M 빌드 P 24 위치(7개, 14개 SKIP), `-m32`(260K 64 위치, 15M 16 위치와 mask 0/ff 전 위치). run 684개 모두 PASS(token, logits hash, KCMP 2,029,960 호출 mismatch 0, COH 0, fallback 0, IPERR 0). 결함 주입 11종(3.1 목록 10 + 레지스터 순서)과 보호 조건 fallback이 각각 고유 증거로 FAIL. 상세 `fpga/sys/README.md` 2절. 초기화의 LDW 36개 CYCLES 추정(호스트 PIM 모델, 명령별 점유 합) 36,630은 pim.md 6.2의 측정 36,629와 1 차이다(참고, 추정식).

### 3.2 RTL 수준: 시스템 TB (같은 드라이버 C 코드가 RTL을 구동)
구성:
```
tb_sys_top (Questa)
  DUT: sys_a_top 또는 sys_p_top (axil_xbar + IP 3개, 1.7절)
  axil_bfm (tb/common, 32비트 주소) -> s_axi
  axi_mem_slave x 사용하는 HP 포트 수 (m_hp*_axi), 저장소는 C 쪽 DDR 이미지 하나를 공유(EXT_STORE 모드)
  DPI: import "DPI-C" context task sys_tb_main();           // C의 시스템 프로그램 진입
       export "DPI-C" task sv_axil_wr / sv_axil_rd;          // hal_dpi.c의 io32 -> AXI-Lite BFM (시뮬레이션 시간 소비)
       export "DPI-C" function sv_cycles;                    // plat_now -> PL cycle
  C: model/src + fpga/sys/sw (sx_exec, drv_*, sysmem, sbench 축소판) + hal_dpi.c(io = exported task, cache 모사는 3.1과 같음)
```
- **가부: 가능하다.** DPI-C의 imported context task 안에서 시간이 흐르는 exported task를 부르는 것은 SystemVerilog 표준이 허용하는 사용법이다(Questa에서 이 프로젝트가 아직 쓰지 않은 기능이라 S5-3 smoke로 먼저 확인한다) [미확인, 실행 안 함]. ARM 쪽 kernel(`k_exec`)과 cache 모사는 C에서 시뮬레이션 시간 0으로 돈다.
- **공유 메모리**: 지금 `axi_mem_slave`는 인스턴스마다 SV 희소 배열을 가진다. `EXT_STORE` parameter(기본 0, 기존 동작 불변)를 추가해 1이면 64비트 beat 읽기/쓰기를 DPI 함수(`mem_rd64`, `mem_wr64(addr, data, strb)`)로 C의 DDR 이미지에 보낸다. HP 포트마다의 인스턴스가 같은 저장소를 보게 되고, 드라이버 C 코드의 "DDR"과 같은 메모리다. TB 공통 모듈을 바꾸므로 `axi_mem` 단독 test와 이 모델을 쓰는 모든 TB를 다시 돌린다(기본값 0이면 경로가 같다).
- **실행 시나리오**(사용자 보드 순서와 같은 호출 순서. cycle은 시뮬레이션 측정값에서 [계산], wall time은 [미측정]):

| run | 빌드 | 모델 | 내용 | 예상 PL cycle |
|---|---|---|---|---|
| p_full | P | 260K | 초기화(LDW 36개) + 위치 0..3 mask 전부, opt 기본 | 36,629 + 4 x 약 22k~25k ≈ 13만 |
| p_warm | P | 260K | 위치 0..510은 C(ARM 경로, 시간 0), `sx_kv_sync(511)` KVW 2,555 op(x 48 = 122,640) 후 위치 511 mask 전부(T 512) | 약 16만 + 위치 511 약 5.3만 |
| p_single | P | 260K | 위치 0..1, mask G / A / R+S+Qh+Qa+M 각각 | 각 LDW 36,629 + 2만 이하 |
| p_opt | P | 260K | 위치 0..1, PIM_BATCH 1, WRGB_SKIP 0, DEFER_AT 0 | LDW + 약 5만 |
| p_kmode | P | 260K | p_full과 같은 위치를 run K로 | 약 13만 |
| a_m2 | A | 15M | 위치 0 mask 전부(FUSE_AM 1) | 1,951,992 + 5,622 + 53,726 ≈ 201만 |
| a_m2_warm | A | 15M | 위치 0..254는 C, 위치 255 mask 전부(DDR KV라 sync 불필요) | 1,951,992 + 198,403 + 53,726 ≈ 220만 |
| a_m1 | A | 260K | 위치 0..3 mask 전부(가속기형 GEMV + DDR attention, hs 8 on HS_MAX 64 구성) | 4 x 약 5.5만 |
| err | A, P | 260K | memory model의 SLVERR 주입, 응답 없는 포트(timeout 경로) | 작음 |

- **비교 기준**: 시뮬레이션한 위치마다 token과 logits hash가 PC 기대값(`exp_m*.h`, 보드와 같은 헤더)과 일치, K run의 KCMP mismatch 0, COH 오류 0, IPERR 0(주입 run은 주입한 오류만 정확히 보고), AXI 프로토콜 검사(`axi_mem_slave`의 tag) 0, fallback 0. 각 IP 호출의 CYCLES는 TB가 버스 관측으로 독립 계산한 e - s와 같아야 한다(기존 IP TB의 방식).
- **비용** [추정]: 새 코드는 `axil_xbar` + TB, L4 top 2개(배선), `tb_sys_top.sv`, `hal_dpi.c`, `axi_mem_slave` EXT_STORE. 드라이버와 실행기는 3.1과 같은 코드라 새로 쓰는 것이 아니다. 15M 위치 하나가 약 200만 cycle이라 wall time이 IP TB보다 길다(백그라운드 실행, 순차). DPI 빌드는 기존 `run.sh`의 `gcc @g.f` 방식으로 하고 실행 설정은 인자 파일과 환경변수로 준다(`process-privacy.md`).
- **대안(O8 b)**: SV 쪽에서 덤프 레코드로 호출 순서를 재현하고 ARM 쪽 kernel을 DPI로 부르는 TB. 드라이버 C 코드가 RTL에 닿지 않아 보드에서 처음 만나는 통합 문제(레지스터 순서, 정렬, 일관성)를 못 잡는다. 권고하지 않는다.

**S5-3/S5-4 구현 (2026-11-23, Questa 2024.2 시뮬레이션 통과, 보드 전)**
- DPI 구조(채택: 위 구성 그대로): `tb/sys_top/tb_sys_fwd.sv`의 `import "DPI-C" context task sys_tb_main`이 `fpga/sys/sw/sys_main.c`의 main(이름만 `sys_main_dpi.c`에서 바꿈)을 돌리고, `hal_rd/hal_wr`(`tb/sys_top/hal_dpi.c`)는 exported task `sv_axil_rd/sv_axil_wr`(axil_bfm 트랜잭션 하나, 시뮬레이션 시간 소비)를 부른다. 먼저 작은 실험(`sim/.x0`)으로 imported context task 안에서 시간 소비 exported task 2,000회 왕복, C 재귀 깊이 200(약 1 MB 스택)이 되는 것과, 쓰지 않는 DPI import는 C 구현 없이 경고 0임을 확인했다. `fpga/sys/sw`의 실행기, 드라이버, 초기화, sbench는 수정 없이 같은 소스를 컴파일한다(바꾼 것은 HAL과 platform 계층: `hal_dpi.c`, `plat_dpi.c`).
- 시간: `plat_now` = 시뮬레이션 cycle(exported `sv_cycles`), `plat_tps` = 100,000,000(tick = PL cycle). ARM 쪽 일(k_exec, cache 모사, 로그)은 시뮬레이션 시간 0이라 KERN/RUN ticks는 PL 시간 + AXI-Lite 시간만이다.
- 공유 메모리: `axi_mem_slave` parameter `EXT_STORE`(기본 0, 기존 동작 불변. 1이면 beat 읽기/쓰기와 backdoor가 DPI `axm_rd64/axm_wr64`로 C 메모리에 간다, 밖이면 tag `AXI_EXT`). C 메모리는 S5-1 cache 모사의 DDR 이미지(`fpga/sys/test/hal_cache.c`, `hal_host.c`에서 분리, 동작 불변)라 IP 쪽 일관성 검사(`ip_rd_dirty`, `ip_wr_dirty`)가 RTL의 beat마다 그대로 돈다. 주입: `inj_hang(r, b)`(R/B 응답 중지).
- 설정: plusarg가 호스트 환경변수와 같은 이름(`+SX_LIST +SX_RUNS +SX_STEPS +SX_MODELS +SX_FAULT`, 15M 이미지 `+DDR_CK +DDR_TK`). 판정(`tb/sys_top/sys_tb.c`): 프로그램의 SYS 줄이 기대 빌드와 1.7절 slot 표의 ID/CONFIG(`+EXP_BUILD` A, A2, P, PD), CHECK 수 `+EXP_CHECKS`, 모든 CHECK의 tok_mis/hash_mis/kmis/coh 0, (주입 없으면) fb/iperr 0과 RESULT PASS, COH/SKIP/kernel_error 0, gemv_acc(P = 1)와 vec의 모든 op CYCLES == 닫힌 식(gemv_acc.md 5, vec.md 6.2, driver가 쓴 레지스터로 계산), arena 밖 beat 0. SV 쪽은 memory model의 프로토콜 tag 전부와 끝의 idle 검사.
- IP 오류 주입(`+TB_IPFAULT=rdresp|wrresp|hang`, `+TB_IPFAULT_SLOT`, `+TB_IPFAULT_OP`): n번째 start에서 그 IP의 HP 포트 memory model이 모든 주소에 SLVERR(그 op가 끝날 때까지)이거나 응답을 멈춘다. [측정] 응답 오류에서 네 IP 모두 STATUS = 0x6(done과 err 동시), ERR = RD_RESP(gemv_acc 0x10, pim 0x20) 또는 WR_RESP(attn, vec 0x20)이고 출력 데이터는 맞았다(token, hash, K 비교 0).
- 회귀: `sim/tests/sys_smoke.cfg`(S5-3, 2 run: 빌드 A/P, 260K 위치 0 mask ff, run P + K), `sim/tests/sys_fwd.cfg`(S5-4, 24 run, 아래 표. memory stall run 3개는 S5-4 후속). q tier는 smoke 2개와 `p_full`, `a_m1`, `a_err_rd`.

| run | 빌드 | 모델, 위치 | mask / opt / run | 확인 |
|---|---|---|---|---|
| p_full | P | 260K 0..3 (+ 초기화 LDW 36개) | ff / 기본 / P, K | token, hash, KCMP, CYCLES |
| p_warm | P | 260K 0..510 ARM, KVW 2,555개, 511 | ff / 기본 / W | 512 위치 token, hash |
| p_single | P | 260K 0..1 | 비트 8개 각각 / P, K | |
| p_masks | P | 260K 0..1 | 0, 3, 82, 7, f8, df / P, K | |
| p_opt | P | 260K 0..1 | ff:0c(DEFER_AT 0), ff:0f(PIM_BATCH 1), ff:09(WRGB_SKIP 0), ff:1d(COH_STRICT), 3:0f / P, K | |
| p_xb0, a_xb0 | P, A (XB_REG 0, AXI-Lite 간격) | 260K 0..1 | ff / K | |
| pd_m1 | PD (KV_SRC 1, H_PAR 2) | 260K 0..1 | ff, 4 / P, K | |
| a_m1 | A | 260K 0..3 | ff, 3 / P, K | DDR KV attention hs 8 on HS_MAX 64 |
| a_m1_single | A | 260K 0..1 | 비트 각각, 82, ff:05(FUSE_AM 0) / P, K | |
| a_m1_warm | A | 260K 0..510 ARM, 511 | ff / W | |
| a2_m1 | A2 (GA_P 2) | 260K 0..1 | ff, 3 / P, K | |
| a_m2 | A | 15M 0..3 | ff / P | |
| a_m2_k | A | 15M 0..1 | ff / K | |
| a_m2_warm | A | 15M 0..254 ARM, 255 | ff / W | |
| a_err_rd, a_err_wr, a_err_hang | A | 260K 0..1 | ff / P | gemv_acc SLVERR 읽기, vec SLVERR 쓰기, attn 응답 없음(timeout) |
| p_err_rd, p_err_wr, p_err_hang | P | 260K 0..1 | ff / P | pim SLVERR 읽기, attn SLVERR 쓰기, vec timeout |
| p_stall | P (+PROF=2, MAXD 1) | 260K 0..1 (+ 초기화 LDW) | ff / P, K | HP 4개 모두 AR/AW/W/R/B 50% stall, R latency 1~60, B 1~40 |
| a_stall | A (+PROF=3) | 260K 0..1 | ff / P, K | 포트마다 다름: HP0 20%/R 1~30/B 1~20, HP1 50%/1~60/1~40, HP2 30%/5~40/1~10, HP3 10%/1~80/1~60 |
| a_m2_stall | A (+PROF=1) | 15M 0 | ff / P | HP 4개 모두 20% stall, R latency 1~30, B 1~20 |

- memory stall run(`+PROF` != 0, `tb_sys_fwd.sv` 머리 주석): `axi_mem_slave`의 기존 `cfg_stall`/`cfg_lat`(다른 IP TB의 PROF 1/2와 같은 값)을 HP 포트 4개에 건다. `EXT_STORE`와 같이 동작한다(beat를 내보내거나 받는 시점에 C 메모리를 읽고 쓰므로 stall과 latency는 시점만 바꾼다). 판정은 위 기준과 같고 CYCLES만 다르다: 닫힌 식은 latency 1, stall 없음 전제라 하한으로 쓰고(`CYC_LOW` 0), 모든 op에서 RD_STALL, WR_STALL <= CYCLES(`ST_BAD` 0, 이 검사는 PROF 0 run에도 적용). memory model은 끝에 `AXI_MEM_STALL`(채널별로 stall이 실제로 요청이나 beat를 막은 cycle 수, 뽑힌 R latency 평균), C 쪽은 `SYSTB STALL`(slot별 CYCLES, RD_STALL, WR_STALL, 식 대비 초과 합)을 찍는다.
- 결과 [측정, 시뮬레이션, TB의 random memory model이라 보드 값이 아님]: 세 run 모두 token, logits hash, K 비교, COH, fallback, IPERR, AXI 프로토콜 검사 0, `CYC_LOW` 0, `ST_BAD` 0. RUN ticks(AXI-Lite 포함) token당: p_stall 43,613(stall 없는 p_full 31,688), a_stall 85,953(a_m1 63,819), a_m2_stall 위치 0 2,514,750(a_m2 위치 0..3 평균 2,021,290). stall 증거: p_stall HP0(pim) R beat가 stall로 막힌 cycle 37,069, pim RD_STALL 합 39,860(LDW 포함 74 op); a_m2_stall HP0(gemv_acc) R 487,420, gemv_acc RD_STALL 488,213, CYCLES가 닫힌 식보다 488,598 많음.
- 발견과 수정(2026-11-23): `vec_top`의 RD_STALL이 구조상 항상 0이었다. `axi_rd_eng.stall_o = busy && d_ready && !d_valid`를 셌는데 `vec_core`의 `d_ready_o`는 beat pop이라 `d_valid_i`를 포함해 d_ready와 !d_valid가 함께 참일 수 없었다(수정 전 stall run의 vec RD_STALL 전부 0, HP3 R stall 8,493 cycle). `tb_vec_top`의 참조 모델이 DUT 내부 event를 그대로 세어 놓쳤다. 수정: `vec_core`에 `d_want_o`(원소를 원함, `d_valid` 무관)를 추가하고 `vec_top`이 `rd_busy && d_want && !d_valid`를 센다(`d_ready_o`를 valid와 무관하게 바꾸면 unpacker의 lane 동작과 cycle이 바뀌어 택하지 않음, vec.md 3절 주). 데이터와 CYCLES는 불변(CYC_MIS 0 유지). 수정 후 [측정, 시뮬레이션]: stall 없는 run에서 vec RD_STALL = op당 4(p_full 408 op 1,632, a_m1 404 op 1,616, a_m2 532 op 2,128), stall run의 vec RD_STALL 합 p_stall 7,381(204 op, HP3 R stall 8,493), a_stall 9,021(202 op, 844), a_m2_stall 2,662(133 op, 2,742). `sys_tb.c`가 PROF != 0에서 "HP3 R stall > 0이면 vec RD_STALL 합 > 0"(`VE_RDST`)을 검사하고, 수정 전 RTL로 세 stall run이 모두 이 검사로 FAIL함을 확인했다. vec WR_STALL은 모든 시스템 run에서 0이며 구조상 정상이다(vec.md 3절 주: packer가 1 beat/4~8 cycle이라 32 beat write buffer가 차지 않음; W를 길게 막는 `tb_vec_top` WBLK run에서는 > 0). 다른 IP의 stall 계수는 core ready가 상태로만 정해져(valid 무관) 같은 문제가 없다: stall run에서 gemv_acc RD_STALL 20,020(a_stall)/488,213(a_m2_stall), pim 39,860(p_stall), attn 39/5,314/1,007.

- CYCLES [측정, 시뮬레이션, latency 1 메모리, stall 없음] token당(위치 평균): 빌드 P 260K 위치 0..3: vec 15,680(RMSNORM 3,993, SWIGLU 3,005, ACTQ 8,155, ARGMAX 527, 4.4절과 같음), PIM 레코드마다 run(WRGB 생략) 5,681, WRGB 생략 끔 5,846, PIM_BATCH 5,156(2 위치), attention BRAM H_PAR 2 + KVW 2,140, 합 23,501(RUN ticks 31,688 = AXI-Lite 포함). 빌드 A 260K: gemv_acc 37,930(4.4절 37,903~37,938 안), DDR attention hs 8 4,115(T 1..4, 이 구성의 첫 측정), 합 57,198(ticks 63,819). 빌드 A 15M 위치 0..3: gemv_acc 1,952,048(그중 cls 1,184,072/호출), vec 53,731, DDR attention 6,756, 합 2,012,535(ticks 2,021,290). 15M 위치 255(warm, 1 위치): ticks 2,209,722(위 4.4절 예상 약 220만). 이전 4.4절의 "레코드마다 run 약 6,950"과 시스템 TB 5,846(WRGB 매번)의 차이는 측정 조건 차이다(S5-4 확인): 그 값은 `pim_top` TB의 run `m1_perrec`(`sim/tests/pim_top.cfg`, `+MODE=2 +PROF=1 +MAXD=1`)에서 나왔고, PROF 1은 memory model의 AR/AW/W/R/B 20% random stall, R latency 1~30, B latency 1~20이다(12 위치 6,878~7,096, 평균 6,974; 같은 run의 LDW도 46,251로 stall 없는 36,629보다 크다). 명령 구성(레코드마다 WRGB + MACAB 한 run, 36 run)과 RUN 시점(push 검사가 끝난 뒤)은 시스템 TB와 같다. 같은 TB를 `+PROF=0 +MAXD=0 +MODE=2`로 다시 돌리면 위치 0..3이 5,822 / 5,845 / 5,852 / 5,837 [측정, 시뮬레이션]이고 LDW 36,629로 시스템 TB와 같은 범위다. 남는 수십 cycle 차는 `pim_top` TB가 x와 y 주소를 run마다 random으로 두어 burst 분할(16 beat, 4 KiB)이 달라지는 것으로 본다 [추정, 레코드별 대조 안 함]. 4.4절 표와 s5calc를 고쳤다.
- 호스트 IP 모델 CYCLES 대 RTL(같은 프로그램, 같은 설정의 op별 trace, `tb/sys_top/cyc_cmp.py`): gemv_acc P = 1, vec 4종, KVW는 모든 op 일치. 추정인 것: PIM run(LDW, WRGB, MACAB 목록) RTL이 +0.02~+0.35%(run당 최대 +7), attention BRAM 묶음 op +0.26%(op마다 +1), head 하나씩(DEFER_AT 0) -5.8%(op당 최대 -19), DDR attention 260K -4.7~-4.9%(op당 최대 -46), 15M -2.6%(최대 -30), gemv_acc P = 2는 짝수 ROWS에서 op마다 +1(gemv_acc.md 5절 6번 규칙. S5-4에서 호스트 모델에 반영해 일치).
- 실행기 수정(S5-4): IP timeout으로 IP를 끄면 드라이버가 D-cache 전체를 clean + invalidate한다(`drv_com.c`). 그 전에는 "소비자가 IP라 invalidate하지 않은" 버퍼(예: vec이 쓴 K/V slot)를 ARM 대체 실행이 cache의 옛 값으로 읽거나(`arm_rd_stale`, 빌드 A에서 logits hash 불일치) 그 line을 덮어 썼다(`flush_clobber`). 생산자 규칙으로 ARM이 쓴 line은 모두 clean이라 이 flush는 쓰기를 만들지 않는다.

### 3.3 G5 통과 기준 (AXI BFM 시뮬레이션 통과)
1. `model/src` 변경(O3 a) 뒤 `make test` PASS, 기존 덤프 `cmp` 동일.
2. 호스트 테스트(3.1) 전 항목 PASS: 모든 mask/opt/run 조합 mismatch 0, COH 0, fallback 0, 결함 주입 10종 모두 FAIL로 검출, xilstub 문법 검사, Tcl stub 검사.
3. `axil_xbar` 단독 TB mismatch 0(G4), L4 top과 xbar `vlog/vopt -lint=full` 경고 0, 두 빌드 구성 elaboration.
4. 시스템 TB(3.2) 모든 run PASS(위 비교 기준).
5. `sim/run.sh all` 전 run PASS(`axi_mem_slave` 변경 뒤 회귀).

## 4. 측정과 추정 계획 (S6, 사용자 보드 실행)

### 4.1 mask 조합
각 조합을 run E(end-to-end)와 P(분해)로 잰다. 15M은 빌드 A, 260K는 빌드 P(PIM)와 빌드 A(가속기형) 둘 다.

| mask | 켜는 것 | 얻는 수치 |
|---|---|---|
| 0 | 없음 | 이 빌드에서의 ARM baseline(E, P). S3 baseline과의 차이(PL 존재의 영향) |
| G | GEMV(cls 제외) | GEMV 단독 가속비 s_G, a/b/c, end-to-end |
| C | cls (+ M with FUSE_AM, 빌드 A) | 분류기 단독, 15M에서 가장 큰 범주(PC 프로파일 52.0%, ARM 아님) |
| G+C | GEMV 전부 | GEMV 오프로드 end-to-end. 260K에서 빌드 A(가속기형)와 P(PIM)의 핵심 비교 |
| A | attention | attention 단독(+ KVW). 260K는 위치에 따라 비중이 커진다(PC 프로파일 70.5%, ARM 아님) |
| R, S, Qh, Qa, M 각각 | vec op 하나 | op별 단독 가속비. Qh는 호출 수가 많아(260K 80, 15M 108 /token [계산]) c가 지배할 것으로 본다 [추정] |
| R+S+Qh+Qa+M | vec 전부 | vec 오프로드 |
| G+C+A | GEMV + attention | 큰 kernel만 |
| 전부 | 모두 | 전부 오프로드 end-to-end |
| 전부 - Qh | Qh만 ARM | head별 ACTQ를 ARM에 남기는 쪽이 나은지(arch.md 5.1 권고의 검증) |
| opt 변형 | 전부 + DEFER_AT 0 / PIM_BATCH 1 / WRGB_SKIP 0 | 호출 묶음의 효과(c의 크기) |

- 위치 수: E는 모델의 seq_len 전체(baseline과 같은 조건). P와 K는 시간이 길면 위치 수를 줄인 빌드를 둔다(`STEPS`, 결과에 표시). 실행 시간은 ARM 측정 전이라 추정하지 않는다.

### 4.2 Amdahl 추정과 실측 비교
measure.md 6절의 식을 그대로 쓰고, mask 집합 O에 대해:
- 이상적: S_ideal(O) = 1 / ((1 - Σ_{k∈O} f_k) + Σ_{k∈O} f_k / s_k), s_k = t_k(ARM) / a_k. f_k, t_k는 mask 0 run P, a_k는 단독 mask run의 KSPLIT `pl`.
- 비용 포함: t'(O) = t - Σ_{k∈O} n_k t_k + Σ_{k∈O} n_k (a_k + b_k + c_k) + Σ_{j∉O} sync_j(O), S_cost(O) = t / t'(O). a, b, c는 **그 kernel만 켠 run**의 KSPLIT에서, sync_j(O)는 ARM에 남은 kernel j의 생산자 flush(KSPLIT `mv`의 ARM 쪽).
- 실측: mask O run E의 ms_tok. 표에 S_ideal, S_cost, 실측을 나란히 적고 실측 / S_cost를 "상호작용 계수"로 본다. 1에서 벗어나면 원인을 KSPLIT로 가린다(cache 상태 변화, 묶음 효과, DDR 경쟁).
- 단독 run들로 조합 run을 예측하는 것이 추정이고, 조합 run의 E가 실측이다. 둘을 구분해 적는다(project-flow.md 시스템 방식 5).

### 4.3 HP 대역폭 측정 결과가 들어갈 자리 (`bwtest.md` 7절, 보드 결과 후 채움)
| 항목 | 값 | 쓰는 곳 |
|---|---|---|
| 포트 하나 RD MB/s (burst 16, outstanding 4, 8 MiB) | [미측정] | eta_rd = 값 / 800. 가속기형 GEMV와 DDR attention의 a 예측: CYCLES_board ≈ beat 수 / eta_rd + 고정 항 |
| 포트 하나 WR MB/s | [미측정] | y, o, q 쓰기 꼬리 |
| 포트 두 개 동시 RD MB/s (HP0 + HP2) | [미측정] | A2(P 2)를 만들지(O12) |
| outstanding 1, 2, 4, 8의 차이 | [미측정] | OUTS 기본값, DDR latency 추정 |
| ARM `t_us` - CYCLES / f_PL (bw op 하나) | [미측정] | 호출 오버헤드 c의 하한 참고값 |

### 4.4 PL 쪽 시간 표 (지금 계산할 수 있는 것)
시뮬레이션 cycle(latency 1 메모리 모델, 보드 아님)을 100 MHz로 환산한 [계산](s5calc 4절). 보드에서는 HP latency와 eta, ARM 쪽 b, c가 더해진다. ARM 칸은 보드 측정 전이라 비워 둔다.

| 모델 | kernel (token당) | 시뮬레이션 cycle | PL us @100 MHz [계산] | ARM baseline us [미측정] | 보드 a, b, c [미측정] |
|---|---|---|---|---|---|
| 260K | PIM GEMV, token 한 run | 4,499 ~ 4,506 | 45.0 ~ 45.1 | | |
| 260K | PIM GEMV, layer마다 run | 4,663 ~ 4,676 | 46.6 ~ 46.8 | | |
| 260K | PIM GEMV, 레코드마다 run(호출 단위, 묶음 없음, WRGB 매번) | 5,822 ~ 5,852 | 58.2 ~ 58.5 | | |
| 260K | 가속기형 GEMV P 1 / P 2 | 37,903 ~ 37,938 / 19,895 ~ 19,930 | 379.0 ~ 379.4 / 198.9 ~ 199.3 | | |
| 260K | attention BRAM KV H_PAR 2 + KVW, T 1 / 64 / 256 / 512 | 2,050 / 5,830 / 17,350 / 32,710 | 20.5 / 58.3 / 173.5 / 327.1 | | |
| 260K | 같은 것, 위치 0..511 평균 | 17,380 | 173.8 | | |
| 260K | attention DDR KV(빌드 A) | 미측정(구성은 시스템 TB에서 처음 실행) | - | | |
| 260K | vec 전부(RMSNORM 3,993, SWIGLU 3,005, ACTQ 8,155, ARGMAX 527) | 15,680 | 156.8 | | |
| 260K | **빌드 P 전부, 위치 평균** | 37,559 ~ 38,912 | **375.6 ~ 389.1** | | |
| 15M | 가속기형 GEMV P 1 (cls 포함, 1 위치) | 1,951,992 | 19,519.9 | | |
| 15M | 그중 cls (y_en, argmax_en) | 1,184,069 ~ 1,184,077 | 11,840.7 ~ 11,840.8 | | |
| 15M | attention DDR H_PAR 1, T 1 / 128 / 256 | 5,622 / 101,634 / 198,403 | 56.2 / 1,016.3 / 1,984.0 | | |
| 15M | 같은 것, 위치 0..255 평균 | 102,012 | 1,020.1 | | |
| 15M | attention DDR H_PAR 2, 위치 평균(A', O2) | 51,405 | 514.0 | | |
| 15M | vec 전부 / ARGMAX를 cls에 융합하면 | 85,741 / 53,726 | 857.4 / 537.3 | | |
| 15M | **빌드 A 전부(FUSE_AM), 위치 평균** | 2,107,730 | **21,077** | | |
| 260K | (초기화 1회) LDW 36개 | 36,629 | 366.3 | | |

- attention token 합은 attn.md 6.2 표에 맞춘 직선이다 [계산]: 260K BRAM H_PAR 2 `60 T + 1,750`, H_PAR 1 `120 T + 3,295`(표의 모든 점과 일치), 15M DDR H_PAR 1 `756 T + 4,866`, H_PAR 2 `378 T + 2,832`(T 256 점과 1 차이). 위치 평균은 이 직선의 평균이다.
- 15M은 PL 합의 92.6%가 GEMV이고 [계산], GEMV는 행 레코드 15,586,816 B를 HP 포트 하나 이론 대역폭(800 MB/s)으로 읽는 19.48 ms가 하한이다 [계산]. 참고로 PC(x86) baseline은 6.650 ms/token이었다(S3 로그, ARM 아님). ARM에서 이보다 얼마나 느린지 모르므로 15M 가속비를 추정하지 않는다. eta가 1보다 작으면 PL 시간은 더 길다.

## 5. 융합 후보 (S5 이후 선택)
v1은 kernel 경계를 DDR 버퍼로 둔다(D11). 아래는 S6 측정(특히 호출 비용 c)을 본 뒤 고를 후보다.

| ID | 내용 | 예상 이득 [계산] | 필요한 RTL 변경 | bit-exact 검증 | v1 권고 |
|---|---|---|---|---|---|
| F1 | head별 ACTQ(K, V, q; n = hs)를 attention 앞단에 융합. `attn_top`이 int32 `qr`, `kr`, `v`를 읽어 head마다 양자화해 core와 (BRAM KV) `kv_store`, (DDR KV 또는 K 모드) golden `kc/vc` slot에 씀 | vec 호출 제거: 260K 80회/token(vec cycle 7,120), 15M 108회(19,116). 융합 단위가 순차면 core `2 hs + 59` x 호출 수가 다시 붙어 PL 순감은 260K 1,120, 15M 2,376 cycle. 앞 head의 P1~P3와 겹치게 하면 PL 순감 최대 7,120 / 19,116. 큰 몫은 ARM 호출 비용 80 / 108 x (b + c) [미측정] | engine마다 `actq_core`(N_MAX = HS_MAX, LUTRAM, DSP 4) + int32 읽기 경로 + 새 op(ATTNQ, KVWQ). `actq_core`, `attn_core`는 수정 없이 인스턴스 | K_ACTQ 레코드와 K_ATTN2 레코드를 이어서 대조(같은 덤프), 시스템 TB의 token/hash | 넣지 않음. S6에서 Qh의 c가 크면 첫 후보 |
| F1a | (RTL 변경 없음) ACTQ(q)가 IP일 때 OUT_ADDR = q 레코드 + 8, SCL_ADDR = q 레코드로 써서 q 레코드 복사를 없앰 | head마다 24 B / 104 B 복사와 flush 제거 [미측정] | 없음(SW) | 시스템 TB, K 모드 | v1에 넣을 수 있음(opt 비트로) |
| F2 | 생산자(RMSNORM, SWIGLU, ACTQ(att)) -> GEMV x 직결 또는 GEMV가 scale을 메모리에서 읽음 | 경계 260K 21개, 15M 25개 /token. 데이터는 260K 1,884 B, 15M 10,080 B(쓰기 + 읽기 beat 472 / 2,520 이하)라 작다. 이득은 `as` invalidate와 레지스터 전달, 그리고 PIM에서 "scale을 알아야 MACAB를 push할 수 있는" 직렬화를 푸는 것 [미측정] | `gemv_acc`/`pim`에 scale-from-memory 플래그(8 B 읽기 후 시작). 직결은 IP 사이 handshake 또는 공용 sequencer가 필요해 크다 | K_GEMV 레코드(같은 x, scale), 시스템 TB | 넣지 않음 |
| F3 | cls + argmax (`gemv_acc` `argmax_en`) | 15M vec ARGMAX 32,015 cycle과 호출 1회 제거, logits 128,000 B를 ARM이 다시 읽지 않음 | 없음(이미 구현, gemv_acc.md 2.5) | 이미 G4(K_GEMV + K_ARGMAX) | **v1에 넣음**(빌드 A, FUSE_AM) |
| F4 | w1/w3 GEMV 출력 -> SWIGLU 직결 | h1, h3 DDR 왕복 제거(260K 1,376 B, 15M 6,144 B /layer)와 호출 1회/layer [계산, s5calc 5] | GEMV와 vec 사이 스트림 연결(IP 경계를 넘는 구조 변경) | K_GEMV + K_SWIGLU | 넣지 않음(이득 작음) |
| F5 | 공용 명령 sequencer: ARM이 layer의 kernel 목록(IP 여러 개)을 한 번에 넣고 한 번 기다림 | token당 IP 대상 호출(260K 178, 15M 213 [계산, s5calc 5: embed, rope, add 제외])의 c를 layer 수 수준으로 | 새 control 모듈(명령 FIFO, IP 사이 done 연결) | 시스템 TB | 넣지 않음. S6에서 c 합이 a 합보다 크면 검토 |
| F6 | attention 출력의 ACTQ(att, n = D)를 `attn_top` 출력단에 | vec 호출 260K 5회(1,035 cycle), 15M 6회(3,906) /token | `attn_top`에 `actq_core`(N_MAX = D) | K_ATTN2 + K_ACTQ 레코드 | 넣지 않음 |

- F1의 cycle은 vec_top CYCLES 식(1 + core + 11 + max(L_last, 2))으로 센 [계산]이다. 260K ACTQ 합 8,155는 시뮬레이션 측정(vec.md 6.3)과 정확히 같고, 15M은 23,022로 측정 평균 23,019와 3 차이(쓰기 burst 분할이 주소에 따라 다름).

## 6. 확인하지 못한 것
- 보드 수치 전부: ARM baseline, HP 대역폭과 latency, 호출 비용(AXI-Lite 왕복, polling), cache 유지 비용, 100 MHz timing, LUT 수.
- Vivado가 144비트와 210비트 `ram_sdp`에 512 x 72의 parity 비트를 데이터로 매핑하는지(빌드 P의 BRAM 성립 조건).
- `vec_top` N_MAX 256(O7) 구성은 아직 시뮬레이션하지 않았다.
- HP DDR segment 범위, HP0/HP1과 HP2/HP3의 DDR 포트 공유, AXI4 -> AXI3 변환, `Xil_DCacheInvalidateRange`의 부분 line 처리, cache line 크기와 `dsb` 포함 여부, SLCR PL reset 주소(모두 Xilinx 문서를 이 작업에서 열지 않음).
- `vt` job bimg의 행렬 순서(bank base 배정을 같게 맞출 수 있는지).

## 7. 제안 하위 단계 (plan.md S5-1 ~ S5-6과 같음)
| 단계 | 내용 | 통과 기준 |
|---|---|---|
| S5-1 | `model/src` 실행기 끼움점(`lm_h_forward_x`), 시스템 SW(`fpga/sys/sw`: 실행기, 드라이버 4개, 초기화, 로그), 호스트 IP 모델과 cache 모사, 파서 확장, 호스트 테스트 | `make test` PASS와 덤프 `cmp` 동일, 호스트 테스트 전 조합 mismatch 0, COH 0, fallback 0, 결함 주입 10종 검출, xilstub 문법 검사 |
| S5-2 | `axil_xbar`(+ 단독 TB), `sys_a_top`, `sys_p_top`(인스턴스와 배선만) | xbar mismatch 0, lint 경고 0, 두 빌드 elaboration |
| S5-3 | 시스템 TB 기반: `axi_mem_slave` EXT_STORE, DPI HAL(`hal_dpi.c`, exported AXI-Lite task), DPI 빌드, smoke(모든 slot ID, IP마다 호출 하나) | 기존 회귀 PASS, smoke mismatch 0 |
| S5-4 | 시스템 TB forward(3.2 시나리오 전부) = G5 | 시뮬레이션 위치의 token/hash mismatch 0, K 모드 0, COH 0, IPERR 0(주입 run은 주입한 것만), `sim/run.sh all` PASS |
| S5-5 | Vivado/Vitis 스크립트(`fpga/sys/`: BD Tcl BUILD=A/P, build, XDC, XSCT), README(실행 순서, 돌려받을 것) | Tcl/XSCT stub 검사 PASS, 호스트 테스트 PASS, 사용자 빌드 요청 |
| S5-6 | 사용자 빌드 리포트 분석(utilization, timing, BRAM parity 매핑) | 두 빌드 WNS >= 0, BRAM <= 140, DSP가 [계산]과 맞음. 아니면 1.6 대안으로 S5-2로 되돌림 |

## 8. (참고) 기존 결정과의 관계
- arch.md D1(자체 AXI master), D2(P parameter, 첫 보드 빌드 P = 1), D7(260K KV BRAM), D8(H_PAR 2), D9(layer 단위 attention 명령), D10(vec 하나), D11(v1 DDR 경유)을 그대로 따른다. D9는 IP 쪽이 이미 layer 단위 op를 지원하므로, 이 문서는 SW가 golden의 head 단위 호출을 그 op로 묶는 방법(지연 실행과 barrier)을 정한다.
- measure.md 7절의 "하위 범주 `gemv_cls.pl`, `.mv`, `.call` [계획]"을 KSPLIT로 구체화했다.

## 9. 열린 결정
| ID | 결정 | 대안 | 장단점 | 권고 |
|---|---|---|---|---|
| O1 | bitstream 수와 구성 | (a) A(TMAX 512, 260K 가속기형 비교 겸용) + P (b) A + P + C(260K 가속기형 전용) (c) PC 병합 1개 + A | (a) 최소. GEMV 비교는 bitstream이 다르지만 mask = GEMV만이면 ARM 일이 같다. (b) 얻는 것이 (a)와 같고 빌드 하나 더. (c) 같은 bitstream 비교이나 BRAM 126~128.5와 HP read 채널 5개(공유 필요), 위험 증가 | (a) |
| O2 | 빌드 A의 attention H_PAR | (a) 1 (b) 2(read를 HP2에) | (a) DSP 60, 단순. 15M attention 위치 평균 102,012 cycle. (b) DSP 93, 51,405 cycle(attention은 15M PL 합의 약 5%), P 2(A2)와 HP2를 다툼 | (a). A의 utilization과 S6 결과를 본 뒤 재검토 |
| O3 | 실행기를 forward에 넣는 방법 | (a) `model/src/fwd_h.c`에 `lm_h_forward_x`(exec 포인터) 추가 (b) `fpga/sys/sw`에 forward를 옮겨 적고 매 run `lm_h_forward`와 self check(fq_prof 방식) | (a) 호출 순서의 원본이 하나, 변경 몇 줄, `make test`/`cmp` 재확인 필요. (b) model/src 무변경이나 forward 사본이 생겨 어긋날 위험(self check로 잡음), 묶음을 위해 순서를 바꿀 자유는 있음 | (a). 묶음은 지연 실행으로 순서 변경 없이 얻는다 |
| O4 | 제어 경로 | (a) L4 top 안에 `axil_xbar`(RTL), GP0 -> `s_axi` 하나 (b) BD interconnect가 IP별 `s_axi`로 | (a) TB가 PS와 같은 BFM 하나로 전체를 구동, 빈 slot이 0을 읽어 SW가 빌드를 탐지(DECERR abort 없음), RTL 모듈 하나와 TB 추가. (b) RTL 추가 없음, TB에 BFM 여러 개 또는 TB 쪽 decoder, 빌드 구성은 컴파일 상수 | (a) |
| O5 | HP 포트 배정 | (a) IP의 read/write 채널을 포트별로 직접 배선(1.3 표, 중재 없음) (b) IP 여럿을 interconnect로 HP 하나에 공유(arch.md 7.1의 PIM형 안) | (a) 측정에 중재 효과가 없음, interconnect는 변환만. (b) HP 포트를 아끼나 지금은 4개 안에 들어가 필요 없음 | (a) |
| O6 | 빌드 구성 탐지 | (a) xbar slot의 ID 읽기(O4 a) (b) 컴파일 시점 상수 (c) L4에 sys_id 레지스터 블록 | (a) 추가 RTL 없음, 같은 ELF가 두 빌드에서 돈다. (b) ELF가 빌드마다 다름. (c) RTL 추가 | (a) (O4 a일 때) |
| O7 | 빌드 P의 vec N_MAX | (a) 1024(검증한 구성) (b) 256 | (a) BRAM 128~129, 15M vec도 빌드 P에서 가능. (b) BRAM 126~128, 시스템 TB에서 처음 검증 | (a)로 시작, BRAM이 넘치면 (b)가 첫 대안 |
| O8 | RTL 시스템 TB 구동 | (a) 드라이버 C를 DPI로 연결(같은 코드, 공유 C 메모리) (b) SV가 덤프 레코드로 호출 재현 | 3.2절 | (a) |
| O9 | v1 호출 묶음 | (a) DEFER_AT 기본 켬, PIM_BATCH 선택(기본 끔), WRGB_SKIP 켬 (b) 묶음 없음(golden 호출 그대로) | (a) H_PAR 2가 실제로 두 engine을 씀, 호출 비용 비교 가능. 실행기 복잡도 증가(barrier 규칙, 호스트 결함 주입으로 검사). (b) 단순하나 260K attention에서 engine 하나만 일함 | (a) |
| O10 | BRAM KV와 mask 전환 | (a) ATTN을 켠 run은 위치 0부터, 중간 전환 없음(보드). TB만 `sx_kv_sync` (b) 실행기가 언제든 sync | (a) 단순, 보드 측정에 sync 비용이 섞이지 않음. (b) 유연하나 측정 해석이 복잡 | (a) |
| O11 | IP timeout 복구 | (a) 그 IP를 끄고 계속(run FAIL 표시) (b) SLCR PL reset 후 재초기화 | (a) 단순, 원인 분석용 로그가 남음. (b) 주소/순서 [미확인], 재적재 필요 | (a), (b)는 보드에서 timeout이 실제로 나면 |
| O12 | 가속기형 HP 포트 2개(A2) | (a) bw 측정 후 조건부(포트 2개 동시 RD가 1.5배 이상) (b) 처음부터 A2도 빌드 | arch.md D2와 같은 논리 | (a) |
| O13 | 인터럽트 | (a) polling (b) L4에서 done을 IRQ_F2P로 | (a) 측정 단순(arch.md 7.1). (b) 긴 호출(15M cls 11.8 ms)에서 ARM이 다른 일을 할 수 있으나 v1은 순차 | (a) |

## 10. 결정 (2026-11-20, 오케스트레이터)
열린 결정 O1~O13은 9절의 권고대로 확정한다.
- O1 bitstream은 A + P 두 개(A2, PD는 조건부), O2 A의 attention H_PAR = 1, O3 `model/src`에 `lm_h_forward_x` 추가(기존 `lm_h_forward`의 결과는 bit 단위로 불변: 덤프 `cmp`와 `make test`로 확인), O4 `axil_xbar`, O5 HP 채널 직접 배선, O6 ID slot 읽기, O7 P의 vec N_MAX는 1024로 시작, O8 시스템 TB는 드라이버 C 코드를 DPI로 연결, O9 DEFER_AT 켬, PIM_BATCH 선택, WRGB_SKIP 켬, O10 BRAM KV에서는 위치 0부터 시작하고 중간 mask 전환 없음, O11 timeout이면 그 IP를 끄고 계속, O12 A2는 대역폭 측정 뒤, O13 polling.
- 융합: v1에는 F3(분류기 + argmax)만. F1(head별 ACTQ를 attention 앞단에)은 S6에서 호출 비용을 잰 뒤 첫 후보.
- 정정: 빌드 P의 BRAM36 [계산]은 128(= 64 + 60 + 2 + 2)이다. S4-7 로그의 129는 이중 계산이었다.
- 조건: BRAM 수와 parity 비트 매핑은 사용자 빌드 리포트(S5-6)로 확인한다. 넘치면 1.6절의 대안 순서를 따른다.
