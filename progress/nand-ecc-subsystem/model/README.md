# model: NAND ECC 서브시스템 C golden model (N2)

C99, 표준 라이브러리만. `src/`는 PC와 ARM bare-metal에서 같은 소스로 컴파일되는 라이브러리다(파일 I/O 없음, 메모리는 `plat.c` 한 곳: PC는 malloc, `-DPLAT_ARENA`이면 정적 arena). 수치 규칙은 `docs/spec/numeric.md`, 결과는 `docs/spec/n2_results.md`.

## 구조
| 파일 | 내용 | kernel |
|---|---|---|
| `src/plat.c` | 메모리 할당 계층 | - |
| `src/rng.c/h` | xoshiro128** [R50], splitmix64 seed, Box-Muller(검증용) | K_RNG(채널 안) |
| `src/code.c/h` | QC 표(`code/qc_*.txt`)와 alist 파서, H 전개(CSR), dual-diagonal 구조 검사, syndrome | K_SYND |
| `src/enc.c/h` | QC dual-diagonal encoder(선형 시간), 임의 H의 GF(2) 소거 encoder(외부 code, rank) | K_ENC |
| `src/chan.c/h` | TLC fit 모델([R5] 표, α), MLC 해석 모델([R3], 격자 위 수치 convolution), 최적 기준 전압 | 표 생성(측정 제외) |
| `src/sense.c/h` | 감지 격자, 정수 누적확률 표, 이산 역CDF 샘플러(정수만), read 설정(hard, retry offset, soft L), 해석/표 raw BER | K_CHAN, K_SENSE |
| `src/llr.c/h` | LLR LUT(double → int8), hard ±A, `llr_map` | K_LLR |
| `src/dec_ref.c/h` | float 참조: SPA, NMS, OMS × flooding, horizontal layered. 임의 H | 비교용 |
| `src/dec_fix.c/h` | 고정소수점 layered min-sum(RTL golden), 형식 parameter, ET-A/B, dump hook | K_DEC |
| `src/bch.c/h` | GF(2^14) BCH t = 73 (9207, 8192): LFSR encoder, syndrome, iBM, Chien | K_BCH_* |
| `src/policy.c/h` | read retry 상태 기계(hard → retry → soft 단계), 지연 모델 | K_POLICY |
| `tools/io.c/h` | PC 전용: 파일, 설정(`key value`, 같은 이름의 환경변수가 우선), 시계 | - |
| `tools/fer.c` | Monte Carlo FER 시뮬레이터(설정 파일, 오류 frame 수 정지, checkpoint 재시작, 실패 frame 통계, kernel 시간) | - |
| `tools/xdump.c`, `tools/fixref.py`, `tools/xcheck.sh` | 고정소수점 decoder의 kernel 경계 trace와 독립 Python 구현 비교 | - |
| `tools/rtab.c` | raw BER, 기준 전압, retry offset 표 | - |
| `tools/prof.c` | kernel별 PC 시간 | - |
| `tools/qc2alist.py` | 자체 code를 alist로(AFF3CT 입력) | - |
| `tools/queue.sh`, `tools/aff.sh`, `tools/summ.py` | FER 설정 순차 실행(checkpoint 재시작), AFF3CT 실행, 결과 표(95% Wilson 구간) | - |
| `tests/t.c`, `tools/det.sh` | `make test` | - |
| `cfg/` | 실행 설정(`r*` 외부 기준과 AWGN, `n*` NAND, `aff/*.args` AFF3CT 인자) | |
| `results/` | 실행 결과 텍스트 | |
| `code/`, `tools/gen.py`, `chk.py`, `qclib.py` | N1의 code 구성과 검증 | |

## 실행
명령행 인자를 쓰지 않는다(`process-privacy.md`). 설정은 `CFG` 환경변수가 가리키는 파일과 같은 이름의 환경변수.
```sh
sh ../data/scripts/fetch.sh && sh ../data/scripts/build_aff3ct.sh   # 프로젝트 디렉토리 기준 경로는 data/README.md
make                     # build/t, fer, xdump, rtab, prof  (gcc, -O2 -ffp-contract=off, -j1)
make ext                 # C2 alist와 자체 code alist
make test                # 단위 테스트 49항목 + fer 결정성 + 고정소수점 교차 검사
Q="cfg/r1.cfg ..." sh tools/queue.sh      # FER 실행 (job 파일로)
sh tools/aff.sh                            # AFF3CT 교차 실행 (cfg/aff/*.args)
CFG=cfg/tab.cfg ./build/rtab; CFG=cfg/prof.cfg ./build/prof
```

## fer 결과 줄 형식
`pt <x> sigma <σ> rber_ana <해석> rber_tab <정수 표> rber_meas <측정 hard> frames <N> sec <초>`, 이어서 decoder마다
`d<i> fe <frame 오류> fer <FER> fe_info <정보 비트 frame 오류> ber_info <정보 BER> undet <ok인데 틀린 frame> avg_it <평균 iteration> dec_ms <frame당 ms> cls <실패 frame 오류 비트: 정보 열, p0 열, dual-diagonal 열> hist <실패 frame 오류 수 분포: 1-2, 3-5, 6-10, 11-20, 21-50, 51+>`, BCH는 `fer_binom`(이항 꼬리) 추가, `prof_ms`(frame당 msg, enc, chan, llr ms).
- frame 오류는 codeword 전체 비교(정보 비트만 비교한 값은 `fe_info`). AFF3CT는 정보 비트 기준이다.
