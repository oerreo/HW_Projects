# Log: llm-pim-soc

## 2026-11-18: 프로젝트 시작  [notion: synced]
- 결정(사용자): 다음 프로젝트를 "LLM 추론 + PIM"으로, 그 다음을 NAND ECC로 한다. `pqc-ntt-ip`는 보드 검증까지만.
- 한 일: brief와 plan 작성, 서베이(S0) 착수.
- S0 결과: `survey/survey.md`(직접 확인 38, 재인용 1, 미확인 10). S1 결정: 두 모델(260K, 15M) 지원, C 구현 3단계(F, Q, H), kernel 6종 초안. `spec/scope.md`.

## 2026-11-18: S2 C golden model (G1)  [notion: pending]
- 한 일: `model/`(F float 참조판, Q int8 matmul판, H 전체 정수판과 kernel 경계 함수, bank 분할 GEMV), `data/`(받는 스크립트, 체크섬, 프롬프트 32개), `docs/spec/numeric.md`.
- 결과(수퍼바이저 재실행): `make test` 14,190,666 항목, mismatch 0, PASS. 포함: F판이 공개 참조 구현과 두 모델에서 생성 token과 logits 일치, H판 추론 경로에 float 없음(13항목), bank 분할 GEMV bit-exact, 덤프 재생.
- agent 보고(재실행 안 함): 정확도 표(F 대비 cross-entropy 증가. 260K: Qg +0.0014, HD +0.0011. 15M: Qg +0.0030, HD +0.0053 nats/token), PC 시간 비중(260K gemv 43%, attn 49%. 15M gemv 94.6%. x86 수치이며 ARM 아님).
- 발견: 공개 양자화 구현(runq.c)은 행 길이가 그룹 크기의 배수가 아니면 행 끝 입력을 버리고 scale 인덱스가 어긋난다. 260K에서 재현(top-1 일치 42.0%). 단 시험 파일은 export 규칙을 C로 재현해 만든 것이라 원본 export 결과와 bit 일치는 미확인.
- 미정: H판 형식. 권장 HD(q/k/v int16)는 260K에서 KV cache 320 KiB(추정)라 가중치와 함께 BRAM에 안 들어간다. 후보 간 차이가 표본(프롬프트 32, story 32) 잡음 수준이라 평가를 늘려 다시 잰다(S2b).
- 한계: ARM 컴파일 미확인(cross compiler 없음). 15M tokenizer 라이선스 미확인.
- 다음: S2b(평가 확대와 형식 확정), S3(ARM baseline 프로그램).
