# 마이크로아키텍처 스펙: pqc-ntt-ip v1

확정일 2026-11-16 (P1-c). 근거: `docs/survey/survey.md`, golden model(`model/`) 검증 결과.
모듈 트리와 L0 포트는 `hierarchy.md`. 이 문서는 L1 이상의 구조 결정을 고정한다.

## 설계 원칙
논문의 주제가 "같은 구조에서 데이터패스만 바꾼 통제 비교"이므로, v1은 성능 기록이 아니라 **비교의 공정성과 단순성**을 우선한다.
- 컨트롤러, 메모리, 인터페이스는 모든 변형에서 동일한 RTL.
- 바뀌는 것은 `bfu` 이하(L1, L0)뿐: reduction 4종 x 구현 방식 2종(RTL, HLS).
- IP의 외부 계약은 변형과 무관하게 동일: 모든 모드의 출력이 FIPS 203 Algorithm 9, 10, 11과 bit-exact로 일치하고 canonical [0, q)이다. Montgomery나 K2-RED의 스케일 인자는 IP 밖으로 새지 않는다.

## 결정 사항
| 항목 | 결정 | 근거 |
|---|---|---|
| butterfly 수 | 1개 (iterative) | 통제 비교에 충분. 다중 butterfly는 후속 확장 |
| 메모리 | TDP RAM 2개(`bank0`, `bank1`), 각 256 x 12b. NTT/INTT는 layer마다 ping-pong | 한 cycle에 read 2 + write 2가 필요. bank를 나누면 read/write 주소 충돌과 forwarding이 없어 컨트롤러가 단순하고 `bfu` latency에 독립 |
| layer 경계 | 한 layer의 마지막 write가 끝난 뒤 다음 layer read 시작 (`bfu` LATENCY만큼 대기) | hazard 제거. 대기 cycle 수는 LATENCY에서 자동 계산 |
| INTT 스케일 1/128 | GS butterfly의 두 출력에 `mod_half`를 넣어 layer마다 1/2 (7 layer = 1/128) | 별도 스케일 pass(256 cycle)와 상수 곱 제거 |
| `bfu` 모드 | `CT`: x = a + b*z, y = a - b*z / `GS`: x = (a + b)/2, y = (b - a)*z/2 | 곱셈기 1개, `mod_add` 1개, `mod_sub` 1개, `mod_half` 2개를 공유 |
| basemul | 전용 데이터패스 없이 `bfu`의 `CT` 모드를 micro-op으로 반복 사용. z 입력을 ROM 또는 데이터에서 선택 | 곱셈기를 추가하지 않는다. 시퀀스는 `ntt_ctrl`(RTL)이 담당 |
| 스케일 보정 | twiddle ROM은 변형별로 사전 보정된 값을 저장. basemul은 변형별 micro-op 시퀀스로 보정 | 아래 "basemul 시퀀스" |
| 결과 위치 | NTT/INTT는 7 layer(홀수)이므로 입력 bank의 반대 bank에 결과. basemul은 a가 있던 bank0에 결과 | 컨트롤러가 결과 bank를 status로 알린다 |

## bfu 인터페이스
```
parameter ALGO   : BARRETT | MONT12 | SHIFTADD | K2RED
parameter PRE_REG, MUL_REG, RED_PIPE, OUT_REG, SHARE_ADDSUB  (LATENCY는 localparam으로 노출, "bfu 파이프라인" 절)
input  mode_i    : CT | GS
input  a_i, b_i, z_i [11:0], valid_i
output x_o, y_o [11:0], valid_o      (고정 LATENCY, backpressure 없음)
```
- 곱셈 결과의 의미: `mul(b, z)` = b * z * S mod q. S는 ALGO별 스케일 (BARRETT, SHIFTADD: 1 / MONT12: 2^-12 / K2RED: 169).
- z가 ROM에서 올 때는 ROM 값이 S^-1로 사전 보정되어 있으므로 결과는 정확한 b * zeta이다.
- HLS판 `bfu`는 같은 포트, 같은 의미를 가진다. LATENCY만 다를 수 있다.

## 정정 (2026-11-16, P2-0 검증 결과)
- GS의 뺄셈 순서는 `b - a`다. 초안의 `a - b`는 틀렸다: FIPS 203 Algorithm 10은 `f[j+len] = zeta * (f[j+len] - t)`이고, 단일 zeta ROM과 Algorithm 10 순서에서 `a - b`를 쓰면 layer마다 홀수 출력의 부호가 뒤집힌다(golden model 변이 M7: INTT 4 ALGO와 외부 벡터 1800/1800 mismatch).
- 채택: `bfu`가 GS 모드에서 `mod_sub`에 (b, a) 순서로 넣는다. `mod_sub`의 입력은 CT(곱셈 뒤 a - t)와 GS(곱셈 앞 b - a)에서 어차피 다른 신호를 받으므로 mux 구성에 추가 비용이 사실상 없다. 대안(컨트롤러가 read 포트를 맞바꿈, INTT용 부호 반전 ROM)은 `ntt_ctrl` trace의 주소 의미가 모드에 따라 달라지거나 ROM이 늘어나서 택하지 않았다.
- basemul 5 op / 7 op 시퀀스는 golden model에서 4 ALGO 모두 FIPS 203 Algorithm 11과 일치함을 확인했다(random 2,000쌍 + 경계 36쌍 + 외부 2,145쌍).
- ALGO 인코딩: 0 `BARRETT`, 1 `MONT12`, 2 `SHIFTADD`, 3 `K2RED`. mode: 0 `CT`, 1 `GS`. `mlkem_pkg.sv`에 enum으로 고정하고 DPI 인자와 같은 값을 쓴다(golden model의 기존 `mul_kind` 인코딩과 다르므로 섞어 쓰지 않는다).
- 보정 상수(golden model 실측): MONT12는 S = 2704, S^-1 = 767, K2 = 2385. K2RED는 S = 169, S^-1 = 2285, K2 = 1353.

## bfu 파이프라인 (2026-11-16, P2-3 결과 반영)
- parameter: `PRE_REG`(0..1), `MUL_REG`(0..1), `RED_PIPE`(0..2), `OUT_REG`(0..1). `LATENCY = PRE_REG + MUL_REG + RED_PIPE + OUT_REG`, CT와 GS에서 동일.
- 단계 구성:
  1. pre 단: GS의 `s = a + b`, `d = b - a` 계산(CT는 통과). `PRE_REG`가 그 뒤 레지스터.
  2. mul 단: `mod_mul`(`MUL_REG`, `RED_PIPE`). 피연산자는 CT (b, z), GS (d, z). 곱을 거치지 않는 신호(CT의 a, GS의 s)는 `mod_mul.LATENCY`만큼 지연선으로 맞춘다.
  3. post 단: CT `x = a + t`, `y = a - t` / GS `x = half(s)`, `y = half(m)`. `OUT_REG`가 출력 레지스터.
- `mod_add`, `mod_sub` 공유 (2026-11-16 P3-1 결과로 정정): 초안의 "한 쌍 공유"는 무조건 성립하지 않는다. GS는 pre 단(입력 cycle c), CT는 post 단(cycle c + D, D = `PRE_REG + MUL_REG + RED_PIPE`)에서 쓰므로, CT 입력 뒤 정확히 D cycle 후에 GS 입력이 오면 충돌하고, D = 0이면 조합 루프가 된다.
  - `SHARE_ADDSUB = 0` (기본): pre 용과 post 용을 따로 둔다(`mod_add` 2, `mod_sub` 2). 입력 순서에 제약이 없다.
  - `SHARE_ADDSUB = 1` (선택): 한 쌍 공유 + 12b 2:1 mux 4개. D >= 1 필요. CT에서 GS로 바뀔 때 LATENCY 이상 비워야 한다(`L1_SHARE` assertion). NTT, INTT, BASEMUL은 각각 한 mode만 쓰므로 op 경계에서만 대기하면 된다.
  - v1 `ntt_core`는 op 경계에서 항상 LATENCY 이상 대기하도록 만들어 두 설정 모두 쓸 수 있게 하고, 면적 차이는 QoR 측정(P6)에서 두 설정을 모두 재서 보고한다.
- z와 mode는 데이터와 같은 지연을 따라간다. bfu 입력 a, b, z는 모두 canonical [0, q)여야 한다(`mod_mul`의 MONT12 정의역 보장 전제).
- 하위 L0 인스턴스의 `PIPE`는 0으로 두고 bfu가 직접 단 사이 레지스터를 둔다(절단 위치를 bfu 한 곳에서 관리).

## 회귀 구성
- `./sim/run.sh quick`: 모듈당 필수 구성만(조합 전부, 대표 1단, 최대 단수). 상위 계층 작업 중 반복 실행용.
- `./sim/run.sh all`: 전체 조합. 마일스톤 통과 판정과 커밋 전에 실행. 2026-11-16 기준 68 run, 약 450초.

## basemul 데이터패스 요구 (ntt_ctrl)
- 쌍 시작 시 a0, a1, b0, b1을 operand 레지스터(12b x 4)에 latch한다. op마다 RAM을 다시 읽으면 c0를 쓴 뒤 a0를 읽는 RAW hazard가 생긴다.
- 임시 레지스터: S = 1은 1개(R0), S != 1은 2개(R0, R1).
- bfu 호출 수: NTT 896, INTT 896, BASEMUL 640(S = 1) 또는 896(S != 1).

## basemul 시퀀스 (계수 쌍 하나, `CT` 모드의 x 출력만 사용)
입력 (a0, a1), (b0, b1), gamma. 목표: c0 = a0*b0 + a1*b1*gamma, c1 = a0*b1 + a1*b0 (FIPS 203 Algorithm 12).

S = 1 (BARRETT, SHIFTADD), 5 op:
```
t  = CT(0,  a1, b1)
p  = CT(0,  t,  gamma)
c0 = CT(p,  a0, b0)
u  = CT(0,  a0, b1)
c1 = CT(u,  a1, b0)
```
S != 1 (MONT12, K2RED), 7 op. 데이터끼리의 곱에는 S가 남으므로 ROM 상수 K2 = S^-2 로 보정한다 (gamma도 S^-2로 저장한 `gamma2` 사용):
```
t  = CT(0,  a1, b1)        = a1*b1*S
p  = CT(0,  t,  gamma2)    = a1*b1*gamma
v  = CT(0,  a0, b0)        = a0*b0*S
c0 = CT(p,  v,  K2)        = a1*b1*gamma + a0*b0
u  = CT(0,  a0, b1)        = a0*b1*S
w  = CT(u,  a1, b0)        = (a0*b1 + a1*b0)*S
c1 = CT(0,  w,  K2)        = a0*b1 + a1*b0
```
- 이 2 op의 차이가 "Montgomery/K2-RED를 canonical 계약의 IP에 넣을 때의 시스템 비용"이며, 비교 결과에 그대로 보고한다.
- golden model에 이 시퀀스를 모델링한 `multiply_ntts`(MONT12, K2RED)를 추가하고 기준 구현과 일치함을 먼저 확인한다 (P2 선행 작업).
- v1 컨트롤러는 쌍 단위로 순차 실행한다. op 간 파이프라인 중첩은 후속 최적화.

## 동작 모드와 예상 cycle (LATENCY = L)
| 모드 | 내용 | cycle (근사) |
|---|---|---|
| LOAD | AXI4-Stream에서 256 계수를 지정 bank에 기록 | 256 |
| NTT | 7 layer x 128 butterfly, ping-pong | 7 * (128 + L) |
| INTT | 위와 동일, GS 모드 | 7 * (128 + L) |
| BASEMUL | 128 쌍 x (5 또는 7 op) | 128 * ops * (L + 1) 이하 |
| UNLOAD | 결과 bank에서 256 계수를 AXI4-Stream으로 출력 | 256 |

수치는 설계 목표가 아니라 구조에서 나오는 값이다. 실제 값은 시뮬레이션으로 측정해 기록한다.

## 주소와 zeta 순서
- NTT: FIPS 203 Algorithm 9의 순서 그대로 (len = 128 .. 2, zeta index 1부터 증가).
- INTT: Algorithm 10의 순서 (len = 2 .. 128, zeta index 127부터 감소).
- `ntt_ctrl`의 (read 주소 2개, zeta 주소, mode) 시퀀스는 golden model의 butterfly trace 덤프와 비교해 검증한다.

## CSR (AXI4-Lite, L4)과 스트림은 P5에서 확정
지금 고정하는 것은 `ntt_core`의 로컬 인터페이스뿐이다: `start_i`, `op_i`(LOAD0, LOAD1, NTT, INTT, BASEMUL, UNLOAD), `bank_i`, `busy_o`, `done_o`, `result_bank_o`, 계수 입력 valid/ready, 계수 출력 valid/ready.

## 비교 실험 매트릭스 (논문용)
| 축 | 값 |
|---|---|
| reduction | BARRETT, MONT12, SHIFTADD, K2RED |
| 구현 | hand RTL, Catapult HLS |
| 단위 | `mod_red`/`mod_mul` 단독, `bfu`, `ntt_core` 전체 |
| 타깃 | FPGA XC7Z020 (사용자 Vivado), ASIC (DC, 사용자 승인 시) |
| 지표 | 면적(LUT/FF/DSP 또는 um^2), Fmax 또는 slack, latency(cycle), NTT/INTT/BASEMUL 총 cycle, 설계 노력(`agent-metrics.md`) |

## v1에서 하지 않는 것
다중 butterfly, lazy reduction, basemul op 중첩, Karatsuba basemul, side-channel 대응, ML-DSA modulus. 필요하면 `todo/`가 아니라 이 프로젝트의 P4에서 검토한다.
