# Code 구성 스펙: nand-ecc-subsystem 주 LDPC code

상태: **초안** (2026-11-25, N1). 오케스트레이터 검토 후 확정. 열린 결정은 `scope.md` 9절(C로 시작하는 ID).

- 근거: `brief.md` 잠정 결정, `survey/survey.md` 2.2~2.3, 3, 4.1, 6.1절.
- 표기: **[계산]** 스크립트나 식으로 구한 값(측정 아님). **[추정]** 가정이나 판단이 들어간 값. **미확인** 출처를 확인하지 못한 것.
- 산출물: `model/tools/qclib.py`(공용), `model/tools/gen.py`(구성), `model/tools/chk.py`(검증), `model/code/qc_*.txt`(shift 표), `model/code/gen.log`, `chk.log`, `sha256.txt`, `repro.log`.

## 1. 요약

| 항목 | 값 |
|---|---|
| 구조 | QC-LDPC, weight-1 circulant(순환 이동 단위행렬)만 사용, Z = 128 |
| base matrix | mb x nb = 8 x 72. 정보 열 64개(열 weight 4), parity 열 8개(p0 weight 3 + dual diagonal 7개) |
| 길이 | n = 9216, k = 8192(1 KiB 데이터), parity 1024, rate 8/9 = 0.888889 |
| H | 1024 x 9216, edge 34,944, 행 weight 34(896행)/35(128행) |
| girth | 6 (4-cycle 0, 6-cycle 54,528개) [계산, `chk.log`] |
| encoding | dual-diagonal back substitution, 선형 시간. random 1,000/1,000 codeword가 H c = 0 [계산] |
| layered 복호 | layer = base 행 1개(128 check), 8 layer. 한 layer 안에서 variable node 중복 0 |
| 재현 | `gen.py`의 seed 1~32를 모두 돌려 6-cycle이 가장 적은 seed 20을 채택. 두 번 생성한 shift 표의 sha256이 같음(`repro.log`) |

## 2. 정의

### 2.1 shift 표와 circulant 규약
- base matrix 원소 `s`: `-1`이면 Z x Z 영행렬, `s >= 0`이면 `P^s` = 단위행렬을 순환 이동한 행렬로 **행 i의 1이 열 (i + s) mod Z에 있다**.
- 블록 벡터 x(Z비트, x[0]이 index 0)에 곱하면 `(P^s x)[i] = x[(i + s) mod Z]`. decoder에서는 APP 블록을 자연 순서로 읽어 `s`만큼 index 0 쪽으로 순환 이동하면 lane i가 check (r, i)에 맞는 variable을 받는다.
- 열 순서: 0..63 정보 블록(codeword 비트 `c*Z + t`), 64 = p0, 65..71 = p1..p7. codeword는 systematic `[u_0 .. u_63 | p_0 .. p_7]`.
- 같은 규약을 802.11n/5G 표기와 비교할 때 이동 방향이 반대일 수 있다. 외부 행렬을 읽을 때는 그 표준의 정의를 따로 변환한다(N2).

### 2.2 텍스트 저장 형식 (`model/code/qc_<name>.txt`)
```
# 주석 줄(#). "# key = value" 줄은 메타데이터(name, generator, seed, seeds_tried, wc, p0_a, p0_j, base_6cycles)
mb nb Z
s(0,0) s(0,1) ... s(0,nb-1)
...                                  (mb 줄, 공백 구분 정수, -1 = 영블록)
```
- C, RTL용 ROM 생성기, TB는 모두 이 파일 하나를 읽는다. C 쪽 파서는 N2에서 `#` 줄을 건너뛰고 첫 세 정수를 차원으로 읽는다.
- 축소판 `qc_t8.txt` 예:
```
4 12 8
 5  7 -1  1  1  4 -1  0  1  0 -1 -1
 0 -1  1  5  3  1  3 -1 -1  0  0 -1
 3  1  2 -1  2 -1  5  0  0 -1  0  0
-1  4  6  4 -1  2  7  7  1 -1 -1  0
```

### 2.3 parity부 구조 (802.11n식 dual diagonal [R14])
- p0(열 64): 행 0, j = 4, 7에 shift (a, 0, a), a = 1. p_k(k = 1..7, 열 64+k): 행 k-1과 k에 shift 0.
- 모든 행을 더하면 p_1..p_7은 두 번씩 나와 사라지고 p0 열은 `P^a + P^0 + P^a = I`가 되므로 `p0 = Σ_r λ_r`. 여기서 `λ_r = Σ_c P^{s(r,c)} u_c`(정보부의 행 r 합).
- 이어서 `p1 = λ_0 + P^a p0`, `p_{r+1} = λ_r + p_r + [r = j] p0` (r = 1..6). 마지막 행 7의 식은 자동으로 만족한다(1,000개 검사로 확인).
- encoder 비용 [계산]: 정보부 블록 연산 256회(블록 회전 + XOR) + parity 9회. Z비트 블록을 한 cycle에 하나 처리하면 약 265 cycle/codeword(하드웨어 구조는 `scope.md` 5절).
- parity부가 가역이므로 H의 rank는 1024(full)이고 k = 8192가 정확히 성립한다.

## 3. 구성 알고리즘 (`gen.py`)

1. **행 패턴**: 정보 열 64개마다 8행 중 4행을 고른다. 70개의 4-부분집합 중에서 (사용 횟수, 행 weight 합, 행 쌍 동시 출현 합) 비용이 가장 작은 것을 차례로 고르고 동점은 seed로 고른다. 결과: 정보부 행 weight 모두 32, 행 쌍 동시 출현 12~15, 같은 패턴 반복 없음.
2. **parity 열 배치**: 2.3절 고정 값.
3. **greedy shift 선택**: 정보 열을 0부터 차례로, 그 열의 각 원소에 대해 0..Z-1 후보 중
   - 4-cycle을 닫는 값(`s(r,c) = s(r2,c) - s(r2,c2) + s(r,c2)`)은 금지,
   - 남은 값 중 이미 놓인 원소와 6-cycle(`s(r,c) - s(r2,c) + s(r2,c2) - s(r3,c2) + s(r3,c3) - s(r,c3) ≡ 0`)을 가장 적게 닫는 값을 고른다(동점은 seed).
4. **국소 개선**: 정보 원소를 seed 순서로 하나씩 빼고 나머지 전체를 기준으로 다시 고른다. 6-cycle 수가 엄격히 줄 때만 바꾼다. 한 바퀴에 변화가 없을 때까지(최대 30바퀴).
5. **seed 선택**: seed 1~32를 모두 돌려 base 6-cycle이 가장 적은 표를 저장한다(동점이면 앞 seed).
- 실행: 프로젝트 루트에서 `python3 -I model/tools/gen.py`, 인자 없음. 4개 variant 전체 약 30초, core 1개.
- base 단계의 cycle 하나(shift 합 ≡ 0 mod Z)는 펼친 graph에서 길이가 같은 cycle Z개가 된다. 그래서 6-cycle 수는 base 수 x Z로 센다.

### 3.1 seed별 결과 (`gen.log` 발췌, m128)
- base graph의 구조적 cycle(모든 shift를 무시): 4-cycle 2,587, 6-cycle 145,348. shift를 무작위로 두면 6-cycle 기대값은 145,348 / 128 = 1,135.5 [계산].
- greedy 직후 455~498, 개선 후 426~488 (32 seed). 채택: **seed 20, base 6-cycle 426 → 펼친 graph 54,528**. 무작위 기대값의 약 38%.
- 두 행이 공유하는 block 열의 최대 수 16. girth 8(6-cycle 0)이 되려면 145,348개 구조적 6-cycle의 shift 합이 전부 0이 아니어야 하는데, 이번 탐색(greedy + 국소 개선)으로는 가능성을 보이지 못했다. Z = 128에서 girth 8 구성이 존재하는지는 **미확인**(증명도 반증도 안 함).

## 4. 검증 (`chk.py`, `model/code/chk.log` 실제 출력)

`chk.py`는 `gen.py`와 독립적으로 표 파일만 읽어 다시 계산한다. encoder 검사의 H c 계산은 펼친 edge 목록(1024개 check마다 variable index 목록)으로 하므로 encoder의 블록 회전 구현과 독립이다. 1,000개 codeword를 비트 위치별 정수의 bit-slice로 한 번에 검사한다.

```
== model/code/qc_m128.txt (mb 8, nb 72, Z 128, n 9216, seed 20, sha256 ead0d5dd7f4452ff)
  base cycles with zero shift sum: 4-cycles 0, 6-cycles 426 -> lifted 4-cycles 0, 6-cycles 54528
  girth (BFS, expanded graph): 6
  lifted 6-cycles by path enumeration: 54528 (matches base x Z)
  base row weight {weight: rows} {34: 7, 35: 1}, base column weight {weight: cols} {2: 7, 3: 1, 4: 64}
  expanded H: 1024 x 9216, row weight {w: count} {34: 896, 35: 128}, column weight {w: count} {2: 896, 3: 128, 4: 8192}, edges 34944
  GF(2) rank 1024 of 1024 rows -> k = 8192, rate 0.888889 (design 64/72 = 0.888889)
  encoding: 1000 / 1000 random messages (seed 2026) give H c = 0; single-bit-flip control detected 1000 / 1000
  layers: 8 layers of 128 checks, every variable node at most once per layer: yes
  shared block columns of consecutive layers (r, r+1 mod mb): [16, 15, 14, 16, 15, 14, 15, 15]
  shared block columns, all layer pairs: min 13 max 16
  RESULT: PASS
```
- girth: 각 block 열의 variable node 0에서 BFS(순환 자기동형 때문에 이 72개로 충분)한 최소값. 6-cycle 수는 base 계수(`qclib.base_cycles`)와 펼친 graph의 경로 열거 두 방법이 일치한다.
- single-bit-flip 대조: codeword마다 임의 비트 하나를 뒤집으면 1,000개 모두 syndrome이 0이 아니다(검사기 자체가 동작함을 확인).
- 축소판 결과(같은 출력 형식, `chk.log`): s32 PASS(4-cycle 0, girth 6, 6-cycle 128,640, rank 256, k 2048, encoding 1000/1000), t8 PASS(4-cycle 0, girth 6, 6-cycle 368, rank 32, k 64, encoding 1000/1000). 마지막 줄 `ALL: PASS (3 tables)`.
- 재현성: 같은 job 안에서 `gen.py`를 두 번 실행해 첫 실행의 sha256(`sha256.txt`)을 두 번째 결과로 검사, 3개 표 모두 `OK`(`repro.log`).

## 5. 축소판

| 이름 | mb x nb, Z | n, k, rate | 용도 | 결과 |
|---|---|---|---|---|
| `qc_s32` | 8 x 72, 32 | 2304, 2048, 8/9 | 주 code와 base 모양, layer 수, 행 weight가 같다. RTL을 `Z` parameter로 만들 때 lane 32로 빠르게 도는 모듈 TB와 시스템 TB, C 단위 테스트 | seed 7, 4-cycle 0, girth 6 |
| `qc_t8` | 4 x 12, 8 | 96, 64, 2/3 | 손으로 따라갈 수 있는 크기. 복호 trace 검토, 단일/이중 오류 전수 검사(96 + 4,560 패턴), viewer의 L0 예제. 열 weight 3 | seed 6, 4-cycle 0, girth 6 |
| `s16`(실패) | 8 x 72, 16 | - | 시도만 함 | seed 1~4 모두 greedy 단계에서 4-cycle 없는 값이 남지 않아 실패. 행 쌍이 최대 16개 열을 공유하므로 Z = 16에서는 그 16개의 shift 차이가 mod 16에서 모두 달라야 해 여유가 없다. 존재 불가능을 증명한 것은 아니다 |

- Z = 8~16의 같은 base(8 x 72)는 위 이유로 만들지 못했다. 그래서 "같은 base 모양"은 s32, "작은 크기"는 t8로 나눴다(열린 결정 C4).
- t8은 6-cycle 46개가 구조적 6-cycle 377개의 12%이고 girth가 6이다. 정정 성능 평가용이 아니라 기능 검사용이다.

## 6. layered 복호 관점

- layer = base 행 하나(128 check). weight-1 circulant라 한 layer 안에서 한 variable node는 최대 한 번만 갱신된다(`chk.py` 확인). CCSDS C2처럼 weight-2 circulant의 layer 내 충돌 처리가 필요 없다 [R25][추정: 구조에서 도출].
- 인접 layer가 공유하는 block 열은 14~16개(행 weight 34의 약 45%). layer를 겹쳐 돌리는(파이프라인) decoder는 이 열에서 read-after-write hazard가 생긴다.
- `docs/spec/s1calc.py` [1]의 [계산]: phase 2(쓰기)의 열 순서를 다음 layer의 읽기 순서에 맞추고, 각 layer는 앞 layer와 공유하지 않는 열부터 읽으면 CNU 파이프라인 L = 2~8에서 stall 0, iteration당 273 cycle(= block edge 수, 하한). 자연 순서면 L = 6에서 stall 54 cycle(iteration당 327). 이 순서는 layer마다 (열, shift, 읽기 위치, 쓰기 위치) ROM으로 고정한다.
- 조건: phase 2가 R을 (min1, min2, index, sign)으로 다시 만들기 때문에 쓰기 순서를 자유롭게 바꿀 수 있다. Q(= APP − R) 버퍼는 FIFO가 아니라 읽기 위치로 주소를 매기는 RAM이어야 한다.

## 7. 한계와 위험 (정직하게)

- **girth 6**: 6-cycle 54,528개가 남는다. 열 weight 4, rate 8/9에서 짧은 cycle은 수렴과 error floor에 불리하다고 알려져 있으나, 이 code에서의 영향은 아직 FER로 확인하지 않았다(N2).
- **error floor와 trapping set 미분석**: 최소 거리, (a, b) trapping set, absorbing set을 계산하지 않았다. SSD 목표 실패율(문헌의 1e-15 목표 [R7])은 시뮬레이션(서버 1e-5급, 보드 1e-7급 [추정, `scope.md` 6절])으로 확인할 수 없다. 이 프로젝트의 FER 곡선은 floor 영역을 보여주지 못할 수 있고, 그렇다고 기록한다.
- **ACE/EMD 같은 cycle 연결도 지표 미사용**: 구성 기준은 4-cycle 금지와 6-cycle 개수뿐이다. weight-2 열이 짧은 cycle에 들어가는지 따로 막지 않았다.
- **고정 shift a = 1, j = 4**: 802.11n식을 따랐을 뿐 최적화하지 않았다.
- **외부 기준 없음**: 자체 구성 code라 공인 test vector가 없다. golden decoder를 외부 code(CCSDS C2, 802.3an)로 먼저 검증하고 같은 코드를 이 code에 쓴다(`scope.md` 7절).

### 7.1 dual-diagonal parity의 weight-2 열
parity 열 p1..p7은 weight 2라 펼치면 896개(전체의 9.7%) variable node가 degree 2다. 이 node들은 check에서 받는 메시지가 2개뿐이라 정보가 느리게 모이고, degree-2 node끼리 cycle을 이루면 낮은 weight codeword와 error floor의 원인이 된다고 알려져 있다(일반론, 이 문서에서 출처를 새로 확인하지 않음). 이 구성에서는 degree-2 node만으로 이루어진 부분 graph가 길이 7의 경로 128개라 cycle이 없다(dual diagonal을 끝에서 닫지 않음)[계산: 구조에서 도출]. 그래도 degree 2~4가 섞인 짧은 cycle은 제한하지 않았다.
대안: (1) **5G NR BG식 core**(QC 구조와 lifting size는 [R15]. core parity가 weight-3 열 + double diagonal이라는 세부는 이번에 원문으로 확인하지 않음, **미확인**): 그 세부가 맞다면 이 구성과 본질적으로 같아 이득이 작다. (2) **모든 열 weight ≥ 3 + 근사 하삼각(Richardson-Urbanke식) encoder**: degree-2를 없애 floor에 유리하나 encoder에 dense한 1024 x 1024 역행렬 부분이 생긴다(출처 미확인, 일반론). (3) **CCSDS식 QC systematic generator**: 모든 열을 weight 4 regular로 두고, generator를 circulant(첫 행만 저장) 블록 64 x 8로 만들어 shift register로 encoding [R25 Annex A의 방식]. generator 저장 64 x 8 x 128 = 65,536 bit [계산], 단 H가 full rank가 아니면 k가 바뀐다(C2는 rank 1020 [R25]). (2)(3)은 encoder 구조와 rate가 바뀌므로 v1에서는 하지 않고, N2에서 dual-diagonal 판의 FER이 나온 뒤 비교 실험 후보로만 둔다(열린 결정 C2).

## 8. 다음 단계에서 쓸 것
- N2: C의 code loader(2.2절 형식), encoder(2.3절), H 행렬 alist 내보내기(AFF3CT 교차용), 축소판 t8/s32 단위 테스트.
- N4: RTL ROM 생성기는 같은 표 파일과 6절의 읽기/쓰기 순서를 입력으로 한다. 순서 생성 코드는 `s1calc.py`의 `order_layers('split')`를 `model/tools/`로 옮겨 쓴다(지금은 계산용).
