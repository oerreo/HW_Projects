# Log: nand-ecc-subsystem

## 2026-11-25: 프로젝트 시작  [notion: synced]
- `todo/`의 brief와 서베이를 `progress/nand-ecc-subsystem/docs/`로 옮기고 로드맵(`plan.md`)을 만듦.
- 결정(오케스트레이터): `llm-pim-soc`와 `pqc-ntt-ip`가 사용자 보드 실행을 기다리는 동안 병행한다. 근거: 프로젝트 순서는 2026-11-18 사용자 결정(llm-pim-soc 다음 nand-ecc-subsystem), 앞 프로젝트에 시뮬레이션으로 남은 일이 없음.
- 서베이 요약과 잠정 결정은 `brief.md` "사전 조사" 절.
- 다음: N1(범위와 시스템 스펙).

## 2026-11-25: N1 범위와 시스템 스펙 (G0)  [notion: synced]
- 한 일(hw-worker): `spec/code.md`와 code 구성/검증 스크립트(`model/tools/gen.py`, `chk.py`, `qclib.py`), shift 표 3개(`model/code/`: 주 code Z 128, 축소판 Z 32, 4x12 Z 8). `spec/channel.md`(MLC 해석 모델, 3D TLC fit 표, soft read와 LLR LUT, 정수 표 기반 난수). `spec/scope.md`(C 구성, decoder 형식 후보, IP 분할, 인터페이스, 자원 계산, test data, 측정 계획, 열린 결정 23개). `spec/s1calc.py`.
- 결과 [측정, 수퍼바이저 재실행 `chk.py`]: 주 code (9216, 8192), 8 x 72 base, Z 128: 4-cycle 0, girth 6(6-cycle 54,528), GF(2) rank 1024, rate 0.8889, random 정보 1,000개 encoding 후 H c = 0 1,000/1,000, 한 bit 뒤집기 검출 1,000/1,000, layer 안 열 충돌 없음. 축소판 2개도 PASS.
- agent 보고: seed 1~32 탐색에서 base 6-cycle 426이 최소(seed 20). 같은 base의 Z 16은 구성 실패(존재 불가 증명은 아님). 재현성 확인(sha256 일치).
- [계산, 100 MHz 가정, 합성 전]: iteration당 273 cycle(열 순서를 읽기/쓰기로 나눠 stall 0), 10 iteration 2,771 cycle = 정보 296 Mbps. BRAM36 42/140. LUT는 [추정] 시스템 27k~40k. BCH 비교 기준 GF(2^14), t = 73, (9207, 8192). PL 채널 에뮬레이터 36k~87k codeword/s.
- 결정(오케스트레이터): 열린 결정 23개를 권고대로 확정(`spec/scope.md` 11절). girth 6은 조건부 수용(N2 FER에서 error floor가 1e-5 위에 보이면 code 구성을 다시 연다).
- 미확인: 이 code의 최소 거리와 trapping set, FER(아직 한 번도 돌리지 않음), TLC fit 표의 다른 P/E·retention 격자 값(서베이에 없음), 외부 파일의 재배포 조건, 자원 수치 전부(합성 전).
- 다음: N2(C 전체 구현, G1).

## 2026-11-27: N2 C 전체 구현 (G1)  [notion: pending]
- 한 일(hw-worker): `model/src`(code loader, encoder, 채널 모델 TLC/MLC, 감지, LLR, float 참조 decoder(SPA flooding/layered, NMS/OMS), 고정소수점 layered min-sum, BCH GF(2^14) t 73, read retry 정책), FER 시뮬레이터와 도구, `docs/spec/numeric.md`(고정소수점 bit-exact 규칙), `docs/spec/n2_results.md`, `data/`(받는 스크립트, checksum, 문헌 parameter 표).
- 결과 [측정, 수퍼바이저 재실행]: `make test` 49항목 failed 0, 결정성 PASS(checkpoint 재시작 포함), 고정소수점 C 대 독립 Python 구현의 kernel 경계 값 대조 8구성 mismatch 0.
- 외부 기준 비교(agent 보고, `n2_results.md`): 802.3an (2048,1723)과 CCSDS C2 (8176,7156)를 같은 decoder로 복호해 오픈소스 참조 구현(직접 빌드)과 공개 참조 곡선에 비교. 비교 약 25개가 통계 오차 안. 4.0 dB 부근(FER 1e-4~1e-5)의 차이는 모두 이 구현이 약간 좋은 방향(z -1.1~-2.2)이며 원인은 확인하지 않음.
- 자체 code FER(agent 보고): AWGN 3.8 dB 5.4e-3, 4.0 dB 1.4e-5(오류 1개). NAND(TLC fit, P/E 3000, 30일, LSB page, (6,7,8)): FER 1e-2가 되는 raw BER이 hard 7.2e-3, +2 1.05e-2, +4 1.35e-2, +6 1.55e-2. raw BER 5.43e-3에서 BCH 7.2e-4 대 LDPC hard 2.6e-5(오류 2개). 낮은 FER 점은 오류 수가 50개 기준에 못 미침(0~22개).
- 발견: 고정소수점 (6,6,8)과 (5,6,7)은 FER이 2e-3~1e-2에서 내려가지 않고 undetected 오류가 다수(AWGN 4.2 dB에서 오류 961개 중 591개). (6,7,8)은 같은 조건에서 오류 0. C와 Python이 그 frame에서도 값 단위로 같아 구현 오류가 아니라 포화 규칙의 성질로 판단. 메커니즘은 미분석.
- 결정(오케스트레이터): 형식 후보를 w_m = w_ch + 1, w_a = w_m + 1로 변경, 기본 (6,7,8). undetected 수를 평가 지표에 추가. 메커니즘 분석을 N2b에 포함(`spec/scope.md` 결정 추가).
- 프로파일 [측정, PC]: hard 0.75 ms/codeword(decoder 84%), +6 soft 1.79 ms(decoder 94%). BCH 복호 0.89 ms.
- 미확인: FER 1e-5 아래(error floor), MLC 모델과 MSB/CSB page의 곡선, read retry 정책의 곡선, 참조 구현과의 frame 단위 비교, 외부 파일의 재배포 조건(저장소에 넣지 않음).
- 기록상 주의: N2 파일 대부분은 검수 전에 문서 커밋 `ddcc0d9`에 함께 들어갔다(오케스트레이터가 `git add -A`로 범위를 넓게 잡은 실수). 검수는 이 항목의 재실행으로 사후에 했다. 함께 들어간 `__pycache__`는 제거.
- 다음: N2b(형식 평가와 (6,6) 불안정 분석), N3(ARM baseline).
