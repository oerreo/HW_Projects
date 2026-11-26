# nand-ecc-subsystem 사전 조사 (G0 준비)

작성일: 2026-11-24. 상태: 사전 조사(구현 없음). 원 brief는 `todo/nand-ecc-subsystem.md`.

표기 규칙
- 각 사실 뒤 `[Rn]`은 7절 참고 문헌 번호. 본문을 직접 열어 확인한 것은 그대로 쓰고, 검색 요약이나 초록에서만 확인한 것은 "(초록 기준)" 또는 "(검색 요약 기준)"으로 표시.
- **미확인**: 이번 조사에서 출처를 찾지 못했거나 원문을 열지 못한 것.
- **[추정]**: 이 문서 작성자의 계산이나 판단. 문헌 수치가 아니다.
- 내려받은 문서와 코드는 저장소에 넣지 않았다(링크와 요약만).

---

## 1. NAND 오류 모델

### 1.1 Threshold voltage(Vth) 분포 모델 계보
| 모델 | 내용 | 출처 |
|---|---|---|
| Gaussian + additive white noise | MLC 실측. 95% 이상 정확도로 Gaussian 근사, P/E cycle이 늘면 분포가 오른쪽으로 이동하고 넓어짐(정성적, 초록에 수치 없음) | Cai et al., DATE 2013 [R1] (초록 기준) |
| Student's t + power law | 1X-nm MLC 실측. Gaussian은 tail을 과소평가. 수정 Student's t로 정적 분포, power law로 wear에 따른 이동을 모델링. 평균 오차 0.68%, 미래 이동 예측 오차 2.72% | Luo et al., JSAC 2016 [R2] (초록 기준) |
| 해석적 모델(지우기 Gaussian + ISPP 균일 + RTN + CCI + retention) | 아래 1.2의 parameter 표. 시뮬레이션 재현용으로 가장 완전한 공개 parameter 세트 | Pan, Dong, Zhang, FAST 2011 [R3]; Dong, Xie, Zhang, TCAS-I 2011 [R4] |
| 3D TLC 실측 Gaussian fit 표 | 64-layer 3D FG TLC 64개 chip 실측을 Gaussian으로 fit한 state별 평균/표준편차 표(P/E 500~5000, retention 15/30/90일). 단, 값은 정규화되고 "어느 정도 확대"했으며 P0 평균은 가정값이라고 논문이 명시 | Cui et al., ACM TODAES 2021 [R5] 부록 Table A1~A3 |
| 3D NAND 특유 오류 | layer 간 process variation, early retention loss(프로그램 후 약 3시간 안에 retention error율이 10배), retention interference | Luo et al., SIGMETRICS 2018 [R6] (초록/검색 요약 기준) |

### 1.2 재현 가능한 parameter 표 (원문 확인)

**(a) MLC 해석 모델: Pan/Dong/Zhang, FAST 2011 [R3] Example 2.1** (2 bit/cell, 정규화 전압)
- 지우기 상태: Gaussian, σe = 0.35, μe = 1.4.
- 프로그램 상태: ISPP 이상 분포는 `[Vp, Vp+ΔVpp]` 균일, ΔVpp = 0.3, verify 전압 Vp = 2.85, 3.55, 4.25.
- RTN: 대칭 지수분포 `p_r(x) = 1/(2λr) · exp(-|x|/λr)`, `λr = Kλ · N^0.5`, Kλ = 4e-4 (N = P/E cycle 수).
- Cell-to-cell interference(CCI): `F = Σ ΔVt(k) · γ(k)`. 결합비 γy(수직), γxy(대각)는 bounded Gaussian, 평균 0.08과 0.0048, wc = 0.1μc, σc = 0.4μc. all-bit-line 구조 가정.
- Retention(interface trap recovery + electron detrapping): Gaussian N(μd, σd²),
  `μd = Ks(x − x0) · Kd · N^0.5 · ln(1 + t/t0)`, `σd² = Ks(x − x0) · Km · N^0.6 · ln(1 + t/t0)`,
  Ks = 0.333, x0 = 1.4, Kd = 4e-4, Km = 2e-6, t0 = 1 h (x는 초기 Vth, t는 retention 시간). 상수는 문헌 [30],[31]의 측정에 fit했다고 명시.
- 같은 논문의 ECC: 512 B sector에 binary BCH(4798, 4096, 54), 10K P/E 목표.

**(b) MLC CCI 모델과 LLR 계산: Dong/Xie/Zhang, TCAS-I 2011 [R4] Example 2.1, 3.1**
- σe = 0.35, μe = 1.2, ΔVpp = 0.3, Vp = 2.55, 3.0, 3.45, CCI 강도 인자 s (γy 평균 0.08s, γxy 평균 0.006s), Gray 매핑 11/10/00/01.
- LLR: 감지 구간 (Rl, Rr]에 대해 상태별 분포를 적분한 식(20). 기준 전압 Ks개면 LLR LUT는 Nb(Ks+1) 항목. l-bit 정밀도 감지는 hard 대비 on-chip 감지 지연이 약 (2^l − 1)/3배, page buffer가 l/2배.
- 사용 code: rate 19/20 (34520, 32794) QC-LDPC, column weight 4, girth 6, min-sum, LLR 6 bit. 비교 BCH: (32767, 31133, 109).

**(c) 3D TLC fit 표: Cui et al., TODAES 2021 [R5]**
- 상태 P0..P7, 정규화 평균 예(15일, P/E 500): −85, 64.5, 121.9, 181.6, 236.4, 289.5, 341.2, 401.5. 표준편차: 18.2, 9.1, 8.9, 9.1, 7.5, 7.8, 7.6, 9.0. P/E 5000에서 표준편차는 19.3 ~ 9.8 범위로 증가. 전체 표는 부록 A1~A3.
- Gray 매핑(Table 1): MSB 1,0,0,1,1,0,0,1 / CSB 1,1,0,0,0,0,1,1 / LSB 1,1,1,1,0,0,0,0 (P0..P7). 이 표에서 page별 hard read 횟수는 LSB 1회, CSB 2회, MSB 4회가 된다[추정: 표에서 도출].
- 시뮬레이션 설정: 2 KB QC-LDPC, rate 0.9(저자 자체 구성, 행렬 비공개), 초기 LLR 6 bit 부호 양자화([−31, 31]), layered min-sum, 보정 계수 0.75, 최대 10 iteration. soft 기준 전압은 hard 기준 전압 주변 2~4개에서 오류율이 포화된다고 보고.
- 측정 환경: 85°C 13시간 bake = 25°C 1개월(Arrhenius) 가정.

### 1.3 P/E, retention, read disturb와 raw BER(RBER)
- P/E: 위 모델 모두 N의 power law로 분포 폭이 증가 [R2][R3]. 25nm MLC 4개 chip, 10K P/E + 1개월 retention 등가 bake 후 page RBER 분포가 대략 0.004~0.013에 걸침(Fig. 9 히스토그램) [R7].
- Retention: 오류의 주된 원인이며 최적 read reference가 retention 나이에 따라 달라짐. ROR(블록별 최적 기준 전압 학습)로 수명 64% 증가, ECC 지연 10.1% 감소. RFR로 RBER 50% 감소 [R8] (초록 기준).
- Read disturb: 2Y-nm MLC 실측. wear와 pass-through 전압이 클수록 증가. RDR로 RBER 36% 감소 [R9] (초록/검색 요약 기준).
- 정량적 RBER 대 (P/E, retention) 곡선의 원 데이터는 공개되어 있지 않다. 위 논문들은 그림과 fit 모델만 제공.

### 1.4 Soft read (여러 read reference로 LLR 생성)
- 감지는 word-line 전압을 단계적으로 올리며 bit-line charge/discharge를 반복하므로 지연이 감지 레벨 수에 비례 [R7].
- 25nm MLC 측정 기반 수치: hard read 55 µs(upper)/41 µs(lower), 추가 감지 레벨 1개당 약 14 µs, 7레벨 soft 감지 약 125 µs, ONFI 2.1 200 MB/s로 7레벨 결과 4 KB 전송 약 80 µs, LDPC 복호 8 µs(4 Gbps 가정) [R7].
- Samsung 21nm 2 bit/cell chip은 인접 상태 사이에 7개 양자화 레벨(hard 1 + soft 6) 지원 [R7](그 논문의 인용 [14] 기준).
- 기준 전압 배치: 비균일 감지(경계 근처에 집중) [R4], 상호정보량 최대화(MMI) 양자화 [R10](초록 기준), 분포 인지 LLR 최적화 [R5].
- 흐름: hard 감지 + hard 복호 → 실패 시 soft 감지 + soft 복호(two-step) [R7]. 개선안: look-ahead soft 감지, 레벨을 1개씩 늘리는 progressive 감지, chip 간 interleaving [R7]. 3D NAND 160개 chip 실측 기반 read-retry 최적화(PR²: CACHE READ로 retry 파이프라인, AR²: ECC 여유로 감지 시간 단축), 응답시간 평균 17%, 최대 31.5% 개선 [R11] (초록 기준).
- Gaussian 기반 LLR은 실제 분포가 Gaussian이 아니므로 근사치라는 지적 [R12] (검색 요약 기준).

### 1.5 공개 실측 데이터셋
- 공개된 raw NAND Vth/RBER 측정 데이터셋은 찾지 못했다(**미확인**, GitHub/데이터 저장소 검색 결과 없음). vendor 전압은 비공개라 논문들도 정규화 단위를 쓴다 [R6](검색 요약 기준).
- 재현 가능한 대안은 위 1.2의 parameter 표 세 가지다. (a)(b)는 해석 모델의 상수, (c)는 실측 fit 결과(정규화·확대됨)다.

---

## 2. SSD용 ECC

### 2.1 BCH에서 LDPC로
- BCH는 hard-decision만 쓴다. LDPC는 hard 감지에서도 BCH보다 약간 높은 RBER을 견디고, 6개 추가 감지 레벨 soft 복호에서는 목표 실패율 1e-15 기준 약 3배 높은 RBER을 견딘다(4 KB 사용자 데이터 + 512 B 중복, rate 8/9) [R7].
- TCAS-I 2011은 rate 19/20 QC-LDPC 대 같은 rate BCH 비교에서 LDPC의 이득을 보였다 [R4].

### 2.2 대표 code 길이와 rate (문헌)
| 출처 | 데이터 크기 | Code | Rate |
|---|---|---|---|
| [R7] FAST 2013 | 4 KB | LDPC(구조 미공개), 4 KB + 512 B | 8/9 ≈ 0.889 |
| [R4] TCAS-I 2011 | 4 KB | QC-LDPC (34520, 32794), col weight 4 | 19/20 = 0.95 |
| [R5] TODAES 2021 | 2 KB | QC-LDPC(자체 구성) | 0.9 |
| [R3] FAST 2011 | 512 B | BCH (4798, 4096, t=54) | 0.854 |
| [R4] | 4 KB | BCH (32767, 31133, t=109) | 0.95 |
| [R13] 8 KB page 대상 학위논문 | 8 KB | 대수적 QC-LDPC | 0.96 (검색 요약 기준) |
- 공통점: rate 0.85~0.96, codeword 1~4 KB급, QC 구조. 상용 SSD의 정확한 code 행렬은 공개 문헌에서 찾지 못함(**미확인**).

### 2.3 QC-LDPC 구조
- H를 Z×Z circulant(순환 이동 단위행렬) 블록 배열로 구성. 802.11n은 Z = 27/54/81로 n = 648/1296/1944, rate 1/2, 2/3, 3/4, 5/6의 12개 code [R14]. 5G NR은 BG1(46×68), BG2(42×52), lifting size 2~384의 51개 값 [R15](2차 출처 기준).
- 이 구조 덕분에 partially parallel decoder가 Z개(또는 그 약수) lane과 barrel shifter로 구성된다(4절).

### 2.4 Hard-decision decoder (bit flipping 계열)
- AFF3CT가 구현한 hard 계열: Gallager A/B/E(GALA, GALB, GALE), WBF, MWBF, PPBF [R16].
- GDBF(gradient descent bit flipping): 목적함수의 gradient로 유도, WBF/MWBF보다 성능 우수. local minimum에서 멈추는 문제가 있어 probabilistic/noisy GDBF 후속 연구가 있음 [R17](초록 기준).
- ASIC 비교표 예: (1296, 648) regular QC-LDPC(Z = 54)에서 GDBF/PGDBF 계열은 1 clock/iteration, MS 비교 대상은 6 clock/iteration [R18]. bit flipping 계열이 면적당 throughput에서 크게 유리하다는 근거로 쓸 수 있다.

### 2.5 Soft-decision decoder (min-sum 계열)
- Normalized min-sum(NMS, 정규화 계수 < 1)과 offset min-sum(OMS, 가산 offset). density evolution으로 계수를 최적화하며 BP에 근접. offset BP 기반 복호는 4 bit 정밀도에서도 잘 동작한다는 요약 [R19](초록/검색 요약 기준).
- AFF3CT 옵션: 스케줄 `BP_FLOODING`, `BP_HORIZONTAL_LAYERED`, `BP_VERTICAL_LAYERED`, 갱신 규칙 `SPA`, `LSPA`, `MS`, `NMS`(`--dec-norm`), `OMS`(`--dec-off`), `AMS`, syndrome 기반 조기 종료(`--dec-synd-depth`, `--dec-no-synd`) [R16].

### 2.6 Read retry와 결합한 복호 흐름
문헌의 흐름을 합치면 다음과 같다([R7][R8][R11]).
1. 기본 기준 전압으로 hard read → hard 복호(bit flipping 또는 1-bit 입력 min-sum).
2. 실패 시 read retry: 기준 전압을 조정해 다시 hard read(ROR처럼 retention 나이로 기준 전압 예측 가능).
3. 그래도 실패하면 soft read(기준 전압 주변 추가 감지, 2~6개) → LLR LUT → soft min-sum. progressive하게 레벨을 늘릴 수 있음.
4. 최종 실패 시 복구 기법(RFR, RDR) 또는 상위 RAID.
- 평균 지연 모델: `τ_total = τ_hd-sen + τ_hd-xfer + τ_dec + P_hd-fail · (τ_sd-sen + τ_sd-xfer + τ_dec)` [R7] 식(1).

---

## 3. 공개적으로 구할 수 있는 code 행렬

SSD용 고rate QC-LDPC 행렬은 공개 문헌에서 찾지 못했다([R4][R5]도 구조만 공개). 대안 후보:

| 후보 | 길이/rate | 구조 | 문서 공개/조건 | 참조 구현, 행렬 파일 |
|---|---|---|---|---|
| IEEE 802.3an (10GBASE-T) RS-LDPC | (2048, 1723), rate 0.841 | (6,32)-regular, 384×2048, 64×64 **permutation** 부분행렬 6×32 배열. **QC가 아님**(Butler [R20]), d_min = 14 [R20]. 6개 64-row layer로 layered 복호 가능 [R21] | IEEE GET 프로그램으로 무료 열람(계정 필요, 개인 사용 1부 허용) [R22]. 행렬을 저장소에 재배포하는 것의 허용 여부 **미확인**. 구성법은 Djurdjevic et al.의 RS 기반 구성 [R20] | AFF3CT `configuration_files`에 `10GBPS-ETHERNET_1723_2048.alist`와 `..._ALT_...` 두 파일 [R23]. 그 저장소의 license **미확인**. IEEE 802.3 reflector에 H 파일 행 수(384 대 325) 불일치 문의가 있었고 해결 여부 **미확인** [R24] |
| CCSDS C2 (near-earth) | 기본 (8176, 7156), rate 0.875. shortened (8160, 7136) = 223/255 | 1022×8176, 511×511 circulant 2×16 배열. 각 circulant의 행/열 weight 2 → 행 weight 32, 열 weight 4. rank 1020. Euclidean geometry 기반 [R25] | CCSDS 131.1-O-2(2007, Experimental, 현재 Historical 상태) 원문 확인: circulant 위치 표(Table 2-1)와 systematic circulant generator 표(Annex A) 포함 [R25]. 현행 정규 문서는 CCSDS 131.0-B-3(2017)의 rate 223/255 code [R26]. CCSDS 문서는 무료 공개. 복제/재배포 조건 문구는 **미확인** | 상용 IP: layered, 1.6 Gbit/s coded @200 MHz [R27]. GSFC-STD-9100B도 같은 code를 다룸 [R28](검색 요약 기준). AFF3CT 설정 저장소에는 C2 alist가 보이지 않음(`CCSDS_64_128`만) [R23]. 공인 test vector **미확인** |
| IEEE 802.11n/ac | n = 648/1296/1944, rate 1/2~5/6 | QC, Z = 27/54/81, dual-diagonal parity로 H에서 직접 encoding [R14] | IEEE GET [R22] | AFF3CT에 `WIFI_540_648.alist`(rate 5/6, n=648) [R23]. YALDPC(C99, BSD, 802.11ax와 802.16) [R29] |
| 5G NR BG1/BG2 | mother rate 1/3(BG1), 1/5(BG2) 수준에서 rate matching으로 고rate | QC, Z ≤ 384 [R15] | 3GPP TS 38.212 무료 공개 | Sionna(Apache-2.0) [R30], 5G LDPC 모듈 포함 여부는 이번에 **미확인** |
| DVB-S2 | normal 64800, short 16200, 최고 rate 9/10(normal) | IRA, 360 단위 주소표 [R31](2차 출처 기준) | ETSI EN 302 307-1 무료 공개 | AFF3CT에 DVB-S2 폴더 [R23]. 64800은 Zybo 규모에 비해 큼[추정] |
| 직접 생성(array code, PEG, EG/QC) | 임의(예: rate 0.89, 1 KB) | array code는 cyclic permutation 행렬 구조 [R32], PEG는 girth 하한 보장 구성 [R33] | 논문 기반 알고리즘이라 행렬은 자체 산출물(재배포 문제 없음) | AFF3CT에 `PEG_Reg_1008x504`, `PureIRA_R_9_10_N16k_H` 등 [R23]. MacKay 백과사전 alist [R34](내용 **미확인**). Radford Neal LDPC software(저작권 고지 유지 조건의 자유 사용·수정·배포 허용) [R35] |

참조 구현
- **AFF3CT**: MIT license [R36]. LDPC(위 2.5의 스케줄과 갱신 규칙, alist/QC 행렬 입력), BCH(ALGEBRAIC = BM + Chien, `STD`/`FAST`/`GENIUS` 구현) [R16][R37]. 고정소수점 시뮬레이션 지원의 세부(비트폭 지정 방식)는 이번에 **미확인**.
- 상용 툴(MATLAB 5G/Wireless HDL Toolbox 등)은 이 워크스페이스에서 쓰지 않는 전제로 제외.

---

## 4. Decoder 아키텍처 선행 연구

### 4.1 스케줄
- Layered(row-layered) 복호: Hocevar, SiPS 2004 [R38]. flooding 대비 수렴 속도 약 2배라는 서술이 후속 문헌에 널리 있으나 원문 확인은 못 함(2차 출처 기준) [R38]. 상용 CCSDS IP도 "non-layered 대비 2배 빠른 수렴"을 명시 [R27].
- Layered는 같은 layer 안에서 한 variable node가 두 번 갱신되면 충돌한다. CCSDS C2처럼 weight-2 circulant는 한 layer(511 row)가 같은 열을 두 번 건드리므로 delta 누적 처리가 필요하다[추정: 구조에서 도출].
- 802.3an decoder 예: 6×32 블록을 node group으로 묶은 grouped-parallel 구조, 7단 파이프라인 [R21].

### 4.2 양자화
- 802.3an ASIC: 6-bit OMS가 6-bit sum-product 대비 0.5 dB 이득, post-processing으로 4-bit OMS까지 축소 [R21].
- FPGA layered OMS: 메시지/APP 비트폭 (6,8)이 기준, (5,7)은 LUT −15%, (7,9)는 LUT +18%. RCQ 4-bit는 OMS(6,8) 대비 0.03~0.05 dB 이득 [R39].
- NAND 문헌: LLR 6 bit [R4][R5], 보정 계수 0.75 [R5].

### 4.3 Partially parallel QC decoder의 메모리와 shifter
- Z개(또는 Z/k) lane이 한 circulant 블록을 한 사이클에 처리하고, APP 메모리에서 읽은 Z개 값을 circulant shift만큼 cyclic shift(barrel shifter)해 CN에 정렬한다. HLS에서 shifter를 다단 shift로 다시 쓰면 bit-selection 회로가 줄어든다는 보고 [R40].
- check-to-variable 메시지 저장은 edge별 저장과 row별 압축 저장(min1, min2, index, sign) 두 가지가 있다. 위 802.3an 사례는 메모리 분할로 접근 대역을 확보 [R21].

### 4.4 조기 종료
- syndrome 검사로 반복 중단(AFF3CT `--dec-synd-depth`) [R16]. 상용 IP도 early stopping을 기능으로 명시 [R27].

### 4.5 FPGA 구현 사례(공개 수치)
| 연구 | 디바이스 | Code | 알고리즘/방식 | 자원 | 클럭/throughput |
|---|---|---|---|---|---|
| Terrill et al. 2021 [R39] | Zynq UltraScale+ MPSoC PL | (16384, 8192) PBRL | layered OMS(6,8), Imax 16 | LUT 9,484, Reg 9,518, BRAM 33 (기준 설계) | 500 MHz 타이밍 만족. throughput 수치 **미확인** |
| Mhaske et al. 2015 [R41] | Kintex-7 | 802.11n (1944, rate 1/2) | layered 계열 min-sum, LabVIEW 컴파일러 생성 | 비율로만 공개(절대값 **미확인**) | 608 Mb/s (본문 200 MHz, 결론 260 MHz로 불일치) |
| Mhaske et al. 후속 [R42] | NI USRP-2953R(Kintex-7 계열) | 802.11n | 6 core | LUT 73%, BRAM 44% | 2.48 Gb/s (검색 요약 기준) |
| Zhang et al. (R-LDPC), DATE 2023 [R40] | Alveo U50 | 802.16e, CCSDS | Vitis HLS, layered | 단일 decoder 약 14K LUT(유사 throughput의 이전 HLS 설계 약 25K) | 다중 instance로 최대 9.9 Gbps |
| Creonic CCSDS IP [R27] | FPGA/ASIC(상용) | (8160, 7136) | layered, early stop | 브리프에 자원 없음 | 1.6 Gbit/s coded @200 MHz, 5 iteration 지연 4.3 µs |
| Cui, Wang, ISCAS 2006 [R43] | Virtex-II | (8176, 7156) EG-LDPC | semi-parallel | **미확인** | 15 iteration에서 정보 throughput 170 Mbps 이상 (초록 기준) |
| 학위논문 [R44] | **XC7Z020** | QC-LDPC n=1106, rate 0.857 (dv 4, dc 28) | GaB(bit flipping) | **미확인**(원문 403) | **미확인** |
| 참고: Zhang et al., JSSC 2010 [R21] | 65 nm ASIC | 802.3an (2048, 1723) | grouped-parallel OMS + post-processing | 5.35 mm² | 47.7 Gb/s |

- Zynq-7020급의 soft LDPC decoder 공개 수치는 찾지 못했다(**미확인**). 위 표의 다른 디바이스 수치는 비교 기준으로만 쓴다.

---

## 5. BCH (비교 기준)

### 5.1 SSD/NAND용 parameter 예
| 출처 | sector | Code / t | 체 |
|---|---|---|---|
| Micron 문서(2006 FMS 발표, 2012 노트) | 528 B(512 + 16) | t = 4 예 | 원문 **미확인**(검색 요약 기준) [R45] |
| Intel Agilex 5 HPS NAND 컨트롤러 | 1024~1064 B | t = 8, 16, 32 | 원 페이지가 열리지 않음, 검색 요약 기준 [R46] |
| [R3] | 512 B | (4798, 4096), t = 54 | GF(2^13) [추정: n < 8191에서 도출] |
| [R4] | 4 KB | (32767, 31133), t = 109 | GF(2^15) |

### 5.2 Decoder 구성
- Syndrome 계산 → 오류 위치 다항식(BM, inversionless BM, reformulated iBM) → Chien search.
- Reformulated inversionless BM: 임계 경로가 곱셈기 1개 + 덧셈기 1개(RS decoder 대상) [R47](초록 기준).
- binary BCH에서는 BM iteration을 하나 걸러 건너뛸 수 있다(특허 서술) [R48](검색 요약 기준).
- Chien search: P-병렬이면 ⌈n/P⌉ 사이클 [R49](검색 요약 기준). conventional 구조 지연 2t+2 사이클(BM t iteration × 2사이클 + 완전 병렬 Chien) [R49](검색 요약 기준).
- AFF3CT BCH: BM + Chien, `STD`는 Chien이 찾은 근 수가 BM 차수와 다르면 frame을 그대로 둔다 [R37]. RTL golden 비교에는 `STD`와 같은 실패 처리 규칙을 써야 한다[추정].

### 5.3 이 프로젝트에서의 범위
- 같은 rate(예: 0.89)와 같은 데이터 크기에서 BCH 대 LDPC(hard, soft) FER 곡선 비교가 주 용도. BCH IP는 시간 여유가 있을 때의 선택 항목으로 둔다[추정: 6절 권고].

---

## 6. 범위 제안 (Zybo Z7-20: LUT 53,200, BRAM36 140, DSP 220)

아래 수치 중 자원과 throughput은 모두 [추정]이다. 측정 전 계획값으로만 쓴다.

### 6.1 Code 선택 권고
**1안(권고): SSD형 자체 QC-LDPC를 HW 주 code로, CCSDS C2와 802.3an을 golden 검증용 외부 기준으로.**
- 주 code [추정 설계]: weight-1 circulant만 쓰는 QC-LDPC, Z = 128(2의 거듭제곱), base 8×72, n = 9216, k = 8192(1 KB), rate 0.889, 정보부 열 weight 4, parity부는 802.11n/5G처럼 dual-diagonal로 두어 H에서 직접 encoding. 구성은 array code 또는 QC-PEG로 하고 girth ≥ 6(가능하면 8)을 스크립트로 검사. 생성 스크립트와 seed를 `data/`에 남겨 재현 가능하게 한다.
- 근거: (1) SSD 문헌의 code 형태(rate 0.89~0.95, 1~4 KB, QC, 열 weight 4 [R4][R5][R7])와 맞는다. (2) weight-1 circulant + 2의 거듭제곱 Z는 표준 layered 구조(barrel shifter, 충돌 없음)로 바로 대응한다. (3) C2(weight-2 circulant, Z = 511 = 7 × 73)는 layer 내 열 충돌 처리와 비2진 shifter가 필요해 첫 IP의 위험이 크다. (4) 802.3an은 QC가 아니라 permutation network가 필요하다. (5) 공개 SSD code가 없으므로 어떤 공개 code도 "SSD 그대로"는 아니다.
- 약점: 주 code에 외부 공인 기준이 없다. 보완: golden decoder를 code 무관(H 행렬 입력)으로 만들고, C2와 802.3an 행렬에서 AFF3CT와 교차 검증해 golden 자체를 검증한 뒤 같은 코드로 주 code를 돌린다. 주 code에서도 AFF3CT에 alist로 넣어 FER을 교차 확인한다.

**2안: CCSDS C2 (8176, 7156)를 HW 주 code로.** 공개 정규 code이고 rate와 길이(약 1 KB)가 SSD와 가깝다. 상용 IP 수치 [R27]가 비교 기준이 된다. 대신 weight-2 circulant의 layered 충돌 처리, Z = 511 lane 분할(73 또는 511)로 구조가 복잡하다. 연구 포인트로는 흥미로우나 첫 IP로는 위험.

**3안: 5G NR BG의 고rate 부분.** 3GPP 공개, 참조 구현(Sionna) 있음. multi-Z, rate matching까지 가면 범위가 커지고 NAND와 연결이 약하다.

### 6.2 (a) C 전체 구성 (golden이자 ARM baseline)
| 모듈 | 내용 |
|---|---|
| `chan` | NAND 채널: MLC 해석 모델 [R3] 또는 TLC fit 표 [R5] 선택. P/E, retention 입력. 출력은 셀별 Vth(고정소수점 또는 double) |
| `sense` | read reference 집합(hard 1개, soft 2·4·6개)으로 Vth를 구간 index로 양자화. read retry 정책(기준 전압 offset 표) 포함 |
| `llr` | 구간 index → LLR LUT(채널 parameter에서 오프라인 계산, q bit 포화) [R4][R5] |
| `ldpc_enc` | dual-diagonal 기반 QC encoder |
| `ldpc_dec_hard` | bit flipping(GaB 또는 GDBF 계열) |
| `ldpc_dec_soft` | layered NMS/OMS, 고정소수점, syndrome 조기 종료. flooding 변형은 비교용 |
| `bch_enc`, `bch_dec` | 같은 rate의 BCH, BM(또는 iBM) + Chien |
| `policy` | hard → retry → soft 흐름과 지연 모델 [R7] 식(1)(3) |
| `fer` | Monte Carlo FER 대 RBER, 시드 고정 |
- golden 언어: 비트 정확성, PS(ARM)에서 그대로 실행, HLS 공유 때문에 C(필요 시 C++의 `ac_int` 대응 계층은 HLS 소스에서만)[추정 권고].

### 6.3 (b) IP 분할 후보와 RTL/HLS 분담
| IP | 내용 | 방식 | 자원 [추정] |
|---|---|---|---|
| IP1 `ldpc_dec` | layered min-sum, 128 lane, block-serial CNU, edge별 R 메모리(BRAM), APP 메모리, barrel shifter 128×8b, 조기 종료 | 스케줄러·주소 생성·shifter·메모리·조기 종료는 RTL. CNU/VNU datapath는 HLS(Catapult) 가능, RTL 버전과 QoR 비교 권장 | LUT 25k~35k, BRAM36 30~45. 이터레이션당 약 8 layer × (36 + 파이프라인 약 10) ≈ 370 사이클, 100 MHz·10 iteration이면 약 220 Mbps, 조기 종료 시 그 이상 |
| IP2 `llr_gen` | 감지 index → LLR LUT, page 종류별 | RTL(작음). IP1 입력단에 붙일 수 있음 | LUT 1k 미만 |
| IP3 `ldpc_enc` | dual-diagonal QC encoder | RTL | LUT 수 k |
| IP4 `bch_dec`(선택) | syndrome(HLS 가능), iBM(RTL), 병렬 Chien | 혼합 | t와 병렬도에 따라 큼, **범위 결정 필요** |
| IP5 `chan_emu`(선택) | PL NAND 채널 에뮬레이터: 결정적 RNG + 근사 Gaussian + 기준 전압 비교 | RTL 또는 HLS. C 모델과 비트 정확해야 함 | 수 k LUT, DSP 일부 |
| top | AXI4-Lite 레지스터, AXI4-Stream + AXI DMA, IP 간 FIFO | RTL | |
- 시스템 프로젝트 방식대로 ARM 프로파일 결과로 오프로드 순서를 정한다. 예상 순서는 IP1 → IP2/IP3 → (IP5 또는 IP4)[추정].

### 6.4 (c) Test data 3종
1. **공인/외부**
   - code 행렬: CCSDS 131.1-O-2 Table 2-1(C2 H), Annex A(generator) [R25]. 802.3an H(AFF3CT alist [R23], 또는 Djurdjevic 구성법으로 재생성해 비교). 재배포 조건이 불명확하므로 저장소에는 생성/다운로드 스크립트와 checksum만 둔다.
   - 참조 구현 출력: AFF3CT(MIT)로 같은 H, 같은 채널 LLR 입력에서 FER 곡선과 가능하면 frame 단위 복호 결과를 덤프해 golden과 비교 [R36][R16]. BCH도 AFF3CT로 교차 [R37].
   - 채널 parameter: [R3] 상수, [R4] 상수, [R5] 표를 `data/README.md`에 출처와 함께 기록. 공개 raw NAND 데이터가 없다는 사실과 대체 근거(문헌 fit 표 + 독립 구현 교차)를 명시.
   - 공개 곡선 대조(정성): C2 BER/BLER 곡선(5/10/15 iteration) [R27], [R7]의 Fig. 3/10.
2. **방향성**: 전부 0 codeword, (짝수 행 weight이면) 전부 1 codeword, 오류 0개(0 iteration 조기 종료), 단일 비트 오류, circulant 경계(index 0, Z−1) 오류, LLR 최대 포화 값과 0(erasure), 최대 iteration에서 실패하는 패턴, girth/trapping set 근처 패턴, BCH에서 정확히 t개와 t+1개 오류, 기준 전압 경계값 Vth.
3. **random**: 시드와 개수 기록. 데이터 비트 random + 채널 조건(P/E 0/1K/3K/5K/10K, retention 1일/1개월/1년)별 Vth 샘플. 기대값은 golden이 생성.

### 6.5 (d) 측정 항목
- 정정 성능: FER 대 RBER(hard, soft 1/2/3 bit 감지), LDPC 대 BCH, 양자화 비트폭(4/5/6 bit)별 차이, layered 대 flooding의 평균 iteration.
- Throughput: RTL sim 사이클(frame당), 보드 실측(PS 타이머).
- 가속: ARM Cortex-A9 단독 대비 모듈별 가속비.
- Amdahl: 프로파일 비중으로 추정한 전체 가속 대 end-to-end 실측. 차이(DMA, 캐시 flush, 호출 오버헤드)를 분리해 기록. 추정과 실측을 구분.
- 시스템 지연 모델: [R7] 식(1)에 측정한 τ_dec과 FER을 넣은 평균 read 지연(감지 시간은 문헌 값 [R7]을 쓰고 그 사실을 명시).

### 6.6 (e) 위험과 열린 결정
| 항목 | 내용 |
|---|---|
| code 선택 | 6.1의 1안/2안/3안. 1안이면 code 구성과 girth 검증이 G0~G1 작업에 추가됨 |
| soft 정보 비트 수 | 감지 레벨 수(hard + 2/4/6) 대 LLR 비트폭(4~6). 문헌은 6 bit LLR이 일반적 [R4][R5] |
| 채널 모델 | MLC 해석 모델(P/E·retention 식 있음) [R3] 대 TLC fit 표(실측 기반, P/E·retention 격자값만) [R5]. 둘 다 구현하고 기본을 하나로 정할지 |
| FER 깊이 | 서버는 병렬 2, core 1개. C min-sum frame당 약 1 ms면 1e6 frame에 약 17분, FER 1e-6 근처를 안정적으로 보려면 1e8 frame급이라 서버에서는 1e-5 부근까지가 현실적[추정]. 보드 FER은 ARM의 채널 샘플 생성이 병목이 될 가능성이 커서 IP5(PL 채널 에뮬레이터) 여부가 깊이를 결정[추정] |
| 메모리 폭 | 128 lane × 8 bit APP 읽기는 BRAM 폭으로 결정됨. row별 압축 R 저장은 폭이 너무 넓어 FF 소모가 클 수 있어 edge별 BRAM 저장을 기본으로[추정] |
| layered 파이프라인 hazard | 연속 layer가 같은 열 블록을 쓰면 stall 필요. layer 순서/열 순서 스케줄을 code 설계 단계에서 함께 고려 |
| HLS QoR | CNU/VNU를 Catapult로 할 때 shifter와 메모리는 RTL로 고정해야 한다는 보고 [R40] |
| 라이선스 | IEEE GET 문서의 행렬 재배포, AFF3CT 설정 저장소 license, CCSDS 복제 조건 모두 **미확인**. 저장소에는 스크립트와 checksum만 |
| DC | 면적 수치는 DC 미승인 시 Vivado 리포트(사용자 실행)만 사용 |

### 6.7 (f) `ldpc-decoder-5g.md` 흡수 권고
- **흡수 권고.** 그 brief의 연구 가치(layered min-sum, 양자화 대 성능, layer 스케줄과 파이프라인 충돌 회피, check/variable node HLS + 스케줄러·shifter RTL 분담)는 이 프로젝트의 IP1과 그대로 겹친다. 별도 프로젝트로 두면 같은 decoder를 두 번 만들게 된다.
- 5G 특유 부분(multi-Z lifting, rate matching, HARQ)은 이 프로젝트 범위 밖이다. IP1을 base matrix ROM과 Z를 parameter로 만들어 두면 나중에 5G BG2 소형 Z 구성을 "확장"으로 붙일 수 있다. 이 확장은 todo에 한 줄 메모로 남기고 brief는 흡수 처리하는 것을 권고(분야 다양화 원칙상 통신 분야는 다른 주제로 채우는 편이 낫다).

---

## 7. 참고 문헌

NAND 오류 모델과 soft read
- [R1] Y. Cai, E. F. Haratsch, O. Mutlu, K. Mai, "Threshold Voltage Distribution in MLC NAND Flash Memory: Characterization, Analysis, and Modeling," DATE 2013. https://www.pdl.cmu.edu/PDL-FTP/NVM/flash-memory-voltage-characterization_date13_abs.shtml
- [R2] Y. Luo, S. Ghose, Y. Cai, E. F. Haratsch, O. Mutlu, "Enabling Accurate and Practical Online Flash Channel Modeling for Modern MLC NAND Flash Memory," IEEE JSAC, 2016. https://www.pdl.cmu.edu/PDL-FTP/NVM/online-flash-channel-modeling_jsac16_abs.shtml
- [R3] Y. Pan, G. Dong, T. Zhang, "Exploiting Memory Device Wear-Out Dynamics to Improve NAND Flash Memory System Performance," USENIX FAST 2011, pp. 245-258. https://usenix.org/event/fast11/tech/full_papers/Pan.pdf
- [R4] G. Dong, N. Xie, T. Zhang, "On the Use of Soft-Decision Error-Correction Codes in NAND Flash Memory," IEEE TCAS-I, vol. 58, no. 2, pp. 429-439, Feb. 2011. DOI 10.1109/TCSI.2010.2071990. https://sites.ecse.rpi.edu/~tzhang/pub/ECCTCASI2011.pdf
- [R5] L. Cui, F. Wu, X. Liu, M. Zhang, R. Xiao, C. Xie, "Improving LDPC Decoding Performance for 3D TLC NAND Flash by LLR Optimization Scheme for Hard and Soft Decision," ACM TODAES, vol. 27, no. 1, Art. 5, 2021. DOI 10.1145/3473305. https://xiaorz.github.io/paper/TODAES2021-Cui.pdf
- [R6] Y. Luo, S. Ghose, Y. Cai, E. F. Haratsch, O. Mutlu, "Improving 3D NAND Flash Memory Lifetime by Tolerating Early Retention Loss and Process Variation," SIGMETRICS 2018 / POMACS. DOI 10.1145/3224432. https://arxiv.org/abs/1807.05140
- [R7] K. Zhao, W. Zhao, H. Sun, T. Zhang, X. Zhang, N. Zheng, "LDPC-in-SSD: Making Advanced Error Correction Codes Work Effectively in Solid State Drives," USENIX FAST 2013, pp. 243-256. https://www.usenix.org/conference/fast13/technical-sessions/presentation/zhao
- [R8] Y. Cai, Y. Luo, E. F. Haratsch, K. Mai, O. Mutlu, "Data Retention in MLC NAND Flash Memory: Characterization, Optimization, and Recovery," HPCA 2015. https://pdl.cmu.edu/PDL-FTP/NVM/flash-memory-data-retention_hpca15_abs.shtml
- [R9] Y. Cai, Y. Luo, S. Ghose, E. F. Haratsch, K. Mai, O. Mutlu, "Read Disturb Errors in MLC NAND Flash Memory: Characterization, Mitigation, and Recovery," DSN 2015. https://arxiv.org/abs/1805.03283
- [R10] J. Wang, G. Dong, T. Courtade, H. Shankar, T. Zhang, R. Wesel, "LDPC Decoding with Limited-Precision Soft Information in Flash Memories," arXiv:1210.0149, 2012. https://arxiv.org/abs/1210.0149
- [R11] J. Park, M. Kim, M. Chun, L. Orosa, J. Kim, O. Mutlu, "Reducing Solid-State Drive Read Latency by Optimizing Read-Retry," ASPLOS 2021 (확장 초록 arXiv:2012.12178). https://arxiv.org/abs/2012.12178
- [R12] Y. Cai, S. Ghose, E. F. Haratsch, Y. Luo, O. Mutlu, "Error Characterization, Mitigation, and Recovery in Flash-Memory-Based Solid-State Drives," Proc. IEEE, vol. 105, no. 9, pp. 1666-1704, 2017. https://arxiv.org/abs/1706.08642 (관련 서베이: https://arxiv.org/abs/1808.04016)

ECC, code, 참조 구현
- [R13] Politecnico di Torino 학위논문(8 KB page, rate 0.96 QC-LDPC FPGA). https://iris.polito.it/retrieve/handle/11583/2654903/129979 (검색 요약 기준)
- [R14] 802.11n LDPC parameter: "Channel Coding Toward 6G: Technical Overview and Outlook," arXiv:2405.07547. https://arxiv.org/abs/2405.07547 ; MathWorks WLAN HDL LDPC Encoder 문서 https://au.mathworks.com/help/wireless-hdl/ug/wlanhdlldpcencoder.html
- [R15] 3GPP TS 38.212 (NR multiplexing and channel coding). 2차 출처: "Demystifying 5G Polar and LDPC Codes," arXiv:2502.11053. https://arxiv.org/abs/2502.11053
- [R16] AFF3CT LDPC decoder parameters. https://aff3ct.readthedocs.io/en/latest/user/simulation/parameters/codec/ldpc/decoder.html
- [R17] T. Wadayama et al., "Gradient Descent Bit Flipping Algorithms for Decoding LDPC Codes," IEEE Trans. Commun., vol. 58, no. 6, pp. 1610-1614, 2010. https://arxiv.org/abs/0711.0261
- [R18] H. Raza et al., "Area-efficient, high-throughput layered MS-IC-APP LDPC decoder," PLoS ONE 16(3): e0249269, 2021. https://pmc.ncbi.nlm.nih.gov/articles/PMC8007033/
- [R19] J. Chen, A. Dholakia, E. Eleftheriou, M. Fossorier, X.-Y. Hu, "Reduced-Complexity Decoding of LDPC Codes," IEEE Trans. Commun., vol. 53, no. 8, pp. 1288-1299, 2005. DOI 10.1109/TCOMM.2005.852852
- [R20] B. K. Butler, "Minimum Distances of the QC-LDPC Codes in IEEE 802 Communication Standards," arXiv:1602.02831, 2016 (802.3an 절에서 RS-LDPC, non-QC, d_min 14 확인). https://arxiv.org/abs/1602.02831
- [R21] Z. Zhang, V. Anantharam, M. J. Wainwright, B. Nikolić, "An Efficient 10GBASE-T Ethernet LDPC Decoder Design With Low Error Floors," IEEE JSSC, vol. 45, no. 4, pp. 843-855, 2010. DOI 10.1109/JSSC.2010.2042255. https://people.eecs.berkeley.edu/~bora/Journals/2010/JSSC-0410.pdf
- [R22] IEEE GET Program(802 표준 무료 열람 조건). https://standards.ieee.org/getieee802/ ; 이용 조건 https://ieeexplore.ieee.org/Xplorehelp/overview-of-ieee-xplore/get-program-terms-of-use
- [R23] AFF3CT configuration files, `dec/LDPC`. https://github.com/aff3ct/configuration_files/tree/master/dec/LDPC
- [R24] IEEE 802.3 reflector의 H 행렬 행 수 문의. https://grouper.ieee.org/groups/802/3/email_dialog/msg00414.html
- [R25] CCSDS 131.1-O-2, "Low Density Parity Check Codes for Use in Near-Earth and Deep Space Applications," Experimental Specification, Orange Book Issue 2, Sept. 2007 (Historical). https://ccsds.org/Pubs/131x1o2e2s.pdf
- [R26] CCSDS 131.0-B-3, "TM Synchronization and Channel Coding," Blue Book, Sept. 2017. (B-2 목차: https://public.ccsds.org/Pubs/131x0b2ec1s.pdf)
- [R27] Creonic, "CCSDS (8160, 7136) LDPC Encoder and Decoder Product Brief," 2023. https://www.aldec.com/files/ip_products/PB_Creonic_CCSDS_LDPC_FEC_IP.pdf
- [R28] NASA GSFC-STD-9100B, "Low Density Parity Check Code for Rate 7/8." https://standards.nasa.gov/sites/default/files/standards/GSFC/B/0/GSFC-STD-9100B_Approved.pdf
- [R29] T. Palenik, V. Szitkey, "High Throughput Open-Source Implementation of Wi-Fi 6 and WiMAX LDPC Encoder and Decoder," arXiv:2306.12063 (코드 BSD). https://github.com/talenik/YALDPC
- [R30] NVIDIA Sionna (Apache-2.0). https://github.com/NVlabs/sionna
- [R31] ETSI EN 302 307-1 (DVB-S2). https://www.etsi.org/deliver/etsi_EN/302300_302399/302307/01.03.01_20/en_302307v010301a.pdf ; rate 목록 2차 출처 https://ch.mathworks.com/help/satcom/ref/dvbsldpcpcm.html
- [R32] J. L. Fan, "Array Codes as Low-Density Parity-Check Codes," Proc. 2nd Int. Symp. Turbo Codes, Brest, 2000, pp. 543-546.
- [R33] X.-Y. Hu, E. Eleftheriou, D. M. Arnold, "Regular and Irregular Progressive Edge-Growth Tanner Graphs," IEEE Trans. Inf. Theory, vol. 51, no. 1, pp. 386-398, 2005. DOI 10.1109/TIT.2004.839541
- [R34] D. J. C. MacKay, Encyclopedia of Sparse Graph Codes (inference.phy.cam.ac.uk/mackay/codes/data.html, 접근 **미확인**).
- [R35] R. M. Neal, LDPC software (2006-02-08 판, 이용 조건 페이지). https://glizen.com/radfordneal/ftp/LDPC-2006-02-08/index.html
- [R36] AFF3CT (MIT license). https://github.com/aff3ct/aff3ct
- [R37] AFF3CT BCH decoder parameters. https://aff3ct.readthedocs.io/en/latest/user/simulation/parameters/codec/bch/decoder.html

Decoder 아키텍처
- [R38] D. E. Hocevar, "A Reduced Complexity Decoder Architecture via Layered Decoding of LDPC Codes," IEEE SiPS 2004, pp. 107-112 (원문 미확인. 수렴 2배 서술의 2차 출처: arXiv:2104.06867 https://arxiv.org/abs/2104.06867)
- [R39] C. Terrill, L. Wang, S. Chen, C. Hulse, C. Kuo, R. Wesel, D. Divsalar, "FPGA Implementations of Layered MinSum LDPC Decoders Using RCQ Message Passing," arXiv:2104.09480, 2021. https://arxiv.org/abs/2104.09480
- [R40] Y. Zhang, Q. Cao, J. Yao, H. Jiang, "R-LDPC: Refining Behavior Descriptions in HLS to Implement High-throughput LDPC Decoder," DATE 2023. https://ranger.uta.edu/~jiang/publication/Conferences/2023/DATE2023-R-LDPC.pdf
- [R41] S. Mhaske, H. Kee, T. Ly, A. Aziz, P. Spasojevic, "Strategies for High-Throughput FPGA-based QC-LDPC Decoder Architecture," arXiv:1503.02986, 2015. https://arxiv.org/abs/1503.02986
- [R42] "A 2.48Gb/s QC-LDPC Decoder Implementation on the NI USRP-2953R," arXiv:1505.04339. https://arxiv.org/abs/1505.04339 (검색 요약 기준)
- [R43] Z. Cui, Z. Wang, "A 170 Mbps (8176, 7156) quasi-cyclic LDPC decoder implementation with FPGA," ISCAS 2006. DOI 10.1109/ISCAS.2006.1693778 (초록 기준)
- [R44] XC7Z020 GaB decoder 학위논문. https://core.ac.uk/download/222806222.pdf (원문 접근 실패, 검색 요약 기준)

BCH
- [R45] Micron NAND ECC 자료: Flash Memory Summit 2006 발표 https://old.flashmemorysummit.com/English/Collaterals/Proceedings/2006/20060810_S201_Feeley.pdf (검색 요약 기준)
- [R46] Intel Agilex 5 HPS TRM, NAND ECC engine. https://www.intel.com/content/www/us/en/docs/programmable/814346/24-1/ecc-engine-functionality.html (페이지 열람 실패, 검색 요약 기준)
- [R47] D. V. Sarwate, N. R. Shanbhag, "High-Speed Architectures for Reed-Solomon Decoders," IEEE TVLSI, vol. 9, no. 5, Oct. 2001.
- [R48] US 2011/0239094, "Error correction mechanisms for flash memories." https://patents.justia.com/patent/20110239094 (검색 요약 기준)
- [R49] "High-throughput Low-latency Hardware Implementation of BCH Decoders," arXiv:2606.17837 (검색 요약 기준); Chien 병렬 사이클 수는 같은 검색의 par.nsf.gov 자료 https://par.nsf.gov/servlets/purl/10525578 (검색 요약 기준)

추가 (2026-11-25, N1 스펙 작성 중 확인)
- [R50] D. Blackman, S. Vigna, "Scrambled Linear Pseudorandom Number Generators," arXiv:1805.01407 (ACM TOMS 게재, DOI 10.1145/3460772는 검색 요약 기준). 참조 C 코드 https://prng.di.unimi.it/xoshiro128starstar.c 원문 확인: 상태 128 bit, 출력 `rotl(s[1] * 5, 7) * 9`, 주기 2^128 − 1, public domain 헌정(사용·수정·배포 허용).
- [R51] Digilent, Zybo Z7 Reference Manual. https://digilent.com/reference/programmable-logic/zybo-z7/reference-manual (페이지 직접 열람 실패, 검색 요약 기준): Cortex-A9 dual-core 667 MHz, 1 GB DDR3L 32-bit bus 1066 MT/s.
- [R52] AMD UG953 Vivado 7 series libraries, RAMB36E1. https://docs.amd.com/r/en-US/ug953-vivado-7series-libraries/RAMB36E1 (검색 요약 기준): simple dual port 72 bit x 512 deep 구성 가능, TDP는 1 bit x 32K ~ 36 bit x 1K.
