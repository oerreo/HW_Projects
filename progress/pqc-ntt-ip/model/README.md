# ML-KEM 다항식 연산 golden model (P1-b, P2-0)

FIPS 203 Algorithm 9~12 (NTT, NTT^-1, MultiplyNTTs, BaseCaseMultiply)와 모듈러 reduction 후보들의 bit-accurate C++17 모델.
q = 3329, n = 256, zeta = 17. 계수는 항상 canonical unsigned [0, q) (12 bit).

## 빌드와 실행
외부 라이브러리 없이 g++ (C++17)만 사용한다. 공용 서버이므로 병렬 빌드는 `-j2` 이하.

```
make -j2 all              # build/test_mlkem, build/gen_vectors, build/libmlkem_dpi.so
make test                 # 자체 테스트 (width assertion 켜진 빌드), 마지막에 항목별 검사 수/mismatch, OVERALL PASS/FAIL
make test-hw              # 하드웨어 구조 항목(hw, hw-ext)만 (1초 내외)
make test EXT_DIR=/path   # 외부 벡터 디렉토리 지정 (기본 ../data/vectors/ext, 읽기만 함. 없으면 hw-ext 항목 FAIL)
make test TEST_SEED=7     # random 부분의 시드 변경
make vectors              # vectors/ 에 벡터 생성 (기본 SEED=1 COUNT=100 NRED=100000)
make vectors SEED=3 COUNT=1000 NRED=10000 VEC_DIR=/path/out
make clean                # build/, vectors/ 삭제
```
`build/`, `vectors/` 는 생성물이다.

## 디렉토리
| 경로 | 내용 |
|---|---|
| `include/mlkem_params.h` | q, n, zeta, 128^-1 |
| `include/mlkem_modarith.h` | 기준 연산(`*_ref`), mod_add/sub HW 형태, reduction 후보 5종, `MulKind` |
| `include/mlkem_ntt.h`, `src/mlkem_ntt.cpp` | zeta/gamma 테이블 생성, CT/GS butterfly, NTT/INTT, BaseCaseMultiply, MultiplyNTTs, trace/layer 덤프 |
| `src/mlkem_schoolbook.cpp` | NTT와 독립인 negacyclic schoolbook 곱 (int64와 `%`만 사용) |
| `include/mlkem_hw.h`, `include/mlkem_hw_impl.h` | header-only (sim/run.sh 의 DPI 소스 목록을 바꾸지 않아도 링크되도록). 확정 아키텍처(`docs/spec/arch.md`)의 하드웨어 구조 모델: `bfu`, ALGO별 ROM, ping-pong 스케줄 NTT/INTT, basemul micro-op 프로그램, trace 덤프 |
| `include/mlkem_dpi.h`, `src/mlkem_dpi.cpp` | DPI-C용 C linkage wrapper (SV import 예시는 헤더 주석과 아래 "DPI-C") |
| `include/mlkem_rng.h`, `include/mlkem_cases.h` | 시드 고정 PRNG(splitmix64), 경계 케이스 다항식 |
| `test/` | 자체 테스트 (`test_main.cpp`), pq-crystals 교차 확인, 하드웨어 구조 모델 테스트 (`test_hw.cpp`) |
| `tools/gen_vectors.cpp` | 벡터 생성기 |
| `third_party/pq-crystals-kyber/` | pq-crystals/kyber ref NTT 코드 (CC0, 교차 확인 전용, 출처는 `SOURCE.txt`) |
| `third_party/fips203/appendix_a.txt` | FIPS 203 Appendix A의 zeta/gamma 표 (PDF에서 추출, 출처 주석 포함) |

## Reduction 후보 요약
모든 함수는 `include/mlkem_modarith.h` 에 있고, 중간값은 고정폭 정수와 비트폭 주석으로 표기한다.
테스트 빌드(`-DMLKEM_CHECK_WIDTHS`)에서는 선언한 비트폭을 런타임으로 검사한다.
아래 "곱셈"은 12b x 12b 곱(a*b)을 제외한 reduction 내부 연산만 센 것이다.

| 함수 | 입력 정의역 | 출력 | 주요 중간 비트폭 | 연산 구성 |
|---|---|---|---|---|
| `mod_add_hw(a,b)` | a,b in [0,q) | (a+b) mod q, [0,q) | 합 13b, 차 s14 | 가산 1 + 조건부 감산 1 + mux |
| `mod_sub_hw(a,b)` | a,b in [0,q) | (a-b) mod q, [0,q) | 차 s13 | 감산 1 + 조건부 가산 1 + mux |
| `mod_half(x)` | x in [0,q) | x*2^-1 mod q, [0,q) | x>>1 11b, 합 12b (최대 3328) | 가산 1 (상수 1665 또는 0), 보정 없음 |
| `barrett_reduce(x)` (k=24, m=5039) | [0, 2^24) | x mod q, [0,q) | x*m 37b, qhat 13b, r 14b (하위 14b만 계산) | 상수곱 2개 (24b x 5039, 13b x q 하위 14b), 감산 1, 조건부 감산 1 |
| `mont12_reduce(x)` (R=2^12) | [0, q*2^12) | x*2^-12 mod q, [0,q) | t 12b, t*q 24b, 합 25b, u 13b | t = -(xl*769) mod 2^12 (3입력 가산, 곱셈기 없음), 상수곱 t*q 1개, 가산 1, 조건부 감산 1 |
| `mont16_reduce(x)` (R=2^16) | [0, q*2^16) | x*2^-16 mod q, [0,q) | t 16b, t*q 28b, 합 29b | 상수곱 2개 (16b x 3327 하위 16b, 16b x q), 가산 1, 조건부 감산 1 |
| `shiftadd_reduce(x)` (2^12 = 2^9+2^8-1) | [0, 2^24) | x mod q, [0,q) | fold 출력 22/20/17/15/14b | fold 5단 (각각 4항 합: h<<9, h<<8, -h, l), 병렬 감산 2 (q, 2q) + 3:1 mux. 곱셈기 없음 |
| `k2red_reduce(x)` (K2-RED, k=13, m=8) | [0, 2^24) | 169*x mod q, [0,q) | r1 s17, r2 s13 [-12, 3571] | 13*c (3항 shift-add) 2회, 감산 2, 보정 (+q / -q) + mux. 곱셈기 없음 |

- Montgomery는 R=2^12를 HW 후보로 둔다. q보다 큰 최소 2의 거듭제곱이라 t가 12b이고, mod 2^12 에서 q^-1 = 769 = 2^9+2^8+1 이라 t 계산이 가산만으로 된다. R=2^16은 pq-crystals(int16 signed lazy reduction) 비교용이며 canonical 표현에서는 폭만 넓어진다.
- Montgomery와 K2-RED는 결과에 2^-12, 2^-16, 169가 곱해지므로 butterfly에서는 twiddle ROM에 보정된 값(`twiddle_prescale`)을 넣어 출력을 canonical 기준과 같게 만든다. ROM 내용은 `vectors/twiddle_rom_<kind>.hex` (128번째 줄은 INTT 128^-1 스케일 값).
- 실측 범위(전수): shiftadd y5 최대값은 전체 24b 정의역에서 7392 (> 2q, 2q 분기 필요), a*b 곱만 보면 6396 (< 2q). K2-RED r2는 곱 입력에서도 [-12, 3482] 이라 +q/-q 보정 둘 다 필요.
- `basecase_multiply` / `multiply_ntts` 의 `MulKind` 는 ref, barrett, shiftadd만 지원한다(기존 동작 유지). MONT12, K2RED의 basemul은 아래 하드웨어 구조 모델의 7 op 프로그램(K2 = S^-2 보정)으로 모델링한다.

## 벡터 형식 (`make vectors`)
- 스칼라 (`*.txt`): 한 줄에 한 벡터, 공백으로 나눈 hex 필드, 맨 앞 `//` 주석에 필드 이름. `$fscanf` 로 읽는다.
  `reduce_<kind>.txt` (x, 기대값), `modarith.txt`, `bfly_ct.txt`, `bfly_gs.txt`, `basemul.txt`. 경계값이 먼저, 그 뒤 random.
- 다항식 (`*.hex`): 한 줄에 12b 계수 하나 (3자리 hex), `$readmemh` 호환. case c 는 [c*256, c*256+255] 줄.
  `ntt_in/out`, `intt_in/out`, `mul_a/b/out` (MultiplyNTTs), `polymul_f/g/h` (h = f*g mod X^256+1, schoolbook으로 확인됨).
  `ntt_layers.hex` 는 case당 7 layer, `intt_layers.hex` 는 case당 8 (7 layer + 3303 스케일).
- `ntt_trace.txt`, `intt_trace.txt`: butterfly 하나당 한 줄 (layer, len, zeta 인덱스, j0, j1, 입력, zeta, ROM 값, 출력).
- `manifest.txt`: 시드, 개수, case 번호와 이름. 경계 케이스 6개(all_zero, all_qm1, impulse_1_at_0, impulse_1_at_255, impulse_qm1_at_128, all_one)가 항상 앞에 온다.
- 같은 시드면 플랫폼과 무관하게 같은 벡터가 나온다 (자체 PRNG, std 분포 미사용).

## 하드웨어 구조 모델 (P2-0, `include/mlkem_hw.h`)
`docs/spec/arch.md` 의 구조를 bit-accurate로 옮긴 계층이다. 기존 함수의 시그니처와 동작은 바꾸지 않았다. 모든 결과는 기준 `ntt`/`intt`/`multiply_ntts` 와 bit-exact 이다.

### ALGO와 스케일
ALGO 인코딩은 arch.md 순서이며 기존 `mul_kind` 와 다르다: 0 BARRETT, 1 MONT12, 2 SHIFTADD, 3 K2RED. mode: 0 CT, 1 GS.
`mul(b, z) = reduce_ALGO(b * z) = b * z * S mod q`.

| ALGO | S | S^-1 (zeta ROM 보정) | S^-2 (K2, gamma ROM 보정) | basemul op 수 |
|---|---|---|---|---|
| BARRETT | 1 | 1 | 1 (사용 안 함) | 5 |
| MONT12 | 2^-12 = 2704 | 2^12 mod q = 767 | 2385 | 7 |
| SHIFTADD | 1 | 1 | 1 (사용 안 함) | 5 |
| K2RED | 169 | 169^-1 = 2^16 mod q = 2285 | 1353 | 7 |

- zeta ROM[i] = zeta_i * S^-1 (128개, 주소 = zeta 인덱스). 기존 `twiddle_rom(MulKind)` 와 같은 값임을 테스트가 확인한다.
- gamma ROM[i] = gamma_i (S = 1), gamma_i * S^-2 (S != 1). 주소 = 계수 쌍 번호.
- K2 = S^-2. 예: MONT12 zeta ROM[0..3] = 2ff 4b1 59a a32, K2RED gamma ROM[0] = bd3 (hex).

### bfu
`bfu(algo, mode, a, b, z)` 는 `mul12x12` + reduction 1개, `mod_add_hw` 1개, `mod_sub_hw` 1개, `mod_half` 2개로만 구성된다.
```
CT: t = mul(b, z);  x = add(a, t);   y = sub(a, t)
GS: s = add(a, b);  d = sub(b, a);   x = half(s);  y = half(mul(d, z))
```
**arch.md와의 차이 (GS 뺄셈 순서)**: arch.md는 GS를 `y = (a - b)*z/2` 로 적었지만, 모델은 FIPS 203 Algorithm 10 의 10행(`f[j+len] = zeta * (f[j+len] - t)`)대로 `b - a` 를 쓴다.
단일 zeta ROM(S^-1 보정)과 Alg. 10 순서에서 `a - b` 를 쓰면 매 layer 홀수 출력의 부호가 바뀌어 INTT가 틀린다(변이 M7, 아래). 방법은 셋이다:
(1) bfu가 `b - a` 를 계산 (모델의 선택, `mod_sub` 첫 입력에도 mux 1개 추가),
(2) bfu는 `a - b` 를 유지하고 GS에서 컨트롤러가 두 read 포트를 맞바꿈 (a_i = f[j+len], b_i = f[j], 쓰기 주소는 그대로. 스크래치에서 INTT 4종, 외부 벡터까지 일치 확인),
(3) INTT용 부호 반전 zeta ROM 128개 추가.
최종 선택은 스펙(arch.md)에서 정한다. 다른 선택을 하면 `bfu` 의 GS 정의, 테스트 오라클(`bfu_oracle`), trace 의미가 함께 바뀌어야 한다.

### 하드웨어 스케줄 NTT/INTT (ping-pong)
- `hw_ntt(algo, Banks&, in_bank, trace)`, `hw_intt(...)`: layer마다 read bank `in_bank ^ (layer & 1)` 의 256개 주소를 한 번씩 읽고 반대 bank의 256개 주소에 한 번씩 쓴다(모델이 매 layer 검사). 결과는 `in_bank ^ 1`.
- 주소 순서: NTT는 Alg. 9 (len 128..2, zeta 주소 1부터 증가, mode CT), INTT는 Alg. 10 (len 2..128, zeta 주소 127부터 감소, mode GS). 스케줄 자체는 `transform_schedule(mode)` 로 데이터와 무관하게 얻는다.
- INTT는 GS가 두 출력을 매 layer 반으로 나누므로 7 layer 뒤 1/128 이 되고, 별도의 스케일 pass가 없다. layer L 상태는 기준 INTT의 layer L 상태 * 2^-(L+1) 과 같다(테스트가 확인).
- bfu 호출 수: NTT 896, INTT 896 (ALGO 무관).

### basemul micro-op 프로그램
계수 쌍 i 마다 a0 = bank0[2i], a1 = bank0[2i+1], b0 = bank1[2i], b1 = bank1[2i+1] 을 operand 레지스터에 latch 한 뒤, 모든 op를 `bfu(CT).x` 로 수행한다. C0, C1은 bank0[2i], bank0[2i+1] 에 쓴다.
operand를 latch하므로 c0를 쓴 뒤 a0를 다시 읽어도 hazard가 없다. latch 없이 매 op RAM을 읽는 구현이라면 c0/c1 쓰기를 쌍의 마지막으로 미뤄야 한다.

S = 1 (5 op, 임시 레지스터 R0 하나):
| op | a | b | z | dst | 값 |
|---|---|---|---|---|---|
| 0 | 0 | A1 | B1 | R0 | t = a1 b1 |
| 1 | 0 | R0 | GAMMA | R0 | p = t gamma |
| 2 | R0 | A0 | B0 | C0 | c0 = p + a0 b0 |
| 3 | 0 | A0 | B1 | R0 | u = a0 b1 |
| 4 | R0 | A1 | B0 | C1 | c1 = u + a1 b0 |

S != 1 (7 op, 임시 레지스터 R0, R1):
| op | a | b | z | dst | 값 |
|---|---|---|---|---|---|
| 0 | 0 | A1 | B1 | R0 | t = a1 b1 S |
| 1 | 0 | R0 | GAMMA | R0 | p = t (gamma S^-2) S = a1 b1 gamma |
| 2 | 0 | A0 | B0 | R1 | v = a0 b0 S |
| 3 | R0 | R1 | K2 | C0 | c0 = p + v S^-2 S = a1 b1 gamma + a0 b0 |
| 4 | 0 | A0 | B1 | R0 | u = a0 b1 S |
| 5 | R0 | A1 | B0 | R0 | w = (a0 b1 + a1 b0) S |
| 6 | 0 | R0 | K2 | C1 | c1 = w S^-2 S = a0 b1 + a1 b0 |

arch.md 의 두 시퀀스는 위와 같고 그대로 맞았다(4 ALGO, random 2000쌍 + 경계 36쌍 + 외부 2145쌍 mismatch 0). bfu 호출 수: 128 x 5 = 640 (S = 1), 128 x 7 = 896 (S != 1).

### trace 덤프
- `dump_bfu_trace`: 한 줄에 bfu 호출 하나. `layer step len rd_bank wr_bank addr0 addr1 zeta_addr mode a b z x y` (제어는 10진, 데이터는 hex). x는 `wr_bank[addr0]`, y는 `wr_bank[addr1]` 에 쓴다. `ntt_ctrl` 의 주소/zeta 주소/mode 시퀀스 비교용.
- `dump_basemul_trace`: 한 줄에 op 하나. `pair op a_src b_src z_src dst a b z x`. 출처 이름은 ZERO, A0, A1, B0, B1, R0, R1, GAMMA, K2.

### 벡터 생성기 추가 파일 (`make vectors`)
| 파일 | 내용 |
|---|---|
| `rom_zeta_<algo>.hex`, `rom_gamma_<algo>.hex` | 128줄, `$readmemh` 용 |
| `rom_k2_<algo>.hex` | 1줄 (K2) |
| `bfu_<algo>.txt` | `mode a b z x y` (hex). 경계 5^3 x 2 mode 다음 mode별 random NRED개 (z는 random과 ROM 값 교대) |
| `mod_half.txt` | `x h`, x in [0, q) 전체 |
| `hw_ntt_trace_<algo>.txt`, `hw_intt_trace_<algo>.txt` | trace case(manifest의 `trace_case`)의 bfu trace, 896줄 |
| `hw_basemul_trace_<algo>.txt` | 같은 case의 `mul_a`, `mul_b` 에 대한 basemul op trace, 640 또는 896줄 |

`<algo>` 는 barrett, mont12, shiftadd, k2red.

### 테스트 항목 (`test/test_hw.cpp`, group `hw`, `hw-ext`)
| 항목 | 내용 |
|---|---|
| mod_half | x in [0, q) 전체, x * 1665 mod q 와 비교 |
| ROM | S S^-1 = 1, K2 S^2 = 1, zeta ROM * S = zeta, mul(1, zeta ROM) = zeta, gamma ROM 값, 기존 `twiddle_rom` 과 일치 |
| bfu (ALGO 4 x mode 2) | 경계값 {0, 1, q-1, (q-1)/2, (q+1)/2} 의 a, b, z 전 조합 125 + 경계 a, b 25 x ROM 값 전체 257, random 100만 (z 임의), random 100만 (z ROM 값) 을 `%` 기반 오라클과 비교. 후자는 zeta ROM일 때 기존 FIPS butterfly(GS는 반으로)와도 비교 |
| hw_ntt / hw_intt (ALGO별) | random 2000 + 경계 6, 기준 `ntt`/`intt` 와 비교 |
| hw ntt/intt trace | ALGO 4 x 20 다항식 x 2 방향: 결과 bank, read/write bank 교대, 주소와 zeta 주소가 기준 모델 trace와 같음, 기록된 bfu 입출력 재현, layer별 상태 |
| hw_basemul (ALGO별) | op 수 (5/7), random 2000쌍 + 경계 36쌍, 기준 `multiply_ntts` 와 비교 |
| hw basemul trace | op별 출처 값과 결과 재현 |
| hw-ext | `data/vectors/ext` 의 NTT 855, INTT 450, MultiplyNTTs 2145 다항식을 ALGO 4종으로 실행해 파일의 기대값과 비교 (모델과 독립인 기대값) |
| hw dpi | 추가한 DPI 함수 == C++ API, 범위 밖 입력 거부 |

### DPI-C (추가 함수)
`tb/common/mlkem_dpi_pkg.sv` 는 P2-2에서 아래 선언을 포함하도록 갱신됐다. 잘못된 algo/mode/범위 밖 입력은 -1 (다항식 함수는 반환값 -1).
```
  // algo: 0 BARRETT, 1 MONT12, 2 SHIFTADD, 3 K2RED (mul_kind 와 다름). mode: 0 CT, 1 GS.
  import "DPI-C" pure function int mlkem_dpi_barrett_reduce(input int x);
  import "DPI-C" pure function int mlkem_dpi_mont12_reduce(input int x);
  import "DPI-C" pure function int mlkem_dpi_shiftadd_reduce(input int x);
  import "DPI-C" pure function int mlkem_dpi_k2red_reduce(input int x);
  import "DPI-C" pure function int mlkem_dpi_mod_half(input int x);
  import "DPI-C" function void mlkem_dpi_bfu(input int algo, input int mode, input int a,
      input int b, input int z, output int x, output int y);
  // power: 1 (S), -1 (S^-1), -2 (S^-2)
  import "DPI-C" pure function int mlkem_dpi_algo_scale(input int algo, input int power);
  // rom_kind: 0 zeta ROM (index 0..127), 1 gamma ROM (0..127), 2 K2 (index 0)
  import "DPI-C" pure function int mlkem_dpi_rom(input int algo, input int rom_kind,
      input int index);
  // mode 0 NTT, 1 INTT; step 0..895. read bank = in_bank ^ (layer & 1)
  import "DPI-C" function int mlkem_dpi_hw_sched(input int mode, input int step,
      output int layer, output int len, output int addr0, output int addr1,
      output int zeta_addr);
  import "DPI-C" pure function int mlkem_dpi_basemul_nops(input int algo);
  // src: 0 ZERO 1 A0 2 A1 3 B0 4 B1 5 R0 6 R1 7 GAMMA 8 K2; dst: 0 R0 1 R1 2 C0 3 C1
  import "DPI-C" function int mlkem_dpi_basemul_op(input int algo, input int idx,
      output int a_src, output int b_src, output int z_src, output int dst);
  import "DPI-C" function int mlkem_dpi_hw_basemul_pair(input int algo, input int a0,
      input int a1, input int b0, input int b1, input int pair, output int c0, output int c1);
  import "DPI-C" function int mlkem_dpi_hw_ntt(input int algo, input int f[256],
      output int f_hat[256]);
  import "DPI-C" function int mlkem_dpi_hw_intt(input int algo, input int f_hat[256],
      output int f[256]);
  import "DPI-C" function int mlkem_dpi_hw_basemul(input int algo, input int f_hat[256],
      input int g_hat[256], output int h_hat[256]);
```

### 변이 테스트 (2026-11-16, P2-0)
`model/` 를 스크래치에 복사하고 한 군데씩 바꾼 뒤 `test_mlkem --only-hw` 로 확인했다. 18개 변이 모두 1개 이상 항목이 FAIL 했다.
| 변이 | FAIL 한 항목 (주요) |
|---|---|
| M1 zeta ROM S^-1 보정 누락 | ROM, bfu (MONT12, K2RED), hw_ntt/hw_intt (MONT12, K2RED), trace, hw-ext ntt/intt |
| M2 K2 누락 (K2 = 1) | ROM, hw_basemul (MONT12, K2RED), hw-ext basemul |
| M3 gamma ROM을 S^-1로 보정 / M4 gamma ROM 보정 없음 | ROM, hw_basemul (MONT12, K2RED), hw-ext basemul |
| M5 GS x halving 누락 / M6 GS y halving 누락 | bfu GS 4종, hw_intt 4종, trace, hw-ext intt |
| M7 GS를 arch.md 문자 그대로 a - b | bfu GS 4종, hw_intt 4종, trace, hw-ext intt |
| M8 S != 1 op 순서 (u를 c0 앞으로) / M9 S = 1 같은 변이 | hw_basemul (해당 ALGO), hw-ext basemul |
| M10 S != 1 v를 R0에 써서 p를 덮음 / M11 w의 z를 B1로 | hw_basemul (MONT12, K2RED), hw-ext basemul |
| M12 ping-pong bank 교대 누락 | hw_ntt/hw_intt 4종, trace, hw-ext ntt/intt |
| M13 INTT zeta 주소 증가 / M18 NTT zeta 주소 0부터 | hw_intt 또는 hw_ntt 4종, trace, hw-ext |
| M14 mod_half 상수 1664 / M15 홀수 보정 누락 | mod_half, bfu GS 4종, hw_intt 4종, hw-ext intt |
| M16 CT y = t - a | bfu CT 4종, hw_ntt 4종, hw-ext ntt |
| M17 MONT12 bfu_mul 이 barrett reduction 사용 | ROM, bfu MONT12, hw_ntt/intt/basemul MONT12, hw-ext 3종 |
