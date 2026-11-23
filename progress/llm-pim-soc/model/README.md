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
  - `bank.c`에는 S4-1에서 PIM bank RAM image(`bimg_*`)와 가속기형 gemv 행 레코드(`rrec_*`) 생성기가 추가됐다(ARM에서도 쓰는 대상이라 `src/`에 둔다).
- `tools/` PC 전용: `io.c`(파일, 설정, 덤프와 프로파일 hook, 모델 메모리의 유일한 malloc, 덤프 loop `dump_steps`와 위치 필터 `pos_sel`), `run.c`(평가, 프로파일, 덤프, 생성), `vt.c`(S4-1 RTL 벡터 도구: split, range, bimg, rrec), `vec.sh`(`make vec`), `rq.c`(runq.c 그룹 경계 검사), `gentab.c`, `chk.sh`(정수 경로 증명).
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
make vec                         # S4-1 RTL 벡터(K12V8): build/vec/ (아래 "RTL 검증 벡터")
CFG=cfg/r1.cfg ./build/rq        # runq.c 그룹 경계 검사 -> results/runq_m*.txt
CFG=cfg/g1.cfg ./build/run       # S2b story 단위 평가 (g1~g3: 260K, h1~h3: 15M) -> results/ce_m*.txt
CI_IN="results/ce_m1a.txt results/ce_m1b.txt results/ce_m1c.txt" CI_OUT=results/ci_m1.txt python3 -I tools/ci.py
python3 -I tools/cost.py         # 형식별 메모리 비용 [계산] -> 표준 출력 (results/cost.txt)
```
- `job ceval`(S2b): story마다 한 줄(`st index tokens sum_ce(F, 변형...) | top1(변형...)`)을 쓴다. `tools/ci.py`가 여러 파일을 story index로 합치고(F 합이 파일 사이에서 같은지 검사) paired bootstrap과 표준오차로 95% 구간을 낸다. 인자 없이 환경변수(`CI_IN`, `CI_OUT`, `CI_B`, `CI_SEED`)만 쓴다.
- S2b 형식(`tools/io.c`의 `FMTS`): `HI`(HD + 가중치 그룹), `KxVy`(HB/HD 바탕, q와 K x비트, V y비트, x, y는 8, 12, 16), 이름 끝 `w<N>`(attention window N). `lm_hfmt_t`의 추가 필드 `kbits`, `vbits`, `win`이 0이면 기존 동작과 bit 단위로 같다. `kbits`가 0이 아니면 attention은 `K_ATTN2`(`k_attn2`)로 호출된다.

- 빌드 플래그 `-O2 -ffp-contract=off`(F판의 bit 일치 조건). `-ffast-math` 금지.
- `make -j` 금지(Makefile이 `.NOTPARALLEL`).
- 공용 서버 규칙에 따라 긴 실행은 프로젝트 디렉토리의 job 파일(`sh .job`)로 돌린다.

## 덤프 레코드 형식 (`tools/io.c`)
little-endian u32 단위. `magic 0x504D444B, kid, np, nb, prm[np], (esz, n, out) x nb`, 이어서 입력 버퍼 데이터(순서대로), 출력 버퍼 데이터(순서대로). kernel별 prm과 버퍼 순서는 `src/kern.h` 주석. `k_exec`에 그대로 넣어 재생할 수 있다(`make test`의 dump replay).

## Stage 함수 (S4-1, `docs/spec/hierarchy.md` 4절 A1~A7)
kernel 함수가 스스로 호출하는 stage 함수로 나눠 export했다. RTL leaf/L1 모듈의 golden이며 별도 재구현은 없다. 바꾼 뒤 기존 덤프 4종(HB와 K12V8, 260K와 15M, `cfg/d1.cfg`, `cfg/d2.cfg`)이 변경 전 바이너리의 출력과 `cmp` 동일함을 확인했다(2026-11-19).

| 함수 (`src/kern.h`) | 대상 RTL | 내용 |
|---|---|---|
| `k_sat32`, `k_rshr` | `rshr_sat` | 포화와 round-half-up shift |
| `k_dot8` | `dotp`, `mac_row` | int8 곱 n개의 int32 합(그룹 하나, gs = n이면 행 전체) |
| `k_gemv_row` | `mac_row` + 행 가수 곱 | `S = sum(dot8(group) * wm[group])` |
| `k_gemv_out` | `gemv_scale` | `y = sat32(rshr(S * xm, we + xe - fo))` |
| `k_aq_setup`, `k_aq_one` (`k_aq_t`) | `actq_core` | amax에서 (M, R, e)와 원소 하나의 양자화 |
| `k_gemv_st`, `k_actq_st`, `k_rmsnorm_st`, `k_swiglu_st`, `k_attn2_st`, `k_exec_st` | L1/L2 stage 덤프 | 원래 kernel과 같은 계산에 선택적 trace 구조체(`k_*_st_t`)로 중간값을 기록. NULL이면 원래 kernel과 같다 |

trace 내용: gemv는 행별 `S`, actq는 `amax`와 `k_aq_t`, rmsnorm은 `k, ss, u, rm, re, sh`, 양자화 전 `y[n]`, `ymax`, swiglu는 양자화 전 `g[n]`과 `amax`, attention은 `dot[T]`, score `s[T]`, 분자 `e[T]`, `mx`, `sum`, `R`, `emin`, `mmax`, `G`, 정렬된 V 가중치 `w[T]`, 누산기 `acc[hs]`.

## RTL 검증 벡터 (`make vec`, `tools/vec.sh`, 출력은 `build/vec/`, 커밋 안 함)
| 파일 | 내용 | 생성 |
|---|---|---|
| `d3.bin` | 260K K12V8 덤프, 프롬프트 1, 위치 0..7, 63, 127, 255, 511 (512 위치 계산, 12 위치 기록, T 최대 512), 2,388 레코드 | `cfg/d3.cfg` |
| `d4.bin` | 15M K12V8 덤프, 프롬프트 1, 위치 0..3, 127, 255 (T 최대 256), 1,428 레코드 | `cfg/d4.cfg` |
| `m1/`, `m2/<kernel>.bin` | kernel별 레코드 파일(덤프와 같은 형식). 쓰기 전에 모든 레코드를 `k_exec`로 재생해 기록 출력과 같은지 확인 | `vt` job split |
| `m1/`, `m2/manifest.txt` | `rec <kernel> <파일 안 index> <기록 위치 서수> <prm...>`, 파일별 레코드 수 | 같음 |
| `m1/`, `m2/rrec.bin`, `rrec_map.txt` | 모든 행렬(층마다 wq wk wv wo w1 w3 w2, 끝에 cls)의 gemv 행 레코드(header 8 B + 행, 8 B padding, `arch.md` 2.2). 260K 288,704 B, 15M 15,586,816 B | `vt` job rrec |
| `pim/bank0..3.hex`, `bimg_map.txt` | 260K PIM bank RAM image, NB 4 x LB 16, depth 4096, 행렬 순서는 rrec와 같음. 한 줄 = 144비트 word(상위 16비트 tag, lane i = 비트 8i+7..8i). 행의 첫 word tag = 행 가수, 나머지 0. 사용 4,072 word | `vt` job bimg |
| `SHA256SUMS` | 위 파일의 체크섬 | `vec.sh` |
| `../results/range_k12v8.txt` | A10 지수(E)와 shift(SH) 범위표. 모든 레코드를 trace와 함께 재생(재생 불일치 0) | `vt` job range |

- 덤프 설정 키(S4-1 추가): `pos`(위치 필터 `a-b,c,...`, 모든 위치를 계산하되 선택한 위치의 kernel 호출만 기록), `noeos 1`(BOS/EOS 뒤에도 계속 생성해 긴 T에 도달). 둘 다 없으면 이전 동작과 같다(`cmp` 확인).
- `vt` 설정: `CFG` 파일 또는 같은 이름의 환경변수. job `split`(`in`, `odir`), `range`(`in` 공백 구분, `lab`, `out`), `bimg`(`ck`, `tk`, `var`, `nb`, `depth`, `odir`), `rrec`(`ck`, `tk`, `var`, `odir`). 명령행 인자는 쓰지 않는다.
- PIM bank image의 물리 배치(144비트 중 tag 16비트를 두 BRAM36의 parity 비트에 나누는 방법)는 `fpga/` wrapper의 일이다. image 형식은 논리 word(데이터 128 + tag 16)로 정했다.
- DPI-C: `tb/dpi/kdpi.c`가 `src/kern.c`, `tabs.c`, `bank.c`, `core.c`를 Questa에서 직접 부른다(레코드 파일 reader, kernel 재생, stage 함수, 행 레코드 beat, bank image). 연산은 모두 `src/`의 함수다.

## 실행기 끼움점 `lm_h_forward_x` (S5-1, `docs/spec/system.md` 2.1, 결정 O3)
- `lm_h_forward_x(s, c, w, tok, pos, hook, ex)`: `lm_h_forward`와 같은 호출 순서와 descriptor로 forward를 돌리되, 모든 kernel 호출을 `k_exec(c)` 대신 `ex->fn(ex->user, c)`로 낸다(`ex` 또는 `ex->fn`이 NULL이면 `k_exec`). hook은 그대로 호출 앞(phase 0)과 뒤(phase 1)에 불린다. 반환값 규칙도 같다(호출 중 하나라도 음수면 NULL).
- `k_exec_t { k_exec_fn fn; void *user; }`, `k_exec_fn(void *user, const kcall_t *c)`는 `src/llm.h`. 실행기는 descriptor의 버퍼에 결과를 써야 한다(forward가 이어서 그 버퍼를 읽는다). `fpga/sys/sw/sx_exec.c`의 `sx_exec`가 이 자리에서 kernel을 ARM 또는 PL IP로 보낸다.
- `lm_h_forward(...)`는 `lm_h_forward_x(..., NULL)`이다. 바꾼 뒤 기존 덤프 4종(`cfg/d1.cfg`, `cfg/d2.cfg`의 HB와 K12V8, 260K와 15M)이 변경 전 바이너리의 출력과 `cmp` 동일함을 확인했고(2026-11-20, `model/.job51a`, `.job51b`), `make test`에 그룹 `m1/m2 forward_x executor`를 더했다: K12V8 두 사본에서 `lm_h_forward`와, 출력을 사본 버퍼에서 계산해 되돌려 쓰는 실행기를 낀 `lm_h_forward_x`를 260K 64 위치, 15M 16 위치 돌려 호출마다 (kid, prm, 버퍼 모양, 호출 뒤 버퍼 내용 hash)와 logits, argmax, 실행기 호출 수를 비교한다. 결과: TOTAL items 16,686,497(16,669,793 + 12,864 + 3,840), mismatches 0. 로그 `results/maketest_s5_1.txt`.

## make test 추가 그룹 (S4-1)
| 그룹 | 내용 |
|---|---|
| `m1/m2 stage traces K12V8` | 260K 40 위치, 15M 6 위치의 모든 레코드를 `k_exec_st`로 재생. 출력이 기록과 같고, 기록 출력이 trace와 export한 stage 함수로 다시 나오는지(gemv `k_gemv_out`/`k_dot8`, actq/rmsnorm/swiglu `k_aq_one`, rmsnorm `k_rsqrt`, attention의 score, 정규화, 출력 shift) |
| `m1 PIM bank image` | 260K 36개 행렬을 image로 만들고 되읽은 `bank_mat_t`가 `bank_pack(BANK_ROW)`과 배열 단위로 같고, `bank_gemv`가 `k_gemv`와 같고, 명령 수가 같고, depth가 4,072 word(`arch.md` 3.1)인지 |
| `m1/m2 gemv row records` | 모든 행렬의 행 레코드 pack/unpack 왕복, 크기, header 비율(260K 10.78%, 15M 2.63%, `arch.md` 2.2와 같음) |
| `m1 dump position filter` | 위치 필터 파서, 필터한 덤프 = 필터 없는 덤프에서 선택 위치 구간을 이은 것(byte 단위) |

결과: TOTAL items 16,669,793, mismatches 0 (S4-1 전 15,489,337 + 추가 1,180,456). 로그 `results/maketest_s4_1.txt`.
