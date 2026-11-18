# data: llm-pim-soc

외부 원본은 저장소에 넣지 않는다. `data/third_party/`(`.gitignore` 대상)에 받는 스크립트와 SHA-256 목록만 둔다.

## 받는 방법

```sh
# 프로젝트 디렉토리에서
sh data/scripts/fetch.sh
```

- 이미 받은 파일은 다시 받지 않는다. 받은 뒤 `data/scripts/checksums.sha256`으로 검증한다(처음 실행 때 이 목록을 만들었다).
- 받은 날짜: 2026-11-18. 요청에는 일반 User-Agent(`curl`)만 쓰고 개인 정보는 넣지 않는다.
- 용량: 약 63 MB(대부분 stories15M.bin).

## 파일, 출처, 라이선스

| 파일 (`data/third_party/`) | 출처 URL | 라이선스 | 확인 상태 | 용도 |
|---|---|---|---|---|
| `models/stories260K.bin` | https://huggingface.co/karpathy/tinyllamas/resolve/main/stories260K/stories260K.bin | MIT | 확인: HF 저장소 README 메타데이터 `license: mit` (`models/README.tinyllamas.md`) | 260K 모델 checkpoint (llama2.c version 0 형식, float32) |
| `models/tok512.bin` | https://huggingface.co/karpathy/tinyllamas/resolve/main/stories260K/tok512.bin | MIT (같은 HF 저장소) | 확인: 저장소 단위 라이선스. 파일별 별도 고지는 없음 | 260K용 tokenizer (vocab 512) |
| `models/stories15M.bin` | https://huggingface.co/karpathy/tinyllamas/resolve/main/stories15M.bin | MIT | 확인: 위와 같음 | 15M 모델 checkpoint |
| `models/README.tinyllamas.md` | https://huggingface.co/karpathy/tinyllamas/resolve/main/README.md | - | - | 라이선스 근거 보관 |
| `models/tokenizer.bin` | https://raw.githubusercontent.com/karpathy/llama2.c/master/tokenizer.bin | **미확인** | llama2.c 저장소는 MIT이나, 이 파일은 Meta Llama 2의 `tokenizer.model`에서 변환한 것이다. Meta 쪽 라이선스(Llama 2 Community License)가 tokenizer에 적용되는지 원문으로 확인하지 못했다 | 15M용 tokenizer (vocab 32000) |
| `llama2c/run.c` | https://raw.githubusercontent.com/karpathy/llama2.c/master/run.c | MIT (`llama2c/LICENSE`, "Copyright (c) 2023 Andrej") | 확인 | float 참조 구현. 테스트에서 기준 token과 logits 생성에만 사용 |
| `llama2c/runq.c` | 같은 저장소 | MIT | 확인 | 공개 int8 구현. 그룹 경계 의심 확인(`model/tools/rq.c`)에만 사용 |
| `llama2c/export.py`, `model.py`, `tokenizer.py`, `README.md`, `LICENSE` | 같은 저장소 | MIT | 확인 | 형식 확인용 참고 자료(실행하지 않음) |
| `tinystories/valid_head.txt` | https://huggingface.co/datasets/roneneldan/TinyStories/resolve/main/TinyStories-valid.txt 의 처음 262,144 B (HTTP Range) | CDLA-Sharing-1.0 | 확인: 데이터셋 README 메타데이터 (`tinystories/README.dataset.md`) | 평가 텍스트(cross-entropy). 앞쪽 32개 story만 사용 |
| `tinystories/README.dataset.md` | https://huggingface.co/datasets/roneneldan/TinyStories/resolve/main/README.md | - | - | 라이선스 근거 보관 |

- `master` 브랜치와 `main` revision에서 받았으므로 원본이 바뀌면 체크섬 검증이 실패한다. 그때는 바뀐 내용을 확인하고 체크섬과 이 표를 갱신한다.
- TinyStories는 GPT-3.5/GPT-4 생성 텍스트다. 앞부분 256 KiB(story 약 300개)만 받았고, 마지막 story는 잘려 있어 평가에서 뺀다. 파일 첫 story는 원본 자체가 문장 중간("Spot. Spot saw ...")에서 시작한다.

## 참조 구현의 사용 방식

- 우리 C 코드(`model/src/`)는 llama2.c의 구조(연산 순서, checkpoint와 tokenizer 형식)를 참고해 직접 작성했다. 코드를 복사하지 않았다.
- `run.c`와 `runq.c`는 수정하지 않고, 빌드 때 심볼릭 링크(`model/build/x1.c`, `x2.c`)로 테스트와 검사 도구에 include한다(`model/tests/ref.c`, `model/tools/rq.c`). 저장소에는 들어가지 않는다.
- `runq.c` 실행에 필요한 version 2(Q8_0) checkpoint는 PyTorch 없이 `model/tools/rq.c`가 `export.py`의 version 2 규칙을 C로 재현해 만든다(그룹 64, `dim`으로만 축소, 평탄화한 tensor 단위 그룹, float32 scale, round half to even). 결과 파일은 `model/build/`에만 둔다.

## 직접 만든 데이터

| 파일 | 내용 | 생성 |
|---|---|---|
| `prompts/prompts.txt` | 검증 프롬프트 32개: 빈 프롬프트 1개(`<EMPTY>`) + 직접 작성한 짧은 영어 문장 31개(숫자, 따옴표, 비ASCII `é` 포함) | 직접 작성 |
| (seed) | 단위 테스트의 random 벡터 seed 20261118 (xorshift64), `model/test.cfg` | - |

## Test data 세 종류 (project-flow G2 기준) 현황

1. 공인/외부: 공개 checkpoint와 tokenizer, 공개 참조 구현 `run.c`의 출력(F판이 일치해야 하는 기준), TinyStories validation 일부.
2. 방향성: `model/tests/t.c`의 경계값(0 벡터, int32 최대/최소, 포화, 최대 길이 행 16384, 모든 원소 127, 그룹이 행을 나누지 못하는 descriptor 거부), exp/sigmoid LUT 전 구간 전수.
3. random: seed 20261118로 생성하는 kernel 입력. 항목 수는 `make test` 출력에 나온다.
4. kernel 경계 덤프: `model/cfg/d1.cfg`, `d2.cfg`로 H판 kernel 입출력 레코드를 `model/build/vec_m*.bin`에 만든다(RTL TB 벡터 후보, 형식은 `docs/spec/numeric.md`).
