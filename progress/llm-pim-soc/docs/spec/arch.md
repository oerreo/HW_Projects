# 마이크로아키텍처 스펙: llm-pim-soc kernel IP (S4)

상태: **초안** (2026-11-19, S4-0). 오케스트레이터 검토 대상. 모듈 트리와 포트는 `hierarchy.md`. 이 문서는 구조 결정과 그 근거, cycle 식, 자원 예산을 적는다. 열린 결정(11절)은 확정되지 않았으며 본문은 **권고안 기준**으로 썼다.

- 근거 문서: `spec/scope.md`, `spec/numeric.md`(1.3절 kernel, 4절 K12V8), `spec/measure.md`, `survey/survey.md`(5.2, 6, 7절), `model/src/kern.c`, `bank.c`, `fwd_h.c`, `model/results/cost.txt`.
- 표기: **[계산]** 구성에서 식으로 구한 값(`docs/spec/s4calc.py` 또는 손계산, 합성/시뮬레이션 아님). **[추정]** 가정이 들어간 값. **[미확인]** 출처를 열지 못한 값. 측정값은 이 문서에 하나도 없다. Fmax, LUT 수, 실제 HP 대역폭은 측정 전이다.
- 전제(오케스트레이터 확정): XC7Z020(53,200 LUT, 220 DSP48E1, 140 BRAM36), PS가 호스트, 목표 클럭 100 MHz 단일 클럭(CDC 없음), control은 직접 RTL, 산술 leaf는 RTL 기본.

## 1. 모델 상수와 연산량 [계산]

| 항목 | 260K | 15M |
|---|---|---|
| dim, hidden, layer, head, kv head, head size | 64, 172, 5, 8, 4, 8 | 288, 768, 6, 6, 6, 48 |
| vocab, ctx | 512, 512 | 32000, 256 |
| 행렬 (rows x n) | wq 64x64, wk/wv 32x64, wo 64x64, w1/w3 172x64, w2 64x172, cls 512x64 | wq/wk/wv/wo 288x288, w1/w3 768x288, w2 288x768, cls 32000x288 |
| token당 gemv 행 수 / MAC | 3,512 / 259,328 | 49,856 / 15,187,968 |
| 행을 8바이트로 padding한 가중치 | 260,608 B (w2의 n = 172 -> 176) | 15,187,968 B (padding 없음) |

## 2. GEMV 가속기형 (15M 주 대상, 260K는 비교용)

### 2.1 가중치 공급 경로: 자체 AXI master (권고, 열린 결정 D1)
`gemv_acc_top`이 HP 포트에 붙는 AXI4 read master(`axi_rd_eng`)와 write master(`axi_wr_eng`)를 직접 갖는다. 가중치, 활성 벡터 x, 출력 y를 모두 IP가 DDR에서 직접 읽고 쓴다.

| 기준 | 자체 AXI master | AXI DMA(Xilinx IP) + AXI-Stream |
|---|---|---|
| RTL 시뮬레이션(G4~G5) | TB의 AXI slave memory model로 전체를 이 서버에서 검증 가능 | DMA IP의 시뮬레이션 모델은 Vivado가 생성해야 한다. 이 서버에서는 Vivado를 실행할 수 없어 DMA 경로는 보드에서 처음 검증된다 |
| ARM 호출 비용 | 레지스터 7~9개 쓰기 + start 1회 | DMA 채널 설정(주소, 길이)과 IP CSR 설정이 둘 다 필요. 행렬마다 DMA 2~3회(x, W, y) |
| 재사용 | 같은 engine을 PIM(x, y, 가중치 적재), attention(DDR KV), vec IP가 쓴다 | 각 IP 앞에 DMA 하나씩 또는 공유 |
| 작업량 | AXI master FSM(4 KiB 분할, outstanding, B 응답) 직접 작성 | block design 구성만 |
| 연구 가치 | control RTL 직접 작성 원칙(`design-methodology.md`)에 맞음 | - |

- burst: HP 포트가 AXI3라 LEN <= 15(16 beat), INCR, SIZE = 8 B, ID 0(in-order). AXI4 master로 쓰되 AXI3에 맞는 부분만 쓰고, block design에서 interconnect/protocol 변환을 거친다(직접 연결 가능 여부는 [미확인]).
- outstanding read 4개(`OUTS`) [추정]: DDR read latency(수십 cycle [추정, Zybo 미측정])를 가리기 위함. 실제 필요 수는 대역폭 측정 빌드(9절)로 정한다.
- 주소는 8 B 정렬 필수(정렬 안 되면 ERR). burst는 4 KiB 경계에서 자른다.

### 2.2 행 레코드 형식 (권고, 열린 결정 D3)
DDR의 행렬 하나 = 행 레코드의 배열. 행 레코드 = header 8 B(`wm`[15:0], 나머지 0) + 가중치 `ceil(n/8) x 8` B(뒤를 0으로 padding). 호스트가 초기화 때 한 번 만든다(`lm_hm_t`에서 재배치, 덤프의 W와 m에서 그대로 생성 가능).
- 엔진은 연속 스트림 하나만 읽고, header beat에서 `wm`을 꺼낸다. 행마다 별도 가수 배열을 읽는 경로가 없다.
- 비용 [계산]: header가 가중치 트래픽에 더하는 비율 15M 2.63%, 260K 10.78%.
- padding 원소의 가중치는 0이라 곱이 0이고, x의 padding 위치도 0으로 마스크해 golden과 bit-exact가 유지된다.
- 같은 레코드 형식을 PIM의 가중치 적재(`LDW`)에도 쓴다(3.3절).

### 2.3 병렬도와 데이터패스
- HP 포트 하나 = 64비트 x 100 MHz = 800 MB/s(방향당 이론) [계산]. int8 가중치는 1 B당 MAC 1회이므로 **포트 하나당 MAC lane 8개면 포트를 포화**한다. lane을 더 두어도 대역폭이 늘지 않는다.
- 구조: 포트 하나에 slice 하나(`gemv_core`, `LANES = 8`). 포트 수 P(1 또는 2, 열린 결정 D2)만큼 slice를 두고, 행을 slice에 교대로 나눈다(행 r은 slice r mod P). y는 행 순서대로 합쳐 `axi_wr_eng` 하나로 쓴다.
- `gemv_core` 데이터패스: x buffer(`N_MAX` B, 64비트 word, LUTRAM) -> 매 beat 8 B x 8 B를 `dotp`(8 lane, int8 x int8, adder tree) -> `mac_row`(25비트 누산, 행 끝 표시) -> `gemv_scale`(행당 1회: `S = acc x wm`, `S x xm`, `rshr_sat(sh = we + xe - fo)`) -> y FIFO.
- 누산 폭 [계산]: lane 곱 < 2^14, 행 합 < `N_MAX` x 127^2 = 1024 x 16,129 < 2^24 -> 25비트 signed(golden의 int32 `acc`와 같은 값). `S` < 2^40(41비트), `S x xm` < 2^57(58비트).
- DSP [계산]: lane 8개 x 1 = 8, `gemv_scale` = 3(`acc x wm`: 25x17 -> 1개, `S x xm`: S를 24 + 17비트로 나눠 2개). slice당 11, P = 2면 22. DSP48E1(25x18)에서 int8 곱 2개를 한 DSP에 넣는 packing은 여유 비트가 부족해 쓰지 않는다 [추정].
- 행 단위 scale(gs = n)만 지원한다(K12V8 확정 형식). gs < n인 descriptor는 ERR. 활성 scale 모드는 무관하다(gemv는 xm, xe만 받는다).

### 2.4 cycle 식 [계산]
입력 beat가 매 cycle 오는 경우(대역폭 효율 eta = 1), slice 하나:

- 호출 1회: `C_gemv = ceil(n/8) + ceil(rows/P) x (1 + ceil(n/8)) + L_dram + L_pipe`
  - `ceil(n/8)`: x 적재. `L_dram`: 첫 read latency(미측정). `L_pipe`: dotp + mac_row + gemv_scale + FIFO(약 8~12 [추정]).
- 실제 시간은 `C / eta`. eta는 HP 실측 전이라 모른다(survey 5.2: ZC702에서 4포트 합 3,254 MB/s, 포트별 376 MB/s 요청 시 달성, Zybo 미측정).

| 경우 | token당 cycle (L_dram, L_pipe 제외, eta = 1) | 100 MHz 시간 |
|---|---|---|
| 15M, P = 1 | 1,950,260 | 19.50 ms |
| 15M, P = 2 | 976,084 | 9.76 ms |
| 15M 분류기만, P = 1 | 1,184,000 (32000 x 37) | 11.84 ms |
| 260K, P = 1 | 36,446 | 0.364 ms |
| 260K, P = 2 | 18,402 | 0.184 ms |

- 15M token당 가중치 15.19 MB는 HP 포트 하나의 이론 대역폭으로 19 ms가 하한이다. ARM의 NEON GEMV도 DDR 대역폭에 묶일 수 있어, P = 1의 가속비가 1 근처일 가능성이 있다 [추정]. 그래서 P = 2 확장을 처음부터 parameter로 둔다.

### 2.5 큰 행렬: 15M 분류기(32000 x 288)
- 타일링이 필요 없다. x(288 B)는 x buffer에 한 번 올리고 32000행을 스트림으로 흘린다. 행마다 37 beat(header 1 + 36).
- 출력 y 128,000 B는 write 채널로 연산과 겹쳐 나간다(read 37 beat당 write 0.5 beat).
- 선택: `argmax_red`를 y 스트림에 붙여 분류기 호출의 끝에 index를 레지스터로 낸다(`FLAGS.argmax_en`). ARM이 128 KB를 invalidate하고 다시 읽는 비용(measure.md의 b)을 없앤다. 검증은 K_GEMV(cls)와 이어지는 K_ARGMAX 레코드를 같이 비교한다. y 쓰기는 끌 수 있으나 검증 빌드에서는 켠다.

## 3. GEMV PIM형 (260K)

### 3.1 bank 구성 (권고: NB = 4, LB = 16, 열린 결정 D4, D5)
- bank 4개, bank당 MAC lane 16개(합 64 lane). bank 하나 = BRAM36 2개 폭(512 x 72 SDP 두 개, 데이터 128비트 + parity 16비트) x 8개 깊이 = 4096 word = 64 KiB 데이터.
- 배치: `bank.c`의 **BANK_ROW 그대로**(행 r -> bank r mod 4, 행렬마다 모든 bank에서 같은 base word 주소). 260K의 모든 행 수(64, 32, 172, 512)가 4의 배수라 bank 사이 빈칸이 없다.
- 행 하나 = `ceil(n/16)` word(n = 64 -> 4 word, n = 172 -> 11 word). 행의 가수 `wm`(16비트)은 그 행 첫 word의 parity 16비트에 둔다(별도 메모리 없음, 열린 결정 D6).

bank 구성 후보 [계산, `docs/spec/s4calc.py`, depth는 bank당 최대 word 수]:

| 구성 | lane | 배치 | bank당 depth (word) | 가중치 BRAM36 | token당 MAC cycle |
|---|---|---|---|---|---|
| **NB 4 x LB 16** | 64 | BANK_ROW | 4,072 / 4,096 | **64** | 4,072 |
| NB 8 x LB 8 | 64 | BANK_ROW | 4,112 (넘침) | 72 | 4,112 |
| NB 8 x LB 8 | 64 | 전역 interleave + bank별 base 표 | 4,072 | 64 | 4,112 |
| NB 16 x LB 8 | 128 | BANK_ROW | 2,056 | 80 | 2,056 |
| NB 16 x LB 8 / NB 8 x LB 16 | 128 | 전역 interleave + bank별 base 표 | 2,040 / 2,036 | 64 | 2,056 |

- 하한: padding한 가중치 260,608 B / 4 KiB = 63.6 -> 64 BRAM36. 위 권고는 이 하한과 같다. parity bit를 데이터로 쓰므로 가수(행 3,512개 x 16비트 = 6.9 KiB) 몫의 BRAM이 따로 들지 않는다.
- "전역 interleave"는 모든 행렬의 행을 이어 붙인 전역 행 번호 g를 bank g mod NB에 두는 방식이다. bank마다 행렬의 시작 주소가 달라 bank별 base 표가 필요하고, `bank.c`에 이 모드(4절 A6)를 추가해야 한다. 128 lane으로 키울 때만 필요하다.

### 3.2 bank 안의 연산과 reduction
```
pim_gb (x, 128b word) --방송--> bank0..3 (lock-step, 같은 word 주소)
bank b: ram_sdp(144b) -> 16 x int8 -> dotp(16 lane) -> mac_row(25b 누산) -> MAC_REG[b] (+ wm, 행 끝에서 latch, double buffer)
gather: MAC_REG[0..3]를 round 순서로 한 개씩 -> gemv_scale(1개/cycle) -> y FIFO -> axi_wr_eng
```
- bank 안: 16 lane 곱을 adder tree(4단)로 합하고, 행의 word 수만큼 누산한다. 행이 bank 안에서 끝나므로 **bank 사이 reduction이 없다**(BANK_ROW). 결과는 행 단위 완성값이다.
- 출력 순서: round i에서 bank b의 결과는 행 4i + b다. gather가 b = 0..3 순서로 읽으면 y가 행 순서로 나온다.
- 처리율 조건: round 하나(행 word 수 nw cycle) 동안 NB개 결과를 scaler 하나가 처리해야 한다. nw >= NB가 조건이고, 260K는 nw = 4 또는 11이라 NB = 4에서 만족한다 [계산]. NB를 8 이상으로 하면 n = 64 행렬에서 scaler 2개 또는 stall이 필요하다.
- BANK_COL(열 분할)과 비교: COL은 bank마다 열 구간만 가져 x 방송이 없고, 매 cycle NB개 부분합을 bank 밖에서 더해야 한다(bank 사이 adder tree). n = 172는 4로 나누면 43이라 lane 16에 맞지 않는다. 공개 PIM의 row-major 타일링(부분합을 MAC_REG에 유지)과 맞는 쪽은 ROW다. 권고는 ROW.

### 3.3 명령과 컨트롤러 (`pim_ctrl`)
| 명령 | 인자 | 동작 | 대응하는 AiM 명령(survey 6.1) |
|---|---|---|---|
| `LDW` | DDR 주소, rows, n, base | 행 레코드(2.2절 형식)를 읽어 행 r을 bank r mod 4의 `base + (r div 4) x nw`에 쓴다. header의 `wm`을 첫 word parity에 넣는다. 초기화 때 1회 | `WRBK`(bank 쓰기) |
| `WRGB` | DDR 주소, n | x(int8 n개)를 global buffer에 적재, 나머지 0 | `WRGB` |
| `MACAB` | base, rows, n, we, xm, xe, fo, y 주소 | 모든 bank가 같은 주소로 lock-step MAC, 결과 gather와 scale, y를 DDR에 씀 | `MACAB` + `RDMAC` |
| `RDROW` (선택) | 행 번호, we, fo, y 주소 | 행 하나를 읽어 `k_embed` 계산(embedding) | `RDCP` 유사 |

- 명령은 CSR의 명령 FIFO로 받는다. 한 layer의 명령을 몰아 넣을 수 있다. 같은 입력을 쓰는 행렬은 `WRGB` 1회 후 `MACAB`를 여러 번 낸다: layer당 `WRGB`(rmsnorm 출력) -> `MACAB` q, k, v / `WRGB`(attention 출력) -> `MACAB` o / `WRGB` -> `MACAB` w1, w3 / `WRGB` -> `MACAB` w2. layer당 WRGB 4회, MACAB 7회 [계산, fwd_h.c 순서]. golden은 K_GEMV 레코드마다 x를 따로 갖고 있으므로 TB는 같은 x임을 확인한다.
- 명령 수는 `bank_stat_t`(wrgb: 32 B 단위, mac: bank당 16 lane 명령 수, rdmac)와 같은 정의로 세어 CSR에 노출한다. `bank.c`의 `BANK_LANES = 16`과 NB = 4가 그대로 맞는다.

### 3.4 cycle 식 [계산]
- `MACAB`: `C_mac = ceil(rows/NB) x ceil(n/16) + L_rd + L_pipe + NB` (L_rd: BRAM read 1 + 깊이 mux 단, L_pipe: dotp + 누산 + scaler, NB: 마지막 round의 drain).
- `WRGB`: `ceil(n/8) + L_dram`.
- token당 MAC cycle: 4,072(64 lane). 100 MHz에서 40.7 us. 같은 260K를 가속기형 P = 1로 하면 36,446 cycle(eta = 1)이라 **cycle 비 8.95배** [계산].
- 호출 오버헤드: layer당 WRGB 4회의 DDR latency와 MACAB 7회의 pipeline/drain이 더해진다. 호출당 50~150 cycle로 가정하면 token당 약 1.8k~5.4k cycle이 MAC cycle과 같은 크기다 [추정]. ARM 쪽 오버헤드(AXI-Lite 쓰기, cache 유지, polling)는 이보다 클 수 있다(survey 9.3 위험 1). 명령 FIFO로 layer 단위 묶음을 권고하는 이유다.

### 3.5 공개 PIM 구조와의 대응
| 요소 | GDDR6-AiM / HBM-PIM (survey 6.1) | 이 설계 | 같음/다름 |
|---|---|---|---|
| 연산기 위치 | DRAM bank마다 PU(AiM: 16 MAC) | BRAM bank마다 16 lane MAC | 같음(bank 옆 연산, lane 수도 16) |
| bank 수 | die당 16(AiM) | 4 | 다름: 용량이 작아 bank를 넓게(2 BRAM 폭) 했다 |
| 벡터 방송 | global buffer 2 KB + `WRGB` | `pim_gb`(N_MAX B) + `WRGB` | 같음 |
| 전 bank 명령 | `MACAB` | `MACAB`(lock-step) | 같음 |
| 결과 | `MAC_REG` + `RDMAC` | bank별 MAC_REG(double buffer) -> gather | 같음. 단 `RDMAC`을 따로 내지 않고 `MACAB`이 끝에서 자동으로 drain |
| 숫자 | BF16(AiM), FP16(HBM-PIM) | int8 x int8, int32 누산, 행 가수 scale | 다름. scale은 컨트롤러의 공유 scaler(`gemv_scale`)가 함 |
| 메모리 timing | ACT/PRE/refresh, row buffer, tCCD | BRAM 1 cycle read, timing 없음 | 다름(scope.md 비범위) |
| 내부 대역폭 | bank 내부 32 B/column | bank당 16 B/cycle, 합 64 B/cycle = 6.4 GB/s @100 MHz [계산] | HP 포트 하나(0.8 GB/s)의 8배 |
| 활성함수 | AiM의 AF(LUT + 선형 보간) | `lut_lerp`(exp, sigmoid)가 같은 방식이나 vec/attention IP에 있다 | 위치 다름 |
| 호스트 명령 | ISR 패킷 -> 저수준 명령 | AXI-Lite 명령 FIFO -> `pim_ctrl` | 같은 계층 구조, 단순화 |

- 가중치 BRAM 64개 중 매 cycle 읽히는 것은 bank당 2개(깊이 방향 8개 중 하나)라 8개뿐이다. 내부 대역폭을 더 쓰려면 lane을 늘려야 하고, 그 한도는 DSP다(8절).

## 4. Attention

### 4.1 알고리즘 경계 (golden `attn_core`, head 하나)
3 pass와 나눗셈 1회가 필요하다. golden이 max를 먼저 구한 뒤 `exp(s - max)`를 계산하므로, max를 따라가며 다시 scale하는 online softmax는 bit-exact가 될 수 없다.

| pass | 읽는 것 | 계산 | 저장 |
|---|---|---|---|
| P1 score | K[t](hs), ks[t], vs[t] | `dot = sum q_i K_ti`, `s = sat32(rshr(rshr(dot, d0) x (qm x km), qe + ke - d0 - 16))`, running `max`, vs.m != 0인 t의 `emin`, `mmax` | p buffer[t] = s |
| P2 exp | p buffer | `d = max(s - max, -2^30)`, `w = rshr(d x 47274, 15)`, `e = exp2neg(-w)`(LUT 보간), `sum += e` | p buffer[t] = e |
| DIV | - | `R = 2^48 / sum`(`udiv_seq`, 몫 33비트) , `G = 17 - bitlen(mmax)` | - |
| P3 V | p buffer, V[t], vs[t] | `p = (e x R + 2^31) >> 32`(출력 p), vs.m != 0이면 `w = rshr(p x vm, ve - emin - G)`, `acc_i += w x V_ti` | 끝에 `o_i = sat32(rshr(acc_i, emin + G))` |

- `d0`는 kb에 따라 0, 7, 15(`k_attn_d0`). q, K, V는 16비트 container로 받아 kb, vb in {8, 12, 16}을 모두 지원한다(비용은 d0 mux 정도, HB/HD 덤프도 벡터로 쓸 수 있다). 기본 형식은 K12V8.

### 4.2 KV 저장 위치와 접근
- **260K (PIM형 시스템): KV를 BRAM에 둔다** (권고, 열린 결정 D7). `kv_store` = kv head마다 SDP RAM 하나, word 216비트(BRAM36 512 x 72 세 개 폭) x 2560(layer 5 x 위치 512, BRAM36 다섯 개 깊이). word = K 8 x 12비트(96) + V 8 x 8비트(64) + ks(m 17 + e 8) + vs(25) = 210비트 <= 216. kv head 4개 x 15 = **60 BRAM36** [계산](`cost.txt`의 하한 60.0과 같다).
  - 쓰기: 위치마다 layer x kv head 20번, 한 번에 한 word. 읽기: 위치 t의 word 하나에서 P1은 K와 두 scale을, P3은 V와 vs를 쓴다. 1 위치/cycle.
  - 주소: `(layer x 512 + t)`. golden `fwd_h.c`의 slot `((l x nkv + j) x seq + pos)`에서 j가 bank 선택이 된다.
- **15M (가속기형 시스템): KV는 DDR** (1,134 KiB, BRAM 초과). `kv_rd`가 golden과 같은 배치(`kc` int16 container, `vc` int8, `kcs`/`vcs`는 {int32 m, int32 e})의 버퍼를 `axi_rd_eng`로 읽어 pass 스트림을 만든다. ARM의 `actq`가 쓰는 배치를 그대로 쓰므로 재배치가 없다.

### 4.3 데이터패스와 폭 [계산]
| 단계 | 연산 | 폭 | DSP48E1 |
|---|---|---|---|
| score MAC | q(16b) x K(16b), KL lane | 곱 < 2^30(kb 16), dot < 2^36(hs 64) | KL (lane당 1) |
| c | qm x km (17b x 17b unsigned) | 34비트 | 1 |
| score scale | (dot >> d0, 23비트) x c(34비트) | < 2^56 | 2 |
| exp 인자 | d(31비트) x 47274(16비트) | 48비트 | 2 |
| LUT 보간 | (a - b) x fr | < 2^20 | 1 (또는 LUT) |
| 정규화 | e(17b) x R(33b) | 50비트 | 2 |
| V 가중치 | p(17b) x vm(17b) | 34비트 | 1 |
| V MAC | w(34~35비트) x V(16b container), VL lane | 곱 < 2^50, 누산 `35 + 16 + clog2(T_MAX)` = 60비트(T_MAX 512) | VL x 2 (w를 17비트 둘로 나눔) |

- head engine 하나(KL = VL = 8): DSP 8 + 1 + 2 + 2 + 1 + 2 + 1 + 16 = **33** [계산]. V 누산기 60비트 x 8은 DSP의 48비트 누산을 넘으므로 fabric 덧셈기로 둔다. 12x12 곱을 LUT로 하면 DSP 25개로 줄지만 LUT가 lane당 약 80 늘어난다 [추정].
- p buffer: `T_MAX x 32` = BRAM18 하나(512 x 36). exp LUT 257 x 17비트는 인접 두 항목을 한 번에 읽도록 (a, b) 쌍 256 x 34비트 ROM(LUT 약 140개 [추정])으로 둔다.

### 4.4 cycle 식 [계산]
head 하나, KV가 매 cycle 오는 경우: `C_head = T x ceil(hs/KL) + T + T x ceil(hs/VL) + C_div + L_pipe`. `C_div = 35`(`udiv_seq` Q_W 33 + 2), `C_div + L_pipe`를 합쳐 약 80으로 둔다 [추정].

- 260K(hs 8, KL = VL = 8, KV는 BRAM): `C_head = 3T + 80`. engine 수 H_PAR(열린 결정 D8). token당 `5 x 8 / H_PAR x (3T + 80)`.

| T | head 1개 | token당 H_PAR = 2 | token당 H_PAR = 4 |
|---|---|---|---|
| 1 | 83 | 1,660 | 830 |
| 64 | 272 | 5,440 | 2,720 |
| 256 | 848 | 16,960 | 8,480 |
| 512 | 1,616 | 32,320 (323 us @100 MHz) | 16,160 |
| 위치 1..512 평균 | - | 16,990 (170 us) | 8,495 |

- 15M(hs 48, KV는 DDR, HP 포트 하나, eta = 1): P1은 위치당 K 96 B + scale 16 B = 14 beat, P3은 V 48 B = 6 beat라 대역폭에 묶인다. `C_head = 14T + T + 6T + 80 = 21T + 80`. token당 36 head: T = 128에서 99,648, T = 256에서 196,416, 위치 1..256 평균 100,026 cycle(1.0 ms) [계산]. gemv(19.5 ms)의 약 5%로, 15M에서는 attention 오프로드의 이득이 작다 [추정].
- engine과 KV bank 대응(260K): H_PAR = 2면 engine 0이 kv head 0, 1(q head 0~3), engine 1이 kv head 2, 3을 맡는다. H_PAR = 4면 engine j = kv head j(q head 2j, 2j+1 순차). q head 두 개가 같은 kv head를 쓰므로, 두 head를 lock-step으로 묶어 K/V read를 공유하는 변형도 가능하다(DSP는 두 배, BRAM 포트는 그대로).

### 4.5 호출 단위
golden과 ARM baseline은 head마다 attention을 호출한다(260K token당 40회, 15M 36회). IP는 layer 단위 명령(head 범위, T, q 레코드 주소, o 주소)을 받아 head를 돌고, 출력은 head별 레코드와 같은 배치(o: head j의 hs개가 `att + j x hs`)로 쓴다(열린 결정 D9). p 출력은 검증용으로 켜고 끌 수 있다.

## 5. 나머지 kernel

### 5.1 actq_core (rmsnorm, swiglu, actq 공유)
- 순서: 입력 int32 스트림을 buffer(`N_MAX x 32`)에 쓰며 `amax`(|v| 최대) -> `amax == 0`이면 0 출력과 scale {0, 0} -> 아니면 `L = bitlen(amax)`, `e = 16 + bitlen(qmax) - L`, `num = rshr(amax, -e)`, `M = (num + qmax/2) / qmax`, `R = (2^40 + M/2) / M`(나눗셈 2회, `udiv_seq` 하나 순차) -> buffer를 다시 읽어 `q = clamp(rshr(v x R, 40 - e), qmax)` -> scale `{M, e + f}`.
- rmsnorm과 swiglu도 golden에서 같은 `aq_setup`/`aq_one`을 쓰고 출력 지수만 `e + fy`, `e + K_FX`로 다르다. 따라서 front가 int32 스트림을 넘기고 `f`를 parameter로 주면 같은 모듈로 bit-exact다 [코드 대조로 확인, 실행 안 함].
- MANT만 지원(K12V8). qmax는 127, 2047, 32767 런타임 값.
- cycle [계산]: `2n + 2 x 27 + L` (udiv Q_W 25 + 2 두 번). n = 8(head 하나)이면 나눗셈이 대부분이라, ARM의 head별 actq(token당 260K 85회)를 하나씩 오프로드하는 것은 호출 오버헤드가 지배한다 [추정]. v1에서는 rmsnorm, swiglu 안의 actq와 단독 ACTQ op만 두고, head별 q/K/V 양자화는 ARM에 남기는 것을 권고한다(S5에서 attention 앞단 융합 후보).
- DSP 2(v x R: 32 x 25비트). buffer: `N_MAX` 1024면 BRAM36 1개, 260K 시스템에서 `N_MAX` 256이면 LUTRAM.

### 5.2 rmsnorm (`rms_front` + `actq_core`)
- pass: (1) x와 g를 buffer에 받으며 amax, (2) `k = max(bitlen(amax) - 15, 0)`, `xs = clamp(rshr(x, k), 32767)`, `ss += xs^2`(41비트), (3) `u = ss + rshr(epsc, 2k)`, `rsqrt_nr`(seed 48항목 + Newton 2회, 순차), (4) `y = sat32(rshr(xs x g x rm, ge + re - fy))`를 `actq_core`로 보냄.
- cycle [계산]: 약 `4n + C_rsqrt + C_actq_setup`, C는 약 130 [추정]. 260K n = 64 약 390, 15M n = 288 약 1,280.
- DSP 약 5(xs^2 1, xs x g x rm 2, rsqrt 순차 곱 1~2) [계산].

### 5.3 swiglu (`swi_front` + `actq_core`)
- 원소마다 `s = sigmoid(h1)`(LUT 보간, 음수는 1 - s), `silu = rshr(h1 x s, 16)`(32 x 17비트), `g = sat32(rshr(silu x h3, 16))`(32 x 32비트) -> `actq_core`.
- cycle [계산]: 약 `2n + 110` [추정 상수]. 260K n = 172 약 450, 15M n = 768 약 1,650.
- DSP 약 7(2 + 4 + 1) [계산].

### 5.4 argmax
- `argmax_red`: 1원소/cycle, 엄격한 `>`일 때만 갱신(같은 값이면 앞 index). DSP 0, LUT 약 60 [추정].
- 15M 분류기는 gemv_acc의 y 스트림에 융합(2.5절). 단독 op는 vec_top의 ARGMAX(n cycle).

### 5.5 embed, rope, add
v1은 ARM에 둔다(measure.md 7절, PC 비중 합 0.5% 이하). PIM형에서 embedding은 cls 가중치가 bank에 있으므로 `RDROW`로 선택 지원한다. rope ROM(260K 512 x 8 x 16비트 = 8 KiB, BRAM36 2개)은 rope를 PL로 옮길 때만 필요하다.

## 6. 공통 leaf의 bit-exact 규칙
- `rshr`: `s > 0`이면 `floor((x + 2^(s-1)) / 2^s)`(산술), `s >= IN_W`이면 0(golden: `s >= 62` -> 0, `|x| < 2^61` 전제에서 같은 결과), `s == 0`이면 x, `s < 0`이면 포화 좌shift. golden의 64비트 포화는 `+I64MAX` / `-I64MAX`(대칭)이고 `sat32`는 `I32MIN`까지 쓴다. 두 경우를 `SAT_MODE`로 구분한다.
- golden이 uint32로 계산하는 보간(`(a - b) x fr`)은 범위 안에서 wrap이 없다 [계산: 차이 < 2^11, fr < 2^12].
- `udiv_seq`는 몫이 Q_W 비트에 들어간다는 전제를 가진다(actq의 M < 2^17, R < 2^25; attention의 R <= 2^32). 전제 위반은 assertion.
- 지수와 shift 범위는 덤프에서 집계해 `E_W`, `SH_W`를 확정한다(hierarchy.md 4절 A10). 그 전까지 TB는 range assertion으로 범위 밖 입력을 표시한다.

## 7. HW/SW 인터페이스 (초안)

### 7.1 데이터 이동 방식
- v1: **kernel 경계 = DDR 버퍼**. 모든 IP가 입력을 DDR에서 읽고 출력을 DDR에 쓴다. 버퍼 형식은 golden의 버퍼와 같다(int8/int16/int32 배열, scale은 {int32 m, int32 e}). 예외는 초기화 때 만드는 가중치 행 레코드(2.2절)와 PIM bank 적재뿐이다. 이렇게 하면 IP 호출 1회 = 덤프 레코드 1개라 보드 결과를 golden과 바로 비교한다(열린 결정 D11).
- cache: PS는 입력 버퍼를 `Xil_DCacheFlushRange`, 출력은 `Xil_DCacheInvalidateRange`. 비용은 크기에 비례하고 measure.md의 (b)로 따로 잰다. ACP(coherent)는 쓰지 않는다(survey 5.2: ACP 대역폭이 낮다는 2차 자료 [미확인]).
- HP 포트: 가속기형 시스템은 gemv_acc HP0(P = 2면 HP2 추가, HP0/HP1과 HP2/HP3이 다른 DDR 포트를 쓴다는 자료 [미확인]), attention HP1, vec HP3. PIM형 시스템은 트래픽이 작아 HP 하나를 interconnect로 공유.
- interrupt: done을 IRQ_F2P에 연결해 두되 v1 드라이버는 polling(측정 단순화).

### 7.2 레지스터 맵 틀 (모든 L3 IP 공통, 32비트, offset은 byte)
| offset | 이름 | 접근 | 내용 |
|---|---|---|---|
| 0x00 | ID | R | [31:16] IP 종류(GEMV_ACC, PIM, ATTN, VEC), [15:0] 버전 |
| 0x04 | CONFIG | R | 빌드 parameter(IP별: LANES, P, NB, LB, KL, VL, H_PAR, N_MAX, T_MAX), `fclk_mhz` |
| 0x08 | CTRL | W | bit0 `start`(1 cycle pulse), [7:4] `op` |
| 0x0C | STATUS | R | bit0 `busy`, bit1 `done_sticky`(CTRL 쓰기 때 clear), bit2 `err_any`, [23:8] 명령 FIFO 수(PIM, ATTN) |
| 0x10 | ERR | R/W1C | `start_busy`, `bad_op`, `bad_desc`(범위: n > N_MAX, T > T_MAX, gs != n, 지원 안 하는 kb/vb/mode), `misalign`, `axi_resp`(SLVERR/DECERR), `fifo_ovf` |
| 0x14 | CYCLES | R | 마지막 op의 start 수락부터 done까지 cycle(measure.md의 a) |
| 0x18 | RD_STALL | R | 같은 구간에서 코어가 read 데이터를 기다린 cycle(데이터 이동 중 연산과 겹치지 않은 부분) |
| 0x1C | WR_STALL | R | write 쪽 backpressure로 멈춘 cycle |
| 0x20 | OPS | R | 명령 수 카운터(PIM: WRGB, MACAB, mac 명령 수. 비교 지표) |
| 0x40~ | descriptor | R/W | IP별(아래) |

pqc-ntt-ip `l4_axi.md`의 확정 동작(done_sticky 우선순위, W1C set 우선, 정의되지 않은 주소 읽기 0, WSTRB 무시)을 그대로 따른다.

IP별 descriptor:
- GEMV_ACC: `W_ADDR`(행 레코드), `X_ADDR`, `Y_ADDR`, `ROWS`, `N`, `XM`[16:0], `EXP`{`we`, `xe`, `fo`} 각 8비트 signed, `FLAGS`{`argmax_en`, `y_en`}, `ARGMAX_IDX`(R).
- PIM: `CMD0..CMD3` + `CMD_PUSH`(쓰면 FIFO에 1개 넣음). 명령 형식은 3.3절. op = RUN이면 FIFO를 비울 때까지 실행.
- ATTN: `Q_ADDR`(head마다 q[hs] int16 + {m, e}), `O_ADDR`, `P_ADDR`(+ `p_en`), `T`, `HS`, `KB`, `VB`, `HEAD0`, `NHEAD`, `KVMUL`, `LAYER`(BRAM KV) 또는 `K_ADDR`/`V_ADDR`/`KS_ADDR`/`VS_ADDR`(DDR KV). KV 쓰기 명령 `KVW`(260K: layer, kv head, pos, 원본 주소).
- VEC: op(RMSNORM, SWIGLU, ACTQ, ARGMAX), `N`, `IN0_ADDR`, `IN1_ADDR`(g 또는 h3), `LUT_SEL`, `OUT_ADDR`, `SCL_ADDR`(m, e를 int32 두 개로 씀), 파라미터(`f`, `qmax`, `ge`, `epsc`, `fy`).

### 7.3 kernel 호출 한 번의 순서 (GEMV 가속기형 예)
1. (초기화 1회) 가중치를 행 레코드로 재배치하고 flush.
2. ARM이 만든 x(int8 n개)를 `Xil_DCacheFlushRange(x, n)`.
3. descriptor 쓰기: `X_ADDR`, `W_ADDR`, `Y_ADDR`, `ROWS`, `N`, `XM`, `EXP`(바뀌는 것만, 최대 7회).
4. `CTRL.start`.
5. `STATUS.done_sticky` polling(또는 interrupt).
6. `ERR`, `CYCLES`, `RD_STALL` 읽기(측정 빌드).
7. `Xil_DCacheInvalidateRange(y, 4 x rows)`, ARM이 y 사용.

measure.md 6절과의 대응: a = `CYCLES / f_PL`, b = 2와 7의 시간 + `RD_STALL / f_PL`, c = 3~6의 ARM 시간에서 a를 뺀 값. PIM은 3~4 대신 명령 FIFO에 layer 묶음을 넣고 한 번 기다린다.

## 8. 자원 예산 (Z7-20: 220 DSP, 140 BRAM36, 53,200 LUT)

DSP와 BRAM은 구조에서 센 [계산], LUT는 [추정](비슷한 크기 모듈의 경험치, 합성 안 함). AXI interconnect와 PS 주변 IP는 Xilinx IP라 LUT만 [추정].

| 모듈 | DSP | BRAM36 | LUT [추정] |
|---|---|---|---|
| gemv_acc (P = 1, 엔진과 CSR 포함) | 11 | 0~1 (FIFO) | 2.5k~4k |
| gemv_acc (P = 2) | 22 | 0~2 | 4k~6k |
| pim (NB 4 x LB 16, 엔진과 CSR 포함) | 67 | 64 | 3k~5k |
| attention engine 1개 (KL = VL = 8) | 33 | 0.5 | 3k~5k |
| kv_store (260K) | 0 | 60 | 0.3k~0.5k |
| kv_rd (15M) | 0 | 0 | 0.5k~1k |
| vec (rms_front, swi_front, actq_core, argmax) | 14 | 0.5~1 | 3k~5k |
| AXI interconnect, proc_sys_reset 등 | 0 | 0 | 2k~5k |

시스템별 합:

| 시스템 | 구성 | DSP | BRAM36 | LUT [추정] |
|---|---|---|---|---|
| P (260K PIM형) | pim + attention H_PAR 2 + kv_store + vec + interconnect | 67 + 66 + 14 = **147 / 220 (67%)** | 64 + 60 + 1 + 1 = **126 / 140 (90%)**, rope ROM을 넣으면 128 | 15k~25k (28~47%) |
| P, H_PAR 4 | 위에서 attention만 4개 | 213 / 220 (97%) | 127 | 21k~35k |
| A (15M 가속기형) | gemv_acc P 1 + attention 1 (kv_rd) + vec + interconnect | 11 + 33 + 14 = **58 (26%)** | 약 3 | 10k~17k (19~32%) |
| A, P = 2 | | 69 (31%) | 약 4 | 12k~19k |

- 가장 빡빡한 것은 시스템 P의 BRAM(90%)이다. 남는 14개 안에 FIFO, buffer, (Vivado가 넣는) interconnect FIFO가 들어가야 한다. 72비트 폭 SDP RAM을 추론하면서 parity bit를 데이터로 쓰는 매핑을 Vivado가 하는지는 [미확인]이다. 안 되면 `fpga/` wrapper에서 RAMB36E1을 직접 쓴다(`design-methodology.md` 허용 범위).
- 시스템 P에서 H_PAR = 4는 DSP 97%라 배치가 어렵다 [추정]. 권고는 H_PAR = 2.
- 100 MHz 타이밍 위험 [추정, 미측정]: 64비트 barrel shifter(`rshr_sat`), 58비트 곱 사슬(`gemv_scale`), 60비트 누산, BRAM 깊이 8단 출력 mux. 모두 `PIPE` parameter로 단을 추가할 수 있게 한다.

## 9. 구현 순서 제안

오케스트레이터 틀(공통 leaf -> GEMV 가속기형 -> PIM형 -> attention -> 나머지 -> S5)을 유지하고 세 가지를 바꾼다.

1. **leaf는 필요한 단계에서 만든다**: GEMV에 필요한 `rshr_sat`, `dotp`, `sync_fifo`, `ram_sdp`만 먼저 만들고, `lut_lerp`, `udiv_seq`는 attention 단계, `rsqrt_nr`은 vec 단계에서 만든다. 앞에서 모든 leaf를 만들면 상위 인터페이스가 정해지기 전에 leaf를 고정하게 되어 재작업이 생긴다.
2. **GEMV 가속기형을 core와 AXI engine으로 나눈다**: `gemv_core`(스트림)를 먼저 G4로 통과시키고, `axi_rd_eng`/`axi_wr_eng`는 따로 검증한다. engine은 PIM, attention, vec이 모두 재사용한다.
3. **HP 대역폭 측정 빌드를 일찍 요청한다**: `axi_rd_eng`가 G4를 통과하면 `axi_rd_eng` + CSR만 있는 측정 top(N 바이트 읽기, cycle 수)을 만들어 사용자 보드 실행을 요청한다(scope.md 측정 계획의 "HP 대역폭 측정용 단순 빌드"). 결과(eta, OUTS 효과, 포트 2개 동시)로 D2(포트 수)를 정한다. 이 빌드는 GEMV IP의 G5가 아니라 측정 도구다.

- 대안: 260K의 PC 프로파일(measure.md, 512 위치)에서 attention이 70.5%라 attention을 PIM보다 먼저 하는 순서도 가능하다. 다만 프로젝트의 핵심 비교가 GEMV 두 구조라 원래 순서를 권고한다.

## 10. 확인하지 못한 것
- Zybo Z7-20의 HP 포트 실측 대역폭과 DDR read latency(eta, L_dram). 모든 가속기형 시간은 eta = 1 가정의 하한이다.
- 100 MHz 타이밍 달성 여부, LUT 수, Vivado가 72비트 SDP에 parity bit를 쓰는 추론을 하는지.
- DSP48E1에서 int8 곱 2개 packing의 가능 여부(쓰지 않는 것으로 가정).
- AXI3 HP 포트에 interconnect 없이 붙일 수 있는지.
- 지수와 shift의 실제 범위(`E_W` = 8 가정).
- ARM baseline 수치(S3 보드 실행 대기). 따라서 kernel별 가속비는 어떤 것도 추정하지 않았다.
- `actq_core`를 rmsnorm/swiglu에 공유해도 bit-exact라는 판단은 코드 대조만 했다(S4 해당 단계의 TB로 확인).

## 11. 열린 결정

| ID | 결정 | 대안 | 장단점 | 권고 |
|---|---|---|---|---|
| D1 | 가속기형 가중치 경로 | (a) 자체 AXI master on HP (b) AXI DMA + AXI-Stream | (a) 이 서버에서 전체 RTL 시뮬레이션 가능, ARM 호출이 단순, 다른 IP가 재사용. AXI master를 직접 써야 함. (b) block design만 하면 되나 DMA 시뮬레이션 모델을 만들 수 없어 보드에서 처음 검증, 호출당 DMA 설정 비용 | (a) |
| D2 | 가속기형 HP 포트 수 | (a) P = 1 (8 lane) (b) P = 2 (16 lane) (c) 4 | P가 이론 대역폭에 비례(15M 19.5 / 9.76 ms). 포트를 늘리면 DSP와 LUT는 작게 늘지만 DDR 포화와 PS 접근 경쟁이 미지수 | RTL은 P parameter로 만들고 v1 보드 빌드는 P = 1. 대역폭 측정(9절 3) 후 P = 2 결정 |
| D3 | 행 레코드 형식 | (a) header 8 B + 행 (b) 가수 배열 분리 | (a) 스트림 하나, 컨트롤 단순, PIM LDW와 공유. 트래픽 +2.63%(15M), +10.78%(260K). (b) 트래픽 +0.7%(15M)이나 두 스트림을 섞는 prefetch가 필요 | (a) |
| D4 | PIM bank 수와 lane | (a) NB 4 x LB 16 (64 lane) (b) NB 8 x LB 16 또는 NB 16 x LB 8 (128 lane) | (a) BRAM 64, bank.c BANK_ROW와 그대로 일치, scaler 1개, DSP 67. (b) MAC cycle 절반(2,056)이나 DSP 131, 전역 interleave와 scaler 2개 필요, attention에 줄 DSP가 줄어듦. 260K에서는 attention이 gemv보다 cycle이 많다(4.4절) | (a) |
| D5 | PIM 가중치 배치 | (a) BANK_ROW (b) 전역 interleave + bank별 base 표 (c) BANK_COL | (a) golden 그대로, NB 4에서 BRAM 64. (b) NB 8 이상에서 BRAM을 64로 유지하나 bank.c에 모드 추가. (c) 방송이 없고 bank 밖 reduction이 필요, n = 172 분할이 불균등 | (a). D4가 (b)이면 (b) |
| D6 | PIM 행 가수 저장 | (a) 첫 word의 parity bit (b) bank별 LUTRAM 표 | (a) 추가 메모리 0, 가중치와 같이 읽힘. Vivado 추론 확인 필요. (b) LUT 약 80 x 4 [추정] | (a), 추론이 안 되면 primitive wrapper |
| D7 | 260K KV 위치 | (a) BRAM (60 BRAM36) (b) DDR | (a) PIM형 시스템이 "가중치와 KV 상주"라는 전제를 만족, attention이 1 위치/cycle. BRAM 90% 사용. (b) BRAM 여유가 크나 attention이 DDR 대역폭에 묶이고 260K의 KV 트래픽이 가중치와 비슷(cost.txt 비 0.87~1.18) | (a) |
| D8 | attention engine 수 H_PAR (260K) | 1, 2, 4, q head 쌍 lock-step | 2: DSP 66, token당 평균 17k cycle. 4: DSP 132, 8.5k cycle이나 시스템 P DSP 97% | 2 |
| D9 | attention 호출 단위 | (a) head마다 호출 (golden 그대로) (b) layer 단위 명령, 출력은 head별 배치 | (a) 260K token당 40회 호출 오버헤드. (b) 호출 5회, 출력 배치가 같아 레코드 비교 가능 | (b) |
| D10 | vec IP 구성 | (a) rmsnorm/swiglu/actq/argmax를 vec_top 하나로, actq_core 공유 (b) kernel마다 IP | (a) DSP와 buffer 절약, HP 포트 하나. 동시에 실행할 일이 없다(forward가 순차). (b) kernel별 오프로드 측정이 독립적 | (a). 측정은 op별 CYCLES로 분리 |
| D11 | kernel 사이 데이터 전달 | (a) v1은 DDR 경유 (b) on-chip 연결(융합) | (a) IP 호출 = 덤프 레코드, 측정 항목(b) 분리가 쉽다. (b) 데이터 이동 감소, S5 이후 | (a), (b)는 S5에서 측정 결과를 보고 결정 |
| D12 | 구현 순서 | 오케스트레이터 순서 그대로, 또는 9절의 세 수정, 또는 attention 우선 | 9절 | 9절의 세 수정 |
| D13 | HLS 병행 | (a) v1 생략 (b) `exp_unit` 또는 `gemv_core`를 Catapult로 같은 포트에 | (b) 연구 가치는 있으나 S4 범위가 이미 크다 | (a), S4 완료 후 `exp_unit` 후보 |
| D14 | 지원 형식 범위 | (a) kb, vb in {8, 12, 16}, gs = n, MANT만 (b) K12V8 고정 | (a) 비용이 작고 HB/HD 덤프로 벡터를 늘림. (b) 가장 단순 | (a) |

## 12. 결정 (2026-11-19, 오케스트레이터)
D1~D14는 모두 11절의 권고대로 확정한다.
- D1 (a) 자체 AXI master, D2 RTL은 P parameter이고 첫 보드 빌드는 P = 1, D3 (a), D4 (a) NB 4 x LB 16, D5 (a) BANK_ROW, D6 (a) parity bit(Vivado 추론이 안 되면 `fpga/` wrapper에서 primitive), D7 (a) BRAM, D8 H_PAR = 2, D9 (b), D10 (a), D11 (a), D12 9절의 세 수정, D13 (a), D14 (a).
- 조건: BRAM 126/140과 parity bit 사용은 보드 빌드 전까지 [계산]이다. 첫 PIM형 빌드의 utilization 리포트로 확인하고, 넘치면 D7을 다시 연다.
- 정리할 것(S4-1): `s4calc.py`의 KV word 208비트와 4.2절의 210비트가 다르다. 어느 쪽이 맞는지 맞춘다(BRAM 수 60은 둘 다 같다).
