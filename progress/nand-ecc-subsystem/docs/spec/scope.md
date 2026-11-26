# N1 범위와 시스템 스펙: nand-ecc-subsystem

상태: **초안** (2026-11-25, N1). 열린 결정(9절)은 오케스트레이터가 확정한다. 본문의 "권고"는 확정 전 제안이다.

- 함께 읽을 문서: `spec/code.md`(주 code 구성과 검증), `spec/channel.md`(채널 모델, 감지, LLR, 난수), `survey/survey.md`(출처 R1~R52).
- 표기: **[계산]** `docs/spec/s1calc.py`(출력 `docs/spec/s1calc.txt`, 표준 라이브러리, 인자 없음) 또는 식으로 구한 값. 합성/시뮬레이션/보드 결과가 아니다. **[추정]** 가정이나 판단이 들어간 값. **미확인** 출처 미확인. 이 문서에 측정값은 없다.
- 전제: Zybo Z7-20(XC7Z020: LUT 53,200, BRAM36 140, DSP 220 [survey 6절], PS Cortex-A9 667 MHz, DDR3L 1 GB [R51]), PL 100 MHz 단일 클럭 가정, PS가 호스트. 이 서버에서 Vivado는 실행하지 않는다.

## 1. 시스템 범위

| 구분 | 포함 | 비포함 |
|---|---|---|
| 채널 | MLC 해석 모델 [R3], 3D TLC fit 표 [R5], 감지(hard, retry, soft +2/+4/+6), LLR LUT | 실측 NAND, 셀 간 상관(CCI는 주변분포로만), read disturb 동역학 |
| ECC | 자체 QC-LDPC (9216, 8192)(`code.md`), BCH (9207, 8192) t = 73(C만), 외부 기준 code(CCSDS C2, 802.3an)는 golden 검증용 | 5G/802.11 multi-rate, HARQ, RAID |
| 정책 | hard → retry → soft 단계 read 정책(상태 기계), [R7] 식(1) 지연 모델 | FTL, 블록별 기준 전압 학습(ROR [R8] 원리만 참고) |
| HW | LDPC decoder IP, LLR 생성, encoder, (선택) PL 채널 에뮬레이터, AXI top | BCH IP(시간 여유 시 별도 결정), ASIC 합성(DC는 승인 시) |

## 2. C 전체 구성 (golden이자 ARM baseline, N2)

언어는 C99(표준 라이브러리만). PC(gcc)와 Zybo ARM(bare-metal)에서 같은 소스가 돈다. 비트 정확성이 필요한 경로(채널 감지 샘플, LLR, 고정소수점 decoder, encoder, BCH)는 정수만 쓴다. double은 표 생성과 float 참조 decoder에만.

| 파일 (`model/src/`) | 책임 | kernel 경계(프로파일 단위) |
|---|---|---|
| `code.c/h` | shift 표 로더(`code.md` 2.2), H 펼침, alist 입출력(외부 code와 AFF3CT 교차용) | - |
| `rng.c/h` | xoshiro128** [R50], lane별 seed 생성 | K_RNG(채널 안에 포함해 측정) |
| `chan.c/h` | 모델 A/B, 감지 격자별 누적확률 정수 표 T_s[j] 생성(double, 오프라인), 연속 Vth 참조 샘플러(Box-Muller, 검증용) | - (표 생성은 측정 제외) |
| `sense.c/h` | `chan_sample`(이산 역CDF, 정수), read 설정별 격자 → 구간 묶음, retry offset 표 | **K_CHAN**, **K_SENSE** |
| `llr.c/h` | LLR LUT 생성(double → 정수), `llr_map` | **K_LLR** |
| `enc.c/h` | dual-diagonal encoder(`code.md` 2.3), 블록 회전 | **K_ENC** |
| `dec_ref.c/h` | float 참조: SPA와 min-sum, flooding과 layered. 임의 H(외부 code 포함) | 비교용, 측정 대상 아님 |
| `dec_fix.c/h` | 고정소수점 layered NMS/OMS(3절 형식, RTL의 golden). layer/iteration 단위 dump hook | **K_DEC**(iteration, layer 단위 하위 측정) |
| `dec_hard.c/h` | GDBF 계열 bit flipping(C 비교용) [R17] | 비교용 |
| `synd.c/h` | syndrome 계산과 조기 종료 판정 | **K_SYND** |
| `bch.c/h` | GF(2^14) 표, systematic LFSR encoder, syndrome, (inversionless) BM, Chien. 실패 규칙은 AFF3CT `STD`와 같게(근 수 ≠ 차수면 입력 그대로) [R37] | **K_BCH_ENC**, **K_BCH_SYND**, **K_BCH_BM**, **K_BCH_CHIEN** |
| `policy.c/h` | read retry 상태 기계와 지연 모델(2.2절) | **K_POLICY**(작음) |
| `fer.c` | Monte Carlo FER 드라이버. 설정 파일 입력, seed와 codeword 수 기록, 오류 frame 100개 또는 상한에서 정지 | - |
| `dump.c/h` | TB 벡터 덤프(kernel 경계 입출력) | - |

- 실행 파일 이름은 일반적으로(`t` 단위 테스트, `fer`), 조건은 설정 파일로 넘긴다(`process-privacy.md`).
- 외부 code 검증용으로 decoder는 code 무관(H 입력)하게 만든다. 고정소수점 decoder는 weight-1 circulant QC만 지원해도 된다(layer 내 중복 없음을 전제). 외부 code의 layered 검증은 `dec_ref.c`(일반 H, 행 단위 layer)가 맡는다.

### 2.1 BCH parameter (비교용, C만)
- 같은 데이터 8192 bit, 같은 parity 예산(≤ 1024 bit = LDPC parity)에서 [계산, `s1calc.txt` 8절]:
  - **GF(2^14), t = 73, parity 1015 bit, shortened (9207, 8192), rate 0.889758** (권고). α^129의 cyclotomic coset이 크기 7이라 parity가 14 x 73 = 1022가 아니라 1015다.
  - 대안 GF(2^15), t = 68, parity 1020, (9212, 8192).
  - GF(2^13)는 n ≤ 8191이라 불가.
- 문헌 비교: [R3] 512 B에 t = 54(GF(2^13)), [R4] 4 KB에 t = 109. 1 KB t = 73은 그 사이다.
- 비교 기준: 같은 raw BER에서 BCH(hard), LDPC hard(±A 입력 min-sum), LDPC soft(+2/+4/+6)의 FER. BCH의 FER은 해석식(오류 > t인 확률)으로도 계산해 Monte Carlo와 교차 확인한다.

### 2.2 read retry 정책 (상태 기계)
```
HARD(ref0) -> DEC_H --ok--> DONE
                |fail
                v
RETRY(k=1..K): HARD(ref0 + Δ_k) -> DEC_H --ok--> DONE
                |fail after K
                v
SOFT(L in levels, e.g. +2 -> +4 -> +6): sense L levels -> LLR LUT -> DEC_S --ok--> DONE
                |fail after last level
                v
FAIL (UECC 보고)
```
- DEC_H: 같은 decoder에 hard LLR(±A)을 넣는다(권고, D7). GDBF는 C 비교용.
- 정책 parameter: K(retry 수, 0 허용), Δ_k 표(`channel.md` 4.2), soft level 순서, 단계별 iteration 상한.
- 지연 모델: `τ_total = τ_hd-sen + τ_hd-xfer + τ_dec + P_hd-fail · (τ_sd-sen + τ_sd-xfer + τ_dec)` [R7] 식(1)을 retry 단계까지 확장한 합. 감지/전송 시간은 [R7]의 25nm MLC 값(hard 41/55 µs, 레벨당 약 14 µs, 7레벨 4 KB 전송 약 80 µs)을 쓰고 그 사실을 명시한다. τ_dec은 측정값(C, ARM, PL)을 넣는다.
- 출력: 조건별 평균 read 지연, 단계별 도달 확률, 평균 read 횟수.

## 3. Decoder 알고리즘과 고정소수점 형식 (후보, N2b에서 결정)

### 3.1 알고리즘 (dec_fix, RTL golden)
layer r(= base 행 r, 128 check 병렬)마다, 그 layer의 block 열 c에 대해:
```
phase 1 (열마다):  Q_c = sat_Q(APP_c − R_old[r,c])            (lane i: shift s(r,c) 적용 후)
                   check별 min1, min2, idx(min1 위치), sign 곱 갱신 (|Q| 기준)
phase 2 (열마다):  m = (c == idx) ? min2 : min1
                   R_new[r,c] = sign_i · f(m),  f = NMS: floor(α m) 또는 OMS: max(m − β, 0)
                   APP_c = sat_A(Q_c + R_new[r,c])
```
- 한 layer 안에서 variable이 한 번만 나오므로(`code.md` 6절) 열 처리 순서는 결과에 영향이 없다. **layer 순서만** 결과를 바꾼다. 그래서 RTL은 hazard를 피하려고 열 순서를 바꿔도(`code.md` 6절) golden과 bit-exact를 유지한다. layer 순서는 0..7 고정(권고).
- R 초기값 0, APP 초기값 = 채널 LLR(부호 확장).
- 조기 종료 후보:
  - ET-A(정확): iteration 끝의 APP 부호로 전체 syndrome 계산, 0이면 종료.
  - ET-B(on-the-fly): 한 iteration 동안 모든 layer의 check가 phase 1에서 읽은 부호로 만족 **그리고** 그 iteration 동안 hard decision이 하나도 바뀌지 않았으면 종료. 이 경우 그 hard decision은 codeword다.
  - 어느 쪽이든 C와 RTL은 같은 규칙과 같은 판정 시점을 쓴다. 출력은 정보 비트 8192와 (iteration 수, 성공 flag).
- iteration 상한: register 설정(1..63), 기본값은 N2b에서.

### 3.2 형식 후보

| 항목 | 후보 | 비고 |
|---|---|---|
| 채널 LLR 폭 w_ch | 4, 5, 6 bit, 대칭 포화 ±(2^(w−1) − 1) | 문헌 NAND 6 bit [R4][R5] |
| 메시지 Q, R 폭 w_m | w_ch (부호 + 크기 w_m − 1) | |
| APP 폭 w_a | w_m + 1, w_m + 2 | FPGA layered OMS (6,8) 기준 [R39] |
| CN 메시지 저장 | (a) edge별 R(w_m bit) (b) 압축: min1, min2(각 w_m − 1), idx(6 bit, dc ≤ 35), edge별 sign | 4.3절 메모리 |
| 보정 | NMS α ∈ {0.75, 0.8125, 0.875}(shift-add, 내림), OMS β ∈ {0, 1, 2} LSB | NAND 문헌 α = 0.75 [R5] |
| 포화 | Q는 w_m으로, APP는 w_a로 대칭 포화. 중간 합(APP − R, Q + R)은 w_a + 1 bit로 계산 후 포화 | −2^(w−1)은 쓰지 않음(부호-크기 대칭) |
| layer 순서 | 0..7 고정 | 열 순서는 HW 자유 |
| iteration 상한 | 10, 15, 20, 30 | 문헌 NAND 10 [R5] |
| 조기 종료 | ET-A, ET-B | 평균 iteration과 미검출 오류 |

### 3.3 N2b 실험 표
기준점: float SPA(flooding, 상한 50)의 FER이 1e−2, 1e−3, 1e−4가 되는 raw BER 세 점(모델 B, LSB/MSB page)과 hard/+2/+6 감지.

| 실험 | 변수 | 고정 | 지표 |
|---|---|---|---|
| E1 양자화 | (w_ch, w_m, w_a) = (4,4,6), (5,5,7), (6,6,8), (6,6,7) | NMS 0.75, 상한 20, ET-A | FER 손실(dB 대신 같은 FER에서의 raw BER 비), APP/R 메모리 bit [계산] |
| E2 보정 | NMS α 3개, OMS β 3개 | E1 선택 형식 | FER, 평균 iteration |
| E3 감지 레벨 | hard, +2, +4, +6 x δ 3개 | E1/E2 선택 | FER, 감지 시간 [R7] 포함 read 지연 |
| E4 LUT 불일치 | LUT 공칭 조건 3개 x 채널 조건 | | FER |
| E5 iteration/ET | 상한 10/15/20/30, ET-A/B | | FER, 평균·최대 iteration, 미검출 오류 수 |
| E6 스케줄 | layered 대 flooding(float, 고정소수점) | | 평균 iteration(수렴 속도 [R38] 서술 확인) |
| E7 hard decoder | ±A min-sum(A 3개) 대 GDBF | hard 감지 | FER |
| E8 BCH 대 LDPC | BCH t = 73, LDPC hard, LDPC soft | 같은 raw BER 축 | FER, 지연 모델 |
- 결정 기준(권고): 6 bit 대비 FER 손실이 같은 FER에서 raw BER 비 5% 이내인 가장 작은 형식을 IP 기본값으로 [추정: 기준값 자체가 제안].

## 4. IP 분할, 인터페이스, 메모리와 자원

### 4.1 IP 목록과 RTL/HLS 분담

| IP | 기능 | 방식 | 순서 |
|---|---|---|---|
| IP1 `ldpc_dec` | layered NMS/OMS, Z = 128 lane, 메모리, shifter, 조기 종료, 통계 | 스케줄러·주소/ROM·shifter·메모리·ET·CSR·AXI = RTL. lane datapath(CNU/VNU)는 RTL 먼저, Catapult 버전을 같은 포트로 만들어 QoR 비교(선택) | 1 |
| IP2 `llr_gen` | 감지 구간 index → LLR LUT(page, read 설정별 표는 CSR로 적재) | RTL, IP1 입력단에 붙임 | 2 |
| IP3 `ldpc_enc` | dual-diagonal encoder | RTL | 3 |
| IP5 `chan_emu` (선택) | xoshiro128** lane G개 + 이산 역CDF(`channel.md` 7절) | RTL | 4 (D8) |
| top | AXI4-Lite CSR, HP AXI master(read/write engine), IP 간 stream, FER loop 모드 | RTL | 함께 |
| BCH | - | C만 (D9) | - |

### 4.2 데이터 경로: HP master 대 AXI-Stream + DMA

| 기준 | 자체 HP AXI master (llm-pim-soc 방식) | AXI DMA + AXI-Stream |
|---|---|---|
| 서버 RTL 검증 | TB의 AXI slave memory model로 IP 전체를 Questa에서 검증 | DMA IP 시뮬레이션 모델은 Vivado가 생성해야 해 이 서버에서 검증 불가, 보드에서 처음 만남 |
| ARM 호출 | descriptor(주소, codeword 수, 형식) 쓰고 start 1회 | DMA 채널 2개(MM2S, S2MM) 설정 + IP CSR |
| 재사용 | llm-pim-soc의 `axi_rd_eng`/`axi_wr_eng` 설계(같은 연구 공간의 자체 RTL, 그 프로젝트 G4 통과본)를 옮겨 씀 | block design만 |
| 일괄 처리 | codeword N개를 연속 주소로 한 번에 | 가능(scatter-gather) |
| FER loop 모드 | DDR 경로가 필요 없음(통계만 CSR) | 동일 |
- **권고: 자체 HP master** (D5). 근거는 서버에서 전 경로 검증 가능, 호출 비용, 앞 프로젝트 자산 재사용. HP 포트는 AXI3(LEN ≤ 15) 64 bit이고 그 처리 방식은 llm-pim-soc `arch.md` 2.1절을 따른다.

### 4.3 IP1 인터페이스 초안
- CSR(AXI4-Lite, 32 bit): `CTRL`(start, soft_reset, mode: 0 = DDR batch, 1 = FER loop), `STATUS`(busy, done, err), `IN_ADDR`, `OUT_ADDR`, `NCW`(codeword 수), `ITER_MAX`, `FLAGS`(ET 종류, 입력 형식: LLR int8 / 구간 index, NMS/OMS 선택과 계수 index), `STAT_ITER_SUM`, `STAT_FAIL`, `STAT_ITER_MAX_SEEN`, `CYCLES`(64 bit), 버전 ID.
- DDR 입력(형식 0): codeword당 LLR 9216 B(int8, w_ch bit 부호 확장), 연속 배치. 형식 1(`llr_gen` 경유): 구간 index 4 bit x 16개/beat → 576 beat/codeword [계산].
- DDR 출력: codeword당 정보 비트 1024 B + 상태 8 B(iteration 수, 성공 flag, syndrome 결과).
- golden 비교 단위: codeword별 (출력 비트, iteration 수, 성공 flag). 내부 dump(layer별 APP)는 RTL TB에서만.

### 4.4 메모리 구조 (Z = 128 완전 병렬, BRAM36 = 512 x 72 SDP [R52])
[계산, `s1calc.txt` 3절], (w_m, w_a) = (6, 8) 기준. 괄호는 (5, 7), (4, 6).

| 메모리 | bit | 구성 | BRAM36 |
|---|---|---|---|
| APP (ping-pong 2 codeword) | 73,728/codeword | 1024 bit x 144 | 15 (13, 11) |
| R edge별 | 209,664 | 768 bit x 273 | 11 (9, 8) |
| R 압축(대안) | 51,328 | min1/min2/idx 16 bit x 1024 check(FF 또는 LUTRAM) + sign 128 bit x 273(BRAM36 2) | 2 + FF 16,384 |
| Q 버퍼 | 40,320/layer | 1152 bit x 35(겹침 시 x2 = 70 deep) | 16 (BRAM일 때) |
| shift/순서 ROM | 273 x (열 7 + shift 7 + 위치 6 x 2) | LUT ROM | 0 |
- BRAM 합(edge별 R, Q를 BRAM에): 15 + 11 + 16 = **42 / 140** [계산]. Q를 LUTRAM으로 두면 26.
- 권고: v1은 edge별 R(BRAM), Q는 BRAM(D2). BRAM이 넉넉하고 control이 단순하다. 압축 R은 LUT/FF와 BRAM의 교환을 보는 v2 실험.

### 4.5 shifter와 lane datapath
- 순환 shifter: Z = 128, 7단, w_a = 8이면 2:1 mux 7,168개, LUT6이 4:1 mux 하나를 맡는다고 보면 약 4,096 LUT/개 [추정]. 읽기(APP → lane)와 쓰기(lane → APP, 역방향 shift) 두 개면 약 8.2k LUT [추정]. 메모리에 "마지막 shift 상태"로 저장하고 상대 shift 하나만 쓰는 방식은 LUT를 절반으로 줄이지만 dump와 golden 비교가 어려워 v1에서는 쓰지 않는다(권고).
- lane 하나(Q 감산과 포화, min1/min2/idx 비교, sign, phase 2 선택·보정·APP 가산): 80~120 LUT [추정] → 128 lane 10~15k LUT [추정].
- IP1 합계 [추정]: LUT 20k~28k(shifter 8.2k + lane 10~15k + control/ROM/CSR/AXI 2~5k), BRAM36 42, DSP 0. 서베이 6.3의 추정(25k~35k)과 같은 범위. 합성 전이라 수치는 근거가 약하다.
- 부분 병렬 P = 64(lane 절반): lane LUT 절반, 그러나 Z = 128 circulant를 두 번에 나눠 shift하는 구조가 따로 필요하다(비용 미계산). 처리량은 iteration 수가 많을 때 절반(4.6절).

### 4.6 cycle과 throughput [계산, `s1calc.txt` 1~2절]
- iteration당 cycle: 하한 273(= block edge 수). layer 겹침 + `code.md` 6절의 읽기/쓰기 순서로 CNU 파이프라인 L = 2~8에서 stall 0 → **273 cycle/iteration**. 자연 순서면 L = 6에서 327, 겹치지 않으면 594.
- codeword당: `iter x 273 + (L + 35)`, L = 6. 입력은 ping-pong이라 다음 codeword 적재와 겹친다. HP 포트 하나(64 bit, 100 MHz) 입력 한계: LLR int8 1152 beat/codeword → 86,806 codeword/s = **711 Mbps** 정보. 구간 index 입력(576 beat)이면 한계가 두 배.

| iteration | cycle/codeword | 정보 throughput Mbps (P = 128) | P = 64 | P = 32 |
|---|---|---|---|---|
| 1 | 314 | 711 (입력 한계) | 711 | 711 |
| 2 | 587 | 711 (입력 한계) | 711 | 368 |
| 5 | 1,406 | 583 | 296 | 149 |
| 10 | 2,771 | 296 | 149 | 75 |
| 20 | 5,501 | 149 | 75 | 37 |
- 조기 종료가 있으면 낮은 raw BER에서 평균 iteration이 작아 입력 대역폭이 한계가 된다 [추정]. 평균 iteration은 N2에서 C로 측정한다.
- ARM 소프트웨어 decoder [추정]: edge 34,944개, edge당 iteration마다 10~20 cycle이면 10 iteration에 3.5M~7M cycle → 667 MHz에서 5~10 ms/codeword(0.8~1.6 Mbps). 그러면 IP1 단독 가속비는 10 iteration에서 약 180~360배 [추정]. N3의 ARM 프로파일로 바꾼다.

### 4.7 IP2, IP3, IP5 [추정]
- IP2 `llr_gen`: 구간 index(≤ 5 bit) → w_ch bit LUT, page/read 설정별 표 ≤ 64 항목. lane 16개/cycle(입력 beat 하나)이면 LUT 1k 미만.
- IP3 `ldpc_enc`: 정보 블록 64개를 받아 블록당 행 4개의 λ에 회전 XOR(128 bit 회전기 4개, 약 2k LUT [추정]), 64 cycle + parity chain 8 cycle + 입출력. DDR 입력 1024 B = 128 beat가 지배.
- IP5 `chan_emu`: lane당 xoshiro128**(128 FF + 약 150 LUT [추정]), 6단 이진 탐색(표 16,128 bit, lane 쌍마다 BRAM36 1개 또는 LUTRAM) → G = 8 lane 약 3k~5k LUT, BRAM36 4 [추정].
- 시스템 합 [추정]: LUT 27k~40k(53,200의 51~75%), BRAM36 47~50. LUT가 빠듯해지면 IP1의 P = 64가 첫 대안.

## 5. 보드 FER 깊이와 PL 채널 에뮬레이터

### 5.1 넣었을 때 [계산, `s1calc.txt` 5절]
FER loop 모드: data PRNG → `ldpc_enc` → `chan_emu` → `llr_gen` → `ldpc_dec` → 비교와 계수기. DDR 경로를 쓰지 않는다.

| 평균 iteration | 에뮬레이터 lane G | codeword/s | codeword/시간 | 오류 frame 100개 기준 FER 하한 (1 h / 8 h) |
|---|---|---|---|---|
| 2 | 8 | 86,806 | 3.1e8 | 3.2e−7 / 4.0e−8 |
| 5 | 8 | 71,124 | 2.6e8 | 3.9e−7 / 4.9e−8 |
| 10 | 4~16 | 36,088 | 1.3e8 | 7.7e−7 / 9.6e−8 |
- G = 8이면 에뮬레이터(1152 cycle/codeword)가 iteration 4 이하에서 병목, 그 이상에서는 decoder가 병목.
- 검증: FER loop의 bit-exact 확인은 C replay(같은 seed)로 한다. 1e8 codeword를 C로 다시 도는 것은 서버에서 비현실적이라(C decoder가 codeword당 ms급이면 1e8개는 수십 시간 [추정]), 앞쪽 1e5 codeword의 codeword별 결과 checksum과 실패 index 목록을 비교하고, 긴 실행은 계수만 쓴다.

### 5.2 넣지 않았을 때 [추정]
- ARM이 채널 샘플을 만들어 DDR로 넘김: 셀 샘플당 40~300 cycle(이산 역CDF 40~80, Box-Muller double 약 300 [추정])이면 codeword당 0.55~4.15 ms → 약 240~1,800 codeword/s, 시간당 8.7e5~6.5e6 [계산: 가정 cycle에서]. 오류 100개 기준 FER 하한 1e−4~1e−5/시간 수준.
- 즉 에뮬레이터가 보드에서 시간당 볼 수 있는 codeword 수를 약 20~360배(5.1절 1.3e8~3.1e8 대 6.5e6~8.7e5) 늘린다 [추정].

### 5.3 권고 (D8)
**넣는다. 단 IP1 단독 G6(DDR batch 모드, ARM 생성 벡터) 다음 단계로.** 비용(LUT 3~5k, BRAM 4 [추정])이 작고, 서버 FER(1e−5 부근이 현실적 [survey 6.6 추정])보다 2자릿수 깊은 곡선을 보드에서 얻는 것이 이 프로젝트의 차별점이 된다. 에뮬레이터는 시스템 workload(실제 SSD read 경로)가 아니라 측정 도구이므로 Amdahl 분석(8절)에서 따로 분리한다.

## 6. Test data 계획 (G2)

### 6.1 공인/외부
| 대상 | 방법 | 저장소 |
|---|---|---|
| CCSDS C2 (8176, 7156) H와 generator | [R25] PDF를 받는 스크립트(`data/ext/get.sh`) + sha256, `pdftotext`(서버에 있음)로 Table 2-1(circulant 위치)과 Annex A(generator) 추출하는 파서. 검사: H 1022 x 8176, rank 1020, 열 weight 4, 행 weight 32 [R25]; generator로 만든 codeword가 H를 만족 | 스크립트와 checksum만(재배포 조건 미확인) |
| IEEE 802.3an (2048, 1723) | AFF3CT `configuration_files`의 alist 2개 [R23] 다운로드 + sha256. 독립 재생성: Djurdjevic RS 구성 [R20]으로 만들어 alist와 비교. 검사: (6,32)-regular, 384 x 2048, rank 325 | 동일 |
| 참조 구현 | AFF3CT(MIT [R36]) 소스를 받아 서버에서 빌드(`make -j1`). 같은 alist와 같은 LLR 입력 파일에서 float BP/min-sum(flooding, layered) frame별 복호 결과와 FER을 golden `dec_ref`와 비교. 고정소수점 세부는 미확인이라 bit-exact 비교는 float 경로만. BCH도 같은 방식 [R37] (shortened 지원 여부 미확인) | 빌드 산출물 커밋 안 함 |
| 채널 parameter | [R3][R4][R5]의 상수와 표, 출처 표 번호(`channel.md`) | `data/README.md`(H5) |
| 공개 곡선(정성) | C2 BER/BLER 곡선(5/10/15 iteration) [R27], [R7] Fig. 3/10 | 인용만 |
- 공개 raw NAND 측정 데이터셋은 없다(서베이 1.5). 대체 근거: 문헌 fit 표 + 독립 구현(AFF3CT) 교차 검증, 해석식 raw BER과 Monte Carlo의 일치. `data/README.md`와 로그에 적는다.

### 6.2 방향성
- code/encoder: 전부 0 메시지, 단일 1 메시지(64 블록 x {0, 63, 127} 위치), 전부 1 메시지.
- decoder: 오류 없음(iteration 1에서 ET), LLR 전부 0(erasure, 상한까지 돌고 실패, 출력 결정적), 최대 포화 LLR, 단일 오류(각 block 열의 index 0과 Z−1), 같은 check의 두 오류, degree-2 parity node 오류, 한 iteration에서 정확히 상한에 걸리는 패턴, hard 입력 ±A, 포화 경계(Q, APP가 정확히 포화하는 값), t8 code에서 단일·이중 오류 전수(96 + 4,560 패턴).
- 채널/LLR: uniform u가 표 경계값 T_s[j]와 같을 때(G4의 ≥ 규칙), 확률 0 구간, 감지 격자 끝.
- BCH: 정확히 t = 73개, t + 1개 오류, 단축 영역 경계.

### 6.3 random
- seed와 개수를 설정 파일과 로그에 기록. 메시지 random, 조건 격자(모델 B: P/E 500/1000/3000/5000 x retention 15/30/90일(값 확보 시) x α, 모델 A: N 0/1K/3K/5K/10K x t 1 h/1일/1개월/1년)별.
- RTL TB 벡터: 조건마다 codeword 수백~수천 개(시뮬레이션 시간에 맞춤), 실패 frame을 일부러 포함(상한에서 실패하는 비율이 0이 아니게 raw BER 선택).

## 7. 측정 계획 (시스템 프로젝트 방식 1~5단계)

| 단계 | 내용 | 산출 |
|---|---|---|
| 1 | C 전체(PC, ARM 같은 소스). PC에서 FER 곡선, N2b 실험 | FER 곡선, 형식 결정 |
| 2 | ARM bare-metal 프로파일(PMU cycle counter): 두 workload를 **분리**. (A) read 경로: 감지 결과 → LLR → decode(→ retry/soft). (B) FER 시뮬레이션: 채널 샘플 + A | kernel별 시간 비중 표(A, B 각각) |
| 3 | IP 구현(G3/G4): IP1 → IP2 → IP3 → IP5, 모듈마다 golden 대비 mismatch 0 | 회귀 로그 |
| 4 | 하나씩 PL 오프로드: IP1 단독(DDR batch) → +IP2(구간 index 입력) → +IP3 → FER loop(+IP5). 각 단계에서 (a) 순수 연산 cycle(IP `CYCLES`) (b) 데이터 이동(cache flush/invalidate, DDR 전송) (c) 호출 오버헤드(CSR 쓰기, polling)를 분리 측정 | 모듈별 가속비, end-to-end 시간 |
| 5 | Amdahl 추정(2단계 비중 + 4단계 모듈 가속비) 대 end-to-end 실측. 차이를 (b)(c)로 설명 | 추정/실측 구분 표, read 지연 모델(2.2절)에 측정 τ_dec 대입 |
- workload A가 SSD 컨트롤러 관점의 시스템이고, B는 측정 도구의 가속이다. 결론은 A 기준으로 쓰고 B는 FER 깊이 결과로만 쓴다.
- 보드 통과 기준(G6): DDR batch 모드에서 PS가 넣은 벡터의 출력이 golden과 codeword별 일치(mismatch 0), FER loop 모드는 C replay 구간 일치.

## 8. 위험

| 위험 | 영향 | 대응 |
|---|---|---|
| girth 6, error floor 미분석(`code.md` 7절) | FER 곡선이 낮은 BER에서 꺾일 수 있음 | 보드 FER loop로 1e−7급까지 관찰, 결과를 그대로 기록. 필요하면 C2 비교 |
| LUT 예산(시스템 51~75% [추정]) | 100 MHz 타이밍과 배치 곤란 | P = 64, 압축 R(BRAM 대신 FF), shifter 하나 방식 |
| shifter 128 x 8 bit가 임계 경로 | 100 MHz 미달 | shifter 중간 파이프라인 단(L 증가, stall은 L ≤ 8까지 0 [계산]) |
| [R5] 격자 값 미확보 | 모델 B 격자 knob 축소 | α knob, 모델 A로 보완 |
| CCSDS PDF 파싱 실패 | C2 외부 기준 지연 | 802.3an과 AFF3CT로 먼저 진행, C2는 수동 확인 |
| AFF3CT 빌드가 무거움 | 서버 부하 | `-j1`, 다른 무거운 작업과 겹치지 않게 |
| FER loop의 bit-exact 확인 범위 | 긴 실행은 계수만 | 1e5 구간 replay로 한정한다고 명시 |
| HP 대역폭 실효값 미측정 | 낮은 iteration에서 throughput 추정이 틀림 | llm-pim-soc의 대역폭 측정 결과를 재사용 |

## 9. 열린 결정 (오케스트레이터 확정 대상)

| ID | 결정 | 선택지 | 장단점 | 권고 |
|---|---|---|---|---|
| C1 | 주 code | (a) `qc_m128.txt`(seed 20) (b) 추가 탐색 후 교체 | (a) 4-cycle 0, rank full, encoding 검증 끝. girth 6 (b) 탐색 비용, girth 8 가능성 미확인 | (a). N2 FER에서 문제가 보이면 (b) |
| C2 | parity 구조 | (a) dual diagonal (b) 전 열 weight ≥ 3 + RU encoder (c) CCSDS식 generator | `code.md` 7.1 | (a), (b)(c)는 N2 이후 비교 후보 |
| C3 | girth 목표 | (a) girth 6 수용, 6-cycle 최소화로 끝 (b) girth 8 탐색을 N2에 추가 | (b)는 존재 여부부터 미확인 | (a) |
| C4 | 축소판 | (a) s32 + t8 (b) Z = 16 재시도(backtracking) | Z = 16은 greedy 실패 | (a) |
| C5 | shift 규약과 표 형식 | `code.md` 2.1~2.2 | 외부 표준과 이동 방향이 다를 수 있음 | 그대로 확정 |
| H1 | 기본 채널 모델 | (a) TLC fit(B) (b) MLC 해석(A) | (a) 실측 기반, 격자 값 일부 미확보 (b) 연속 knob, 식 세부 미확인 | (a) 기본, (b) 병행(brief 잠정 결정과 같음) |
| H2 | 난수/감지 샘플러 | G1~G4 + uniform 후보 | `channel.md` 7절 | G4 + xoshiro128** |
| H3 | 감지 격자 | 경계당 15점 균일, page당 경계 ≤ 63 | retry offset과 soft 위치가 격자로 제한 | 15점 |
| H4 | LLR scale, LUT 공칭 조건 | N2b | | N2b E3/E4로 결정 |
| H5 | 문헌 parameter 저장 | (a) `data/`에 값과 출처 표 번호를 적은 parameter 파일 (b) 저장하지 않고 수동 입력 안내만 | (a) 재현 쉬움. 수십 개 숫자 인용 (b) 외부 데이터 비커밋 원칙에 가장 엄격 | (a). 행렬/문서 파일이 아니라 수치 인용이므로. 오케스트레이터 판단 필요 |
| D1 | decoder 병렬도 | (a) Z = 128 (b) P = 64 | (a) 273 cycle/iteration, LUT 큼 (b) LUT 절반, shift 구조 추가 | (a), LUT 초과 시 (b) |
| D2 | CN 메시지 저장 | (a) edge별 BRAM (b) 압축 | 4.4절 | (a) v1, (b) v2 실험 |
| D3 | 열 순서 | (a) 읽기/쓰기 분리 순서 (b) 자연 순서 | (a) stall 0, ROM 약간 (b) L = 6에서 +54 cycle/iteration | (a) |
| D4 | lane datapath | (a) RTL (b) Catapult (c) 둘 다 | (c)가 연구 가치, 범위 증가 | (a) 먼저, IP1 G4 후 (c) |
| D5 | 데이터 경로 | (a) 자체 HP master (b) AXI DMA | 4.2절 | (a) |
| D6 | DDR 입력 형식 | (a) LLR int8 (b) 구간 index + IP2 | (b) 입력 beat 절반, IP2 필요 | v1 (a), IP2 단계에서 (b) 추가 |
| D7 | hard decoder | (a) 같은 decoder에 ±A (b) 별도 bit flipping IP | (a) HW 추가 없음 (b) 면적당 throughput 이점 [R18] | (a), GDBF는 C 비교만 |
| D8 | PL 채널 에뮬레이터 | 넣음/안 넣음 | 5절 | 넣음, IP1 G6 이후 |
| D9 | BCH | (a) C만, GF(2^14) t = 73 (b) GF(2^15) t = 68 (c) IP화 | 2.1절 | (a) |
| D10 | encoder IP | 넣음/안 넣음 | FER loop에 필요, 작음 | 넣음, IP2 다음 |
| D11 | 외부 데이터 확보 | 6.1절 스크립트 + AFF3CT 서버 빌드 | 빌드는 한 번, `-j1` | 그대로 |
| D12 | 조기 종료 | ET-A, ET-B | 3.1절 | N2b E5로 결정, RTL은 둘 다 parameter |

## 10. 미확인 항목 요약
- `channel.md` 9절 전부(MLC 매핑 비트 순서, [R3] 합성 순서와 retention 부호, CCI 이웃 범위, [R5] 격자 값, 문헌 read reference/retry offset).
- Z = 128에서 girth 8 구성의 존재, 이 code의 최소 거리와 trapping set.
- 5G NR core parity 세부 구조(`code.md` 7.1).
- AFF3CT 고정소수점 비트폭 지정 방식과 shortened BCH 지원, CCSDS/IEEE/AFF3CT 설정 파일의 재배포 조건.
- XC7Z020의 FF 수(이 문서에서 쓰지 않음), LUTRAM 구성별 LUT 비용, shifter 실제 LUT 수, 100 MHz 달성 여부(합성 전).
- HP 포트 실효 대역폭(Zybo 미측정).

## 11. 결정 (오케스트레이터, 2026-11-25)
9절의 열린 결정 23개를 권고대로 확정한다. 아래는 조건을 붙인 것이다.
- C3(girth 6 수용): 조건부. N2의 FER 곡선에서 error floor가 FER 1e-5보다 위에서 보이면 code 구성(shift 탐색 강화, parity부 구조 변경: C2의 대안)을 다시 연다. weight-2 열 896개가 원인 후보이므로 N2에서 실패 frame의 오류 위치 통계를 남긴다.
- D1(Z = 128 완전 병렬): LUT [추정] 20k~28k는 합성 전 값이다. N4의 첫 모듈(shifter, lane datapath)에서 구조 기준 계산을 다시 하고, 사용자 Vivado 리포트 전에는 확정 수치로 쓰지 않는다. 넘치면 lane 수를 parameter로 줄일 수 있게 설계한다(Z의 약수).
- H5(문헌 parameter 값): 논문에 인쇄된 수치는 출처와 함께 `data/`에 텍스트로 둔다. 논문의 그림, 표 이미지, 원문은 넣지 않는다. 외부 행렬 파일과 참조 구현 소스는 넣지 않는다(받는 스크립트와 checksum).
- D11(오픈소스 참조 구현 빌드): 서버에서 `-j1`, 저장소 밖 또는 ignore된 디렉토리에 둔다. 빌드가 안 되면 대체 근거(독립 구현 두 개의 교차 검증)를 `data/README.md`에 적는다.
- D8(PL 채널 에뮬레이터): 포함하되 IP1이 G4를 통과한 뒤 착수. C 채널 모델은 처음부터 PL과 같은 정수 표(H2)를 써서 나중에 bit-exact로 맞춘다.
