# data/: pqc-ntt-ip 외부 기준 test data (P1-d)

ML-KEM (FIPS 203, q = 3329, n = 256) 다항식 연산 IP의 검증용 데이터.
이 문서는 `.claude/rules/project-flow.md` 의 "Test data" 절에서 요구하는 세 종류 중 **공인/외부 데이터**를 다룬다.
방향성 벡터와 random 벡터는 golden model의 생성기(`model/tools/gen_vectors.cpp`, `make -C model vectors`)가 만든다.

## 1. 요약

| 항목 | 결과 |
|---|---|
| NIST ACVP ML-KEM 벡터 | keyGen 75, encapsulation 75, decapsulation 30, encapsulationKeyCheck 30, decapsulationKeyCheck 30 = 240 케이스 |
| pq-crystals ref 구현의 ACVP 통과 | 240 / 240 PASS (ML-KEM-512/768/1024 각 80) |
| 추출한 다항식 벡터 (`vectors/ext/`) | NTT 855, INTT 450, MultiplyNTTs 2145 (전부 서로 다른 입력) |
| 독립 Python FIPS 203 검사 | 883,200 계수 비교, mismatch 0 |
| golden model (`model/`) 대조 | NTT/INTT는 MulKind 6종, MultiplyNTTs는 3종 전부 mismatch 0 |

받은 날짜는 모두 2026-11-16.

## 2. 출처, 버전, 라이선스

| 대상 | 출처 | 고정 버전 | 라이선스 / 이용 조건 |
|---|---|---|---|
| ACVP ML-KEM 벡터 | https://github.com/usnistgov/ACVP-Server, `gen-val/json-files/ML-KEM-keyGen-FIPS203/`, `gen-val/json-files/ML-KEM-encapDecap-FIPS203/` | commit `975de31eb83d87039ec88934fdc47d8c312b892d` (master HEAD, 2026-08-12). 두 디렉토리의 마지막 변경 commit은 `ad33b3d9504491767f1aa76382464f3b3fa2359e` (2026-07-28). JSON의 `vsId` 42, `revision` FIPS203 | 저장소에 LICENSE 파일이 없고 README.md의 "License" 절이 이용 조건이다. NIST 직원이 만든 소프트웨어는 미국 내 저작권 보호 대상이 아니며, 사용, 복제, 배포, 수정이 허용된다. 조건: 고지문 유지, 수정본은 변경 사실과 날짜 명시, NIST를 출처로 명시. 보증 없음. (받은 `README.md` 원문을 같이 보관) |
| pq-crystals/kyber ref 구현 | https://github.com/pq-crystals/kyber, branch `main` | commit `3edd5af5991927164edd4aacebfcbee00b8064e7` (2026-08-02) | `LICENSE`: Public Domain (CC0) 또는 Apache 2.0 중 선택. 이 프로젝트는 CC0으로 사용. Keccak 코드는 각 파일 머리의 출처에 따른 public domain |

버전 선택 근거 (pq-crystals): 저장소에는 `main`, `standard`(2024-08 이후 갱신 없음), round2/round3 등의 브랜치와 `v3.0` 태그(round 3 Kyber)가 있다.
`main`의 `ref/` 는 FIPS 203 형태다. keygen에서 `G(d || k)` 도메인 분리(`indcpa.c` 의 `buf[KYBER_SYMBYTES] = KYBER_K`),
decaps의 implicit rejection이 `J(z || c)` (`rkprf`), 공유키를 다시 해시하지 않음. ACVP 240 케이스 통과로 FIPS 203과의 일치를 실제로 확인했다.
(참고: upstream README는 "더 이상 production 수준으로 유지보수하지 않는다"고 적고 있다. 여기서는 검증 기준으로만 쓴다.)

`model/third_party/pq-crystals-kyber/` 도 같은 commit의 `ntt.c`, `reduce.c` 를 갖고 있다(P1-b 담당이 받은 것). 이 디렉토리와는 별도로 다시 받았다.

### 저장소 반영 방침 (`.gitignore`)
- 커밋하지 않음: `third_party/` (ACVP JSON, pq-crystals 소스와 tarball), `build/` (빌드 산출물, raw int16 덤프 약 12 MB).
- 커밋함: `scripts/`, `harness/`, `checksums.sha256`, `vectors/ext/` (약 9.2 MB, 생성 벡터), `logs/`, 이 README.
- 원본은 재배포 자체는 허용되지만, 대용량 원본은 커밋하지 않는다는 방침에 따라 받기 스크립트와 체크섬만 둔다.

### 체크섬
- `checksums.sha256`: 받은 원본 전체(ACVP JSON 8개와 README, pq-crystals tarball과 풀린 파일 전부)의 sha256. 경로는 `data/` 기준.
  `scripts/fetch.sh --verify` 로 확인한다.
- `vectors/ext/SHA256SUMS`: 생성 벡터와 manifest의 sha256. `scripts/gen_ext_vectors.sh` 가 재생성 후 자동으로 확인한다.

주요 원본 체크섬:
```
3f9ce34f6c836c77958bad2729e837c3b213f44ac36c3065976e7acca6389523  ML-KEM-keyGen-FIPS203/prompt.json
a253d0ad91c95ebea5b409673defef0aa49d65d4ed72286399e2e798ddf073a4  ML-KEM-keyGen-FIPS203/expectedResults.json
998e22dfb12efb14ce9fdff911ca634b13612819a1806f25da69adba7e16db91  ML-KEM-encapDecap-FIPS203/prompt.json
9089ec6ff2424da9f2782b89b2f831a329a3e28d6e5e24b802b78ff36ac61cdf  ML-KEM-encapDecap-FIPS203/expectedResults.json
b89cb8cecdd42c9c33c041121ba897e1bdba43375dc4522479468044be5489b4  kyber-3edd5af59919.tar.gz
```

## 3. 재현 명령

공용 서버이므로 한 번에 한 프로세스, make는 `-j2` 이하. 필요한 것은 bash, curl, tar, gcc/g++, python3 (표준 라이브러리만).

```
cd progress/pqc-ntt-ip/data
scripts/gen_ext_vectors.sh            # 받기 + ACVP 실행 + 벡터 생성 + 독립 FIPS 검사 + 체크섬 확인
scripts/gen_ext_vectors.sh --golden   # 위 + model/ golden model 대조
```
단계별로는:
```
scripts/fetch.sh                                                   # third_party/ 에 받고 sha256 확인 (이미 있으면 건너뜀)
python3 -I scripts/acvp_to_cases.py third_party/acvp-975de31eb83d build
make -C harness -j2 all && make -C harness run                     # build/acvp_result_<ps>.log, build/raw_dump_<ps>.txt
python3 -I scripts/make_ext_vectors.py build vectors/ext
python3 -I scripts/check_fips203.py vectors/ext
make -C harness golden && build/golden_check vectors/ext
```
2026-11-16 실행에서 `build/` 를 지우고 처음부터 다시 생성했을 때 `vectors/ext/SHA256SUMS` 와 바이트 단위로 같았다(결정적).

## 4. 파일별 용도

| 경로 | 용도 |
|---|---|
| `scripts/fetch.sh` | 고정 commit의 ACVP JSON(prompt, expectedResults, internalProjection, registration)과 README, pq-crystals tarball을 받는다. tarball은 `LICENSE`, `README.md`, `ref/` 만 풀고 절대경로와 `..` 경로를 거부한다. `--verify` 는 체크섬만 확인 |
| `scripts/acvp_to_cases.py` | ACVP JSON(prompt + expectedResults만 사용)을 파라미터 셋별 한 줄 한 케이스 텍스트로 변환 |
| `harness/acvp_harness.c` | ref 구현을 ACVP 케이스로 실행해 판정하고, 링커 `--wrap` 으로 `poly_ntt`, `poly_invntt_tomont`, `poly_basemul_montgomery` 의 모든 호출 입출력을 raw int16 그대로 덤프 |
| `harness/golden_check.cpp` | `model/` 의 `mlkem::ntt`, `mlkem::intt`, `mlkem::multiply_ntts` 를 `vectors/ext` 로 검사 (model 소스를 읽기만 하고 링크) |
| `harness/Makefile` | 위 두 프로그램 빌드. 산출물은 `build/` 에만 쓴다 |
| `scripts/make_ext_vectors.py` | raw 덤프에 표현 변환 규칙(5절)을 적용해 canonical hex 벡터와 manifest를 쓴다. PASS한 ACVP 케이스의 호출만 사용 |
| `scripts/check_fips203.py` | FIPS 203 Algorithm 9/10/11/12를 순수 Python 정수로 직접 구현한 독립 검사기 |
| `scripts/gen_ext_vectors.sh` | 전체 재현 |
| `vectors/ext/ntt_in.hex`, `ntt_out.hex` | NTT (Alg. 9) 입력과 기대 출력, 855개 |
| `vectors/ext/intt_in.hex`, `intt_out.hex` | NTT^-1 (Alg. 10, 128^-1 스케일 포함) 입력과 기대 출력, 450개 |
| `vectors/ext/basemul_a.hex`, `basemul_b.hex`, `basemul_out.hex` | MultiplyNTTs (Alg. 11) 두 입력과 기대 출력, 2145개 |
| `vectors/ext/manifest.csv` | 다항식마다 한 행: 연산, 파일 안 인덱스와 줄 범위, 파라미터 셋, ACVP vector set, ACVP function, tcId, 케이스 안 호출 순번, raw 입출력 최소/최대 |
| `vectors/ext/manifest.json` | 파일별 다항식 수, 서로 다른 입력 수, 파라미터 셋별 개수 |
| `logs/` | 2026-11-16 실행 로그: `acvp_result_<ps>.log`, `check_fips203.log`, `golden_check.log`, golden 대조 당시 model 소스 sha256 (`golden_check_model_snapshot.sha256`) |

### hex 형식
`$readmemh` 호환. 한 줄에 계수 하나, 3자리 소문자 hex, 값은 [0, q). 다항식 i 는 줄 [256 i, 256 i + 255], 계수 인덱스 0이 먼저.
같은 연산의 입력 파일과 출력 파일은 같은 인덱스끼리 쌍이다. 계수 순서는 FIPS 203 의 배열 인덱스 그대로이며 별도의 bit-reversal 재배열은 없다
(ref 구현과 FIPS 203 모두 NTT 결과를 같은 인덱스 규약으로 둔다. 6절 검사가 이를 확인한다).

### 연산별, 파라미터 셋별 개수

| 파일 | 합계 | ML-KEM-512 | ML-KEM-768 | ML-KEM-1024 |
|---|---|---|---|---|
| `ntt_*` | 855 | 190 | 285 | 380 |
| `intt_*` | 450 | 115 | 150 | 185 |
| `basemul_*` | 2145 | 330 | 675 | 1140 |

KEM 흐름에서 나온 위치 (k = 2, 3, 4):

| ACVP function | NTT | NTT^-1 | MultiplyNTTs |
|---|---|---|---|
| keyGen (각 25) | s, e: 2k | 없음 | A o s: k^2 |
| encapsulation (각 25) | y: k | A^T y, t^T y: k + 1 | k^2 + k |
| decapsulation (각 10) | u' (복원된 암호문) k + 재암호화 y k | s^T u' 1 + 재암호화 k + 1 | k + k^2 + k |

하니스는 케이스마다 위 호출 횟수를 실제 관측 횟수와 비교해 모두 일치했다(`callcount_mismatch=0`). 즉 `--wrap` 이 모든 호출을 잡았다.

### 입력 분포 (주의)
- NTT 입력 855개 중 765개는 CBD 잡음 다항식(raw 계수 |x| <= 3, canonical 값은 {0..3, q-3..q-1})이다. 전 범위 [0, q) 입력은 decapsulation의 u' 90개뿐이다.
  NTT의 전 범위 coverage는 golden model의 random 벡터로 보완해야 한다.
- NTT^-1, MultiplyNTTs 입력은 전 범위이며 네 입력 파일 모두 0과 q-1을 포함한다 (`intt_in`, `basemul_a`, `basemul_b` 는 q개 값 전부 등장).
- MultiplyNTTs는 `poly_basemul_montgomery` 한 번의 곱이다. `polyvec_basemul_acc_montgomery` 의 누적 합과 `poly_reduce` 는 포함하지 않는다.

## 5. 표현 변환 규칙

### 기호
- q = 3329, R = 2^16. R mod q = 2285, R^-1 mod q = 169 (2285 * 169 = 116 q + 1).
- ref의 `montgomery_reduce(a)` 는 a R^-1 과 합동인 int16 을 돌려준다. 따라서 `fqmul(a, b)` 는 a b R^-1 (mod q).
- ref의 `zetas[k]` 는 zeta^BitRev7(k) * R (mod q) 의 centered 대표값이다 (zeta = 17). 따라서 `fqmul(zetas[k], x)` 는 zeta^BitRev7(k) x (mod q).
- `barrett_reduce` 와 `poly_reduce` 는 대표값만 바꾼다 (값은 mod q 로 불변).
- 아래에서 `in`, `out` 은 ref가 덤프한 raw int16 계수, `_c` 는 canonical [0, q) 값, `mod` 는 음이 아닌 나머지.

### NTT: `poly_ntt` = `ntt` + `poly_reduce`
ref `ntt` 의 루프는 Alg. 9 와 같다: len = 128, 64, ..., 2, k = 1 부터 증가, butterfly
t = zeta^BitRev7(k) f[j+len], f[j+len] = f[j] - t, f[j] = f[j] + t. 곱셈은 위 성질로 정확히 zeta^BitRev7(k) 배이고, 나머지는 int16 덧셈이다.
```
out == NTT(in)  (mod q)
ntt_in_c  = in  mod q
ntt_out_c = out mod q
```

### NTT^-1: `poly_invntt_tomont` = `invntt`
루프는 Alg. 10 과 같다: len = 2, 4, ..., 128, k = 127 부터 감소, butterfly t = f[j], f[j] = t + f[j+len] (Barrett), f[j+len] = zeta^BitRev7(k) (f[j+len] - t).
마지막에 모든 계수에 `fqmul(r[j], 1441)` 을 적용한다. 1441 = R^2 * 128^-1 mod q 이므로 (R^2 mod q = 1353, 1353 * 3303 mod q = 1441) 실제 곱해지는 값은
1441 R^-1 = R * 128^-1 (mod q). Alg. 10 의 마지막 스케일은 128^-1 (= 3303) 이므로 ref 결과에는 R 이 한 번 더 곱해져 있다.
```
out == R * NTT^-1(in)  (mod q)
intt_in_c  = in mod q
intt_out_c = out * R^-1 mod q = out * 169 mod q
```

### MultiplyNTTs: `poly_basemul_montgomery`
i = 0..63 에 대해 계수 쌍 (4i, 4i+1) 은 `zetas[64+i]`, 쌍 (4i+2, 4i+3) 은 `-zetas[64+i]` 로 `basemul` 을 호출한다. `basemul` 은
```
r0 = fqmul(fqmul(a1, b1), zm) + fqmul(a0, b0) == R^-1 (a0 b0 + a1 b1 zeta^BitRev7(64+i))   (zm = zetas[64+i] == zeta^BitRev7(64+i) R)
r1 = fqmul(a0, b1) + fqmul(a1, b0)            == R^-1 (a0 b1 + a1 b0)
```
FIPS 203 Alg. 11 은 쌍 m = 0..127 에 gamma_m = zeta^(2 BitRev7(m) + 1) 을 쓴다 (Alg. 12).
- m = 2i (i < 64): BitRev7(2i) = BitRev6(i), 그리고 BitRev7(64 + i) = 2 BitRev6(i) + 1. 따라서 gamma_2i = zeta^BitRev7(64+i).
- m = 2i + 1: BitRev7(2i + 1) = 64 + BitRev6(i) 이므로 gamma_(2i+1) = zeta^128 gamma_2i = -gamma_2i (zeta^128 == -1 mod q).

ref의 쌍 (4i, 4i+1) 이 FIPS 의 m = 2i, (4i+2, 4i+3) 이 m = 2i+1 이므로 계수별로 정확히 대응한다.
```
out == R^-1 * MultiplyNTTs(a, b)  (mod q)
basemul_a_c   = a mod q
basemul_b_c   = b mod q
basemul_out_c = out * R mod q = out * 2285 mod q
```

### KEM 흐름 안의 Montgomery 인자와의 관계
KEM 안에서 `poly_invntt_tomont` 의 입력은 `polyvec_basemul_acc_montgomery` 결과(R^-1 배)라서, ref 흐름 전체로는 R 과 R^-1 이 상쇄된다.
여기서 만든 벡터는 그 흐름과 무관하게 "그 시점에 실제로 나타난 입력 값" 과 "그 입력에 대한 FIPS 203 함수 값" 의 쌍이다.
즉 `intt_out_c == NTT^-1(intt_in_c)`, `basemul_out_c == MultiplyNTTs(basemul_a_c, basemul_b_c)` 가 정확히 성립하며, 하드웨어는 Montgomery 인자를 신경 쓸 필요가 없다.

## 6. 검증

### 6.1 ref 구현 대 ACVP (`logs/acvp_result_<ps>.log`)
- keyGen: `crypto_kem_keypair_derand(pk, sk, d || z)` 의 ek, dk 를 ACVP 기대값과 바이트 비교.
- encapsulation: `crypto_kem_enc_derand(ct, ss, ek, m)` 의 c, k 비교.
- decapsulation: `crypto_kem_dec(ss, c, dk)` 의 k 비교 (ACVP에 "modified ciphertext" 케이스 포함, implicit rejection 경로 검증).
- encapsulationKeyCheck / decapsulationKeyCheck: ref 구현에는 이 입력 검사 함수가 없어 하니스가 FIPS 203 7.2절(ek의 모든 12비트 필드 < q)과 7.3절(H(dk의 ek 부분) == dk 안의 해시)을 구현했다. 해시는 ref의 `sha3_256` 사용. 이 30+30 케이스는 ref의 NTT 경로를 거치지 않는다.

| 파라미터 셋 | keyGen | encap | decap | ekCheck | dkCheck | 합계 |
|---|---|---|---|---|---|---|
| ML-KEM-512 | 25/25 | 25/25 | 10/10 | 10/10 | 10/10 | 80/80 |
| ML-KEM-768 | 25/25 | 25/25 | 10/10 | 10/10 | 10/10 | 80/80 |
| ML-KEM-1024 | 25/25 | 25/25 | 10/10 | 10/10 | 10/10 | 80/80 |

음성 확인: 768 케이스 파일에서 함수 종류별로 기대값 1개씩(총 5개)을 바꾸면 정확히 그 5개가 FAIL 로 나온다.

### 6.2 변환 규칙의 독립 교차 확인 (`logs/check_fips203.log`)
`scripts/check_fips203.py` 는 zeta 를 17^BitRev7(i) mod q 로 직접 계산하고 Alg. 9/10/11/12 를 표준 본문대로 구현한다.
ref 코드, golden model, `make_ext_vectors.py` 와 코드를 공유하지 않는다. 먼저 자기 검사(NTT^-1(NTT(f)) == f, NTT 영역 곱 == negacyclic schoolbook 곱, random 20쌍)를 한다.

| 파일 쌍 | 다항식 | 계수 비교 | mismatch |
|---|---|---|---|
| ntt | 855 | 218,880 | 0 |
| intt | 450 | 115,200 | 0 |
| basemul | 2145 | 549,120 | 0 |

음성 확인: (a) 출력 파일 세 개에서 계수 하나씩을 +1 하면 각각 정확히 1 계수 mismatch, (b) Montgomery 보정(R^-1, R)을 빼고 단순 mod q 만 한 출력은 intt 450/450, basemul 2145/2145 다항식이 mismatch (ntt 는 보정이 없으므로 0). 즉 5절의 규칙이 필요하고 충분함을 확인했다.

### 6.3 golden model 대조 (`logs/golden_check.log`)
`model/` 을 수정하지 않고 `model/src/mlkem_ntt.cpp`, `mlkem_schoolbook.cpp`, `model/include/` 를 `harness/golden_check.cpp` 와 함께 `build/` 에 컴파일했다.
대조 당시 model 소스의 sha256 은 `logs/golden_check_model_snapshot.sha256`.

| 함수 | MulKind | 다항식 | mismatch |
|---|---|---|---|
| `mlkem::ntt` | ref, barrett, shiftadd, mont12, mont16, k2red | 855 x 6 | 0 |
| `mlkem::intt` | ref, barrett, shiftadd, mont12, mont16, k2red | 450 x 6 | 0 |
| `mlkem::multiply_ntts` | ref, barrett, shiftadd (model이 지원하는 종류) | 2145 x 3 | 0 |

## 7. 한계와 확인하지 못한 것
- ACVP는 KEM 단위 입출력만 준다. 다항식 단위 벡터는 "ACVP를 통과한 ref 구현의 중간값" 이며, NIST가 직접 준 다항식 값은 아니다.
- NTT 외부 벡터의 전 범위 입력은 90개뿐이다 (4절).
- ACVP encapDecap JSON 의 `isSample` 은 true 다 (ACVP-Server 저장소의 예제 vector set). keyGen 은 false.
- ref 구현의 int16 lazy reduction 이 모든 입력에서 overflow 없이 정확하다는 것을 증명하지는 않았다. 여기서 관측한 모든 호출에서 결과가 FIPS 203 과 정확히 일치함만 확인했다.
- golden model 대조는 위 sha256 시점의 model 소스 기준이다. model 이 바뀌면 `scripts/gen_ext_vectors.sh --golden` 으로 다시 확인한다.
