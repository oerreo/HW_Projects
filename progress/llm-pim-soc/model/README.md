# model: 소형 LLM 추론 C golden model

llama2 구조(stories260K, stories15M)의 추론 전체를 C99로 구현한다. 세 판을 같은 코드베이스에 둔다.

| 판 | 내용 | 파일 |
|---|---|---|
| F | float32. 참조 구현(llama2.c `run.c`)과 연산 순서가 같아 logits까지 bit-identical | `src/fwd_f.c` |
| Q | int8 가중치와 활성, 행 안의 그룹마다 float scale, int32 그룹 누산, 비선형은 float | `src/fwd_q.c` |
| H | 전체 정수. RTL의 golden. kernel 경계 함수만 호출 | `src/kern.c`, `src/fwd_h.c`, 준비 `src/hq.c` |

숫자 형식과 측정 결과는 `docs/spec/numeric.md`.

## 구조
- `src/` 라이브러리. 파일 입출력 없음, 동적 할당 없음(호출자가 준 메모리 블록 하나를 `lm_arena_t`로 나눠 씀, 크기 계산 pass와 채우기 pass). ARM bare-metal에서 그대로 컴파일하는 대상.
  - `core.c` arena, checkpoint 배치, 그룹 크기 / `tok.c` BPE tokenizer / `bank.c` PIM형 bank 분할 GEMV 모델 / `tabs.c` LUT 상수(생성물, `make tabs`).
- `tools/` PC 전용: `io.c`(파일, 설정, 덤프와 프로파일 hook, 모델 메모리의 유일한 malloc), `run.c`(평가, 프로파일, 덤프, 생성), `rq.c`(runq.c 그룹 경계 검사), `gentab.c`, `chk.sh`(정수 경로 증명).
- `tests/` `t.c`(make test), `ref.c`(수정하지 않은 run.c를 include하는 wrapper).
- `cfg/` 실행 설정. `results/` 측정 결과 텍스트.

## 실행
명령행 인자를 쓰지 않는다. 설정은 파일(`CFG` 환경변수, 기본 `./run.cfg`)과 같은 이름의 환경변수로 준다.

```sh
sh ../data/scripts/fetch.sh     # 처음 한 번 (프로젝트 디렉토리 기준 경로는 data/README.md)
make                             # build/run, build/t, build/rq
make test                        # 전체 테스트, 끝에 TOTAL items, mismatches, PASS/FAIL
CFG=cfg/e1.cfg ./build/run       # 평가 (e1: 260K, e2: 15M) -> results/eval_m*.txt
CFG=cfg/p1.cfg ./build/run       # kernel 프로파일 -> results/prof_m*.txt
CFG=cfg/d1.cfg ./build/run       # kernel 입출력 덤프 -> build/vec_m*.bin
CFG=cfg/r1.cfg ./build/rq        # runq.c 그룹 경계 검사 -> results/runq_m*.txt
```

- 빌드 플래그 `-O2 -ffp-contract=off`(F판의 bit 일치 조건). `-ffast-math` 금지.
- `make -j` 금지(Makefile이 `.NOTPARALLEL`).
- 공용 서버 규칙에 따라 긴 실행은 프로젝트 디렉토리의 job 파일(`sh .job`)로 돌린다.

## 덤프 레코드 형식 (`tools/io.c`)
little-endian u32 단위. `magic 0x504D444B, kid, np, nb, prm[np], (esz, n, out) x nb`, 이어서 입력 버퍼 데이터(순서대로), 출력 버퍼 데이터(순서대로). kernel별 prm과 버퍼 순서는 `src/kern.h` 주석. `k_exec`에 그대로 넣어 재생할 수 있다(`make test`의 dump replay).
