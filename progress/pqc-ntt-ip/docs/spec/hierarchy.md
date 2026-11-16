# 계층 구조: pqc-ntt-ip

상태: 확정 (2026-11-16). L1 이상의 구조 결정은 `arch.md`가 원본이다. reduction 변형 이름은 `BARRETT`, `MONT12`, `SHIFTADD`, `K2RED`로 통일한다.

## 트리
```
L4  pqc_ntt_axi_top            AXI4-Lite(CSR) + AXI4-Stream(in/out) wrapper          RTL
      L3  ntt_core             NTT / INTT / basemul 모드, start/done, 계수 스트림    RTL (구조)
            L2  ntt_ctrl       layer/group/index 스케줄 FSM, 주소와 zeta 주소 생성   RTL
            L2  zeta_rom       zeta, gamma 테이블 (golden model에서 생성)            RTL
            L2  coef_ram       dual-port RAM wrapper (추론형, FPGA/ASIC 교체 지점)   RTL
            L1  bfu            unified butterfly (CT / GS / basemul 보조)            RTL + HLS
                  L0  mod_add        (a + b) mod q
                  L0  mod_sub        (a - b) mod q
                  L0  mod_mul        a * b mod q = 곱셈기 + mod_red
                        L0  mod_red  24-bit 이하 입력을 [0, q)로 reduction           RTL 4종 + HLS
                  L0  mod_half       x * 2^-1 mod q = (x >> 1) + (x[0] ? 1665 : 0), GS 출력 2곳에 사용
```

## 진행 순서 (bottom-up)
| 순서 | 모듈 | 계층 | 구현 | 검증 방식 | 통과 기준 |
|---|---|---|---|---|---|
| 1 | `mod_add`, `mod_sub`, `mod_half` | L0 | RTL | exhaustive, a,b in [0,q) 전체 q^2 (`mod_half`는 q개) | mismatch 0 |
| 2 | `mod_red` 4종 (`BARRETT`, `MONT12`, `SHIFTADD`, `K2RED`) | L0 | RTL | 각 변형의 정의역 전체 exhaustive | mismatch 0 |
| 3 | `mod_mul` | L0 | RTL | exhaustive q^2, reduction 변형별 | mismatch 0 |
| 4 | `mod_red`, `mod_mul` HLS판 | L0 | Catapult | 같은 벡터, 같은 TB | mismatch 0 |
| 5 | `bfu` | L1 | RTL, HLS | random + 경계, golden butterfly 덤프 대비 | mismatch 0 |
| 6 | `zeta_rom`, `coef_ram`, `ntt_ctrl` | L2 | RTL | 주소 시퀀스를 golden의 접근 순서 덤프와 비교 | mismatch 0 |
| 7 | `ntt_core` | L3 | RTL | 다항식 단위 벡터(외부 데이터 포함), stall random | mismatch 0 |
| 8 | `pqc_ntt_axi_top` | L4 | RTL | AXI BFM, 다항식 단위 벡터 | mismatch 0 |

순서 1~4가 로드맵 P2, 5~7이 P3, 8이 P5에 해당한다.

## L0 인터페이스 (고정)
공통: `clk`, `rst_n`, 계수 폭 `COEF_W = 12`, `Q = 3329`. 모든 계수 입출력은 canonical [0, Q).
L0은 valid/ready 없이 `valid_i`와 고정 latency의 `valid_o`만 갖는다(backpressure 없음, 상위 `ntt_ctrl`이 스케줄 보장).
각 모듈은 `parameter int PIPE` 로 내부 레지스터 단수를 정하고 `localparam int LATENCY` 를 노출한다. `PIPE = 0`이면 조합 로직.

| 모듈 | 입력 | 출력 | 비고 |
|---|---|---|---|
| `mod_add` | `a_i[11:0]`, `b_i[11:0]`, `valid_i` | `sum_o[11:0]`, `valid_o` | 조건부 감산 1회 |
| `mod_sub` | `a_i[11:0]`, `b_i[11:0]`, `valid_i` | `diff_o[11:0]`, `valid_o` | 조건부 가산 1회 |
| `mod_red` | `x_i[23:0]`, `valid_i` | `r_o[11:0]`, `valid_o` | `parameter ALGO`. 변형별 허용 입력 범위는 golden model 주석과 일치시킨다. 출력은 x * S mod q (S = 1, 2^-12, 1, 169)이며 래퍼는 S를 제거하지 않는다. 보정은 `arch.md`의 ROM 사전 보정과 basemul K2 op이 담당. PIPE 0~2 지원 |
| `mod_half` | `x_i[11:0]`, `valid_i` | `h_o[11:0]`, `valid_o` | 가산 1회, 2 * h_o mod Q == x_i |
| `mod_mul` | `a_i[11:0]`, `b_i[11:0]`, `valid_i` | `p_o[11:0]`, `valid_o` | 곱셈기 1개 + `mod_red`. p = a * b * S mod q. 단일 `PIPE` 대신 `MUL_REG`(0..1), `RED_PIPE`(0..2) 두 parameter, `LATENCY = MUL_REG + RED_PIPE` (같은 latency라도 절단 위치가 다른 구성을 비교하기 위한 예외) |

## L1 인터페이스 (고정, 2026-11-16)
`bfu`: `clk`, `rst_n`, `mode_i`(`mode_e`), `a_i`, `b_i`, `z_i` [11:0], `valid_i`, `x_o`, `y_o` [11:0], `valid_o`.
parameter `ALGO`, `PRE_REG`(0..1), `MUL_REG`(0..1), `RED_PIPE`(0..2), `OUT_REG`(0..1), `SHARE_ADDSUB`(0..1).
`LATENCY = PRE_REG + MUL_REG + RED_PIPE + OUT_REG`, CT와 GS 동일. 고정 latency, backpressure 없음. 의미와 제약은 `arch.md`.
