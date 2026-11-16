# P1-a 선행 연구 서베이: ML-KEM 다항식 연산 HW, HLS vs RTL, 검증, AI agent 설계 흐름

- 작성일: 2026-11-16
- 범위: Kyber/ML-KEM NTT 및 다항식 연산 HW, HLS 기반 PQC, RTL 대비 HLS QoR 격차, ML-KEM+ML-DSA 통합, 모듈러/NTT HW 검증, LLM/agent 기반 HW 설계(2024~2026)
- 확인 표기: **[확인]** = 원문 페이지(초록 페이지, HTML 본문, PDF 본문 중 하나)를 직접 열어 확인. **[재인용]** = 직접 열어본 다른 논문의 비교표/참고문헌을 통해서만 확인(1차 원문은 미열람). **[미확인]** = 검색 결과 요약으로만 접했고 원문을 열지 못함(403, 봇 차단 등). 미확인 항목의 수치는 근거로 쓰지 말 것.
- 수치는 원문 조건(디바이스, 지표 정의)을 같이 적었다. 서로 다른 디바이스/지표의 수치는 직접 비교할 수 없다.

## 1. 요약

1. Kyber/ML-KEM NTT FPGA 구현은 실제로 포화 상태다. KiD 논문 비교표 하나에만 Kyber 단독 NTT 설계가 7건 이상 있고, 2025~2026년에도 신규 FPGA 설계가 계속 나온다(Bertels 2025/1763, Varandi 2026/2726 등). 단순 "또 하나의 Kyber NTT FPGA 구현"은 기여가 되기 어렵다는 오케스트레이터 예상은 맞다.
2. 모듈러 곱셈기 단위에서도 경쟁이 극단적이다(Bertels FPL 2024: 49 LUT + 1 DSP, Xing-Li CHES 2021: 90 LUT + 1 DSP). 면적 최소화로 새 기록을 내기는 어렵다.
3. ML-KEM+ML-DSA 통합 NTT도 이미 다수(KaLi, KiD, PQShield ASHES 2024, ICASSP 2025 FFT/NTT 통합, Microsoft Adams Bridge, RISQrypt)이며, 산업 IP(Caliptra/Adams Bridge)까지 존재한다.
4. 반면 "같은 마이크로아키텍처를 RTL과 HLS로 각각 구현해 QoR을 통제 비교"한 연구는 NTT 전체로 보면 2019~2020년 GMU(Vivado HLS, FPGA 전용, Round-2 파라미터)와 Mert et al. TC(Virtex-7, Vivado HLS, 서로 다른 구조)가 거의 전부이며, ML-KEM(q=3329, 7-layer incomplete NTT + basemul)과 Catapult HLS, ASIC 합성을 함께 다룬 통제 비교는 찾지 못했다.
5. Catapult로 Kyber NTT를 만든 사례는 LLM4PQC(DATE 2026)뿐이며, LLM 생성 HLS 결과(Artix-7, 5,639 cycles @75 MHz)가 hand RTL 기준선(277 cycles @250 MHz)보다 크게 느리다. 인간 설계 HLS 기준선은 없다.
6. 모듈러 연산/NTT의 formal 검증은 SW(CryptoLine, Jasmin/EasyCrypt) 쪽에 집중되어 있고, HW에서는 2^n±1 모듈러 곱셈기(DAC 2022)와 masking 보안성 검증(2026)이 있을 뿐, Kyber NTT RTL의 기능 formal 검증 사례는 찾지 못했다.
7. LLM/agent 기반 PQC HW 설계는 2026년에 급증(LLM4PQC, FALCON co-design, deployed-silicon 사례 연구)했고, "agent 산출물의 신뢰를 machine-checkable gate로 확보"하는 방향(NeurIPS 2026 워크숍, FormalRTL)이 새로 부상하고 있다.
8. 가장 현실적인 빈 곳은 (a) ML-KEM 다항식 연산에 대한 RTL vs Catapult HLS 통제 비교(FPGA + ASIC, reduction 알고리즘 sweep 포함)와 (b) agent 보조 설계 흐름을 exhaustive/formal 수용 기준과 함께 정량 기록하는 것이다. 둘 다 top-tier 암호 HW 학회(TCHES)급 기여는 아니고, 설계 방법론/EDA 성격의 학회나 저널 short paper 수준을 현실적 목표로 본다.

## 2. 주제별 표

### 2.1 Kyber/ML-KEM NTT 및 다항식 연산 HW 구현

#### (a) 직접 확인한 주요 설계

| 논문 | 구조 유형 | reduction | 디바이스 | 자원 | 주파수 | latency | 확인 |
|---|---|---|---|---|---|---|---|
| Bertels, Norga, Verbauwhede, "A Better Kyber Butterfly for FPGAs", FPL 2024 | butterfly/모듈러 곱셈기 단위 | K-reduction + LUT 기반 reduction | Xilinx FPGA(초록에 부품명 없음) | 모듈러 곱 1개당 49 LUT + 1 DSP (Xing-Li 90 LUT + 1 DSP 대비) | 초록에 없음 | 초록에 없음 | [확인] 초록. PDF는 403 |
| Bertels, Verbauwhede, "A High Throughput Kyber NTT", ePrint 2025/1763 | 완전 전개(매 클럭 NTT 1회) | CHES 2025의 LUT 기반 모듈러 곱 | FPGA(초록에 부품명 없음) | 67,210 LUT, 0 DSP | 초록에 없음 | 매 클럭 NTT 1회 처리량 | [확인] 초록 |
| Mandal, Roy, "KiD", arXiv 2311.04581 (VLSID 2024) | iterative, radix-2, BFU 2개(Kyber 단독), conflict-free 메모리 매핑, pipeline depth 15 | Montgomery(12x12 곱 1개당 71 LUT + 1 DSP) | Artix-7 XC7A200T | 799 LUT, 916 FF, 2 BRAM, 2 DSP | 310 MHz | NTT/INTT 448, PWM 256 cycles | [확인] PDF 본문 Table II |
| 같은 논문 | 같은 구조 | 같음 | ZCU102 (Zynq US+) | 698 LUT, 865 FF, 2 BRAM, 2 DSP | 500 MHz | NTT/INTT 448, PWM 256 | [확인] |
| Kundi, Bermudo Mera, Strub, Hutter (PQShield), ASHES 2024 | 완전 pipelined R2MDC, 단일 CT BF2 구성으로 NTT/iNTT 공용, ML-KEM/ML-DSA 통합 | ML-KEM: Xing-Li 방식을 수정한 Barrett(몫을 시프트-가산으로 근사, 2 cycle). ML-DSA: Solinas | Zynq UltraScale+ | 3,821 LUT, 2,970 FF, 20 DSP, 5 BRAM | 322 MHz | 1 벡터 258 cycles(파이프 채움 130 + 출력 128), 이후 벡터당 128 | [확인] PDF 본문 |
| Varandi, Salarifard, ePrint 2026/2726 | 단일 PE / 이중 PE, unified butterfly, constant-geometry | q=3329 특화 reduction | 초록에 없음 | 이중 PE는 DSP/BRAM 미사용 | 초록에 없음 | 초록에 없음 | [확인] 초록만(수치 없음) |
| Yaman, Mert, Öztürk, Savaş, DATE 2021 (ePrint 2021/485) | lightweight/balanced/high-performance 3종, unified butterfly, 최대 16 BU | 초록에 없음 | 초록에 없음 | 초록에 없음 | 초록에 없음 | Cortex-M4 SW 대비 NTT 112x, INTT 132x | [확인] 초록 |
| Bisheh-Niasar et al.(Microsoft), "PQC Cloudization", ePrint 2023/1038 (PAINE 2023) | HLS 기반 확장형 NTT/INTT | 초록에 없음 | 초록에 없음 | 초록에 없음 | 초록에 없음 | 차수 256 NTT 14 cycles | [확인] 초록 |
| Shrivastava et al., "Unified FFT/NTT", ICASSP 2025 (arXiv 2504.11124) | FFT butterfly 재사용, FFT 1개 / ML-DSA 2개 / ML-KEM 4개 butterfly 모드 | Barrett(두 modulus 모두) | Zynq US+ | 3,716 LUT, 2,400 FF, 12 DSP, 5 BRAM | 400 MHz | ML-KEM NTT 322 cycles(0.80 us), ML-DSA 624 cycles | [확인] HTML 본문 Table II |
| Gimenez et al., "An HLS-Based Hardware Accelerator for ML-KEM Polynomial Operations", SBSeg 2026 (학부/학위 워크숍) | Vitis HLS, Load-Compute-Store, 16 BRAM bank 분할 | 레퍼런스 C의 Montgomery/Barrett | PYNQ-Z2 (XC7Z020, 이 프로젝트 Zybo Z7-20과 동일 칩) | 13,984 LUT, 14,274 FF, 15.5 BRAM, 91 DSP | PL 100 MHz | POLYVEC NTT 23,693 cycles(데이터 전송 포함), Cortex-A9 SW 대비 4.65x | [확인] PDF 본문 Table 2, 3 |

#### (b) KiD 논문 Table II에서 재인용한 Kyber NTT 설계(Artix-7 그룹, 1차 원문 미열람)

| 설계(KiD 참고문헌 번호) | LUT | FF | BRAM | DSP | NTT/INTT/PWM cycles | MHz | 확인 |
|---|---|---|---|---|---|---|---|
| Bisheh-Niasar et al., ARITH 2021 [3] | 801 | 717 | 2 | 4 | 324/324/- | 222 | [재인용] |
| Bisheh-Niasar et al., TCAS-I 2021 [17] (2가지 구성) | 360 / 737 | 145 / 290 | 2 / 4 | 3 / 6 | 940/1203/1289, 474/602/1289 | 115 | [재인용] |
| Xing, Li, TCHES 2021(2), DOI 10.46586/tches.v2021.i2.328-356 [2] | 1,579 | 1,058 | 3 | 2 | 448/448/256 | 161 | [재인용]. DOI는 검색으로 확인, TCHES 페이지는 봇 차단 |
| Dang, Mohajerani, Gaj, IEEE TC 2023 [5] (ePrint 2021/1508) | 880 | 999 | 1.5 | 2 | 448/448/256 | 222 | [재인용] |
| Zhang et al., ISCAS 2021 [4] | 609 | 640 | 4 | 2 | 490/490/- | 256 | [재인용]. ICASSP 2025 표에는 BRAM 2, 257 MHz, 1.9 us로 기재되어 두 2차 출처가 약간 다름 |
| Li et al., TCAD 2022 [7] | - | - | - | - | - | - | KiD가 "modular adder/subtractor가 오류값을 낼 수 있다"며 비교에서 제외 [재인용] |

참고: ICASSP 2025 Table II에는 TVLSI'24 Kyber NTT(Kintex US, 1,914 LUT, 3 DSP, 3 BRAM, 275 MHz)가 추가로 있으나 저자 미확인.

#### (c) 구조 유형과 reduction 방식 정리(위 확인/재인용 자료 기준)

| 분류 | 사례 | 비고 |
|---|---|---|
| iterative 단일/소수 butterfly | KiD(2 BFU), Xing-Li(2 BFU, NTT+PWM 공용), Zhang ISCAS21, Dang-Gaj | Artix-7에서 600~1,600 LUT, 2~4 DSP, 448 cycles 전후가 표준 |
| 다중 butterfly | Yaman DATE21(최대 16 BU), KiD unified 8 BFU(Kyber 112 cycles) | BU 수와 메모리 뱅킹이 핵심 |
| 완전 pipelined | PQShield R2MDC(ASHES 2024), Bertels 2025/1763(매 클럭 1 NTT) | 다중 벡터(ML-KEM k, ML-DSA l) 처리량에서 유리 |
| unified CT/GS 또는 NTT/INTT 공용 butterfly | Xing-Li, Yaman, Varandi 2026, PQShield(CT만으로 NTT/iNTT) | 사실상 기본 기법이 됨 |
| Barrett | ICASSP 2025, PQShield(Xing-Li 변형), Gimenez(SW 레퍼런스 그대로) | q=3329의 낮은 Hamming weight 활용 |
| Montgomery | KiD(71 LUT + 1 DSP) | |
| K-RED/K2-RED (Longa-Naehrig, q=k*2^m+1, 3329=13*2^8+1) | GMU FPT 2019(K-RED, K-RED-2x를 시프트-가산으로), Bertels FPL 2024(K-RED + LUT), Tosun 2024/1890(K2-RED-Shift, FHE 대상) | |
| 곱셈 없는 LUT/시프트-가산 | Bertels 2024/2025, Müller et al. arXiv 2308.15079(Barrett 대비 면적 약 60~90% 감소, Kyber/Dilithium) | |

#### (d) ASIC 결과(참고)

| 논문 | 공정 | 결과 | 확인 |
|---|---|---|---|
| Bisheh-Niasar et al.(Microsoft), "Adams Bridge (V2.0)", ePrint 2026/256 | 5 nm | 600 MHz, ML-KEM 단계 11/14/20 us, ML-DSA 26/61/31 us, AT 효율 ML-KEM 1.4x, ML-DSA 2.7x, masking/shuffling, TVLA 100만 trace | [확인] 초록 |
| Nabeel, Hafez, Maniatakos, "@NTT", ISCAS 2026 (arXiv 2601.17806) | TSMC 28 nm | 1.0 GHz, 1.45 mm². FPGA throughput-per-LUT 5.2x. 사례는 Dilithium NTT | [확인] 초록 |
| Dam et al., RISC-V RoCC NTT 가속기, MDPI Electronics 15(1):100 | 180 nm | 118 MHz, 면적 오버헤드 8.7% | [미확인] 403 |
| Banerjee et al., Sapphire, TCHES 2019 | TSMC 40 nm LP | 코어 0.28 mm² 등 | [미확인] 검색 요약만 |
| MMU 저장소의 "Evaluating NTT/INTT implementation styles" (28 nm ASIC + Virtex-7) | 28 nm | forward/inverse 분리 설계가 unified 대비 throughput/area 1.25x | [미확인] 403 |

### 2.2 HLS 기반 PQC 가속기와 RTL 대비 QoR 격차

| 논문 | HLS 툴 | 대상 | RTL 대비 정량 결과 | 확인 |
|---|---|---|---|---|
| Nguyen, Dang, Gaj, "A High-Level Synthesis Approach to the Software/Hardware Codesign of NTT-based PQC Algorithms", ICFPT 2019 | Vivado HLS(Vivado 2018.3로 구현) | 같은 NTT 구조를 RTL/HLS 양쪽으로. NewHope/FALCON(N=1024, q=12289), qTESLA, Dilithium. K-RED 사용. **Kyber 미포함** | Zynq US+: cycles, DSP, BRAM 동일. LUT 비 1.02~1.51, FF 1.02~1.58, slice 1.02~1.60, Fmax 0.96~0.97. Zynq-7000(N=1024): LUT 1.69, FF 2.41, slice 2.27, latency 1.04 | [확인] PDF 본문 Table II, III |
| Mert, Karabulut, Öztürk, Savaş, Aysu, "An Extensive Study of Flexible Design Methods for the NTT", IEEE TC, DOI 10.1109/TC.2020.3017930 | Vivado HLS | 파라메트릭 RTL 생성기 vs HLS vs RISC-V SW | Virtex-7에서 RTL이 HLS 대비 평균 4.4x 작고 22.5x 빠름. 설계 노력: RTL 생성기 약 450 man-hour, HLS 약 60 man-hour. PE 8개 초과 시 HLS 합성시간 급증, 개선 없음 | [확인] PDF 본문 |
| He, Kim (RIT), "A Survey on High-Level Synthesis Approaches for NTT on FPGAs" (NSF PAR 10629642, 2025 추정, 학회 미확인) | Vitis/Vivado HLS, Intel HLS, Catapult(NTTSuite), oneAPI | HLS NTT 설계 정리 | Nguyen-Dang-Gaj ARC 2020 기준 HLS/RTL 비 1.00~1.53 인용. 향후 과제로 NTT 전용 DSE 프레임워크, HLS 친화 코드 변환(ScaleHLS) 제시. Catapult 기반 사례는 FHE용 NTTSuite뿐이며 Kyber Catapult 사례 없음 | [확인] PDF 본문 |
| Basu, Soni, Nabeel, Karri, "NIST PQC: A Hardware Evaluation Study", ePrint 2019/047 | HLS(초록에 툴명 없음) | Round 1/2 후보 FPGA/ASIC | 초록에 수치 없음. PQC-HA 논문은 이 연구가 "HLS가 HDL 대비 자원과 성능 모두 열세"라고 결론냈다고 인용 | [확인] 초록 |
| Sattel, Spang, Heinz, Koch, "PQC-HA", arXiv 2308.06621 | TaPaSCo 기반 HLS | Kyber/Dilithium 전 보안 레벨, ANSI C 레퍼런스 거의 그대로 | off-chip 인터페이스 오버헤드만으로 AVX2 Kyber-512 SW 실행시간 초과 | [확인] 초록 |
| Gimenez et al., SBSeg 2026 | Vitis HLS | Kyber-768 다항식 연산, PYNQ-Z2 | RTL 비교 없음. 위 2.1(a) 수치 참조 | [확인] |
| Bisheh-Niasar et al., ePrint 2023/1038 | HLS(툴명 초록에 없음) | Kyber NTT/INTT | RTL 비교 언급 없음 | [확인] 초록 |
| Perera et al., "LLM4PQC", DATE 2026 (arXiv 2602.09919) | **Catapult HLS 2023.1_2** + C2HLSC | Kyber/Dilithium/Falcon NTT 등 | ASIC(Nangate 45, DC): Kyber-NTT 평균 2,957.54 um², latency는 신뢰 불가로 미보고. FPGA(Artix-7): LLM4PQC Kyber-NTT 146 LUT, 119 FF, 3 DSP, 1 BRAM, 75 MHz, 5,639 cycles(75 us) vs 기존 RTL 4,834 LUT, 0 DSP, 250 MHz, 277 cycles(1.11 us). 인간 HLS 기준선 없음 | [확인] HTML 본문 |
| Soni, Karri, ISVLSI 2021 / El-Kady et al., VLSI-SoC 2022 / Ozcan, Aysu, IEEE ESL 2019 | Vivado HLS | HLS NTT | He-Kim 서베이 표에 등장 | [재인용] |
| Siemens SLEC HLS (C-to-RTL 순차 등가성 검사) | Catapult 연동 | 일반 | 벤더 자료. 암호 사례 없음 | [미확인] 검색 요약만 |

### 2.3 ML-KEM + ML-DSA 통합(다중 modulus) 다항식 연산기

| 논문 | 통합 방식 | 결과 | 확인 |
|---|---|---|---|
| KiD (arXiv 2311.04581) | 23x12 DSP 2개로 Kyber 곱 2개 또는 Dilithium 곱 1개. 12번째 bit에서 carry 전파를 끊거나 잇는 공유 adder/subtractor. Kyber 2/4/8 BFU = Dilithium 1/2/4 BFU | ZCU102: 1,384 LUT, 2 DSP, 4.5 BRAM, 387 MHz, Kyber NTT 448 / Dilithium 1024 cycles. 4 BFU 구성 2,893 LUT, 4 DSP, 342 MHz | [확인] |
| Aikata et al., "KaLi", IEEE TCAS-I 70(2), 2023 | 4 Kyber BFU = 2 Dilithium BFU, Solinas 기반 통합 reduction | 3,487 LUT, 4 DSP, 270 MHz, Kyber NTT 224 cycles (KiD 표) | [재인용] |
| PQShield ASHES 2024 | 통합 modular reduction unit(Kyber Barrett 변형 + Dilithium Solinas), MDC 파이프라인 | 2.1(a) 참조 | [확인] |
| Shrivastava et al., ICASSP 2025 | FFT butterfly에 mod_kyber_mul, mod_dilithium_mul 추가 | 2.1(a) 참조 | [확인] |
| Adams Bridge V2.0 (ePrint 2026/256) | 두 스킴이 공유하는 NTT/INTT/PWM 엔진(초록 기준, modulus 처리 방식은 초록에 없음). Caliptra RoT용 | 2.1(d) 참조 | [확인] 초록 |
| Tosun et al., "RISQrypt", ePrint 2026/312 | RISC-V HW/SW co-design, masking 포함 통합 | masked ML-KEM-768 Decaps 약 109K cycles, masked ML-DSA-65 Sign 평균 약 1,230K cycles | [확인] 초록 |
| Park et al., arXiv 2609.04058 | ML-KEM-768 + ML-DSA-65 통합 가속기(Kintex-7 XC7K160T, slice 98.5%) | 2.5 참조 | [확인] 초록 |
| Nguyen et al., IEEE Access 2024, DOI 10.1109/ACCESS.2024.3371581 | radix-2/4 통합 pipelined NTT | Dilithium NTT 3.4~9.6x, Kyber 1.36~34.16x 개선 주장 | [미확인] 403 |
| CRYPHTOR (IEEE Access 2024), Dobias et al. (PeerJ CS 11:e2746, 2025), RECAPHE(Kyber+HE) | 메모리 통합 / Kyber+Dilithium 통합 / PQC+HE 통합 | | [미확인] 검색 요약만 |

### 2.4 NTT/모듈러 연산 HW의 formal/exhaustive 검증

| 논문 | 대상 | 방법 | HW 여부 | 확인 |
|---|---|---|---|---|
| Mahzoon, Große, Scholl, Konrad, Drechsler, "Formal Verification of Modular Multipliers using Symbolic Computer Algebra and Boolean Satisfiability", DAC 2022, DOI 10.1145/3489517.3530605 | 2^n-1, 2^n+1 모듈러 곱셈기(수백만 gate) | SCA(Gröbner) + SAT | 게이트 수준 HW. 일반 소수 modulus(3329)나 Barrett/Montgomery 구조는 다루지 않음. Montgomery 곱셈기는 theorem proving 기반 선행 연구가 있으나 자동화되지 않았다고 기술 | [확인] PDF 본문 |
| Hwang et al., "Verified NTT Multiplications for NISTPQC KEM Lattice Finalists", TCHES 2022(4), DOI 10.46586/tches.v2022.i4.718-750 | Kyber/Saber/NTRU NTT 곱셈 | CryptoLine 확장 | SW(AVX2, Cortex-M4 pqm4) | [확인] 아티팩트 페이지 |
| Almeida et al., "Formally verifying Kyber Episode IV", ePrint 2023/215 (TCHES 2023) | Kyber 전체 구현 | EasyCrypt 명세 + Jasmin 구현 기능 정확성 증명 | SW | [확인] 초록 |
| Iskander, Kirah, arXiv 2604.15249 | Adams Bridge masked NTT(117만 cell, 30개 masked 서브모듈), ML-KEM Barrett 모듈 5,543 cell | 구조적 의존성 분석 + SADC, Z3/CVC5 교차 검증. 363개 의심 wire 중 198개 1차 안전 증명 | HW, 단 **기능 정확성이 아니라 masking(probing) 보안성** | [확인] 초록 |
| Gimenez et al., SBSeg 2026 | ML-KEM HLS 가속기 | 연산별 random 10,000회 SW 비교 | HW, simulation/보드 비교 | [확인] |
| LLM4PQC | Catapult 산출 RTL | KAT 1,000개 시뮬레이션(ModelSim), formal 없음 | HW | [확인] |
| HOPE-MLKEM 아티팩트(Camacho-Ruiz et al., TCHES 2026) | ML-KEM 전체 RTL(1/2/4 BU, masked) | Verilator 시뮬, TVLA. formal 언급 없음 | HW, 오픈소스 | [확인] README |
| Park et al., arXiv 2609.04058 | ML-DSA 서명 | 표준 KAT가 BRAM latency 관련 결함을 놓침. golden oracle + random adversarial soak로 대체 | HW | [확인] 초록 |

탐색 결과: Kyber NTT 또는 q=3329 reduction RTL에 대한 기능 formal 검증(등가성 검사, 모델 체킹)을 보고한 논문은 찾지 못했다. 12-bit 입력 2개(2^24)인 모듈러 곱셈기는 exhaustive simulation으로 끝나므로 그 자체로는 기여가 아니다. 의미 있는 공백은 NTT 전체(256 계수 메모리 + 주소 생성 + twiddle 순서)의 등가성 증명이다.

### 2.5 LLM/agent 기반 RTL/HLS 설계 흐름(암호/산술 IP, 2024~2026)

| 논문 | 내용 | 정량 결과 | 확인 |
|---|---|---|---|
| Collini, Garg, Karri, "C2HLSC", LAD 2024 (arXiv 2406.09233) | LLM으로 C를 HLS 호환 C로 리팩터링. AES-128, NIST 800-22 등 | 초록에 수치 없음 | [확인] 초록 |
| Perera et al., "LLM4PQC", DATE 2026 | C2HLSC + Catapult, o3-mini, Kyber/Dilithium/Falcon | 2.2 참조. Kyber-NTT 성공률 100%, Falcon-Sampler 40% | [확인] |
| Liao, Adegbija, Lysecky, ISQED 2026 (arXiv 2602.09410) | LLM 기반 FALCON HW/SW co-design | human-in-the-loop LLM 가속기가 HLS 대비 kernel 최대 2.6x 빠름, 자원/전력 trade-off | [확인] 초록 |
| Park et al., "AI-Assisted Design of a PQC Accelerator: A Deployed-Silicon Case Study", arXiv 2609.04058 | agentic LLM으로 ML-KEM-768/ML-DSA-65 통합 가속기를 RTL부터 PCIe bring-up까지 | 232개 실험 기록, 전체 성공률 71.6%(문서/조사 77~85%, 합성/bring-up 50~53%). soak 779,945회 무결함 | [확인] 초록 |
| Collini et al., "Can Reasoning Models Reason about Hardware? An Agentic HLS Perspective", arXiv 2503.12721 | reasoning LLM 기반 HLS DSE agent | 초록에 수치 없음 | [확인] 초록 |
| Purini et al., "ArchXBench", MLCAD 2025 (arXiv 2508.06047) | 암호 포함 6단계 RTL 벤치마크 | 최고 o4-mini-high 30개 중 16개(Level 1~3), Level 4 이상 전 모델 실패 | [확인] 초록 |
| Zhao, "Machine-Checked Trust for Agent-Built Hardware", NeurIPS 2026 AI for Chip Design 워크숍 | LLM agent가 FP 연산기를 SystemVerilog로 만들고 Lean/SMT/exhaustive로 증명 | pipelined FMA 268 MHz, 2^96 입력 bit-exact 등가 | [확인] 초록 페이지 |
| Li et al., "FormalRTL", arXiv 2603.08738 | SW 참조 모델을 명세로 쓰는 multi-agent RTL 생성 + formal 등가성 검사 | 초록에 수치 없음 | [확인] 초록 |
| LLM-DSE (arXiv 2505.12188), Agent Factories for HLS (arXiv 2603.25719), floating-point SVA 생성 (arXiv 2512.06850), VERI-SURE (arXiv 2601.19747) | HLS DSE agent, 등 | | [미확인] 검색 요약만 |

## 3. 최근 2년(2025~2026) 동향

1. Kyber FPGA 구현은 "더 작은 곱셈기"(LUT 기반, DSP-free)와 "극단적 처리량"(매 클럭 NTT) 양 극단으로 이동했다(Bertels 2024/2025, Varandi 2026, @NTT 2026).
2. 단독 ML-KEM보다 ML-KEM+ML-DSA 통합, masking 포함 통합(RISQrypt, Adams Bridge V2.0, HOPE-MLKEM)이 주류가 되었다. 산업 오픈소스 IP(Caliptra Adams Bridge)와 TCHES 아티팩트(HOPE-MLKEM)가 공개되어 비교 기준선 확보가 쉬워졌다.
3. 검증 쪽 관심은 기능 정확성보다 side-channel(masking) 증명으로 이동했다(2604.15249, NeurIPS 2026 관련 masking 증명 논문은 검색 요약만 확인).
4. LLM/agent 기반 PQC HW 설계가 2026년에 본격 등장했다. 공통 관찰: agent 산출 QoR은 hand RTL보다 크게 뒤지고(LLM4PQC), HW 작업은 문서/조사보다 성공률이 낮으며(Park 2026), 신뢰는 시뮬레이션이 아닌 machine-checkable gate로 확보해야 한다는 주장이 늘고 있다(Zhao 2026, FormalRTL).
5. HLS 쪽은 툴 연구가 LLM 보조 DSE로 이동했고, ML-KEM에 대한 인간 설계 HLS vs RTL 통제 비교는 2019~2020년 이후 갱신되지 않았다.

## 4. 덜 다뤄진 지점과 실현 가능성

자원 가정: Zybo Z7-20(XC7Z020), Catapult HLS, Questa, Synopsys DC(사용자 승인 시), Vivado 합성은 사용자가 수행, 1인 + AI agent.

### G1. ML-KEM 다항식 연산의 RTL vs Catapult HLS 통제 비교(FPGA + ASIC)
- 근거: 같은 구조를 RTL/HLS로 비교한 연구는 GMU ICFPT 2019(Vivado HLS, FPGA만, Kyber 미포함)와 Mert TC(구조 상이, Virtex-7)뿐. Catapult + Kyber는 LLM 생성 사례(LLM4PQC)만 있고 인간 설계 기준선이 없다. ASIC 측 HLS vs RTL 수치는 찾지 못했다.
- 차별화 요소: (1) 7-layer incomplete NTT + basemul 포함, (2) 같은 RTL 컨트롤러에 데이터패스만 RTL/HLS 교체하는 통제 설계, (3) FPGA(XC7Z020)와 ASIC(DC) 동시, (4) 설계 노력(man-hour, agent 상호작용 수) 기록.
- 실현 가능성: **높음**. plan.md 구조와 일치한다. 위험: novelty가 "통제 비교" 자체에 있어 학회 등급은 중간(FPT/ISCAS/ISQED short, 또는 IEEE Access/Electronics 수준)으로 예상. DC 실행은 사용자 승인 필요, Vivado 결과는 사용자 실행에 의존. 기존 결과(GMU: LUT 1.02~1.69x, Mert: 4.4x)가 상충하므로 "격차가 어디서(reduction, 메모리 포트, 제어) 생기는가"를 분해하면 기여가 더 분명해진다.

### G2. q=3329 reduction 알고리즘 설계공간을 RTL/HLS, FPGA/ASIC 4개 조건에서 동시 비교
- 근거: Barrett, Montgomery, K2-RED, LUT 기반, Müller식 곱셈 없는 reduction이 각자 다른 논문, 다른 디바이스에서 보고되었고, 같은 라이브러리/같은 툴 조건의 head-to-head는 찾지 못했다. 특히 HLS가 시프트-가산 상수곱을 RTL만큼 잘 만드는지(@NTT는 툴에 맡기면 ASIC 10%, FPGA 20% 오버헤드라고 보고)는 열린 질문이다.
- 실현 가능성: **높음**. P2 단계 산출물로 바로 나온다. 2^24 exhaustive 검증도 가볍다. 단독 논문으로는 약하므로 G1의 한 장(section)으로 넣는 것을 권한다.

### G3. NTT 전체 데이터패스+컨트롤러의 formal 등가성 검증
- 근거: SW 쪽(CryptoLine, Jasmin)과 HW masking 보안성(2604.15249)은 있으나, Kyber NTT RTL의 기능 formal 검증은 찾지 못했다. Mahzoon DAC 2022도 2^n±1만 다룬다.
- 방법 후보: butterfly 단위 SMT/exhaustive + 주소/twiddle 시퀀스 formal + 전체는 C(golden)-RTL 순차 등가성(Catapult SLEC 라이선스가 있으면 HLS 쪽에 적용).
- 실현 가능성: **중간 이하**. SLEC/Questa Formal 라이선스 보유 여부가 미확인이며, 256x12-bit 메모리 상태 때문에 전체 증명은 상태 폭발 위험이 크다. 1인 프로젝트에서 "부분 증명 + 근거 있는 분해"까지는 가능하지만 완전 증명은 장담할 수 없다. 라이선스 확인 후 판단.

### G4. agent 보조 설계 흐름을 machine-checkable 수용 기준과 함께 정량 기록
- 근거: LLM4PQC는 agent가 HLS C를 만들었지만 QoR이 hand RTL보다 수십 배 느리다. Park 2026은 agent 성공률을 기록했지만 RTL vs HLS 비교나 formal gate는 없다. Zhao 2026은 FP 연산기 대상. "인간이 아키텍처를 정하고 agent가 RTL/HLS를 구현할 때 hand-SOTA 대비 QoR이 어디까지 오는가 + exhaustive/formal gate로 정확성 보장 + 작업 유형별 agent 성공률"을 암호 산술 IP로 보고한 사례는 찾지 못했다.
- 실현 가능성: **중간~높음**. 이 워크스페이스가 이미 agent 기반으로 운영되므로 로그 수집 비용이 낮다. 위험: 1인 사례 연구라 일반화가 약하고, 모델 버전 변화로 재현성이 떨어진다. 평가 지표(성공 정의, 개입 횟수)를 P2 시작 전에 고정해야 한다.

### G5. ML-KEM+ML-DSA 통합 butterfly(참고, 비추천)
- 근거: KaLi, KiD, PQShield, ICASSP 2025, Adams Bridge, RISQrypt로 이미 포화. 산업 IP까지 존재한다.
- 실현 가능성: 구현은 가능(중간)하지만 기여는 낮다. 하려면 "다중 modulus 모드 전환 데이터패스에서 HLS가 RTL 대비 얼마나 손해를 보는가"처럼 G1의 확장으로만 의미가 있다.

## 5. 참고문헌

표기: [확인] 원문 직접 확인, [재인용] 다른 확인 논문의 표/참고문헌을 통해서만 확인, [미확인] 검색 요약만.

### 확인 (32건)
1. [확인] J. Bertels, Q. Norga, I. Verbauwhede, "A Better Kyber Butterfly for FPGAs," FPL 2024. https://eprint.iacr.org/2024/1367
2. [확인] J. Bertels, I. Verbauwhede, "A High Throughput Kyber NTT," ePrint 2025/1763. https://eprint.iacr.org/2025/1763
3. [확인] S. Mandal, D. B. Roy, "KiD: A Hardware Design Framework Targeting Unified NTT Multiplication for CRYSTALS-Kyber and CRYSTALS-Dilithium on FPGA," arXiv 2311.04581 (VLSID 2024는 ICASSP 2025 표 기준). https://arxiv.org/abs/2311.04581
4. [확인] H. Naderi Varandi, R. Salarifard, "Efficient Polynomial Multiplier Architectures for ML-KEM on Resource-Constrained FPGAs," ePrint 2026/2726. https://eprint.iacr.org/2026/2726
5. [확인] M. Nabeel, M. Hafez, M. Maniatakos, "@NTT: Algorithm-Targeted NTT hardware acceleration via Design-Time Constant Optimization," ISCAS 2026, arXiv 2601.17806. https://arxiv.org/abs/2601.17806
6. [확인] D.-e-S. Kundi, J. M. Bermudo Mera, P.-Y. Strub, M. Hutter, "High-Performance NTT Hardware Accelerator to Support ML-KEM and ML-DSA," ASHES 2024. https://pqshield.com/publications/high-performance-ntt-hardware-accelerator-to-support-ml-kem-and-ml-dsa/
7. [확인] F. Yaman, A. C. Mert, E. Öztürk, E. Savaş, "A Hardware Accelerator for Polynomial Multiplication Operation of CRYSTALS-KYBER PQC Scheme," DATE 2021. https://eprint.iacr.org/2021/485
8. [확인] M. Bisheh-Niasar, D. Lo, A. Parthasarathy, B. Pelton, B. Pillilli, B. Kelly, "PQC Cloudization: Rapid Prototyping of Scalable NTT/INTT Architecture to Accelerate Kyber," ePrint 2023/1038 (PAINE 2023). https://eprint.iacr.org/2023/1038
9. [확인] R. Shrivastava, C. P. Ratnala, D. M. Puli, U. Banerjee, "A Unified Hardware Accelerator for Fast Fourier Transform and Number Theoretic Transform," ICASSP 2025, DOI 10.1109/ICASSP49660.2025.10889132. https://arxiv.org/abs/2504.11124
10. [확인] H. G. Gimenez, E. T. Midorikawa, F. V. de Almeida, T. B. Paiva, "An HLS-Based Hardware Accelerator for ML-KEM Polynomial Operations," SBSeg 2026 Anais Estendidos. https://sol.sbc.org.br/index.php/sbseg_estendido/article/download/44489/44252/
11. [확인] M. Bisheh-Niasar, E. Karabulut, K. Upadhyayula, M. Norris, B. Pillilli, "Adams Bridge (V2.0) Accelerator: Bridging the Post-Quantum Transition," ePrint 2026/256. https://eprint.iacr.org/2026/256
12. [확인] T. Tosun, A. U. Ay, M. Yazıcı, E. Savaş, Q. Norga, S. Kundu, I. Verbauwhede, "RISQrypt: Fast, Secure and Agile Hardware-Software Co-Design for Post-Quantum Cryptography," ePrint 2026/312. https://eprint.iacr.org/2026/312
13. [확인] T. Tosun, S. Kırbıyık, E. Koçer, E. Alaybeyoğlu, "Optimized FPGA Architecture for Modular Reduction in NTT," ePrint 2024/1890. https://eprint.iacr.org/2024/1890
14. [확인] R. Müller, W. Meier, C. F. Wildfeuer, "Area Efficient Modular Reduction in Hardware for Arbitrary Static Moduli," arXiv 2308.15079 (저널판 MDPI Cryptography 7(4):46은 미확인). https://arxiv.org/abs/2308.15079
15. [확인] D. T. Nguyen, V. B. Dang, K. Gaj, "A High-Level Synthesis Approach to the Software/Hardware Codesign of NTT-based Post-Quantum Cryptography Algorithms," ICFPT 2019. https://par.nsf.gov/servlets/purl/10174988
16. [확인] A. C. Mert, E. Karabulut, E. Öztürk, E. Savaş, A. Aysu, "An Extensive Study of Flexible Design Methods for the Number Theoretic Transform," IEEE Trans. Computers, DOI 10.1109/TC.2020.3017930. https://par.nsf.gov/servlets/purl/10208110
17. [확인] W. He, S. Kim, "A Survey on High-Level Synthesis Approaches for Number Theoretic Transform on FPGAs" (학회/연도 미확인). https://par.nsf.gov/servlets/purl/10629642
18. [확인] K. Basu, D. Soni, M. Nabeel, R. Karri, "NIST Post-Quantum Cryptography: A Hardware Evaluation Study," ePrint 2019/047. https://eprint.iacr.org/2019/047
19. [확인] R. Sattel, C. Spang, C. Heinz, A. Koch, "PQC-HA: A Framework for Prototyping and In-Hardware Evaluation of Post-Quantum Cryptography Hardware Accelerators," arXiv 2308.06621. https://arxiv.org/abs/2308.06621
20. [확인] B. Perera, Z. Wang, W. Xiao, M. Nabeel, O. Sinanoglu, J. Knechtel, R. Karri, "LLM4PQC: Accurate and Efficient Synthesis of PQC Cores by Feedback-Driven LLMs," DATE 2026, arXiv 2602.09919. https://arxiv.org/html/2602.09919v2
21. [확인] A. Mahzoon, D. Große, C. Scholl, A. Konrad, R. Drechsler, "Formal Verification of Modular Multipliers using Symbolic Computer Algebra and Boolean Satisfiability," DAC 2022, DOI 10.1145/3489517.3530605. https://agra.informatik.uni-bremen.de/doc/konf/Formal_Verification_of_Modular_Multipliers.pdf
22. [확인] V. Hwang, J. Liu, G. Seiler, X. Shi, M.-H. Tsai, B.-Y. Wang, B.-Y. Yang, "Verified NTT Multiplications for NISTPQC KEM Lattice Finalists: Kyber, Saber, and NTRU," TCHES 2022(4), DOI 10.46586/tches.v2022.i4.718-750. https://artifacts.iacr.org/tches/2022/a20/
23. [확인] J. B. Almeida et al., "Formally verifying Kyber Episode IV: Implementation Correctness," TCHES 2023, ePrint 2023/215. https://eprint.iacr.org/2023/215
24. [확인] R. Iskander, K. Kirah, "Structural Dependency Analysis for Masked NTT Hardware: Scalable Pre-Silicon Verification of Post-Quantum Cryptographic Accelerators," arXiv 2604.15249. https://arxiv.org/abs/2604.15249
25. [확인] E. Camacho-Ruiz et al.(전체 저자 미확인), "A Framework for Designing High-Order Side-Channel Protected Hardware Implementations of ML-KEM" (HOPE-MLKEM), TCHES 2026 아티팩트. https://artifacts.iacr.org/tches/2026/a21/readme.html
26. [확인] J. Park, E. Kim, W. Kim, S. Cho, B. Cha, "AI-Assisted Design of a Post-Quantum Cryptographic Accelerator: A Deployed-Silicon Case Study," arXiv 2609.04058. https://arxiv.org/abs/2609.04058
27. [확인] L. Collini, S. Garg, R. Karri, "C2HLSC: Can LLMs Bridge the Software-to-Hardware Design Gap?," LAD 2024, arXiv 2406.09233. https://arxiv.org/abs/2406.09233
28. [확인] L. Collini, A. Hennessee, R. Karri, S. Garg, "Can Reasoning Models Reason about Hardware? An Agentic HLS Perspective," arXiv 2503.12721. https://arxiv.org/abs/2503.12721
29. [확인] Y. Liao, T. Adegbija, R. Lysecky, "Accelerating Post-Quantum Cryptography via LLM-Driven Hardware-Software Co-Design," ISQED 2026, arXiv 2602.09410. https://arxiv.org/abs/2602.09410
30. [확인] S. Purini et al., "ArchXBench: A Complex Digital Systems Benchmark Suite for LLM Driven RTL Synthesis," MLCAD 2025, arXiv 2508.06047. https://arxiv.org/abs/2508.06047
31. [확인] S. Zhao, "Machine-Checked Trust for Agent-Built Hardware: LLM Agents Formally Verify Synthesizable Floating-Point Arithmetic," NeurIPS 2026 AI for Chip Design 워크숍. https://neurips.cc/virtual/2026/161628
32. [확인] K. Li et al., "FormalRTL: Verified RTL Synthesis at Scale," arXiv 2603.08738. https://arxiv.org/abs/2603.08738

### 재인용 (1차 원문 미열람, 수치는 KiD/ICASSP 2025/He-Kim 표 기준)
33. [재인용] Y. Xing, S. Li, "A Compact Hardware Implementation of CCA-Secure Key Exchange Mechanism CRYSTALS-KYBER on FPGA," TCHES 2021(2), DOI 10.46586/tches.v2021.i2.328-356. https://doi.org/10.46586/TCHES.V2021.I2.328-356
34. [재인용] M. Bisheh-Niasar, R. Azarderakhsh, M. Mozaffari-Kermani, "High-speed NTT-based polynomial multiplication accelerator for post-quantum cryptography," IEEE ARITH 2021. (URL 미확보, KiD 참고문헌 [3]) https://arxiv.org/pdf/2311.04581
35. [재인용] M. Bisheh-Niasar, R. Azarderakhsh, M. Mozaffari-Kermani, "Instruction-set accelerated implementation of CRYSTALS-Kyber," IEEE TCAS-I 68(11), 2021. (KiD 참고문헌 [17]) https://arxiv.org/pdf/2311.04581
36. [재인용] C. Zhang et al., "Towards efficient hardware implementation of NTT for Kyber on FPGAs," ISCAS 2021. (KiD [4], ICASSP 2025 [15]) https://arxiv.org/html/2504.11124v1
37. [재인용] V. B. Dang, K. Mohajerani, K. Gaj, "High-Speed Hardware Architectures and FPGA Benchmarking of CRYSTALS-Kyber, NTRU, and Saber," IEEE TC 72(2), 2023. https://eprint.iacr.org/2021/1508
38. [재인용] A. Aikata, A. C. Mert, M. Imran, S. Pagliarini, S. S. Roy, "KaLi: A Crystal for Post-Quantum Security Using Kyber and Dilithium," IEEE TCAS-I 70(2), 2023. (KiD [1]) https://arxiv.org/pdf/2311.04581
39. [재인용] M. Li, J. Tian, X. Hu, Z. Wang, "Reconfigurable and high-efficiency polynomial multiplication accelerator for CRYSTALS-Kyber," IEEE TCAD 2022. (KiD [7]) https://arxiv.org/pdf/2311.04581
40. [재인용] D. T. Nguyen, V. B. Dang, K. Gaj, "High-Level Synthesis in Implementing and Benchmarking NTT in Lattice-Based PQC Using Software/Hardware Codesign," ARC 2020, DOI 10.1007/978-3-030-44534-8_19. (He-Kim이 HLS/RTL 비 1.00~1.53 인용)
41. [재인용] P. Longa, M. Naehrig, "Speeding up the Number Theoretic Transform for Faster Ideal Lattice-Based Cryptography," CANS 2016. (K-RED 원전, GMU/He-Kim 참고문헌)
42. [재인용] D. Soni, R. Karri, "Efficient hardware implementation of PQC primitives and PQC algorithms using high-level synthesis," ISVLSI 2021. (He-Kim [22])
43. [재인용] E. Ozcan, A. Aysu, "High-level synthesis of number-theoretic transform: A case study for future cryptosystems," IEEE ESL 12(4), 2019. (He-Kim [16])
44. [재인용] J. Ding, Y. Liu, L. Sun, B. Reagen, "NTTSuite," arXiv 2405.11353 (Catapult HLS, FHE). (He-Kim [24])

### 미확인 (검색 결과 요약만, 원문 미열람)
45. [미확인] D. T. Nguyen et al. 등, "unified pipelined NTT/INTT architecture," IEEE Access 2024, DOI 10.1109/ACCESS.2024.3371581. https://doaj.org/article/6ff691237ea543ad8c72bd40500075be
46. [미확인] Dobias et al., "Efficient unified architecture for post-quantum cryptography: combining Dilithium and Kyber," PeerJ CS 11:e2746, 2025. https://peerj.com/articles/cs-2746
47. [미확인] CRYPHTOR, IEEE Access 2024. https://doaj.org/article/7cb28f5139824390b363c331df9ecfa2
48. [미확인] RECAPHE (Kyber + HE 통합 가속기). https://par.nsf.gov/servlets/purl/10674498
49. [미확인] Dam et al., RISC-V RoCC dual-butterfly NTT 가속기(180 nm), MDPI Electronics 15(1):100, 2026. https://www.mdpi.com/2079-9292/15/1/100
50. [미확인] Sonbul et al., 시프트-가산 reduction NTT(Artix-7), Preprints 202504.2368. https://www.preprints.org/manuscript/202504.2368
51. [미확인] A. Alhassani, RNS 기반 ML-KEM NTT 곱셈기 박사논문(Sheffield). https://etheses.whiterose.ac.uk/id/eprint/38249/
52. [미확인] U. Banerjee et al., Sapphire lattice crypto-processor(40 nm), TCHES 2019. https://tches.iacr.org/index.php/TCHES/article/download/8344/7692
53. [미확인] "Evaluating NTT/INTT implementation styles for post-quantum cryptography"(28 nm ASIC + Virtex-7). https://repository.mmu.ac.uk/articles/journal_contribution/Evaluating_NTT_INTT_implementation_styles_for_post-quantum_cryptography/32489487
54. [미확인] LLM-DSE, arXiv 2505.12188. https://arxiv.org/abs/2505.12188
55. [미확인] Agent Factories for High Level Synthesis, arXiv 2603.25719. https://www.alphaxiv.org/abs/2603.25719.md
56. [미확인] LLM 기반 IEEE-754 SVA 생성, arXiv 2512.06850. https://arxiv.org/html/2512.06850v1
57. [미확인] VERI-SURE, arXiv 2601.19747. https://arxiv.org/pdf/2601.19747
58. [미확인] Siemens, "Formally ensuring equivalence between C and RTL designs" (SLEC HLS 백서). https://resources.sw.siemens.com/en-GB/white-paper-formally-ensuring-equivalence-between-c-and-rtl-designs/

## 6. 조사하지 못한 부분
- TCHES 사이트(tches.iacr.org)와 일부 미러가 봇 차단되어 Xing-Li 등 TCHES 원문 표를 직접 보지 못했다. ePrint PDF 일부(2024/1367 등), MDPI, PeerJ, Preprints.org는 403.
- Bertels FPL 2024의 디바이스/주파수, Varandi 2026/2726의 수치, Yaman DATE 2021의 자원 수치는 초록에 없어 미기재.
- Kyber/ML-KEM ASIC NTT의 같은 공정 비교표(um², GE)는 확보하지 못했다.
- Catapult 사용 PQC 연구는 LLM4PQC와 NTTSuite(FHE) 외에는 찾지 못했다. Catapult 내부 사례(Siemens 고객 사례)는 공개 자료로 확인 불가.
- HLS 산출 RTL에 대한 SLEC 같은 C-RTL formal 등가성 검사를 NTT에 적용한 공개 사례는 찾지 못했다(부재 증명이 아님).
