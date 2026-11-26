# Log: nand-ecc-subsystem

## 2026-11-25: 프로젝트 시작  [notion: pending]
- `todo/`의 brief와 서베이를 `progress/nand-ecc-subsystem/docs/`로 옮기고 로드맵(`plan.md`)을 만듦.
- 결정(오케스트레이터): `llm-pim-soc`와 `pqc-ntt-ip`가 사용자 보드 실행을 기다리는 동안 병행한다. 근거: 프로젝트 순서는 2026-11-18 사용자 결정(llm-pim-soc 다음 nand-ecc-subsystem), 앞 프로젝트에 시뮬레이션으로 남은 일이 없음.
- 서베이 요약과 잠정 결정은 `brief.md` "사전 조사" 절.
- 다음: N1(범위와 시스템 스펙).

## 2026-11-25: N1 범위와 시스템 스펙 (G0)  [notion: pending]
- 한 일(hw-worker): `spec/code.md`와 code 구성/검증 스크립트(`model/tools/gen.py`, `chk.py`, `qclib.py`), shift 표 3개(`model/code/`: 주 code Z 128, 축소판 Z 32, 4x12 Z 8). `spec/channel.md`(MLC 해석 모델, 3D TLC fit 표, soft read와 LLR LUT, 정수 표 기반 난수). `spec/scope.md`(C 구성, decoder 형식 후보, IP 분할, 인터페이스, 자원 계산, test data, 측정 계획, 열린 결정 23개). `spec/s1calc.py`.
- 결과 [측정, 수퍼바이저 재실행 `chk.py`]: 주 code (9216, 8192), 8 x 72 base, Z 128: 4-cycle 0, girth 6(6-cycle 54,528), GF(2) rank 1024, rate 0.8889, random 정보 1,000개 encoding 후 H c = 0 1,000/1,000, 한 bit 뒤집기 검출 1,000/1,000, layer 안 열 충돌 없음. 축소판 2개도 PASS.
- agent 보고: seed 1~32 탐색에서 base 6-cycle 426이 최소(seed 20). 같은 base의 Z 16은 구성 실패(존재 불가 증명은 아님). 재현성 확인(sha256 일치).
- [계산, 100 MHz 가정, 합성 전]: iteration당 273 cycle(열 순서를 읽기/쓰기로 나눠 stall 0), 10 iteration 2,771 cycle = 정보 296 Mbps. BRAM36 42/140. LUT는 [추정] 시스템 27k~40k. BCH 비교 기준 GF(2^14), t = 73, (9207, 8192). PL 채널 에뮬레이터 36k~87k codeword/s.
- 결정(오케스트레이터): 열린 결정 23개를 권고대로 확정(`spec/scope.md` 10절). girth 6은 조건부 수용(N2 FER에서 error floor가 1e-5 위에 보이면 code 구성을 다시 연다).
- 미확인: 이 code의 최소 거리와 trapping set, FER(아직 한 번도 돌리지 않음), TLC fit 표의 다른 P/E·retention 격자 값(서베이에 없음), 외부 파일의 재배포 조건, 자원 수치 전부(합성 전).
- 다음: N2(C 전체 구현, G1).
